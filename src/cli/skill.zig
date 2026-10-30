const std = @import("std");
const Io = std.Io;
const cli_args = @import("args.zig");
const cli_control = @import("control.zig");
const cli_workspace = @import("workspace.zig");
const skill = @import("../skill/skill.zig");

const ExitCode = cli_control.ExitCode;

pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    home: ?[]const u8,
    stdin: ?*Io.Reader,
    directory: Io.Dir,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    var offending: ?[]const u8 = null;
    const command = skill.parseReporting(argv, &offending) catch |err| {
        reportParseError(stderr, err, offending, argv);
        return .usage;
    };
    return switch (command) {
        .help => blk: {
            stdout.writeAll(skill.usage) catch {};
            break :blk ExitCode.ok;
        },
        .print => blk: {
            stdout.writeAll(skill.content) catch {};
            break :blk ExitCode.ok;
        },
        .install => |options| install(io, allocator, options, home, stdin, directory, stdout, stderr),
        .uninstall => |options| uninstall(io, allocator, options, home, stdin, directory, stdout, stderr),
        .status => |options| status(io, allocator, options, home, directory, stdout, stderr),
    };
}

fn reportParseError(stderr: *Io.Writer, err: skill.ParseError, offending: ?[]const u8, argv: []const [:0]const u8) void {
    const argument = offending orelse "";
    switch (err) {
        error.MissingSubcommand => stderr.writeAll("error: qenome skill needs a subcommand: print, install, uninstall or status (see qenome skill --help)\n") catch {},
        error.UnknownSubcommand => stderr.print("error: unknown skill subcommand '{s}'; use print, install, uninstall or status (see qenome skill --help)\n", .{argument}) catch {},
        error.UnknownOption => stderr.print("error: unknown option '{s}' for qenome skill (see qenome skill --help)\n", .{argument}) catch {},
        error.UnsupportedOption => {
            const subcommand = if (argv.len > 0) argv[0] else "qenome skill";
            stderr.print("error: {s} does not take {s} (see qenome skill --help)\n", .{ subcommand, argument }) catch {};
        },
        error.UnexpectedArgument => stderr.print("error: unexpected argument '{s}' (see qenome skill --help)\n", .{argument}) catch {},
        error.MissingValue => stderr.writeAll("error: --target needs a value: claude, agents or all (see qenome skill --help)\n") catch {},
        error.UnknownTarget => stderr.print("error: unknown --target '{s}'; use claude, agents or all\n", .{argument}) catch {},
    }
}

fn resolveLocations(
    io: Io,
    allocator: std.mem.Allocator,
    options: skill.Options,
    home: ?[]const u8,
    directory: Io.Dir,
    stderr: *Io.Writer,
) ?[]skill.Location {
    const project_root = directory.realPathFileAlloc(io, ".", allocator) catch |err| {
        stderr.print("error: cannot read the current directory: {s}\n", .{cli_args.fileErrorMessage(err)}) catch {};
        return null;
    };
    return skill.resolve(io, allocator, home, project_root, options) catch |err| switch (err) {
        error.HomeNotFound => blk: {
            stderr.writeAll("error: cannot find the home directory (HOME is not set, empty, or not an absolute path); pass --project to use the current directory\n") catch {};
            break :blk null;
        },
        error.OutOfMemory => blk: {
            stderr.writeAll("error: out of memory\n") catch {};
            break :blk null;
        },
    };
}

fn printAction(stdout: *Io.Writer, location: skill.Location, action: []const u8) void {
    stdout.print("{s}  {s}  {s}\n", .{ location.target.name(), location.path, action }) catch {};
}

fn reportFileError(stderr: *Io.Writer, verb: []const u8, path: []const u8, err: anyerror) void {
    stderr.print("error: cannot {s} '{s}': {s}\n", .{ verb, path, cli_args.fileErrorMessage(err) }) catch {};
}

fn readYes(stdin: ?*Io.Reader) bool {
    const reader = stdin orelse return false;
    const answer = (reader.takeDelimiter('\n') catch return false) orelse return false;
    const trimmed = std.mem.trim(u8, answer, " \t\r");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

fn confirmOverwrite(stdin: ?*Io.Reader, stdout: *Io.Writer, path: []const u8) bool {
    stdout.print("overwrite {s}? [y/N] ", .{path}) catch return false;
    stdout.flush() catch {};
    return readYes(stdin);
}

fn confirmRemove(stdin: ?*Io.Reader, stdout: *Io.Writer, path: []const u8) bool {
    stdout.print("remove {s}? [y/N] ", .{path}) catch return false;
    stdout.flush() catch {};
    return readYes(stdin);
}

fn writeLocation(io: Io, location: skill.Location, action: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) bool {
    skill.write(io, location) catch |err| {
        reportFileError(stderr, "write", location.path, err);
        return false;
    };
    printAction(stdout, location, action);
    return true;
}

fn install(
    io: Io,
    allocator: std.mem.Allocator,
    options: skill.Options,
    home: ?[]const u8,
    stdin: ?*Io.Reader,
    directory: Io.Dir,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    const locations = resolveLocations(io, allocator, options, home, directory, stderr) orelse return .rejected;
    var code: ExitCode = .ok;
    for (locations) |location| {
        const state = skill.inspect(io, allocator, location) catch |err| {
            reportFileError(stderr, "read", location.path, err);
            code = .rejected;
            continue;
        };
        switch (state) {
            .up_to_date => printAction(stdout, location, "up to date"),
            .missing => {
                if (options.dry_run) {
                    printAction(stdout, location, "would install");
                    continue;
                }
                if (!writeLocation(io, location, "installed", stdout, stderr)) code = .rejected;
            },
            .differs => {
                if (!options.yes) {
                    const installed = (skill.read(io, allocator, location) catch null) orelse "";
                    const rendered = skill.renderDiff(allocator, location.path, installed, skill.content) catch "";
                    stdout.writeAll(rendered) catch {};
                }
                if (options.dry_run) {
                    printAction(stdout, location, "would overwrite");
                    continue;
                }
                if (!options.yes and !confirmOverwrite(stdin, stdout, location.path)) {
                    printAction(stdout, location, "skipped (kept the modified file; pass --yes to overwrite)");
                    code = .rejected;
                    continue;
                }
                if (!writeLocation(io, location, "overwrote", stdout, stderr)) code = .rejected;
            },
        }
    }
    return code;
}

fn uninstall(
    io: Io,
    allocator: std.mem.Allocator,
    options: skill.Options,
    home: ?[]const u8,
    stdin: ?*Io.Reader,
    directory: Io.Dir,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    const locations = resolveLocations(io, allocator, options, home, directory, stderr) orelse return .rejected;
    var code: ExitCode = .ok;
    for (locations) |location| {
        const state = skill.inspect(io, allocator, location) catch |err| {
            reportFileError(stderr, "read", location.path, err);
            code = .rejected;
            continue;
        };
        switch (state) {
            .missing => printAction(stdout, location, "not installed"),
            .differs => {
                printAction(stdout, location, "kept (the file differs from this binary's copy; remove it yourself if you no longer want it)");
                code = .rejected;
            },
            .up_to_date => {
                if (!options.yes and !confirmRemove(stdin, stdout, location.path)) {
                    printAction(stdout, location, "skipped (pass --yes to remove without asking)");
                    code = .rejected;
                    continue;
                }
                const outcome = skill.remove(io, allocator, location) catch |err| {
                    reportFileError(stderr, "remove", location.path, err);
                    code = .rejected;
                    continue;
                };
                switch (outcome) {
                    .removed => printAction(stdout, location, "removed"),
                    .directory_kept => printAction(stdout, location, "removed (the directory holds other files, so it stays)"),
                    .missing => printAction(stdout, location, "not installed"),
                    .differs => {
                        printAction(stdout, location, "kept (the file differs from this binary's copy)");
                        code = .rejected;
                    },
                    .linked => {
                        printAction(stdout, location, "kept (a symbolic link or a file qenome did not install; remove it yourself if you no longer want it)");
                        code = .rejected;
                    },
                }
            },
        }
    }
    return code;
}

fn status(
    io: Io,
    allocator: std.mem.Allocator,
    options: skill.Options,
    home: ?[]const u8,
    directory: Io.Dir,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    const locations = resolveLocations(io, allocator, options, home, directory, stderr) orelse return .rejected;
    var code: ExitCode = .ok;
    for (locations) |location| {
        const state = skill.inspect(io, allocator, location) catch |err| {
            reportFileError(stderr, "read", location.path, err);
            code = .rejected;
            continue;
        };
        printAction(stdout, location, switch (state) {
            .missing => "not installed",
            .up_to_date => "up to date",
            .differs => "differs from this binary's copy",
        });
    }
    return code;
}

test {
    _ = @import("skill_tests.zig");
}
