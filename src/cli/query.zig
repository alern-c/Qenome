const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const result = @import("../result.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const Side = cli_comparison.Side;

pub const Kind = enum { baseline, variant };

pub fn sqliteVersion() [*:0]const u8 {
    return sqlite.sqlite3_libversion();
}

pub fn sqliteSourceId() [*:0]const u8 {
    return sqlite.sqlite3_sourceid();
}

pub const QuerySession = struct {
    database: db.Db = .{},
    statement: ?*sqlite.sqlite3_stmt = null,
    opened: bool = false,

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
            switch (kind) {
                .baseline => stderr.print("error: --bind: {s}\n", .{detail}) catch {},
                .variant => stderr.print("error: --bind on the variant: {s}\n", .{detail}) catch {},
            }
            failure.* = .rejected;
            return false;
        };
        return true;
    }

    pub fn finalize(self: *QuerySession) void {
        if (self.statement) |statement| {
            _ = sqlite.sqlite3_finalize(statement);
            self.statement = null;
        }
    }

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

    pub fn deinit(self: *QuerySession, kind: Kind, stderr: *Io.Writer, cleanup_failed: *bool) void {
        self.finalize();
        self.close(kind, stderr, cleanup_failed);
    }

    pub fn checkCreateIndex(self: *QuerySession, sql: [:0]const u8, stderr: *Io.Writer) bool {
        self.database.checkCreateIndex(sql) catch |err| {
            reportCheckFailure(stderr, "--index-sql", err, &self.database);
            return false;
        };
        return true;
    }

    pub fn clues(self: *const QuerySession) db.Clues {
        return self.database.clues;
    }

    pub fn counters(self: *const QuerySession) db.Counters {
        return db.statementCounters(self.statement.?);
    }

    pub fn columnCount(self: *const QuerySession) c_int {
        return sqlite.sqlite3_column_count(self.statement.?);
    }

    pub fn message(self: *const QuerySession) []const u8 {
        return self.database.message();
    }

    pub fn reset(self: *QuerySession) void {
        _ = sqlite.sqlite3_reset(self.statement.?);
    }

    pub fn step(self: *QuerySession, control: *db.StepControl) db.StepError!u64 {
        return self.database.stepAll(self.statement.?, control, null);
    }

    pub fn run(self: *QuerySession, control: *db.StepControl, rows_out: ?*result.RowCollector) db.StepError!u64 {
        return self.database.stepAll(self.statement.?, control, rows_out);
    }

    pub fn firstRowInt64(self: *QuerySession) db.StepError!?i64 {
        self.reset();
        const rc = sqlite.sqlite3_step(self.statement.?);
        if (rc == sqlite.SQLITE_DONE) return null;
        if (rc != sqlite.SQLITE_ROW) return error.StepFailed;
        return sqlite.sqlite3_column_int64(self.statement.?, 0);
    }

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

fn reportSelectFailure(stderr: *Io.Writer, err: db.CheckError, database: *db.Db, index_sql: [:0]const u8) void {
    const prefix = "no such index: ";
    if (err == error.StatementInvalid and database.errorCode() != sqlite.SQLITE_OK) {
        const message = database.message();
        var saved: [512]u8 = undefined;
        if (std.mem.startsWith(u8, message, prefix) and message.len <= saved.len) {
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

const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

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
    try testing.expectEqual(@as(?i64, 1), try session.firstRowInt64());
    session.reset();
    try testing.expectEqual(@as(u64, 1), try session.run(&control, null));
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
}

test "a timeout on the variant names the variant and is not a comparison" {
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

    try testing.expect(session.statement != null);
    session.deinit(.baseline, &stderr, &cleanup_failed);
    try testing.expect(session.statement == null);
    try testing.expect(!session.opened);
    try testing.expect(!cleanup_failed);
}
