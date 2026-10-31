const std = @import("std");
const Io = std.Io;
const cli_args = @import("args.zig");

pub const inline_label: [:0]const u8 = "--sql";

pub const Loaded = struct {
    label: [:0]const u8,
    sql: [:0]const u8,
};

pub fn loadSelect(
    io: Io,
    allocator: std.mem.Allocator,
    stdin: ?*Io.Reader,
    sql: ?[:0]const u8,
    path: ?[:0]const u8,
    stderr: *Io.Writer,
) ?Loaded {
    if (sql) |text| {
        const copy = copySql(allocator, text) catch |err| {
            reportSql(stderr, "--sql", err);
            return null;
        };
        return .{ .label = inline_label, .sql = copy };
    }
    const file = path orelse {
        stderr.writeAll("error: missing the SELECT (see --help)\n") catch {};
        return null;
    };
    if (std.mem.eql(u8, file, "-")) {
        const reader = stdin orelse {
            stderr.writeAll("error: - reads the SELECT from stdin, and stdin is not available\n") catch {};
            return null;
        };
        const copy = readReader(allocator, reader) catch |err| {
            reportSql(stderr, "stdin", err);
            return null;
        };
        return .{ .label = file, .sql = copy };
    }
    const data = cli_args.readSqlFile(io, allocator, file) catch |err| {
        reportFile(stderr, "--select", file, err);
        return null;
    };
    return .{ .label = file, .sql = data };
}

fn copySql(allocator: std.mem.Allocator, text: []const u8) ![:0]u8 {
    if (text.len == 0) return error.Empty;
    if (text.len > cli_args.max_sql_bytes) return error.SqlFileTooLarge;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.SqlFileContainsNul;
    return allocator.dupeSentinel(u8, text, 0);
}

fn readReader(allocator: std.mem.Allocator, reader: *Io.Reader) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (list.items.len <= cli_args.max_sql_bytes) {
        const room = cli_args.max_sql_bytes + 1 - list.items.len;
        const n = reader.readSliceShort(buffer[0..@min(buffer.len, room)]) catch return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
    }
    if (list.items.len > cli_args.max_sql_bytes) return error.SqlFileTooLarge;
    if (list.items.len == 0) return error.Empty;
    if (std.mem.indexOfScalar(u8, list.items, 0) != null) return error.SqlFileContainsNul;
    return try list.toOwnedSliceSentinel(allocator, 0);
}

fn reportSql(stderr: *Io.Writer, source: []const u8, err: anyerror) void {
    const detail = switch (err) {
        error.Empty => "the SQL is empty",
        error.SqlFileTooLarge => "the SQL is larger than 1 MiB",
        error.SqlFileContainsNul => "the SQL contains a NUL byte",
        error.ReadFailed => "the read failed",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    stderr.print("error: cannot use the SQL from {s}: {s}\n", .{ source, detail }) catch {};
}

fn reportFile(stderr: *Io.Writer, option: []const u8, path: []const u8, err: anyerror) void {
    stderr.print("error: cannot read {s} file '{s}': {s}", .{ option, path, cli_args.fileErrorMessage(err) }) catch {};
    if (cli_args.looksLikeSql(path)) {
        stderr.print("; {s} takes a path to a file holding the SQL, not the SQL text. Pass --sql to give the SQL directly", .{option}) catch {};
    }
    stderr.writeByte('\n') catch {};
}

test {
    _ = @import("sql_input_tests.zig");
}
