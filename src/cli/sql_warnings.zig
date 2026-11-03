const std = @import("std");
const db = @import("../db.zig");
const model = @import("../report/model.zig");
const sql_lint = @import("../sql/lint.zig");
const cli_warnings = @import("warnings.zig");

pub const Inputs = struct {
    sql: []const u8,
    plan: ?db.Plan = null,
    binds: []const db.BindArg = &.{},
    enabled: bool = true,
    ignored: []const []const u8 = &.{},
};

pub const Position = struct {
    line: u32,
    column: u32,
};

pub fn collect(allocator: std.mem.Allocator, inputs: Inputs) std.mem.Allocator.Error![]const model.SqlWarning {
    if (!inputs.enabled) return &.{};
    const bounds = try boundValues(allocator, inputs.binds);
    defer allocator.free(bounds);
    const findings = try sql_lint.lint(allocator, inputs.sql, bounds);
    defer allocator.free(findings);
    var warnings: std.ArrayList(model.SqlWarning) = .empty;
    errdefer warnings.deinit(allocator);
    var cursor: Cursor = .{ .sql = inputs.sql };
    for (findings) |finding| {
        if (ignoredCode(inputs.ignored, finding.code)) continue;
        var plan_checked = false;
        switch (finding.plan_check) {
            .none => {},
            .index_on_table => {
                const table = finding.table orelse continue;
                if (inputs.plan) |plan| {
                    if (usesIndex(plan, table)) continue;
                    plan_checked = true;
                }
            },
            .full_scan_of_table => {
                const table = finding.table orelse continue;
                const plan = inputs.plan orelse continue;
                if (!fullScan(plan, table)) continue;
                plan_checked = true;
            },
        }
        const at = cursor.at(finding.offset);
        try warnings.append(allocator, .{
            .code = finding.code,
            .severity = finding.severity,
            .message = finding.message,
            .line = at.line,
            .column = at.column,
            .plan_checked = plan_checked,
        });
    }
    return warnings.toOwnedSlice(allocator);
}

fn boundValues(allocator: std.mem.Allocator, binds: []const db.BindArg) std.mem.Allocator.Error![]const sql_lint.Bound {
    const bounds = try allocator.alloc(sql_lint.Bound, binds.len);
    for (binds, 0..) |bind, index| {
        bounds[index] = .{ .parameter = bind.number };
        switch (bind.value) {
            .text => |text| bounds[index].text = text,
            .int => |value| bounds[index].int = value,
            else => {},
        }
    }
    return bounds;
}

fn ignoredCode(ignored: []const []const u8, code: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, entry, code)) return true;
    }
    return false;
}

pub fn position(sql: []const u8, offset: usize) Position {
    var cursor: Cursor = .{ .sql = sql };
    return cursor.at(offset);
}

const Cursor = struct {
    sql: []const u8,
    index: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    fn at(self: *Cursor, offset: usize) Position {
        const target = @min(offset, self.sql.len);
        if (target < self.index) {
            self.index = 0;
            self.line = 1;
            self.line_start = 0;
        }
        while (self.index < target) : (self.index += 1) {
            if (self.sql[self.index] != '\n') continue;
            self.line += 1;
            self.line_start = self.index + 1;
        }
        return .{ .line = self.line, .column = @intCast(target - self.line_start + 1) };
    }
};

pub fn usesIndex(plan: db.Plan, table: []const u8) bool {
    for (plan.rows) |row| {
        const detail = row.detail;
        const rest = if (std.mem.startsWith(u8, detail, "SEARCH "))
            detail["SEARCH ".len..]
        else if (std.mem.startsWith(u8, detail, "SCAN "))
            detail["SCAN ".len..]
        else
            continue;
        const separator = std.mem.indexOf(u8, rest, " USING ") orelse continue;
        if (!std.ascii.eqlIgnoreCase(rest[0..separator], table)) continue;
        const usage = rest[separator + " USING ".len ..];
        if (std.mem.startsWith(u8, usage, "AUTOMATIC ")) continue;
        if (std.mem.indexOf(u8, usage, "INDEX ") != null) return true;
    }
    return false;
}

pub fn fullScan(plan: db.Plan, table: []const u8) bool {
    for (plan.rows) |row| {
        if (cli_warnings.bareScan(row.detail, table)) return true;
    }
    return false;
}

test {
    _ = @import("sql_warnings_tests.zig");
}
