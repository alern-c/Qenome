const std = @import("std");
const Io = std.Io;
const db = @import("db.zig");
const result_rows = @import("result.zig");
const cli_d1_migrations = @import("d1/migrations.zig");

const cli_args = @import("cli/args.zig");
const cli_d1 = @import("cli/d1.zig");
const cli_control = @import("cli/control.zig");
const cli_comparison = @import("cli/comparison.zig");
const cli_query = @import("cli/query.zig");
const cli_workspace = @import("cli/workspace.zig");
const cli_timing = @import("cli/timing.zig");
const report_model = @import("report/model.zig");
const report_human = @import("report/human.zig");
const report_kv = @import("report/kv.zig");
const report_json = @import("report/json.zig");
const cli_pair = @import("cli/pair.zig");
const cli_batch = @import("cli/batch.zig");
const cli_audit = @import("cli/audit.zig");
const cli_rank = @import("cli/rank.zig");
const cli_record = @import("cli/record.zig");
const cli_seed = @import("cli/seed.zig");
const cli_scale = @import("cli/scale.zig");
const cli_skill = @import("cli/skill.zig");
const cli_sql_input = @import("cli/sql_input.zig");

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
pub const version = cli_args.version;
pub const ExitCode = cli_control.ExitCode;
pub const finalExitCode = cli_control.finalExitCode;

const tempParentPath = cli_workspace.tempParentPath;
pub const tempParent = cli_workspace.tempParent;
pub const home = cli_workspace.home;
const WorkDir = cli_workspace.WorkDir;
const prepareCopies = cli_workspace.prepareCopies;
const fileSize = cli_workspace.fileSize;
const measure = cli_query.measure;
const sqliteVersion = cli_query.sqliteVersion;
const sqliteSourceId = cli_query.sqliteSourceId;
const decide = cli_comparison.decide;
const timeRuns = cli_timing.timeRuns;
const judgeRows = cli_comparison.judgeRows;
const Header = report_model.Header;
const installSignalHandlers = cli_control.installSignalHandlers;
const clearSignals = cli_control.clearSignals;
const signalPending = cli_control.signalPending;
const reportInterrupted = cli_control.reportInterrupted;
const parseErrorMessage = cli_args.parseErrorMessage;
const fileErrorMessage = cli_args.fileErrorMessage;
const printVersion = cli_args.printVersion;

fn resultExitCode(outcome: cli_comparison.Outcome) ExitCode {
    return switch (outcome.verdict) {
        .match => .ok,
        .mismatch => .mismatch,
        .incomparable => .incomparable,
    };
}

pub const Context = struct {
    temp_parent: ?[]const u8 = null,
    home: ?[]const u8 = null,
    stdin: ?*Io.Reader = null,
};

pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    context: Context,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    const json_errors = argvRequestsJson(argv);
    var bridge: cli_control.JsonStderr = .init(stderr);
    const sink = if (json_errors) &bridge.writer else stderr;
    const code = runCaptured(io, allocator, argv, context, stdout, sink);
    if (json_errors) bridge.finish(code);
    return code;
}

fn argvRequestsJson(argv: []const [:0]const u8) bool {
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "skill")) return false;
    var wants = false;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--format=json")) {
            wants = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            const next = index + 1;
            if (next < argv.len and std.mem.eql(u8, argv[next], "json")) wants = true;
            index = next;
        }
    }
    return wants;
}

fn runCaptured(
    io: Io,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    context: Context,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    installSignalHandlers();
    defer clearSignals();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (argv.len > 1 and std.mem.eql(u8, argv[1], "skill")) {
        return cli_skill.run(io, arena, argv[2..], context.home, context.stdin, Io.Dir.cwd(), stdout, stderr);
    }

    const temp_parent = context.temp_parent;

    var offending: ?[:0]const u8 = null;
    const args = cli_args.parseArgsReporting(arena, argv, &offending) catch |err| {
        reportParseError(stderr, err, offending) catch {};
        return if (err == error.OutOfMemory) .rejected else .usage;
    };

    if (args.help) {
        usage(stdout) catch {};
        return .ok;
    }

    if (args.version) {
        printVersion(stdout) catch {};
        return .ok;
    }

    var missing_buffer: [cli_args.required_option_count][]const u8 = undefined;
    const missing = cli_args.missingRequired(args, &missing_buffer);
    if (missing.len != 0) {
        return missingArguments(stderr, args, missing);
    }

    if (args.record) |record_path| {
        return cli_record.run(io, arena, record_path, args.out.?, args.format, args.n_plus_one_threshold, stdout, stderr);
    }

    var d1: ?report_model.D1 = null;
    var unapplied: ?cli_d1_migrations.Pending = null;

    const database_path = if (args.d1) |binding| resolved: {
        const outcome = cli_d1.resolve(io, arena, Io.Dir.cwd(), binding, args.config) catch |err| {
            stderr.print("error: {s}\n", .{fileErrorMessage(err)}) catch {};
            return .rejected;
        };
        switch (outcome) {
            .resolved => |resolution| {
                d1 = reportD1(resolution);
                unapplied = cli_d1_migrations.find(io, arena, resolution.config_path, resolution.migrations_dir, resolution.migrations_table, resolution.local_path, resolution.binding);
                break :resolved arena.dupeSentinel(u8, resolution.local_path, 0) catch {
                    stderr.print("error: out of memory\n", .{}) catch {};
                    return .rejected;
                };
            },
            .failure => |failure| {
                reportD1Failure(stderr, failure) catch {};
                return .incomparable;
            },
        }
    } else args.db.?;

    var seed_spec: ?cli_seed.Spec = null;
    var seed_report: ?report_model.Seed = null;
    if (args.seed_data) |seed_path| {
        seed_spec = cli_seed.load(io, arena, seed_path, stderr) orelse return .rejected;
        seed_report = buildSeedReport(arena, seed_spec.?) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return .rejected;
        };
    }

    if (args.scale) |scale| {
        const spec = seed_spec orelse {
            stderr.writeAll("error: --scale needs --seed-data (see --help)\n") catch {};
            return .usage;
        };
        const scale_query = if (args.write == null) cli_sql_input.loadSelect(io, arena, context.stdin, args.sql, args.select, stderr) else null;
        if (args.write == null and scale_query == null) return .rejected;
        return cli_scale.run(io, arena, allocator, .{
            .database_path = database_path,
            .d1 = d1,
            .unapplied_migrations = unapplied,
            .select_path = if (scale_query) |query| query.label else null,
            .select_sql = if (scale_query) |query| query.sql else null,
            .write_path = args.write,
            .index_path = args.index_sql.?,
            .binds = args.binds,
            .timeout_ms = args.timeout_ms,
            .runs = args.runs,
            .format = args.format,
            .show_binds = args.show_binds,
            .show_rows = args.show_rows,
            .temp_parent = tempParentPath(temp_parent),
            .seed = spec,
            .scale = scale,
        }, stdout, stderr);
    }

    if (args.batch) |batch_path| {
        var cleanup_failed = false;
        const code = blk: {
            var migration: ?cli_batch.Migration = null;
            if (args.migration) |migration_path| {
                const migration_sql = readSqlFile(io, arena, migration_path) catch |err| {
                    reportSqlFileError(stderr, "--migration", migration_path, err) catch {};
                    break :blk ExitCode.rejected;
                };
                migration = .{ .path = migration_path, .sql = migration_sql, .statements = &.{} };
            }
            const loaded = cli_batch.load(io, arena, batch_path, stderr, .{
                .suggest = args.suggest,
                .migration = args.migration != null,
                .audit = args.audit_indexes,
                .rank = args.rank,
            }) orelse break :blk ExitCode.rejected;
            if (signalPending()) break :blk reportInterrupted(stderr);
            const parent_path = tempParentPath(temp_parent);
            var work = WorkDir.create(io, arena, parent_path) catch |err| {
                stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ parent_path, fileErrorMessage(err) }) catch {};
                break :blk ExitCode.rejected;
            };
            defer work.remove(io, stderr, &cleanup_failed);
            if (prepareCopies(io, arena, database_path, &work, seed_spec, !args.audit_indexes and !args.rank, stderr, &cleanup_failed)) |failure| break :blk failure;
            if (args.rank) {
                break :blk cli_rank.run(io, arena, allocator, .{
                    .database_path = database_path,
                    .baseline_path = work.baseline_path,
                    .unapplied_migrations = unapplied,
                    .timeout_ms = args.timeout_ms,
                    .format = args.format,
                    .work_parent = parent_path,
                    .seed_path = if (seed_report) |seed| seed.path else null,
                }, loaded.queries, stdout, stderr, &cleanup_failed);
            }
            if (args.audit_indexes) {
                break :blk cli_audit.run(io, arena, allocator, .{
                    .database_path = database_path,
                    .baseline_path = work.baseline_path,
                    .unapplied_migrations = unapplied,
                    .timeout_ms = args.timeout_ms,
                    .format = args.format,
                    .work_parent = parent_path,
                }, loaded.queries, stdout, stderr, &cleanup_failed);
            }
            break :blk cli_batch.run(io, arena, allocator, .{
                .database_path = database_path,
                .baseline_path = work.baseline_path,
                .variant_path = work.variant_path,
                .d1 = d1,
                .unapplied_migrations = unapplied,
                .migration = migration,
                .timeout_ms = args.timeout_ms,
                .show_binds = args.show_binds,
                .show_rows = args.show_rows,
                .format = args.format,
                .suggest = args.suggest,
                .seed = seed_report,
                .work_parent = parent_path,
            }, loaded, stdout, stderr, &cleanup_failed, &work);
        };
        return finalExitCode(code, cleanup_failed);
    }

    if (args.suggest) {
        const suggest_query = cli_sql_input.loadSelect(io, arena, context.stdin, args.sql, args.select, stderr) orelse return .rejected;
        if (signalPending()) return reportInterrupted(stderr);

        const suggest_parent_path = tempParentPath(temp_parent);
        var suggest_work = WorkDir.create(io, arena, suggest_parent_path) catch |err| {
            stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ suggest_parent_path, fileErrorMessage(err) }) catch {};
            return .rejected;
        };

        var suggest_cleanup_failed = false;
        const suggest_code = blk: {
            defer suggest_work.remove(io, stderr, &suggest_cleanup_failed);
            if (prepareCopies(io, arena, database_path, &suggest_work, seed_spec, true, stderr, &suggest_cleanup_failed)) |failure| break :blk failure;
            var queries = [_]cli_batch.Query{.{
                .label = suggest_query.label,
                .path = suggest_query.label,
                .sql = suggest_query.sql,
                .binds = args.binds,
            }};
            break :blk cli_batch.run(io, arena, allocator, .{
                .database_path = database_path,
                .baseline_path = suggest_work.baseline_path,
                .variant_path = suggest_work.variant_path,
                .d1 = d1,
                .unapplied_migrations = unapplied,
                .timeout_ms = args.timeout_ms,
                .show_binds = args.show_binds,
                .show_rows = args.show_rows,
                .format = args.format,
                .suggest = true,
                .manifest = false,
                .seed = seed_report,
                .work_parent = suggest_parent_path,
            }, .{ .queries = &queries, .candidates = &.{} }, stdout, stderr, &suggest_cleanup_failed, &suggest_work);
        };
        return finalExitCode(suggest_code, suggest_cleanup_failed);
    }

    const write_path = args.write;
    const index_path = args.index_sql.?;
    const loaded_select = if (write_path == null) cli_sql_input.loadSelect(io, arena, context.stdin, args.sql, args.select, stderr) else null;
    if (write_path == null and loaded_select == null) return .rejected;
    const select_path = if (loaded_select) |query| query.label else write_path.?;
    const select_sql = if (loaded_select) |query| query.sql else readSqlFile(io, arena, write_path.?) catch |err| {
        reportSqlFileError(stderr, "--write", write_path.?, err) catch {};
        return .rejected;
    };
    const index_sql = readSqlFile(io, arena, index_path) catch |err| {
        reportSqlFileError(stderr, "--index-sql", index_path, err) catch {};
        return .rejected;
    };

    if (signalPending()) return reportInterrupted(stderr);

    const parent_path = tempParentPath(temp_parent);
    var work = WorkDir.create(io, arena, parent_path) catch |err| {
        stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ parent_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };

    var cleanup_failed = false;
    const code = blk: {
        defer work.remove(io, stderr, &cleanup_failed);

        if (prepareCopies(io, arena, database_path, &work, seed_spec, true, stderr, &cleanup_failed)) |failure| break :blk failure;

        const inputs: Inputs = .{
            .database_path = database_path,
            .d1 = d1,
            .unapplied_migrations = unapplied,
            .baseline_path = work.baseline_path,
            .variant_path = work.variant_path,
            .select_path = select_path,
            .index_path = index_path,
            .select_sql = select_sql,
            .write_path = write_path,
            .write_sql = if (write_path != null) select_sql else null,
            .index_sql = index_sql,
            .binds = args.binds,
            .timeout_ms = args.timeout_ms,
            .runs = args.runs,
            .work_parent = parent_path,
            .show_binds = args.show_binds,
            .show_rows = args.show_rows,
            .format = args.format,
            .seed = seed_report,
        };
        break :blk runChecked(io, arena, allocator, inputs, stdout, stderr, &cleanup_failed, &work);
    };
    return finalExitCode(code, cleanup_failed);
}

const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    d1: ?report_model.D1 = null,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    write_path: ?[:0]const u8 = null,
    write_sql: ?[:0]const u8 = null,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
    runs: u32,
    work_parent: []const u8,
    show_binds: bool = false,
    show_rows: bool = false,
    format: cli_args.Format = .human,
    seed: ?report_model.Seed = null,
    progress_interval_ns: u64 = std.time.ns_per_s,
};

fn buildSeedReport(arena: std.mem.Allocator, spec: cli_seed.Spec) !report_model.Seed {
    const tables = try arena.alloc(report_model.SeedTable, spec.tables.len);
    var total: u64 = 0;
    for (spec.tables, 0..) |table, index| {
        tables[index] = .{ .table = table.name, .rows = table.rows };
        total += table.rows;
    }
    return .{ .path = spec.path, .seed = spec.seed, .rows = total, .tables = tables };
}

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
    var rows: cli_pair.RowBuffers = undefined;
    rows.init(allocator);
    defer rows.deinit();
    const computed = switch (cli_pair.compute(io, arena, .{
        .database_path = inputs.database_path,
        .baseline_path = inputs.baseline_path,
        .variant_path = inputs.variant_path,
        .d1 = inputs.d1,
        .unapplied_migrations = inputs.unapplied_migrations,
        .select_path = inputs.select_path,
        .index_path = inputs.index_path,
        .select_sql = inputs.select_sql,
        .write_sql = inputs.write_sql,
        .index_sql = inputs.index_sql,
        .binds = inputs.binds,
        .timeout_ms = inputs.timeout_ms,
        .runs = inputs.runs,
        .work_parent = inputs.work_parent,
        .show_binds = inputs.show_binds,
        .show_rows = inputs.show_rows,
        .progress_interval_ns = inputs.progress_interval_ns,
    }, &rows, stderr, cleanup_failed, work)) {
        .computed => |value| value,
        .failed => |code| return code,
    };

    const code = resultExitCode(computed.outcome);
    const header: Header = .{
        .database_path = inputs.database_path,
        .select_path = inputs.select_path,
        .write_path = inputs.write_path,
        .index_path = inputs.index_path,
        .work_parent = inputs.work_parent,
        .sqlite_version = sqliteVersion(),
        .sqlite_source_id = sqliteSourceId(),
        .qenome_version = version,
        .binds = inputs.binds,
        .show_binds = inputs.show_binds,
        .show_rows = inputs.show_rows,
        .exit_code = @backingInt(code),
        .d1 = inputs.d1,
        .seed = inputs.seed,
    };
    writeReport(stdout, arena, inputs.format, header, computed.before, computed.after, computed.outcome, computed.report) catch |err| {
        switch (err) {
            error.OutOfMemory => stderr.print("error: out of memory\n", .{}) catch {},
            else => stderr.print("error: the summary could not be written\n", .{}) catch {},
        }
        return .rejected;
    };
    return code;
}

fn writeReport(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    format: cli_args.Format,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: report_model.Report,
) report_model.Error!void {
    switch (format) {
        .human => try report_human.writeHumanSummary(stdout, allocator, header, before, after, outcome, report),
        .kv => try report_kv.writeSummary(stdout, allocator, header, before, after, outcome, report),
        .json => try report_json.writeJsonReport(stdout, allocator, header, before, after, outcome, report),
    }
}

fn reportD1(resolution: cli_d1.Resolved) report_model.D1 {
    return .{
        .binding = resolution.binding,
        .config_path = resolution.config_path,
        .database_id = resolution.database_id,
        .local_path = resolution.local_path,
        .sqlite_version = cli_d1.local_engine_sqlite_version,
    };
}

fn reportD1Failure(stderr: *Io.Writer, failure: cli_d1.Failure) Io.Writer.Error!void {
    const binding = failure.binding;
    switch (failure.kind) {
        .config_not_found => try stderr.print(
            "error: --d1 {s}: no wrangler config in the current directory (expected {s}, {s} or {s}); pass --config <PATH>, or run qenome in the wrangler project\n",
            .{ binding, cli_d1.config_names[0], cli_d1.config_names[1], cli_d1.config_names[2] },
        ),
        .config_ambiguous => try stderr.print(
            "error: --d1 {s}: more than one wrangler config in the current directory ({s}); pass --config <PATH> to choose one\n",
            .{ binding, failure.detail },
        ),
        .config_unreadable => try stderr.print(
            "error: --d1 {s}: cannot read the wrangler config '{s}': {s}\n",
            .{ binding, failure.config_path, fileErrorMessage(failure.other orelse error.Unexpected) },
        ),
        .config_unsupported => try stderr.print(
            "error: --d1 {s}: --config '{s}' must name a .toml, .jsonc or .json file\n",
            .{ binding, failure.config_path },
        ),
        .config_invalid => try stderr.print(
            "error: --d1 {s}: cannot use the wrangler config '{s}': {s}\n",
            .{ binding, failure.config_path, failure.detail },
        ),
        .binding_not_found => try stderr.print(
            "error: --d1 {s}: no top-level d1_databases binding named '{s}' in '{s}' ({s})\n",
            .{ binding, failure.binding, failure.config_path, failure.detail },
        ),
        .binding_ambiguous => try stderr.print(
            "error: --d1 {s}: '{s}' has more than one d1_databases binding named '{s}' ({s}); keep one so that the local database is unambiguous\n",
            .{ binding, failure.config_path, failure.binding, failure.detail },
        ),
        .database_id_missing => try stderr.print(
            "error: --d1 {s}: the binding in '{s}' has no database_id and no preview_database_id, so its local database cannot be found\n",
            .{ binding, failure.config_path },
        ),
        .local_file_missing => try stderr.print(
            "error: --d1 {s}: no local D1 database at '{s}'; create it first with a local wrangler command in '{s}', for example npx wrangler d1 execute {s} --local --command \"SELECT 1\" (or npx wrangler dev and use the database once)\n",
            .{ binding, failure.local_path, std.fs.path.dirname(failure.config_path) orelse ".", binding },
        ),
        .local_file_unreadable => try stderr.print(
            "error: --d1 {s}: cannot open the local D1 database '{s}': {s}\n",
            .{ binding, failure.local_path, fileErrorMessage(failure.other orelse error.Unexpected) },
        ),
    }
}

fn reportSqlFileError(stderr: *Io.Writer, option: []const u8, path: []const u8, err: anyerror) Io.Writer.Error!void {
    try stderr.print("error: cannot read {s} file '{s}': {s}", .{ option, path, fileErrorMessage(err) });
    if (cli_args.looksLikeSql(path)) {
        try stderr.print("; {s} takes a path to a file holding the SQL, not the SQL text", .{option});
    }
    try stderr.writeAll("\n");
}

fn reportParseError(stderr: *Io.Writer, err: ParseError, offending: ?[:0]const u8) Io.Writer.Error!void {
    const arg = offending orelse return stderr.print("error: {s}\n", .{parseErrorMessage(err)});
    switch (err) {
        error.UnknownOption => {
            try stderr.writeAll("error: unknown option ");
            try result_rows.writeText(stderr, arg);
            if (cli_args.suggestOptionName(arg)) |suggestion| {
                try stderr.writeAll("; did you mean '");
                try stderr.writeAll(suggestion);
                try stderr.writeAll("'?");
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
        error.TooManyPaths => {
            try stderr.writeAll("error: unexpected argument ");
            try result_rows.writeText(stderr, arg);
            try stderr.writeAll("; paths are the database, the SELECT file and the CREATE INDEX file, at most 3 (see --help)\n");
        },
        error.TooManyD1Paths => {
            try stderr.writeAll("error: unexpected argument ");
            try result_rows.writeText(stderr, arg);
            try stderr.writeAll("; with --d1 the paths are the SELECT file and the CREATE INDEX file, at most 2 (see --help)\n");
        },
        error.RecordTakesNoPaths => {
            try stderr.writeAll("error: --record takes no database or SQL path: ");
            try result_rows.writeText(stderr, arg);
            try stderr.writeAll(" (see --help)\n");
        },
        error.RecordConflict => {
            try stderr.print("error: --record does not take {s} (see --help)\n", .{arg});
        },
        error.OutRequiresRecord => {
            try stderr.writeAll("error: --out is only used with --record (see --help)\n");
        },
        error.RecordRejectsFormat => {
            try stderr.writeAll("error: --record supports --format human or json, not kv (see --help)\n");
        },
        error.ThresholdRequiresRecord => {
            try stderr.writeAll("error: --n-plus-one-threshold is only used with --record (see --help)\n");
        },
        error.EmptyPath => try stderr.writeAll("error: a path cannot be empty (see --help)\n"),
        error.UnexpectedValue => {
            const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            try stderr.print("error: {s} does not take a value (see --help)\n", .{arg[0..end]});
        },
        error.BatchTakesOnlyDatabasePath => {
            try stderr.writeAll("error: --batch takes only the database path; put the SELECT and CREATE INDEX files in the manifest (see --help)\n");
        },
        error.BatchRejectsBind => try stderr.writeAll("error: --batch does not take --bind; put the binds in the manifest (see --help)\n"),
        error.BatchRejectsRuns => try stderr.writeAll("error: --batch does not run the timing; remove --runs (see --help)\n"),
        error.BatchRejectsKv => try stderr.writeAll("error: --batch supports --format human or --format json, not kv (see --help)\n"),
        error.ScaleConflict => try stderr.print("error: --scale does not take {s} (see --help)\n", .{arg}),
        error.AuditConflict => {
            if (std.mem.eql(u8, arg, "--batch")) {
                try stderr.writeAll("error: --audit-indexes needs --batch and a manifest (see --help)\n");
            } else {
                try stderr.print("error: --audit-indexes does not take {s} (see --help)\n", .{arg});
            }
        },
        else => try stderr.print("error: {s}\n", .{parseErrorMessage(err)}),
    }
}

fn missingArguments(stderr: *Io.Writer, args: cli_args.Args, missing: []const []const u8) ExitCode {
    if (args.record != null) {
        stderr.print("{s}\n", .{cli_args.record_usage_line}) catch {};
    } else if (args.batch != null) {
        const line: []const u8 = if (args.rank)
            (if (args.d1 != null) cli_args.d1_rank_usage_line else cli_args.rank_usage_line)
        else if (args.audit_indexes)
            (if (args.d1 != null) cli_args.d1_audit_usage_line else cli_args.audit_usage_line)
        else if (args.d1 != null)
            cli_args.d1_batch_usage_line
        else
            cli_args.batch_usage_line;
        stderr.print("{s}\n", .{line}) catch {};
    } else if (missing.len == cli_args.required_option_count) {
        stderr.print("{s}\n{s}\n", .{ cli_args.usage_line, cli_args.d1_usage_line }) catch {};
    }
    stderr.writeAll("error: missing: ") catch {};
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

    var buffer: [32768]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try usage(&writer);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "usage: qenome"));
    try testing.expectEqual(ExitCode.cleanup, finalExitCode(.ok, true));

    const read_file: *const fn (Io, std.mem.Allocator, []const u8) (SqlFileError || Io.Dir.ReadFileAllocError)![:0]u8 = readSqlFile;
    const parse_args: *const fn (std.mem.Allocator, []const [:0]const u8) ParseError!Args = parseArgs;
    const print_usage: *const fn (*Io.Writer) Io.Writer.Error!void = usage;
    const run_cli: *const fn (Io, std.mem.Allocator, []const [:0]const u8, Context, *Io.Writer, *Io.Writer) ExitCode = run;
    const final_code: *const fn (ExitCode, bool) ExitCode = finalExitCode;
    _ = read_file;
    _ = parse_args;
    _ = print_usage;
    _ = run_cli;
    _ = final_code;
}
