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

pub const SnapshotError = error{
    /// Another connection holds a lock that the copy needs (`SQLITE_BUSY`),
    /// for example a writer inside `BEGIN EXCLUSIVE`. There is no busy
    /// handler, so the copy fails at once instead of waiting (D-003).
    SourceBusy,
    /// The destination could not be created, filled, switched to the rollback
    /// journal, or closed. `SnapshotDetail` holds the engine message.
    SnapshotFailed,
};

/// Engine message of a failed `copySnapshotTo`, copied before the destination
/// connection is closed. Longer messages are cut.
pub const SnapshotDetail = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const SnapshotDetail) []const u8 {
        return self.buffer[0..self.len];
    }

    fn capture(self: *SnapshotDetail, conn: *sqlite.sqlite3) void {
        const message_text = std.mem.span(sqlite.sqlite3_errmsg(conn));
        self.len = @min(message_text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], message_text[0..self.len]);
    }
};

pub const StepError = error{
    StepFailed,
    /// The time limit expired while the statement was running.
    Timeout,
    /// The cancel flag was set (SIGINT) while the statement was running.
    Interrupted,
};

pub const ExplainError = error{
    /// The query plan of an accepted SELECT could not be read.
    ExplainFailed,
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
        // The `-wal` file is opened read-write even on a read-only connection,
        // so only the missing exclusive lock on the main file keeps the last
        // close of a WAL database from checkpointing into it. Make that a
        // setting instead of a side effect.
        if (sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null)) != sqlite.SQLITE_OK) {
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

    /// Copies the database into a new file at `dest_path` as one snapshot.
    ///
    /// One `sqlite3_backup_step(-1)` copies every page inside a single read
    /// transaction on this connection, so the copy holds the committed WAL
    /// frames as of that moment, and a writer elsewhere cannot tear it. The
    /// source is only read. Page 1 is copied as is, so a WAL source would leave
    /// the copy in WAL mode; the copy is switched back to the rollback journal
    /// before it is closed, so that later writes to it stay in the file.
    ///
    /// The destination is the only connection this module opens read-write.
    /// `dest_path` must not exist yet and should sit in a private directory.
    pub fn copySnapshotTo(self: *Db, dest_path: [:0]const u8, detail: *SnapshotDetail) SnapshotError!void {
        detail.len = 0;
        var handle: ?*sqlite.sqlite3 = null;
        const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOFOLLOW;
        const open_rc = sqlite.sqlite3_open_v2(dest_path, &handle, flags, null);
        const dest = handle orelse return error.SnapshotFailed;
        var closed = false;
        defer if (!closed) {
            _ = sqlite.sqlite3_close(dest);
        };
        if (open_rc != sqlite.SQLITE_OK) {
            detail.capture(dest);
            return error.SnapshotFailed;
        }

        const backup = sqlite.sqlite3_backup_init(dest, "main", self.connection(), "main") orelse {
            detail.capture(dest);
            return error.SnapshotFailed;
        };
        const step_rc = sqlite.sqlite3_backup_step(backup, -1);
        // `finish` is required after every outcome, `SQLITE_BUSY` included,
        // and it leaves the backup's error on the destination connection.
        const finish_rc = sqlite.sqlite3_backup_finish(backup);
        if (step_rc != sqlite.SQLITE_DONE or finish_rc != sqlite.SQLITE_OK) {
            detail.capture(dest);
            if (step_rc & 0xff == sqlite.SQLITE_BUSY) return error.SourceBusy;
            return error.SnapshotFailed;
        }

        if (sqlite.sqlite3_exec(dest, "PRAGMA journal_mode=DELETE", null, null, null) != sqlite.SQLITE_OK) {
            detail.capture(dest);
            return error.SnapshotFailed;
        }

        closed = true;
        if (sqlite.sqlite3_close(dest) != sqlite.SQLITE_OK) {
            // No statement is left on `dest`, so this only happens when the
            // last write cannot be completed; the copy is not trusted then.
            detail.capture(dest);
            _ = sqlite.sqlite3_close(dest);
            return error.SnapshotFailed;
        }
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

    /// Reads the query plan of `sql` with `binds` bound, as
    /// `EXPLAIN QUERY PLAN` would print it. The rows and their `detail` text
    /// are owned by `allocator`.
    ///
    /// The plan comes from a statement of its own (D-302): switching a
    /// statement to `EXPLAIN QUERY PLAN` re-prepares it with plan opcodes that
    /// stay in its program, so the statement that runs the SELECT would count
    /// more VM steps. Same connection, SQL and binds give the same plan.
    ///
    /// The switch re-prepares under the select allowlist, so the authorizer
    /// stays as strict as for `prepareSelect`.
    pub fn explainPlan(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const BindArg,
    ) (CheckError || BindError || ExplainError || std.mem.Allocator.Error)!Plan {
        const statement = try self.prepareSelect(sql);
        defer _ = sqlite.sqlite3_finalize(statement);
        try bindAll(statement, binds);

        // Entered after `prepareSelect`, which resets the observed actions,
        // so the list shows what the re-prepare reported.
        const previous = self.enterMode(.user_select);
        defer self.mode = previous;

        if (sqlite.sqlite3_stmt_explain(statement, 2) != sqlite.SQLITE_OK) return error.ExplainFailed;
        // `EXPLAIN QUERY PLAN` rows are (id, parent, notused, detail).
        if (sqlite.sqlite3_column_count(statement) != 4) return error.ExplainFailed;

        var rows: std.ArrayList(PlanRow) = .empty;
        errdefer {
            for (rows.items) |row| allocator.free(row.detail);
            rows.deinit(allocator);
        }
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
                    // The text is only valid until the next step, so it is
                    // copied before the row is kept.
                    const text = sqlite.sqlite3_column_text(statement, 3) orelse return error.ExplainFailed;
                    const detail = try allocator.dupe(u8, std.mem.span(text));
                    errdefer allocator.free(detail);
                    try rows.append(allocator, .{
                        .id = sqlite.sqlite3_column_int64(statement, 0),
                        .parent = sqlite.sqlite3_column_int64(statement, 1),
                        .label = classifyDetail(detail),
                        .detail = detail,
                    });
                },
                sqlite.SQLITE_DONE => break,
                else => return error.ExplainFailed,
            }
        }
        return .{ .rows = try rows.toOwnedSlice(allocator) };
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

/// Main shape of one query plan line.
pub const PlanKind = enum {
    /// `SCAN ...`: reads a table, an index, a subquery, or constant rows from
    /// start to end.
    scan,
    /// `SEARCH ...`: looks rows up through a key or an index.
    search,
    /// `USE TEMP B-TREE ...`: sorts or deduplicates into a temporary tree.
    temp_btree,
    /// Any other line, including wording this release does not produce.
    other,
};

/// A rough label for one plan line (D-303). SQLite does not promise a stable
/// wording, so the label is a hint; the raw `detail` stays the source of
/// truth and the counters carry the judgement.
pub const PlanLabel = struct {
    kind: PlanKind,
    /// The index holds every column the line needs (`COVERING INDEX`).
    covering: bool = false,
    /// SQLite builds the index while the statement runs (`AUTOMATIC`).
    automatic: bool = false,
};

pub const PlanRow = struct {
    id: i64,
    /// `id` of the enclosing line, or 0 at the top level.
    parent: i64,
    label: PlanLabel,
    detail: []const u8,
};

/// Query plan lines in the order SQLite reports them.
pub const Plan = struct {
    rows: []PlanRow,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        for (self.rows) |row| allocator.free(row.detail);
        allocator.free(self.rows);
    }
};

/// Labels one `EXPLAIN QUERY PLAN` detail line.
///
/// The main kind comes from the first word only. The attributes come from the
/// text after the first `" USING "` of a scan or search line. Names are
/// printed unquoted, so a table or alias that contains `" USING "` can still
/// mislead the attributes; D-303 accepts that for a hint.
pub fn classifyDetail(detail: []const u8) PlanLabel {
    const kind: PlanKind = if (std.mem.startsWith(u8, detail, "SCAN "))
        .scan
    else if (std.mem.startsWith(u8, detail, "SEARCH "))
        .search
    else if (std.mem.startsWith(u8, detail, "USE TEMP B-TREE"))
        .temp_btree
    else
        .other;
    if (kind != .scan and kind != .search) return .{ .kind = kind };

    const using = " USING ";
    const at = std.mem.indexOf(u8, detail, using) orelse return .{ .kind = kind };
    var rest = detail[at + using.len ..];
    const automatic = std.mem.startsWith(u8, rest, "AUTOMATIC ");
    if (automatic) {
        rest = rest["AUTOMATIC ".len..];
        if (std.mem.startsWith(u8, rest, "PARTIAL ")) rest = rest["PARTIAL ".len..];
    }
    return .{
        .kind = kind,
        .covering = std.mem.startsWith(u8, rest, "COVERING INDEX"),
        .automatic = automatic,
    };
}

/// Per-statement counters from `sqlite3_stmt_status`, read after the run.
pub const Counters = struct {
    /// Steps forward through a table or index read from start to end.
    fullscan_steps: u32,
    /// Virtual machine instructions executed.
    vm_steps: u32,
    /// Sort operations.
    sort_ops: u32,
    /// Rows inserted into automatic indexes.
    autoindex_rows: u32,
};

/// Reads the counters of `statement` without resetting them. The counters
/// survive a re-prepare, so they cover the whole run.
pub fn statementCounters(statement: *sqlite.sqlite3_stmt) Counters {
    return .{
        .fullscan_steps = readCounter(statement, sqlite.SQLITE_STMTSTATUS_FULLSCAN_STEP),
        .vm_steps = readCounter(statement, sqlite.SQLITE_STMTSTATUS_VM_STEP),
        .sort_ops = readCounter(statement, sqlite.SQLITE_STMTSTATUS_SORT),
        .autoindex_rows = readCounter(statement, sqlite.SQLITE_STMTSTATUS_AUTOINDEX),
    };
}

/// The engine keeps each counter as `u32` and returns it as `int`, so the
/// bits are reinterpreted instead of range-checked.
fn readCounter(statement: *sqlite.sqlite3_stmt, op: c_int) u32 {
    return @bitCast(sqlite.sqlite3_stmt_status(statement, op, 0));
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
/// Production code opens user databases with `SQLITE_OPEN_READONLY` only; the
/// one production read-write open is the snapshot destination in
/// `copySnapshotTo`. This function exists so that tests can build fixture
/// databases without the `sqlite3` CLI.
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

/// Test-only helper: opens `path` read-write and runs `sql`, keeping the
/// connection open so that a test can hold a lock or keep WAL frames from
/// being checkpointed. Close it with `sqlite3_close`.
pub fn openTestWriter(path: [:0]const u8, sql: [:0]const u8) !*sqlite.sqlite3 {
    comptime std.debug.assert(builtin.is_test);
    var handle: ?*sqlite.sqlite3 = null;
    const rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, null);
    const connection = handle orelse return error.TestFixtureFailed;
    errdefer _ = sqlite.sqlite3_close(connection);
    if (rc != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    if (sqlite.sqlite3_exec(connection, sql, null, null, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    return connection;
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
    const plan = try db.explainPlan(testing.allocator, "SELECT count(*) FROM t WHERE a = ?1", &.{
        .{ .number = 1, .value = .{ .int = 1 } },
    });
    plan.deinit(testing.allocator);
    try db.checkCreateIndex("CREATE INDEX idx_after ON t(a)");
    try db.close();

    const after = try fixture.tmp.dir.readFileAlloc(testing.io, "fixture.db", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-journal", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-wal", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-shm", .{}));
}

/// Plan tests need enough rows for a full scan to differ from a search, a
/// table with one index (`idx_b`), and a second table for joins.
const plan_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO t SELECT x, 'v' || x FROM c;
    \\CREATE INDEX idx_b ON t(b);
    \\CREATE TABLE u(x INTEGER, y TEXT);
    \\INSERT INTO u SELECT a, b FROM t;
;

/// Test-only helper: the first plan row whose detail starts with `prefix`.
fn findRow(plan: Plan, prefix: []const u8) ?PlanRow {
    for (plan.rows) |row| {
        if (std.mem.startsWith(u8, row.detail, prefix)) return row;
    }
    return null;
}

/// Test-only helper: runs a checked SELECT to the end and reads its counters.
fn runCounters(db: *Db, sql: [:0]const u8, binds: []const BindArg) !Counters {
    const statement = try prepareBoundSelect(db, sql, binds);
    defer _ = sqlite.sqlite3_finalize(statement);
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    _ = try db.stepAll(statement, &control);
    return statementCounters(statement);
}

test "classify detail splits main kind and attributes" {
    // Wording reported by the vendored 3.51.2 release. A new release may
    // change it; then this table is re-checked, not the raw detail.
    const cases = [_]struct { detail: []const u8, label: PlanLabel }{
        .{ .detail = "SCAN t", .label = .{ .kind = .scan } },
        .{ .detail = "SCAN t USING INDEX idx_a", .label = .{ .kind = .scan } },
        .{ .detail = "SCAN t USING COVERING INDEX idx_b", .label = .{ .kind = .scan, .covering = true } },
        .{ .detail = "SEARCH t USING INDEX idx_b (b=?)", .label = .{ .kind = .search } },
        .{ .detail = "SEARCH t USING INTEGER PRIMARY KEY (rowid=?)", .label = .{ .kind = .search } },
        .{ .detail = "SEARCH t USING COVERING INDEX idx_b (b>? AND b<?)", .label = .{ .kind = .search, .covering = true } },
        .{ .detail = "SEARCH u USING AUTOMATIC COVERING INDEX (x=?)", .label = .{ .kind = .search, .covering = true, .automatic = true } },
        .{ .detail = "SEARCH u USING AUTOMATIC PARTIAL COVERING INDEX (x=?)", .label = .{ .kind = .search, .covering = true, .automatic = true } },
        .{ .detail = "USE TEMP B-TREE FOR ORDER BY", .label = .{ .kind = .temp_btree } },
        // Constant rows are labelled scan; their full scan counter stays 0.
        .{ .detail = "SCAN CONSTANT ROW", .label = .{ .kind = .scan } },
        .{ .detail = "BLOOM FILTER ON u (x=?)", .label = .{ .kind = .other } },
        .{ .detail = "MULTI-INDEX OR", .label = .{ .kind = .other } },
        .{ .detail = "CO-ROUTINE c", .label = .{ .kind = .other } },
        .{ .detail = "LIST SUBQUERY 1", .label = .{ .kind = .other } },
        // Only the first word decides the kind, so a later "SEARCH" does not.
        .{ .detail = "CORRELATED SCALAR SUBQUERY 1 SEARCH", .label = .{ .kind = .other } },
        .{ .detail = "", .label = .{ .kind = .other } },
    };
    for (cases) |case| {
        const label = classifyDetail(case.detail);
        if (!std.meta.eql(label, case.label)) std.debug.print("unexpected label for '{s}'\n", .{case.detail});
        try testing.expectEqual(case.label, label);
    }
}

test "explain plan reports scan without an index and search with one" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const scan = try db.explainPlan(testing.allocator, "SELECT a, b FROM t WHERE a = ?1", &.{
        .{ .number = 1, .value = .{ .int = 7 } },
    });
    defer scan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), scan.rows.len);
    try testing.expectEqual(PlanKind.scan, scan.rows[0].label.kind);
    try testing.expect(std.mem.indexOf(u8, scan.rows[0].detail, "t") != null);

    const search = try db.explainPlan(testing.allocator, "SELECT a, b FROM t WHERE b = ?1", &.{
        .{ .number = 1, .value = .{ .text = "v7" } },
    });
    defer search.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), search.rows.len);
    try testing.expectEqual(PlanKind.search, search.rows[0].label.kind);
    try testing.expect(std.mem.indexOf(u8, search.rows[0].detail, "idx_b") != null);
}

test "explain plan reflects bound values" {
    // `GLOB` with a fixed prefix can use the index on `b`; a leading wildcard
    // cannot. Both use the same SQL, so only the bound value differs.
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const sql = "SELECT b FROM t WHERE b GLOB ?1";
    const prefix = try db.explainPlan(testing.allocator, sql, &.{.{ .number = 1, .value = .{ .text = "v1*" } }});
    defer prefix.deinit(testing.allocator);
    try testing.expectEqual(PlanKind.search, prefix.rows[0].label.kind);

    const suffix = try db.explainPlan(testing.allocator, sql, &.{.{ .number = 1, .value = .{ .text = "*1" } }});
    defer suffix.deinit(testing.allocator);
    try testing.expectEqual(PlanKind.scan, suffix.rows[0].label.kind);
}

test "explain plan keeps raw detail and parent links" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const sorted = try db.explainPlan(testing.allocator, "SELECT a FROM t ORDER BY a", &.{});
    defer sorted.deinit(testing.allocator);
    const temp = findRow(sorted, "USE TEMP B-TREE") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PlanKind.temp_btree, temp.label.kind);

    // Each branch of an OR over two indexes is a child of the MULTI-INDEX
    // line, and the searches below are children of those branches.
    const multi = try db.explainPlan(testing.allocator, "SELECT a FROM t WHERE b = 'v1' OR rowid = 3", &.{});
    defer multi.deinit(testing.allocator);
    const root = findRow(multi, "MULTI-INDEX OR") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PlanKind.other, root.label.kind);
    const branch = findRow(multi, "INDEX 1") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(root.id, branch.parent);
    const search = findRow(multi, "SEARCH t USING INDEX idx_b") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(branch.id, search.parent);
}

test "explain plan reports only allowlisted actions" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const plan = try db.explainPlan(testing.allocator, "SELECT count(abs(a)) FROM t WHERE b = ?1", &.{
        .{ .number = 1, .value = .{ .text = "v1" } },
    });
    defer plan.deinit(testing.allocator);

    // The list holds what the switch to EXPLAIN QUERY PLAN re-prepared.
    const actions = db.observedActions();
    try testing.expect(actions.len > 0);
    for (actions) |action_code| {
        const allowed = switch (action_code) {
            sqlite.SQLITE_SELECT, sqlite.SQLITE_READ, sqlite.SQLITE_FUNCTION, sqlite.SQLITE_RECURSIVE => true,
            else => false,
        };
        if (!allowed) std.debug.print("explain action {d} is not allowlisted\n", .{action_code});
        try testing.expect(allowed);
    }
    try testing.expectEqual(Mode.internal, db.mode);

    // The plan reuses the SELECT contract, so a rejected input stays rejected.
    try testing.expectError(error.StatementRejected, db.explainPlan(testing.allocator, "DELETE FROM t", &.{}));
    try testing.expectError(error.MissingBindNumber, db.explainPlan(testing.allocator, "SELECT ?1", &.{}));
    try testing.expectEqual(Mode.internal, db.mode);
}

test "explain plan labels an automatic index without creating it" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const count_indexes = "SELECT count(*) FROM sqlite_master WHERE type = 'index'";
    const before = try queryInt(&db, count_indexes);
    const plan = try db.explainPlan(testing.allocator, "SELECT a FROM t JOIN u ON u.x = t.a", &.{});
    defer plan.deinit(testing.allocator);
    // The automatic index of this join exists only while a statement runs.
    const automatic = findRow(plan, "SEARCH u USING AUTOMATIC") orelse return error.TestUnexpectedResult;
    try testing.expect(automatic.label.automatic);
    try testing.expectEqual(before, try queryInt(&db, count_indexes));
}

test "counters show full scan steps only without an index" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const scan = try runCounters(&db, "SELECT a, b FROM t WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 7 } }});
    const search = try runCounters(&db, "SELECT a, b FROM t WHERE b = ?1", &.{.{ .number = 1, .value = .{ .text = "v7" } }});

    // A full scan steps once per row after the first.
    try testing.expectEqual(@as(u32, 999), scan.fullscan_steps);
    try testing.expectEqual(@as(u32, 0), search.fullscan_steps);
    try testing.expect(search.vm_steps < scan.vm_steps);
    try testing.expectEqual(@as(u32, 0), scan.sort_ops);
    try testing.expectEqual(@as(u32, 0), scan.autoindex_rows);

    const joined = try runCounters(&db, "SELECT a FROM t JOIN u ON u.x = t.a", &.{});
    try testing.expect(joined.autoindex_rows > 0);
    // `a` has no index, so the order needs a sort (USE TEMP B-TREE).
    const sorted = try runCounters(&db, "SELECT a FROM t ORDER BY a", &.{});
    try testing.expect(sorted.sort_ops > 0);
}

test "explaining does not change the execution counters" {
    // D-302: the plan is read from a statement of its own, so the statement
    // that runs the SELECT counts the same work with or without it. The
    // control below shows why: switching the running statement itself to
    // EXPLAIN QUERY PLAN and back leaves plan opcodes in its program.
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const sql = "SELECT a FROM t WHERE a IN (SELECT x FROM u WHERE x < ?1)";
    const binds: []const BindArg = &.{.{ .number = 1, .value = .{ .int = 100 } }};
    const plain = try runCounters(&db, sql, binds);

    // Control: reuse one statement for the plan and the run.
    {
        const reused = try prepareBoundSelect(&db, sql, binds);
        defer _ = sqlite.sqlite3_finalize(reused);
        {
            const previous = db.enterMode(.user_select);
            defer db.mode = previous;
            try testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_stmt_explain(reused, 2));
            while (sqlite.sqlite3_step(reused) == sqlite.SQLITE_ROW) {}
            _ = sqlite.sqlite3_reset(reused);
            try testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_stmt_explain(reused, 0));
        }
        var cancel = std.atomic.Value(bool).init(false);
        var control = StepControl.init(testing.io, 0, &cancel);
        _ = try db.stepAll(reused, &control);
        const counters = statementCounters(reused);
        try testing.expectEqual(plain.fullscan_steps, counters.fullscan_steps);
        try testing.expect(counters.vm_steps > plain.vm_steps);
    }

    const statement = try prepareBoundSelect(&db, sql, binds);
    defer _ = sqlite.sqlite3_finalize(statement);
    const plan = try db.explainPlan(testing.allocator, sql, binds);
    defer plan.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    _ = try db.stepAll(statement, &control);

    try testing.expect(plan.rows.len > 0);
    try testing.expectEqual(plain, statementCounters(statement));
}

/// A directory holding a source database and the paths a snapshot test needs.
const SnapshotFixture = struct {
    tmp: testing.TmpDir,
    source: [:0]u8,
    dest: [:0]u8,

    fn init() !SnapshotFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.db", .data = "" });
        const source = try tmp.dir.realPathFileAlloc(testing.io, "source.db", testing.allocator);
        errdefer testing.allocator.free(source);
        const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir_path);
        const dest = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/baseline.db", .{dir_path}, 0);
        return .{ .tmp = tmp, .source = source, .dest = dest };
    }

    fn deinit(self: *SnapshotFixture) void {
        testing.allocator.free(self.source);
        testing.allocator.free(self.dest);
        self.tmp.cleanup();
    }

    fn read(self: *SnapshotFixture, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
    }

    fn exists(self: *SnapshotFixture, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }

    /// Copies the source into `dest` through a read-only connection.
    fn snapshot(self: *SnapshotFixture) !void {
        var source: Db = .{};
        try source.openReadOnly(self.source);
        defer source.close() catch unreachable;
        var detail: SnapshotDetail = .{};
        try source.copySnapshotTo(self.dest, &detail);
    }

    fn countRows(path: [:0]const u8) !i64 {
        var copy: Db = .{};
        try copy.openReadOnly(path);
        defer copy.close() catch unreachable;
        return queryInt(&copy, "SELECT count(*) FROM t");
    }
};

/// WAL source whose rows exist only as frames in `-wal`: the automatic
/// checkpoint is off and the writer stays open, so nothing reaches the main
/// file.
const wal_writer_sql: [:0]const u8 =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA wal_autocheckpoint=0;
    \\CREATE TABLE t(a INTEGER);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000) INSERT INTO t SELECT x FROM c;
;

test "snapshot of a wal database includes frames not yet checkpointed" {
    var fixture = try SnapshotFixture.init();
    defer fixture.deinit();
    const writer = try openTestWriter(fixture.source, wal_writer_sql);
    defer _ = sqlite.sqlite3_close(writer);

    try fixture.snapshot();
    try testing.expectEqual(@as(i64, 1000), try SnapshotFixture.countRows(fixture.dest));

    // A copy of the main file alone misses the table, which is why the plain
    // file copy is not used.
    const main_only = try fixture.read("source.db");
    defer testing.allocator.free(main_only);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "main-only.db", .data = main_only });
    const main_only_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "main-only.db", testing.allocator);
    defer testing.allocator.free(main_only_path);
    try testing.expectError(error.StatementInvalid, SnapshotFixture.countRows(main_only_path));
}

test "baseline uses the rollback journal" {
    var fixture = try SnapshotFixture.init();
    defer fixture.deinit();
    const writer = try openTestWriter(fixture.source, wal_writer_sql);
    defer _ = sqlite.sqlite3_close(writer);

    try fixture.snapshot();

    // Header bytes 18 and 19 are the write and read format versions: 1 means
    // rollback journal, 2 means WAL.
    const bytes = try fixture.read("baseline.db");
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 1), bytes[18]);
    try testing.expectEqual(@as(u8, 1), bytes[19]);
    try testing.expect(!fixture.exists("baseline.db-wal"));
    try testing.expect(!fixture.exists("baseline.db-shm"));
}

test "source db and wal bytes are unchanged by the snapshot" {
    var fixture = try SnapshotFixture.init();
    defer fixture.deinit();
    const writer = try openTestWriter(fixture.source, wal_writer_sql);
    defer _ = sqlite.sqlite3_close(writer);

    const main_before = try fixture.read("source.db");
    defer testing.allocator.free(main_before);
    const wal_before = try fixture.read("source.db-wal");
    defer testing.allocator.free(wal_before);
    try testing.expect(wal_before.len > 0);

    try fixture.snapshot();

    const main_after = try fixture.read("source.db");
    defer testing.allocator.free(main_after);
    const wal_after = try fixture.read("source.db-wal");
    defer testing.allocator.free(wal_after);
    try testing.expectEqualSlices(u8, main_before, main_after);
    try testing.expectEqualSlices(u8, wal_before, wal_after);
}

test "snapshot of a quiescent wal database" {
    var fixture = try SnapshotFixture.init();
    defer fixture.deinit();
    // Closing the only writer checkpoints and removes `-wal` and `-shm`, so
    // the source is a WAL database with no side files.
    const writer = try openTestWriter(fixture.source, wal_writer_sql);
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_close(writer));
    try testing.expect(!fixture.exists("source.db-wal"));
    const main_before = try fixture.read("source.db");
    defer testing.allocator.free(main_before);
    try testing.expectEqual(@as(u8, 2), main_before[18]);

    try fixture.snapshot();

    try testing.expectEqual(@as(i64, 1000), try SnapshotFixture.countRows(fixture.dest));
    // D-001: the read-only connection may leave `-wal` and `-shm` next to the
    // source; only the main file must keep its bytes.
    const main_after = try fixture.read("source.db");
    defer testing.allocator.free(main_after);
    try testing.expectEqualSlices(u8, main_before, main_after);
}

test "busy source is reported" {
    var fixture = try SnapshotFixture.init();
    defer fixture.deinit();
    try createTestDatabase(fixture.source, fixture_schema);

    var source: Db = .{};
    try source.openReadOnly(fixture.source);
    defer source.close() catch unreachable;

    // A rollback-journal writer inside an exclusive transaction blocks every
    // reader, and without a busy handler the copy gives up at once.
    const writer = try openTestWriter(fixture.source, "BEGIN EXCLUSIVE; INSERT INTO t VALUES (9, 'w');");
    defer _ = sqlite.sqlite3_close(writer);

    var detail: SnapshotDetail = .{};
    try testing.expectError(error.SourceBusy, source.copySnapshotTo(fixture.dest, &detail));
    try testing.expect(detail.text().len > 0);
    // The destination connection was closed, so the file can be removed.
    try fixture.tmp.dir.deleteFile(testing.io, "baseline.db");
}
