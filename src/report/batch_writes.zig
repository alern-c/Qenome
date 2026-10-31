const std = @import("std");
const Io = std.Io;
const cli_comparison = @import("../cli/comparison.zig");
const result = @import("../result.zig");
const report_json = @import("json.zig");
const format = @import("format.zig");

pub const Status = enum {
    compared,
    variant_timeout,
};

pub const Rows = struct {
    baseline: u64,
    variant: u64,
};

pub const Result = struct {
    write: []const u8,
    candidate: []const u8,
    status: Status,
    outcome: ?cli_comparison.Verdict = null,
    judgement: cli_comparison.RowVerdict = .not_judged,
    baseline_missing: bool = false,
    rows_read: ?Rows = null,
    rows_written: ?Rows = null,
    variant_read: u64 = 0,
    variant_written: u64 = 0,
    ran: bool = true,
    reason: []const u8 = "",
    comparison: []const u8 = "",
};

pub const note = "rows written counts a table row and each secondary-index insert, trigger insert, and foreign-key cascade, but the bundled counting patch does not count secondary-index deletes, so a migration that drops an index does not lower rows written; the verdict follows rows read (see docs/accuracy.md)";

pub fn writeJson(json: *std.json.Stringify, allocator: std.mem.Allocator, results: []const Result) !void {
    try json.beginArray();
    for (results) |entry| {
        try json.beginObject();
        try json.objectField("write");
        try report_json.writeJsonText(json, allocator, entry.write);
        try json.objectField("candidate");
        try report_json.writeJsonText(json, allocator, entry.candidate);
        try json.objectField("status");
        try json.write(@tagName(entry.status));
        try json.objectField("comparison");
        if (entry.comparison.len == 0) {
            try json.write(null);
        } else {
            try json.print("{s}", .{entry.comparison});
        }
        try json.endObject();
    }
    try json.endArray();
}

pub fn writeHuman(stdout: *Io.Writer, allocator: std.mem.Allocator, results: []const Result) !void {
    const names = try allocator.alloc([]const u8, results.len);
    defer allocator.free(names);
    for (results, 0..) |entry, index| names[index] = entry.write;
    const counts = countVerdicts(results);

    var title: Io.Writer.Allocating = .init(allocator);
    defer title.deinit();
    try title.writer.print("\nWrites: {d} {s}", .{ results.len, word(results.len, "write", "writes") });
    var printed = false;
    for ([_]struct { text: []const u8, count: u64 }{ .{ .text = "improved", .count = counts.improved }, .{ .text = "no-effect", .count = counts.no_effect }, .{ .text = "regressed", .count = counts.regressed }, .{ .text = "not-judged", .count = counts.not_judged }, .{ .text = "timeout", .count = counts.timeout } }) |item| {
        if (item.count == 0) continue;
        try title.writer.writeAll(if (printed) ", " else " (");
        try title.writer.print("{d} {s}", .{ item.count, item.text });
        printed = true;
    }
    if (printed) try title.writer.writeByte(')');
    try title.writer.writeByte('\n');
    try stdout.writeAll(title.written());

    var write_width: usize = "write".len;
    for (names) |name| write_width = @max(write_width, name.len);
    try stdout.writeAll("  ");
    try writeCell(stdout, "write", write_width);
    for ([_][]const u8{ "result", "verdict" }) |header| {
        try stdout.writeAll("  ");
        try writeCell(stdout, header, 12);
    }
    for ([_][]const u8{ "rows read", "rows written" }) |header| {
        try stdout.writeAll("  ");
        try writeCell(stdout, header, 18);
    }
    try stdout.writeByte('\n');

    for (results) |entry| {
        try stdout.writeAll("  ");
        try result.writeEscapedText(stdout, entry.write);
        if (entry.write.len < write_width) try stdout.splatByteAll(' ', write_width - entry.write.len);
        try stdout.writeAll("  ");
        if (entry.status == .variant_timeout) {
            try writeCell(stdout, "-", 12);
            try stdout.writeAll("  ");
            try writeCell(stdout, "timeout", 12);
            try stdout.writeAll("  ");
            try writeCell(stdout, "-", 18);
            try stdout.writeAll("  ");
            try writeCell(stdout, "-", 18);
            try stdout.writeByte('\n');
            continue;
        }
        try writeCell(stdout, if (entry.baseline_missing) "variant-only" else resultText(entry.outcome orelse .match), 12);
        try stdout.writeAll("  ");
        try writeCell(stdout, entry.judgement.text(), 12);
        try stdout.writeAll("  ");
        var read_buffer: [48]u8 = undefined;
        try writeCell(stdout, rowsText(&read_buffer, entry.rows_read, entry.variant_read, entry.baseline_missing, entry.ran), 18);
        try stdout.writeAll("  ");
        var written_buffer: [48]u8 = undefined;
        try writeCell(stdout, rowsText(&written_buffer, entry.rows_written, entry.variant_written, entry.baseline_missing, entry.ran), 18);
        try stdout.writeByte('\n');
    }
    try stdout.writeAll("\n");
    try format.writeWrapped(stdout, "note: " ++ note, 0, 0);
    try stdout.writeByte('\n');
}

fn rowsText(buffer: []u8, rows: ?Rows, variant: u64, variant_only: bool, ran: bool) []const u8 {
    if (rows) |pair| return std.fmt.bufPrint(buffer, "{d} -> {d}", .{ pair.baseline, pair.variant }) catch "-";
    if (!ran or !variant_only) return "-";
    return std.fmt.bufPrint(buffer, "- -> {d}", .{variant}) catch "-";
}

const VerdictCounts = struct {
    improved: u64 = 0,
    no_effect: u64 = 0,
    regressed: u64 = 0,
    not_judged: u64 = 0,
    timeout: u64 = 0,
};

fn countVerdicts(results: []const Result) VerdictCounts {
    var counts: VerdictCounts = .{};
    for (results) |entry| {
        switch (entry.status) {
            .variant_timeout => counts.timeout += 1,
            .compared => switch (entry.judgement) {
                .improved => counts.improved += 1,
                .no_effect => counts.no_effect += 1,
                .regressed => counts.regressed += 1,
                .not_judged, .needs_check => counts.not_judged += 1,
            },
        }
    }
    return counts;
}

fn resultText(verdict: cli_comparison.Verdict) []const u8 {
    return switch (verdict) {
        .match => "match",
        .mismatch => "mismatch",
        .incomparable => "incomparable",
    };
}

fn word(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

fn writeCell(writer: *Io.Writer, text: []const u8, width: usize) Io.Writer.Error!void {
    try writer.writeAll(text);
    if (text.len < width) try writer.splatByteAll(' ', width - text.len);
}

test {
    _ = @import("batch_writes_tests.zig");
}
