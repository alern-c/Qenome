const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("../cli.zig");
const cli_skill = @import("skill.zig");
const skill = @import("../skill/skill.zig");

const testing = std.testing;

const Result = struct {
    code: cli.ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

const Home = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Home {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .path = path, .arena = .init(testing.allocator) };
    }

    fn deinit(self: *Home) void {
        self.arena.deinit();
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn allocator(self: *Home) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn join(self: *Home, parts: []const []const u8) ![]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.arena.allocator());
        try list.append(self.arena.allocator(), self.path);
        for (parts) |part| try list.append(self.arena.allocator(), part);
        return std.fs.path.join(self.arena.allocator(), list.items);
    }

    fn skillPath(self: *Home, agent: []const u8) ![]const u8 {
        return self.join(&.{ agent, "skills", "qenome", "SKILL.md" });
    }

    fn readFile(self: *Home, path: []const u8) !?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, path, self.arena.allocator(), .limited(skill.max_skill_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |other| other,
        };
    }

    fn writeFile(_: *Home, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try Io.Dir.cwd().createDirPath(testing.io, parent);
        }
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    }
};

fn callRun(
    home: ?[]const u8,
    stdin_text: []const u8,
    argv: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) Result {
    var stdin = Io.Reader.fixed(stdin_text);
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const context: cli.Context = .{ .home = home, .stdin = &stdin };
    const code = cli.run(testing.io, testing.allocator, argv, context, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

fn callSkill(
    directory: Io.Dir,
    home: ?[]const u8,
    stdin_text: []const u8,
    argv: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) Result {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var stdin = Io.Reader.fixed(stdin_text);
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = cli_skill.run(testing.io, arena_state.allocator(), argv, home, &stdin, directory, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

fn callSkillInCwd(
    directory: Io.Dir,
    home: ?[]const u8,
    stdin_text: []const u8,
    argv: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) !Result {
    const original_path = try Io.Dir.cwd().realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(original_path);
    var original = try Io.Dir.cwd().openDir(testing.io, original_path, .{});
    defer original.close(testing.io);
    try std.process.setCurrentDir(testing.io, directory);
    defer std.process.setCurrentDir(testing.io, original) catch {};
    return callSkill(directory, home, stdin_text, argv, stdout_buffer, stderr_buffer);
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "print writes the embedded skill and exits with status 0" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "print" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expectEqualStrings(skill.content, result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "the skill help lists the subcommands" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "--help" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "qenome skill install"));
    try testing.expect(contains(result.stdout, "qenome skill uninstall"));
    try testing.expect(contains(result.stdout, "~/.claude/skills/qenome/SKILL.md"));
    try testing.expect(contains(result.stdout, "~/.agents/skills/qenome/SKILL.md"));
}

test "a missing subcommand and an unknown option are usage errors" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const missing = callRun(home.path, "", &.{ "Qenome", "skill" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.usage, missing.code);
    try testing.expect(contains(missing.stderr, "needs a subcommand"));

    var second_stdout: [4096]u8 = undefined;
    var second_stderr: [4096]u8 = undefined;
    const unknown = callRun(home.path, "", &.{ "Qenome", "skill", "install", "--force" }, &second_stdout, &second_stderr);
    try testing.expectEqual(cli.ExitCode.usage, unknown.code);
    try testing.expect(contains(unknown.stderr, "unknown option '--force'"));
}

test "install writes the skill into a detected agent directory" {
    var home = try Home.init();
    defer home.deinit();
    try Io.Dir.cwd().createDirPath(testing.io, try home.join(&.{".claude"}));
    const path = try home.skillPath(".claude");

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const first = callRun(home.path, "", &.{ "Qenome", "skill", "install" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, first.code);
    try testing.expect(contains(first.stdout, "installed"));
    try testing.expect(!contains(first.stdout, ".agents"));
    const installed = (try home.readFile(path)).?;
    try testing.expectEqualStrings(skill.content, installed);

    var second_stdout: [8192]u8 = undefined;
    var second_stderr: [4096]u8 = undefined;
    const second = callRun(home.path, "", &.{ "Qenome", "skill", "install" }, &second_stdout, &second_stderr);
    try testing.expectEqual(cli.ExitCode.ok, second.code);
    try testing.expect(contains(second.stdout, "up to date"));
}

test "install falls back to the cross-agent directory when nothing is detected" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "install" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, ".agents"));
    const path = try home.skillPath(".agents");
    try testing.expect((try home.readFile(path)) != null);
}

test "install --dry-run writes nothing" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "install", "--target", "claude", "--dry-run" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "would install"));
    const path = try home.skillPath(".claude");
    try testing.expect((try home.readFile(path)) == null);
}

test "install shows a diff and keeps a modified file when the answer is no" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    try home.writeFile(path, "---\nname: qenome\ndescription: my notes\n---\n");

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "n\n", &.{ "Qenome", "skill", "install", "--target", "claude" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.rejected, result.code);
    try testing.expect(contains(result.stdout, "--- "));
    try testing.expect(contains(result.stdout, "+++ qenome skill (this binary)"));
    try testing.expect(contains(result.stdout, "description: my notes"));
    try testing.expect(contains(result.stdout, "skipped"));
    try testing.expectEqualStrings("---\nname: qenome\ndescription: my notes\n---\n", (try home.readFile(path)).?);
}

test "install overwrites a modified file when the answer is yes" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    try home.writeFile(path, "old copy\n");

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "y\n", &.{ "Qenome", "skill", "install", "--target", "claude" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "overwrote"));
    try testing.expectEqualStrings(skill.content, (try home.readFile(path)).?);
}

test "install --yes overwrites without reading the answer" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    try home.writeFile(path, "old copy\n");

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "install", "--target", "claude", "--yes" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "overwrote"));
    try testing.expectEqualStrings(skill.content, (try home.readFile(path)).?);
}

test "status reports missing, up to date, and modified copies" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    const argv = [_][:0]const u8{ "Qenome", "skill", "status", "--target", "claude" };

    var first_stdout: [8192]u8 = undefined;
    var first_stderr: [4096]u8 = undefined;
    const missing = callRun(home.path, "", &argv, &first_stdout, &first_stderr);
    try testing.expectEqual(cli.ExitCode.ok, missing.code);
    try testing.expect(contains(missing.stdout, "not installed"));

    try home.writeFile(path, skill.content);
    var second_stdout: [8192]u8 = undefined;
    var second_stderr: [4096]u8 = undefined;
    const current = callRun(home.path, "", &argv, &second_stdout, &second_stderr);
    try testing.expectEqual(cli.ExitCode.ok, current.code);
    try testing.expect(contains(current.stdout, "up to date"));

    try home.writeFile(path, "edited\n");
    var third_stdout: [8192]u8 = undefined;
    var third_stderr: [4096]u8 = undefined;
    const modified = callRun(home.path, "", &argv, &third_stdout, &third_stderr);
    try testing.expectEqual(cli.ExitCode.ok, modified.code);
    try testing.expect(contains(modified.stdout, "differs from this binary's copy"));
}

test "uninstall removes the copy that qenome installed after confirmation" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    try home.writeFile(path, skill.content);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "y\n", &.{ "Qenome", "skill", "uninstall", "--target", "claude" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "removed"));
    try testing.expect((try home.readFile(path)) == null);

    var second_stdout: [8192]u8 = undefined;
    var second_stderr: [4096]u8 = undefined;
    const again = callRun(home.path, "", &.{ "Qenome", "skill", "uninstall", "--target", "claude", "--yes" }, &second_stdout, &second_stderr);
    try testing.expectEqual(cli.ExitCode.ok, again.code);
    try testing.expect(contains(again.stdout, "not installed"));
}

test "uninstall keeps a modified file and a skipped answer removes nothing" {
    var home = try Home.init();
    defer home.deinit();
    const path = try home.skillPath(".claude");
    try home.writeFile(path, skill.content);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const skipped = callRun(home.path, "n\n", &.{ "Qenome", "skill", "uninstall", "--target", "claude" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.rejected, skipped.code);
    try testing.expect(contains(skipped.stdout, "skipped"));
    try testing.expect((try home.readFile(path)) != null);

    try home.writeFile(path, "edited\n");
    var second_stdout: [8192]u8 = undefined;
    var second_stderr: [4096]u8 = undefined;
    const kept = callRun(home.path, "", &.{ "Qenome", "skill", "uninstall", "--target", "claude", "--yes" }, &second_stdout, &second_stderr);
    try testing.expectEqual(cli.ExitCode.rejected, kept.code);
    try testing.expect(contains(kept.stdout, "kept"));
    try testing.expectEqualStrings("edited\n", (try home.readFile(path)).?);
}

test "uninstall keeps a copy reached through a symbolic link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var home = try Home.init();
    defer home.deinit();
    try home.tmp.dir.createDirPath(testing.io, "shared");
    try home.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared/SKILL.md", .data = skill.content });
    try home.tmp.dir.createDirPath(testing.io, ".claude/skills");
    const target = try home.join(&.{"shared"});
    try home.tmp.dir.symLink(testing.io, target, ".claude/skills/qenome", .{ .is_directory = true });

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(home.path, "", &.{ "Qenome", "skill", "uninstall", "--target", "claude", "--yes" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.rejected, result.code);
    try testing.expect(contains(result.stdout, "kept"));
    const shared = try home.join(&.{"shared/SKILL.md"});
    try testing.expectEqualStrings(skill.content, (try home.readFile(shared)).?);
}

test "the project option writes under the given directory" {
    var home = try Home.init();
    defer home.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callSkill(home.tmp.dir, null, "", &.{ "install", "--project", "--target", "agents" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "installed"));
    const path = try home.skillPath(".agents");
    try testing.expectEqualStrings(skill.content, (try home.readFile(path)).?);

    var status_stdout: [8192]u8 = undefined;
    var status_stderr: [4096]u8 = undefined;
    const status = callSkill(home.tmp.dir, null, "", &.{ "status", "--project", "--target", "agents" }, &status_stdout, &status_stderr);
    try testing.expectEqual(cli.ExitCode.ok, status.code);
    try testing.expect(contains(status.stdout, "up to date"));
}

test "install with an empty or relative home writes nothing" {
    var home = try Home.init();
    defer home.deinit();
    const cases = [_]?[]const u8{ "", "relative-home" };
    for (cases) |value| {
        var stdout_buffer: [8192]u8 = undefined;
        var stderr_buffer: [4096]u8 = undefined;
        const result = try callSkillInCwd(home.tmp.dir, value, "", &.{ "install", "--yes" }, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(cli.ExitCode.rejected, result.code);
        try testing.expect(contains(result.stderr, "home directory"));
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectError(error.FileNotFound, home.tmp.dir.access(testing.io, ".agents", .{}));
        try testing.expectError(error.FileNotFound, home.tmp.dir.access(testing.io, ".claude", .{}));
    }
}

test "a missing home directory is reported instead of writing elsewhere" {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(null, "", &.{ "Qenome", "skill", "install" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.rejected, result.code);
    try testing.expect(contains(result.stderr, "home directory"));
    try testing.expectEqualStrings("", result.stdout);
}
