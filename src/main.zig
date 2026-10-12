const std = @import("std");
const Io = std.Io;

const Qenome = @import("Qenome");

pub fn main(init: std.process.Init) !void {
    // Command line arguments and transient CLI state live in the process
    // arena; `cli.run` gets the general allocator for its own arena.
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const io = init.io;

    // Stdout carries the summary, stderr carries diagnostics. Both are flushed
    // before the process exits with the code that `cli.run` decided.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // The snapshot lives in a private directory under TMPDIR.
    const temp_parent = init.environ_map.get("TMPDIR");
    const code = Qenome.cli.run(io, init.gpa, argv, temp_parent, stdout, stderr);

    try stdout.flush();
    // Diagnostics that cannot be written do not change the outcome, which
    // the exit code and stdout already carry.
    stderr.flush() catch {};
    if (code != .ok) std.process.exit(@backingInt(code));
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try command `zig build test --fuzz -Doptimize=ReleaseFast` to see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
