const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const format = @import("format.zig");
const writeDuration = format.writeDuration;
const writeSigned = format.writeSigned;
const writeField = format.writeField;
const measure_scope = format.measure_scope;

test "a duration keeps under 1000 of its unit after rounding" {
    const cases = [_]struct { ns: u64, text: []const u8 }{
        .{ .ns = 0, .text = "0 ns" },
        .{ .ns = 999, .text = "999 ns" },
        .{ .ns = 1000, .text = "1.00 us" },
        .{ .ns = 26_521, .text = "26.52 us" },
        .{ .ns = 999_994, .text = "999.99 us" },
        .{ .ns = 999_999, .text = "1.00 ms" },
        .{ .ns = 3_006_771, .text = "3.01 ms" },
        .{ .ns = 999_999_999, .text = "1.00 s" },
        .{ .ns = 61_500_000_000, .text = "61.50 s" },
    };
    for (cases) |case| {
        var buffer: [32]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try writeDuration(&writer, case.ns);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
}

test "counts get a comma between groups of three digits" {
    const cases = [_]struct { value: i128, text: []const u8 }{
        .{ .value = 0, .text = "0" },
        .{ .value = 999, .text = "+999" },
        .{ .value = 1000, .text = "+1,000" },
        .{ .value = -199_999, .text = "-199,999" },
        .{ .value = 2_170_880, .text = "+2,170,880" },
    };
    for (cases) |case| {
        var buffer: [48]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try writeSigned(&writer, case.value);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
}

test "wrapped text breaks at spaces within the width under its own column" {
    var buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeField(&writer, "scope", measure_scope);
    try testing.expectEqualStrings(
        \\  scope         sqlite3_step from the reset statement to SQLITE_DONE with the
        \\                interrupt checks; columns are not read; prepare, bind, and the
        \\                plan read are not timed
        \\
    , writer.buffered());
}

test "a token that does not fit the hanging indent starts at the left edge" {
    var buffer: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const path = "0123456789012345678901234567890123456789012345678901234567890123456789";
    try writeField(&writer, "next", "qenome " ++ path);
    try testing.expectEqualStrings("  next          qenome\n" ++ path ++ "\n", writer.buffered());
}
