const std = @import("std");
const Io = std.Io;

pub const sqlite = @import("sqlite.zig");
pub const db = @import("db.zig");
pub const result = @import("result.zig");
pub const cli = @import("cli.zig");

pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test {
    _ = @import("sqlite.zig");
    _ = @import("db.zig");
    _ = @import("result.zig");
    _ = @import("cli.zig");
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
