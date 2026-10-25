const std = @import("std");
const Io = std.Io;

const Qenome = @import("Qenome");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const temp_parent = Qenome.cli.tempParent(init.environ_map);
    const code = Qenome.cli.run(io, init.gpa, argv, temp_parent, stdout, stderr);

    try stdout.flush();
    stderr.flush() catch {};
    if (code != .ok) std.process.exit(@backingInt(code));
}
