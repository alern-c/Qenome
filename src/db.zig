//! Read-only database access and the SQL input contract.
//!
//! A connection is opened with `SQLITE_OPEN_READONLY` only, and every user
//! statement is checked behind a deny-by-default authorizer. The allowlists
//! below are measured from the engine itself; the test "authorizer logs only
//! allowlisted actions for select and ddl" pins the actions that the vendored
//! release reports, so a new action cannot pass unnoticed.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sqlite = @import("sqlite.zig");

/// Which actions the authorizer accepts.
///
/// * `internal`: only the fixed statements this module runs itself.
/// * `user_select`: the read-only actions a SELECT needs.
/// * `user_ddl`: `CREATE INDEX` and the actions preparing it reports.
pub const Mode = enum { internal, user_select, user_ddl };

pub const OpenError = error{
    OpenFailed,
    NotReadOnlyConnection,
    GuardSetupFailed,
};

pub const CloseError = error{CloseFailed};

pub const StepError = error{
    StepFailed,
    /// The time limit expired while the statement was running.
    Timeout,
    /// The cancel flag was set (SIGINT) while the statement was running.
    Interrupted,
};

/// Why the progress handler stopped a statement before it finished.
pub const InterruptReason = enum { timeout, signal };

/// Interruption state for `stepAll`.
///
/// `stepAll` installs a progress handler that reads this value, so the control
/// must stay alive until the call returns. The callback runs on the stepping
/// thread and never calls a SQLite API; the SIGINT handler only writes the
/// atomic `cancel` flag, which is the one field it may touch.
pub const StepControl = struct {
    io: Io,
    /// Time limit in milliseconds. `0` disables the limit, as `--timeout-ms 0`
    /// does.
    timeout_ms: u64,
    /// Set by the CLI's SIGINT handler, or by a test.
    cancel: *const std.atomic.Value(bool),
    /// Why the last `stepAll` was interrupted, or null when it was not.
    reason: ?InterruptReason = null,
    /// Absolute deadline on the `awake` clock. `stepAll` fills this in from
    /// `timeout_ms` when it starts, because the limit covers the execution and
    /// not the prepare or bind phases.
    deadline_ns: ?i96 = null,

    pub fn init(io: Io, timeout_ms: u64, cancel: *const std.atomic.Value(bool)) StepControl {
        return .{ .io = io, .timeout_ms = timeout_ms, .cancel = cancel };
    }

    fn shouldStop(self: *StepControl) bool {
        // A signal is the user's own request, so it wins over the deadline.
        if (self.cancel.load(.monotonic)) {
            self.reason = .signal;
            return true;
        }
        if (self.deadline_ns) |deadline| {
            if (Io.Clock.now(.awake, self.io).nanoseconds >= deadline) {
                self.reason = .timeout;
                return true;
            }
        }
        return false;
    }
};

/// Approximate VM instructions between progress callbacks. Small enough that a
/// heavy SELECT notices a deadline or a signal within a few milliseconds.
const progress_opcodes: c_int = 1000;

pub const CheckError = error{
    /// The input holds no statement (empty, whitespace, or comments only).
    EmptyStatement,
    /// More than one statement was found.
    MultipleStatements,
    /// The authorizer denied an action that the mode does not allow.
    StatementRejected,
    /// SQLite could not prepare the statement (syntax, unknown table or column,
    /// an index name that already exists).
    StatementInvalid,
    /// A read-only SELECT was expected but `sqlite3_stmt_readonly` disagreed.
    StatementNotReadOnly,
    /// A CREATE INDEX was expected but the authorizer never reported one, or
    /// `sqlite3_stmt_readonly` disagreed.
    StatementNotCreateIndex,
};

/// Actions recorded per check. The list only feeds diagnostics: tests read it
/// to pin the allowlists, and it never affects the accept/deny decision.
const max_observed_actions = 64;

/// A read-only connection.
///
/// `openReadOnly` hands SQLite a pointer to this value for the authorizer, so
/// the instance must not move while the connection is open. Declare it in the
/// caller and pass `&db` (`var db: Db = .{}; try db.openReadOnly(path);`).
pub const Db = struct {
    handle: ?*sqlite.sqlite3 = null,
    mode: Mode = .internal,
    seen_create_index: bool = false,
    observed: [max_observed_actions]c_int = @splat(0),
    observed_count: usize = 0,

    /// Opens `path` read-only and arms the guards. See the note on `Db` about
    /// the address of the instance.
    pub fn openReadOnly(self: *Db, path: [:0]const u8) OpenError!void {
        var handle: ?*sqlite.sqlite3 = null;
        const rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READONLY, null);
        const conn = handle orelse return error.OpenFailed;
        if (rc != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(conn);
            return error.OpenFailed;
        }
        self.* = .{ .handle = conn };
        errdefer {
            _ = sqlite.sqlite3_close(conn);
            self.* = .{};
        }

        // Fail closed: a connection that can write is not usable here.
        if (sqlite.sqlite3_db_readonly(conn, "main") != 1) return error.NotReadOnlyConnection;

        // SQLite accepts double-quoted string literals by default, so a
        // mistyped identifier such as `CREATE INDEX i ON t("nope")` would
        // prepare as a constant expression instead of failing. Turn that off
        // for DDL and DML; a setting that cannot be applied is fatal.
        if (sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_DQS_DDL, @as(c_int, 0), @as(?*c_int, null)) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
        if (sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_DQS_DML, @as(c_int, 0), @as(?*c_int, null)) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }

        // The authorizer keeps the connection in `internal` mode between
        // checks. Its third argument is the address of this instance.
        if (sqlite.sqlite3_set_authorizer(conn, authorizer, self) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
        // A second barrier behind the read-only open. It does not replace the
        // authorizer: a prepared CREATE INDEX stays writable until it is
        // rejected at prepare time.
        if (sqlite.sqlite3_exec(conn, "PRAGMA query_only=1", null, null, null) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
    }

    /// Closes the connection. On failure the handle stays open so that the
    /// caller can report it; statements must be finalized first.
    pub fn close(self: *Db) CloseError!void {
        const conn = self.handle orelse return;
        if (sqlite.sqlite3_close(conn) != sqlite.SQLITE_OK) return error.CloseFailed;
        self.* = .{};
    }

    /// Accepts exactly one read-only SELECT and returns the prepared statement
    /// so that the caller can bind and step it. The caller owns the statement
    /// and must finalize it.
    pub fn prepareSelect(self: *Db, sql: [:0]const u8) CheckError!*sqlite.sqlite3_stmt {
        const previous = self.enterMode(.user_select);
        defer self.mode = previous;

        const statement = (try self.prepareSingle(sql)) orelse return error.EmptyStatement;
        errdefer _ = sqlite.sqlite3_finalize(statement);

        if (sqlite.sqlite3_stmt_readonly(statement) != 1) return error.StatementNotReadOnly;
        return statement;
    }

    /// Accepts exactly one read-only SELECT and discards the statement.
    pub fn checkSelect(self: *Db, sql: [:0]const u8) CheckError!void {
        const statement = try self.prepareSelect(sql);
        _ = sqlite.sqlite3_finalize(statement);
    }

    /// Accepts exactly one CREATE INDEX that SQLite can prepare. The statement
    /// is never stepped, so the index is not created.
    pub fn checkCreateIndex(self: *Db, sql: [:0]const u8) CheckError!void {
        const previous = self.enterMode(.user_ddl);
        defer self.mode = previous;

        const statement = (try self.prepareSingle(sql)) orelse return error.EmptyStatement;
        defer _ = sqlite.sqlite3_finalize(statement);

        if (!self.seen_create_index) return error.StatementNotCreateIndex;
        // Double check for a statement that is writable although the authorizer
        // saw a CREATE INDEX. The pinned release reports 0 for every CREATE
        // INDEX that reaches this point, so this is a guard for engine changes.
        if (sqlite.sqlite3_stmt_readonly(statement) != 0) return error.StatementNotCreateIndex;
    }

    /// Steps `statement` to completion and returns the number of rows.
    ///
    /// The select allowlist stays active for the whole loop: with bound values
    /// in place SQLite can re-prepare the statement on its first step (a `LIKE`
    /// on an indexed column decides its plan from the bound value, for
    /// example), and that re-prepare runs the authorizer again.
    ///
    /// A progress handler checks `control` every `progress_opcodes`
    /// instructions: the time limit starts here, and the cancel flag arrives
    /// from the CLI's SIGINT handler. The handler itself never calls a SQLite
    /// API.
    pub fn stepAll(self: *Db, statement: *sqlite.sqlite3_stmt, control: *StepControl) StepError!u64 {
        const previous = self.enterMode(.user_select);
        defer self.mode = previous;

        control.reason = null;
        const start = Io.Clock.now(.awake, control.io).nanoseconds;
        control.deadline_ns = if (control.timeout_ms == 0) null else start + @as(i96, @intCast(control.timeout_ms)) * std.time.ns_per_ms;

        // The callback reads `control`, so the handler must be gone again
        // before the control goes out of scope.
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);

        var rows: u64 = 0;
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => rows += 1,
                sqlite.SQLITE_DONE => return rows,
                else => |rc| {
                    // Only an interruption becomes a timeout or signal report;
                    // every other failure keeps its engine message.
                    if (rc == sqlite.SQLITE_INTERRUPT) {
                        if (control.reason) |reason| return switch (reason) {
                            .timeout => error.Timeout,
                            .signal => error.Interrupted,
                        };
                    }
                    return error.StepFailed;
                },
            }
        }
    }

    /// Message SQLite reported for the connection.
    pub fn message(self: *const Db) []const u8 {
        return std.mem.span(sqlite.sqlite3_errmsg(self.connection()));
    }

    /// Result code of the last failed call, or `SQLITE_OK` when the engine has
    /// not reported an error (for example after a rejection that our own final
    /// checks decided, such as an empty statement).
    pub fn errorCode(self: *const Db) c_int {
        return sqlite.sqlite3_errcode(self.connection());
    }

    /// Action codes the authorizer saw during the current check, in order.
    pub fn observedActions(self: *const Db) []const c_int {
        return self.observed[0..self.observed_count];
    }

    fn connection(self: *const Db) *sqlite.sqlite3 {
        return self.handle orelse unreachable;
    }

    /// Prepares exactly one statement under the current mode. Returns null when
    /// the input holds no statement at all.
    fn prepareSingle(self: *Db, sql: [:0]const u8) CheckError!?*sqlite.sqlite3_stmt {
        var statement: ?*sqlite.sqlite3_stmt = null;
        var tail: ?[*:0]const u8 = null;
        const rc = sqlite.sqlite3_prepare_v2(self.connection(), sql.ptr, -1, &statement, &tail);
        if (rc != sqlite.SQLITE_OK) {
            return if (rc == sqlite.SQLITE_AUTH) error.StatementRejected else error.StatementInvalid;
        }
        const first = statement orelse return null;
        errdefer _ = sqlite.sqlite3_finalize(first);

        // EXPLAIN and EXPLAIN QUERY PLAN describe a statement instead of
        // running it, and neither input contract accepts them.
        if (sqlite.sqlite3_stmt_isexplain(first) != 0) return error.StatementRejected;

        // Prepare the tail so that comments, whitespace, and trailing
        // semicolons stay acceptable while a real second statement does not.
        if (tail) |rest| {
            var extra: ?*sqlite.sqlite3_stmt = null;
            var extra_tail: ?[*:0]const u8 = null;
            const extra_rc = sqlite.sqlite3_prepare_v2(self.connection(), rest, -1, &extra, &extra_tail);
            if (extra) |second| {
                _ = sqlite.sqlite3_finalize(second);
                return error.MultipleStatements;
            }
            // The tail can also fail to prepare, for example on a syntax error
            // in the second statement; either way there is more than one.
            if (extra_rc != sqlite.SQLITE_OK) return error.MultipleStatements;
        }
        return first;
    }

    fn enterMode(self: *Db, mode: Mode) Mode {
        const previous = self.mode;
        self.mode = mode;
        self.seen_create_index = false;
        self.observed_count = 0;
        return previous;
    }

    fn record(self: *Db, action_code: c_int) void {
        if (self.observed_count == self.observed.len) return;
        self.observed[self.observed_count] = action_code;
        self.observed_count += 1;
    }

    fn allows(self: *Db, action_code: c_int, arg1: ?[*:0]const u8, arg3: ?[*:0]const u8) bool {
        switch (self.mode) {
            .internal => return action_code == sqlite.SQLITE_PRAGMA,
            .user_select => return switch (action_code) {
                sqlite.SQLITE_SELECT,
                sqlite.SQLITE_READ,
                sqlite.SQLITE_FUNCTION,
                sqlite.SQLITE_RECURSIVE,
                => true,
                else => false,
            },
            .user_ddl => switch (action_code) {
                // Preparing "CREATE INDEX" also reports the schema write and a
                // REINDEX of the new index. They are accepted only once the
                // engine has confirmed the CREATE INDEX itself.
                sqlite.SQLITE_CREATE_INDEX => {
                    self.seen_create_index = true;
                    return true;
                },
                sqlite.SQLITE_READ, sqlite.SQLITE_FUNCTION => return true,
                sqlite.SQLITE_INSERT => return isSchemaTable(arg1) and isMainSchema(arg3),
                sqlite.SQLITE_REINDEX => return self.seen_create_index,
                else => return false,
            },
        }
    }
};

/// A typed value for one positional parameter.
pub const BindValue = union(enum) {
    int: i64,
    real: f64,
    /// Borrowed for the call only; SQLite receives a copy because the bind uses
    /// `SQLITE_TRANSIENT`.
    text: []const u8,
    null,
};

/// One `--bind` entry: a 1-based parameter number and the value for it.
pub const BindArg = struct {
    number: u64,
    value: BindValue,
};

pub const BindError = error{
    /// More values were given than the statement has parameters, including any
    /// value for a statement without parameters.
    ParameterCountMismatch,
    /// A number is 0 or larger than the parameter count.
    BindNumberOutOfRange,
    /// The same number was given more than once.
    DuplicateBindNumber,
    /// A number between 1 and the parameter count has no value.
    MissingBindNumber,
    /// SQLite refused one of the bind calls.
    BindFailed,
};

/// Binds every value to its parameter.
///
/// All numbers `1..parameter_count` must be given exactly once, so a statement
/// that only uses `?3` still needs values for 1, 2 and 3 (D-104=案1). Numbers
/// that the SQL never uses are bound as well; they are simply unreachable.
pub fn bindAll(statement: *sqlite.sqlite3_stmt, binds: []const BindArg) BindError!void {
    const count: u32 = @intCast(sqlite.sqlite3_bind_parameter_count(statement));
    std.debug.assert(count <= sqlite.max_parameter_number);

    // More values than parameters cannot happen while every number is valid,
    // so this is the only "parameter count" complaint needed.
    if (binds.len > count) return error.ParameterCountMismatch;

    var seen: std.StaticBitSet(sqlite.max_parameter_number) = .empty;
    for (binds) |bind| {
        if (bind.number == 0 or bind.number > count) return error.BindNumberOutOfRange;
        const position: usize = @intCast(bind.number - 1);
        if (seen.isSet(position)) return error.DuplicateBindNumber;
        seen.set(position);
    }
    if (binds.len != count) return error.MissingBindNumber;

    for (binds) |bind| {
        const index: c_int = @intCast(bind.number);
        const rc = switch (bind.value) {
            .int => |value| sqlite.sqlite3_bind_int64(statement, index, value),
            .real => |value| sqlite.sqlite3_bind_double(statement, index, value),
            .text => |value| sqlite.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), sqlite.SQLITE_TRANSIENT),
            .null => sqlite.sqlite3_bind_null(statement, index),
        };
        if (rc != sqlite.SQLITE_OK) return error.BindFailed;
    }
}

fn isSchemaTable(name: ?[*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(name orelse return false), "sqlite_master");
}

fn isMainSchema(name: ?[*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(name orelse return false), "main");
}

fn authorizer(
    user_data: ?*anyopaque,
    action_code: c_int,
    arg1: ?[*:0]const u8,
    arg2: ?[*:0]const u8,
    arg3: ?[*:0]const u8,
    arg4: ?[*:0]const u8,
) callconv(.c) c_int {
    _ = arg2;
    _ = arg4;
    const self: *Db = @ptrCast(@alignCast(user_data orelse return sqlite.SQLITE_DENY));
    self.record(action_code);
    return if (self.allows(action_code, arg1, arg3)) sqlite.SQLITE_OK else sqlite.SQLITE_DENY;
}

/// Progress callback installed around `sqlite3_step`. A non-zero return makes
/// the step fail with `SQLITE_INTERRUPT`.
fn progressHandler(user_data: ?*anyopaque) callconv(.c) c_int {
    const control: *StepControl = @ptrCast(@alignCast(user_data orelse return 1));
    return if (control.shouldStop()) 1 else 0;
}

const testing = std.testing;

/// Schema used by the checks below. `existing_idx` makes the "index name
/// already exists" case reachable.
const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
    \\CREATE INDEX existing_idx ON t(a);
;

/// A temporary directory holding one SQLite database file.
const Fixture = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        return initWithSchema(allocator, fixture_schema);
    }

    fn initWithSchema(allocator: std.mem.Allocator, schema: [:0]const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // Create the file first so that its path can be resolved for the C API.
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "fixture.db", .data = "" });
        const path = try tmp.dir.realPathFileAlloc(testing.io, "fixture.db", allocator);
        errdefer allocator.free(path);
        try createTestDatabase(path, schema);
        return .{ .tmp = tmp, .path = path, .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

/// Test-only helper that creates a database file at `path` and runs `schema`.
/// Production code only ever opens with `SQLITE_OPEN_READONLY`; this function
/// exists so that tests can build fixture databases without the `sqlite3` CLI.
/// `SQLITE_OPEN_READWRITE` appears here and nowhere else.
pub fn createTestDatabase(path: [:0]const u8, schema: [:0]const u8) !void {
    comptime std.debug.assert(builtin.is_test);
    var handle: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, null) != sqlite.SQLITE_OK) {
        return error.TestFixtureFailed;
    }
    const connection = handle orelse return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_close(connection);
    if (sqlite.sqlite3_exec(connection, schema, null, null, null) != sqlite.SQLITE_OK) {
        return error.TestFixtureFailed;
    }
}

/// Test-only helper: runs one scalar query through the select allowlist.
fn queryInt(db: *Db, sql: [:0]const u8) !i64 {
    const previous = db.enterMode(.user_select);
    defer db.mode = previous;

    const statement = (try db.prepareSingle(sql)) orelse return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_finalize(statement);
    return switch (sqlite.sqlite3_step(statement)) {
        sqlite.SQLITE_ROW => sqlite.sqlite3_column_int64(statement, 0),
        else => error.TestFixtureFailed,
    };
}

test "read-only connection reports db_readonly==1" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try testing.expectEqual(@as(c_int, 1), sqlite.sqlite3_db_readonly(db.handle, "main"));
}

test "single statement select is accepted" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try db.checkSelect("SELECT 1");
    try db.checkSelect("SELECT count(abs(a)) FROM t WHERE b IS NOT NULL");
    try db.checkSelect("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) SELECT count(*) FROM c");
    try db.checkSelect("SELECT 1; -- a trailing comment is not a second statement");
    try db.checkSelect("SELECT 1;;");
    try db.checkSelect("SELECT \"a\" FROM t");

    // A check must leave the connection guarded again.
    try testing.expectEqual(Mode.internal, db.mode);
}

test "multiple statements are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try testing.expectError(error.MultipleStatements, db.checkSelect("SELECT 1; SELECT 2"));
    try testing.expectError(error.MultipleStatements, db.checkSelect("SELECT 1; INSERT INTO t VALUES (4, 'w')"));
    try testing.expectError(error.MultipleStatements, db.checkSelect("SELECT 1; nonsense"));
    try testing.expectError(error.MultipleStatements, db.checkCreateIndex("CREATE INDEX idx_multi ON t(a); DROP TABLE t"));
}

test "empty or comment-only input is rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try testing.expectError(error.EmptyStatement, db.checkSelect(""));
    try testing.expectError(error.EmptyStatement, db.checkSelect("  \n\t "));
    try testing.expectError(error.EmptyStatement, db.checkSelect("-- nothing to run\n"));
    try testing.expectError(error.EmptyStatement, db.checkSelect("/* nothing to run */"));
    try testing.expectError(error.EmptyStatement, db.checkSelect(";"));
    try testing.expectError(error.EmptyStatement, db.checkCreateIndex(""));
}

test "write statements are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const writes = [_][:0]const u8{
        "INSERT INTO t VALUES (4, 'w')",
        "INSERT INTO t SELECT a, b FROM t",
        "UPDATE t SET a = 9",
        "DELETE FROM t",
        "CREATE TABLE u(x)",
        "DROP TABLE t",
        "DROP INDEX existing_idx",
        "ALTER TABLE t RENAME TO z",
        "REINDEX",
        "ANALYZE",
        "CREATE VIEW v AS SELECT a FROM t",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END",
        "CREATE INDEX idx_select_slot ON t(a)",
    };
    for (writes) |sql| try testing.expectError(error.StatementRejected, db.checkSelect(sql));
}

test "non-select read-only statements are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statements = [_][:0]const u8{
        "PRAGMA table_info(t)",
        "PRAGMA query_only",
        "ATTACH DATABASE 'other.db' AS other",
        "DETACH DATABASE other",
        "BEGIN",
        "COMMIT",
        "SAVEPOINT s1",
    };
    for (statements) |sql| try testing.expectError(error.StatementRejected, db.checkSelect(sql));
}

test "candidate create index is validated without being applied" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try db.checkCreateIndex("CREATE INDEX idx_new ON t(a)");
    try testing.expectEqual(
        @as(i64, 0),
        try queryInt(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_new'"),
    );
    // Repeating the check only succeeds while the index is still absent.
    try db.checkCreateIndex("CREATE INDEX idx_new ON t(a)");
    try db.checkCreateIndex("CREATE UNIQUE INDEX idx_unique ON t(abs(a)) WHERE b IS NOT NULL");
    try testing.expectEqual(
        @as(i64, 0),
        try queryInt(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_unique'"),
    );
    try testing.expectEqual(Mode.internal, db.mode);
}

test "candidate create index with an existing name is rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX existing_idx ON t(a)"));
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE UNIQUE INDEX existing_idx ON t(b)"));
    // "IF NOT EXISTS" with an existing name prepares without reporting
    // SQLITE_CREATE_INDEX, so the authorizer evidence is what rejects it.
    try testing.expectError(
        error.StatementNotCreateIndex,
        db.checkCreateIndex("CREATE INDEX IF NOT EXISTS existing_idx ON t(b)"),
    );
}

test "double quoted unknown columns are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    // SQLite's double-quoted string literals would turn these into constants.
    try testing.expectError(error.StatementInvalid, db.checkSelect("SELECT \"nope\" FROM t"));
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX idx_dqs ON t(\"nope\")"));
    // Real columns and single-quoted literals keep working.
    try db.checkSelect("SELECT \"a\" FROM t");
    try db.checkSelect("SELECT 'nope' FROM t");
}

test "explain statements are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    // EXPLAIN only describes a statement; the contract wants the statement.
    try testing.expectError(error.StatementRejected, db.checkSelect("EXPLAIN SELECT 1"));
    try testing.expectError(error.StatementRejected, db.checkSelect("EXPLAIN QUERY PLAN SELECT * FROM t"));
    try testing.expectError(error.StatementRejected, db.checkCreateIndex("EXPLAIN CREATE INDEX idx_explain ON t(a)"));
    try testing.expectError(
        error.StatementRejected,
        db.checkCreateIndex("EXPLAIN QUERY PLAN CREATE INDEX idx_explain ON t(a)"),
    );
    try testing.expectEqual(
        @as(i64, 0),
        try queryInt(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_explain'"),
    );
}

test "final authorizer checks reject statements without the expected evidence" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    // VACUUM prepares without reporting an authorizer action and is not
    // read-only, so only the double checks can reject it.
    try testing.expectError(error.StatementNotReadOnly, db.checkSelect("VACUUM"));
    try testing.expectError(error.StatementNotCreateIndex, db.checkCreateIndex("VACUUM"));
}

test "a failed open leaves the connection closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "missing.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "missing.db", testing.allocator);
    defer testing.allocator.free(path);
    try tmp.dir.deleteFile(testing.io, "missing.db");

    var db: Db = .{};
    try testing.expectError(error.OpenFailed, db.openReadOnly(path));
    try testing.expect(db.handle == null);
}

test "a failed close keeps the connection for the caller" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);

    // `sqlite3_close` reports SQLITE_BUSY while a statement is unfinalized, and
    // the handle has to stay usable so that the caller can report it.
    const statement = (try db.prepareSingle("PRAGMA query_only")) orelse return error.TestFixtureFailed;
    try testing.expectError(error.CloseFailed, db.close());
    try testing.expect(db.handle != null);
    _ = sqlite.sqlite3_finalize(statement);
    try db.close();
    try testing.expect(db.handle == null);
}

test "candidate ddl that is not create index is rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statements = [_][:0]const u8{
        "SELECT 1",
        "VALUES(1)",
        "CREATE TABLE u(x)",
        "DROP INDEX existing_idx",
        "DROP TABLE t",
        "ALTER TABLE t RENAME TO z",
        "REINDEX",
        "REINDEX existing_idx",
        "ANALYZE",
        "CREATE VIEW v AS SELECT a FROM t",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END",
        "INSERT INTO t VALUES (4, 'w')",
        "PRAGMA table_info(t)",
        "ATTACH DATABASE 'other.db' AS other",
        "BEGIN",
    };
    for (statements) |sql| try testing.expectError(error.StatementRejected, db.checkCreateIndex(sql));

    // The only write action the DDL mode allows is SQLite's own schema write,
    // and SQLite refuses that statement before the final check can run.
    try testing.expectError(
        error.StatementInvalid,
        db.checkCreateIndex("INSERT INTO sqlite_master VALUES (1, 2, 3, 4, 5)"),
    );
}

test "candidate create index on unknown table or column is rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX idx_missing ON nope(a)"));
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX idx_badcol ON t(nope)"));
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX idx_syntax ON t("));
}

test "authorizer logs only allowlisted actions for select and ddl" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try db.checkSelect("SELECT count(abs(a)) FROM t");
    const select_actions = db.observedActions();
    try testing.expect(select_actions.len > 0);
    for (select_actions, 0..) |action_code, index| {
        const allowed = switch (action_code) {
            sqlite.SQLITE_SELECT, sqlite.SQLITE_READ, sqlite.SQLITE_FUNCTION, sqlite.SQLITE_RECURSIVE => true,
            else => false,
        };
        if (!allowed) std.debug.print("select action {d} at index {d} is not allowlisted\n", .{ action_code, index });
        try testing.expect(allowed);
    }

    try db.checkCreateIndex("CREATE INDEX idx_log ON t(abs(a))");
    const ddl_actions = db.observedActions();
    try testing.expect(ddl_actions.len > 0);
    var saw_create_index = false;
    for (ddl_actions) |action_code| {
        if (action_code == sqlite.SQLITE_CREATE_INDEX) saw_create_index = true;
        const allowed = switch (action_code) {
            sqlite.SQLITE_CREATE_INDEX,
            sqlite.SQLITE_READ,
            sqlite.SQLITE_FUNCTION,
            sqlite.SQLITE_INSERT,
            sqlite.SQLITE_REINDEX,
            => true,
            else => false,
        };
        if (!allowed) std.debug.print("ddl action {d} is not allowlisted\n", .{action_code});
        try testing.expect(allowed);
    }
    try testing.expect(saw_create_index);

    // A denial is visible as an action outside the select allowlist, and every
    // check starts a fresh list.
    try testing.expectError(error.StatementRejected, db.checkSelect("INSERT INTO t VALUES (4, 'w')"));
    try testing.expectEqualSlices(c_int, &.{sqlite.SQLITE_INSERT}, db.observedActions());
    try db.checkSelect("SELECT 1");
    try testing.expectEqualSlices(c_int, &.{sqlite.SQLITE_SELECT}, db.observedActions());
}

test "stepping a candidate create index fails with SQLITE_READONLY" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const previous = db.enterMode(.user_ddl);
    defer db.mode = previous;

    const statement = (try db.prepareSingle("CREATE INDEX idx_step ON t(a)")) orelse
        return error.TestFixtureFailed;
    try testing.expectEqual(@as(c_int, 0), sqlite.sqlite3_stmt_readonly(statement));
    try testing.expectEqual(sqlite.SQLITE_READONLY, sqlite.sqlite3_step(statement));
    _ = sqlite.sqlite3_finalize(statement);

    try testing.expectEqual(
        @as(i64, 0),
        try queryInt(&db, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_step'"),
    );
}

/// Test-only helper: prepares a checked SELECT and binds `binds` to it.
fn prepareBoundSelect(db: *Db, sql: [:0]const u8, binds: []const BindArg) !*sqlite.sqlite3_stmt {
    const statement = try db.prepareSelect(sql);
    errdefer _ = sqlite.sqlite3_finalize(statement);
    try bindAll(statement, binds);
    return statement;
}

/// Test-only helper: text of a column of the current row.
fn columnText(statement: *sqlite.sqlite3_stmt, column: c_int) []const u8 {
    return std.mem.span(sqlite.sqlite3_column_text(statement, column) orelse return "");
}

test "typed binds keep their declared type" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(
        &db,
        "SELECT typeof(?1), typeof(?2), typeof(?3), typeof(?4), ?1, ?2, ?3, ?4 IS NULL",
        &.{
            .{ .number = 1, .value = .{ .int = 1234 } },
            .{ .number = 2, .value = .{ .real = 2.5 } },
            .{ .number = 3, .value = .{ .text = "ok" } },
            .{ .number = 4, .value = .null },
        },
    );
    defer _ = sqlite.sqlite3_finalize(statement);

    try testing.expectEqual(@as(c_int, sqlite.SQLITE_ROW), sqlite.sqlite3_step(statement));
    try testing.expectEqualStrings("integer", columnText(statement, 0));
    try testing.expectEqualStrings("real", columnText(statement, 1));
    try testing.expectEqualStrings("text", columnText(statement, 2));
    try testing.expectEqualStrings("null", columnText(statement, 3));
    try testing.expectEqual(@as(i64, 1234), sqlite.sqlite3_column_int64(statement, 4));
    try testing.expectEqual(@as(f64, 2.5), sqlite.sqlite3_column_double(statement, 5));
    try testing.expectEqualStrings("ok", columnText(statement, 6));
    try testing.expectEqual(@as(i64, 1), sqlite.sqlite3_column_int64(statement, 7));
}

test "duplicate or out-of-range bind numbers are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try db.prepareSelect("SELECT ?1, ?2");
    defer _ = sqlite.sqlite3_finalize(statement);

    try testing.expectError(
        error.DuplicateBindNumber,
        bindAll(statement, &.{ .{ .number = 1, .value = .null }, .{ .number = 1, .value = .null } }),
    );
    try testing.expectError(
        error.BindNumberOutOfRange,
        bindAll(statement, &.{.{ .number = 0, .value = .null }}),
    );
    try testing.expectError(
        error.BindNumberOutOfRange,
        bindAll(statement, &.{.{ .number = 3, .value = .null }}),
    );
}

test "bind numbers must cover 1..parameter_count" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try db.prepareSelect("SELECT ?3");
    defer _ = sqlite.sqlite3_finalize(statement);

    try testing.expectError(
        error.MissingBindNumber,
        bindAll(statement, &.{.{ .number = 3, .value = .null }}),
    );
    try testing.expectError(
        error.MissingBindNumber,
        bindAll(statement, &.{
            .{ .number = 1, .value = .null },
            .{ .number = 3, .value = .null },
        }),
    );

    // D-104=案1: the numbers 1 and 2 are unused by the SQL but still required.
    try bindAll(statement, &.{
        .{ .number = 1, .value = .{ .int = 10 } },
        .{ .number = 2, .value = .{ .int = 20 } },
        .{ .number = 3, .value = .{ .int = 30 } },
    });
    try testing.expectEqual(@as(c_int, sqlite.SQLITE_ROW), sqlite.sqlite3_step(statement));
    try testing.expectEqual(@as(i64, 30), sqlite.sqlite3_column_int64(statement, 0));
}

test "parameter count mismatch is rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const no_parameters = try db.prepareSelect("SELECT 1");
    defer _ = sqlite.sqlite3_finalize(no_parameters);
    try bindAll(no_parameters, &.{});
    try testing.expectError(
        error.ParameterCountMismatch,
        bindAll(no_parameters, &.{.{ .number = 1, .value = .null }}),
    );

    const one_parameter = try db.prepareSelect("SELECT ?1");
    defer _ = sqlite.sqlite3_finalize(one_parameter);
    try testing.expectError(
        error.ParameterCountMismatch,
        bindAll(one_parameter, &.{
            .{ .number = 1, .value = .null },
            .{ .number = 2, .value = .null },
        }),
    );
}

test "the vendored parameter limit matches the pinned bound" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    // `bindAll` asserts this bound, so the constant and the engine must agree.
    try testing.expectEqual(
        @as(c_int, @intCast(sqlite.max_parameter_number)),
        sqlite.sqlite3_limit(db.handle, sqlite.SQLITE_LIMIT_VARIABLE_NUMBER, -1),
    );
}

test "stepping a select that SQLite re-prepares keeps working" {
    // `LIKE` on an indexed column makes SQLite re-prepare the statement on the
    // first step, once the bound parameter is known. The re-prepare runs the
    // authorizer again, so the select allowlist must still be active then.
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
        \\CREATE INDEX idx_b ON t(b);
    );
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, "SELECT b FROM t WHERE b LIKE ?1", &.{
        .{ .number = 1, .value = .{ .text = "x%" } },
    });
    defer _ = sqlite.sqlite3_finalize(statement);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control));
    try testing.expectEqual(Mode.internal, db.mode);
}

/// A statement that needs far longer than any test time limit, so the progress
/// handler is what ends it.
const heavy_select: [:0]const u8 =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c";

/// A bounded statement that still crosses many progress intervals, but finishes
/// in milliseconds.
const bounded_select: [:0]const u8 =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200000) SELECT count(*) FROM c";

test "time limit interrupts a heavy select (timeout)" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, heavy_select, &.{});
    defer _ = sqlite.sqlite3_finalize(statement);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 1, &cancel);
    try testing.expectError(error.Timeout, db.stepAll(statement, &control));
    try testing.expectEqual(InterruptReason.timeout, control.reason.?);

    // The progress handler must be uninstalled when `stepAll` returns, because
    // `control` lives on this stack frame. With the cancel flag set, a direct
    // step of a fresh statement only runs to completion when no handler is
    // left to read the stale control.
    cancel.store(true, .monotonic);
    const probe = try prepareBoundSelect(&db, bounded_select, &.{});
    defer _ = sqlite.sqlite3_finalize(probe);
    try testing.expectEqual(sqlite.SQLITE_ROW, sqlite.sqlite3_step(probe));
}

test "a heavy select inside the time limit finishes (positive control)" {
    // The deadline comparison is load-bearing in both directions: with an
    // inverted test the first progress callback would interrupt every
    // statement that has a time limit at all. This pins the direction.
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, bounded_select, &.{});
    defer _ = sqlite.sqlite3_finalize(statement);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 60_000, &cancel);
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control));
    try testing.expect(control.reason == null);
}

test "cancel flag interrupts a heavy select (signal)" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, heavy_select, &.{});
    defer _ = sqlite.sqlite3_finalize(statement);

    var cancel = std.atomic.Value(bool).init(true);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.Interrupted, db.stepAll(statement, &control));
    try testing.expectEqual(InterruptReason.signal, control.reason.?);
    try testing.expectEqual(Mode.internal, db.mode);
}

test "source db bytes are unchanged and no journal files appear" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    const before = try fixture.tmp.dir.readFileAlloc(testing.io, "fixture.db", testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    const statement = try prepareBoundSelect(&db, "SELECT count(*) FROM t WHERE a = ?1", &.{
        .{ .number = 1, .value = .{ .int = 1 } },
    });

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control));
    // `sqlite3_close` refuses to close while a statement is open, so the
    // finalize-before-close order is part of the D-105 contract.
    _ = sqlite.sqlite3_finalize(statement);
    try db.checkCreateIndex("CREATE INDEX idx_after ON t(a)");
    try db.close();

    const after = try fixture.tmp.dir.readFileAlloc(testing.io, "fixture.db", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-journal", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-wal", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-shm", .{}));
}
