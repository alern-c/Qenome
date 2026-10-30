const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const diff = @import("diff.zig");

pub const content: []const u8 = @embedFile("qenome_skill");

pub const max_skill_bytes = 1024 * 1024;

pub const renderDiff = diff.render;

pub const Target = enum {
    claude,
    agents,

    pub fn name(self: Target) []const u8 {
        return @tagName(self);
    }

    pub fn directoryName(self: Target) []const u8 {
        return switch (self) {
            .claude => ".claude",
            .agents => ".agents",
        };
    }
};

pub const all_targets = [_]Target{ .claude, .agents };

pub const Scope = enum { user, project };

pub const Targets = struct {
    claude: bool = false,
    agents: bool = false,
    explicit: bool = false,

    pub fn has(self: Targets, target: Target) bool {
        return switch (target) {
            .claude => self.claude,
            .agents => self.agents,
        };
    }

    pub fn add(self: *Targets, target: Target) void {
        switch (target) {
            .claude => self.claude = true,
            .agents => self.agents = true,
        }
    }

    pub fn any(self: Targets) bool {
        return self.claude or self.agents;
    }

    pub fn count(self: Targets) usize {
        return @as(usize, @intFromBool(self.claude)) + @intFromBool(self.agents);
    }
};

pub const Options = struct {
    scope: Scope = .user,
    targets: Targets = .{},
    dry_run: bool = false,
    yes: bool = false,
};

pub const Command = union(enum) {
    print,
    install: Options,
    uninstall: Options,
    status: Options,
    help,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownOption,
    UnsupportedOption,
    UnexpectedArgument,
    MissingValue,
    UnknownTarget,
};

const Kind = enum { print, install, uninstall, status };

fn parseKind(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "print")) return .print;
    if (std.mem.eql(u8, name, "install")) return .install;
    if (std.mem.eql(u8, name, "uninstall")) return .uninstall;
    if (std.mem.eql(u8, name, "status")) return .status;
    return null;
}

fn targetFromName(name: []const u8) ?Target {
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "agents")) return .agents;
    return null;
}

pub fn parse(argv: []const [:0]const u8) ParseError!Command {
    var offending: ?[]const u8 = null;
    return parseReporting(argv, &offending);
}

pub fn parseReporting(argv: []const [:0]const u8, offending: *?[]const u8) ParseError!Command {
    offending.* = null;
    if (argv.len == 0) return error.MissingSubcommand;
    const name = argv[0];
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "help")) {
        return .help;
    }
    const kind = parseKind(name) orelse {
        offending.* = name;
        return error.UnknownSubcommand;
    };
    var options: Options = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        offending.* = arg;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            offending.* = null;
            return .help;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (kind == .print) return error.UnsupportedOption;
            options.scope = .project;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            if (kind != .install) return error.UnsupportedOption;
            options.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes")) {
            if (kind == .print or kind == .status) return error.UnsupportedOption;
            options.yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            if (kind == .print) return error.UnsupportedOption;
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            try addTargets(&options, argv[index], offending);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            if (kind == .print) return error.UnsupportedOption;
            try addTargets(&options, arg["--target=".len..], offending);
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') return error.UnknownOption;
        return error.UnexpectedArgument;
    }
    offending.* = null;
    return switch (kind) {
        .print => .print,
        .install => .{ .install = options },
        .uninstall => .{ .uninstall = options },
        .status => .{ .status = options },
    };
}

fn addTargets(options: *Options, text: []const u8, offending: *?[]const u8) ParseError!void {
    if (text.len == 0) return error.MissingValue;
    offending.* = text;
    if (std.mem.eql(u8, text, "all")) {
        options.targets.explicit = true;
        for (all_targets) |target| options.targets.add(target);
        return;
    }
    const target = targetFromName(text) orelse return error.UnknownTarget;
    options.targets.explicit = true;
    options.targets.add(target);
}

pub const Location = struct {
    target: Target,
    scope: Scope,
    directory: []const u8,
    path: []const u8,
};

pub const ResolveError = error{HomeNotFound} || std.mem.Allocator.Error;

pub fn resolve(
    io: Io,
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    project_root: []const u8,
    options: Options,
) ResolveError![]Location {
    const root = switch (options.scope) {
        .user => blk: {
            const value = home orelse return error.HomeNotFound;
            if (value.len == 0 or !std.fs.path.isAbsolute(value)) return error.HomeNotFound;
            break :blk value;
        },
        .project => project_root,
    };
    const canonical_root = Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch root;
    const selected = if (options.targets.explicit) options.targets else detect(io, allocator, canonical_root);
    const locations = try allocator.alloc(Location, selected.count());
    var position: usize = 0;
    for (all_targets) |target| {
        if (!selected.has(target)) continue;
        locations[position] = try locate(allocator, canonical_root, options.scope, target);
        position += 1;
    }
    return locations;
}

fn locate(allocator: std.mem.Allocator, root: []const u8, scope: Scope, target: Target) std.mem.Allocator.Error!Location {
    const directory = try std.fs.path.join(allocator, &.{ root, target.directoryName(), "skills", "qenome" });
    const path = try std.fs.path.join(allocator, &.{ directory, "SKILL.md" });
    return .{ .target = target, .scope = scope, .directory = directory, .path = path };
}

fn detect(io: Io, allocator: std.mem.Allocator, root: []const u8) Targets {
    var found: Targets = .{ .explicit = true };
    if (exists(io, allocator, root, ".claude")) found.claude = true;
    if (exists(io, allocator, root, ".agents") or
        exists(io, allocator, root, ".codex") or
        exists(io, allocator, root, ".cursor") or
        exists(io, allocator, root, ".gemini"))
    {
        found.agents = true;
    }
    if (!found.any()) found.agents = true;
    return found;
}

fn exists(io: Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ root, name }) catch return false;
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const State = enum { missing, up_to_date, differs };

pub fn inspect(io: Io, allocator: std.mem.Allocator, location: Location) !State {
    const installed = try read(io, allocator, location) orelse return .missing;
    return if (std.mem.eql(u8, installed, content)) .up_to_date else .differs;
}

pub fn read(io: Io, allocator: std.mem.Allocator, location: Location) !?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, location.path, allocator, .limited(max_skill_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.IsDir => null,
        else => |other| other,
    };
}

pub fn write(io: Io, location: Location) !void {
    try Io.Dir.cwd().createDirPath(io, location.directory);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = location.path, .data = content });
}

pub const RemoveOutcome = enum { removed, missing, differs, linked, directory_kept };

pub fn remove(io: Io, allocator: std.mem.Allocator, location: Location) !RemoveOutcome {
    switch (try inspect(io, allocator, location)) {
        .missing => return .missing,
        .differs => return .differs,
        .up_to_date => {},
    }
    if (try linked(io, allocator, location)) return .linked;
    try Io.Dir.cwd().deleteFile(io, location.path);
    var directory = Io.Dir.cwd().openDir(io, location.directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .removed,
        else => |other| return other,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    const empty = (try iterator.next(io)) == null;
    if (!empty) return .directory_kept;
    Io.Dir.cwd().deleteDir(io, location.directory) catch return .directory_kept;
    return .removed;
}

fn linked(io: Io, allocator: std.mem.Allocator, location: Location) !bool {
    const canonical = Io.Dir.cwd().realPathFileAlloc(io, location.path, allocator) catch return true;
    return !std.mem.eql(u8, canonical, location.path);
}

pub const usage =
    \\usage: qenome skill print
    \\       qenome skill install [--project] [--target <NAME>] [--dry-run] [--yes]
    \\       qenome skill uninstall [--project] [--target <NAME>] [--yes]
    \\       qenome skill status [--project] [--target <NAME>]
    \\
    \\Shows, installs, and removes the bundled Agent Skill (skills/qenome/SKILL.md).
    \\
    \\subcommands:
    \\  print        write the skill to stdout
    \\  install      copy the skill into each detected agent's skills directory
    \\  uninstall    remove the copy that qenome installed
    \\  status       show where the skill is installed and whether it is up to date
    \\
    \\options:
    \\  --project    use the current directory instead of the home directory
    \\  --target <NAME>  claude or agents (repeatable, or all); default: detected
    \\  --dry-run    show what install would do without writing (install only)
    \\  --yes        do not ask before overwriting or removing
    \\  --help, -h   print this message
    \\
    \\targets:
    \\  claude  ~/.claude/skills/qenome/SKILL.md, read by Claude Code
    \\  agents  ~/.agents/skills/qenome/SKILL.md, read by Codex, Cursor, and Gemini CLI
    \\
    \\With --project, the same paths are under the current directory. install keeps
    \\a file that differs from this binary's copy unless you answer yes or pass
    \\--yes. uninstall removes only a regular copy that still matches this binary,
    \\and keeps a copy reached through a symbolic link.
    \\
    \\exit status: 0 done or nothing to do, 1 a file could not be read, written
    \\or removed, or an answer said no, 2 usage error
    \\
;

const testing = std.testing;

fn expectParseError(expected: ParseError, argv: []const [:0]const u8) !void {
    try testing.expectError(expected, parse(argv));
}

test "every subcommand is parsed" {
    try testing.expectEqual(Command.print, try parse(&.{"print"}));
    try testing.expectEqual(Command.help, try parse(&.{"help"}));
    try testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try testing.expectEqual(Command.help, try parse(&.{ "install", "--help" }));

    const install = try parse(&.{ "install", "--project", "--target", "claude", "--target=agents", "--dry-run", "--yes" });
    try testing.expectEqual(Scope.project, install.install.scope);
    try testing.expect(install.install.targets.has(.claude));
    try testing.expect(install.install.targets.has(.agents));
    try testing.expect(install.install.targets.explicit);
    try testing.expect(install.install.dry_run);
    try testing.expect(install.install.yes);

    const status = try parse(&.{"status"});
    try testing.expectEqual(Scope.user, status.status.scope);
    try testing.expect(!status.status.targets.explicit);

    const uninstall = try parse(&.{ "uninstall", "--yes", "--target", "all" });
    try testing.expect(uninstall.uninstall.yes);
    try testing.expect(uninstall.uninstall.targets.has(.claude));
    try testing.expect(uninstall.uninstall.targets.has(.agents));
}

test "a missing or unknown subcommand is a usage error" {
    try expectParseError(error.MissingSubcommand, &.{});
    try expectParseError(error.UnknownSubcommand, &.{"list"});
}

test "unknown and unsupported options are rejected" {
    try expectParseError(error.UnknownOption, &.{ "install", "--force" });
    try expectParseError(error.UnsupportedOption, &.{ "print", "--project" });
    try expectParseError(error.UnsupportedOption, &.{ "status", "--yes" });
    try expectParseError(error.UnsupportedOption, &.{ "uninstall", "--dry-run" });
    try expectParseError(error.UnexpectedArgument, &.{ "install", "claude" });
}

test "a target needs a known name" {
    try expectParseError(error.MissingValue, &.{ "install", "--target" });
    try expectParseError(error.MissingValue, &.{ "install", "--target=" });
    try expectParseError(error.UnknownTarget, &.{ "install", "--target", "vim" });
    var offending: ?[]const u8 = null;
    try testing.expectError(error.UnknownTarget, parseReporting(&.{ "install", "--target", "vim" }, &offending));
    try testing.expectEqualStrings("vim", offending.?);
}

test "the usage lists every subcommand and target" {
    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writer.writeAll(usage);
    const text = writer.buffered();
    for ([_][]const u8{ "print", "install", "uninstall", "status", "--dry-run", "--yes", "--target", ".claude", ".agents" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "the user and project paths follow the documented locations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const user = try resolve(testing.io, arena, root, "/elsewhere", .{ .targets = .{ .claude = true, .agents = true, .explicit = true } });
    try testing.expectEqual(@as(usize, 2), user.len);
    try testing.expect(std.mem.endsWith(u8, user[0].path, "/.claude/skills/qenome/SKILL.md"));
    try testing.expect(std.mem.endsWith(u8, user[1].path, "/.agents/skills/qenome/SKILL.md"));
    try testing.expectEqual(Scope.user, user[0].scope);

    const project = try resolve(testing.io, arena, null, root, .{ .scope = .project, .targets = .{ .claude = true, .explicit = true } });
    try testing.expectEqual(@as(usize, 1), project.len);
    try testing.expectEqualStrings(".claude", project[0].target.directoryName());
    try testing.expect(std.mem.startsWith(u8, project[0].path, root));
}

test "a missing, empty, or relative home directory is reported" {
    try testing.expectError(error.HomeNotFound, resolve(testing.io, testing.allocator, null, "/tmp", .{}));
    try testing.expectError(error.HomeNotFound, resolve(testing.io, testing.allocator, "", "/tmp", .{}));
    try testing.expectError(error.HomeNotFound, resolve(testing.io, testing.allocator, "relative", "/tmp", .{}));
}

test "detection picks the agent directories that exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const fallback = try resolve(testing.io, arena, root, root, .{});
    try testing.expectEqual(@as(usize, 1), fallback.len);
    try testing.expectEqual(Target.agents, fallback[0].target);

    try tmp.dir.createDir(testing.io, ".claude", .default_dir);
    const claude = try resolve(testing.io, arena, root, root, .{});
    try testing.expectEqual(@as(usize, 1), claude.len);
    try testing.expectEqual(Target.claude, claude[0].target);

    try tmp.dir.createDir(testing.io, ".cursor", .default_dir);
    const both = try resolve(testing.io, arena, root, root, .{});
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqual(Target.claude, both[0].target);
    try testing.expectEqual(Target.agents, both[1].target);
}

test "write, inspect, and remove follow the installed file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const locations = try resolve(testing.io, arena, root, root, .{ .targets = .{ .claude = true, .explicit = true } });
    const location = locations[0];

    try testing.expectEqual(State.missing, try inspect(testing.io, arena, location));
    try testing.expectEqual(RemoveOutcome.missing, try remove(testing.io, arena, location));

    try write(testing.io, location);
    try testing.expectEqual(State.up_to_date, try inspect(testing.io, arena, location));
    const installed = (try read(testing.io, arena, location)).?;
    try testing.expectEqualStrings(content, installed);

    try testing.expectEqual(RemoveOutcome.removed, try remove(testing.io, arena, location));
    try testing.expectEqual(State.missing, try inspect(testing.io, arena, location));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".claude/skills/qenome", .{}));
}

test "a modified file is kept by remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const locations = try resolve(testing.io, arena, root, root, .{ .targets = .{ .claude = true, .explicit = true } });
    const location = locations[0];

    try write(testing.io, location);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = location.path, .data = "my own notes\n" });
    try testing.expectEqual(State.differs, try inspect(testing.io, arena, location));
    try testing.expectEqual(RemoveOutcome.differs, try remove(testing.io, arena, location));
    const kept = (try read(testing.io, arena, location)).?;
    try testing.expectEqualStrings("my own notes\n", kept);
}

test "remove keeps a directory that holds another file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const locations = try resolve(testing.io, arena, root, root, .{ .targets = .{ .claude = true, .explicit = true } });
    const location = locations[0];

    try write(testing.io, location);
    const notes = try std.fs.path.join(arena, &.{ location.directory, "notes.txt" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = notes, .data = "keep\n" });
    try testing.expectEqual(RemoveOutcome.directory_kept, try remove(testing.io, arena, location));
    try testing.expectEqual(State.missing, try inspect(testing.io, arena, location));
    try tmp.dir.access(testing.io, ".claude/skills/qenome/notes.txt", .{});
}

test "a root reached through a symbolic link is resolved before use" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.createDirPath(testing.io, "home/.claude/skills/qenome");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/skills/qenome/SKILL.md", .data = content });
    const home = try std.fs.path.join(arena, &.{ root, "home" });
    try tmp.dir.symLink(testing.io, home, "linked-home", .{ .is_directory = true });
    const linked_root = try std.fs.path.join(arena, &.{ root, "linked-home" });

    const locations = try resolve(testing.io, arena, linked_root, linked_root, .{ .targets = .{ .claude = true, .explicit = true } });
    try testing.expect(std.mem.startsWith(u8, locations[0].path, home));
    try testing.expectEqual(State.up_to_date, try inspect(testing.io, arena, locations[0]));
    try testing.expectEqual(RemoveOutcome.removed, try remove(testing.io, arena, locations[0]));
    try testing.expectEqual(State.missing, try inspect(testing.io, arena, locations[0]));
}

test "remove keeps a directory reached through a symbolic link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.createDirPath(testing.io, "shared");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared/SKILL.md", .data = content });
    try tmp.dir.createDirPath(testing.io, ".claude/skills");
    const shared = try std.fs.path.join(arena, &.{ root, "shared" });
    try tmp.dir.symLink(testing.io, shared, ".claude/skills/qenome", .{ .is_directory = true });

    const locations = try resolve(testing.io, arena, root, root, .{ .targets = .{ .claude = true, .explicit = true } });
    try testing.expectEqual(State.up_to_date, try inspect(testing.io, arena, locations[0]));
    try testing.expectEqual(RemoveOutcome.linked, try remove(testing.io, arena, locations[0]));
    try testing.expectEqualStrings(content, (try read(testing.io, arena, locations[0])).?);
}

test "remove keeps a file reached through a symbolic link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.createDirPath(testing.io, "shared");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared/SKILL.md", .data = content });
    try tmp.dir.createDirPath(testing.io, ".claude/skills/qenome");
    const shared = try std.fs.path.join(arena, &.{ root, "shared/SKILL.md" });
    try tmp.dir.symLink(testing.io, shared, ".claude/skills/qenome/SKILL.md", .{});

    const locations = try resolve(testing.io, arena, root, root, .{ .targets = .{ .claude = true, .explicit = true } });
    try testing.expectEqual(State.up_to_date, try inspect(testing.io, arena, locations[0]));
    try testing.expectEqual(RemoveOutcome.linked, try remove(testing.io, arena, locations[0]));
    try testing.expectEqualStrings(content, (try read(testing.io, arena, locations[0])).?);
}

test "the embedded skill is the repository file" {
    try testing.expect(std.mem.startsWith(u8, content, "---\nname: qenome\n"));
    try testing.expect(std.mem.indexOf(u8, content, "description:") != null);
}

test {
    _ = @import("diff.zig");
}
