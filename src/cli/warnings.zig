const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const result = @import("../result.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const cli_suggest = @import("suggest.zig");

pub const Error = Io.Writer.Error || std.mem.Allocator.Error;

pub const max_listed_names: usize = 10;

pub const SmallData = struct {
    table: []const u8,
    rows: u64,
    full_scan: bool,
    suggested: bool,
    next_command: []const u8,
    message: []const u8,
};

pub const ScaleTarget = struct {
    database: []const u8,
    binding: ?[]const u8 = null,
    select_path: []const u8,
    write_path: ?[]const u8 = null,
    index_path: []const u8,
    suggested: bool = false,
};

pub const Warnings = struct {
    no_analyze_stats: bool = false,
    data_too_small: bool = false,
    bind_dependent_partial_index: ?[]const u8 = null,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
    small_data: ?SmallData = null,
};

pub const Comparison = struct {
    query: []const u8,
    candidate: []const u8,
    index_name: []const u8,
};

pub const CandidateWarning = struct {
    candidate: []const u8,
    code: []const u8,
    message: []const u8,
    owned: bool = false,
};

pub fn anyWarnings(warnings: Warnings) bool {
    return warnings.no_analyze_stats or warnings.data_too_small or warnings.bind_dependent_partial_index != null or warnings.unapplied_migrations != null;
}

pub fn bindDependentPartialIndexMessage(allocator: std.mem.Allocator, index_name: []const u8) Error![]const u8 {
    const escaped = try escapedText(allocator, index_name);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, contract.bind_dependent_partial_index_message, .{escaped});
}

pub fn unappliedMigrationsMessage(allocator: std.mem.Allocator, pending: cli_d1_migrations.Pending) Error![]const u8 {
    return unappliedMigrations(allocator, pending, false);
}

pub fn unappliedMigrationsText(allocator: std.mem.Allocator, pending: cli_d1_migrations.Pending) Error![]const u8 {
    return unappliedMigrations(allocator, pending, true);
}

fn unappliedMigrations(allocator: std.mem.Allocator, pending: cli_d1_migrations.Pending, escape: bool) Error![]const u8 {
    var names: Io.Writer.Allocating = .init(allocator);
    defer names.deinit();
    for (pending.names[0..@min(pending.names.len, max_listed_names)], 0..) |name, index| {
        if (index != 0) try names.writer.writeAll(", ");
        if (escape) try result.writeEscapedText(&names.writer, name) else try names.writer.writeAll(name);
    }
    if (pending.names.len > max_listed_names) {
        try names.writer.print(", and {d} more", .{pending.names.len - max_listed_names});
    }
    const binding = if (escape) try escapedText(allocator, pending.binding) else pending.binding;
    defer if (escape) allocator.free(binding);
    return std.fmt.allocPrint(allocator, contract.unapplied_migrations_message, .{ binding, names.written(), binding });
}

fn escapedText(allocator: std.mem.Allocator, text: []const u8) Error![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try result.writeEscapedText(&out.writer, text);
    return allocator.dupe(u8, out.written());
}

pub fn bareScan(detail: []const u8, table: []const u8) bool {
    const prefix = "SCAN ";
    if (table.len == 0 or !std.mem.startsWith(u8, detail, prefix)) return false;
    return std.mem.eql(u8, detail[prefix.len..], table);
}

fn needsQuote(token: []const u8) bool {
    if (token.len == 0) return true;
    return std.mem.indexOfAny(u8, token, " \t'\"\\$") != null;
}

fn appendToken(out: *std.ArrayList(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    if (out.items.len != 0) try out.append(allocator, ' ');
    if (!needsQuote(token)) return out.appendSlice(allocator, token);
    try out.append(allocator, '\'');
    for (token) |byte| {
        if (byte == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
}

pub fn scaleCommand(allocator: std.mem.Allocator, target: ScaleTarget) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const index_path = if (target.suggested) "index.sql" else target.index_path;
    try appendToken(&out, allocator, "qenome");
    if (target.binding) |binding| {
        try appendToken(&out, allocator, "--d1");
        try appendToken(&out, allocator, binding);
    } else {
        try appendToken(&out, allocator, target.database);
    }
    if (target.write_path) |path| {
        try appendToken(&out, allocator, "--write");
        try appendToken(&out, allocator, path);
        try appendToken(&out, allocator, "--index-sql");
        try appendToken(&out, allocator, index_path);
    } else {
        try appendToken(&out, allocator, target.select_path);
        try appendToken(&out, allocator, index_path);
    }
    try appendToken(&out, allocator, "--seed-data");
    try appendToken(&out, allocator, "seed.json");
    try appendToken(&out, allocator, "--scale");
    try appendToken(&out, allocator, "1000,10000");
    return out.toOwnedSlice(allocator);
}

fn leadText(allocator: std.mem.Allocator, full_scan: bool, suggested: bool) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{
        if (full_scan) contract.data_too_small_full_scan else "",
        if (suggested) contract.data_too_small_suggested else "",
    });
}

pub fn smallDataMessage(
    allocator: std.mem.Allocator,
    table: []const u8,
    rows: u64,
    full_scan: bool,
    target: ScaleTarget,
) ![]const u8 {
    const command = try scaleCommand(allocator, target);
    defer allocator.free(command);
    const lead = try leadText(allocator, full_scan, target.suggested);
    defer allocator.free(lead);
    return std.fmt.allocPrint(allocator, contract.data_too_small_message, .{ table, rows, lead, table, command });
}

pub fn attachSmallData(
    allocator: std.mem.Allocator,
    warnings: *Warnings,
    table: []const u8,
    rows: u64,
    full_scan: bool,
    target: ScaleTarget,
) !void {
    if (!warnings.data_too_small) return;
    const next_command = try scaleCommand(allocator, target);
    errdefer allocator.free(next_command);
    const lead = try leadText(allocator, full_scan, target.suggested);
    defer allocator.free(lead);
    const message = try std.fmt.allocPrint(allocator, contract.data_too_small_message, .{ table, rows, lead, table, next_command });
    warnings.small_data = .{
        .table = table,
        .rows = rows,
        .full_scan = full_scan,
        .suggested = target.suggested,
        .next_command = next_command,
        .message = message,
    };
}

fn warningText(warnings: Warnings, code: []const u8, message: []const u8) []const u8 {
    if (!std.mem.eql(u8, code, contract.code.data_too_small)) return message;
    const detail = warnings.small_data orelse return message;
    return detail.message;
}

pub fn writeSmallDataRanking(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    table: []const u8,
    rows: u64,
    full_scan: bool,
    target: ScaleTarget,
) Error!void {
    if (table.len == 0) return;
    const command = try scaleCommand(allocator, target);
    defer allocator.free(command);
    var buffer: [512]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    const scan = if (full_scan) " A full scan reads every row, so this ranking does not show that a missing index is harmless." else "";
    text.print("  {s} has {d} rows, fewer than 1000 rows.{s}\n", .{ table, rows, scan }) catch {
        try stdout.writeAll("  fewer than 1000 rows, so this ranking is not meaningful yet.\n");
        try stdout.print("  Next: {s}\n", .{command});
        return;
    };
    try stdout.writeAll(text.buffered());
    try stdout.print("  Next: {s}\n", .{command});
}

pub fn writeWarnings(stdout: *Io.Writer, allocator: std.mem.Allocator, warnings: Warnings) Error!void {
    const enabled = [_]bool{ warnings.no_analyze_stats, warnings.data_too_small };
    for (enabled, contract.warning_codes, contract.warning_messages) |active, code, message| {
        if (active) try stdout.print("warning: {s}: {s}\n", .{ code, warningText(warnings, code, message) });
    }
    if (warnings.bind_dependent_partial_index) |name| {
        const message = try bindDependentPartialIndexMessage(allocator, name);
        defer allocator.free(message);
        try stdout.print("warning: {s}: {s}\n", .{ contract.code.bind_dependent_partial_index, message });
    }
    if (warnings.unapplied_migrations) |pending| {
        const message = try unappliedMigrationsText(allocator, pending);
        defer allocator.free(message);
        try stdout.print("warning: {s}: {s}\n", .{ contract.code.unapplied_migrations, message });
    }
}

pub fn writeBatchWarnings(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    candidates: []const CandidateWarning,
    comparisons: []const Comparison,
) Error!void {
    if (candidates.len == 0 and comparisons.len == 0) return;
    try stdout.writeAll("\nWarnings\n");
    for (candidates) |entry| {
        try stdout.writeAll("  ");
        try result.writeEscapedText(stdout, entry.candidate);
        try stdout.print(": {s}: ", .{entry.code});
        try result.writeEscapedText(stdout, entry.message);
        try stdout.writeByte('\n');
    }
    for (comparisons) |entry| {
        const message = try bindDependentPartialIndexMessage(allocator, entry.index_name);
        defer allocator.free(message);
        try stdout.writeAll("  ");
        try result.writeEscapedText(stdout, entry.query);
        try stdout.writeAll(" -> ");
        try result.writeEscapedText(stdout, entry.candidate);
        try stdout.print(": {s}: {s}\n", .{ contract.code.bind_dependent_partial_index, message });
    }
}

pub fn writeRunWarnings(stdout: *Io.Writer, warnings: []const cli_suggest.Warning) Io.Writer.Error!void {
    for (warnings) |warning| {
        try stdout.print("warning: {s}: ", .{warning.code});
        try result.writeEscapedText(stdout, warning.message);
        try stdout.writeByte('\n');
    }
}

const testing = std.testing;

test "the unapplied migration message lists every name" {
    const names = [_][]const u8{ "0001_a.sql", "0002_b.sql" };
    const message = try unappliedMigrationsMessage(testing.allocator, .{ .binding = "DB", .names = &names });
    defer testing.allocator.free(message);
    try testing.expectEqualStrings(
        "wrangler has not applied these migrations to the local D1 database for DB: 0001_a.sql, 0002_b.sql. Run `npx wrangler d1 migrations apply DB --local` and compare again; the schema under test is older than the migrations describe.",
        message,
    );
}

test "the unapplied migration message counts the names past the limit" {
    var names: [max_listed_names + 2][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = try std.fmt.allocPrint(testing.allocator, "{d:0>4}_x.sql", .{index + 1});
    defer for (names) |name| testing.allocator.free(name);
    const message = try unappliedMigrationsMessage(testing.allocator, .{ .binding = "DB", .names = &names });
    defer testing.allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "0001_x.sql") != null);
    try testing.expect(std.mem.indexOf(u8, message, "0010_x.sql") != null);
    try testing.expect(std.mem.indexOf(u8, message, "0011_x.sql") == null);
    try testing.expect(std.mem.indexOf(u8, message, "0010_x.sql, and 2 more.") != null);
}

test "the unapplied migration text escapes a name for the human report" {
    const names = [_][]const u8{"a\nb.sql"};
    const text = try unappliedMigrationsText(testing.allocator, .{ .binding = "DB", .names = &names });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "a\\nb.sql") != null);
    try testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
}

test "the batch warnings list candidate and comparison entries under one heading" {
    var buffer: [2048]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const candidates = [_]CandidateWarning{.{
        .candidate = "a.sql",
        .code = contract.code.no_analyze_stats,
        .message = contract.warning_messages[0],
    }};
    const comparisons = [_]Comparison{.{ .query = "q.sql", .candidate = "a.sql", .index_name = "ix" }};
    try writeBatchWarnings(&stdout, testing.allocator, &candidates, &comparisons);
    const output = stdout.buffered();
    try testing.expect(std.mem.startsWith(u8, output, "\nWarnings\n"));
    try testing.expect(std.mem.indexOf(u8, output, "\n  a.sql: no_analyze_stats: ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\n  q.sql -> a.sql: bind_dependent_partial_index: ") != null);
}

test "the batch warnings write nothing when no warning applies" {
    var buffer: [64]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    try writeBatchWarnings(&stdout, testing.allocator, &.{}, &.{});
    try testing.expectEqualStrings("", stdout.buffered());
}

test "a path with a space is quoted in the scale command" {
    const command = try scaleCommand(testing.allocator, .{
        .database = "my db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
    });
    defer testing.allocator.free(command);
    try testing.expect(std.mem.indexOf(u8, command, "'my db.sqlite'") != null);
    try testing.expect(std.mem.indexOf(u8, command, "--seed-data seed.json --scale 1000,10000") != null);
}

test "a bare scan is SCAN and the table name, with nothing after it" {
    try testing.expect(bareScan("SCAN events", "events"));
    try testing.expect(!bareScan("SCAN events USING INDEX idx_customer", "events"));
    try testing.expect(!bareScan("SEARCH events USING INDEX idx_customer (customer_id=?)", "events"));
    try testing.expect(!bareScan("SCAN other", "events"));
    try testing.expect(!bareScan("SCAN events", ""));
}

test "the small-data message names the table, the scan, and a scale command" {
    const target: ScaleTarget = .{
        .database = "app.db",
        .select_path = "select.sql",
        .index_path = "index.sql",
    };
    const message = try smallDataMessage(testing.allocator, "events", 12, true, target);
    defer testing.allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "events") != null);
    try testing.expect(std.mem.indexOf(u8, message, "12") != null);
    try testing.expect(std.mem.indexOf(u8, message, "fewer than 1000 rows") != null);
    try testing.expect(std.mem.indexOf(u8, message, contract.data_too_small_full_scan) != null);
    try testing.expect(std.mem.indexOf(u8, message, "qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000") != null);
}

test "a suggested index tells the user to save index.sql before --scale" {
    const command = try scaleCommand(testing.allocator, .{
        .database = "app.db",
        .select_path = "select.sql",
        .index_path = "suggested:1",
        .suggested = true,
    });
    defer testing.allocator.free(command);
    try testing.expectEqualStrings("qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000", command);
    const message = try smallDataMessage(testing.allocator, "events", 3, false, .{
        .database = "app.db",
        .select_path = "select.sql",
        .index_path = "suggested:1",
        .suggested = true,
    });
    defer testing.allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, contract.data_too_small_suggested) != null);
    try testing.expect(std.mem.indexOf(u8, message, contract.data_too_small_full_scan) == null);
}

test "the ranking note prints the table and the next command" {
    var buffer: [1024]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    try writeSmallDataRanking(&stdout, testing.allocator, "events", 12, true, .{
        .database = "app.db",
        .binding = "DB",
        .select_path = "select.sql",
        .index_path = "index.sql",
    });
    const output = stdout.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "events has 12 rows, fewer than 1000 rows.") != null);
    try testing.expect(std.mem.indexOf(u8, output, "full scan") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Next: qenome --d1 DB select.sql index.sql --seed-data seed.json --scale 1000,10000\n") != null);
}
