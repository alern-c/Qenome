const std = @import("std");
const Io = std.Io;
const db = @import("db.zig");
const result_rows = @import("result.zig");

const cli_args = @import("cli/args.zig");
const cli_control = @import("cli/control.zig");
const cli_comparison = @import("cli/comparison.zig");
const cli_query = @import("cli/query.zig");
const cli_workspace = @import("cli/workspace.zig");
const cli_timing = @import("cli/timing.zig");
const cli_report = @import("cli/report.zig");

pub const max_sql_bytes = cli_args.max_sql_bytes;
pub const SqlFileError = cli_args.SqlFileError;
pub const readSqlFile = cli_args.readSqlFile;
pub const default_timeout_ms = cli_args.default_timeout_ms;
pub const default_runs = cli_args.default_runs;
pub const max_runs = cli_args.max_runs;
pub const Args = cli_args.Args;
pub const ParseError = cli_args.ParseError;
pub const parseArgs = cli_args.parseArgs;
pub const usage = cli_args.usage;
pub const ExitCode = cli_control.ExitCode;
pub const finalExitCode = cli_control.finalExitCode;

const tempParentPath = cli_workspace.tempParentPath;
const WorkDir = cli_workspace.WorkDir;
const prepareCopies = cli_workspace.prepareCopies;
const fileSize = cli_workspace.fileSize;
const measure = cli_query.measure;
const sqliteVersion = cli_query.sqliteVersion;
const sqliteSourceId = cli_query.sqliteSourceId;
const decide = cli_comparison.decide;
const timeRuns = cli_timing.timeRuns;
const judgeTime = cli_timing.judgeTime;
const TimeReport = cli_report.TimeReport;
const Header = cli_report.Header;
const writeReport = cli_report.writeReport;
const installSignalHandlers = cli_control.installSignalHandlers;
const clearSignals = cli_control.clearSignals;
const signalPending = cli_control.signalPending;
const reportInterrupted = cli_control.reportInterrupted;
const parseErrorMessage = cli_args.parseErrorMessage;
const fileErrorMessage = cli_args.fileErrorMessage;

fn resultExitCode(outcome: cli_comparison.Outcome) ExitCode {
    return switch (outcome.verdict) {
        .match => .ok,
        .mismatch => .mismatch,
        .incomparable => .incomparable,
    };
}

pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    temp_parent: ?[]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    installSignalHandlers();
    defer clearSignals();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var offending: ?[:0]const u8 = null;
    const args = cli_args.parseArgsReporting(arena, argv, &offending) catch |err| {
        reportParseError(stderr, err, offending) catch {};
        return if (err == error.OutOfMemory) .rejected else .usage;
    };

    if (args.help) {
        usage(stdout) catch {};
        return .ok;
    }

    var missing_buffer: [cli_args.required_option_count][]const u8 = undefined;
    const missing = cli_args.missingRequired(args, &missing_buffer);
    if (missing.len != 0) {
        return missingArguments(stderr, missing, missing.len == cli_args.required_option_count);
    }

    const database_path = args.db.?;
    const select_path = args.select.?;
    const index_path = args.index_sql.?;

    const select_sql = readSqlFile(io, arena, select_path) catch |err| {
        stderr.print("error: cannot read --select file '{s}': {s}\n", .{ select_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };
    const index_sql = readSqlFile(io, arena, index_path) catch |err| {
        stderr.print("error: cannot read --index-sql file '{s}': {s}\n", .{ index_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };

    if (signalPending()) return reportInterrupted(stderr);

    const parent_path = tempParentPath(temp_parent);
    var work = WorkDir.create(io, arena, parent_path) catch |err| {
        stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ parent_path, @errorName(err) }) catch {};
        return .rejected;
    };

    var cleanup_failed = false;
    const code = blk: {
        defer work.remove(io, stderr, &cleanup_failed);

        if (prepareCopies(io, database_path, &work, stderr, &cleanup_failed)) |failure| break :blk failure;

        const inputs: Inputs = .{
            .database_path = database_path,
            .baseline_path = work.baseline_path,
            .variant_path = work.variant_path,
            .select_path = select_path,
            .index_path = index_path,
            .select_sql = select_sql,
            .index_sql = index_sql,
            .binds = args.binds,
            .timeout_ms = args.timeout_ms,
            .runs = args.runs,
            .work_parent = parent_path,
            .show_binds = args.show_binds,
            .format = args.format,
        };
        break :blk runChecked(io, arena, allocator, inputs, stdout, stderr, &cleanup_failed, &work);
    };
    return finalExitCode(code, cleanup_failed);
}

const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
    runs: u32,
    work_parent: []const u8,
    show_binds: bool = false,
    format: cli_args.Format = .human,
    progress_interval_ns: u64 = std.time.ns_per_s,
};

fn runChecked(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
    work: *const WorkDir,
) ExitCode {
    if (signalPending()) return reportInterrupted(stderr);

    var failure: ExitCode = .rejected;
    var baseline: cli_query.QuerySession = .{};
    defer baseline.deinit(.baseline, stderr, cleanup_failed);
    if (!baseline.open(inputs.baseline_path, inputs.select_sql, inputs.binds, .baseline, inputs.index_sql, stderr, &failure)) return failure;

    if (!baseline.checkCreateIndex(inputs.index_sql, stderr)) return .rejected;

    if (signalPending()) return reportInterrupted(stderr);

    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());
    var detail: db.SnapshotDetail = .{};
    work.applyCandidate(inputs.index_sql, &control, &detail) catch |err| switch (err) {
        error.Timeout => {
            stderr.print("error: --index-sql exceeded the time limit of {d} ms\n", .{inputs.timeout_ms}) catch {};
            return .timeout;
        },
        error.Interrupted => return reportInterrupted(stderr),
        else => {
            const reason = if (detail.len != 0) detail.text() else @errorName(err);
            stderr.print("error: --index-sql: the index could not be created on the variant: {s}\n", .{reason}) catch {};
            return .rejected;
        },
    };

    var budget: result_rows.Budget = .{};
    var baseline_rows = result_rows.RowCollector.init(allocator, &budget);
    defer baseline_rows.deinit();
    var variant_rows = result_rows.RowCollector.init(allocator, &budget);
    defer variant_rows.deinit();

    const keep_rows = !baseline.clues().alwaysIncomparable();
    const before = measure(arena, &baseline, inputs.select_sql, inputs.binds, &control, if (keep_rows) &baseline_rows else null, .baseline, stderr, &failure) orelse return failure;

    if (signalPending()) return reportInterrupted(stderr);

    var variant: cli_query.QuerySession = .{};
    defer variant.deinit(.variant, stderr, cleanup_failed);
    if (!variant.open(inputs.variant_path, inputs.select_sql, inputs.binds, .variant, inputs.index_sql, stderr, &failure)) return failure;
    const variant_out: ?*result_rows.RowCollector = if (keep_rows and baseline_rows.failure == null) &variant_rows else null;
    const after = measure(arena, &variant, inputs.select_sql, inputs.binds, &control, variant_out, .variant, stderr, &failure) orelse return failure;

    if (signalPending()) return reportInterrupted(stderr);

    const outcome = decide(arena, before, after, &baseline_rows, &variant_rows, .{
        .clues = db.Clues.merge(baseline.clues(), variant.clues()),
        .limit_or_offset = db.mentionsLimitOrOffset(inputs.select_sql),
    });

    var report: TimeReport = .{ .judgement = .{ .verdict = .not_judged } };
    if (outcome.verdict == .mismatch) {
        report.judgement.add("the result rows do not match, so the SELECT is not timed");
    } else if (outcome.verdict == .incomparable) {
        report.judgement.add("the result rows cannot be compared, so the SELECT is not timed");
    } else if (inputs.runs == 0) {
        report.judgement.add("--runs 0 skips the timing");
    } else {
        const timing = timeRuns(io, arena, &baseline, &variant, .{ .runs = inputs.runs, .timeout_ms = inputs.timeout_ms, .progress_interval_ns = inputs.progress_interval_ns }, &control, stderr, &failure) orelse return failure;
        report.timing = timing.summary();
        report.judgement = judgeTime(before, after, report.timing.?);
    }
    report.sizes = .{
        .baseline = fileSize(io, inputs.baseline_path, .baseline, stderr) orelse return .rejected,
        .variant = fileSize(io, inputs.variant_path, .variant, stderr) orelse return .rejected,
    };

    if (signalPending()) return reportInterrupted(stderr);

    const header: cli_report.Header = .{
        .database_path = inputs.database_path,
        .select_path = inputs.select_path,
        .index_path = inputs.index_path,
        .work_parent = inputs.work_parent,
        .sqlite_version = sqliteVersion(),
        .sqlite_source_id = sqliteSourceId(),
        .binds = inputs.binds,
        .show_binds = inputs.show_binds,
    };
    writeReport(stdout, inputs.format, header, before, after, outcome, report) catch {
        stderr.print("error: the summary could not be written\n", .{}) catch {};
        return .rejected;
    };
    return resultExitCode(outcome);
}

fn reportParseError(stderr: *Io.Writer, err: ParseError, offending: ?[:0]const u8) Io.Writer.Error!void {
    const arg = offending orelse return stderr.print("error: {s}\n", .{parseErrorMessage(err)});
    switch (err) {
        error.UnknownOption, error.UnexpectedArgument => {
            try stderr.writeAll(if (err == error.UnknownOption) "error: unknown option " else "error: unexpected argument ");
            try result_rows.writeText(stderr, arg);
            if (err == error.UnknownOption) {
                if (cli_args.suggestOptionName(arg)) |suggestion| {
                    try stderr.writeAll("; did you mean '");
                    try stderr.writeAll(suggestion);
                    try stderr.writeAll("'?");
                }
            }
            try stderr.writeAll(" (see --help)\n");
        },
        error.MissingValue => {
            const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            try stderr.print("error: {s} needs a value (see --help)\n", .{arg[0..end]});
        },
        error.DuplicateOption => {
            const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            try stderr.print("error: {s} was given more than once (see --help)\n", .{arg[0..end]});
        },
        error.UnexpectedValue => {
            const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            try stderr.print("error: {s} does not take a value (see --help)\n", .{arg[0..end]});
        },
        else => try stderr.print("error: {s}\n", .{parseErrorMessage(err)}),
    }
}

fn missingArguments(stderr: *Io.Writer, missing: []const []const u8, show_usage: bool) ExitCode {
    if (show_usage) stderr.writeAll(cli_args.usage_line ++ "\n") catch {};
    const noun = if (missing.len == 1) "option" else "options";
    stderr.print("error: missing required {s}: ", .{noun}) catch {};
    for (missing, 0..) |name, position| {
        if (position != 0) stderr.writeAll(", ") catch {};
        stderr.writeAll(name) catch {};
    }
    stderr.writeAll(" (see --help)\n") catch {};
    return .usage;
}

const testing = std.testing;

test {
    _ = @import("cli/tests.zig");
}

test "the compatibility re-exports keep the public names and signatures" {
    try testing.expectEqual(@as(usize, 1024 * 1024), max_sql_bytes);
    try testing.expectEqual(@as(u64, 30_000), default_timeout_ms);
    try testing.expectEqual(@as(u32, 10), default_runs);
    try testing.expectEqual(@as(u32, 1000), max_runs);
    try testing.expectEqual(@as(u8, 0), @backingInt(ExitCode.ok));

    const parsed = try parseArgs(testing.allocator, &.{ "Qenome", "--db", "d", "--select", "s", "--index-sql", "i" });
    defer testing.allocator.free(parsed.binds);
    try testing.expectEqualStrings("d", parsed.db.?);
    try testing.expectEqualStrings("s", parsed.select.?);
    try testing.expectEqualStrings("i", parsed.index_sql.?);

    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "usage: qenome"));
    try testing.expectEqual(ExitCode.cleanup, finalExitCode(.ok, true));

    const read_file: *const fn (Io, std.mem.Allocator, []const u8) (SqlFileError || Io.Dir.ReadFileAllocError)![:0]u8 = readSqlFile;
    const parse_args: *const fn (std.mem.Allocator, []const [:0]const u8) ParseError!Args = parseArgs;
    const print_usage: *const fn (*Io.Writer) Io.Writer.Error!void = usage;
    const run_cli: *const fn (Io, std.mem.Allocator, []const [:0]const u8, ?[]const u8, *Io.Writer, *Io.Writer) ExitCode = run;
    const final_code: *const fn (ExitCode, bool) ExitCode = finalExitCode;
    _ = read_file;
    _ = parse_args;
    _ = print_usage;
    _ = run_cli;
    _ = final_code;
}
