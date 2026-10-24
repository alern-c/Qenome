//! Command line contract for Qenome.
//!
//! `run` takes a database path, one read-only SELECT file, one candidate
//! CREATE INDEX file, typed bind values, and an optional time limit. The
//! database is opened read-only and copied as one snapshot (`baseline`) into a
//! private temporary directory; the baseline is then copied byte for byte to
//! `variant`. The candidate index is built on the variant only, and the SELECT
//! runs on both copies. The summary shows, per copy, the row count, the query
//! plan, and the execution counters, then whether the result rows are the
//! same. Same rows are then timed again on both copies in alternating rounds,
//! and the times, the database sizes, and a verdict that never changes the
//! exit code are added. The temporary directory is removed on every return
//! path.
//!
//! Every outcome is a process exit code:
//!
//! * 0: the SELECT ran on both copies and the result rows match (as a
//!   multiset)
//! * 1: an input was rejected (file, database, snapshot, temporary directory,
//!   SQL, DDL, bind, index build, query plan, step)
//! * 2: the arguments cannot be used
//! * 3: the SELECT ran on both copies and the result rows differ
//! * 4: the SELECT ran on both copies, but the results cannot be compared
//! * 5: a connection or the temporary directory could not be cleaned up after
//!   a run that would have exited 0
//! * 124: the time limit interrupted the index build or a SELECT
//! * 129 / 130 / 143: SIGHUP / SIGINT / SIGTERM interrupted the run

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

// The public names and signatures stay as they were before the split, so
// `src/root.zig` and the CLI tests keep working. The bodies live in the
// module of the stage that owns them.
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

/// The process exit code of a finished comparison. Kept in the coordinator so
/// that the comparison itself does not depend on the CLI exit codes.
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
    // A signal only sets a flag; the checks below and the SELECT progress
    // handler consume it. Clearing it here keeps a later run in the same
    // process from seeing a stale interrupt.
    installSignalHandlers();
    defer clearSignals();

    // Every input below lives until the run ends, so one arena keeps the
    // cleanup path short.
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

    const database_path = args.db orelse return missingArgument(stderr, "--db");
    const select_path = args.select orelse return missingArgument(stderr, "--select");
    const index_path = args.index_sql orelse return missingArgument(stderr, "--index-sql");

    const select_sql = readSqlFile(io, arena, select_path) catch |err| {
        stderr.print("error: cannot read --select file '{s}': {s}\n", .{ select_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };
    const index_sql = readSqlFile(io, arena, index_path) catch |err| {
        stderr.print("error: cannot read --index-sql file '{s}': {s}\n", .{ index_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };

    // A signal that arrived before the copy skips it.
    if (signalPending()) return reportInterrupted(stderr);

    const parent_path = tempParentPath(temp_parent);
    var work = WorkDir.create(io, arena, parent_path) catch |err| {
        stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ parent_path, @errorName(err) }) catch {};
        return .rejected;
    };

    var cleanup_failed = false;
    const code = blk: {
        // Every connection below is closed before this runs.
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

/// Everything one checked run needs.
const Inputs = struct {
    /// The database as given, for the summary.
    database_path: [:0]const u8,
    /// The snapshot without the candidate index.
    baseline_path: [:0]const u8,
    /// The copy of the snapshot that gets the candidate index.
    variant_path: [:0]const u8,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
    runs: u32,
    /// Where the temporary directory was made, for the measurement
    /// conditions.
    work_parent: []const u8,
    show_binds: bool = false,
    format: cli_args.Format = .human,
    /// Least time between two progress lines of the timing (D-603). Tests
    /// set it to 0 to see every line.
    progress_interval_ns: u64 = std.time.ns_per_s,
};

/// Opens the baseline and walks the accepted order: check the SELECT, bind,
/// and check the candidate DDL on the baseline; build the index on the
/// variant; read the plan of the SELECT and run it on the baseline, then on
/// the variant; compare the rows. The index is built first so that a failing
/// build (a UNIQUE index over duplicates) shows before a long SELECT runs.
/// `cleanup_failed` is set when a connection cannot be closed. The plans live
/// in `arena`; the result rows live in `allocator`, so that a run that
/// outgrows the budget gives them back at once.
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
    // A signal that arrived before the SELECT started still stops the run.
    if (signalPending()) return reportInterrupted(stderr);

    var failure: ExitCode = .rejected;
    var baseline: cli_query.QuerySession = .{};
    // The session finalises its statement before it closes its connection, on
    // every return path (D-105=案1).
    defer baseline.deinit(.baseline, stderr, cleanup_failed);
    if (!baseline.open(inputs.baseline_path, inputs.select_sql, inputs.binds, .baseline, inputs.index_sql, stderr, &failure)) return failure;

    if (!baseline.checkCreateIndex(inputs.index_sql, stderr)) return .rejected;

    if (signalPending()) return reportInterrupted(stderr);

    // The time limit and the signal flag cover the index build and each
    // SELECT execution, each with the full limit (D-509); prepare, bind, and
    // the plan reads stay outside it.
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

    // A SELECT whose rows are never compared (D-502, D-507) still runs on
    // both copies for its plan and counters, but its rows are not kept.
    const keep_rows = !baseline.clues().alwaysIncomparable();
    const before = measure(arena, &baseline, inputs.select_sql, inputs.binds, &control, if (keep_rows) &baseline_rows else null, .baseline, stderr, &failure) orelse return failure;

    if (signalPending()) return reportInterrupted(stderr);

    var variant: cli_query.QuerySession = .{};
    defer variant.deinit(.variant, stderr, cleanup_failed);
    // The same SQL and binds were accepted on the baseline, so a failure here
    // comes from the variant itself.
    if (!variant.open(inputs.variant_path, inputs.select_sql, inputs.binds, .variant, inputs.index_sql, stderr, &failure)) return failure;
    // Rows the baseline could not keep cannot be compared, so the variant only
    // runs for its plan and counters then.
    const variant_out: ?*result_rows.RowCollector = if (keep_rows and baseline_rows.failure == null) &variant_rows else null;
    const after = measure(arena, &variant, inputs.select_sql, inputs.binds, &control, variant_out, .variant, stderr, &failure) orelse return failure;

    // A signal that arrives after the last progress check but before the run
    // ends still wins over the summary.
    if (signalPending()) return reportInterrupted(stderr);

    const outcome = decide(arena, before, after, &baseline_rows, &variant_rows, .{
        .clues = db.Clues.merge(baseline.clues(), variant.clues()),
        .limit_or_offset = db.mentionsLimitOrOffset(inputs.select_sql),
    });

    // Times are only worth reading for the same rows (D-601), and the first
    // run of each copy above was the warm-up.
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

    // The timed runs end on the same checks as the first ones.
    if (signalPending()) return reportInterrupted(stderr);

    // The summary is the result of the run, so a failed write is a rejection,
    // whatever the comparison said. It is written only here, after every run,
    // so a rejection, timeout, or interruption leaves stdout empty.
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

/// Names the argument a parse error is about. An unknown argument is the
/// user's own text, so it is quoted and escaped like a TEXT value: it cannot
/// steer the terminal.
fn reportParseError(stderr: *Io.Writer, err: ParseError, offending: ?[:0]const u8) Io.Writer.Error!void {
    const arg = offending orelse return stderr.print("error: {s}\n", .{parseErrorMessage(err)});
    switch (err) {
        error.UnknownOption, error.UnexpectedArgument => {
            try stderr.writeAll(if (err == error.UnknownOption) "error: unknown option " else "error: unexpected argument ");
            try result_rows.writeText(stderr, arg);
            try stderr.writeAll(" (see --help)\n");
        },
        // Only an option of this CLI can miss its value, so it is plain text.
        error.MissingValue => try stderr.print("error: {s} needs a value (see --help)\n", .{arg}),
        else => try stderr.print("error: {s}\n", .{parseErrorMessage(err)}),
    }
}

fn missingArgument(stderr: *Io.Writer, option: []const u8) ExitCode {
    stderr.print("error: {s} is required (see --help)\n", .{option}) catch {};
    return .usage;
}

const testing = std.testing;

test {
    // The tests that drive the whole CLI live in a test-only file, which is
    // reachable from this entry only.
    _ = @import("cli/tests.zig");
}

test "the compatibility re-exports keep the public names and signatures" {
    // Every public name of the single-file CLI stays available from `cli`,
    // with the same type, so `src/root.zig` and a caller keep working.
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

    // The signatures themselves are part of the contract, so name their
    // types once: the aliases must keep them.
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
