const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const result_rows = @import("../result.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_d1 = @import("d1.zig");
const cli_query = @import("query.zig");
const cli_report = @import("report.zig");
const cli_timing = @import("timing.zig");
const cli_workspace = @import("workspace.zig");

const measure = cli_query.measure;
const decide = cli_comparison.decide;
const judgeRows = cli_comparison.judgeRows;
const timeRuns = cli_timing.timeRuns;
const fileSize = cli_workspace.fileSize;
const signalPending = cli_control.signalPending;
const reportInterrupted = cli_control.reportInterrupted;
const WorkDir = cli_workspace.WorkDir;
const ExitCode = cli_control.ExitCode;

pub const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    d1: ?cli_d1.Resolved = null,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
    runs: u32,
    work_parent: []const u8,
    show_binds: bool = false,
    show_rows: bool = false,
    progress_interval_ns: u64 = std.time.ns_per_s,
};

pub const Computed = struct {
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: cli_report.Report,
};

pub const RowBuffers = struct {
    budget: result_rows.Budget = .{},
    baseline: result_rows.RowCollector = undefined,
    variant: result_rows.RowCollector = undefined,

    pub fn init(self: *RowBuffers, allocator: std.mem.Allocator) void {
        self.* = .{
            .budget = .{},
            .baseline = result_rows.RowCollector.init(allocator, &self.budget),
            .variant = result_rows.RowCollector.init(allocator, &self.budget),
        };
    }

    pub fn deinit(self: *RowBuffers) void {
        self.baseline.deinit();
        self.variant.deinit();
    }
};

pub const Result = union(enum) {
    computed: Computed,
    failed: ExitCode,
};

pub fn compute(
    io: Io,
    arena: std.mem.Allocator,
    inputs: Inputs,
    rows: *RowBuffers,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
    work: *const WorkDir,
) Result {
    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    var failure: ExitCode = .rejected;
    var baseline: cli_query.QuerySession = .{};
    defer baseline.deinit(.baseline, stderr, cleanup_failed);
    if (!baseline.open(inputs.baseline_path, inputs.select_sql, inputs.binds, .baseline, inputs.index_sql, stderr, &failure)) return .{ .failed = failure };

    if (!baseline.checkCreateIndex(inputs.index_sql, stderr)) return .{ .failed = .rejected };
    const candidate_table = baseline.database.indexTarget(arena, inputs.index_sql) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .{ .failed = .rejected };
    };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());
    var detail: db.SnapshotDetail = .{};
    work.applyCandidate(inputs.index_sql, &control, &detail) catch |err| switch (err) {
        error.Timeout => {
            stderr.print("error: --index-sql exceeded the time limit of {d} ms\n", .{inputs.timeout_ms}) catch {};
            return .{ .failed = .timeout };
        },
        error.Interrupted => return .{ .failed = reportInterrupted(stderr) },
        else => {
            const reason = if (detail.len != 0) detail.text() else @errorName(err);
            stderr.print("error: --index-sql: the index could not be created on the variant: {s}\n", .{reason}) catch {};
            return .{ .failed = .rejected };
        },
    };

    const keep_rows = !baseline.clues().alwaysIncomparable();
    const before = measure(arena, &baseline, inputs.select_sql, inputs.binds, &control, if (keep_rows) &rows.baseline else null, .baseline, stderr, &failure) orelse return .{ .failed = failure };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    var variant: cli_query.QuerySession = .{};
    defer variant.deinit(.variant, stderr, cleanup_failed);
    if (!variant.open(inputs.variant_path, inputs.select_sql, inputs.binds, .variant, inputs.index_sql, stderr, &failure)) return .{ .failed = failure };
    const variant_out: ?*result_rows.RowCollector = if (keep_rows and rows.baseline.failure == null) &rows.variant else null;
    const after = measure(arena, &variant, inputs.select_sql, inputs.binds, &control, variant_out, .variant, stderr, &failure) orelse return .{ .failed = failure };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    const outcome = decide(arena, before, after, &rows.baseline, &rows.variant, .{
        .clues = db.Clues.merge(baseline.clues(), variant.clues()),
        .limit_or_offset = db.mentionsLimitOrOffset(inputs.select_sql),
    });

    var report: cli_report.Report = .{ .judgement = .{ .verdict = .not_judged } };
    if (outcome.verdict == .mismatch) {
        report.judgement.add("the result rows do not match, so the row counts are not judged");
    } else if (outcome.verdict == .incomparable) {
        report.judgement.add("the result rows cannot be compared, so the row counts are not judged");
    } else {
        report.judgement = judgeRows(before, after);
        if (inputs.runs != 0) {
            const timing = timeRuns(io, arena, &baseline, &variant, .{ .runs = inputs.runs, .timeout_ms = inputs.timeout_ms, .progress_interval_ns = inputs.progress_interval_ns }, &control, stderr, &failure) orelse return .{ .failed = failure };
            report.timing = timing.summary();
        }
    }
    const warnings = baseline.database.tableWarnings(arena, candidate_table, &control) catch |err| {
        return .{ .failed = diagnosticFailure(err, &baseline, &control, stderr) };
    };
    report.warnings = .{ .no_analyze_stats = warnings.no_analyze_stats, .data_too_small = warnings.data_too_small };
    report.warnings.bind_dependent_partial_index = variant.database.findBindDependentPartialIndex(arena, after.plan, inputs.select_sql, inputs.binds, &control) catch null;
    report.sizes = .{
        .baseline = fileSize(io, inputs.baseline_path, .baseline, stderr) orelse return .{ .failed = .rejected },
        .variant = fileSize(io, inputs.variant_path, .variant, stderr) orelse return .{ .failed = .rejected },
    };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    return .{ .computed = .{ .before = before, .after = after, .outcome = outcome, .report = report } };
}

fn diagnosticFailure(err: anyerror, session: *cli_query.QuerySession, control: *db.StepControl, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.Timeout => cli_query.reportStepFailure(error.Timeout, session, control.timeout_ms, .baseline, null, stderr),
        error.Interrupted => reportInterrupted(stderr),
        error.OutOfMemory => blk: {
            stderr.writeAll("error: out of memory\n") catch {};
            break :blk .rejected;
        },
        else => cli_query.reportStepFailure(error.StepFailed, session, control.timeout_ms, .baseline, null, stderr),
    };
}
