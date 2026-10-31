const std = @import("std");
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const result = @import("../result.zig");

pub const Execution = struct {
    rows: u64,
    counters: db.Counters,
    changes: u64,
    total_changes: u64,
};

pub const Runner = struct {
    database: db.Db = .{},
    statement: ?*sqlite.sqlite3_stmt = null,
    opened: bool = false,

    pub fn open(self: *Runner, path: [:0]const u8) db.OpenError!void {
        try self.database.openWritable(path);
        self.opened = true;
    }

    pub fn prepare(self: *Runner, sql: [:0]const u8) db.CheckError!void {
        self.finalize();
        self.statement = try self.database.prepareWrite(sql);
    }

    pub fn bind(self: *Runner, binds: []const db.BindArg) db.BindError!void {
        try db.bindAll(self.statement.?, binds);
    }

    pub fn bindParameterCount(self: *const Runner) c_int {
        return sqlite.sqlite3_bind_parameter_count(self.statement.?);
    }

    pub fn plan(
        self: *Runner,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const db.BindArg,
        control: *db.StepControl,
    ) (db.CheckError || db.BindError || db.ExplainError || db.StepError || std.mem.Allocator.Error)!db.Plan {
        return self.database.explainDml(arena, sql, binds, control);
    }

    pub fn execute(self: *Runner, control: *db.StepControl, rows_out: ?*result.RowCollector) db.StepError!Execution {
        const statement = self.statement orelse return error.StepFailed;
        try db.resetStatement(statement);
        try self.database.beginWrite(control);

        const total_before = self.database.totalChanges();
        const rows = self.database.stepDml(statement, control, rows_out) catch |err| {
            self.database.rollbackWrite() catch {};
            return err;
        };
        const counters = db.takeCounters(statement);
        const changes = self.database.changes();
        const total_after = self.database.totalChanges();

        try self.database.rollbackWrite();
        return .{
            .rows = rows,
            .counters = counters,
            .changes = changes,
            .total_changes = total_after - total_before,
        };
    }

    pub fn columnCount(self: *const Runner) c_int {
        return db.columnCount(self.statement.?);
    }

    pub fn clues(self: *const Runner) db.Clues {
        return self.database.clues;
    }

    pub fn message(self: *const Runner) []const u8 {
        return self.database.message();
    }

    pub fn errorCode(self: *const Runner) c_int {
        return self.database.errorCode();
    }

    pub fn finalize(self: *Runner) void {
        if (self.statement) |statement| {
            _ = sqlite.sqlite3_finalize(statement);
            self.statement = null;
        }
    }

    pub fn close(self: *Runner) db.CloseError!void {
        if (!self.opened) return;
        try self.database.close();
        self.opened = false;
    }
};

const testing = std.testing;

test "a runner without an open database and statement rejects an execution" {
    var runner: Runner = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var control = db.StepControl.init(testing.io, 0, &cancel);
    try testing.expectError(error.StepFailed, runner.execute(&control, null));
    try runner.close();
}
