const std = @import("std");
const Io = std.Io;
const cli_comparison = @import("../cli/comparison.zig");
const batch_writes = @import("batch_writes.zig");

const testing = std.testing;

fn compared(write: []const u8, judgement: cli_comparison.RowVerdict) batch_writes.Result {
    return .{
        .write = write,
        .candidate = "drop.sql",
        .status = .compared,
        .outcome = .match,
        .judgement = judgement,
        .rows_read = .{ .baseline = 1, .variant = 2000 },
        .rows_written = .{ .baseline = 2000, .variant = 4000 },
        .comparison = "{}",
    };
}

test "the human writes section reports the rows of both copies and the counting limit" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const results = [_]batch_writes.Result{
        compared("w/update.sql", .regressed),
        compared("w/delete.sql", .no_effect),
    };
    try batch_writes.writeHuman(&stdout, testing.allocator, &results);
    const output = stdout.buffered();
    try testing.expect(std.mem.startsWith(u8, output, "\nWrites: 2 writes (1 no-effect, 1 regressed)\n"));
    try testing.expect(std.mem.indexOf(u8, output, "w/update.sql") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1 -> 2000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2000 -> 4000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "regressed") != null);
    try testing.expect(std.mem.indexOf(u8, output, "note: rows written counts") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secondary-index") != null);
}

test "the human writes section names a timeout without rows" {
    var buffer: [2048]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const results = [_]batch_writes.Result{.{
        .write = "w/slow.sql",
        .candidate = "drop.sql",
        .status = .variant_timeout,
    }};
    try batch_writes.writeHuman(&stdout, testing.allocator, &results);
    const output = stdout.buffered();
    try testing.expect(std.mem.startsWith(u8, output, "\nWrites: 1 write (1 timeout)\n"));
    try testing.expect(std.mem.indexOf(u8, output, "timeout") != null);
    try testing.expect(std.mem.indexOf(u8, output, "->") == null);
}

test "the human writes section shows the variant rows of a write the baseline cannot run" {
    var buffer: [2048]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const results = [_]batch_writes.Result{.{
        .write = "w/email.sql",
        .candidate = "add.sql",
        .status = .compared,
        .baseline_missing = true,
        .judgement = .not_judged,
        .variant_read = 3,
        .variant_written = 6,
    }};
    try batch_writes.writeHuman(&stdout, testing.allocator, &results);
    const output = stdout.buffered();
    try testing.expect(std.mem.startsWith(u8, output, "\nWrites: 1 write (1 not-judged)\n"));
    try testing.expect(std.mem.indexOf(u8, output, "- -> 3") != null);
    try testing.expect(std.mem.indexOf(u8, output, "- -> 6") != null);
}

test "the json writes array carries the status and the embedded comparison" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    const results = [_]batch_writes.Result{
        .{
            .write = "w/update.sql",
            .candidate = "drop.sql",
            .status = .compared,
            .outcome = .match,
            .judgement = .regressed,
            .rows_read = .{ .baseline = 1, .variant = 2000 },
            .rows_written = .{ .baseline = 2000, .variant = 4000 },
            .comparison = "{\"verdict\":\"regressed\"}",
        },
        .{ .write = "w/slow.sql", .candidate = "drop.sql", .status = .variant_timeout },
    };
    try batch_writes.writeJson(&json, testing.allocator, &results);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const entries = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("w/update.sql", entries[0].object.get("write").?.string);
    try testing.expectEqualStrings("drop.sql", entries[0].object.get("candidate").?.string);
    try testing.expectEqualStrings("compared", entries[0].object.get("status").?.string);
    try testing.expectEqualStrings("regressed", entries[0].object.get("comparison").?.object.get("verdict").?.string);
    try testing.expectEqualStrings("variant_timeout", entries[1].object.get("status").?.string);
    try testing.expect(entries[1].object.get("comparison").? == .null);
}

test "the human writes section names a variant-only write and hides rows it did not measure" {
    var buffer: [2048]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const results = [_]batch_writes.Result{.{
        .write = "w/random.sql",
        .candidate = "add.sql",
        .status = .compared,
        .baseline_missing = true,
        .judgement = .not_judged,
        .ran = false,
    }};
    try batch_writes.writeHuman(&stdout, testing.allocator, &results);
    const output = stdout.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "variant-only") != null);
    try testing.expect(std.mem.indexOf(u8, output, "not-judged") != null);
    try testing.expect(std.mem.indexOf(u8, output, "->") == null);
}
