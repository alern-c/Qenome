const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const result = @import("../result.zig");
const model = @import("model.zig");
const Stats = model.Stats;

pub const line_width = 80;

pub const value_column = 16;

pub const measure_warmup = "1 per copy (the run whose rows were compared, not timed)";
pub const measure_order = "each round: baseline-baseline A/A, then alternating baseline-variant or variant-baseline (ABBA)";
pub const measure_scope = "sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed";
pub const measure_cache = "warm; each copy reuses its connection and page cache, and its file was just written";
pub const write_measure_warmup = "none (every run starts from the same rows)";
pub const write_measure_order = "baseline then variant; every run is rolled back";
pub const write_measure_scope = "sqlite3_step from the reset statement to SQLITE_DONE; rows written includes secondary-index inserts, triggers, and foreign-key cascades, but not secondary-index deletes";
pub const write_measure_cache = "warm; each copy reuses its connection and page cache";

pub const d1_caution = "the times are measured on this local copy; they do not guarantee the speed on production D1";

pub fn writeD1VersionNote(writer: *Io.Writer, sqlite_version: [*:0]const u8, d1_sqlite_version: []const u8) Io.Writer.Error!void {
    try writer.print(
        "SQLite {s} here (bundled, runs the comparison) and SQLite {s} in D1; plans and times can differ",
        .{ sqlite_version, d1_sqlite_version },
    );
}

pub fn writeStats(stdout: *Io.Writer, key: []const u8, stats: Stats) Io.Writer.Error!void {
    try stdout.print("{s}: median={d} p25={d} p75={d} min={d} max={d} (median ", .{ key, stats.median, stats.p25, stats.p75, stats.min, stats.max });
    try writeDuration(stdout, stats.median);
    try stdout.writeAll(")\n");
}

pub fn writeDuration(writer: *Io.Writer, ns: u64) Io.Writer.Error!void {
    if (ns < 1000) return writer.print("{d} ns", .{ns});
    const units = [_]struct { name: []const u8, ns: f64 }{
        .{ .name = "us", .ns = 1e3 },
        .{ .name = "ms", .ns = 1e6 },
    };
    const value: f64 = @floatFromInt(ns);
    for (units) |unit| {
        const hundredths = @round(value / unit.ns * 100);
        if (hundredths < 100_000) return writer.print("{d:.2} {s}", .{ hundredths / 100, unit.name });
    }
    return writer.print("{d:.2} s", .{value / 1e9});
}

pub fn writeLabel(stdout: *Io.Writer, label: []const u8) Io.Writer.Error!void {
    try stdout.print("  {s}", .{label});
    const used = 2 + label.len;
    try writeIndent(stdout, if (used < value_column) value_column - used else 1);
}

pub fn writeField(stdout: *Io.Writer, label: []const u8, value: []const u8) Io.Writer.Error!void {
    try writeLabel(stdout, label);
    try writeWrapped(stdout, value, value_column, value_column);
    try stdout.writeByte('\n');
}

pub fn writeIndent(writer: *Io.Writer, count: usize) Io.Writer.Error!void {
    try writer.splatByteAll(' ', count);
}

pub fn writeWrapped(writer: *Io.Writer, text: []const u8, column: usize, indent: usize) Io.Writer.Error!void {
    var at = column;
    var first = true;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (!first) {
            if (at + 1 + word.len > line_width) {
                try writer.writeByte('\n');
                const hang: usize = if (indent + word.len > line_width and word.len <= line_width) 0 else indent;
                try writeIndent(writer, hang);
                at = hang;
            } else {
                try writer.writeByte(' ');
                at += 1;
            }
        }
        try writer.writeAll(word);
        at += word.len;
        first = false;
    }
}

pub fn writeCount(writer: *Io.Writer, value: u128) Io.Writer.Error!void {
    var digits_buffer: [40]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{value}) catch unreachable;
    for (digits, 0..) |digit, at| {
        if (at != 0 and (digits.len - at) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

pub fn writeSigned(writer: *Io.Writer, value: i128) Io.Writer.Error!void {
    if (value > 0) try writer.writeByte('+');
    if (value < 0) try writer.writeByte('-');
    try writeCount(writer, @abs(value));
}

pub fn writeMebibytes(writer: *Io.Writer, bytes: i128) Io.Writer.Error!void {
    const mib = @as(f64, @floatFromInt(@abs(bytes))) / (1024 * 1024);
    const sign: []const u8 = if (bytes > 0) "+" else if (bytes < 0) "-" else "";
    try writer.print("{s}{d:.2} MiB", .{ sign, mib });
}

pub fn writeBind(writer: *Io.Writer, bind: db.BindArg, show: bool) Io.Writer.Error!void {
    try writer.print("{d}:", .{bind.number});
    if (!show) {
        switch (bind.value) {
            .text => |value| try writer.print("text ({d} bytes)", .{value.len}),
            else => |value| try writer.print("{t}", .{value}),
        }
        return;
    }
    switch (bind.value) {
        .int => |value| try writer.print("int:{d}", .{value}),
        .real => |value| try writer.print("real:{e}", .{value}),
        .text => |value| {
            try writer.writeAll("text:");
            try result.writeText(writer, value);
        },
        .null => try writer.writeAll("null"),
    }
}

test {
    _ = @import("format_tests.zig");
}
