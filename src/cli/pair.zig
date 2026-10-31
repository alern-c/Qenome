const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const result_rows = @import("../result.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_query = @import("query.zig");
const report_model = @import("../report/model.zig");
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
    d1: ?report_model.D1 = null,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    write_sql: ?[:0]const u8 = null,
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
    report: report_model.Report,
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

    if (inputs.write_sql) |write_sql| return computeWrite(io, arena, inputs, write_sql, rows, stderr, cleanup_failed, work);

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

    var report: report_model.Report = .{ .judgement = .{ .verdict = .not_judged } };
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
    report.warnings = .{
        .no_analyze_stats = warnings.no_analyze_stats,
        .data_too_small = warnings.data_too_small,
        .unapplied_migrations = inputs.unapplied_migrations,
    };
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

const WriteExecution = struct {
    rows: u64,
    counters: db.Counters,
    changes: u64,
    total_changes: u64,
    executions: u32 = 0,
};

const WriteRuns = struct {
    first: WriteExecution,
    repeat_mismatch: ?cli_comparison.Side = null,
};

const WriteSession = struct {
    database: db.Db = .{},
    statement: ?*sqlite.sqlite3_stmt = null,
    opened: bool = false,

    fn open(
        self: *WriteSession,
        path: [:0]const u8,
        sql: [:0]const u8,
        binds: []const db.BindArg,
        side: cli_comparison.Side,
        stderr: *Io.Writer,
        failure: *ExitCode,
    ) bool {
        self.database.openWritable(path) catch |err| {
            stderr.print("error: cannot open the {t} '{s}' for writing: {s}\n", .{ side, path, cli_query.openErrorMessage(err) }) catch {};
            failure.* = .rejected;
            return false;
        };
        self.opened = true;

        self.statement = self.database.prepareWrite(sql) catch |err| {
            reportWritePrepareFailure(stderr, side, err, &self.database);
            failure.* = .rejected;
            return false;
        };

        db.bindAll(self.statement.?, binds) catch |err| {
            const parameters = sqlite.sqlite3_bind_parameter_count(self.statement.?);
            const given: u64 = @intCast(binds.len);
            stderr.print("error: --bind on the {t}: {s} (parameters in the write: {d}; --bind given: {d})\n", .{
                side, cli_query.bindErrorMessage(err), parameters, given,
            }) catch {};
            failure.* = .rejected;
            return false;
        };
        return true;
    }

    fn checkCreateIndex(self: *WriteSession, sql: [:0]const u8, stderr: *Io.Writer) bool {
        self.database.checkCreateIndex(sql) catch |err| {
            cli_query.reportCheckFailure(stderr, "--index-sql", err, &self.database);
            self.database.checkWrite(sql) catch return false;
            stderr.writeAll("hint: the write and CREATE INDEX files may be swapped\n") catch {};
            return false;
        };
        return true;
    }

    fn plan(
        self: *WriteSession,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        binds: []const db.BindArg,
        control: *db.StepControl,
        side: cli_comparison.Side,
        stderr: *Io.Writer,
        failure: *ExitCode,
    ) ?db.Plan {
        return self.database.explainDml(arena, sql, binds, control) catch |err| {
            switch (err) {
                error.Timeout => {
                    stderr.print("error: --write exceeded the time limit of {d} ms while reading the plan on the {t}\n", .{ control.timeout_ms, side }) catch {};
                    failure.* = .timeout;
                },
                error.Interrupted => failure.* = reportInterrupted(stderr),
                error.OutOfMemory => {
                    stderr.writeAll("error: out of memory\n") catch {};
                    failure.* = .rejected;
                },
                else => {
                    const detail = if (err == error.ExplainFailed and self.database.errorCode() != sqlite.SQLITE_OK)
                        self.database.message()
                    else
                        @errorName(err);
                    stderr.print("error: --write: the query plan could not be read on the {t}: {s}\n", .{ side, detail }) catch {};
                    failure.* = .rejected;
                },
            }
            return null;
        };
    }

    fn columnCount(self: *const WriteSession) c_int {
        return db.columnCount(self.statement.?);
    }

    fn execute(
        self: *WriteSession,
        control: *db.StepControl,
        rows_out: ?*result_rows.RowCollector,
        run_number: u32,
        timeout_ms: u64,
        side: cli_comparison.Side,
        stderr: *Io.Writer,
        failure: *ExitCode,
    ) ?WriteExecution {
        db.resetStatement(self.statement.?) catch |err| {
            failure.* = reportWriteStepFailure(err, self, timeout_ms, side, run_number, stderr);
            return null;
        };
        self.database.beginWrite(control) catch |err| {
            failure.* = reportWriteStepFailure(err, self, timeout_ms, side, run_number, stderr);
            return null;
        };

        const total_before = self.database.totalChanges();
        const rows = self.database.stepDml(self.statement.?, control, rows_out) catch |err| {
            self.database.rollbackWrite() catch {};
            failure.* = reportWriteStepFailure(err, self, timeout_ms, side, run_number, stderr);
            return null;
        };
        const counters = db.takeCounters(self.statement.?);
        const changes = self.database.changes();
        const total_after = self.database.totalChanges();

        self.database.rollbackWrite() catch |err| {
            failure.* = reportWriteStepFailure(err, self, timeout_ms, side, run_number, stderr);
            return null;
        };
        return .{
            .rows = rows,
            .counters = counters,
            .changes = changes,
            .total_changes = total_after - total_before,
            .executions = run_number,
        };
    }

    fn deinit(self: *WriteSession, side: cli_comparison.Side, stderr: *Io.Writer, cleanup_failed: *bool) void {
        if (self.statement) |statement| {
            _ = sqlite.sqlite3_finalize(statement);
            self.statement = null;
        }
        if (!self.opened) return;
        self.database.close() catch {
            cleanup_failed.* = true;
            stderr.print("error: the database connection of the {t} could not be closed: {s}\n", .{ side, self.database.message() }) catch {};
            return;
        };
        self.opened = false;
    }
};

fn reportWritePrepareFailure(stderr: *Io.Writer, side: cli_comparison.Side, err: db.CheckError, database: *const db.Db) void {
    if (database.errorCode() != sqlite.SQLITE_OK) {
        stderr.print("error: --write on the {t}: {s}: {s}\n", .{ side, cli_query.checkErrorMessage(err), database.message() }) catch {};
    } else {
        stderr.print("error: --write on the {t}: {s}\n", .{ side, cli_query.checkErrorMessage(err) }) catch {};
    }
}

fn reportWriteStepFailure(
    err: db.StepError,
    session: *WriteSession,
    timeout_ms: u64,
    side: cli_comparison.Side,
    run_number: ?u32,
    stderr: *Io.Writer,
) ExitCode {
    var buffer: [32]u8 = undefined;
    const run_name = if (run_number) |number| std.fmt.bufPrint(&buffer, " (run {d})", .{number}) catch "" else "";
    switch (err) {
        error.Timeout => {
            stderr.print("error: --write exceeded the time limit of {d} ms on the {t}{s}\n", .{ timeout_ms, side, run_name }) catch {};
            return .timeout;
        },
        error.Interrupted => return reportInterrupted(stderr),
        error.StepFailed => {
            stderr.print("error: --write failed on the {t}{s}: {s}\n", .{ side, run_name, session.database.message() }) catch {};
            return .rejected;
        },
    }
}

fn executeWriteRuns(
    session: *WriteSession,
    runs: u32,
    control: *db.StepControl,
    collector: *result_rows.RowCollector,
    side: cli_comparison.Side,
    timeout_ms: u64,
    stderr: *Io.Writer,
    failure: *ExitCode,
) ?WriteRuns {
    var first: ?WriteExecution = null;
    var round: u32 = 0;
    while (round < runs) : (round += 1) {
        if (signalPending()) {
            failure.* = reportInterrupted(stderr);
            return null;
        }
        const run_number = round + 1;
        const execution = session.execute(control, if (round == 0) collector else null, run_number, timeout_ms, side, stderr, failure) orelse return null;
        if (first) |expected| {
            if (execution.rows != expected.rows or
                execution.changes != expected.changes or
                execution.total_changes != expected.total_changes or
                !std.meta.eql(execution.counters, expected.counters))
            {
                var result = expected;
                result.executions = run_number;
                return .{ .first = result, .repeat_mismatch = side };
            }
        } else {
            first = execution;
        }
    }
    var result = first orelse return null;
    result.executions = runs;
    return .{ .first = result };
}

fn writeMeasurement(plan: db.Plan, execution: WriteExecution, columns: c_int) cli_comparison.Measurement {
    return .{
        .rows = execution.rows,
        .plan = plan,
        .counters = execution.counters,
        .columns = columns,
        .changes = execution.changes,
        .total_changes = execution.total_changes,
        .executions = execution.executions,
    };
}

fn skippedWriteMeasurement(plan: db.Plan, columns: c_int) cli_comparison.Measurement {
    return .{
        .rows = 0,
        .plan = plan,
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 0, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = columns,
    };
}

fn computeWrite(
    io: Io,
    arena: std.mem.Allocator,
    inputs: Inputs,
    write_sql: [:0]const u8,
    rows: *RowBuffers,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
    work: *const WorkDir,
) Result {
    var failure: ExitCode = .rejected;
    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());

    var baseline: WriteSession = .{};
    defer baseline.deinit(.baseline, stderr, cleanup_failed);
    if (!baseline.open(inputs.baseline_path, write_sql, inputs.binds, .baseline, stderr, &failure)) return .{ .failed = failure };

    if (!baseline.checkCreateIndex(inputs.index_sql, stderr)) return .{ .failed = .rejected };
    const candidate_table = baseline.database.indexTarget(arena, inputs.index_sql) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .{ .failed = .rejected };
    };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    if (applyWriteCandidate(work, inputs.index_sql, &control, inputs.timeout_ms, stderr)) |code| return .{ .failed = code };

    const before_plan = baseline.plan(arena, write_sql, inputs.binds, &control, .baseline, stderr, &failure) orelse return .{ .failed = failure };

    var variant: WriteSession = .{};
    defer variant.deinit(.variant, stderr, cleanup_failed);
    if (!variant.open(inputs.variant_path, write_sql, inputs.binds, .variant, stderr, &failure)) return .{ .failed = failure };
    const after_plan = variant.plan(arena, write_sql, inputs.binds, &control, .variant, stderr, &failure) orelse return .{ .failed = failure };

    const sizes: report_model.Sizes = .{
        .baseline = fileSize(io, inputs.baseline_path, .baseline, stderr) orelse return .{ .failed = .rejected },
        .variant = fileSize(io, inputs.variant_path, .variant, stderr) orelse return .{ .failed = .rejected },
    };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };

    var report: report_model.Report = .{ .judgement = .{ .verdict = .not_judged }, .sizes = sizes };
    report.warnings.unapplied_migrations = inputs.unapplied_migrations;
    const clues = db.Clues.merge(baseline.database.clues, variant.database.clues);
    if (cli_comparison.writeIncomparable(arena, clues)) |outcome| {
        const before = skippedWriteMeasurement(before_plan, baseline.columnCount());
        const after = skippedWriteMeasurement(after_plan, variant.columnCount());
        report.judgement.add("the write was not run, so the row counts are not judged");
        tryWriteWarnings(arena, &report, &baseline, candidate_table, &control) catch |err| {
            return .{ .failed = writeDiagnosticFailure(err, &baseline, &control, stderr) };
        };
        return .{ .computed = .{ .before = before, .after = after, .outcome = outcome, .report = report } };
    }

    const runs = if (inputs.runs == 0) 1 else inputs.runs;
    const before_runs = executeWriteRuns(&baseline, runs, &control, &rows.baseline, .baseline, inputs.timeout_ms, stderr, &failure) orelse return .{ .failed = failure };
    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };
    const after_runs = executeWriteRuns(&variant, runs, &control, &rows.variant, .variant, inputs.timeout_ms, stderr, &failure) orelse return .{ .failed = failure };

    const before = writeMeasurement(before_plan, before_runs.first, baseline.columnCount());
    const after = writeMeasurement(after_plan, after_runs.first, variant.columnCount());

    var outcome: cli_comparison.Outcome = undefined;
    var changes_mismatch = false;
    if (before_runs.repeat_mismatch) |side| {
        outcome = cli_comparison.writeRepeatMismatch(side);
    } else if (after_runs.repeat_mismatch) |side| {
        outcome = cli_comparison.writeRepeatMismatch(side);
    } else {
        outcome = decide(arena, before, after, &rows.baseline, &rows.variant, .{
            .clues = .{},
            .limit_or_offset = false,
        });
        if (before_runs.first.changes != after_runs.first.changes or before_runs.first.total_changes != after_runs.first.total_changes) {
            changes_mismatch = true;
            outcome.verdict = .mismatch;
        }
    }

    if (changes_mismatch) {
        report.judgement = cli_comparison.writeChangesMismatch();
    } else if (outcome.verdict == .mismatch) {
        report.judgement.add("the RETURNING rows do not match, so the row counts are not judged");
    } else if (outcome.verdict == .incomparable) {
        report.judgement.add("the result rows cannot be compared, so the row counts are not judged");
    } else {
        report.judgement = judgeRows(before, after);
    }
    report.write_runs = before.executions;

    tryWriteWarnings(arena, &report, &baseline, candidate_table, &control) catch |err| {
        return .{ .failed = writeDiagnosticFailure(err, &baseline, &control, stderr) };
    };

    if (signalPending()) return .{ .failed = reportInterrupted(stderr) };
    return .{ .computed = .{ .before = before, .after = after, .outcome = outcome, .report = report } };
}

fn applyWriteCandidate(work: *const WorkDir, index_sql: [:0]const u8, control: *db.StepControl, timeout_ms: u64, stderr: *Io.Writer) ?ExitCode {
    var detail: db.SnapshotDetail = .{};
    work.applyCandidate(index_sql, control, &detail) catch |err| switch (err) {
        error.Timeout => {
            stderr.print("error: --index-sql exceeded the time limit of {d} ms\n", .{timeout_ms}) catch {};
            return .timeout;
        },
        error.Interrupted => return reportInterrupted(stderr),
        else => {
            const reason = if (detail.len != 0) detail.text() else @errorName(err);
            stderr.print("error: --index-sql: the index could not be created on the variant: {s}\n", .{reason}) catch {};
            return .rejected;
        },
    };
    return null;
}

fn tryWriteWarnings(
    arena: std.mem.Allocator,
    report: *report_model.Report,
    baseline: *WriteSession,
    candidate_table: []const u8,
    control: *db.StepControl,
) !void {
    const warnings = try baseline.database.tableWarnings(arena, candidate_table, control);
    report.warnings.no_analyze_stats = warnings.no_analyze_stats;
    report.warnings.data_too_small = warnings.data_too_small;
}

fn writeDiagnosticFailure(err: anyerror, session: *WriteSession, control: *db.StepControl, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.Timeout => reportWriteStepFailure(error.Timeout, session, control.timeout_ms, .baseline, null, stderr),
        error.Interrupted => reportInterrupted(stderr),
        error.OutOfMemory => blk: {
            stderr.writeAll("error: out of memory\n") catch {};
            break :blk .rejected;
        },
        else => reportWriteStepFailure(error.StepFailed, session, control.timeout_ms, .baseline, null, stderr),
    };
}
