const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const cli_args = @import("args.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_pair = @import("pair.zig");
const cli_query = @import("query.zig");
const cli_seed = @import("seed.zig");
const cli_workspace = @import("workspace.zig");
const result_rows = @import("../result.zig");
const report_model = @import("../report/model.zig");
const report_json = @import("../report/json.zig");
const report_scale = @import("../report/scale.zig");

const ExitCode = cli_control.ExitCode;
const WorkDir = cli_workspace.WorkDir;

pub const Inputs = struct {
    database_path: [:0]const u8,
    d1: ?report_model.D1 = null,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
    select_path: ?[:0]const u8 = null,
    select_sql: ?[:0]const u8 = null,
    write_path: ?[:0]const u8 = null,
    index_path: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
    runs: u32,
    format: cli_args.Format = .human,
    show_binds: bool = false,
    show_rows: bool = false,
    temp_parent: []const u8,
    seed: cli_seed.Spec,
    scale: cli_args.Scale,
};

const Plan = struct {
    rows: u64,
    spec: cli_seed.Spec,
    seed: report_model.Seed,
};

const StepResult = union(enum) {
    measured: report_scale.Step,
    failed: ExitCode,
};

const Session = struct {
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    select_path: [:0]const u8,
    select_sql: [:0]const u8,
    write_sql: ?[:0]const u8,
    index_sql: [:0]const u8,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
};

fn outOfMemory(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: out of memory\n") catch {};
    return .rejected;
}

fn reportFailure(stderr: *Io.Writer, err: report_model.Error) ExitCode {
    switch (err) {
        error.OutOfMemory => stderr.writeAll("error: out of memory\n") catch {},
        else => stderr.print("error: the summary could not be written\n", .{}) catch {},
    }
    return .rejected;
}

fn stepExitCode(outcome: cli_comparison.Outcome) ExitCode {
    return switch (outcome.verdict) {
        .match => .ok,
        .mismatch => .mismatch,
        .incomparable => .incomparable,
    };
}

fn rank(code: ExitCode) u8 {
    return switch (code) {
        .mismatch => 4,
        .incomparable => 3,
        .timeout => 2,
        .rejected => 1,
        else => 0,
    };
}

fn heavier(current: ExitCode, next: ExitCode) ExitCode {
    return if (rank(next) > rank(current)) next else current;
}

fn isSignal(code: ExitCode) bool {
    return code == .interrupted or code == .terminated or code == .hangup;
}

fn largestRows(spec: cli_seed.Spec) u64 {
    var largest: u64 = 0;
    for (spec.tables) |table| largest = @max(largest, table.rows);
    return largest;
}

fn scaledRows(current: u64, largest: u64, target: u64) u64 {
    if (largest == 0) return target;
    if (current == 0) return 1;
    const scaled = (current * target + largest / 2) / largest;
    return @max(scaled, 1);
}

pub fn scaleSpec(arena: std.mem.Allocator, spec: cli_seed.Spec, rows: u64) !cli_seed.Spec {
    const largest = largestRows(spec);
    const tables = try arena.alloc(cli_seed.Table, spec.tables.len);
    for (spec.tables, 0..) |table, index| {
        tables[index] = .{
            .name = table.name,
            .rows = scaledRows(table.rows, largest, rows),
            .columns = table.columns,
        };
    }
    return .{ .path = spec.path, .seed = spec.seed, .tables = tables };
}

fn buildSeedReport(arena: std.mem.Allocator, spec: cli_seed.Spec) !report_model.Seed {
    const tables = try arena.alloc(report_model.SeedTable, spec.tables.len);
    var total: u64 = 0;
    for (spec.tables, 0..) |table, index| {
        tables[index] = .{ .table = table.name, .rows = table.rows };
        total += table.rows;
    }
    return .{ .path = spec.path, .seed = spec.seed, .rows = total, .tables = tables };
}

fn buildPlans(arena: std.mem.Allocator, spec: cli_seed.Spec, steps: []const u64) ![]Plan {
    const plans = try arena.alloc(Plan, steps.len);
    for (steps, 0..) |rows, index| {
        const scaled = try scaleSpec(arena, spec, rows);
        plans[index] = .{ .rows = rows, .spec = scaled, .seed = try buildSeedReport(arena, scaled) };
    }
    return plans;
}

fn validateSteps(stderr: *Io.Writer, steps: []const u64) ?ExitCode {
    for (steps) |rows| {
        if (rows > cli_seed.max_rows_per_table) {
            stderr.print(
                "error: --scale {d}: a step must not exceed the seed limit of {d} rows for one table (see --help)\n",
                .{ rows, cli_seed.max_rows_per_table },
            ) catch {};
            return .usage;
        }
    }
    return null;
}

fn validateScaled(stderr: *Io.Writer, plans: []const Plan) ?ExitCode {
    for (plans) |plan| {
        var total: u64 = 0;
        for (plan.spec.tables) |table| {
            if (table.rows > cli_seed.max_rows_per_table) {
                stderr.print(
                    "error: --scale {d}: table '{s}' would hold {d} rows, over the seed limit of {d} rows for one table (see --help)\n",
                    .{ plan.rows, table.name, table.rows, cli_seed.max_rows_per_table },
                ) catch {};
                return .usage;
            }
            total += table.rows;
        }
        if (total > cli_seed.max_total_rows) {
            stderr.print(
                "error: --scale {d}: the seed spec would hold {d} rows in total, over the seed limit of {d} rows (see --help)\n",
                .{ plan.rows, total, cli_seed.max_total_rows },
            ) catch {};
            return .usage;
        }
    }
    return null;
}

fn readSql(io: Io, arena: std.mem.Allocator, stderr: *Io.Writer, option: []const u8, path: [:0]const u8) ?[:0]const u8 {
    return cli_args.readSqlFile(io, arena, path) catch |err| {
        stderr.print("error: cannot read {s} file '{s}': {s}\n", .{ option, path, cli_args.fileErrorMessage(err) }) catch {};
        return null;
    };
}

fn baseHeader(session: *const Session) report_model.Header {
    return .{
        .database_path = session.inputs.database_path,
        .select_path = session.select_path,
        .write_path = session.inputs.write_path,
        .index_path = session.inputs.index_path,
        .work_parent = session.inputs.temp_parent,
        .sqlite_version = cli_query.sqliteVersion(),
        .sqlite_source_id = cli_query.sqliteSourceId(),
        .qenome_version = cli_args.version,
        .binds = session.inputs.binds,
        .show_binds = session.inputs.show_binds,
        .show_rows = session.inputs.show_rows,
        .d1 = session.inputs.d1,
    };
}

fn stepHeader(session: *const Session, plan: Plan, exit_code: u8) report_model.Header {
    var header = baseHeader(session);
    header.exit_code = exit_code;
    header.seed = plan.seed;
    return header;
}

fn comparisonJson(session: *const Session, plan: Plan, computed: cli_pair.Computed, code: ExitCode) ?[]const u8 {
    var out: Io.Writer.Allocating = .init(session.allocator);
    defer out.deinit();
    report_json.writeJsonTo(
        &out.writer,
        session.allocator,
        stepHeader(session, plan, @intCast(@backingInt(code))),
        computed.before,
        computed.after,
        computed.outcome,
        computed.report,
        .minified,
    ) catch |err| {
        _ = reportFailure(session.stderr, err);
        return null;
    };
    return session.arena.dupe(u8, out.written()) catch {
        _ = outOfMemory(session.stderr);
        return null;
    };
}

fn exampleRows(arena: std.mem.Allocator, rows: []const []const u8) ![]const []const u8 {
    const lines = try arena.alloc([]const u8, rows.len);
    for (rows, 0..) |row, index| {
        var out: Io.Writer.Allocating = .init(arena);
        try result_rows.writeRow(&out.writer, row);
        lines[index] = out.written();
    }
    return lines;
}

fn runStep(session: *const Session, plan: Plan) StepResult {
    var work = WorkDir.create(session.io, session.arena, session.inputs.temp_parent) catch |err| {
        session.stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ session.inputs.temp_parent, cli_args.fileErrorMessage(err) }) catch {};
        return .{ .failed = .rejected };
    };
    defer work.remove(session.io, session.stderr, session.cleanup_failed);

    if (cli_workspace.prepareCopies(session.io, session.arena, session.inputs.database_path, &work, plan.spec, true, session.stderr, session.cleanup_failed)) |failure| {
        return .{ .failed = failure };
    }

    var rows: cli_pair.RowBuffers = undefined;
    rows.init(session.allocator);
    defer rows.deinit();

    const computed = switch (cli_pair.compute(session.io, session.arena, .{
        .database_path = session.inputs.database_path,
        .baseline_path = work.baseline_path,
        .variant_path = work.variant_path,
        .d1 = session.inputs.d1,
        .select_path = session.select_path,
        .index_path = session.inputs.index_path,
        .select_sql = session.select_sql,
        .write_sql = session.write_sql,
        .index_sql = session.index_sql,
        .binds = session.inputs.binds,
        .timeout_ms = session.inputs.timeout_ms,
        .runs = session.inputs.runs,
        .work_parent = session.inputs.temp_parent,
        .show_binds = session.inputs.show_binds,
        .show_rows = session.inputs.show_rows,
    }, &rows, session.stderr, session.cleanup_failed, &work)) {
        .computed => |value| value,
        .failed => |failure| return .{ .failed = failure },
    };

    const code = stepExitCode(computed.outcome);
    const json = comparisonJson(session, plan, computed, code) orelse return .{ .failed = .rejected };
    var baseline_examples: []const []const u8 = &.{};
    var variant_examples: []const []const u8 = &.{};
    var baseline_only: usize = 0;
    var variant_only: usize = 0;
    if (computed.outcome.comparison) |comparison| {
        baseline_only = comparison.baseline_only;
        variant_only = comparison.variant_only;
        if (session.inputs.show_rows and !comparison.matched) {
            baseline_examples = exampleRows(session.arena, comparison.baselineExamples()) catch |err| {
                _ = reportFailure(session.stderr, err);
                return .{ .failed = .rejected };
            };
            variant_examples = exampleRows(session.arena, comparison.variantExamples()) catch |err| {
                _ = reportFailure(session.stderr, err);
                return .{ .failed = .rejected };
            };
        }
    }
    return .{ .measured = .{
        .rows = plan.rows,
        .tables = plan.seed.tables,
        .before = computed.before,
        .after = computed.after,
        .result = computed.outcome.verdict,
        .judgement = computed.report.judgement,
        .plan_changed = !cli_comparison.samePlan(computed.before.plan, computed.after.plan),
        .timing = computed.report.timing,
        .warnings = computed.report.warnings,
        .baseline_only = baseline_only,
        .variant_only = variant_only,
        .baseline_examples = baseline_examples,
        .variant_examples = variant_examples,
        .comparison_json = json,
        .exit_code = @intCast(@backingInt(code)),
    } };
}

fn writeScale(stdout: *Io.Writer, allocator: std.mem.Allocator, format: cli_args.Format, report: report_scale.Report, stderr: *Io.Writer) ExitCode {
    const written = switch (format) {
        .human => report_scale.writeHumanScale(stdout, allocator, report),
        .json => report_scale.writeJsonScale(stdout, allocator, report),
        .kv => return .usage,
    };
    written catch |err| return reportFailure(stderr, err);
    return .ok;
}

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    const steps = inputs.scale.steps();
    if (validateSteps(stderr, steps)) |code| return code;
    const plans = buildPlans(arena, inputs.seed, steps) catch return outOfMemory(stderr);
    if (validateScaled(stderr, plans)) |code| return code;

    const write_path = inputs.write_path;
    const select_path = write_path orelse inputs.select_path orelse return outOfMemory(stderr);
    var cleanup_failed = false;
    const option: []const u8 = if (write_path != null) "--write" else "--select";
    const select_sql = if (inputs.select_sql) |text| text else readSql(io, arena, stderr, option, select_path) orelse return .rejected;
    const index_sql = readSql(io, arena, stderr, "--index-sql", inputs.index_path) orelse return .rejected;
    var session = Session{
        .io = io,
        .arena = arena,
        .allocator = allocator,
        .inputs = inputs,
        .select_path = select_path,
        .select_sql = select_sql,
        .write_sql = if (write_path != null) select_sql else null,
        .index_sql = index_sql,
        .stderr = stderr,
        .cleanup_failed = &cleanup_failed,
    };

    const measured = arena.alloc(report_scale.Step, plans.len) catch return outOfMemory(stderr);
    var code: ExitCode = .ok;
    for (plans, 0..) |plan, index| {
        switch (runStep(&session, plan)) {
            .measured => |step| {
                measured[index] = step;
                code = heavier(code, stepExitCodeOf(step));
            },
            .failed => |failure| {
                if (isSignal(failure)) return cli_control.finalExitCode(failure, cleanup_failed);
                return cli_control.finalExitCode(heavier(code, failure), cleanup_failed);
            },
        }
    }

    const report = report_scale.Report{
        .header = baseHeader(&session),
        .seed_path = inputs.seed.path,
        .scale = steps,
        .steps = measured,
        .unapplied_migrations = inputs.unapplied_migrations,
        .exit_code = @intCast(@backingInt(code)),
    };
    const failure = writeScale(stdout, allocator, inputs.format, report, stderr);
    if (failure != .ok) return cli_control.finalExitCode(failure, cleanup_failed);
    return cli_control.finalExitCode(code, cleanup_failed);
}

fn stepExitCodeOf(step: report_scale.Step) ExitCode {
    return switch (step.result) {
        .match => .ok,
        .mismatch => .mismatch,
        .incomparable => .incomparable,
    };
}

test {
    _ = @import("scale_tests.zig");
}
