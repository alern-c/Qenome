//! Command line parsing and the input file contract.
//!
//! Nothing here touches a database; `readSqlFile` reads one SQL file.

const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");

/// The typed value of one `--bind` input, as the SQLite layer takes it.
pub const BindArg = db.BindArg;

/// Upper bound for a SQL input file (1 MiB). A file of exactly this size is
/// still accepted.
pub const max_sql_bytes = 1024 * 1024;

pub const SqlFileError = error{
    /// The file is larger than `max_sql_bytes`.
    SqlFileTooLarge,
    /// The file contains a NUL byte. SQLite takes NUL-terminated strings, so a
    /// NUL cannot be part of a statement.
    SqlFileContainsNul,
};

/// Reads a SQL file and returns it NUL-terminated for the SQLite C API.
///
/// `path` may be absolute or relative to the current directory. The size bound
/// is enforced while reading; the reader reports `error.StreamTooLong` when the
/// limit is reached, so one extra byte is allowed before rejecting.
pub fn readSqlFile(io: Io, allocator: std.mem.Allocator, path: []const u8) (SqlFileError || Io.Dir.ReadFileAllocError)![:0]u8 {
    const data = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_sql_bytes + 1),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.SqlFileTooLarge,
        else => |e| return e,
    };
    errdefer allocator.free(data);
    if (std.mem.indexOfScalar(u8, data, 0) != null) return error.SqlFileContainsNul;
    return data;
}

/// Default value of `--timeout-ms`.
pub const default_timeout_ms: u64 = 30_000;

/// Timed rounds per run unless `--runs` says otherwise. One round times the
/// SELECT once on each copy.
pub const default_runs: u32 = 10;

/// Most rounds `--runs` accepts, so that the samples and the wait stay
/// bounded.
pub const max_runs: u32 = 1000;

/// How the summary is written on stdout.
pub const Format = enum {
    /// Sections for people, the conclusion first (the default).
    human,
    /// One `key: value` per line, for scripts and logs (D-510).
    kv,
};

/// Parsed command line. `binds` is owned by the allocator passed to
/// `parseArgs`.
pub const Args = struct {
    db: ?[:0]const u8 = null,
    select: ?[:0]const u8 = null,
    index_sql: ?[:0]const u8 = null,
    binds: []const db.BindArg = &.{},
    /// Time limit for the index build and for each SELECT run; `0` disables
    /// it.
    timeout_ms: u64 = default_timeout_ms,
    /// Timed rounds after the result comparison; `0` skips the timing.
    runs: u32 = default_runs,
    /// Print the bind values in the summary instead of their types only.
    show_binds: bool = false,
    format: Format = .human,
    help: bool = false,
};

pub const ParseError = error{
    /// An option that needs a value is the last argument.
    MissingValue,
    /// An argument starts with `-` and is not an option of this CLI.
    UnknownOption,
    /// A positional argument was given.
    UnexpectedArgument,
    /// `--bind` does not follow `<N>:<TYPE>[:<VALUE>]`.
    InvalidBindFormat,
    /// `--timeout-ms` is not a non-negative decimal integer.
    InvalidTimeout,
    /// `--runs` is not a decimal integer in `0..max_runs`.
    InvalidRuns,
    /// `--format` is not one of the `Format` names.
    InvalidFormat,
    OutOfMemory,
};

/// Parses `argv`, including the program name at `argv[0]`, without touching
/// any file or database.
///
/// A repeated option keeps its last value. `--help` and `-h` only set a flag;
/// `run` decides what they do.
pub fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) ParseError!Args {
    var offending: ?[:0]const u8 = null;
    return parseArgsReporting(allocator, argv, &offending);
}

/// `parseArgs`, and on an unknown option, an unexpected argument, or an
/// option without its value, also the argument that caused it, so that the
/// diagnostic can name it.
pub fn parseArgsReporting(allocator: std.mem.Allocator, argv: []const [:0]const u8, offending: *?[:0]const u8) ParseError!Args {
    var args: Args = .{};
    var binds: std.ArrayList(db.BindArg) = .empty;
    errdefer binds.deinit(allocator);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        offending.* = arg;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--db")) {
            args.db = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--select")) {
            args.select = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--index-sql")) {
            args.index_sql = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--bind")) {
            const raw = try nextValue(argv, &index);
            try binds.append(allocator, try parseBind(raw));
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const raw = try nextValue(argv, &index);
            args.timeout_ms = std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidTimeout;
        } else if (std.mem.eql(u8, arg, "--show-binds")) {
            args.show_binds = true;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            const raw = try nextValue(argv, &index);
            args.runs = std.fmt.parseUnsigned(u32, raw, 10) catch return error.InvalidRuns;
            if (args.runs > max_runs) return error.InvalidRuns;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const raw = try nextValue(argv, &index);
            args.format = std.meta.stringToEnum(Format, raw) orelse return error.InvalidFormat;
        } else if (arg.len != 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            return error.UnexpectedArgument;
        }
    }
    offending.* = null;
    args.binds = try binds.toOwnedSlice(allocator);
    return args;
}

fn nextValue(argv: []const [:0]const u8, index: *usize) ParseError![:0]const u8 {
    index.* += 1;
    if (index.* == argv.len) return error.MissingValue;
    return argv[index.*];
}

/// Parses one `--bind` value: `<N>:<TYPE>[:<VALUE>]`.
///
/// Only the first two colons separate the fields, so a text value may hold
/// colons itself. `null` takes no value; `int`, `real` and `text` need one
/// (an empty text value is allowed and means the empty string).
fn parseBind(raw: [:0]const u8) ParseError!db.BindArg {
    const separator = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidBindFormat;
    const number_text = raw[0..separator];
    if (number_text.len == 0) return error.InvalidBindFormat;
    const number = std.fmt.parseUnsigned(u64, number_text, 10) catch return error.InvalidBindFormat;

    const rest = raw[separator + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':');
    const type_text = if (second) |at| rest[0..at] else rest;
    const value_text: ?[]const u8 = if (second) |at| rest[at + 1 ..] else null;

    const value: db.BindValue = blk: {
        if (std.mem.eql(u8, type_text, "int")) {
            const text = value_text orelse return error.InvalidBindFormat;
            break :blk .{ .int = std.fmt.parseInt(i64, text, 10) catch return error.InvalidBindFormat };
        }
        if (std.mem.eql(u8, type_text, "real")) {
            const text = value_text orelse return error.InvalidBindFormat;
            const parsed = std.fmt.parseFloat(f64, text) catch return error.InvalidBindFormat;
            // SQLite stores NaN as NULL, which would silently lose the
            // declared type, so a NaN is not a usable `real` value.
            if (std.math.isNan(parsed)) return error.InvalidBindFormat;
            break :blk .{ .real = parsed };
        }
        if (std.mem.eql(u8, type_text, "text")) {
            break :blk .{ .text = value_text orelse return error.InvalidBindFormat };
        }
        if (std.mem.eql(u8, type_text, "null")) {
            if (value_text != null) return error.InvalidBindFormat;
            break :blk .null;
        }
        return error.InvalidBindFormat;
    };
    return .{ .number = number, .value = value };
}

/// Writes the CLI contract to `writer`.
pub fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\usage: qenome --db <PATH> --select <FILE> --index-sql <FILE> [options]
        \\
        \\Compares one read-only SELECT before and after one candidate CREATE INDEX
        \\on a local SQLite database, without changing the database.
        \\
        \\The database is opened read-only and copied as one snapshot into a
        \\private directory under $TMPDIR (default /tmp) as a baseline and a
        \\variant; the candidate index is built on the variant only. The SELECT
        \\runs on both copies and their result rows are compared. When they
        \\match, the SELECT is timed again on both copies in alternating rounds.
        \\The directory is removed before exit.
        \\
        \\output (stdout, written once after every run; empty when an input is
        \\rejected, the time limit is reached, or the run is interrupted):
        \\  The default (--format human) starts with a summary: whether the result
        \\  rows match, the time verdict, whether the plan changed, the times, and
        \\  the size increase. Then come the counters and times of both copies
        \\  side by side, the query plans, the row comparison, the timing
        \\  conditions, and the inputs and versions. --format kv prints the same
        \\  facts as one `key: value` per line, for scripts and logs.
        \\  Time verdict: improved (less work, a median more than 20% lower, and
        \\  faster in every round), no-effect (the same plan and counters, and
        \\  medians within 20%), needs-check (anything else, with the reasons), or
        \\  not-judged (the rows differ or cannot be compared, or --runs 0). The
        \\  verdict never changes the exit status. Plan labels (kind, covering,
        \\  automatic) are hints read from SQLite's wording; the detail text is
        \\  what SQLite reported.
        \\
        \\options:
        \\  --db <PATH>          SQLite database file (required)
        \\  --select <FILE>      file holding one read-only SELECT (required)
        \\  --index-sql <FILE>   file holding one candidate CREATE INDEX (required)
        \\  --bind <N>:<TYPE>[:<VALUE>]
        \\                       typed value bound to parameter N, repeatable;
        \\                       TYPE is int, real, text or null (null takes no
        \\                       value); every number in 1..parameter count must
        \\                       be given exactly once
        \\  --timeout-ms <MS>    time limit for the index build and for each SELECT
        \\                       run, 0 disables it (default 30000); a run can
        \\                       wait up to the copy plus (3 + 2 x runs) limits
        \\  --runs <N>           timed rounds after a match, each timing the SELECT
        \\                       once per copy; 0 skips the timing (default 10,
        \\                       at most 1000); a timing that takes longer
        \\                       than a second reports its progress on stderr
        \\  --format <FORMAT>    human (default) or kv
        \\  --show-binds         print the bind values in the summary; by default
        \\                       only their numbers, types and text lengths are
        \\                       printed, so that the values stay out of logs
        \\  --help, -h           print this message and exit with status 0
        \\
        \\exit status: 0 result rows match, 1 rejected, 2 usage error,
        \\3 result rows differ, 4 results cannot be compared, 5 cleanup
        \\failure, 124 time limit reached, 129 / 130 / 143 interrupted by
        \\SIGHUP / SIGINT / SIGTERM
        \\
    );
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingValue => "an option is missing its value (see --help)",
        error.UnknownOption => "unknown option (see --help)",
        error.UnexpectedArgument => "unexpected argument (see --help)",
        error.InvalidBindFormat => "--bind expects <N>:<TYPE>[:<VALUE>] with TYPE int, real, text or null",
        error.InvalidTimeout => "--timeout-ms expects a non-negative integer",
        error.InvalidRuns => std.fmt.comptimePrint("--runs expects an integer from 0 to {d}", .{max_runs}),
        error.InvalidFormat => "--format expects human or kv",
        error.OutOfMemory => "out of memory",
    };
}

pub fn fileErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SqlFileTooLarge => "the file is larger than 1 MiB",
        error.SqlFileContainsNul => "the file contains a NUL byte",
        else => @errorName(err),
    };
}

const testing = std.testing;

test "sql file is read with a trailing sentinel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "select.sql", .data = "SELECT 1;\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "select.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const sql = try readSqlFile(std.testing.io, std.testing.allocator, path);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT 1;\n", sql);
    try std.testing.expectEqual(@as(u8, 0), sql[sql.len]);
}

test "sql file containing a NUL byte is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nul.sql", .data = "SELECT 1\x00SELECT 2" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "nul.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.SqlFileContainsNul,
        readSqlFile(std.testing.io, std.testing.allocator, path),
    );
}

test "sql file at the size limit is accepted and a larger one is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const at_limit = try allocator.alloc(u8, max_sql_bytes);
    defer allocator.free(at_limit);
    @memset(at_limit, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at_limit.sql", .data = at_limit });
    const at_limit_path = try tmp.dir.realPathFileAlloc(std.testing.io, "at_limit.sql", allocator);
    defer allocator.free(at_limit_path);
    const sql = try readSqlFile(std.testing.io, allocator, at_limit_path);
    defer allocator.free(sql);
    try std.testing.expectEqual(@as(usize, max_sql_bytes), sql.len);

    const too_large = try allocator.alloc(u8, max_sql_bytes + 1);
    defer allocator.free(too_large);
    @memset(too_large, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "too_large.sql", .data = too_large });
    const too_large_path = try tmp.dir.realPathFileAlloc(std.testing.io, "too_large.sql", allocator);
    defer allocator.free(too_large_path);
    try std.testing.expectError(
        error.SqlFileTooLarge,
        readSqlFile(std.testing.io, allocator, too_large_path),
    );
}

test "missing sql file reports the read error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing.sql", .data = "SELECT 1" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "missing.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try tmp.dir.deleteFile(std.testing.io, "missing.sql");

    try std.testing.expectError(
        error.FileNotFound,
        readSqlFile(std.testing.io, std.testing.allocator, path),
    );
}

test "bind parsing keeps colons and types" {
    const args = try parseArgs(testing.allocator, &.{
        "Qenome",
        "--bind",
        "1:text:a:b:c",
        "--bind",
        "2:null",
        "--bind",
        "3:real:1.5",
        "--timeout-ms",
        "0",
    });
    defer testing.allocator.free(args.binds);

    try testing.expectEqual(@as(usize, 3), args.binds.len);
    try testing.expectEqualStrings("a:b:c", args.binds[0].value.text);
    try testing.expect(args.binds[1].value == .null);
    try testing.expectEqual(@as(f64, 1.5), args.binds[2].value.real);
    try testing.expectEqual(@as(u64, 0), args.timeout_ms);
}

test "timeout defaults to 30000" {
    const args = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(args.binds);
    try testing.expectEqual(default_timeout_ms, args.timeout_ms);
}

test "format defaults to human and takes human or kv" {
    const default = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(default.binds);
    try testing.expectEqual(Format.human, default.format);
    const kv = try parseArgs(testing.allocator, &.{ "Qenome", "--format", "kv" });
    defer testing.allocator.free(kv.binds);
    try testing.expectEqual(Format.kv, kv.format);
    const human = try parseArgs(testing.allocator, &.{ "Qenome", "--format", "kv", "--format", "human" });
    defer testing.allocator.free(human.binds);
    try testing.expectEqual(Format.human, human.format);
    for ([_][:0]const u8{ "json", "", "KV" }) |raw| {
        try testing.expectError(error.InvalidFormat, parseArgs(testing.allocator, &.{ "Qenome", "--format", raw }));
    }
}

test "a parse error names the argument it is about" {
    const cases = [_]struct { argv: []const [:0]const u8, err: ParseError, offending: []const u8 }{
        .{ .argv = &.{ "Qenome", "--db", "d", "--nope" }, .err = error.UnknownOption, .offending = "--nope" },
        .{ .argv = &.{ "Qenome", "stray" }, .err = error.UnexpectedArgument, .offending = "stray" },
        .{ .argv = &.{ "Qenome", "--select" }, .err = error.MissingValue, .offending = "--select" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(case.err, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
    }
}
