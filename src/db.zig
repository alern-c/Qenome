const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sql_lexer = @import("sql/lexer.zig");
const sqlite = @import("sqlite.zig");
const result = @import("result.zig");

pub const Mode = enum { internal, user_select, user_dml, user_ddl, user_migration };

pub const OpenError = error{
    OpenFailed,
    NotReadOnlyConnection,
    NotWritableConnection,
    GuardSetupFailed,
};

pub const CloseError = error{CloseFailed};

pub const SnapshotError = error{
    SourceBusy,
    SnapshotFailed,
};

pub const SnapshotDetail = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    error_code: c_int = 0,
    statement_index: usize = 0,

    pub fn text(self: *const SnapshotDetail) []const u8 {
        return self.buffer[0..self.len];
    }

    fn capture(self: *SnapshotDetail, conn: *sqlite.sqlite3) void {
        self.error_code = sqlite.sqlite3_errcode(conn) & 0xff;
        const message_text = std.mem.span(sqlite.sqlite3_errmsg(conn));
        self.len = @min(message_text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], message_text[0..self.len]);
    }
};

pub const StepError = error{
    StepFailed,
    Timeout,
    Interrupted,
};

pub const ApplyError = CheckError || error{
    OpenFailed,
    GuardSetupFailed,
    Timeout,
    Interrupted,
    ApplyFailed,
};

pub const MigrationKind = enum {
    create_index,
    drop_index,
    create_table,
    alter_table,

    pub fn text(self: MigrationKind) []const u8 {
        return switch (self) {
            .create_index => "create_index",
            .drop_index => "drop_index",
            .create_table => "create_table",
            .alter_table => "alter_table",
        };
    }
};

pub const MigrationStatement = struct {
    kind: MigrationKind,
    sql: [:0]const u8,
};

pub const MigrationError = error{
    MigrationEmpty,
    MigrationStatementNotAllowed,
};

pub const MigrationApplyError = error{
    OpenFailed,
    GuardSetupFailed,
    MigrationApplyFailed,
    Timeout,
    Interrupted,
};

pub const ExplainError = error{
    ExplainFailed,
};

pub const InterruptReason = enum { timeout, signal };

pub const StepControl = struct {
    io: Io,
    timeout_ms: u64,
    cancel: *const std.atomic.Value(bool),
    reason: ?InterruptReason = null,
    deadline_ns: ?i96 = null,

    pub fn init(io: Io, timeout_ms: u64, cancel: *const std.atomic.Value(bool)) StepControl {
        return .{ .io = io, .timeout_ms = timeout_ms, .cancel = cancel };
    }

    fn start(self: *StepControl) void {
        self.reason = null;
        const now = Io.Clock.now(.awake, self.io).nanoseconds;
        self.deadline_ns = if (self.timeout_ms == 0) null else now + @as(i96, @intCast(self.timeout_ms)) * std.time.ns_per_ms;
    }

    fn shouldStop(self: *StepControl) bool {
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

const progress_opcodes: c_int = 1000;

pub const CheckError = error{
    EmptyStatement,
    MultipleStatements,
    StatementRejected,
    StatementInvalid,
    StatementNotReadOnly,
    StatementNotWrite,
    StatementNotCreateIndex,
};

pub const BytesInUseError = CheckError || StepError;

fn diagnosticStepError(rc: c_int, control: *StepControl) StepError {
    if (rc == sqlite.SQLITE_INTERRUPT) if (control.reason) |reason| return switch (reason) {
        .timeout => error.Timeout,
        .signal => error.Interrupted,
    };
    return error.StepFailed;
}

fn controlStopError(control: *StepControl) ?StepError {
    if (!control.shouldStop()) return null;
    return switch (control.reason.?) {
        .timeout => error.Timeout,
        .signal => error.Interrupted,
    };
}

pub const TableWarnings = struct {
    no_analyze_stats: bool = false,
    data_too_small: bool = false,
};

pub const Clues = struct {
    nondeterministic_function: ?[]const u8 = null,
    schema_table: ?[]const u8 = null,
    order_dependent_function: ?[]const u8 = null,
    time_function: ?[]const u8 = null,
    view_or_cte: bool = false,

    pub fn merge(a: Clues, b: Clues) Clues {
        return .{
            .nondeterministic_function = a.nondeterministic_function orelse b.nondeterministic_function,
            .schema_table = a.schema_table orelse b.schema_table,
            .order_dependent_function = a.order_dependent_function orelse b.order_dependent_function,
            .time_function = a.time_function orelse b.time_function,
            .view_or_cte = a.view_or_cte or b.view_or_cte,
        };
    }

    pub fn alwaysIncomparable(self: Clues) bool {
        return self.nondeterministic_function != null or self.schema_table != null;
    }
};

const nondeterministic_functions = [_][]const u8{
    "random", "randomblob", "changes", "last_insert_rowid", "total_changes",
};

const time_functions = [_][]const u8{
    "julianday", "unixepoch", "date",         "time",         "datetime",
    "strftime",  "timediff",  "current_time", "current_date", "current_timestamp",
};

const order_dependent_functions = [_][]const u8{
    "sum",              "avg",               "total",             "group_concat",       "string_agg",
    "json_group_array", "json_group_object", "jsonb_group_array", "jsonb_group_object", "row_number",
    "ntile",            "first_value",       "last_value",        "nth_value",          "lag",
    "lead",
};

const schema_tables = [_][]const u8{ "sqlite_schema", "sqlite_master", "sqlite_temp_schema", "sqlite_temp_master" };
const stat_table_prefix = "sqlite_stat";

fn findName(list: []const []const u8, name: []const u8) ?[]const u8 {
    for (list) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, name)) return entry;
    }
    return null;
}

const max_observed_actions = 64;

const IndexTarget = struct {
    allocator: std.mem.Allocator,
    table: ?[]const u8 = null,
};

pub const IndexOrigin = enum { created, unique_constraint, primary_key };

pub const IndexColumn = struct {
    name: []const u8,
    collation: []const u8,
    descending: bool,
};

pub const IndexInfo = struct {
    name: []const u8,
    table: []const u8,
    origin: IndexOrigin = .created,
    unique: bool = false,
    partial: bool = false,
    unreadable: bool = false,
    columns: []IndexColumn = &.{},
};

pub const RowidPrimaryKey = struct {
    table: []const u8,
    column: []const u8,
};

pub const IndexCatalog = struct {
    indexes: []IndexInfo = &.{},
    rowid_primary_keys: []RowidPrimaryKey = &.{},

    pub fn deinit(self: IndexCatalog, allocator: std.mem.Allocator) void {
        for (self.indexes) |info| freeIndexInfo(allocator, info);
        allocator.free(self.indexes);
        for (self.rowid_primary_keys) |key| {
            allocator.free(key.table);
            allocator.free(key.column);
        }
        allocator.free(self.rowid_primary_keys);
    }
};

fn freeIndexInfo(allocator: std.mem.Allocator, info: IndexInfo) void {
    allocator.free(info.name);
    allocator.free(info.table);
    for (info.columns) |column| {
        allocator.free(column.name);
        allocator.free(column.collation);
    }
    allocator.free(info.columns);
}

pub const IndexCatalogError = CheckError || StepError || std.mem.Allocator.Error || error{IndexCatalogFailed};

const catalog_tables = "SELECT name FROM main.sqlite_schema WHERE type = 'table' AND name NOT GLOB 'sqlite_*' ORDER BY name";

const catalog_pragma_list = "PRAGMA main.index_list(";

const catalog_pragma_xinfo = "PRAGMA main.index_xinfo(";

const catalog_pragma_table_info = "PRAGMA main.table_info(";

fn catalogPragma(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![:0]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, prefix);
    try buffer.append(allocator, '"');
    for (name) |byte| {
        try buffer.append(allocator, byte);
        if (byte == '"') try buffer.append(allocator, byte);
    }
    try buffer.appendSlice(allocator, "\")");
    return allocator.dupeSentinel(u8, buffer.items, 0);
}

fn indexOrigin(text: ?[*:0]const u8) IndexOrigin {
    const bytes = std.mem.span(text orelse return .created);
    if (bytes.len == 0) return .created;
    return switch (bytes[0]) {
        'u' => .unique_constraint,
        'p' => .primary_key,
        else => .created,
    };
}

pub const Db = struct {
    index_target: ?*IndexTarget = null,
    handle: ?*sqlite.sqlite3 = null,
    mode: Mode = .internal,
    seen_create_index: bool = false,
    seen_write: bool = false,
    candidate_index: [256]u8 = undefined,
    candidate_index_len: usize = 0,
    clues: Clues = .{},
    observed: [max_observed_actions]c_int = @splat(0),
    observed_count: usize = 0,

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

        if (sqlite.sqlite3_db_readonly(conn, "main") != 1) return error.NotReadOnlyConnection;

        if (!disableDoubleQuotedStrings(conn)) return error.GuardSetupFailed;
        if (sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null)) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }

        if (sqlite.sqlite3_set_authorizer(conn, authorizer, self) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
        if (sqlite.sqlite3_exec(conn, "PRAGMA query_only=1", null, null, null) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
    }

    pub fn openWritable(self: *Db, path: [:0]const u8) OpenError!void {
        var handle: ?*sqlite.sqlite3 = null;
        const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_NOFOLLOW;
        const rc = sqlite.sqlite3_open_v2(path, &handle, flags, null);
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

        if (sqlite.sqlite3_db_readonly(conn, "main") != 0) return error.NotWritableConnection;

        if (!disableDoubleQuotedStrings(conn)) return error.GuardSetupFailed;
        if (sqlite.sqlite3_exec(conn, "PRAGMA foreign_keys=ON", null, null, null) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }

        if (sqlite.sqlite3_set_authorizer(conn, authorizer, self) != sqlite.SQLITE_OK) {
            return error.GuardSetupFailed;
        }
    }

    pub fn close(self: *Db) CloseError!void {
        const conn = self.handle orelse return;
        if (sqlite.sqlite3_close(conn) != sqlite.SQLITE_OK) return error.CloseFailed;
        self.* = .{};
    }

    pub fn copySnapshotTo(self: *Db, dest_path: [:0]const u8, detail: *SnapshotDetail) SnapshotError!void {
        detail.len = 0;
        detail.error_code = 0;
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
            detail.capture(dest);
            _ = sqlite.sqlite3_close(dest);
            return error.SnapshotFailed;
        }
    }

    pub fn prepareSelect(self: *Db, sql: [:0]const u8) CheckError!*sqlite.sqlite3_stmt {
        self.clues = .{};
        const previous = self.enterMode(.user_select);
        defer self.mode = previous;

        const statement = (try self.prepareSingle(sql)) orelse return error.EmptyStatement;
        errdefer _ = sqlite.sqlite3_finalize(statement);

        if (sqlite.sqlite3_stmt_readonly(statement) != 1) return error.StatementNotReadOnly;
        return statement;
    }

    pub fn checkSelect(self: *Db, sql: [:0]const u8) CheckError!void {
        const statement = try self.prepareSelect(sql);
        _ = sqlite.sqlite3_finalize(statement);
    }

    pub fn checkWrite(self: *Db, sql: [:0]const u8) CheckError!void {
        const statement = try self.prepareWrite(sql);
        _ = sqlite.sqlite3_finalize(statement);
    }

    pub fn prepareWrite(self: *Db, sql: [:0]const u8) CheckError!*sqlite.sqlite3_stmt {
        self.clues = .{};
        const previous = self.enterMode(.user_dml);
        defer self.mode = previous;

        if (!startsWithWriteKeyword(sql)) return error.StatementNotWrite;

        const statement = (try self.prepareSingle(sql)) orelse return error.EmptyStatement;
        errdefer _ = sqlite.sqlite3_finalize(statement);

        if (sqlite.sqlite3_stmt_readonly(statement) != 0) return error.StatementNotWrite;
        if (!self.seen_write) return error.StatementNotWrite;
        return statement;
    }

    pub fn checkCreateIndex(self: *Db, sql: [:0]const u8) CheckError!void {
        const previous = self.enterMode(.user_ddl);
        defer self.mode = previous;

        const statement = (try self.prepareSingle(sql)) orelse return error.EmptyStatement;
        defer _ = sqlite.sqlite3_finalize(statement);

        if (!self.seen_create_index) return error.StatementNotCreateIndex;
        if (sqlite.sqlite3_stmt_readonly(statement) != 0) return error.StatementNotCreateIndex;
    }

    pub const SchemaEntry = struct {
        name: []const u8,
        sql: []const u8,
    };

    pub fn readSchemaEntries(self: *Db, allocator: std.mem.Allocator) ![]SchemaEntry {
        const previous = self.enterMode(.user_select);
        const saved_clues = self.clues;
        defer self.mode = previous;
        defer self.clues = saved_clues;

        const statement = (try self.prepareSingle("SELECT name, sql FROM main.sqlite_schema WHERE sql IS NOT NULL")) orelse return error.SchemaReadFailed;
        defer _ = sqlite.sqlite3_finalize(statement);

        var entries: std.ArrayList(SchemaEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.sql);
            }
            entries.deinit(allocator);
        }
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
                    const name_text = sqlite.sqlite3_column_text(statement, 0) orelse "";
                    const sql_text = sqlite.sqlite3_column_text(statement, 1) orelse "";
                    const name_len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 0));
                    const sql_len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 1));
                    try entries.append(allocator, .{
                        .name = try allocator.dupe(u8, name_text[0..name_len]),
                        .sql = try allocator.dupe(u8, sql_text[0..sql_len]),
                    });
                },
                sqlite.SQLITE_DONE => break,
                else => return error.SchemaReadFailed,
            }
        }
        return try entries.toOwnedSlice(allocator);
    }

    pub fn stepAll(self: *Db, statement: *sqlite.sqlite3_stmt, control: *StepControl, collector: ?*result.RowCollector) StepError!u64 {
        return self.stepAllInMode(.user_select, statement, control, collector);
    }

    pub fn stepDml(self: *Db, statement: *sqlite.sqlite3_stmt, control: *StepControl, collector: ?*result.RowCollector) StepError!u64 {
        return self.stepAllInMode(.user_dml, statement, control, collector);
    }

    fn stepAllInMode(self: *Db, mode: Mode, statement: *sqlite.sqlite3_stmt, control: *StepControl, collector: ?*result.RowCollector) StepError!u64 {
        const previous = self.enterMode(mode);
        defer self.mode = previous;

        control.start();

        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);

        var rows: u64 = 0;
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
                    rows += 1;
                    if (collector) |rows_out| rows_out.add(statement);
                },
                sqlite.SQLITE_DONE => return rows,
                else => |rc| {
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

    pub fn beginWrite(self: *Db, control: *StepControl) StepError!void {
        const previous = self.enterMode(.internal);
        defer self.mode = previous;
        control.start();
        if (controlStopError(control)) |stop| return stop;
        if (sqlite.sqlite3_exec(self.connection(), "BEGIN IMMEDIATE", null, null, null) != sqlite.SQLITE_OK) return error.StepFailed;
    }

    pub fn rollbackWrite(self: *Db) StepError!void {
        if (sqlite.sqlite3_get_autocommit(self.connection()) != 0) return;
        const previous = self.enterMode(.internal);
        defer self.mode = previous;
        if (sqlite.sqlite3_exec(self.connection(), "ROLLBACK", null, null, null) != sqlite.SQLITE_OK) return error.StepFailed;
    }

    pub fn changes(self: *const Db) u64 {
        return @intCast(@max(sqlite.sqlite3_changes64(self.connection()), 0));
    }

    pub fn totalChanges(self: *const Db) u64 {
        return @intCast(@max(sqlite.sqlite3_total_changes64(self.connection()), 0));
    }

    pub fn explainPlan(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const BindArg,
    ) (CheckError || BindError || ExplainError || StepError || std.mem.Allocator.Error)!Plan {
        return self.explainPlanBounded(allocator, sql, binds, null);
    }

    pub fn explainDml(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const BindArg,
        control: *StepControl,
    ) (CheckError || BindError || ExplainError || StepError || std.mem.Allocator.Error)!Plan {
        return self.explainPlanInMode(allocator, sql, binds, control, .user_dml);
    }

    pub fn explainPlanBounded(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const BindArg,
        control: ?*StepControl,
    ) (CheckError || BindError || ExplainError || StepError || std.mem.Allocator.Error)!Plan {
        return self.explainPlanInMode(allocator, sql, binds, control, .user_select);
    }

    fn explainPlanInMode(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const BindArg,
        control: ?*StepControl,
        mode: Mode,
    ) (CheckError || BindError || ExplainError || StepError || std.mem.Allocator.Error)!Plan {
        if (control) |running| {
            running.start();
            if (controlStopError(running)) |stop| return stop;
            sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, running);
        }
        defer if (control != null) {
            sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        };

        const statement = switch (mode) {
            .user_dml => try self.prepareWrite(sql),
            else => try self.prepareSelect(sql),
        };
        defer _ = sqlite.sqlite3_finalize(statement);
        try bindAll(statement, binds);

        const previous = self.enterMode(mode);
        defer self.mode = previous;

        if (sqlite.sqlite3_stmt_explain(statement, 2) != sqlite.SQLITE_OK) return error.ExplainFailed;
        if (sqlite.sqlite3_column_count(statement) != 4) return error.ExplainFailed;

        var rows: std.ArrayList(PlanRow) = .empty;
        errdefer {
            for (rows.items) |row| allocator.free(row.detail);
            rows.deinit(allocator);
        }
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
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
                else => |rc| {
                    if (control) |running| {
                        if (rc == sqlite.SQLITE_INTERRUPT) return diagnosticStepError(rc, running);
                    }
                    return error.ExplainFailed;
                },
            }
        }
        if (control) |running| {
            if (controlStopError(running)) |stop| return stop;
        }
        return .{ .rows = try rows.toOwnedSlice(allocator) };
    }

    pub fn indexTarget(self: *Db, allocator: std.mem.Allocator, sql: [:0]const u8) ![]const u8 {
        var capture: IndexTarget = .{ .allocator = allocator };
        self.index_target = &capture;
        defer self.index_target = null;
        errdefer if (capture.table) |table| allocator.free(table);
        try self.checkCreateIndex(sql);
        return capture.table orelse error.OutOfMemory;
    }

    pub fn findBindDependentPartialIndex(
        self: *Db,
        allocator: std.mem.Allocator,
        plan: Plan,
        sql: [:0]const u8,
        binds: []const BindArg,
        control: *StepControl,
    ) !?[]const u8 {
        if (binds.len == 0) return null;
        if (!planMentionsAnyIndex(plan)) return null;

        var names = self.diagnosticTexts(allocator, "SELECT name FROM main.sqlite_schema WHERE type = 'index' AND sql IS NOT NULL", &.{}, control) catch return null;
        defer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        var used: std.ArrayList([]const u8) = .empty;
        defer used.deinit(allocator);
        for (plan.rows) |row| {
            const name = usedIndexName(row.detail, names.items) orelse continue;
            var seen = false;
            for (used.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try used.append(allocator, name);
        }
        if (used.items.len == 0) return null;

        const unknown_binds = try allocator.alloc(BindArg, binds.len);
        defer allocator.free(unknown_binds);
        for (unknown_binds, 0..) |*bind, position| bind.* = .{ .number = position + 1, .value = .null };

        const saved_clues = self.clues;
        defer self.clues = saved_clues;
        const unknown_plan = self.explainPlanBounded(allocator, sql, unknown_binds, control) catch return null;
        defer unknown_plan.deinit(allocator);

        for (used.items) |name| {
            if (planUsesIndex(unknown_plan, names.items, name)) continue;
            const partial = self.indexIsPartial(allocator, name, control) catch return null;
            if (!partial) continue;
            return try allocator.dupe(u8, name);
        }
        return null;
    }

    fn indexIsPartial(self: *Db, allocator: std.mem.Allocator, name: []const u8, control: *StepControl) !bool {
        const table = (try self.diagnosticText(allocator, "SELECT tbl_name FROM main.sqlite_schema WHERE type = 'index' AND name = ?1 COLLATE NOCASE", &.{
            .{ .number = 1, .value = .{ .text = name } },
        }, control)) orelse return false;
        defer allocator.free(table);

        var query: Io.Writer.Allocating = .init(allocator);
        defer query.deinit();
        try query.writer.writeAll("PRAGMA main.index_list(\"");
        for (table) |byte| {
            try query.writer.writeByte(byte);
            if (byte == '"') try query.writer.writeByte(byte);
        }
        try query.writer.writeAll("\")");
        const sql = try allocator.dupeSentinel(u8, query.written(), 0);
        defer allocator.free(sql);

        const previous = self.enterMode(.internal);
        defer self.mode = previous;
        const statement = (try self.prepareSingle(sql)) orelse return false;
        defer _ = sqlite.sqlite3_finalize(statement);
        if (sqlite.sqlite3_column_count(statement) < 5) return false;

        control.start();
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
                    const text = sqlite.sqlite3_column_text(statement, 1) orelse continue;
                    const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 1));
                    if (std.ascii.eqlIgnoreCase(text[0..len], name)) return sqlite.sqlite3_column_int64(statement, 4) != 0;
                },
                sqlite.SQLITE_DONE => return false,
                else => |rc| return diagnosticStepError(rc, control),
            }
        }
    }

    pub fn readIndexCatalog(self: *Db, allocator: std.mem.Allocator, control: *StepControl) IndexCatalogError!IndexCatalog {
        const previous = self.enterMode(.internal);
        defer self.mode = previous;
        const saved_clues = self.clues;
        defer self.clues = saved_clues;

        var tables: std.ArrayList([]const u8) = .empty;
        defer {
            for (tables.items) |name| allocator.free(name);
            tables.deinit(allocator);
        }
        {
            const statement = (try self.prepareSingle(catalog_tables)) orelse return error.IndexCatalogFailed;
            defer _ = sqlite.sqlite3_finalize(statement);
            control.start();
            sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
            defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
            while (true) {
                switch (sqlite.sqlite3_step(statement)) {
                    sqlite.SQLITE_ROW => {
                        const text = sqlite.sqlite3_column_text(statement, 0) orelse continue;
                        const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 0));
                        const name = try allocator.dupe(u8, text[0..len]);
                        tables.append(allocator, name) catch |err| {
                            allocator.free(name);
                            return err;
                        };
                    },
                    sqlite.SQLITE_DONE => break,
                    else => |rc| return diagnosticStepError(rc, control),
                }
            }
        }

        var indexes: std.ArrayList(IndexInfo) = .empty;
        errdefer {
            for (indexes.items) |info| freeIndexInfo(allocator, info);
            indexes.deinit(allocator);
        }
        var rowid_primary_keys: std.ArrayList(RowidPrimaryKey) = .empty;
        errdefer {
            for (rowid_primary_keys.items) |key| {
                allocator.free(key.table);
                allocator.free(key.column);
            }
            rowid_primary_keys.deinit(allocator);
        }

        for (tables.items) |table| {
            var has_primary_key_index = false;
            const list_sql = try catalogPragma(allocator, catalog_pragma_list, table);
            defer allocator.free(list_sql);
            {
                const statement = (try self.prepareSingle(list_sql)) orelse return error.IndexCatalogFailed;
                defer _ = sqlite.sqlite3_finalize(statement);
                if (sqlite.sqlite3_column_count(statement) < 5) return error.IndexCatalogFailed;
                control.start();
                sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
                defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
                while (true) {
                    switch (sqlite.sqlite3_step(statement)) {
                        sqlite.SQLITE_ROW => {
                            const name_text = sqlite.sqlite3_column_text(statement, 1) orelse continue;
                            const name_len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 1));
                            const name = try allocator.dupe(u8, name_text[0..name_len]);
                            const origin = indexOrigin(sqlite.sqlite3_column_text(statement, 3));
                            if (origin == .primary_key) has_primary_key_index = true;
                            self.appendIndex(allocator, &indexes, table, name, origin, sqlite.sqlite3_column_int64(statement, 2) != 0, sqlite.sqlite3_column_int64(statement, 4) != 0, control) catch |err| return err;
                        },
                        sqlite.SQLITE_DONE => break,
                        else => |rc| return diagnosticStepError(rc, control),
                    }
                }
            }
            if (has_primary_key_index) continue;
            const table_info_sql = try catalogPragma(allocator, catalog_pragma_table_info, table);
            defer allocator.free(table_info_sql);
            const statement = (try self.prepareSingle(table_info_sql)) orelse return error.IndexCatalogFailed;
            defer _ = sqlite.sqlite3_finalize(statement);
            if (sqlite.sqlite3_column_count(statement) < 6) return error.IndexCatalogFailed;
            control.start();
            sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
            defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
            while (true) {
                switch (sqlite.sqlite3_step(statement)) {
                    sqlite.SQLITE_ROW => {
                        if (sqlite.sqlite3_column_int64(statement, 5) != 1) continue;
                        if (!std.ascii.eqlIgnoreCase(columnText(statement, 2), "INTEGER")) continue;
                        const column = try allocator.dupe(u8, columnText(statement, 1));
                        const table_name = allocator.dupe(u8, table) catch |err| {
                            allocator.free(column);
                            return err;
                        };
                        rowid_primary_keys.append(allocator, .{ .table = table_name, .column = column }) catch |err| {
                            allocator.free(column);
                            allocator.free(table_name);
                            return err;
                        };
                        break;
                    },
                    sqlite.SQLITE_DONE => break,
                    else => |rc| return diagnosticStepError(rc, control),
                }
            }
        }

        const index_slice = try indexes.toOwnedSlice(allocator);
        errdefer {
            for (index_slice) |info| freeIndexInfo(allocator, info);
            allocator.free(index_slice);
        }
        return .{
            .indexes = index_slice,
            .rowid_primary_keys = try rowid_primary_keys.toOwnedSlice(allocator),
        };
    }

    fn appendIndex(
        self: *Db,
        allocator: std.mem.Allocator,
        indexes: *std.ArrayList(IndexInfo),
        table: []const u8,
        name: []const u8,
        origin: IndexOrigin,
        unique: bool,
        partial: bool,
        control: *StepControl,
    ) IndexCatalogError!void {
        errdefer allocator.free(name);
        var columns: std.ArrayList(IndexColumn) = .empty;
        errdefer {
            for (columns.items) |column| {
                allocator.free(column.name);
                allocator.free(column.collation);
            }
            columns.deinit(allocator);
        }
        var opaque_flag = false;
        const xinfo_sql = try catalogPragma(allocator, catalog_pragma_xinfo, name);
        defer allocator.free(xinfo_sql);
        {
            const statement = (try self.prepareSingle(xinfo_sql)) orelse return error.IndexCatalogFailed;
            defer _ = sqlite.sqlite3_finalize(statement);
            if (sqlite.sqlite3_column_count(statement) >= 6) {
                control.start();
                sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
                defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
                while (true) {
                    switch (sqlite.sqlite3_step(statement)) {
                        sqlite.SQLITE_ROW => {
                            if (sqlite.sqlite3_column_int64(statement, 5) == 0) continue;
                            const key_text = sqlite.sqlite3_column_text(statement, 2);
                            const coll_text = sqlite.sqlite3_column_text(statement, 4);
                            const key_name = if (key_text) |text| text[0..@intCast(sqlite.sqlite3_column_bytes(statement, 2))] else "<expression>";
                            const collation = if (coll_text) |text| text[0..@intCast(sqlite.sqlite3_column_bytes(statement, 4))] else "";
                            if (key_text == null) opaque_flag = true;
                            const column_name = try allocator.dupe(u8, key_name);
                            const column_collation = allocator.dupe(u8, collation) catch |err| {
                                allocator.free(column_name);
                                return err;
                            };
                            columns.append(allocator, .{
                                .name = column_name,
                                .collation = column_collation,
                                .descending = sqlite.sqlite3_column_int64(statement, 3) != 0,
                            }) catch |err| {
                                allocator.free(column_name);
                                allocator.free(column_collation);
                                return err;
                            };
                        },
                        sqlite.SQLITE_DONE => break,
                        else => |rc| return diagnosticStepError(rc, control),
                    }
                }
            } else {
                opaque_flag = true;
            }
        }
        const columns_slice = columns.toOwnedSlice(allocator) catch |err| return err;
        const table_name = allocator.dupe(u8, table) catch |err| {
            for (columns_slice) |column| {
                allocator.free(column.name);
                allocator.free(column.collation);
            }
            allocator.free(columns_slice);
            return err;
        };
        const info: IndexInfo = .{
            .name = name,
            .table = table_name,
            .origin = origin,
            .unique = unique,
            .partial = partial,
            .unreadable = opaque_flag,
            .columns = columns_slice,
        };
        indexes.append(allocator, info) catch |err| {
            allocator.free(info.table);
            for (info.columns) |column| {
                allocator.free(column.name);
                allocator.free(column.collation);
            }
            allocator.free(info.columns);
            return err;
        };
    }

    pub fn tableWarnings(self: *Db, allocator: std.mem.Allocator, table: []const u8, control: *StepControl) !TableWarnings {
        const has_stat1 = try self.diagnosticInt("SELECT count(*) FROM main.sqlite_schema WHERE type = 'table' AND name = 'sqlite_stat1'", &.{}, control) != 0;
        const has_stats = has_stat1 and try self.diagnosticInt("SELECT count(*) FROM main.sqlite_stat1 WHERE tbl = ?1 COLLATE NOCASE AND length(trim(stat)) > 0", &.{.{ .number = 1, .value = .{ .text = table } }}, control) != 0;
        var query: Io.Writer.Allocating = .init(allocator);
        defer query.deinit();
        try query.writer.writeAll("SELECT count(*) FROM (SELECT 1 FROM main.\"");
        for (table) |byte| {
            try query.writer.writeByte(byte);
            if (byte == '"') try query.writer.writeByte(byte);
        }
        try query.writer.writeAll("\" LIMIT 1000)");
        const sql = try allocator.dupeSentinel(u8, query.written(), 0);
        defer allocator.free(sql);
        const rows = try self.diagnosticInt(sql, &.{}, control);
        return .{ .no_analyze_stats = !has_stats, .data_too_small = rows < 1000 };
    }

    fn diagnosticText(self: *Db, allocator: std.mem.Allocator, sql: [:0]const u8, binds: []const BindArg, control: *StepControl) !?[]const u8 {
        const previous = self.enterMode(.user_select);
        const saved = self.clues;
        defer self.mode = previous;
        defer self.clues = saved;
        const statement = try self.prepareSingle(sql) orelse return error.StepFailed;
        defer _ = sqlite.sqlite3_finalize(statement);
        try bindAll(statement, binds);
        control.start();
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        switch (sqlite.sqlite3_step(statement)) {
            sqlite.SQLITE_DONE => return null,
            sqlite.SQLITE_ROW => {},
            else => |rc| return diagnosticStepError(rc, control),
        }
        const text = sqlite.sqlite3_column_text(statement, 0) orelse return null;
        const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 0));
        return try allocator.dupe(u8, text[0..len]);
    }

    fn diagnosticTexts(self: *Db, allocator: std.mem.Allocator, sql: [:0]const u8, binds: []const BindArg, control: *StepControl) !std.ArrayList([]const u8) {
        const previous = self.enterMode(.user_select);
        const saved = self.clues;
        defer self.mode = previous;
        defer self.clues = saved;
        const statement = try self.prepareSingle(sql) orelse return error.StepFailed;
        defer _ = sqlite.sqlite3_finalize(statement);
        try bindAll(statement, binds);

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |item| allocator.free(item);
            out.deinit(allocator);
        }

        control.start();
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        while (true) {
            switch (sqlite.sqlite3_step(statement)) {
                sqlite.SQLITE_ROW => {
                    const text = sqlite.sqlite3_column_text(statement, 0) orelse continue;
                    const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 0));
                    const copy = try allocator.dupe(u8, text[0..len]);
                    errdefer allocator.free(copy);
                    try out.append(allocator, copy);
                },
                sqlite.SQLITE_DONE => return out,
                else => |rc| return diagnosticStepError(rc, control),
            }
        }
    }

    fn diagnosticInt(self: *Db, sql: [:0]const u8, binds: []const BindArg, control: *StepControl) !i64 {
        const previous = self.enterMode(.user_select);
        const saved = self.clues;
        defer self.mode = previous;
        defer self.clues = saved;
        const statement = try self.prepareSingle(sql) orelse return error.StepFailed;
        defer _ = sqlite.sqlite3_finalize(statement);
        try bindAll(statement, binds);
        control.start();
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        const rc = sqlite.sqlite3_step(statement);
        if (rc != sqlite.SQLITE_ROW) return diagnosticStepError(rc, control);
        return sqlite.sqlite3_column_int64(statement, 0);
    }

    pub fn bytesInUse(self: *Db, control: *StepControl) BytesInUseError!u64 {
        const pages = try self.pragmaInt("PRAGMA page_count", control);
        const free = try self.pragmaInt("PRAGMA freelist_count", control);
        const page_size = try self.pragmaInt("PRAGMA page_size", control);
        const used: u64 = @intCast(@max(pages - free, 0));
        const bytes_per_page: u64 = @intCast(@max(page_size, 0));
        return used * bytes_per_page;
    }

    fn pragmaInt(self: *Db, sql: [:0]const u8, control: *StepControl) BytesInUseError!i64 {
        const previous = self.enterMode(.internal);
        defer self.mode = previous;
        const statement = try self.prepareSingle(sql) orelse return error.StepFailed;
        defer _ = sqlite.sqlite3_finalize(statement);
        control.start();
        sqlite.sqlite3_progress_handler(self.connection(), progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(self.connection(), 0, null, null);
        const rc = sqlite.sqlite3_step(statement);
        if (rc != sqlite.SQLITE_ROW) return diagnosticStepError(rc, control);
        return sqlite.sqlite3_column_int64(statement, 0);
    }

    pub fn message(self: *const Db) []const u8 {
        return std.mem.span(sqlite.sqlite3_errmsg(self.connection()));
    }

    pub fn errorCode(self: *const Db) c_int {
        return sqlite.sqlite3_errcode(self.connection());
    }

    pub fn candidateIndexName(self: *const Db) ?[]const u8 {
        if (self.candidate_index_len == 0) return null;
        return self.candidate_index[0..self.candidate_index_len];
    }

    pub fn observedActions(self: *const Db) []const c_int {
        return self.observed[0..self.observed_count];
    }

    fn connection(self: *const Db) *sqlite.sqlite3 {
        return self.handle orelse unreachable;
    }

    fn prepareSingle(self: *Db, sql: [:0]const u8) CheckError!?*sqlite.sqlite3_stmt {
        var statement: ?*sqlite.sqlite3_stmt = null;
        var tail: ?[*:0]const u8 = null;
        const rc = sqlite.sqlite3_prepare_v2(self.connection(), sql.ptr, -1, &statement, &tail);
        if (rc != sqlite.SQLITE_OK) {
            return if (rc == sqlite.SQLITE_AUTH) error.StatementRejected else error.StatementInvalid;
        }
        const first = statement orelse return null;
        errdefer _ = sqlite.sqlite3_finalize(first);

        if (sqlite.sqlite3_stmt_isexplain(first) != 0) return error.StatementRejected;

        if (tail) |rest| {
            var extra: ?*sqlite.sqlite3_stmt = null;
            var extra_tail: ?[*:0]const u8 = null;
            const extra_rc = sqlite.sqlite3_prepare_v2(self.connection(), rest, -1, &extra, &extra_tail);
            if (extra) |second| {
                _ = sqlite.sqlite3_finalize(second);
                return error.MultipleStatements;
            }
            if (extra_rc != sqlite.SQLITE_OK) return error.MultipleStatements;
        }
        return first;
    }

    fn enterMode(self: *Db, mode: Mode) Mode {
        const previous = self.mode;
        self.mode = mode;
        self.seen_create_index = false;
        self.seen_write = false;
        self.candidate_index_len = 0;
        self.observed_count = 0;
        return previous;
    }

    fn record(self: *Db, action_code: c_int) void {
        if (self.observed_count == self.observed.len) return;
        self.observed[self.observed_count] = action_code;
        self.observed_count += 1;
    }

    fn noteClues(self: *Db, action_code: c_int, arg1: ?[*:0]const u8, arg2: ?[*:0]const u8, arg4: ?[*:0]const u8) void {
        if (arg4 != null) self.clues.view_or_cte = true;
        switch (action_code) {
            sqlite.SQLITE_FUNCTION => {
                const name = std.mem.span(arg2 orelse return);
                if (self.clues.nondeterministic_function == null) {
                    self.clues.nondeterministic_function = findName(&nondeterministic_functions, name);
                }
                if (self.clues.order_dependent_function == null) {
                    self.clues.order_dependent_function = findName(&order_dependent_functions, name);
                }
                if (self.clues.time_function == null) {
                    self.clues.time_function = findName(&time_functions, name);
                }
            },
            sqlite.SQLITE_READ => {
                const name = std.mem.span(arg1 orelse return);
                if (self.clues.schema_table != null) return;
                if (findName(&schema_tables, name)) |entry| {
                    self.clues.schema_table = entry;
                } else if (name.len >= stat_table_prefix.len and std.ascii.eqlIgnoreCase(name[0..stat_table_prefix.len], stat_table_prefix)) {
                    self.clues.schema_table = stat_table_prefix ++ "*";
                }
            },
            else => {},
        }
    }

    fn allows(self: *Db, action_code: c_int, arg1: ?[*:0]const u8, arg2: ?[*:0]const u8, arg3: ?[*:0]const u8) bool {
        switch (self.mode) {
            .internal => return true,
            .user_select => return switch (action_code) {
                sqlite.SQLITE_SELECT,
                sqlite.SQLITE_READ,
                sqlite.SQLITE_FUNCTION,
                sqlite.SQLITE_RECURSIVE,
                => true,
                else => false,
            },
            .user_dml => switch (action_code) {
                sqlite.SQLITE_INSERT, sqlite.SQLITE_UPDATE, sqlite.SQLITE_DELETE => {
                    self.seen_write = true;
                    return true;
                },
                sqlite.SQLITE_SELECT, sqlite.SQLITE_READ, sqlite.SQLITE_FUNCTION, sqlite.SQLITE_RECURSIVE => return true,
                else => return false,
            },
            .user_ddl => switch (action_code) {
                sqlite.SQLITE_CREATE_INDEX => {
                    self.seen_create_index = true;
                    if (self.index_target) |capture| {
                        if (capture.table == null) capture.table = capture.allocator.dupe(u8, std.mem.span(arg2 orelse "")) catch null;
                    }
                    const name = std.mem.span(arg1 orelse "");
                    self.candidate_index_len = if (name.len <= self.candidate_index.len) name.len else 0;
                    @memcpy(self.candidate_index[0..self.candidate_index_len], name[0..self.candidate_index_len]);
                    return true;
                },
                sqlite.SQLITE_READ, sqlite.SQLITE_FUNCTION => return true,
                sqlite.SQLITE_INSERT => return isSchemaTable(arg1) and isMainSchema(arg3),
                sqlite.SQLITE_REINDEX => return self.seen_create_index,
                else => return false,
            },
            .user_migration => switch (action_code) {
                sqlite.SQLITE_CREATE_INDEX,
                sqlite.SQLITE_DROP_INDEX,
                sqlite.SQLITE_SELECT,
                sqlite.SQLITE_READ,
                sqlite.SQLITE_FUNCTION,
                sqlite.SQLITE_REINDEX,
                => return true,
                sqlite.SQLITE_CREATE_TABLE => return isMainSchema(arg3),
                sqlite.SQLITE_ALTER_TABLE => return isMainSchema(arg1),
                sqlite.SQLITE_INSERT => return isMainSchema(arg3) and (isSchemaTable(arg1) or isStatTable(arg1)),
                sqlite.SQLITE_DELETE, sqlite.SQLITE_UPDATE => return (isMainSchema(arg3) or isTempSchema(arg3)) and (isSchemaTable(arg1) or isStatTable(arg1)),
                else => return false,
            },
        }
    }
};

pub const BindValue = union(enum) {
    int: i64,
    real: f64,
    text: []const u8,
    null,
};

pub const BindArg = struct {
    number: u64,
    value: BindValue,
};

pub const BindError = error{
    ParameterCountMismatch,
    BindNumberOutOfRange,
    DuplicateBindNumber,
    MissingBindNumber,
    BindFailed,
};

pub fn bindAll(statement: *sqlite.sqlite3_stmt, binds: []const BindArg) BindError!void {
    const count: u32 = @intCast(sqlite.sqlite3_bind_parameter_count(statement));
    std.debug.assert(count <= sqlite.max_parameter_number);

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

pub const PlanKind = enum {
    scan,
    search,
    temp_btree,
    other,
};

pub const PlanLabel = struct {
    kind: PlanKind,
    covering: bool = false,
    automatic: bool = false,
};

pub const PlanRow = struct {
    id: i64,
    parent: i64,
    label: PlanLabel,
    detail: []const u8,
};

pub const Plan = struct {
    rows: []PlanRow,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        for (self.rows) |row| allocator.free(row.detail);
        allocator.free(self.rows);
    }
};

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

fn planMentionsAnyIndex(plan: Plan) bool {
    for (plan.rows) |row| {
        if (std.mem.indexOf(u8, row.detail, "INDEX ") != null) return true;
    }
    return false;
}

fn planUsesIndex(plan: Plan, names: []const []const u8, wanted: []const u8) bool {
    for (plan.rows) |row| {
        const used = usedIndexName(row.detail, names) orelse continue;
        if (std.ascii.eqlIgnoreCase(used, wanted)) return true;
    }
    return false;
}

pub fn usedIndexName(detail: []const u8, names: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (names) |name| {
        if (!detailUsesIndex(detail, name)) continue;
        if (best == null or name.len > best.?.len) best = name;
    }
    return best;
}

fn detailUsesIndex(detail: []const u8, name: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, detail, offset, "INDEX ")) |at| {
        if (indexReference(detail[at + "INDEX ".len ..], name)) return true;
        offset = at + "INDEX ".len;
    }
    return false;
}

fn indexReference(rest: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, name)) return false;
    if (name.len == rest.len) return true;
    return rest[name.len] == ' ' and name.len + 1 < rest.len and rest[name.len + 1] == '(';
}

pub const Counters = struct {
    rows_read: u32,
    rows_written: u32,
    fullscan_steps: u32,
    vm_steps: u32,
    sort_ops: u32,
    autoindex_rows: u32,
};

pub fn statementCounters(statement: *sqlite.sqlite3_stmt) Counters {
    return .{
        .rows_read = readCounter(statement, sqlite.LIBSQL_STMTSTATUS_ROWS_READ),
        .rows_written = readCounter(statement, sqlite.LIBSQL_STMTSTATUS_ROWS_WRITTEN),
        .fullscan_steps = readCounter(statement, sqlite.SQLITE_STMTSTATUS_FULLSCAN_STEP),
        .vm_steps = readCounter(statement, sqlite.SQLITE_STMTSTATUS_VM_STEP),
        .sort_ops = readCounter(statement, sqlite.SQLITE_STMTSTATUS_SORT),
        .autoindex_rows = readCounter(statement, sqlite.SQLITE_STMTSTATUS_AUTOINDEX),
    };
}

fn readCounter(statement: *sqlite.sqlite3_stmt, op: c_int) u32 {
    return @bitCast(sqlite.sqlite3_stmt_status(statement, op, 0));
}

fn takeCounter(statement: *sqlite.sqlite3_stmt, op: c_int) u32 {
    return @bitCast(sqlite.sqlite3_stmt_status(statement, op, 1));
}

pub fn takeCounters(statement: *sqlite.sqlite3_stmt) Counters {
    return .{
        .rows_read = takeCounter(statement, sqlite.LIBSQL_STMTSTATUS_ROWS_READ),
        .rows_written = takeCounter(statement, sqlite.LIBSQL_STMTSTATUS_ROWS_WRITTEN),
        .fullscan_steps = takeCounter(statement, sqlite.SQLITE_STMTSTATUS_FULLSCAN_STEP),
        .vm_steps = takeCounter(statement, sqlite.SQLITE_STMTSTATUS_VM_STEP),
        .sort_ops = takeCounter(statement, sqlite.SQLITE_STMTSTATUS_SORT),
        .autoindex_rows = takeCounter(statement, sqlite.SQLITE_STMTSTATUS_AUTOINDEX),
    };
}

pub fn resetStatement(statement: *sqlite.sqlite3_stmt) StepError!void {
    if (sqlite.sqlite3_reset(statement) != sqlite.SQLITE_OK) return error.StepFailed;
}

pub fn columnCount(statement: *sqlite.sqlite3_stmt) c_int {
    return sqlite.sqlite3_column_count(statement);
}

pub fn applyCreateIndex(path: [:0]const u8, sql: [:0]const u8, control: *StepControl, detail: *SnapshotDetail) ApplyError!void {
    detail.len = 0;
    detail.error_code = 0;
    var handle: ?*sqlite.sqlite3 = null;
    const open_rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_NOFOLLOW, null);
    const conn = handle orelse return error.OpenFailed;
    var closed = false;
    defer if (!closed) {
        _ = sqlite.sqlite3_close(conn);
    };
    if (open_rc != sqlite.SQLITE_OK) {
        detail.capture(conn);
        return error.OpenFailed;
    }

    var target: Db = .{ .handle = conn };
    if (!disableDoubleQuotedStrings(conn)) return error.GuardSetupFailed;
    if (sqlite.sqlite3_set_authorizer(conn, authorizer, &target) != sqlite.SQLITE_OK) return error.GuardSetupFailed;

    {
        const previous = target.enterMode(.user_ddl);
        defer target.mode = previous;

        const statement = (target.prepareSingle(sql) catch |err| {
            if (sqlite.sqlite3_errcode(conn) != sqlite.SQLITE_OK) detail.capture(conn);
            return err;
        }) orelse return error.EmptyStatement;
        defer _ = sqlite.sqlite3_finalize(statement);
        if (!target.seen_create_index or sqlite.sqlite3_stmt_readonly(statement) != 0) return error.StatementNotCreateIndex;

        control.start();
        sqlite.sqlite3_progress_handler(conn, progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(conn, 0, null, null);
        const step_rc = sqlite.sqlite3_step(statement);
        if (step_rc != sqlite.SQLITE_DONE) {
            if (step_rc == sqlite.SQLITE_INTERRUPT) {
                if (control.reason) |reason| return switch (reason) {
                    .timeout => error.Timeout,
                    .signal => error.Interrupted,
                };
            }
            detail.capture(conn);
            return error.ApplyFailed;
        }
    }

    closed = true;
    if (sqlite.sqlite3_close(conn) != sqlite.SQLITE_OK) {
        detail.capture(conn);
        _ = sqlite.sqlite3_close(conn);
        return error.ApplyFailed;
    }
}

pub fn parseMigration(allocator: std.mem.Allocator, sql: [:0]const u8, detail: *SnapshotDetail) (MigrationError || std.mem.Allocator.Error)![]MigrationStatement {
    detail.len = 0;
    detail.error_code = 0;
    detail.statement_index = 0;

    var statements: std.ArrayList(MigrationStatement) = .empty;
    errdefer {
        for (statements.items) |statement| allocator.free(statement.sql);
        statements.deinit(allocator);
    }

    var start: usize = 0;
    while (sql_lexer.statementEnd(sql, start)) |end| {
        try appendMigrationStatement(allocator, &statements, sql[start..end], detail);
        start = end + 1;
    }
    try appendMigrationStatement(allocator, &statements, sql[start..sql.len], detail);

    if (statements.items.len == 0) return error.MigrationEmpty;
    detail.statement_index = 0;
    return statements.toOwnedSlice(allocator);
}

fn appendMigrationStatement(allocator: std.mem.Allocator, statements: *std.ArrayList(MigrationStatement), span: []const u8, detail: *SnapshotDetail) (MigrationError || std.mem.Allocator.Error)!void {
    const start = sql_lexer.skipTrivia(span, 0);
    if (start == span.len) return;
    const text = std.mem.trimEnd(u8, span[start..], " \t\r\n");
    if (text.len == 0) return;
    const kind = classifyMigrationStatement(text) orelse {
        detail.statement_index = statements.items.len + 1;
        return error.MigrationStatementNotAllowed;
    };
    const owned = try allocator.dupeSentinel(u8, text, 0);
    errdefer allocator.free(owned);
    try statements.append(allocator, .{ .kind = kind, .sql = owned });
}

pub fn applyMigration(path: [:0]const u8, statements: []const MigrationStatement, control: *StepControl, detail: *SnapshotDetail) MigrationApplyError!void {
    detail.len = 0;
    detail.error_code = 0;
    detail.statement_index = 0;

    var handle: ?*sqlite.sqlite3 = null;
    const open_rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_NOFOLLOW, null);
    const conn = handle orelse return error.OpenFailed;
    var closed = false;
    defer if (!closed) {
        _ = sqlite.sqlite3_close(conn);
    };
    if (open_rc != sqlite.SQLITE_OK) {
        detail.capture(conn);
        return error.OpenFailed;
    }

    var target: Db = .{ .handle = conn };
    if (!disableDoubleQuotedStrings(conn)) return error.GuardSetupFailed;
    if (sqlite.sqlite3_set_authorizer(conn, authorizer, &target) != sqlite.SQLITE_OK) return error.GuardSetupFailed;

    {
        const previous = target.enterMode(.user_migration);
        defer target.mode = previous;
        sqlite.sqlite3_progress_handler(conn, progress_opcodes, progressHandler, control);
        defer sqlite.sqlite3_progress_handler(conn, 0, null, null);

        for (statements, 0..) |migration_statement, index| {
            detail.statement_index = index + 1;

            var statement: ?*sqlite.sqlite3_stmt = null;
            var tail: ?[*:0]const u8 = null;
            const prepare_rc = sqlite.sqlite3_prepare_v2(conn, migration_statement.sql.ptr, -1, &statement, &tail);
            if (prepare_rc != sqlite.SQLITE_OK) {
                detail.capture(conn);
                return error.MigrationApplyFailed;
            }
            const prepared = statement orelse return error.MigrationApplyFailed;

            const step_rc = blk: {
                defer _ = sqlite.sqlite3_finalize(prepared);
                if (sqlite.sqlite3_stmt_isexplain(prepared) != 0 or sqlite.sqlite3_stmt_readonly(prepared) != 0) return error.MigrationApplyFailed;
                control.start();
                const rc = sqlite.sqlite3_step(prepared);
                if (rc != sqlite.SQLITE_DONE) detail.capture(conn);
                break :blk rc;
            };
            if (step_rc != sqlite.SQLITE_DONE) {
                if (step_rc == sqlite.SQLITE_INTERRUPT) {
                    if (control.reason) |reason| return switch (reason) {
                        .timeout => error.Timeout,
                        .signal => error.Interrupted,
                    };
                }
                return error.MigrationApplyFailed;
            }
        }
    }

    closed = true;
    if (sqlite.sqlite3_close(conn) != sqlite.SQLITE_OK) {
        detail.capture(conn);
        _ = sqlite.sqlite3_close(conn);
        return error.MigrationApplyFailed;
    }
    detail.statement_index = 0;
}

fn startsWithWriteKeyword(sql: []const u8) bool {
    const start = sql_lexer.skipTrivia(sql, 0);
    const first = sql_lexer.keywordAt(sql, start);
    return std.ascii.eqlIgnoreCase(first.text, "insert") or
        std.ascii.eqlIgnoreCase(first.text, "replace") or
        std.ascii.eqlIgnoreCase(first.text, "update") or
        std.ascii.eqlIgnoreCase(first.text, "delete") or
        std.ascii.eqlIgnoreCase(first.text, "with");
}

fn classifyMigrationStatement(sql: []const u8) ?MigrationKind {
    var i = sql_lexer.skipTrivia(sql, 0);
    const first = sql_lexer.keywordAt(sql, i);
    if (std.ascii.eqlIgnoreCase(first.text, "create")) {
        i = sql_lexer.skipTrivia(sql, first.end);
        const second = sql_lexer.keywordAt(sql, i);
        if (std.ascii.eqlIgnoreCase(second.text, "unique")) {
            i = sql_lexer.skipTrivia(sql, second.end);
            const third = sql_lexer.keywordAt(sql, i);
            return if (std.ascii.eqlIgnoreCase(third.text, "index")) .create_index else null;
        }
        if (std.ascii.eqlIgnoreCase(second.text, "index")) return .create_index;
        if (std.ascii.eqlIgnoreCase(second.text, "table")) return if (createTableHasColumnList(sql, second.end)) .create_table else null;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(first.text, "drop")) {
        i = sql_lexer.skipTrivia(sql, first.end);
        const second = sql_lexer.keywordAt(sql, i);
        return if (std.ascii.eqlIgnoreCase(second.text, "index")) .drop_index else null;
    }
    if (std.ascii.eqlIgnoreCase(first.text, "alter")) {
        i = sql_lexer.skipTrivia(sql, first.end);
        const second = sql_lexer.keywordAt(sql, i);
        if (!std.ascii.eqlIgnoreCase(second.text, "table")) return null;
        i = sql_lexer.skipTrivia(sql, skipMigrationTableName(sql, second.end));
        const third = sql_lexer.keywordAt(sql, i);
        if (std.ascii.eqlIgnoreCase(third.text, "add") or
            std.ascii.eqlIgnoreCase(third.text, "rename") or
            std.ascii.eqlIgnoreCase(third.text, "drop")) return .alter_table;
        return null;
    }
    return null;
}

fn skipMigrationTableName(sql: []const u8, start: usize) usize {
    var i = sql_lexer.skipTrivia(sql, start);
    if (i >= sql.len) return i;
    i = skipMigrationName(sql, i);
    const after = sql_lexer.skipTrivia(sql, i);
    if (after < sql.len and sql[after] == '.') {
        i = sql_lexer.skipTrivia(sql, after + 1);
        if (i >= sql.len) return i;
        return skipMigrationName(sql, i);
    }
    return i;
}

fn skipMigrationName(sql: []const u8, start: usize) usize {
    switch (sql[start]) {
        '\'', '"', '`', '[' => return sql_lexer.quotedSpan(sql, start).end,
        else => return sql_lexer.wordAt(sql, start).end,
    }
}

fn createTableHasColumnList(sql: []const u8, start: usize) bool {
    var i = start;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'', '"', '`', '[' => i = sql_lexer.quotedSpan(sql, i).end,
            '-', '/' => i = sql_lexer.commentSpan(sql, i).end,
            '(' => return true,
            ';' => return false,
            else => {
                const word = sql_lexer.wordAt(sql, i);
                if (word.end == i) {
                    i += 1;
                    continue;
                }
                i = word.end;
                if (std.ascii.eqlIgnoreCase(word.text, "as")) return false;
            },
        }
    }
    return false;
}

pub fn mentionsLimitOrOffset(sql: []const u8) bool {
    var i: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'', '"', '`', '[' => i = sql_lexer.quotedSpan(sql, i).end,
            '-', '/' => i = sql_lexer.commentSpan(sql, i).end,
            else => {
                if (!sql_lexer.isWordByte(c) and c != ':' and c != '@') {
                    i += 1;
                    continue;
                }
                const start = i;
                i += 1;
                i = sql_lexer.wordAt(sql, i).end;
                const word = sql[start..i];
                if (std.ascii.eqlIgnoreCase(word, "limit") or std.ascii.eqlIgnoreCase(word, "offset")) return true;
            },
        }
    }
    return false;
}

fn disableDoubleQuotedStrings(conn: *sqlite.sqlite3) bool {
    return sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_DQS_DDL, @as(c_int, 0), @as(?*c_int, null)) == sqlite.SQLITE_OK and
        sqlite.sqlite3_db_config(conn, sqlite.SQLITE_DBCONFIG_DQS_DML, @as(c_int, 0), @as(?*c_int, null)) == sqlite.SQLITE_OK;
}

fn isSchemaTable(name: ?[*:0]const u8) bool {
    const text = std.mem.span(name orelse return false);
    return std.mem.eql(u8, text, "sqlite_master") or std.mem.eql(u8, text, "sqlite_temp_master");
}

fn isMainSchema(name: ?[*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(name orelse return false), "main");
}

fn isTempSchema(name: ?[*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(name orelse return false), "temp");
}

fn isStatTable(name: ?[*:0]const u8) bool {
    const text = std.mem.span(name orelse return false);
    for ([_][]const u8{ "sqlite_stat1", "sqlite_stat2", "sqlite_stat3", "sqlite_stat4" }) |stat| {
        if (std.ascii.eqlIgnoreCase(text, stat)) return true;
    }
    return false;
}

fn authorizer(
    user_data: ?*anyopaque,
    action_code: c_int,
    arg1: ?[*:0]const u8,
    arg2: ?[*:0]const u8,
    arg3: ?[*:0]const u8,
    arg4: ?[*:0]const u8,
) callconv(.c) c_int {
    const self: *Db = @ptrCast(@alignCast(user_data orelse return sqlite.SQLITE_DENY));
    self.record(action_code);
    if (!self.allows(action_code, arg1, arg2, arg3)) return sqlite.SQLITE_DENY;
    if (self.mode == .user_select or self.mode == .user_dml) self.noteClues(action_code, arg1, arg2, arg4);
    return sqlite.SQLITE_OK;
}

fn progressHandler(user_data: ?*anyopaque) callconv(.c) c_int {
    const control: *StepControl = @ptrCast(@alignCast(user_data orelse return 1));
    return if (control.shouldStop()) 1 else 0;
}

const testing = std.testing;

const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
    \\CREATE INDEX existing_idx ON t(a);
;

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

    try testing.expectError(error.StatementInvalid, db.checkSelect("SELECT \"nope\" FROM t"));
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX idx_dqs ON t(\"nope\")"));
    try db.checkSelect("SELECT \"a\" FROM t");
    try db.checkSelect("SELECT 'nope' FROM t");
}

test "explain statements are rejected" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

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

fn prepareBoundSelect(db: *Db, sql: [:0]const u8, binds: []const BindArg) !*sqlite.sqlite3_stmt {
    const statement = try db.prepareSelect(sql);
    errdefer _ = sqlite.sqlite3_finalize(statement);
    try bindAll(statement, binds);
    return statement;
}

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

    try testing.expectEqual(
        @as(c_int, @intCast(sqlite.max_parameter_number)),
        sqlite.sqlite3_limit(db.handle, sqlite.SQLITE_LIMIT_VARIABLE_NUMBER, -1),
    );
}

test "stepping a select that SQLite re-prepares keeps working" {
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
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control, null));
    try testing.expectEqual(Mode.internal, db.mode);
}

const heavy_select: [:0]const u8 =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c";

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
    try testing.expectError(error.Timeout, db.stepAll(statement, &control, null));
    try testing.expectEqual(InterruptReason.timeout, control.reason.?);

    cancel.store(true, .monotonic);
    const probe = try prepareBoundSelect(&db, bounded_select, &.{});
    defer _ = sqlite.sqlite3_finalize(probe);
    try testing.expectEqual(sqlite.SQLITE_ROW, sqlite.sqlite3_step(probe));
}

test "a heavy select inside the time limit finishes (positive control)" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, bounded_select, &.{});
    defer _ = sqlite.sqlite3_finalize(statement);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 60_000, &cancel);
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control, null));
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
    try testing.expectError(error.Interrupted, db.stepAll(statement, &control, null));
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
    try testing.expectEqual(@as(u64, 1), try db.stepAll(statement, &control, null));
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

const plan_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO t SELECT x, 'v' || x FROM c;
    \\CREATE INDEX idx_b ON t(b);
    \\CREATE TABLE u(x INTEGER, y TEXT);
    \\INSERT INTO u SELECT a, b FROM t;
;

fn findRow(plan: Plan, prefix: []const u8) ?PlanRow {
    for (plan.rows) |row| {
        if (std.mem.startsWith(u8, row.detail, prefix)) return row;
    }
    return null;
}

fn runCounters(db: *Db, sql: [:0]const u8, binds: []const BindArg) !Counters {
    const statement = try prepareBoundSelect(db, sql, binds);
    defer _ = sqlite.sqlite3_finalize(statement);
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    _ = try db.stepAll(statement, &control, null);
    return statementCounters(statement);
}

test "classify detail splits main kind and attributes" {
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
        .{ .detail = "SCAN CONSTANT ROW", .label = .{ .kind = .scan } },
        .{ .detail = "BLOOM FILTER ON u (x=?)", .label = .{ .kind = .other } },
        .{ .detail = "MULTI-INDEX OR", .label = .{ .kind = .other } },
        .{ .detail = "CO-ROUTINE c", .label = .{ .kind = .other } },
        .{ .detail = "LIST SUBQUERY 1", .label = .{ .kind = .other } },
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

test "plan detail matches the catalog index name without guessing its boundary" {
    const names = [_][]const u8{ "idx", "idx (x)", "idx USING suffix", "(odd)", "idx_long" };
    const cases = [_]struct { detail: []const u8, name: ?[]const u8 }{
        .{ .detail = "SCAN t USING INDEX idx", .name = "idx" },
        .{ .detail = "SCAN t USING COVERING INDEX idx (x)", .name = "idx (x)" },
        .{ .detail = "SEARCH t USING COVERING INDEX idx (x) (a=?)", .name = "idx (x)" },
        .{ .detail = "SCAN t USING COVERING INDEX idx USING suffix", .name = "idx USING suffix" },
        .{ .detail = "SCAN t USING COVERING INDEX (odd)", .name = "(odd)" },
        .{ .detail = "SCAN t USING COVERING INDEX idx_long", .name = "idx_long" },
        .{ .detail = "SEARCH t USING INDEX idx (a=?)", .name = "idx" },
        .{ .detail = "SEARCH t USING INTEGER PRIMARY KEY (rowid=?)", .name = null },
        .{ .detail = "SEARCH t USING AUTOMATIC PARTIAL COVERING INDEX (x=?)", .name = null },
        .{ .detail = "SCAN t", .name = null },
        .{ .detail = "USE TEMP B-TREE FOR ORDER BY", .name = null },
    };
    for (cases) |case| {
        const name = usedIndexName(case.detail, &names);
        const rows = [_]PlanRow{.{ .id = 1, .parent = 0, .label = .{ .kind = .scan }, .detail = case.detail }};
        const plan: Plan = .{ .rows = @constCast(&rows) };
        if (case.name) |expected| {
            try testing.expect(name != null);
            try testing.expectEqualStrings(expected, name.?);
            try testing.expect(planUsesIndex(plan, &names, expected));
        } else {
            try testing.expect(name == null);
        }
    }
    const longer = [_]PlanRow{.{ .id = 1, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t USING COVERING INDEX idx_long" }};
    try testing.expect(!planUsesIndex(.{ .rows = @constCast(&longer) }, &names, "idx"));
    const parenthesized = [_]PlanRow{.{ .id = 1, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t USING COVERING INDEX idx (x)" }};
    try testing.expect(!planUsesIndex(.{ .rows = @constCast(&parenthesized) }, &names, "idx"));
}

const index_catalog_schema: [:0]const u8 =
    \\CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c TEXT UNIQUE);
    \\CREATE INDEX ix_a ON t(a);
    \\CREATE INDEX ix_ab ON t(a, b);
    \\CREATE INDEX ix_p ON t(a) WHERE b = 'x';
    \\CREATE INDEX ix_desc ON t(a DESC);
    \\CREATE INDEX ix_nocase ON t(c COLLATE NOCASE);
    \\CREATE INDEX ix_expr ON t(lower(c));
    \\CREATE TABLE wr(k TEXT, v INTEGER, PRIMARY KEY(k)) WITHOUT ROWID;
    \\CREATE INDEX ix_wr_v ON wr(v);
    \\CREATE TABLE d(x INTEGER PRIMARY KEY DESC, v INTEGER);
;

fn catalogIndex(catalog: IndexCatalog, name: []const u8) ?IndexInfo {
    for (catalog.indexes) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    return null;
}

test "the index catalog reports the key columns, origin, and rowid primary key" {
    var fixture = try Fixture.initWithSchema(testing.allocator, index_catalog_schema);
    defer fixture.deinit();
    var database: Db = .{};
    try database.openReadOnly(fixture.path);
    defer database.close() catch unreachable;

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    const catalog = try database.readIndexCatalog(testing.allocator, &control);
    defer catalog.deinit(testing.allocator);

    const ab = catalogIndex(catalog, "ix_ab") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(IndexOrigin.created, ab.origin);
    try testing.expect(!ab.unique);
    try testing.expect(!ab.partial);
    try testing.expect(!ab.unreadable);
    try testing.expectEqualStrings("t", ab.table);
    try testing.expectEqual(@as(usize, 2), ab.columns.len);
    try testing.expectEqualStrings("a", ab.columns[0].name);
    try testing.expectEqualStrings("BINARY", ab.columns[0].collation);
    try testing.expect(!ab.columns[0].descending);
    try testing.expectEqualStrings("b", ab.columns[1].name);

    const nocase = catalogIndex(catalog, "ix_nocase") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("NOCASE", nocase.columns[0].collation);

    const desc = catalogIndex(catalog, "ix_desc") orelse return error.TestUnexpectedResult;
    try testing.expect(desc.columns[0].descending);

    const partial = catalogIndex(catalog, "ix_p") orelse return error.TestUnexpectedResult;
    try testing.expect(partial.partial);
    try testing.expectEqual(@as(usize, 1), partial.columns.len);

    const expression = catalogIndex(catalog, "ix_expr") orelse return error.TestUnexpectedResult;
    try testing.expect(expression.unreadable);
    try testing.expectEqual(@as(usize, 1), expression.columns.len);
    try testing.expectEqualStrings("<expression>", expression.columns[0].name);

    const unique = catalogIndex(catalog, "sqlite_autoindex_t_1") orelse return error.TestUnexpectedResult;
    try testing.expect(unique.unique);
    try testing.expectEqual(IndexOrigin.unique_constraint, unique.origin);

    const primary = catalogIndex(catalog, "sqlite_autoindex_wr_1") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(IndexOrigin.primary_key, primary.origin);
    try testing.expect(primary.unique);
    try testing.expectEqualStrings("k", primary.columns[0].name);

    try testing.expectEqual(@as(usize, 1), catalog.rowid_primary_keys.len);
    try testing.expectEqualStrings("t", catalog.rowid_primary_keys[0].table);
    try testing.expectEqualStrings("id", catalog.rowid_primary_keys[0].column);

    const desc_primary = catalogIndex(catalog, "sqlite_autoindex_d_1") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(IndexOrigin.primary_key, desc_primary.origin);
}

fn catalogWithAllocator(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    var database: Db = .{};
    try database.openReadOnly(path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    const catalog = try database.readIndexCatalog(allocator, &control);
    catalog.deinit(allocator);
}

test "the index catalog frees every allocation when memory runs out" {
    var fixture = try Fixture.initWithSchema(testing.allocator, index_catalog_schema);
    defer fixture.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, catalogWithAllocator, .{fixture.path});
}

const partial_index_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO t SELECT x, 'v' || x FROM c;
    \\CREATE INDEX idx_part ON t(b) WHERE a = 1;
    \\CREATE INDEX idx_b ON t(b);
    \\CREATE TABLE u(x INTEGER, y TEXT);
    \\INSERT INTO u VALUES (1, 'p'), (2, 'q');
    \\CREATE INDEX idx_u_notnull ON u(y) WHERE x IS NOT NULL;
    \\CREATE TABLE "odd""table"(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO "odd""table" SELECT x, 'v' || x FROM c;
    \\CREATE INDEX "idx part" ON "odd""table"(b) WHERE a = 1;
    \\CREATE TABLE v(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO v SELECT x, 'v' || x FROM c;
    \\CREATE INDEX "idx USING suffix" ON v(b) WHERE a = 1;
    \\CREATE TABLE w(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
    \\INSERT INTO w SELECT x, 'v' || x FROM c;
    \\CREATE INDEX "(odd)" ON w(b) WHERE a = 1;
;

fn findBindDependent(db: *Db, sql: [:0]const u8, binds: []const BindArg) !?[]const u8 {
    const plan = try db.explainPlan(testing.allocator, sql, binds);
    defer plan.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    return db.findBindDependentPartialIndex(testing.allocator, plan, sql, binds, &control);
}

test "a partial index counts as bind-dependent only when the unknown values drop it" {
    var fixture = try Fixture.initWithSchema(testing.allocator, partial_index_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const matched = try findBindDependent(&db, "SELECT b FROM t WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 1 } }});
    defer if (matched) |name| testing.allocator.free(name);
    try testing.expect(matched != null);
    try testing.expectEqualStrings("idx_part", matched.?);

    try testing.expect(try findBindDependent(&db, "SELECT b FROM t WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 2 } }}) == null);
    try testing.expect(try findBindDependent(&db, "SELECT b FROM t WHERE a = ?1", &.{.{ .number = 1, .value = .null }}) == null);
    try testing.expect(try findBindDependent(&db, "SELECT b FROM t WHERE a = 1", &.{}) == null);

    try testing.expect(try findBindDependent(&db, "SELECT b FROM t WHERE a = 1 AND b LIKE ?1", &.{.{ .number = 1, .value = .{ .text = "v1%" } }}) == null);
    try testing.expect(try findBindDependent(&db, "SELECT y FROM u WHERE x = ?1", &.{.{ .number = 1, .value = .{ .int = 1 } }}) == null);
    try testing.expect(try findBindDependent(&db, "SELECT a FROM t WHERE b LIKE ?1", &.{.{ .number = 1, .value = .{ .text = "v1%" } }}) == null);

    const quoted = try findBindDependent(&db, "SELECT b FROM \"odd\"\"table\" WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 1 } }});
    defer if (quoted) |name| testing.allocator.free(name);
    try testing.expect(quoted != null);
    try testing.expectEqualStrings("idx part", quoted.?);

    const spaced = try findBindDependent(&db, "SELECT b FROM v WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 1 } }});
    defer if (spaced) |name| testing.allocator.free(name);
    try testing.expect(spaced != null);
    try testing.expectEqualStrings("idx USING suffix", spaced.?);

    const parenthesized = try findBindDependent(&db, "SELECT b FROM w WHERE a = ?1", &.{.{ .number = 1, .value = .{ .int = 1 } }});
    defer if (parenthesized) |name| testing.allocator.free(name);
    try testing.expect(parenthesized != null);
    try testing.expectEqualStrings("(odd)", parenthesized.?);
}

test "a cancelled control drops the bind-dependent partial index warning" {
    var fixture = try Fixture.initWithSchema(testing.allocator, partial_index_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const sql = "SELECT b FROM t WHERE a = ?1";
    const binds: []const BindArg = &.{.{ .number = 1, .value = .{ .int = 1 } }};
    const plan = try db.explainPlan(testing.allocator, sql, binds);
    defer plan.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(true);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expect(try db.findBindDependentPartialIndex(testing.allocator, plan, sql, binds, &control) == null);

    var live = std.atomic.Value(bool).init(false);
    var live_control = StepControl.init(testing.io, 0, &live);
    const recovered = try db.findBindDependentPartialIndex(testing.allocator, plan, sql, binds, &live_control);
    defer if (recovered) |name| testing.allocator.free(name);
    try testing.expect(recovered != null);
    try testing.expectEqualStrings("idx_part", recovered.?);
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

    try testing.expectEqual(@as(u32, 999), scan.fullscan_steps);
    try testing.expectEqual(@as(u32, 0), search.fullscan_steps);
    try testing.expect(search.vm_steps < scan.vm_steps);
    try testing.expectEqual(@as(u32, 0), scan.sort_ops);
    try testing.expectEqual(@as(u32, 0), scan.autoindex_rows);

    const joined = try runCounters(&db, "SELECT a FROM t JOIN u ON u.x = t.a", &.{});
    try testing.expect(joined.autoindex_rows > 0);
    const sorted = try runCounters(&db, "SELECT a FROM t ORDER BY a", &.{});
    try testing.expect(sorted.sort_ops > 0);
}

test "explaining does not change the execution counters" {
    var fixture = try Fixture.initWithSchema(testing.allocator, plan_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const sql = "SELECT a FROM t WHERE a IN (SELECT x FROM u WHERE x < ?1)";
    const binds: []const BindArg = &.{.{ .number = 1, .value = .{ .int = 100 } }};
    const plain = try runCounters(&db, sql, binds);

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
        _ = try db.stepAll(reused, &control, null);
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
    _ = try db.stepAll(statement, &control, null);

    try testing.expect(plan.rows.len > 0);
    try testing.expectEqual(plain, statementCounters(statement));
}

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
    const writer = try openTestWriter(fixture.source, wal_writer_sql);
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_close(writer));
    try testing.expect(!fixture.exists("source.db-wal"));
    const main_before = try fixture.read("source.db");
    defer testing.allocator.free(main_before);
    try testing.expectEqual(@as(u8, 2), main_before[18]);

    try fixture.snapshot();

    try testing.expectEqual(@as(i64, 1000), try SnapshotFixture.countRows(fixture.dest));
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

    const writer = try openTestWriter(fixture.source, "BEGIN EXCLUSIVE; INSERT INTO t VALUES (9, 'w');");
    defer _ = sqlite.sqlite3_close(writer);

    var detail: SnapshotDetail = .{};
    try testing.expectError(error.SourceBusy, source.copySnapshotTo(fixture.dest, &detail));
    try testing.expect(detail.text().len > 0);
    try fixture.tmp.dir.deleteFile(testing.io, "baseline.db");
}

test "applyCreateIndex creates the index and the variant opens read-only afterwards" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    var detail: SnapshotDetail = .{};
    try applyCreateIndex(fixture.path, "CREATE INDEX idx_new ON t(b)", &control, &detail);

    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;
    const plan = try db.explainPlan(testing.allocator, "SELECT a FROM t WHERE b = ?1", &.{
        .{ .number = 1, .value = .{ .text = "x" } },
    });
    defer plan.deinit(testing.allocator);
    try testing.expect(findRow(plan, "SEARCH t USING INDEX idx_new (b=?)") != null);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "fixture.db-journal", .{}));
}

test "applyCreateIndex keeps the ddl allowlist" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    var detail: SnapshotDetail = .{};
    try testing.expectError(error.StatementRejected, applyCreateIndex(fixture.path, "DROP TABLE t", &control, &detail));
    try testing.expectError(error.MultipleStatements, applyCreateIndex(fixture.path, "CREATE INDEX i1 ON t(b); DROP TABLE t", &control, &detail));
    try testing.expectError(error.StatementInvalid, applyCreateIndex(fixture.path, "CREATE INDEX temp.i2 ON t(b)", &control, &detail));
    try testing.expectError(error.StatementNotCreateIndex, applyCreateIndex(fixture.path, "CREATE INDEX IF NOT EXISTS existing_idx ON t(b)", &control, &detail));

    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;
    try testing.expectEqual(@as(i64, 3), try queryInt(&db, "SELECT count(*) FROM t"));
}

test "applyCreateIndex rejects a unique index on duplicate rows" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    var detail: SnapshotDetail = .{};
    try testing.expectError(error.ApplyFailed, applyCreateIndex(fixture.path, "CREATE UNIQUE INDEX u_a ON t(a)", &control, &detail));
    try testing.expect(std.mem.indexOf(u8, detail.text(), "UNIQUE constraint failed") != null);
    try testing.expectEqual(sqlite.SQLITE_CONSTRAINT, detail.error_code);

    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;
    try testing.expectEqual(@as(i64, 0), try queryInt(&db, "SELECT count(*) FROM sqlite_master WHERE name = 'u_a'"));
}

test "applyCreateIndex is interrupted by the cancel flag and by the time limit" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
    );
    defer fixture.deinit();
    var detail: SnapshotDetail = .{};

    var cancel = std.atomic.Value(bool).init(true);
    var signalled = StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.Interrupted, applyCreateIndex(fixture.path, "CREATE INDEX idx_b ON t(b)", &signalled, &detail));
    try testing.expectEqual(InterruptReason.signal, signalled.reason.?);

    cancel.store(false, .monotonic);
    var limited = StepControl.init(testing.io, 1, &cancel);
    try testing.expectError(error.Timeout, applyCreateIndex(fixture.path, "CREATE INDEX idx_b ON t(b)", &limited, &detail));
    try testing.expectEqual(InterruptReason.timeout, limited.reason.?);

    var unlimited = StepControl.init(testing.io, 0, &cancel);
    try applyCreateIndex(fixture.path, "CREATE INDEX idx_b ON t(b)", &unlimited, &detail);
    try testing.expectEqual(@as(c_int, 0), detail.error_code);
}

fn freeMigrationStatements(allocator: std.mem.Allocator, statements: []MigrationStatement) void {
    for (statements) |statement| allocator.free(statement.sql);
    allocator.free(statements);
}

test "parseMigration accepts create and drop index statements" {
    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\DROP INDEX existing_idx;
        \\CREATE INDEX idx_new ON t(b);
        \\CREATE UNIQUE INDEX idx_unique ON t(a) WHERE b IS NOT NULL;
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    try testing.expectEqual(@as(usize, 3), statements.len);
    try testing.expectEqual(MigrationKind.drop_index, statements[0].kind);
    try testing.expectEqualStrings("DROP INDEX existing_idx", statements[0].sql);
    try testing.expectEqual(MigrationKind.create_index, statements[1].kind);
    try testing.expectEqualStrings("CREATE INDEX idx_new ON t(b)", statements[1].sql);
    try testing.expectEqual(MigrationKind.create_index, statements[2].kind);
    try testing.expectEqualStrings("CREATE UNIQUE INDEX idx_unique ON t(a) WHERE b IS NOT NULL", statements[2].sql);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);
}

test "parseMigration allows IF EXISTS and IF NOT EXISTS and keeps a semicolon inside a literal" {
    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\DROP INDEX IF EXISTS nope;
        \\CREATE INDEX IF NOT EXISTS existing_idx ON t(a);
        \\CREATE INDEX idx_note ON t(b) WHERE b <> 'a;b';
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    try testing.expectEqual(@as(usize, 3), statements.len);
    try testing.expectEqual(MigrationKind.drop_index, statements[0].kind);
    try testing.expectEqual(MigrationKind.create_index, statements[1].kind);
    try testing.expectEqual(MigrationKind.create_index, statements[2].kind);
    try testing.expectEqualStrings("CREATE INDEX idx_note ON t(b) WHERE b <> 'a;b'", statements[2].sql);
}

test "parseMigration skips comments and separators between statements" {
    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\; ; -- a comment with ; inside
        \\DROP INDEX existing_idx;
        \\/* another ; comment */
        \\CREATE INDEX idx_new ON t(b)
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    try testing.expectEqual(@as(usize, 2), statements.len);
    try testing.expectEqual(MigrationKind.drop_index, statements[0].kind);
    try testing.expectEqual(MigrationKind.create_index, statements[1].kind);
}

test "parseMigration accepts table changes and index changes" {
    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\CREATE TABLE IF NOT EXISTS n(id INTEGER PRIMARY KEY, note TEXT);
        \\CREATE TABLE "as"("a" INTEGER) STRICT;
        \\CREATE TABLE x$as(id INTEGER);
        \\CREATE TABLE 商品(id INTEGER);
        \\ALTER TABLE t ADD COLUMN c INTEGER DEFAULT 0;
        \\ALTER TABLE main.商品 ADD COLUMN price INTEGER;
        \\ALTER TABLE t RENAME COLUMN b TO label;
        \\ALTER TABLE t RENAME TO u;
        \\ALTER TABLE u DROP COLUMN c;
        \\ALTER TABLE 'quoted' ADD COLUMN c INTEGER;
        \\ALTER TABLE main.'quoted' RENAME TO 'other';
        \\CREATE INDEX idx_note ON u(label);
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    try testing.expectEqual(@as(usize, 12), statements.len);
    try testing.expectEqual(MigrationKind.create_table, statements[0].kind);
    try testing.expectEqual(MigrationKind.create_table, statements[1].kind);
    try testing.expectEqual(MigrationKind.create_table, statements[2].kind);
    try testing.expectEqual(MigrationKind.create_table, statements[3].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[4].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[5].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[6].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[7].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[8].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[9].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[10].kind);
    try testing.expectEqual(MigrationKind.create_index, statements[11].kind);
    try testing.expectEqualStrings("CREATE TABLE IF NOT EXISTS n(id INTEGER PRIMARY KEY, note TEXT)", statements[0].sql);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);
}

test "parseMigration classifies the keyword prefix the same as before the lexer" {
    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\CREATE INDEX2 ON t(a);
        \\CREATE TABLE2 t(a);
        \\DROP INDEX2 i;
        \\CREATE INDEX$x ON t(a);
        \\ALTER TABLE 1abc ADD COLUMN c;
        \\ALTER TABLE main.1t ADD COLUMN c;
        \\CREATE TABLE t 1as (a);
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    try testing.expectEqual(@as(usize, 7), statements.len);
    try testing.expectEqual(MigrationKind.create_index, statements[0].kind);
    try testing.expectEqual(MigrationKind.create_table, statements[1].kind);
    try testing.expectEqual(MigrationKind.drop_index, statements[2].kind);
    try testing.expectEqual(MigrationKind.create_index, statements[3].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[4].kind);
    try testing.expectEqual(MigrationKind.alter_table, statements[5].kind);
    try testing.expectEqual(MigrationKind.create_table, statements[6].kind);
}

test "parseMigration rejects a parameter where the statement needs a name" {
    const cases = [_][:0]const u8{
        "ALTER TABLE ? ADD COLUMN c",
        "ALTER TABLE :t ADD COLUMN c",
        "CREATE TABLE t :as (a)",
    };
    for (cases) |sql| {
        var detail: SnapshotDetail = .{};
        try testing.expectError(error.MigrationStatementNotAllowed, parseMigration(testing.allocator, sql, &detail));
        try testing.expectEqual(@as(usize, 1), detail.statement_index);
    }
}

test "parseMigration rejects other statements and reports the statement number" {
    const cases = [_]struct { sql: [:0]const u8, index: usize }{
        .{ .sql = "INSERT INTO t VALUES (4, 'w')", .index = 1 },
        .{ .sql = "UPDATE t SET a = 4", .index = 1 },
        .{ .sql = "DELETE FROM t", .index = 1 },
        .{ .sql = "VACUUM", .index = 1 },
        .{ .sql = "CREATE TABLE x AS SELECT a FROM t", .index = 1 },
        .{ .sql = "CREATE TABLE x AS SELECT (1)", .index = 1 },
        .{ .sql = "CREATE TEMP TABLE x(y)", .index = 1 },
        .{ .sql = "CREATE VIRTUAL TABLE x USING fts5(y)", .index = 1 },
        .{ .sql = "CREATE VIEW v AS SELECT a FROM t", .index = 1 },
        .{ .sql = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END", .index = 1 },
        .{ .sql = "ALTER TABLE t SET x", .index = 1 },
        .{ .sql = "UPDATE sqlite_stat1 SET stat = ''", .index = 1 },
        .{ .sql = "DROP TABLE t", .index = 1 },
        .{ .sql = "ATTACH DATABASE 'other.db' AS other", .index = 1 },
        .{ .sql = "DETACH other", .index = 1 },
        .{ .sql = "PRAGMA writable_schema = 1", .index = 1 },
        .{ .sql = "ANALYZE", .index = 1 },
        .{ .sql = "INSERT INTO sqlite_stat1 VALUES ('t', 'idx', '1')", .index = 1 },
        .{ .sql = "CREATE INDEX idx_new ON t(b); DROP TABLE t", .index = 2 },
    };
    for (cases) |case| {
        var detail: SnapshotDetail = .{};
        try testing.expectError(error.MigrationStatementNotAllowed, parseMigration(testing.allocator, case.sql, &detail));
        try testing.expectEqual(case.index, detail.statement_index);
    }

    var detail: SnapshotDetail = .{};
    try testing.expectError(error.MigrationEmpty, parseMigration(testing.allocator, "", &detail));
    try testing.expectError(error.MigrationEmpty, parseMigration(testing.allocator, "-- nothing\n/* still nothing */", &detail));
}

test "applyMigration changes only the variant copy and keeps the source bytes" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try createTestDatabase(variant_path, fixture_schema);

    const source_before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.path, testing.allocator, .unlimited);
    defer testing.allocator.free(source_before);

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\DROP INDEX existing_idx;
        \\CREATE INDEX idx_new ON t(b);
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try applyMigration(variant_path, statements, &control, &detail);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);
    try testing.expectEqual(@as(c_int, 0), detail.error_code);

    var source: Db = .{};
    try source.openReadOnly(fixture.path);
    defer source.close() catch unreachable;
    try testing.expectEqual(@as(i64, 1), try queryInt(&source, "SELECT count(*) FROM sqlite_master WHERE name = 'existing_idx'"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&source, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_new'"));

    var variant: Db = .{};
    try variant.openReadOnly(variant_path);
    defer variant.close() catch unreachable;
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'existing_idx'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_new'"));

    const source_after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.path, testing.allocator, .unlimited);
    defer testing.allocator.free(source_after);
    try testing.expectEqualSlices(u8, source_before, source_after);
}

test "applyMigration applies table changes and index changes to the variant" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try createTestDatabase(variant_path, fixture_schema);

    const source_before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.path, testing.allocator, .unlimited);
    defer testing.allocator.free(source_before);

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\CREATE TABLE n(id INTEGER PRIMARY KEY, note TEXT);
        \\ALTER TABLE t ADD COLUMN c INTEGER DEFAULT 7;
        \\ALTER TABLE t RENAME COLUMN b TO label;
        \\ALTER TABLE t RENAME TO u;
        \\CREATE INDEX idx_label ON u(label);
        \\CREATE INDEX idx_n ON n(id);
        \\CREATE TABLE m(dropme INTEGER, keep TEXT);
        \\ALTER TABLE m ADD COLUMN added TEXT DEFAULT 'x';
        \\ALTER TABLE m DROP COLUMN dropme;
        \\CREATE TABLE 商品(id INTEGER);
        \\ALTER TABLE main.商品 ADD COLUMN price INTEGER;
        \\ALTER TABLE main.商品 RENAME TO products;
        \\CREATE INDEX idx_price ON products(price);
        \\CREATE TABLE x$as(id INTEGER);
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try applyMigration(variant_path, statements, &control, &detail);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);
    try testing.expectEqual(@as(c_int, 0), detail.error_code);

    var variant: Db = .{};
    try variant.openReadOnly(variant_path);
    defer variant.close() catch unreachable;
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_label'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_n'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'existing_idx'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'u'"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 't'"));
    try testing.expectEqual(@as(i64, 7), try queryInt(&variant, "SELECT c FROM u WHERE a = 1"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM n"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM m WHERE added IS NULL"));
    try testing.expectError(error.StatementInvalid, queryInt(&variant, "SELECT dropme FROM m"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_price'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'products'"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = '商品'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'x$as'"));

    const source_after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.path, testing.allocator, .unlimited);
    defer testing.allocator.free(source_after);
    try testing.expectEqualSlices(u8, source_before, source_after);
}

test "applyMigration denies forged data changes and other SQL" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try createTestDatabase(variant_path, fixture_schema);

    const forged = [_]MigrationStatement{
        .{ .kind = .drop_index, .sql = "DELETE FROM t" },
        .{ .kind = .create_index, .sql = "UPDATE t SET a = 4" },
        .{ .kind = .create_index, .sql = "DROP TABLE t" },
        .{ .kind = .create_index, .sql = "ATTACH DATABASE 'other.db' AS other" },
        .{ .kind = .drop_index, .sql = "PRAGMA writable_schema = 1" },
        .{ .kind = .create_index, .sql = "CREATE TEMP TABLE x(y)" },
    };
    for (forged) |statement| {
        var detail: SnapshotDetail = .{};
        var cancel = std.atomic.Value(bool).init(false);
        var control = StepControl.init(testing.io, 0, &cancel);
        try testing.expectError(error.MigrationApplyFailed, applyMigration(variant_path, &.{statement}, &control, &detail));
        try testing.expectEqual(sqlite.SQLITE_AUTH, detail.error_code);
        try testing.expectEqual(@as(usize, 1), detail.statement_index);
    }

    var variant: Db = .{};
    try variant.openReadOnly(variant_path);
    defer variant.close() catch unreachable;
    try testing.expectEqual(@as(i64, 3), try queryInt(&variant, "SELECT count(*) FROM t"));
}

test "applyMigration drops an index from an analyzed database" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
        \\CREATE INDEX existing_idx ON t(a);
        \\ANALYZE;
    );
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try Io.Dir.cwd().copyFile(fixture.path, Io.Dir.cwd(), variant_path, testing.io, .{});

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator, "DROP INDEX existing_idx", &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try applyMigration(variant_path, statements, &control, &detail);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);

    var variant: Db = .{};
    try variant.openReadOnly(variant_path);
    defer variant.close() catch unreachable;
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM sqlite_master WHERE name = 'existing_idx'"));
    try testing.expectEqual(@as(i64, 0), try queryInt(&variant, "SELECT count(*) FROM sqlite_stat1 WHERE idx = 'existing_idx'"));
}

test "bytesInUse equals the file size while the database has no freelist" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    var database: Db = .{};
    try database.openReadOnly(fixture.path);
    defer database.close() catch unreachable;

    const stat = try Io.Dir.cwd().statFile(testing.io, fixture.path, .{});
    try testing.expectEqual(@as(i64, 0), try database.pragmaInt("PRAGMA freelist_count", &control));
    try testing.expectEqual(stat.size, try database.bytesInUse(&control));
}

test "bytesInUse drops by the pages that DROP INDEX frees" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
        \\CREATE INDEX existing_idx ON t(a);
    );
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try Io.Dir.cwd().copyFile(fixture.path, Io.Dir.cwd(), variant_path, testing.io, .{});

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);

    var before: Db = .{};
    try before.openReadOnly(variant_path);
    const bytes_before = try before.bytesInUse(&control);
    const pages_before = try before.pragmaInt("PRAGMA page_count", &control);
    const free_before = try before.pragmaInt("PRAGMA freelist_count", &control);
    const page_size = try before.pragmaInt("PRAGMA page_size", &control);
    before.close() catch unreachable;
    try testing.expectEqual(@as(i64, 0), free_before);

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator, "DROP INDEX existing_idx", &detail);
    defer freeMigrationStatements(testing.allocator, statements);
    try applyMigration(variant_path, statements, &control, &detail);

    var after: Db = .{};
    try after.openReadOnly(variant_path);
    const bytes_after = try after.bytesInUse(&control);
    const pages_after = try after.pragmaInt("PRAGMA page_count", &control);
    const free_after = try after.pragmaInt("PRAGMA freelist_count", &control);
    after.close() catch unreachable;

    try testing.expect(free_after > free_before);
    try testing.expectEqual(pages_before, pages_after);
    const freed_bytes = (free_after - free_before) * page_size;
    try testing.expect(freed_bytes > 0);
    try testing.expectEqual(@as(u64, @intCast(freed_bytes)), bytes_before - bytes_after);
}

test "applyMigration reports the failing statement" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try createTestDatabase(variant_path, fixture_schema);

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\DROP INDEX missing_idx;
        \\CREATE INDEX idx_new ON t(b);
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.MigrationApplyFailed, applyMigration(variant_path, statements, &control, &detail));
    try testing.expectEqual(@as(usize, 1), detail.statement_index);
    try testing.expect(std.mem.indexOf(u8, detail.text(), "no such index") != null);
    try testing.expectEqual(sqlite.SQLITE_ERROR, detail.error_code);
}

test "applyMigration reports a syntax error with its statement number" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try createTestDatabase(variant_path, fixture_schema);

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator,
        \\CREATE INDEX idx_new ON t(b);
        \\CREATE INDEX idx_bad ON t(
    , &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.MigrationApplyFailed, applyMigration(variant_path, statements, &control, &detail));
    try testing.expectEqual(@as(usize, 2), detail.statement_index);
    try testing.expect(detail.text().len != 0);
}

test "applyMigration is interrupted by the cancel flag and by the time limit" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
    );
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try Io.Dir.cwd().copyFile(fixture.path, Io.Dir.cwd(), variant_path, testing.io, .{});

    var detail: SnapshotDetail = .{};
    const statements = try parseMigration(testing.allocator, "CREATE INDEX idx_b ON t(b)", &detail);
    defer freeMigrationStatements(testing.allocator, statements);

    var cancel = std.atomic.Value(bool).init(true);
    var signalled = StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.Interrupted, applyMigration(variant_path, statements, &signalled, &detail));
    try testing.expectEqual(InterruptReason.signal, signalled.reason.?);

    cancel.store(false, .monotonic);
    var limited = StepControl.init(testing.io, 1, &cancel);
    try testing.expectError(error.Timeout, applyMigration(variant_path, statements, &limited, &detail));
    try testing.expectEqual(InterruptReason.timeout, limited.reason.?);

    var unlimited = StepControl.init(testing.io, 0, &cancel);
    try applyMigration(variant_path, statements, &unlimited, &detail);
    try testing.expectEqual(@as(usize, 0), detail.statement_index);
}

test "the candidate index name is kept for the INDEXED BY message" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    try db.checkCreateIndex("CREATE INDEX \"Idx New\" ON t(b)");
    try testing.expectEqualStrings("Idx New", db.candidateIndexName().?);
    try testing.expectError(error.StatementInvalid, db.checkCreateIndex("CREATE INDEX existing_idx ON t(b)"));
}

const clue_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE VIEW v AS SELECT random() AS r, a FROM t;
    \\CREATE VIEW v2 AS SELECT a FROM v;
    \\CREATE VIEW vs AS SELECT name FROM sqlite_master;
    \\CREATE VIEW k AS SELECT 1 AS one;
    \\CREATE VIEW vl AS SELECT a FROM t LIMIT 1;
    \\CREATE INDEX idx_a ON t(a);
    \\ANALYZE;
;

fn cluesOf(db: *Db, sql: [:0]const u8) !Clues {
    const statement = try db.prepareSelect(sql);
    _ = sqlite.sqlite3_finalize(statement);
    return db.clues;
}

test "authorizer records nondeterministic functions without denying" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const cases = [_]struct { sql: [:0]const u8, name: []const u8 }{
        .{ .sql = "SELECT RANDOM()", .name = "random" },
        .{ .sql = "SELECT a FROM t WHERE a > abs(random())", .name = "random" },
        .{ .sql = "SELECT a FROM t ORDER BY randomblob(1)", .name = "randomblob" },
        .{ .sql = "SELECT (SELECT changes()) FROM t", .name = "changes" },
        .{ .sql = "WITH c AS (SELECT total_changes() AS n) SELECT n FROM c", .name = "total_changes" },
        .{ .sql = "SELECT a FROM v2", .name = "random" },
        .{ .sql = "SELECT count(*) FROM v", .name = "random" },
    };
    for (cases) |case| {
        const clues = try cluesOf(&db, case.sql);
        try testing.expectEqualStrings(case.name, clues.nondeterministic_function.?);
        try testing.expect(clues.alwaysIncomparable());
    }
}

test "date and time functions are recorded as mismatch-only" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const cases = [_]struct { sql: [:0]const u8, name: []const u8 }{
        .{ .sql = "SELECT current_timestamp", .name = "current_timestamp" },
        .{ .sql = "SELECT DATE()", .name = "date" },
        .{ .sql = "WITH c AS (SELECT datetime('now') AS d) SELECT d FROM c", .name = "datetime" },
        .{ .sql = "SELECT a FROM t WHERE date(b) IS NULL", .name = "date" },
        .{ .sql = "SELECT strftime('%Y', b) FROM t GROUP BY 1", .name = "strftime" },
    };
    for (cases) |case| {
        const clues = try cluesOf(&db, case.sql);
        try testing.expectEqualStrings(case.name, clues.time_function.?);
        try testing.expect(!clues.alwaysIncomparable());
    }
}

test "order-dependent aggregates and window functions are recorded as mismatch-only" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const cases = [_]struct { sql: [:0]const u8, name: []const u8 }{
        .{ .sql = "SELECT SUM(a) FROM t", .name = "sum" },
        .{ .sql = "SELECT sum(a) OVER () FROM t", .name = "sum" },
        .{ .sql = "SELECT group_concat(b ORDER BY b) FROM t", .name = "group_concat" },
        .{ .sql = "SELECT string_agg(b, ',') FROM t", .name = "string_agg" },
        .{ .sql = "SELECT row_number() OVER (ORDER BY a) FROM t", .name = "row_number" },
        .{ .sql = "SELECT json_group_array(a) FROM t", .name = "json_group_array" },
    };
    for (cases) |case| {
        const clues = try cluesOf(&db, case.sql);
        try testing.expectEqualStrings(case.name, clues.order_dependent_function.?);
        try testing.expect(!clues.alwaysIncomparable());
    }
}

test "count, rank, min, max, and count filter are not recorded" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const plain = [_][:0]const u8{
        "SELECT count(*) FROM t",
        "SELECT count(*) FILTER (WHERE a > 1) FROM t",
        "SELECT min(a), max(b) FROM t",
        "SELECT rank() OVER (ORDER BY a) FROM t",
        "SELECT lower(b), abs(a), length(b) FROM t WHERE b LIKE 'x%'",
        "SELECT a FROM t",
    };
    for (plain) |sql| {
        const clues = try cluesOf(&db, sql);
        try testing.expectEqual(Clues{}, clues);
    }
}

test "reading schema tables is recorded" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const cases = [_]struct { sql: [:0]const u8, name: []const u8 }{
        .{ .sql = "SELECT count(*) FROM sqlite_master", .name = "sqlite_master" },
        .{ .sql = "SELECT 1 FROM SQLITE_Schema", .name = "sqlite_schema" },
        .{ .sql = "SELECT name FROM main.sqlite_schema", .name = "sqlite_master" },
        .{ .sql = "SELECT name FROM temp.sqlite_schema", .name = "sqlite_temp_master" },
        .{ .sql = "SELECT name FROM vs", .name = "sqlite_master" },
        .{ .sql = "SELECT * FROM SQLITE_STAT1", .name = "sqlite_stat*" },
    };
    for (cases) |case| {
        const clues = try cluesOf(&db, case.sql);
        try testing.expectEqualStrings(case.name, clues.schema_table.?);
        try testing.expect(clues.alwaysIncomparable());
    }
}

test "view and cte reads are recorded" {
    var fixture = try Fixture.initWithSchema(testing.allocator, clue_schema);
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const through = [_][:0]const u8{
        "SELECT * FROM vl",
        "SELECT count(*) FROM vl",
        "SELECT * FROM k",
        "SELECT a FROM v2",
        "SELECT 1 WHERE EXISTS (SELECT 1 FROM vl)",
        "WITH c AS (SELECT a FROM t) SELECT a FROM c",
    };
    for (through) |sql| {
        try testing.expect((try cluesOf(&db, sql)).view_or_cte);
    }
    try testing.expect(!(try cluesOf(&db, "SELECT a FROM t WHERE a IN (SELECT a FROM t)")).view_or_cte);
}

test "the clues survive a re-prepare during step" {
    var fixture = try Fixture.initWithSchema(testing.allocator,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
        \\CREATE INDEX idx_b ON t(b);
    );
    defer fixture.deinit();
    var db: Db = .{};
    try db.openReadOnly(fixture.path);
    defer db.close() catch unreachable;

    const statement = try prepareBoundSelect(&db, "SELECT sum(a) FROM t WHERE b LIKE ?1", &.{
        .{ .number = 1, .value = .{ .text = "x%" } },
    });
    defer _ = sqlite.sqlite3_finalize(statement);
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 0, &cancel);
    _ = try db.stepAll(statement, &control, null);
    try testing.expectEqualStrings("sum", db.clues.order_dependent_function.?);
}

test "function lists match the vendored function list" {
    const deterministic_flag = 0x800;
    const known_safe_scalars = [_][]const u8{ "sqlite_version", "sqlite_source_id", "sqlite_compileoption_used", "sqlite_compileoption_get" };
    const known_safe_aggregates = [_][]const u8{
        "count", "min", "max", "rank", "dense_rank", "percent_rank", "cume_dist",
    };

    var handle: ?*sqlite.sqlite3 = null;
    defer _ = sqlite.sqlite3_close(handle);
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open_v2(":memory:", &handle, sqlite.SQLITE_OPEN_READWRITE, null));
    var statement: ?*sqlite.sqlite3_stmt = null;
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_prepare_v2(handle, "SELECT DISTINCT name, type, flags FROM pragma_function_list WHERE builtin = 1", -1, &statement, null));
    defer _ = sqlite.sqlite3_finalize(statement);

    var unclassified: usize = 0;
    var seen_listed: usize = 0;
    while (sqlite.sqlite3_step(statement) == sqlite.SQLITE_ROW) {
        const name = std.mem.span(sqlite.sqlite3_column_text(statement, 0).?);
        const kind = std.mem.span(sqlite.sqlite3_column_text(statement, 1).?);
        const flags = sqlite.sqlite3_column_int64(statement, 2);
        const lists = [_][]const []const u8{ &nondeterministic_functions, &order_dependent_functions, &time_functions };
        var hits: usize = 0;
        for (lists) |list| {
            if (findName(list, name) != null) hits += 1;
        }
        try testing.expect(hits <= 1);
        const listed = hits == 1;
        if (listed) seen_listed += 1;
        const known = listed or (if (std.mem.eql(u8, kind, "s"))
            flags & deterministic_flag != 0 or findName(&known_safe_scalars, name) != null
        else
            findName(&known_safe_aggregates, name) != null);
        if (!known) {
            std.debug.print("unclassified built-in function: {s} (type {s}, flags 0x{x})\n", .{ name, kind, flags });
            unclassified += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), unclassified);
    try testing.expectEqual(nondeterministic_functions.len + order_dependent_functions.len + time_functions.len, seen_listed);
}

test "limit scan skips strings, comments, quoted identifiers, and bind names" {
    const without = [_][]const u8{
        "SELECT 'LIMIT 1' FROM t",
        "SELECT 'it''s LIMIT' FROM t",
        "SELECT a FROM t -- LIMIT 1",
        "SELECT a FROM t /* LIMIT 1 */",
        "SELECT \"limit\" FROM t",
        "SELECT [limit] FROM t",
        "SELECT `offset` FROM t",
        "SELECT a FROM t WHERE a = :limit OR a = @offset OR a = $limit",
        "SELECT * FROM t WHERE a = :1limit",
        "SELECT * FROM t WHERE a = @1limit",
        "SELECT * FROM t WHERE a = $1limit",
        "SELECT a FROM t WHERE a > ?1LIMIT 2",
        "SELECT 1limit",
        "SELECT 0x1Flimit",
        "SELECT limited, offsets FROM t",
        "SELECT a FROM t /* unclosed LIMIT",
    };
    for (without) |sql| try testing.expect(!mentionsLimitOrOffset(sql));

    const with = [_][]const u8{
        "SELECT a FROM t LIMIT 1",
        "select a from t limit 1 offset 2",
        "SELECT a FROM t WHERE a IN (SELECT a FROM t LIMIT 2)",
        "SELECT offset FROM t",
        "SELECT a FROM t\nLIMIT\t1",
        "SELECT 'x' FROM t LIMIT(1)",
        "SELECT a FROM t LIMIT:n",
        "SELECT a FROM t LIMIT 1 OFFSET@o",
    };
    for (with) |sql| try testing.expect(mentionsLimitOrOffset(sql));
}

fn runWriteCounters(path: [:0]const u8, sql: [:0]const u8) !Counters {
    var handle: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_close(handle);
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(handle, sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_finalize(statement);
    while (true) switch (sqlite.sqlite3_step(statement)) {
        sqlite.SQLITE_DONE => return statementCounters(statement.?),
        else => return error.TestFixtureFailed,
    };
}

const wide_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
    \\INSERT INTO t SELECT x, 'v' || (x % 500) FROM c;
;

const wide_indexed_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
    \\INSERT INTO t SELECT x, 'v' || (x % 500) FROM c;
    \\CREATE INDEX idx_b ON t(b);
;

test "rows read falls from 100000 on a full scan to 201 with one seek and 200 index steps" {
    var plain = try Fixture.initWithSchema(testing.allocator, wide_schema);
    defer plain.deinit();
    var indexed = try Fixture.initWithSchema(testing.allocator, wide_indexed_schema);
    defer indexed.deinit();

    const binds = [_]BindArg{.{ .number = 1, .value = .{ .text = "v1" } }};
    var scan_db: Db = .{};
    try scan_db.openReadOnly(plain.path);
    defer scan_db.close() catch unreachable;
    var search_db: Db = .{};
    try search_db.openReadOnly(indexed.path);
    defer search_db.close() catch unreachable;

    const scan = try runCounters(&scan_db, "SELECT a FROM t WHERE b = ?1", &binds);
    const search = try runCounters(&search_db, "SELECT a FROM t WHERE b = ?1", &binds);
    try testing.expectEqual(@as(u32, 100_000), scan.rows_read);
    try testing.expectEqual(@as(u32, 201), search.rows_read);
    try testing.expectEqual(@as(u32, 99_999), scan.fullscan_steps);
    try testing.expectEqual(@as(u32, 0), search.fullscan_steps);
    try testing.expectEqual(@as(u32, 0), scan.rows_written);
    try testing.expectEqual(@as(u32, 0), search.rows_written);
}

test "rows written counts one per table row and one more per secondary index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flat.db", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "indexed.db", .data = "" });
    const flat_path = try tmp.dir.realPathFileAlloc(testing.io, "flat.db", testing.allocator);
    defer testing.allocator.free(flat_path);
    const index_path = try tmp.dir.realPathFileAlloc(testing.io, "indexed.db", testing.allocator);
    defer testing.allocator.free(index_path);

    const flat_writer = try openTestWriter(flat_path, "CREATE TABLE t(a INTEGER);");
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_close(flat_writer));
    const index_writer = try openTestWriter(index_path, "CREATE TABLE t(a INTEGER); CREATE INDEX ix_a ON t(a);");
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_close(index_writer));

    const insert_thousand =
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
        \\INSERT INTO t SELECT x FROM c;
    ;
    try testing.expectEqual(@as(u32, 1000), (try runWriteCounters(flat_path, insert_thousand)).rows_written);
    try testing.expectEqual(@as(u32, 2000), (try runWriteCounters(index_path, insert_thousand)).rows_written);
}

test "table warning checks target stats and actual bounded cardinality" {
    const schema =
        \\CREATE TABLE t(a INTEGER);
        \\CREATE TABLE other(a INTEGER);
        \\INSERT INTO other VALUES(1);
        \\ANALYZE other;
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000) INSERT INTO t SELECT x FROM c;
    ;
    var fixture = try Fixture.initWithSchema(testing.allocator, schema);
    defer fixture.deinit();
    var database: Db = .{};
    try database.openReadOnly(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);
    const warnings = try database.tableWarnings(testing.allocator, "t", &control);
    try testing.expect(warnings.no_analyze_stats);
    try testing.expect(!warnings.data_too_small);
    const other = try database.tableWarnings(testing.allocator, "other", &control);
    try testing.expect(!other.no_analyze_stats);
    try testing.expect(other.data_too_small);
}

const WriteCounts = struct {
    rows: u64,
    counters: Counters,
    changes: u64,
    total_changes: u64,
};

fn runWrite(database: *Db, sql: [:0]const u8, control: *StepControl) !WriteCounts {
    const statement = try database.prepareWrite(sql);
    defer _ = sqlite.sqlite3_finalize(statement);
    try database.beginWrite(control);
    const total_before = database.totalChanges();
    const rows = try database.stepDml(statement, control, null);
    const counters = takeCounters(statement);
    const changes = database.changes();
    const total_after = database.totalChanges();
    try database.rollbackWrite();
    return .{ .rows = rows, .counters = counters, .changes = changes, .total_changes = total_after - total_before };
}

test "a writable connection opens the sandbox database for writing" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;

    try testing.expectEqual(@as(c_int, 0), sqlite.sqlite3_db_readonly(database.handle, "main"));
}

test "one insert counts the table, its secondary index, and its trigger, then rolls back" {
    const schema =
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
        \\CREATE INDEX ix_b ON t(b);
        \\CREATE TABLE log(x INTEGER);
        \\CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES(new.a); END;
        \\INSERT INTO t VALUES (1, 'x');
    ;
    var fixture = try Fixture.initWithSchema(testing.allocator, schema);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);

    const counts = try runWrite(&database, "INSERT INTO t VALUES (2, 'y')", &control);
    try testing.expectEqual(@as(u64, 0), counts.rows);
    try testing.expectEqual(@as(u32, 3), counts.counters.rows_written);
    try testing.expectEqual(@as(u64, 1), counts.changes);
    try testing.expectEqual(@as(u64, 2), counts.total_changes);
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM t"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM log"));
}

test "a foreign key cascade is counted and rolled back" {
    const schema =
        \\CREATE TABLE p(id INTEGER PRIMARY KEY);
        \\CREATE TABLE c(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE CASCADE);
        \\CREATE INDEX ix_c_pid ON c(pid);
        \\INSERT INTO p VALUES (1);
        \\INSERT INTO c VALUES (10, 1), (11, 1);
    ;
    var fixture = try Fixture.initWithSchema(testing.allocator, schema);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);

    const counts = try runWrite(&database, "DELETE FROM p WHERE id = 1", &control);
    try testing.expectEqual(@as(u32, 3), counts.counters.rows_written);
    try testing.expectEqual(@as(u64, 1), counts.changes);
    try testing.expectEqual(@as(u64, 3), counts.total_changes);
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM p"));
    try testing.expectEqual(@as(i64, 2), try queryInt(&database, "SELECT count(*) FROM c"));
}

test "insert or replace is rolled back with its implicit delete" {
    const schema =
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
        \\CREATE INDEX ix_b ON t(b);
        \\INSERT INTO t VALUES (1, 'x');
    ;
    var fixture = try Fixture.initWithSchema(testing.allocator, schema);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);

    const counts = try runWrite(&database, "INSERT OR REPLACE INTO t(a, b) VALUES (1, 'y')", &control);
    try testing.expectEqual(@as(u32, 2), counts.counters.rows_written);
    try testing.expectEqual(@as(u64, 1), counts.changes);
    try testing.expectEqual(@as(u64, 1), counts.total_changes);
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM t"));
    try testing.expectEqual(@as(?i64, 1), try firstRowInt64(&database, "SELECT count(*) FROM t WHERE b = 'x'"));
}

fn firstRowInt64(database: *Db, sql: [:0]const u8) !?i64 {
    const statement = try database.prepareSelect(sql);
    defer _ = sqlite.sqlite3_finalize(statement);
    return switch (sqlite.sqlite3_step(statement)) {
        sqlite.SQLITE_ROW => sqlite.sqlite3_column_int64(statement, 0),
        else => error.TestFixtureFailed,
    };
}

test "autoincrement sqlite_sequence returns to its old value after rollback" {
    const schema =
        \\CREATE TABLE t(a INTEGER PRIMARY KEY AUTOINCREMENT, b TEXT);
        \\INSERT INTO t(b) VALUES ('x');
    ;
    var fixture = try Fixture.initWithSchema(testing.allocator, schema);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);

    const counts = try runWrite(&database, "INSERT INTO t(b) VALUES ('y')", &control);
    try testing.expectEqual(@as(u32, 2), counts.counters.rows_written);
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT seq FROM sqlite_sequence WHERE name = 't'"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM t"));
}

test "a repeated write after rollback reports the same counters" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);

    const first = try runWrite(&database, "UPDATE t SET b = b || '!' WHERE a = 2", &control);
    const second = try runWrite(&database, "UPDATE t SET b = b || '!' WHERE a = 2", &control);
    try testing.expect(std.meta.eql(first.counters, second.counters));
    try testing.expectEqual(first.changes, second.changes);
    try testing.expectEqual(first.total_changes, second.total_changes);
    try testing.expectEqual(@as(i64, 1), try queryInt(&database, "SELECT count(*) FROM t WHERE b = 'y'"));
}

test "a write plan is read without changing rows" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const plan = try database.explainDml(arena_state.allocator(), "UPDATE t SET b = 'q' WHERE a = 1", &.{}, &control);
    try testing.expect(plan.rows.len > 0);
    try testing.expectEqual(@as(i64, 3), try queryInt(&database, "SELECT count(*) FROM t"));
}

test "a non-write statement is rejected before it runs" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;

    try testing.expectError(error.StatementNotWrite, database.checkWrite("SELECT 1"));
    try testing.expectError(error.StatementNotWrite, database.checkWrite("VACUUM"));
    try testing.expectError(error.StatementNotWrite, database.checkWrite("CREATE TABLE u(x)"));
    try testing.expectError(error.StatementNotWrite, database.checkWrite("PRAGMA user_version = 1"));
    try testing.expectError(error.StatementNotWrite, database.checkWrite("WITH c AS (SELECT 1) SELECT * FROM c"));
    try testing.expectError(error.MultipleStatements, database.checkWrite("INSERT INTO t VALUES (4, 'w'); SELECT 1"));
    try testing.expectError(error.StatementNotWrite, database.checkWrite("EXPLAIN INSERT INTO t VALUES (4, 'w')"));
}

test "a write records the clues that make its effect incomparable" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;

    const random_statement = try database.prepareWrite("INSERT INTO t SELECT a, b FROM t WHERE random() > 0");
    defer _ = sqlite.sqlite3_finalize(random_statement);
    try testing.expectEqualStrings("random", database.clues.nondeterministic_function.?);

    const schema_statement = try database.prepareWrite("INSERT INTO t SELECT name, sql FROM sqlite_master");
    defer _ = sqlite.sqlite3_finalize(schema_statement);
    try testing.expect(database.clues.schema_table != null);
}

test "a new write run starts a fresh time limit" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(false);
    var control = StepControl.init(testing.io, 30000, &cancel);
    control.start();
    control.deadline_ns = Io.Clock.now(.awake, testing.io).nanoseconds - 1;

    const counts = try runWrite(&database, "INSERT INTO t VALUES (4, 'w')", &control);
    try testing.expectEqual(@as(u64, 1), counts.changes);
}

test "a cancelled write does not start a transaction" {
    var fixture = try Fixture.init(testing.allocator);
    defer fixture.deinit();

    var database: Db = .{};
    try database.openWritable(fixture.path);
    defer database.close() catch unreachable;
    var cancel = std.atomic.Value(bool).init(true);
    var control = StepControl.init(testing.io, 30000, &cancel);

    try testing.expectError(error.Interrupted, database.beginWrite(&control));
    try testing.expectEqual(@as(c_int, 1), sqlite.sqlite3_get_autocommit(database.handle));
}
