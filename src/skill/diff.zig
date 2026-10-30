const std = @import("std");
const Io = std.Io;

pub const max_cells = 250_000;

pub const context_lines = 3;

const Kind = enum { context, removed, added };

const Op = struct {
    kind: Kind,
    text: []const u8,
};

pub fn render(allocator: std.mem.Allocator, path: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.print("--- {s} (installed)\n+++ qenome skill (this binary)\n", .{path});
    const old_lines = try splitLines(arena, old);
    const new_lines = try splitLines(arena, new);
    const ops = try operations(arena, old_lines, new_lines);
    if (!std.mem.eql(u8, old, new) and !changed(ops)) {
        try out.writer.writeAll("(the installed file differs only in the final newline)\n");
        return allocator.dupe(u8, out.written());
    }
    try writeHunks(arena, &out.writer, ops);
    return allocator.dupe(u8, out.written());
}

fn changed(ops: []const Op) bool {
    for (ops) |op| {
        if (op.kind != .context) return true;
    }
    return false;
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return lines.toOwnedSlice(allocator);
    const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    if (body.len == 0) return lines.toOwnedSlice(allocator);
    var parts = std.mem.splitScalar(u8, body, '\n');
    while (parts.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

fn operations(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) ![]const Op {
    var ops: std.ArrayList(Op) = .empty;
    const old_count = old_lines.len;
    const new_count = new_lines.len;
    if (old_count == 0 or new_count == 0 or old_count * new_count > max_cells) {
        for (old_lines) |line| try ops.append(allocator, .{ .kind = .removed, .text = line });
        for (new_lines) |line| try ops.append(allocator, .{ .kind = .added, .text = line });
        return ops.toOwnedSlice(allocator);
    }
    const columns = new_count + 1;
    const table = try allocator.alloc(u32, (old_count + 1) * columns);
    for (0..old_count + 1) |row| table[row * columns] = 0;
    for (0..new_count + 1) |column| table[column] = 0;
    for (1..old_count + 1) |row| {
        for (1..new_count + 1) |column| {
            table[row * columns + column] = if (std.mem.eql(u8, old_lines[row - 1], new_lines[column - 1]))
                table[(row - 1) * columns + column - 1] + 1
            else
                @max(table[(row - 1) * columns + column], table[row * columns + column - 1]);
        }
    }
    var row = old_count;
    var column = new_count;
    while (row > 0 or column > 0) {
        if (row > 0 and column > 0 and std.mem.eql(u8, old_lines[row - 1], new_lines[column - 1])) {
            try ops.append(allocator, .{ .kind = .context, .text = old_lines[row - 1] });
            row -= 1;
            column -= 1;
        } else if (column > 0 and (row == 0 or table[row * columns + column - 1] >= table[(row - 1) * columns + column])) {
            try ops.append(allocator, .{ .kind = .added, .text = new_lines[column - 1] });
            column -= 1;
        } else {
            try ops.append(allocator, .{ .kind = .removed, .text = old_lines[row - 1] });
            row -= 1;
        }
    }
    std.mem.reverse(Op, ops.items);
    reorderRemovedBeforeAdded(ops.items);
    return ops.toOwnedSlice(allocator);
}

fn reorderRemovedBeforeAdded(ops: []Op) void {
    var start: usize = 0;
    while (start < ops.len) {
        if (ops[start].kind == .context) {
            start += 1;
            continue;
        }
        var end = start;
        while (end < ops.len and ops[end].kind != .context) end += 1;
        var write = start;
        var index = start;
        while (index < end) : (index += 1) {
            if (ops[index].kind != .removed) continue;
            const value = ops[index];
            var move = index;
            while (move > write) : (move -= 1) ops[move] = ops[move - 1];
            ops[write] = value;
            write += 1;
        }
        start = end;
    }
}

fn writeHunks(allocator: std.mem.Allocator, writer: *Io.Writer, ops: []const Op) !void {
    if (ops.len == 0) return;
    const old_before = try allocator.alloc(usize, ops.len + 1);
    const new_before = try allocator.alloc(usize, ops.len + 1);
    var old_line: usize = 1;
    var new_line: usize = 1;
    for (ops, 0..) |op, index| {
        old_before[index] = old_line;
        new_before[index] = new_line;
        switch (op.kind) {
            .context => {
                old_line += 1;
                new_line += 1;
            },
            .removed => old_line += 1,
            .added => new_line += 1,
        }
    }
    old_before[ops.len] = old_line;
    new_before[ops.len] = new_line;

    var index: usize = 0;
    while (index < ops.len) {
        if (ops[index].kind == .context) {
            index += 1;
            continue;
        }
        const first = index;
        var last = index;
        while (index < ops.len) {
            if (ops[index].kind != .context) {
                last = index;
                index += 1;
                continue;
            }
            var run: usize = 0;
            while (index + run < ops.len and ops[index + run].kind == .context) : (run += 1) {}
            if (index + run >= ops.len) {
                index = ops.len;
                break;
            }
            if (run > 2 * context_lines) break;
            index += run;
        }
        const start = if (first > context_lines) first - context_lines else 0;
        const end = @min(ops.len, last + context_lines + 1);
        try writer.print("@@ -{d},{d} +{d},{d} @@\n", .{
            old_before[start],
            old_before[end] - old_before[start],
            new_before[start],
            new_before[end] - new_before[start],
        });
        for (ops[start..end]) |op| {
            const marker: u8 = switch (op.kind) {
                .context => ' ',
                .removed => '-',
                .added => '+',
            };
            try writer.writeByte(marker);
            try writer.writeAll(op.text);
            try writer.writeByte('\n');
        }
    }
}

const testing = std.testing;

test "an identical file has no line changes" {
    const text = "alpha\nbeta\n";
    const rendered = try render(testing.allocator, "SKILL.md", text, text);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("--- SKILL.md (installed)\n+++ qenome skill (this binary)\n", rendered);
}

test "an added trailing blank line is shown" {
    const rendered = try render(testing.allocator, "SKILL.md", "alpha\nbeta\n", "alpha\nbeta\n\n");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "@@ -1,2 +1,3 @@\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, " alpha\n beta\n+\n") != null);
}

test "a missing final newline is named" {
    const rendered = try render(testing.allocator, "SKILL.md", "alpha\nbeta", "alpha\nbeta\n");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "differs only in the final newline") != null);
}

test "a removed trailing blank line is shown" {
    const rendered = try render(testing.allocator, "SKILL.md", "alpha\n\n", "alpha\n");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "-\n") != null);
}

test "a changed line is shown once as removed and added" {
    const old = "alpha\nbeta\ngamma\n";
    const new = "alpha\nBETA\ngamma\n";
    const rendered = try render(testing.allocator, "SKILL.md", old, new);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "@@ -1,3 +1,3 @@\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, " alpha\n-beta\n+BETA\n gamma\n") != null);
}

test "an added line comes after the unchanged context" {
    const old = "alpha\ngamma\n";
    const new = "alpha\nbeta\ngamma\n";
    const rendered = try render(testing.allocator, "SKILL.md", old, new);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, " alpha\n+beta\n gamma\n") != null);
}

test "two distant changes become two hunks with context" {
    var old_buffer: [1024]u8 = undefined;
    var new_buffer: [1024]u8 = undefined;
    var old = Io.Writer.fixed(&old_buffer);
    var new = Io.Writer.fixed(&new_buffer);
    for (0..20) |index| {
        try old.print("line {d}\n", .{index});
        if (index == 1 or index == 18) {
            try new.print("line {d} changed\n", .{index});
        } else {
            try new.print("line {d}\n", .{index});
        }
    }
    const rendered = try render(testing.allocator, "SKILL.md", old.buffered(), new.buffered());
    defer testing.allocator.free(rendered);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "@@ -"));
    try testing.expect(std.mem.indexOf(u8, rendered, "-line 1\n+line 1 changed\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "-line 18\n+line 18 changed\n") != null);
}

test "an empty installed file shows every new line" {
    const new = "alpha\nbeta\n";
    const rendered = try render(testing.allocator, "SKILL.md", "", new);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "+alpha\n+beta\n") != null);
}

test "the same output is produced twice" {
    const old = "alpha\nbeta\n";
    const new = "alpha\ngamma\ndelta\n";
    const first = try render(testing.allocator, "SKILL.md", old, new);
    defer testing.allocator.free(first);
    const second = try render(testing.allocator, "SKILL.md", old, new);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}
