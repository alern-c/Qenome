const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const result = @import("../result.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const cli_suggest = @import("suggest.zig");

pub const Error = Io.Writer.Error || std.mem.Allocator.Error;

pub const max_listed_names: usize = 10;

pub const Warnings = struct {
    no_analyze_stats: bool = false,
    data_too_small: bool = false,
    bind_dependent_partial_index: ?[]const u8 = null,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
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

pub fn writeWarnings(stdout: *Io.Writer, allocator: std.mem.Allocator, warnings: Warnings) Error!void {
    const enabled = [_]bool{ warnings.no_analyze_stats, warnings.data_too_small };
    for (enabled, contract.warning_codes, contract.warning_messages) |active, code, message| {
        if (active) try stdout.print("warning: {s}: {s}\n", .{ code, message });
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
