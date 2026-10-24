//! A read-only connection and its bound SELECT statement.
//!
//! `QuerySession` owns both the connection and the statement: it prepares,
//! binds, reads the plan, runs and resets the SELECT, and it finalises the
//! statement before it closes the connection. Declare a session in a fixed
//! location and open it in place: the database keeps the address of its
//! instance, and an opened session must not be returned or moved.

const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const result = @import("../result.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const Side = cli_comparison.Side;

/// Which copy a session belongs to. It only decides the wording of the
/// diagnostics, so that the messages stay those of the single-copy CLI.
pub const Kind = enum { baseline, variant };

/// The version and the source id of the bundled SQLite, for the summary. The
/// display stage receives them as strings and never calls into SQLite.
pub fn sqliteVersion() [*:0]const u8 {
    return sqlite.sqlite3_libversion();
}

pub fn sqliteSourceId() [*:0]const u8 {
    return sqlite.sqlite3_sourceid();
}

/// One read-only connection and its bound SELECT, ready to run again.
pub const QuerySession = struct {
    database: db.Db = .{},
    statement: ?*sqlite.sqlite3_stmt = null,
    opened: bool = false,

    /// Opens `path` read-only, prepares `sql`, and binds `binds`. Returns
    /// false after writing the diagnostic that goes with the failure;
    /// `failure` gets its exit code. A caller that declares the session
    /// before this call still cleans up a half-opened session through
    /// `deinit`.
    pub fn open(
        self: *QuerySession,
        path: [:0]const u8,
        sql: [:0]const u8,
        binds: []const db.BindArg,
        kind: Kind,
        index_sql: [:0]const u8,
        stderr: *Io.Writer,
        failure: *cli_control.ExitCode,
    ) bool {
        self.database.openReadOnly(path) catch |err| {
            const detail = openErrorMessage(err);
            switch (kind) {
                .baseline => stderr.print("error: cannot open the baseline '{s}' read-only: {s}\n", .{ path, detail }) catch {},
                .variant => stderr.print("error: cannot open the variant '{s}' read-only: {s}\n", .{ path, detail }) catch {},
            }
            failure.* = .rejected;
            return false;
        };
        self.opened = true;

        const statement = self.database.prepareSelect(sql) catch |err| {
            switch (kind) {
                .baseline => reportSelectFailure(stderr, err, &self.database, index_sql),
                .variant => reportCheckFailure(stderr, "--select on the variant", err, &self.database),
            }
            failure.* = .rejected;
            return false;
        };
        self.statement = statement;

        db.bindAll(statement, binds) catch |err| {
            const detail = bindErrorMessage(err);
            // The counts tell the user what to change without reading the
            // SELECT again.
            const counts: BindCounts = .{ .parameters = sqlite.sqlite3_bind_parameter_count(statement), .given = binds.len };
            switch (kind) {
                .baseline => stderr.print("error: --bind: {s} ({f})\n", .{ detail, counts }) catch {},
                .variant => stderr.print("error: --bind on the variant: {s} ({f})\n", .{ detail, counts }) catch {},
            }
            failure.* = .rejected;
            return false;
        };
        return true;
    }

    /// Finalises the statement. The connection stays open, so this is the
    /// half of `deinit` that must happen first. Safe to call again.
    pub fn finalize(self: *QuerySession) void {
        if (self.statement) |statement| {
            _ = sqlite.sqlite3_finalize(statement);
            self.statement = null;
        }
    }

    /// Closes the connection. A failed close keeps the handle so that the
    /// caller can report it, and marks the cleanup as failed.
    pub fn close(self: *QuerySession, kind: Kind, stderr: *Io.Writer, cleanup_failed: *bool) void {
        if (!self.opened) return;
        self.database.close() catch {
            cleanup_failed.* = true;
            const detail = self.database.message();
            switch (kind) {
                .baseline => stderr.print("error: the database connection could not be closed: {s}\n", .{detail}) catch {},
                .variant => stderr.print("error: the database connection of the variant could not be closed: {s}\n", .{detail}) catch {},
            }
            return;
        };
        self.opened = false;
    }

    /// Releases both, in the only order that works: the statement is
    /// finalised before the connection is closed.
    pub fn deinit(self: *QuerySession, kind: Kind, stderr: *Io.Writer, cleanup_failed: *bool) void {
        self.finalize();
        self.close(kind, stderr, cleanup_failed);
    }

    /// Checks the candidate DDL on this connection without running it.
    /// Returns false after writing the diagnostic.
    pub fn checkCreateIndex(self: *QuerySession, sql: [:0]const u8, stderr: *Io.Writer) bool {
        self.database.checkCreateIndex(sql) catch |err| {
            reportCheckFailure(stderr, "--index-sql", err, &self.database);
            return false;
        };
        return true;
    }

    /// What the authorizer learnt about the SELECT of this session.
    pub fn clues(self: *const QuerySession) db.Clues {
        return self.database.clues;
    }

    /// The counters of the statement as they stand now. They are cumulative,
    /// so the value is read once, after the first run.
    pub fn counters(self: *const QuerySession) db.Counters {
        return db.statementCounters(self.statement.?);
    }

    pub fn columnCount(self: *const QuerySession) c_int {
        return sqlite.sqlite3_column_count(self.statement.?);
    }

    /// The engine message of the last failure of this connection.
    pub fn message(self: *const QuerySession) []const u8 {
        return self.database.message();
    }

    /// Resets the statement for another run; the binds stay. The result of
    /// the reset is the result of the previous run, which was already
    /// checked, so it is dropped.
    pub fn reset(self: *QuerySession) void {
        _ = sqlite.sqlite3_reset(self.statement.?);
    }

    /// Steps the statement to its end without reading the columns. This is
    /// the narrow API the timed rounds use.
    pub fn step(self: *QuerySession, control: *db.StepControl) db.StepError!u64 {
        return self.database.stepAll(self.statement.?, control, null);
    }

    /// Runs the SELECT once, keeping its rows in `rows_out`.
    pub fn run(self: *QuerySession, control: *db.StepControl, rows_out: ?*result.RowCollector) db.StepError!u64 {
        return self.database.stepAll(self.statement.?, control, rows_out);
    }

    /// Resets, steps to the first row and reads its first column as an
    /// integer, or null when there is no row. This checks that a reset kept
    /// the binds; the timed rounds never read columns.
    pub fn firstRowInt64(self: *QuerySession) db.StepError!?i64 {
        self.reset();
        const rc = sqlite.sqlite3_step(self.statement.?);
        if (rc == sqlite.SQLITE_DONE) return null;
        if (rc != sqlite.SQLITE_ROW) return error.StepFailed;
        return sqlite.sqlite3_column_int64(self.statement.?, 0);
    }

    /// Reads the plan of the SELECT from a statement of its own (D-302).
    /// Returns null after writing the diagnostic; `failure` gets its code.
    pub fn plan(
        self: *QuerySession,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const db.BindArg,
        side: Side,
        stderr: *Io.Writer,
        failure: *cli_control.ExitCode,
    ) ?db.Plan {
        return self.database.explainPlan(arena, sql, binds) catch |err| {
            const detail = if (err == error.ExplainFailed and self.database.errorCode() != sqlite.SQLITE_OK)
                self.database.message()
            else
                @errorName(err);
            stderr.print("error: --select: the query plan could not be read on the {t}: {s}\n", .{ side, detail }) catch {};
            failure.* = .rejected;
            return null;
        };
    }
};

/// Reads the plan of the SELECT on one session and runs it there, keeping the
/// rows in `rows_out`. Returns null after reporting a failure, with its exit
/// code in `failure`.
pub fn measure(
    arena: std.mem.Allocator,
    session: *QuerySession,
    sql: [:0]const u8,
    binds: []const db.BindArg,
    control: *db.StepControl,
    rows_out: ?*result.RowCollector,
    side: Side,
    stderr: *Io.Writer,
    failure: *cli_control.ExitCode,
) ?cli_comparison.Measurement {
    const plan = session.plan(arena, sql, binds, side, stderr, failure) orelse return null;

    const rows = session.run(control, rows_out) catch |err| {
        failure.* = reportStepFailure(err, session, control.timeout_ms, side, null, stderr);
        return null;
    };
    return .{
        .rows = rows,
        .plan = plan,
        .counters = session.counters(),
        .columns = session.columnCount(),
    };
}

/// Reports a SELECT run that did not reach its end and returns its exit code.
/// `timed_run` numbers a timed run from 1; null is the first, untimed run.
pub fn reportStepFailure(
    err: db.StepError,
    session: *QuerySession,
    timeout_ms: u64,
    side: Side,
    timed_run: ?usize,
    stderr: *Io.Writer,
) cli_control.ExitCode {
    var buffer: [32]u8 = undefined;
    const run_name = if (timed_run) |number| std.fmt.bufPrint(&buffer, " (timed run {d})", .{number}) catch "" else "";
    switch (err) {
        error.Timeout => {
            stderr.print("error: --select exceeded the time limit of {d} ms on the {t}{s}\n", .{ timeout_ms, side, run_name }) catch {};
            return .timeout;
        },
        error.Interrupted => return cli_control.reportInterrupted(stderr),
        error.StepFailed => {
            stderr.print("error: --select failed while running on the {t}{s}: {s}\n", .{ side, run_name, session.message() }) catch {};
            return .rejected;
        },
    }
}

const BindCounts = struct {
    parameters: c_int,
    given: usize,

    pub fn format(self: BindCounts, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("parameters in the SELECT: {d}; --bind given: {d}", .{ self.parameters, self.given });
    }
};

fn openMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .baseline => "error: cannot open the baseline '{s}' read-only: {s}\n",
        .variant => "error: cannot open the variant '{s}' read-only: {s}\n",
    };
}

fn closeMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .baseline => "error: the database connection could not be closed: {s}\n",
        .variant => "error: the database connection of the variant could not be closed: {s}\n",
    };
}

fn bindMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .baseline => "error: --bind: {s}\n",
        .variant => "error: --bind on the variant: {s}\n",
    };
}

/// D-508: a SELECT that names the candidate index in `INDEXED BY` cannot be
/// prepared on the baseline, which lacks that index. SQLite reports it as
/// `no such index: <name>` with the name unquoted; when that name is the one
/// the candidate DDL would create, the rejection says so. Every other failure
/// is reported as is.
fn reportSelectFailure(stderr: *Io.Writer, err: db.CheckError, database: *db.Db, index_sql: [:0]const u8) void {
    const prefix = "no such index: ";
    if (err == error.StatementInvalid and database.errorCode() != sqlite.SQLITE_OK) {
        const message = database.message();
        var saved: [512]u8 = undefined;
        if (std.mem.startsWith(u8, message, prefix) and message.len <= saved.len) {
            // The DDL check below replaces the engine message, so keep a copy.
            @memcpy(saved[0..message.len], message);
            const missing = saved[prefix.len..message.len];
            database.checkCreateIndex(index_sql) catch {};
            if (database.candidateIndexName()) |name| {
                if (std.ascii.eqlIgnoreCase(name, missing)) {
                    stderr.print("error: --select: the SELECT (or a view it reads) names the candidate index '{s}' in INDEXED BY, but the baseline does not have that index\n", .{name}) catch {};
                    return;
                }
            }
            stderr.print("error: --select: {s}: {s}\n", .{ checkErrorMessage(err), saved[0..message.len] }) catch {};
            return;
        }
    }
    reportCheckFailure(stderr, "--select", err, database);
}

/// Prints a check failure. The engine message is appended only when SQLite
/// reported an error: some rejections come from our own final checks (an empty
/// file, a `VACUUM`), where the engine message would only say "not an error".
fn reportCheckFailure(stderr: *Io.Writer, option: []const u8, err: db.CheckError, database: *const db.Db) void {
    if (database.errorCode() != sqlite.SQLITE_OK) {
        stderr.print("error: {s}: {s}: {s}\n", .{ option, checkErrorMessage(err), database.message() }) catch {};
    } else {
        stderr.print("error: {s}: {s}\n", .{ option, checkErrorMessage(err) }) catch {};
    }
}

pub fn openErrorMessage(err: db.OpenError) []const u8 {
    return switch (err) {
        error.OpenFailed => "the file is missing, is not a database, or is locked",
        error.NotReadOnlyConnection => "the connection is not read-only",
        error.GuardSetupFailed => "the read-only guards could not be installed",
    };
}

fn checkErrorMessage(err: db.CheckError) []const u8 {
    return switch (err) {
        error.EmptyStatement => "the file holds no statement",
        error.MultipleStatements => "the file must hold exactly one statement",
        error.StatementRejected => "the statement is not allowed here",
        error.StatementInvalid => "the statement is not valid for this database",
        error.StatementNotReadOnly => "the statement is not read-only",
        error.StatementNotCreateIndex => "the statement is not one CREATE INDEX",
    };
}

fn bindErrorMessage(err: db.BindError) []const u8 {
    return switch (err) {
        error.ParameterCountMismatch => "more values were given than the SELECT has parameters",
        error.BindNumberOutOfRange => "a bind number is outside 1..parameter count",
        error.DuplicateBindNumber => "a bind number is given more than once",
        error.MissingBindNumber => "every number in 1..parameter count must be given exactly once",
        error.BindFailed => "SQLite refused a bind value",
    };
}

const testing = std.testing;

/// The schema of the fixture database the sessions below run against.
const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

/// A temporary directory with one database in it.
const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,

    fn init() !Fixture {
        var fixture: Fixture = .{ .tmp = testing.tmpDir(.{}), .db_path = undefined };
        errdefer fixture.tmp.cleanup();
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "fixture.db", .data = "" });
        fixture.db_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "fixture.db", testing.allocator);
        errdefer testing.allocator.free(fixture.db_path);
        try db.createTestDatabase(fixture.db_path, fixture_schema);
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        self.tmp.cleanup();
    }
};

test "a session finalizes its statement before it closes the connection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.finalize();
    if (!session.open(fixture.db_path, "SELECT count(*) FROM t", &.{}, .baseline, "", &stderr, &failure)) return error.OpenFailed;
    try testing.expect(session.statement != null);
    try testing.expect(session.opened);

    // The connection cannot be closed first, so `finalize` must run while the
    // connection is still open: the statement is gone, the session is not.
    session.finalize();
    try testing.expect(session.statement == null);
    try testing.expect(session.opened);
    session.close(.baseline, &stderr, &cleanup_failed);
    try testing.expect(!session.opened);
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
}

test "a session re-runs from reset with the same binds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.close(.baseline, &stderr, &cleanup_failed);
    defer session.finalize();
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .int = 2 } }};
    if (!session.open(fixture.db_path, "SELECT count(*) FROM t WHERE a = ?1", &binds, .baseline, "", &stderr, &failure)) return error.OpenFailed;

    var control = db.StepControl.init(testing.io, 0, cli_control.cancelFlag());
    try testing.expectEqual(@as(u64, 1), try session.run(&control, null));
    // The reset keeps the binds, so the same row comes back on the next step.
    try testing.expectEqual(@as(?i64, 1), try session.firstRowInt64());
    // A reset makes the next run a full run again.
    session.reset();
    try testing.expectEqual(@as(u64, 1), try session.run(&control, null));
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
}

test "a timeout on the variant names the variant and is not a comparison" {
    // Only the variant run is measured here: a SELECT that is slow on the
    // variant alone cannot be built portably, so the step is driven directly.
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c";
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.close(.variant, &stderr, &cleanup_failed);
    defer session.finalize();
    if (!session.open(fixture.db_path, sql, &.{}, .variant, "", &stderr, &failure)) return error.OpenFailed;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var control = db.StepControl.init(testing.io, 1, &cancel);
    var budget: result.Budget = .{};
    var rows = result.RowCollector.init(testing.allocator, &budget);
    defer rows.deinit();
    try testing.expectEqual(@as(?cli_comparison.Measurement, null), measure(arena_state.allocator(), &session, sql, &.{}, &control, &rows, .variant, &stderr, &failure));
    try testing.expectEqual(cli_control.ExitCode.timeout, failure);
    try testing.expectEqualStrings("error: --select exceeded the time limit of 1 ms on the variant\n", stderr.buffered());
}

test "a session that could not open still cleans up through deinit" {
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.deinit(.baseline, &stderr, &cleanup_failed);
    try testing.expect(!session.open("/nonexistent/qenome-no-such.db", "SELECT 1", &.{}, .baseline, "", &stderr, &failure));
    try testing.expectEqual(cli_control.ExitCode.rejected, failure);
    try testing.expectEqualStrings("error: cannot open the baseline '/nonexistent/qenome-no-such.db' read-only: the file is missing, is not a database, or is locked\n", stderr.buffered());

    // The caller's cleanup runs on the half-opened session: it must not touch
    // anything and must not report a cleanup failure. It is safe to repeat.
    session.deinit(.baseline, &stderr, &cleanup_failed);
    try testing.expect(!cleanup_failed);
    try testing.expect(!session.opened);
    try testing.expect(session.statement == null);
    try testing.expectEqualStrings("error: cannot open the baseline '/nonexistent/qenome-no-such.db' read-only: the file is missing, is not a database, or is locked\n", stderr.buffered());
}

test "a session with a bind failure is cleaned up by its caller" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.deinit(.baseline, &stderr, &cleanup_failed);
    const binds = [_]db.BindArg{.{ .number = 2, .value = .{ .int = 1 } }};
    try testing.expect(!session.open(fixture.db_path, "SELECT count(*) FROM t WHERE a = ?1", &binds, .baseline, "", &stderr, &failure));
    try testing.expectEqual(cli_control.ExitCode.rejected, failure);
    try testing.expect(std.mem.startsWith(u8, stderr.buffered(), "error: --bind:"));

    // The statement was prepared before the bind failed; the connection and
    // the statement are still released in the right order.
    try testing.expect(session.statement != null);
    session.deinit(.baseline, &stderr, &cleanup_failed);
    try testing.expect(session.statement == null);
    try testing.expect(!session.opened);
    try testing.expect(!cleanup_failed);
}
