const std = @import("std");
const sql_lexer = @import("../sql/lexer.zig");
const Io = std.Io;
const db = @import("../db.zig");
const build_options = @import("build_options");
const usage_text = @import("usage_text.zig");

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

pub const default_n_plus_one_threshold: u32 = 10;

pub const max_n_plus_one_threshold: u32 = 1_000_000;

pub const Format = enum {
    human,
    kv,
    json,
};

pub const max_scale_steps = 3;

pub const Scale = struct {
    values: [max_scale_steps]u64 = undefined,
    len: u8 = 0,

    pub fn steps(self: *const Scale) []const u64 {
        return self.values[0..self.len];
    }
};

pub const Args = struct {
    db: ?[:0]const u8 = null,
    d1: ?[:0]const u8 = null,
    config: ?[:0]const u8 = null,
    batch: ?[:0]const u8 = null,
    record: ?[:0]const u8 = null,
    out: ?[:0]const u8 = null,
    migration: ?[:0]const u8 = null,
    seed_data: ?[:0]const u8 = null,
    scale: ?Scale = null,
    select: ?[:0]const u8 = null,
    sql: ?[:0]const u8 = null,
    write: ?[:0]const u8 = null,
    index_sql: ?[:0]const u8 = null,
    binds: []const db.BindArg = &.{},
    timeout_ms: u64 = default_timeout_ms,
    runs: u32 = default_runs,
    runs_given: bool = false,
    show_binds: bool = false,
    show_rows: bool = false,
    format: Format = .human,
    n_plus_one_threshold: u32 = default_n_plus_one_threshold,
    n_plus_one_threshold_given: bool = false,
    suggest: bool = false,
    audit_indexes: bool = false,
    help: bool = false,
    version: bool = false,
};

pub const ParseError = error{
    MissingValue,
    DuplicateOption,
    UnexpectedValue,
    UnknownOption,
    TooManyPaths,
    TooManyD1Paths,
    EmptyPath,
    InvalidBindFormat,
    InvalidTimeout,
    InvalidRuns,
    InvalidFormat,
    InvalidNPlusOneThreshold,
    InvalidScale,
    ScaleConflict,
    ScaleRequiresSeedData,
    ConflictingDatabase,
    ConfigRequiresD1,
    BatchTakesOnlyDatabasePath,
    BatchRejectsBind,
    BatchRejectsRuns,
    BatchRejectsKv,
    AuditConflict,
    MigrationRequiresBatch,
    MigrationRejectsSuggest,
    MigrationRejectsIndex,
    SuggestRejectsIndex,
    SuggestRejectsRuns,
    SuggestRejectsKv,
    SuggestTakesTwoPaths,
    WriteRejectsSelect,
    WriteRequiresSingle,
    SqlRejectsSelect,
    SqlRejectedMode,
    StdinNotQuery,
    WriteRejectsSuggest,
    WriteRejectsMigration,
    RecordTakesNoPaths,
    RecordConflict,
    ThresholdRequiresRecord,
    OutRequiresRecord,
    RecordRejectsFormat,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) ParseError!Args {
    var offending: ?[:0]const u8 = null;
    return parseArgsReporting(allocator, argv, &offending);
}

pub fn parseArgsReporting(allocator: std.mem.Allocator, argv: []const [:0]const u8, offending: *?[:0]const u8) ParseError!Args {
    var args: Args = .{};
    const rest = if (argv.len > 1) argv[1..] else argv[0..0];
    var version_requested = false;
    var d1_requested = false;
    var batch_requested = false;
    var suggest_requested = false;
    var write_requested = false;
    var record_requested = false;
    var scale_requested = false;
    var scale_conflict: ?[:0]const u8 = null;
    const scale_conflicting_options = [_][:0]const u8{ "--batch", "--suggest", "--migration", "--audit-indexes", "--record" };
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--record") or std.mem.startsWith(u8, arg, "--record=")) record_requested = true;
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
            offending.* = null;
            return args;
        }
        if (std.mem.eql(u8, arg, "--version")) version_requested = true;
        if (std.mem.eql(u8, arg, "--d1") or std.mem.startsWith(u8, arg, "--d1=")) d1_requested = true;
        if (std.mem.eql(u8, arg, "--batch") or std.mem.startsWith(u8, arg, "--batch=")) batch_requested = true;
        if (std.mem.eql(u8, arg, "--suggest")) suggest_requested = true;
        if (std.mem.eql(u8, arg, "--write") or std.mem.startsWith(u8, arg, "--write=")) write_requested = true;
        if (std.mem.eql(u8, arg, "--scale") or std.mem.startsWith(u8, arg, "--scale=")) scale_requested = true;
        if (scale_conflict == null) {
            for (scale_conflicting_options) |name| {
                if (std.mem.eql(u8, arg, name) or (arg.len > name.len and arg[name.len] == '=' and std.mem.eql(u8, arg[0..name.len], name))) {
                    scale_conflict = name;
                    break;
                }
            }
        }
    }
    if (version_requested) {
        args.version = true;
        offending.* = null;
        return args;
    }
    if (scale_requested) {
        if (scale_conflict) |name| {
            offending.* = name;
            return error.ScaleConflict;
        }
    }

    var binds: std.ArrayList(db.BindArg) = .empty;
    errdefer binds.deinit(allocator);

    var positional_only = false;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        offending.* = arg;
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (positional_only) {
            try assignPositional(&args, arg, d1_requested, batch_requested, suggest_requested, write_requested, record_requested);
            continue;
        }
        const inline_value = splitInline(arg);
        const name = if (inline_value) |inl| inl.name else arg;

        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.help = true;
        } else if (std.mem.eql(u8, name, "--version")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.version = true;
        } else if (std.mem.eql(u8, name, "--db")) {
            if (args.db != null) return error.DuplicateOption;
            args.db = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--d1")) {
            if (args.d1 != null) return error.DuplicateOption;
            args.d1 = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--config")) {
            if (args.config != null) return error.DuplicateOption;
            args.config = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--batch")) {
            if (args.batch != null) return error.DuplicateOption;
            args.batch = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--record")) {
            if (args.record != null) return error.DuplicateOption;
            args.record = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--out")) {
            if (args.out != null) return error.DuplicateOption;
            args.out = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--migration")) {
            if (args.migration != null) return error.DuplicateOption;
            args.migration = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--seed-data")) {
            if (args.seed_data != null) return error.DuplicateOption;
            args.seed_data = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--scale")) {
            if (args.scale != null) return error.DuplicateOption;
            args.scale = try parseScale(try optionValue(argv, &index, inline_value));
        } else if (std.mem.eql(u8, name, "--select")) {
            if (args.select != null) return error.DuplicateOption;
            if (args.write != null) return error.WriteRejectsSelect;
            if (args.sql != null) return error.SqlRejectsSelect;
            args.select = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--sql")) {
            if (args.sql != null) return error.DuplicateOption;
            if (args.select != null or args.write != null) return error.SqlRejectsSelect;
            args.sql = try optionValue(argv, &index, inline_value);
        } else if (std.mem.eql(u8, name, "--write")) {
            if (args.write != null) return error.DuplicateOption;
            if (args.select != null) return error.WriteRejectsSelect;
            args.write = try optionValue(argv, &index, inline_value);
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
        } else if (std.mem.eql(u8, name, "--show-rows")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.show_rows = true;
        } else if (std.mem.eql(u8, name, "--suggest")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.suggest = true;
        } else if (std.mem.eql(u8, name, "--audit-indexes")) {
            if (inline_value != null) return error.UnexpectedValue;
            args.audit_indexes = true;
        } else if (std.mem.eql(u8, name, "--runs")) {
            const raw = try optionValue(argv, &index, inline_value);
            args.runs = std.fmt.parseUnsigned(u32, raw, 10) catch return error.InvalidRuns;
            args.runs_given = true;
            if (args.runs > max_runs) return error.InvalidRuns;
        } else if (std.mem.eql(u8, name, "--format")) {
            const raw = try optionValue(argv, &index, inline_value);
            args.format = std.meta.stringToEnum(Format, raw) orelse return error.InvalidFormat;
        } else if (std.mem.eql(u8, name, "--n-plus-one-threshold")) {
            const raw = try optionValue(argv, &index, inline_value);
            args.n_plus_one_threshold = try parseNPlusOneThreshold(raw);
            args.n_plus_one_threshold_given = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            try assignPositional(&args, arg, d1_requested, batch_requested, suggest_requested, write_requested, record_requested);
        } else if (arg.len != 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            try assignPositional(&args, arg, d1_requested, batch_requested, suggest_requested, write_requested, record_requested);
        }
    }
    offending.* = null;
    if (args.scale != null) {
        if (args.seed_data == null) return error.ScaleRequiresSeedData;
        const conflicts = [_]struct { name: [:0]const u8, present: bool }{
            .{ .name = "--batch", .present = args.batch != null },
            .{ .name = "--suggest", .present = args.suggest },
            .{ .name = "--migration", .present = args.migration != null },
            .{ .name = "--audit-indexes", .present = args.audit_indexes },
            .{ .name = "--record", .present = args.record != null },
            .{ .name = "--format", .present = args.format == .kv },
        };
        for (conflicts) |conflict| {
            if (!conflict.present) continue;
            offending.* = conflict.name;
            return error.ScaleConflict;
        }
    }
    if (args.out != null and args.record == null) {
        offending.* = "--out";
        return error.OutRequiresRecord;
    }
    if (args.record != null) {
        const conflicts = [_]struct { name: [:0]const u8, present: bool }{
            .{ .name = "--db", .present = args.db != null },
            .{ .name = "--d1", .present = args.d1 != null },
            .{ .name = "--config", .present = args.config != null },
            .{ .name = "--batch", .present = args.batch != null },
            .{ .name = "--migration", .present = args.migration != null },
            .{ .name = "--seed-data", .present = args.seed_data != null },
            .{ .name = "--select", .present = args.select != null },
            .{ .name = "--write", .present = args.write != null },
            .{ .name = "--index-sql", .present = args.index_sql != null },
            .{ .name = "--bind", .present = binds.items.len != 0 },
            .{ .name = "--runs", .present = args.runs_given },
            .{ .name = "--timeout-ms", .present = args.timeout_ms != default_timeout_ms },
            .{ .name = "--show-binds", .present = args.show_binds },
            .{ .name = "--show-rows", .present = args.show_rows },
            .{ .name = "--suggest", .present = args.suggest },
            .{ .name = "--audit-indexes", .present = args.audit_indexes },
        };
        for (conflicts) |conflict| {
            if (!conflict.present) continue;
            offending.* = conflict.name;
            return error.RecordConflict;
        }
        if (args.format == .kv) {
            offending.* = "--format";
            return error.RecordRejectsFormat;
        }
    }
    if (args.n_plus_one_threshold_given and args.record == null) {
        offending.* = "--n-plus-one-threshold";
        return error.ThresholdRequiresRecord;
    }
    if (args.db != null and args.d1 != null) {
        offending.* = "--d1";
        return error.ConflictingDatabase;
    }
    if (args.config != null and args.d1 == null) {
        offending.* = "--config";
        return error.ConfigRequiresD1;
    }
    if (args.audit_indexes) {
        if (args.batch == null) {
            offending.* = "--batch";
            return error.AuditConflict;
        }
        if (args.suggest) {
            offending.* = "--suggest";
            return error.AuditConflict;
        }
        if (args.migration != null) {
            offending.* = "--migration";
            return error.AuditConflict;
        }
        if (args.seed_data != null) {
            offending.* = "--seed-data";
            return error.AuditConflict;
        }
    }
    if (args.migration != null) {
        if (args.batch == null) {
            offending.* = "--migration";
            return error.MigrationRequiresBatch;
        }
        if (args.suggest) {
            offending.* = "--suggest";
            return error.MigrationRejectsSuggest;
        }
        if (args.index_sql != null) {
            offending.* = "--index-sql";
            return error.MigrationRejectsIndex;
        }
    }
    if (args.batch != null) {
        if (args.select != null) {
            offending.* = "--select";
            return error.BatchTakesOnlyDatabasePath;
        }
        if (args.index_sql != null) {
            offending.* = "--index-sql";
            return error.BatchTakesOnlyDatabasePath;
        }
        if (binds.items.len != 0) {
            offending.* = "--bind";
            return error.BatchRejectsBind;
        }
        if (args.runs_given) {
            offending.* = "--runs";
            return error.BatchRejectsRuns;
        }
        if (args.format == .kv) {
            offending.* = "--format";
            return error.BatchRejectsKv;
        }
    }
    if (args.suggest) {
        if (args.batch == null and args.index_sql != null) {
            offending.* = "--index-sql";
            return error.SuggestRejectsIndex;
        }
        if (args.runs_given) {
            offending.* = "--runs";
            return error.SuggestRejectsRuns;
        }
        if (args.format == .kv) {
            offending.* = "--format";
            return error.SuggestRejectsKv;
        }
    }
    if (args.sql != null) {
        if (args.select != null) {
            offending.* = "--sql";
            return error.SqlRejectsSelect;
        }
        if (args.batch != null or args.record != null or args.write != null or args.migration != null or args.audit_indexes) {
            offending.* = "--sql";
            return error.SqlRejectedMode;
        }
    }
    if (isStdinPath(args.select)) {
        if (args.batch != null or args.record != null or args.write != null or args.migration != null or args.audit_indexes) {
            offending.* = "--select";
            return error.SqlRejectedMode;
        }
    }
    if (isStdinPath(args.index_sql) or isStdinPath(args.write) or isStdinPath(args.batch) or isStdinPath(args.migration)) {
        offending.* = "-";
        return error.StdinNotQuery;
    }
    if (args.write != null) {
        if (args.suggest) {
            offending.* = "--write";
            return error.WriteRejectsSuggest;
        }
        if (args.migration != null) {
            offending.* = "--write";
            return error.WriteRejectsMigration;
        }
        if (args.batch != null) {
            offending.* = "--write";
            return error.WriteRequiresSingle;
        }
    }
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

fn assignPositional(args: *Args, value: [:0]const u8, d1_requested: bool, batch_requested: bool, suggest_requested: bool, write_requested: bool, record_requested: bool) ParseError!void {
    if (record_requested) return error.RecordTakesNoPaths;
    if (value.len == 0) return error.EmptyPath;
    if (batch_requested) {
        if (!d1_requested and args.db == null) {
            args.db = value;
            return;
        }
        return error.BatchTakesOnlyDatabasePath;
    }
    if (!d1_requested and args.db == null) {
        args.db = value;
        return;
    }
    if (write_requested) {
        if (args.select != null) return error.WriteRejectsSelect;
        if (args.write == null) {
            args.write = value;
            return;
        }
        if (args.index_sql == null) {
            args.index_sql = value;
            return;
        }
        return error.TooManyPaths;
    }
    if (args.select == null and args.sql == null) {
        args.select = value;
        return;
    }
    if (suggest_requested) return error.SuggestTakesTwoPaths;
    if (args.index_sql == null) {
        args.index_sql = value;
        return;
    }
    return if (d1_requested) error.TooManyD1Paths else error.TooManyPaths;
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
    if (std.mem.eql(u8, token, "--")) return true;
    const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
    return isKnownLongOption(token[0..end]) or std.mem.eql(u8, token[0..end], "-h");
}

pub const required_option_count = 3;

pub fn missingRequired(args: Args, buffer: *[required_option_count][]const u8) []const []const u8 {
    var count: usize = 0;
    if (args.record != null) {
        if (args.out == null) {
            buffer[count] = "the output directory (--out)";
            count += 1;
        }
        return buffer[0..count];
    }
    if (args.db == null and args.d1 == null) {
        buffer[count] = "the database (a path, --db or --d1)";
        count += 1;
    }
    if (args.batch == null) {
        if (args.select == null and args.write == null and args.sql == null) {
            buffer[count] = "the SELECT or write file (a path, --select, --sql, or --write)";
            count += 1;
        }
        if (args.index_sql == null and !args.suggest) {
            buffer[count] = "the CREATE INDEX file (a path or --index-sql)";
            count += 1;
        }
    }
    return buffer[0..count];
}

const long_options = [_][]const u8{
    "--help",
    "--db",
    "--d1",
    "--config",
    "--batch",
    "--record",
    "--out",
    "--migration",
    "--seed-data",
    "--scale",
    "--select",
    "--sql",
    "--write",
    "--index-sql",
    "--bind",
    "--timeout-ms",
    "--show-binds",
    "--show-rows",
    "--suggest",
    "--audit-indexes",
    "--runs",
    "--format",
    "--n-plus-one-threshold",
    "--version",
};

const max_option_name = 32;

fn isStdinPath(path: ?[:0]const u8) bool {
    const text = path orelse return false;
    return std.mem.eql(u8, text, "-");
}

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

pub fn parseNPlusOneThreshold(raw: []const u8) ParseError!u32 {
    const value = std.fmt.parseUnsigned(u32, raw, 10) catch return error.InvalidNPlusOneThreshold;
    if (value != 0 and (value < 2 or value > max_n_plus_one_threshold)) return error.InvalidNPlusOneThreshold;
    return value;
}

pub fn parseScale(raw: []const u8) ParseError!Scale {
    var scale: Scale = .{};
    var previous: u64 = 0;
    var iterator = std.mem.splitScalar(u8, raw, ',');
    while (iterator.next()) |text| {
        if (scale.len == max_scale_steps) return error.InvalidScale;
        const value = std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidScale;
        if (value == 0 or value <= previous) return error.InvalidScale;
        scale.values[scale.len] = value;
        scale.len += 1;
        previous = value;
    }
    if (scale.len < 2) return error.InvalidScale;
    return scale;
}

pub fn parseBind(raw: [:0]const u8) ParseError!db.BindArg {
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

pub const usage_line = "usage: qenome <DB> <SELECT_FILE> <INDEX_FILE> [options]";

pub const d1_usage_line = "       qenome --d1 <BINDING> <SELECT_FILE> <INDEX_FILE> [options]";

pub const batch_usage_line = "       qenome <DB> --batch <FILE> [options]";

pub const audit_usage_line = "       qenome <DB> --batch <FILE> --audit-indexes [options]";

pub const d1_audit_usage_line = "       qenome --d1 <BINDING> --batch <FILE> --audit-indexes [options]";

pub const d1_batch_usage_line = "       qenome --d1 <BINDING> --batch <FILE> [options]";

pub const migration_usage_line = "       qenome <DB> --batch <FILE> --migration <FILE> [options]";

pub const d1_migration_usage_line = "       qenome --d1 <BINDING> --batch <FILE> --migration <FILE> [options]";

pub const sql_usage_line = "       qenome <DB> --sql <SQL> <INDEX_FILE> [options]";

pub const sql_suggest_usage_line = "       qenome <DB> --sql <SQL> --suggest [options]";

pub const suggest_usage_line = "       qenome <DB> <SELECT_FILE> --suggest [options]";

pub const d1_suggest_usage_line = "       qenome --d1 <BINDING> <SELECT_FILE> --suggest [options]";

pub const record_usage_line = "       qenome --record <FILE> --out <DIR>";

pub const write_usage_line = "       qenome <DB> --write <FILE> --index-sql <FILE> [options]";

pub const d1_write_usage_line = "       qenome --d1 <BINDING> --write <FILE> --index-sql <FILE> [options]";

pub const version = build_options.version;

pub fn printVersion(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("qenome {s}\n", .{version});
}

pub fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(usage_line ++ "\n" ++ d1_usage_line ++ "\n" ++ sql_usage_line ++ "\n" ++ batch_usage_line ++ "\n" ++ d1_batch_usage_line ++ "\n" ++ audit_usage_line ++ "\n" ++ d1_audit_usage_line ++ "\n" ++ migration_usage_line ++ "\n" ++ d1_migration_usage_line ++ "\n" ++ suggest_usage_line ++ "\n" ++ sql_suggest_usage_line ++ "\n" ++ d1_suggest_usage_line ++ "\n" ++ write_usage_line ++ "\n" ++ d1_write_usage_line ++ "\n" ++ record_usage_line ++ "\n" ++ usage_text.synopsis ++ "\n\n" ++ usage_text.body);
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.RecordTakesNoPaths => "--record reads a log and writes a manifest; do not pass a database or SQL path (see --help)",
        error.RecordConflict => "--record does not take the other mode options (see --help)",
        error.OutRequiresRecord => "--out is only used with --record (see --help)",
        error.RecordRejectsFormat => "--record supports --format human or json, not kv (see --help)",
        error.InvalidNPlusOneThreshold => "--n-plus-one-threshold expects 0 (off) or an integer from 2 to 1000000 (see --help)",
        error.ThresholdRequiresRecord => "--n-plus-one-threshold is only used with --record (see --help)",
        else => parseErrorMessageForMode(err),
    };
}

fn parseErrorMessageForMode(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingValue => "an option is missing its value (see --help)",
        error.DuplicateOption => "an option was given more than once (see --help)",
        error.UnexpectedValue => "an option that takes no value was given one (see --help)",
        error.UnknownOption => "unknown option (see --help)",
        error.TooManyPaths => "too many paths (see --help)",
        error.TooManyD1Paths => "--d1 takes two paths, the SELECT file and the CREATE INDEX file (see --help)",
        error.EmptyPath => "a path cannot be empty (see --help)",
        error.InvalidBindFormat => "--bind expects <N>:<TYPE>[:<VALUE>], where N is the parameter number and TYPE is int, real, text or null; e.g. --bind 1:int:1234, --bind 2:text:ok, --bind 3:null",
        error.InvalidTimeout => "--timeout-ms expects a non-negative integer",
        error.InvalidRuns => std.fmt.comptimePrint("--runs expects an integer from 0 to {d}", .{max_runs}),
        error.InvalidFormat => "--format expects human, kv or json",
        error.InvalidScale => "--scale expects 2 or 3 strictly increasing row counts, for example --scale 1000,10000 (see --help)",
        error.ScaleConflict => "--scale takes only its row counts; remove --batch, --suggest, --migration, --audit-indexes, --record, or --format kv (see --help)",
        error.ScaleRequiresSeedData => "--scale needs --seed-data (see --help)",
        error.ConflictingDatabase => "use either --db <PATH> or --d1 <BINDING>, not both (see --help)",
        error.ConfigRequiresD1 => "--config is only used with --d1 (see --help)",
        error.BatchTakesOnlyDatabasePath => "--batch takes only the database path; put the SELECT and CREATE INDEX files in the manifest (see --help)",
        error.BatchRejectsBind => "--batch does not take --bind; put the binds in the manifest (see --help)",
        error.BatchRejectsRuns => "--batch does not run the timing; remove --runs (see --help)",
        error.BatchRejectsKv => "--batch supports --format human or --format json, not kv (see --help)",
        error.AuditConflict => "--audit-indexes needs --batch and does not take --suggest, --migration, or --seed-data (see --help)",
        error.MigrationRequiresBatch => "--migration needs --batch; put the queries in a manifest (see --help)",
        error.MigrationRejectsSuggest => "--migration applies one SQL file; remove --suggest (see --help)",
        error.MigrationRejectsIndex => "--migration replaces the index file; remove --index-sql (see --help)",
        error.SuggestRejectsIndex => "--suggest suggests the index; remove --index-sql (see --help)",
        error.SuggestRejectsRuns => "--suggest does not run the timing; remove --runs (see --help)",
        error.SuggestRejectsKv => "--suggest supports --format human or --format json, not kv (see --help)",
        error.SuggestTakesTwoPaths => "--suggest takes two paths, the database and the SELECT file (see --help)",
        error.WriteRejectsSelect => "use either --select or --write, not both (see --help)",
        error.WriteRequiresSingle => "--write compares one statement; use --batch for a manifest (see --help)",
        error.WriteRejectsSuggest => "--write names the statement; remove --suggest (see --help)",
        error.WriteRejectsMigration => "--write compares one statement; remove --migration (see --help)",
        error.SqlRejectsSelect => "--sql replaces the SELECT file; remove --select or the SELECT path (see --help)",
        error.SqlRejectedMode => "--sql and a SELECT read from stdin are for one comparison or --suggest, not a manifest, --write, --record, or --migration (see --help)",
        error.StdinNotQuery => "- reads the SELECT from stdin for one comparison or --suggest; it is not a path for the index, write, batch, or migration file (see --help)",
        error.RecordTakesNoPaths, error.RecordConflict, error.OutRequiresRecord, error.RecordRejectsFormat, error.InvalidNPlusOneThreshold, error.ThresholdRequiresRecord => unreachable,
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
    const first = sql_lexer.keywordAt(trimmed, 0);
    const keywords = [_][]const u8{ "SELECT", "WITH", "CREATE", "INSERT", "UPDATE", "DELETE", "PRAGMA", "EXPLAIN" };
    for (keywords) |keyword| {
        if (!std.ascii.eqlIgnoreCase(first.text, keyword)) continue;
        if (first.end == trimmed.len) return true;
        return switch (trimmed[first.end]) {
            ' ', '\t', '\r', '\n', '(' => true,
            else => false,
        };
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

test "format defaults to human and takes human, kv or json" {
    const default = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(default.binds);
    try testing.expectEqual(Format.human, default.format);
    const kv = try parseArgs(testing.allocator, &.{ "Qenome", "--format", "kv" });
    defer testing.allocator.free(kv.binds);
    try testing.expectEqual(Format.kv, kv.format);
    const json = try parseArgs(testing.allocator, &.{ "Qenome", "--format=json" });
    defer testing.allocator.free(json.binds);
    try testing.expectEqual(Format.json, json.format);
    const human = try parseArgs(testing.allocator, &.{ "Qenome", "--format", "kv", "--format", "human" });
    defer testing.allocator.free(human.binds);
    try testing.expectEqual(Format.human, human.format);
    for ([_][:0]const u8{ "JSON", "KV", "human " }) |raw| {
        try testing.expectError(error.InvalidFormat, parseArgs(testing.allocator, &.{ "Qenome", "--format", raw }));
    }
}

test "a parse error names the argument it is about" {
    const cases = [_]struct { argv: []const [:0]const u8, err: ParseError, offending: []const u8 }{
        .{ .argv = &.{ "Qenome", "--db", "d", "--nope" }, .err = error.UnknownOption, .offending = "--nope" },
        .{ .argv = &.{ "Qenome", "--select" }, .err = error.MissingValue, .offending = "--select" },
        .{ .argv = &.{ "Qenome", "d", "s", "i", "extra" }, .err = error.TooManyPaths, .offending = "extra" },
        .{ .argv = &.{ "Qenome", "", "s", "i" }, .err = error.EmptyPath, .offending = "" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(case.err, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
    }
}

test "positional paths fill the first empty role" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "d.db", "s.sql", "i.sql" });
    defer testing.allocator.free(args.binds);

    try testing.expectEqualStrings("d.db", args.db.?);
    try testing.expectEqualStrings("s.sql", args.select.?);
    try testing.expectEqualStrings("i.sql", args.index_sql.?);
}

test "positional paths mix with named options" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "d.db", "--select", "s.sql", "--index-sql", "i.sql" },
        &.{ "Qenome", "--db", "d.db", "s.sql", "i.sql" },
        &.{ "Qenome", "--select", "s.sql", "d.db", "i.sql" },
        &.{ "Qenome", "--index-sql", "i.sql", "d.db", "s.sql" },
    };
    for (cases) |argv| {
        const args = try parseArgs(testing.allocator, argv);
        defer testing.allocator.free(args.binds);
        try testing.expectEqualStrings("d.db", args.db.?);
        try testing.expectEqualStrings("s.sql", args.select.?);
        try testing.expectEqualStrings("i.sql", args.index_sql.?);
    }
}

test "a path and a named option for the same role are a duplicate" {
    var offending: ?[:0]const u8 = null;
    try testing.expectError(
        error.DuplicateOption,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "d.db", "--db", "other.db", "s.sql", "i.sql" }, &offending),
    );
    try testing.expectEqualStrings("--db", offending.?);
}

test "double dash makes the rest positional" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--", "--db", "--select", "--index-sql" });
    defer testing.allocator.free(args.binds);
    try testing.expect(!args.help);
    try testing.expectEqualStrings("--db", args.db.?);
    try testing.expectEqualStrings("--select", args.select.?);
    try testing.expectEqualStrings("--index-sql", args.index_sql.?);

    const help_after = try parseArgs(testing.allocator, &.{ "Qenome", "--", "--help", "s.sql", "i.sql" });
    defer testing.allocator.free(help_after.binds);
    try testing.expect(!help_after.help);
    try testing.expectEqualStrings("--help", help_after.db.?);

    const literal = try parseArgs(testing.allocator, &.{ "Qenome", "--db=--", "--select", "s", "--index-sql", "i" });
    defer testing.allocator.free(literal.binds);
    try testing.expectEqualStrings("--", literal.db.?);

    var offending: ?[:0]const u8 = null;
    try testing.expectError(
        error.MissingValue,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--db", "--" }, &offending),
    );
    try testing.expectEqualStrings("--db", offending.?);
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

test "show-rows defaults to off and does not reveal binds" {
    const hidden = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(hidden.binds);
    try testing.expect(!hidden.show_rows);
    try testing.expect(!hidden.show_binds);

    const shown = try parseArgs(testing.allocator, &.{ "Qenome", "--show-rows" });
    defer testing.allocator.free(shown.binds);
    try testing.expect(shown.show_rows);
    try testing.expect(!shown.show_binds);
}

test "a flag rejects an inline value" {
    for ([_][:0]const u8{ "--help=1", "--show-binds=true", "--show-rows=1", "--version=1" }) |arg| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(
            error.UnexpectedValue,
            parseArgsReporting(testing.allocator, &.{ "Qenome", arg }, &offending),
        );
        try testing.expectEqualStrings(arg, offending.?);
    }
}

test "version is a flag that wins over other argument errors" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "--version" },
        &.{ "Qenome", "--version", "--nope" },
        &.{ "Qenome", "--version", "--db=" },
        &.{ "Qenome", "--db", "--version" },
        &.{ "Qenome", "--runs", "x", "--version" },
    };
    for (cases) |argv| {
        const args = try parseArgs(testing.allocator, argv);
        testing.allocator.free(args.binds);
        try testing.expect(args.version);
        try testing.expect(!args.help);
    }

    const help_wins = [_][]const [:0]const u8{
        &.{ "Qenome", "--version", "--help" },
        &.{ "Qenome", "--help", "--version" },
        &.{ "Qenome", "--version", "-h", "--nope" },
    };
    for (help_wins) |argv| {
        const args = try parseArgs(testing.allocator, argv);
        testing.allocator.free(args.binds);
        try testing.expect(args.help);
        try testing.expect(!args.version);
    }
}

test "a version after the double dash is a path" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--", "--version" });
    defer testing.allocator.free(args.binds);
    try testing.expect(!args.version);
    try testing.expectEqualStrings("--version", args.db.?);
}

test "the version line names the program and the version" {
    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try printVersion(&writer);
    try testing.expectEqualStrings("qenome " ++ version ++ "\n", writer.buffered());
    try testing.expect(version.len != 0);
}

test "missing required options keep the usage order" {
    var buffer: [required_option_count][]const u8 = undefined;

    const none = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(none.binds);
    const all = missingRequired(none, &buffer);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("the database (a path, --db or --d1)", all[0]);
    try testing.expectEqualStrings("the SELECT or write file (a path, --select, --sql, or --write)", all[1]);
    try testing.expectEqualStrings("the CREATE INDEX file (a path or --index-sql)", all[2]);

    const partial = try parseArgs(testing.allocator, &.{ "Qenome", "--select", "s" });
    defer testing.allocator.free(partial.binds);
    const rest = missingRequired(partial, &buffer);
    try testing.expectEqual(@as(usize, 2), rest.len);
    try testing.expectEqualStrings("the database (a path, --db or --d1)", rest[0]);
    try testing.expectEqualStrings("the CREATE INDEX file (a path or --index-sql)", rest[1]);
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
        "--d1",
        "--config",
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
        .{ .argv = &.{ "Qenome", "--db", "--show-rows" }, .option = "--db" },
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
    const options = [_][:0]const u8{ "--db", "--d1", "--config", "--select", "--index-sql" };
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
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "--help" },
        &.{ "Qenome", "--db", "d" },
        &.{ "Qenome", "--d1", "DB" },
        &.{ "Qenome", "--d1", "DB", "--config", "wrangler.toml" },
        &.{ "Qenome", "--batch", "batch.json" },
        &.{ "Qenome", "--batch", "batch.json", "--audit-indexes" },
        &.{ "Qenome", "--record", "record.log", "--out", "manifest-dir" },
        &.{ "Qenome", "--record", "record.log", "--out", "manifest-dir", "--n-plus-one-threshold", "20" },
        &.{ "Qenome", "--batch", "batch.json", "--migration", "m.sql" },
        &.{ "Qenome", "--seed-data", "seed.json" },
        &.{ "Qenome", "--seed-data", "seed.json", "--scale", "1000,5000" },
        &.{ "Qenome", "--select", "s" },
        &.{ "Qenome", "--sql", "SELECT 1" },
        &.{ "Qenome", "--write", "w" },
        &.{ "Qenome", "--index-sql", "i" },
        &.{ "Qenome", "--bind", "1:null" },
        &.{ "Qenome", "--timeout-ms", "1" },
        &.{ "Qenome", "--show-binds" },
        &.{ "Qenome", "--show-rows" },
        &.{ "Qenome", "--suggest" },
        &.{ "Qenome", "--runs", "1" },
        &.{ "Qenome", "--format", "kv" },
        &.{ "Qenome", "--version" },
    };
    var covered: usize = 0;
    for (long_options) |option| {
        var found = false;
        for (cases) |argv| {
            for (argv[1..]) |arg| {
                const name = arg[0..(std.mem.indexOfScalar(u8, arg, '=') orelse arg.len)];
                if (std.mem.eql(u8, option, name)) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        if (found) covered += 1;
    }
    try testing.expectEqual(long_options.len, covered);
    for (cases) |argv| {
        const args = try parseArgs(testing.allocator, argv);
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

test "--d1 and --db cannot be used together" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "--d1", "DB", "--db", "app.db", "s.sql", "i.sql" },
        &.{ "Qenome", "--db", "app.db", "--d1", "DB", "s.sql", "i.sql" },
    };
    for (cases) |argv| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(error.ConflictingDatabase, parseArgsReporting(testing.allocator, argv, &offending));
        try testing.expectEqualStrings("--d1", offending.?);
    }
}

test "--config needs --d1" {
    var offending: ?[:0]const u8 = null;
    try testing.expectError(
        error.ConfigRequiresD1,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--db", "app.db", "--config", "wrangler.toml", "s.sql", "i.sql" }, &offending),
    );
    try testing.expectEqualStrings("--config", offending.?);
}

test "--d1 leaves the positional paths to SELECT and CREATE INDEX" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--d1", "DB", "s.sql", "i.sql" });
    defer testing.allocator.free(args.binds);
    try testing.expect(args.db == null);
    try testing.expectEqualStrings("DB", args.d1.?);
    try testing.expectEqualStrings("s.sql", args.select.?);
    try testing.expectEqualStrings("i.sql", args.index_sql.?);
}

test "--d1 makes the positional paths fill SELECT and CREATE INDEX in any order" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "s.sql", "i.sql", "--d1", "DB" },
        &.{ "Qenome", "--d1", "DB", "s.sql", "i.sql" },
        &.{ "Qenome", "--d1=DB", "s.sql", "i.sql" },
        &.{ "Qenome", "s.sql", "i.sql", "--d1=DB" },
        &.{ "Qenome", "s.sql", "--d1", "DB", "i.sql" },
        &.{ "Qenome", "--d1", "DB", "--", "s.sql", "i.sql" },
    };
    for (cases) |argv| {
        const args = try parseArgs(testing.allocator, argv);
        defer testing.allocator.free(args.binds);
        try testing.expect(args.db == null);
        try testing.expectEqualStrings("DB", args.d1.?);
        try testing.expectEqualStrings("s.sql", args.select.?);
        try testing.expectEqualStrings("i.sql", args.index_sql.?);
    }
}

test "a third path with --d1 is a usage error" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "x.sql", "s.sql", "i.sql", "--d1", "DB" },
        &.{ "Qenome", "--d1", "DB", "x.sql", "s.sql", "i.sql" },
    };
    for (cases) |argv| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(error.TooManyD1Paths, parseArgsReporting(testing.allocator, argv, &offending));
        try testing.expectEqualStrings("i.sql", offending.?);
    }
    const message = parseErrorMessage(error.TooManyD1Paths);
    try testing.expect(std.mem.indexOf(u8, message, "SELECT file") != null);
    try testing.expect(std.mem.indexOf(u8, message, "CREATE INDEX file") != null);
}

test "an explicit --db with --d1 is a conflict in any order" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "--db", "x.db", "--d1", "DB", "s.sql", "i.sql" },
        &.{ "Qenome", "--d1", "DB", "--db", "x.db", "s.sql", "i.sql" },
        &.{ "Qenome", "x.db", "--db", "y.db", "--d1", "DB" },
    };
    for (cases) |argv| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(error.ConflictingDatabase, parseArgsReporting(testing.allocator, argv, &offending));
        try testing.expectEqualStrings("--d1", offending.?);
    }
}

test "a value that looks like --d1 does not choose the D1 roles" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--select=--d1", "d.db", "i.sql" });
    defer testing.allocator.free(args.binds);
    try testing.expect(args.d1 == null);
    try testing.expectEqualStrings("d.db", args.db.?);
    try testing.expectEqualStrings("--d1", args.select.?);
    try testing.expectEqualStrings("i.sql", args.index_sql.?);
}

test "a --d1 taken as the next option is still a missing value" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "--select", "--d1", "s.sql" },
        &.{ "Qenome", "--db", "--d1", "s.sql" },
    };
    for (cases) |argv| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(error.MissingValue, parseArgsReporting(testing.allocator, argv, &offending));
        try testing.expect(offending.?[0] == '-');
    }
}

test "a --d1 after the double dash is a path" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--", "--d1", "s.sql" });
    defer testing.allocator.free(args.binds);
    try testing.expect(args.d1 == null);
    try testing.expectEqualStrings("--d1", args.db.?);
    try testing.expectEqualStrings("s.sql", args.select.?);
}

test "the usage shows the D1 synopsis" {
    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "--d1 <BINDING>") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "3.53.4") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "whatever the order") != null);
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

test "a format error names all three formats" {
    try testing.expectEqualStrings("--format expects human, kv or json", parseErrorMessage(error.InvalidFormat));
}

test "a bind format error shows parameter numbers and examples" {
    const message = parseErrorMessage(error.InvalidBindFormat);
    try testing.expect(std.mem.indexOf(u8, message, "parameter number") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 1:int:1234") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 2:text:ok") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--bind 3:null") != null);
}

test "the usage option list and the known option names agree" {
    var buffer: [32768]u8 = undefined;
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

test "--batch takes only the database and requires it" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "app.db", "--batch", "batch.json", "--timeout-ms", "5" });
    defer testing.allocator.free(args.binds);
    try testing.expectEqualStrings("app.db", args.db.?);
    try testing.expectEqualStrings("batch.json", args.batch.?);
    try testing.expectEqual(@as(u64, 5), args.timeout_ms);
    var buffer: [required_option_count][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), missingRequired(args, &buffer).len);

    const none = try parseArgs(testing.allocator, &.{ "Qenome", "--batch", "batch.json" });
    defer testing.allocator.free(none.binds);
    const missing = missingRequired(none, &buffer);
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("the database (a path, --db or --d1)", missing[0]);
}

test "--batch rejects the SELECT, index, bind, runs and kv options" {
    const cases = [_]struct { argv: []const [:0]const u8, err: ParseError, offending: []const u8 }{
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--select", "s" }, .err = error.BatchTakesOnlyDatabasePath, .offending = "--select" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--index-sql", "i" }, .err = error.BatchTakesOnlyDatabasePath, .offending = "--index-sql" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--bind", "1:null" }, .err = error.BatchRejectsBind, .offending = "--bind" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--runs", "3" }, .err = error.BatchRejectsRuns, .offending = "--runs" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--runs", "10" }, .err = error.BatchRejectsRuns, .offending = "--runs" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b", "--format", "kv" }, .err = error.BatchRejectsKv, .offending = "--format" },
        .{ .argv = &.{ "Qenome", "d", "s", "--batch", "b" }, .err = error.BatchTakesOnlyDatabasePath, .offending = "s" },
        .{ .argv = &.{ "Qenome", "--d1", "DB", "s", "--batch", "b" }, .err = error.BatchTakesOnlyDatabasePath, .offending = "s" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(case.err, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
        try testing.expect(parseErrorMessage(case.err).len != 0);
    }
}

test "--batch is a known option that needs a value and is given once" {
    var offending: ?[:0]const u8 = null;
    try testing.expectError(
        error.MissingValue,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--batch" }, &offending),
    );
    try testing.expectEqualStrings("--batch", offending.?);
    offending = null;
    try testing.expectError(
        error.MissingValue,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--batch=", "d" }, &offending),
    );
    try testing.expectEqualStrings("--batch=", offending.?);
    offending = null;
    try testing.expectError(
        error.DuplicateOption,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--batch", "a", "--batch", "b" }, &offending),
    );
    try testing.expectEqualStrings("--batch", offending.?);
    offending = null;
    try testing.expectError(
        error.MissingValue,
        parseArgsReporting(testing.allocator, &.{ "Qenome", "--batch", "--" }, &offending),
    );
    try testing.expectEqualStrings("--batch", offending.?);
}

test "the usage shows the batch synopsis and the batch option" {
    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "--batch <FILE>") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "qenome <DB> --batch <FILE>") != null);
}

test "--suggest takes one SELECT and keeps the binds" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "app.db", "select.sql", "--suggest", "--bind", "1:int:1" });
    defer testing.allocator.free(args.binds);
    try testing.expect(args.suggest);
    try testing.expectEqualStrings("app.db", args.db.?);
    try testing.expectEqualStrings("select.sql", args.select.?);
    try testing.expect(args.index_sql == null);
    try testing.expectEqual(@as(usize, 1), args.binds.len);
    var buffer: [required_option_count][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), missingRequired(args, &buffer).len);

    const d1 = try parseArgs(testing.allocator, &.{ "Qenome", "--d1", "DB", "select.sql", "--suggest" });
    defer testing.allocator.free(d1.binds);
    try testing.expect(d1.suggest);
    try testing.expectEqualStrings("select.sql", d1.select.?);

    const with_batch = try parseArgs(testing.allocator, &.{ "Qenome", "app.db", "--batch", "batch.json", "--suggest" });
    defer testing.allocator.free(with_batch.binds);
    try testing.expect(with_batch.suggest);
}

test "--suggest rejects the index file, the timing, kv and a third path" {
    const cases = [_]struct { argv: []const [:0]const u8, err: ParseError, offending: []const u8 }{
        .{ .argv = &.{ "Qenome", "d", "s", "--suggest", "--index-sql", "i" }, .err = error.SuggestRejectsIndex, .offending = "--index-sql" },
        .{ .argv = &.{ "Qenome", "d", "s", "i", "--suggest" }, .err = error.SuggestTakesTwoPaths, .offending = "i" },
        .{ .argv = &.{ "Qenome", "d", "s", "--suggest", "--runs", "3" }, .err = error.SuggestRejectsRuns, .offending = "--runs" },
        .{ .argv = &.{ "Qenome", "d", "s", "--suggest", "--format", "kv" }, .err = error.SuggestRejectsKv, .offending = "--format" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(case.err, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
        try testing.expect(parseErrorMessage(case.err).len != 0);
    }

    var offending: ?[:0]const u8 = null;
    try testing.expectError(error.UnexpectedValue, parseArgsReporting(testing.allocator, &.{ "Qenome", "--suggest=1" }, &offending));
    try testing.expectEqualStrings("--suggest=1", offending.?);
}

test "the usage shows the --suggest synopsis and option" {
    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "qenome <DB> <SELECT_FILE> --suggest") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "--suggest            ask SQLite") != null);
}

test "--migration needs --batch and rejects suggest and the index file" {
    const cases = [_]struct { argv: []const [:0]const u8, err: ParseError, offending: []const u8 }{
        .{ .argv = &.{ "Qenome", "d", "s", "--migration", "m.sql" }, .err = error.MigrationRequiresBatch, .offending = "--migration" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b.json", "--migration", "m.sql", "--suggest" }, .err = error.MigrationRejectsSuggest, .offending = "--suggest" },
        .{ .argv = &.{ "Qenome", "d", "--batch", "b.json", "--migration", "m.sql", "--index-sql", "i" }, .err = error.MigrationRejectsIndex, .offending = "--index-sql" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(case.err, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
        try testing.expect(parseErrorMessage(case.err).len != 0);
    }
}

test "--migration with a batch keeps the database and the migration path" {
    const args = try parseArgs(testing.allocator, &.{ "Qenome", "app.db", "--batch", "batch.json", "--migration", "0002.sql" });
    defer testing.allocator.free(args.binds);
    try testing.expectEqualStrings("app.db", args.db.?);
    try testing.expectEqualStrings("batch.json", args.batch.?);
    try testing.expectEqualStrings("0002.sql", args.migration.?);
    try testing.expect(args.select == null);
    try testing.expect(args.index_sql == null);

    var missing_buffer: [required_option_count][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), missingRequired(args, &missing_buffer).len);
}

test "the usage shows the --migration synopsis and option" {
    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "qenome <DB> --batch <FILE> --migration <FILE>") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "--migration <FILE>") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "6 a --migration query") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "CREATE TABLE") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "not-judged") != null);
}

test "--audit-indexes needs a batch manifest and rejects the comparison modes" {
    const cases = [_]struct { argv: []const [:0]const u8, offending: [:0]const u8 }{
        .{ .argv = &.{ "Qenome", "--db", "d", "--audit-indexes" }, .offending = "--batch" },
        .{ .argv = &.{ "Qenome", "--db", "d", "--batch", "b.json", "--audit-indexes", "--suggest" }, .offending = "--suggest" },
        .{ .argv = &.{ "Qenome", "--db", "d", "--batch", "b.json", "--audit-indexes", "--migration", "m.sql" }, .offending = "--migration" },
        .{ .argv = &.{ "Qenome", "--db", "d", "--batch", "b.json", "--audit-indexes", "--seed-data", "s.json" }, .offending = "--seed-data" },
    };
    for (cases) |case| {
        var offending: ?[:0]const u8 = null;
        try testing.expectError(error.AuditConflict, parseArgsReporting(testing.allocator, case.argv, &offending));
        try testing.expectEqualStrings(case.offending, offending.?);
    }

    const args = try parseArgs(testing.allocator, &.{ "Qenome", "--db", "d", "--batch", "b.json", "--audit-indexes", "--format", "json" });
    defer testing.allocator.free(args.binds);
    try testing.expect(args.audit_indexes);
    try testing.expectEqual(Format.json, args.format);

    var missing_buffer: [required_option_count][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), missingRequired(args, &missing_buffer).len);
}

test "the usage shows the --audit-indexes synopsis and option" {
    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "qenome <DB> --batch <FILE> --audit-indexes") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "--audit-indexes      with --batch") != null);
}
