const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");

pub const BindArg = db.BindArg;

pub const max_sql_bytes = 1024 * 1024;

pub const SqlFileError = error{
    SqlFileTooLarge,
    SqlFileContainsNul,
};

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

pub const default_timeout_ms: u64 = 30_000;

pub const default_runs: u32 = 10;

pub const max_runs: u32 = 1000;

pub const Format = enum {
    human,
    kv,
};

pub const Args = struct {
    db: ?[:0]const u8 = null,
    select: ?[:0]const u8 = null,
    index_sql: ?[:0]const u8 = null,
    binds: []const db.BindArg = &.{},
    timeout_ms: u64 = default_timeout_ms,
    runs: u32 = default_runs,
    show_binds: bool = false,
    format: Format = .human,
    help: bool = false,
};

pub const ParseError = error{
    MissingValue,
    DuplicateOption,
    UnexpectedValue,
    UnknownOption,
    UnexpectedArgument,
    InvalidBindFormat,
    InvalidTimeout,
    InvalidRuns,
    InvalidFormat,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) ParseError!Args {
    var offending: ?[:0]const u8 = null;
    return parseArgsReporting(allocator, argv, &offending);
}

pub fn parseArgsReporting(allocator: std.mem.Allocator, argv: []const [:0]const u8, offending: *?[:0]const u8) ParseError!Args {
    var args: Args = .{};
    const rest = if (argv.len > 1) argv[1..] else argv[0..0];
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
            offending.* = null;
            return args;
        }
    }

    var binds: std.ArrayList(db.BindArg) = .empty;
    errdefer binds.deinit(allocator);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        offending.* = arg;
        const inline_value = splitInline(arg);
        const name = if (inline_value) |inl| inl.name else arg;

        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.help = true;
        } else if (std.mem.eql(u8, name, "--db")) {
            if (args.db != null) return error.DuplicateOption;
            args.db = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--select")) {
            if (args.select != null) return error.DuplicateOption;
            args.select = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--index-sql")) {
            if (args.index_sql != null) return error.DuplicateOption;
            args.index_sql = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--bind")) {
            const raw = try optionValue(argv, &index, inline_value);
            try binds.append(allocator, try parseBind(raw));
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            const raw = try optionValue(argv, &index, inline_value);
            args.timeout_ms = std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidTimeout;
        } else if (std.mem.eql(u8, name, "--show-binds")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.show_binds = true;
        } else if (std.mem.eql(u8, name, "--runs")) {
            const raw = try optionValue(argv, &index, inline_value);
            args.runs = std.fmt.parseUnsigned(u32, raw, 10) catch return error.InvalidRuns;
            if (args.runs > max_runs) return error.InvalidRuns;
        } else if (std.mem.eql(u8, name, "--format")) {
            const raw = try optionValue(argv, &index, inline_value);
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

const Inline = struct {
    name: []const u8,
    value: [:0]const u8,
};

fn splitInline(arg: [:0]const u8) ?Inline {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const at = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .name = arg[0..at], .value = arg[at + 1 ..] };
}

fn optionValue(argv: []const [:0]const u8, index: *usize, inline_value: ?Inline) ParseError![:0]const u8 {
    if (inline_value) |inl| {
        if (inl.value.len == 0) return error.MissingValue;
        return inl.value;
    }
    const value = try nextValue(argv, index);
    if (value.len == 0 or isOptionName(value)) return error.MissingValue;
    return value;
}

fn isOptionName(token: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
    return isKnownLongOption(token[0..end]) or std.mem.eql(u8, token[0..end], "-h");
}

pub const required_option_count = 3;

pub fn missingRequired(args: Args, buffer: *[required_option_count][]const u8) []const []const u8 {
    var count: usize = 0;
    if (args.db == null) {
        buffer[count] = "--db";
        count += 1;
    }
    if (args.select == null) {
        buffer[count] = "--select";
        count += 1;
    }
    if (args.index_sql == null) {
        buffer[count] = "--index-sql";
        count += 1;
    }
    return buffer[0..count];
}

const long_options = [_][]const u8{
    "--help",
    "--db",
    "--select",
    "--index-sql",
    "--bind",
    "--timeout-ms",
    "--show-binds",
    "--runs",
    "--format",
};

const max_option_name = 32;

fn isKnownLongOption(name: []const u8) bool {
    for (long_options) |option| {
        if (std.mem.eql(u8, option, name)) return true;
    }
    return false;
}

pub fn suggestOptionName(arg: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
    const token = arg[0..end];
    if (std.mem.startsWith(u8, token, "--")) return suggestLongOption(token[2..]);
    if (token.len > 2 and token[0] == '-') {
        for (long_options) |candidate| {
            if (std.mem.eql(u8, candidate[2..], token[1..])) return candidate;
        }
    }
    return null;
}

fn suggestLongOption(name: []const u8) ?[]const u8 {
    if (name.len < 2) return null;
    var best: ?[]const u8 = null;
    var best_distance: usize = max_option_name + 1;
    var best_prefix: usize = 0;
    for (long_options) |candidate| {
        const other = candidate[2..];
        const prefix = commonPrefixLen(name, other);
        if (name.len >= 3 and prefix == name.len) return candidate;
        const distance = editDistance(name, other);
        if (distance > suggestionLimit(other.len)) continue;
        if (best == null or distance < best_distance or
            (distance == best_distance and prefix > best_prefix))
        {
            best = candidate;
            best_distance = distance;
            best_prefix = prefix;
        }
    }
    return best;
}

fn suggestionLimit(name_len: usize) usize {
    if (name_len <= 2) return 1;
    if (name_len <= 8) return 2;
    return 3;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var count: usize = 0;
    while (count < limit and a[count] == b[count]) : (count += 1) {}
    return count;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > max_option_name or b.len > max_option_name) return max_option_name + 1;
    var previous: [max_option_name + 1]usize = undefined;
    var current: [max_option_name + 1]usize = undefined;
    for (0..b.len + 1) |position| previous[position] = position;
    for (a, 0..) |a_byte, i| {
        current[0] = i + 1;
        for (b, 0..) |b_byte, j| {
            const substitute = previous[j] + @as(usize, @intFromBool(a_byte != b_byte));
            current[j + 1] = @min(@min(previous[j + 1] + 1, current[j] + 1), substitute);
        }
        const swap = previous;
        previous = current;
        current = swap;
    }
    return previous[b.len];
}

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

pub const usage_line = "usage: qenome --db <PATH> --select <FILE> --index-sql <FILE> [options]";

pub fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(usage_line ++ "\n\n" ++
        \\Compares one read-only SELECT before and after one candidate CREATE INDEX
        \\on a local SQLite database, without changing the database.
        \\
        \\options (a value may also be written as --option=value):
        \\  --db <PATH>          SQLite database file (required, once)
        \\  --select <FILE>      file holding one read-only SELECT (required, once)
        \\  --index-sql <FILE>   file holding one candidate CREATE INDEX (required, once)
        \\  --bind <N>:<TYPE>[:<VALUE>]
        \\                       typed value bound to parameter N, repeatable;
        \\                       N is SQLite's parameter number; named parameters
        \\                       share the number of their first appearance and
        \\                       ?NNN uses NNN; TYPE is int, real, text or null
        \\                       (null takes no value); every number in 1..parameter
        \\                       count must be given exactly once
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
        \\examples:
        \\  qenome --db app.db --select select.sql --index-sql index.sql
        \\  qenome --db app.db --select select.sql --index-sql index.sql --bind 1:int:1234
        \\  qenome --db app.db --select select.sql --index-sql index.sql --format kv
        \\
        \\exit status: 0 result rows match, 1 rejected, 2 usage error,
        \\3 result rows differ, 4 results cannot be compared, 5 cleanup
        \\failure, 124 time limit reached, 129 / 130 / 143 interrupted by
        \\SIGHUP / SIGINT / SIGTERM
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
    );
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingValue => "an option is missing its value (see --help)",
        error.DuplicateOption => "an option was given more than once (see --help)",
        error.UnexpectedValue => "an option that takes no value was given one (see --help)",
        error.UnknownOption => "unknown option (see --help)",
        error.UnexpectedArgument => "unexpected argument (see --help)",
        error.InvalidBindFormat => "--bind expects <N>:<TYPE>[:<VALUE>], where N is the parameter number and TYPE is int, real, text or null; e.g. --bind 1:int:1234, --bind 2:text:ok, --bind 3:null",
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
        error.FileNotFound => "no such file",
        error.IsDir => "is a directory",
        error.AccessDenied => "permission denied",
        else => @errorName(err),
    };
}

pub fn looksLikeSql(value: []const u8) bool {
    if (std.mem.findAny(u8, value, " \t\r\n") == null) return false;
    const trimmed = std.mem.trimStart(u8, value, " \t\r\n");
    const keywords = [_][]const u8{ "SELECT", "WITH", "CREATE", "INSERT", "UPDATE", "DELETE", "PRAGMA", "EXPLAIN" };
    for (keywords) |keyword| {
        if (trimmed.len < keyword.len) continue;
        if (!std.ascii.eqlIgnoreCase(trimmed[0..keyword.len], keyword)) continue;
        if (trimmed.len == keyword.len) return true;
        const next = trimmed[keyword.len];
        if (next == ' ' or next == '\t' or next == '\r' or next == '\n' or next == '(') return true;
    }
    return false;
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
    for ([_][:0]const u8{ "json", "KV" }) |raw| {
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

test "a value option takes its value after an equals sign" {
    const args = try parseArgs(testing.allocator, &.{
        "Qenome",
        "--db=db.sqlite",
        "--select=select.sql",
        "--index-sql=index.sql",
        "--bind=1:text:a=b",
        "--timeout-ms=0",
        "--runs=3",
        "--format=kv",
    });
    defer testing.allocator.free(args.binds);

    try testing.expectEqualStrings("db.sqlite", args.db.?);
    try testing.expectEqualStrings("select.sql", args.select.?);
    try testing.expectEqualStrings("index.sql", args.index_sql.?);
    try testing.expectEqual(@as(usize, 1), args.binds.len);
    try testing.expectEqualStrings("a=b", args.binds[0].value.text);
    try testing.expectEqual(@as(u64, 0), args.timeout_ms);
    try testing.expectEqual(@as(u32, 3), args.runs);
    try testing.expectEqual(Format.kv, args.format);
}

test "a flag rejects an inline value" {
    for ([_][:0]const u8{ "--help=1", "--show-binds=true" }) |arg| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(
            error.UnexpectedValue,
            parseArgsReporting(testing.allocator, &.{ "Qenome", arg }, &offending),
        );
        try testing.expectEqualStrings(arg, offending.?);
    }
}

test "missing required options keep the usage order" {
    var buffer: [required_option_count][]const u8 = undefined;

    const none = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(none.binds);
    const all = missingRequired(none, &buffer);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("--db", all[0]);
    try testing.expectEqualStrings("--select", all[1]);
    try testing.expectEqualStrings("--index-sql", all[2]);

    const partial = try parseArgs(testing.allocator, &.{ "Qenome", "--select", "s" });
    defer testing.allocator.free(partial.binds);
    const rest = missingRequired(partial, &buffer);
    try testing.expectEqual(@as(usize, 2), rest.len);
    try testing.expectEqualStrings("--db", rest[0]);
    try testing.expectEqualStrings("--index-sql", rest[1]);
}

test "a misspelt option suggests the closest known name" {
    const cases = [_]struct { given: []const u8, suggested: ?[]const u8 }{
        .{ .given = "--run", .suggested = "--runs" },
        .{ .given = "--run=3", .suggested = "--runs" },
        .{ .given = "--indexsql", .suggested = "--index-sql" },
        .{ .given = "--index", .suggested = "--index-sql" },
        .{ .given = "--timout-ms", .suggested = "--timeout-ms" },
        .{ .given = "--timeout", .suggested = "--timeout-ms" },
        .{ .given = "--selec", .suggested = "--select" },
        .{ .given = "--sel", .suggested = "--select" },
        .{ .given = "--hepl", .suggested = "--help" },
        .{ .given = "-db", .suggested = "--db" },
        .{ .given = "--nope", .suggested = null },
        .{ .given = "-d", .suggested = null },
        .{ .given = "stray", .suggested = null },
    };
    for (cases) |case| {
        const actual = suggestOptionName(case.given);
        if (case.suggested) |expected| {
            try testing.expect(actual != null);
            try testing.expectEqualStrings(expected, actual.?);
        } else {
            try testing.expect(actual == null);
        }
    }
}

test "a value option rejects an empty value" {
    const options = [_][:0]const u8{
        "--db",
        "--select",
        "--index-sql",
        "--bind",
        "--timeout-ms",
        "--runs",
        "--format",
    };
    const empty: [:0]const u8 = "";
    for (options) |option| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(
            error.MissingValue,
            parseArgsReporting(testing.allocator, &.{ "Qenome", option, empty }, &offending),
        );
        try testing.expectEqualStrings(option, offending.?);

        var buffer: [64]u8 = undefined;
        const inline_arg = try std.mem.printSentinel(&buffer, "{s}=", .{option}, 0);
        offending = null;
        try testing.expectError(
            error.MissingValue,
            parseArgsReporting(testing.allocator, &.{ "Qenome", inline_arg }, &offending),
        );
        try testing.expectEqualStrings(inline_arg, offending.?);
    }
}

test "a missing value is not taken from the next option" {
    const cases = [_]struct { argv: []const [:0]const u8, option: []const u8 }{
        .{ .argv = &.{ "Qenome", "--db", "--select", "s.sql" }, .option = "--db" },
        .{ .argv = &.{ "Qenome", "--db", "d.db", "--select", "--index-sql" }, .option = "--select" },
        .{ .argv = &.{ "Qenome", "--db", "--runs=3" }, .option = "--db" },
        .{ .argv = &.{ "Qenome", "--db", "--show-binds" }, .option = "--db" },
        .{ .argv = &.{ "Qenome", "--bind", "--runs", "3" }, .option = "--bind" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(
            error.MissingValue,
            parseArgsReporting(testing.allocator, case.argv, &offending),
        );
        try testing.expectEqualStrings(case.option, offending.?);
    }
}

test "a single-value option may be given only once" {
    const options = [_][:0]const u8{ "--db", "--select", "--index-sql" };
    for (options) |option| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(
            error.DuplicateOption,
            parseArgsReporting(testing.allocator, &.{ "Qenome", option, "a", option, "b" }, &offending),
        );
        try testing.expectEqualStrings(option, offending.?);

        var buffer: [64]u8 = undefined;
        const second = try std.mem.printSentinel(&buffer, "{s}=b", .{option}, 0);
        offending = null;
        try testing.expectError(
            error.DuplicateOption,
            parseArgsReporting(testing.allocator, &.{ "Qenome", option, "a", second }, &offending),
        );
        try testing.expectEqualStrings(second, offending.?);
    }
}

test "help wins over every other argument error" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "-h", "--db" },
        &.{ "Qenome", "--help", "--nope" },
        &.{ "Qenome", "--db=", "--help" },
        &.{ "Qenome", "--db", "a", "--db", "b", "-h" },
    };
    for (cases) |argv| {
        const args = try parseArgs(testing.allocator, argv);
        try testing.expect(args.help);
        testing.allocator.free(args.binds);
    }
}

test "every known long option is accepted by the parser" {
    const cases = [_]struct { option: [:0]const u8, value: ?[:0]const u8 }{
        .{ .option = "--help", .value = null },
        .{ .option = "--db", .value = "d" },
        .{ .option = "--select", .value = "s" },
        .{ .option = "--index-sql", .value = "i" },
        .{ .option = "--bind", .value = "1:null" },
        .{ .option = "--timeout-ms", .value = "1" },
        .{ .option = "--show-binds", .value = null },
        .{ .option = "--runs", .value = "1" },
        .{ .option = "--format", .value = "kv" },
    };
    try testing.expectEqual(long_options.len, cases.len);
    for (cases) |case| {
        const args = if (case.value) |value|
            try parseArgs(testing.allocator, &.{ "Qenome", case.option, value })
        else
            try parseArgs(testing.allocator, &.{ "Qenome", case.option });
        testing.allocator.free(args.binds);
    }
}

test "an inline value keeps an option-like value" {
    const args = try parseArgs(testing.allocator, &.{
        "Qenome",
        "--db=--select",
        "--select=--index-sql",
        "--index-sql=--runs",
    });
    defer testing.allocator.free(args.binds);

    try testing.expect(!args.help);
    try testing.expectEqualStrings("--select", args.db.?);
    try testing.expectEqualStrings("--index-sql", args.select.?);
    try testing.expectEqualStrings("--runs", args.index_sql.?);
}

test "common file errors are shown in plain English" {
    try testing.expectEqualStrings("no such file", fileErrorMessage(error.FileNotFound));
    try testing.expectEqualStrings("is a directory", fileErrorMessage(error.IsDir));
    try testing.expectEqualStrings("permission denied", fileErrorMessage(error.AccessDenied));
    try testing.expectEqualStrings("Unexpected", fileErrorMessage(error.Unexpected));
}

test "sql text passed as a path is recognized" {
    const cases = [_]struct { value: []const u8, expected: bool }{
        .{ .value = "SELECT 1", .expected = true },
        .{ .value = "select\n1", .expected = true },
        .{ .value = "  WITH x AS (SELECT 1)", .expected = true },
        .{ .value = "CREATE INDEX i ON t(a)", .expected = true },
        .{ .value = "INSERT INTO t VALUES (1)", .expected = true },
        .{ .value = "SELECT", .expected = false },
        .{ .value = "SELECTED 1", .expected = false },
        .{ .value = "missing.sql", .expected = false },
        .{ .value = "data sets/backup", .expected = false },
        .{ .value = "-select.sql", .expected = false },
    };
    for (cases) |case| try testing.expectEqual(case.expected, looksLikeSql(case.value));
}

test "a bind format error shows parameter numbers and examples" {
    const message = parseErrorMessage(error.InvalidBindFormat);
    try testing.expect(std.mem.indexOf(u8, message, "parameter number") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 1:int:1234") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 2:text:ok") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 3:null") != null);
}

test "the usage option list and the known option names agree" {
    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  --")) continue;
        const rest = line[2..];
        const end = std.mem.findAny(u8, rest, " ,") orelse rest.len;
        try testing.expect(isKnownLongOption(rest[0..end]));
        count += 1;
    }
    try testing.expectEqual(long_options.len, count);
}
