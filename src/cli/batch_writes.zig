const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const result_rows = @import("../result.zig");
const cli_args = @import("args.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_pair = @import("pair.zig");
const cli_query = @import("query.zig");
const cli_write_runner = @import("write_runner.zig");
const report_model = @import("../report/model.zig");
const report_json = @import("../report/json.zig");
const report_batch_writes = @import("../report/batch_writes.zig");

const ExitCode = cli_control.ExitCode;

pub const max_writes = 100;

pub const Write = struct {
    label: []const u8,
    path: [:0]const u8,
    sql: [:0]const u8,
    binds: []const db.BindArg,
};

pub const Context = struct {
    database_path: []const u8,
    work_parent: []const u8,
    d1: ?report_model.D1 = null,
    show_binds: bool = false,
    show_rows: bool = false,
    baseline_size: u64 = 0,
    variant_size: u64 = 0,
};

pub const Outcome = union(enum) {
    done,
    failed: ExitCode,
};

pub const Severity = struct {
    mismatch: bool = false,
    incomparable: bool = false,
    timeout: bool = false,
    regression: bool = false,
};

pub fn severity(writes: []const report_batch_writes.Result) Severity {
    var found: Severity = .{};
    for (writes) |entry| {
        switch (entry.status) {
            .variant_timeout => found.timeout = true,
            .compared => switch (entry.outcome orelse .match) {
                .mismatch => found.mismatch = true,
                .incomparable => found.incomparable = true,
                .match => {},
            },
        }
        if (entry.baseline_missing) continue;
        if (entry.judgement == .regressed) found.regression = true;
    }
    return found;
}

pub fn blocksRecommendation(writes: []const report_batch_writes.Result) bool {
    for (writes) |entry| {
        if (entry.status != .compared) return true;
        if (entry.baseline_missing) continue;
        if ((entry.outcome orelse .match) != .match) return true;
        if (entry.judgement == .regressed) return true;
    }
    return false;
}

pub fn loadManifest(
    io: Io,
    arena: std.mem.Allocator,
    root: std.json.ObjectMap,
    manifest_dir: []const u8,
    path: []const u8,
    migration: bool,
    stderr: *Io.Writer,
) ?[]const Write {
    const value = root.get("writes") orelse return &.{};
    if (!migration) {
        return invalid(stderr, path, "the writes key needs --migration; remove it or add --migration", .{});
    }
    const values = switch (value) {
        .array => |array| array.items,
        else => return invalid(stderr, path, "writes must be an array", .{}),
    };
    if (values.len < 1 or values.len > max_writes) {
        return invalid(stderr, path, "writes must hold 1 to {d} entries", .{max_writes});
    }

    var writes: std.ArrayList(Write) = .empty;
    for (values, 0..) |write_value, index| {
        const object = switch (write_value) {
            .object => |object| object,
            else => return invalid(stderr, path, "write {d} must be an object", .{index + 1}),
        };
        if (object.get("write") == null or object.count() < 1 or object.count() > 2) {
            return invalid(stderr, path, "write {d} must have write and optional binds", .{index + 1});
        }
        var keys = object.iterator();
        while (keys.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "write") and !std.mem.eql(u8, entry.key_ptr.*, "binds")) {
                return invalid(stderr, path, "write {d} must have write and optional binds", .{index + 1});
            }
        }
        const label = switch (object.get("write").?) {
            .string => |text| text,
            else => return invalid(stderr, path, "write {d} write must be a string", .{index + 1}),
        };
        if (label.len == 0 or std.mem.indexOfScalar(u8, label, 0) != null) {
            return invalid(stderr, path, "write {d} write must be a non-empty path", .{index + 1});
        }
        for (writes.items) |existing| {
            if (std.mem.eql(u8, existing.label, label)) {
                return invalid(stderr, path, "the write path '{s}' appears more than once", .{label});
            }
        }

        var binds: std.ArrayList(db.BindArg) = .empty;
        if (object.get("binds")) |binds_value| {
            const bind_values = switch (binds_value) {
                .array => |array| array.items,
                else => return invalid(stderr, path, "write {d} binds must be an array", .{index + 1}),
            };
            for (bind_values, 0..) |bind_value, bind_index| {
                const text = switch (bind_value) {
                    .string => |text| text,
                    else => return invalid(stderr, path, "write {d} bind {d} must be a string", .{ index + 1, bind_index + 1 }),
                };
                if (std.mem.indexOfScalar(u8, text, 0) != null) {
                    return invalid(stderr, path, "write {d} bind {d} contains a NUL byte", .{ index + 1, bind_index + 1 });
                }
                const raw = arena.dupeSentinel(u8, text, 0) catch return outOfMemory(stderr);
                const bind = cli_args.parseBind(raw) catch |err| {
                    return invalid(stderr, path, "write {d} bind {d}: {s}", .{ index + 1, bind_index + 1, cli_args.parseErrorMessage(err) });
                };
                binds.append(arena, bind) catch return outOfMemory(stderr);
            }
        }

        const resolved = resolvePath(arena, manifest_dir, label) orelse return outOfMemory(stderr);
        writes.append(arena, .{ .label = label, .path = resolved, .sql = undefined, .binds = binds.items }) catch return outOfMemory(stderr);
    }

    for (writes.items) |*write| {
        write.sql = readSqlFile(io, arena, write.path, write.label, stderr) orelse return null;
    }
    return writes.items;
}

fn invalid(stderr: *Io.Writer, path: []const u8, comptime format: []const u8, args: anytype) ?[]const Write {
    stderr.print("error: the batch manifest '{s}' is not valid: ", .{path}) catch {};
    stderr.print(format, args) catch {};
    stderr.writeByte('\n') catch {};
    return null;
}

fn outOfMemory(stderr: *Io.Writer) ?[]const Write {
    stderr.writeAll("error: out of memory\n") catch {};
    return null;
}

fn resolvePath(arena: std.mem.Allocator, manifest_dir: []const u8, value: []const u8) ?[:0]const u8 {
    const resolved = std.fs.path.resolveAlloc(arena, &.{ manifest_dir, value }) catch return null;
    return arena.dupeSentinel(u8, resolved, 0) catch null;
}

fn readSqlFile(io: Io, arena: std.mem.Allocator, path: [:0]const u8, label: []const u8, stderr: *Io.Writer) ?[:0]const u8 {
    return cli_args.readSqlFile(io, arena, path) catch |err| {
        stderr.print("error: cannot read the batch SQL file '{s}' for the batch write '{s}': {s}\n", .{ path, label, cli_args.fileErrorMessage(err) }) catch {};
        return null;
    };
}

const Session = struct {
    runner: cli_write_runner.Runner = .{},
    side: cli_comparison.Side,

    fn open(self: *Session, path: [:0]const u8, stderr: *Io.Writer, failure: *ExitCode) bool {
        self.runner.open(path) catch |err| {
            stderr.print("error: cannot open the {t} '{s}' for writing: {s}\n", .{ self.side, path, cli_query.openErrorMessage(err) }) catch {};
            failure.* = .rejected;
            return false;
        };
        return true;
    }

    fn prepare(self: *Session, write: *const Write, stderr: *Io.Writer, failure: *ExitCode) bool {
        self.runner.prepare(write.sql) catch |err| {
            stderr.print("error: the batch write '{s}': the {t} cannot prepare the write: {s}\n", .{ write.label, self.side, checkDetail(err, &self.runner.database) }) catch {};
            failure.* = .rejected;
            return false;
        };
        self.runner.bind(write.binds) catch |err| {
            stderr.print("error: the batch write '{s}': the {t} cannot bind its values: {s} (parameters in the write: {d}; values given: {d})\n", .{
                write.label, self.side, cli_query.bindErrorMessage(err), self.runner.bindParameterCount(), write.binds.len,
            }) catch {};
            failure.* = .rejected;
            return false;
        };
        return true;
    }

    fn prepareReason(self: *Session, write: *const Write, arena: std.mem.Allocator, reason: *[]const u8) bool {
        self.runner.prepare(write.sql) catch |err| {
            reason.* = truncate(arena, checkDetail(err, &self.runner.database));
            return false;
        };
        self.runner.bind(write.binds) catch |err| {
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{s} (parameters in the write: {d}; values given: {d})", .{
                cli_query.bindErrorMessage(err), self.runner.bindParameterCount(), write.binds.len,
            }) catch "the binds do not fit the write";
            reason.* = truncate(arena, text);
            return false;
        };
        return true;
    }

    fn plan(
        self: *Session,
        arena: std.mem.Allocator,
        write: *const Write,
        control: *db.StepControl,
        stderr: *Io.Writer,
        failure: *ExitCode,
    ) ?db.Plan {
        return self.runner.plan(arena, write.sql, write.binds, control) catch |err| {
            switch (err) {
                error.Timeout => {
                    stderr.print("error: the batch write '{s}' exceeded the time limit of {d} ms while reading the plan on the {t}\n", .{ write.label, control.timeout_ms, self.side }) catch {};
                    failure.* = .timeout;
                },
                error.Interrupted => failure.* = cli_control.reportInterrupted(stderr),
                error.OutOfMemory => {
                    stderr.writeAll("error: out of memory\n") catch {};
                    failure.* = .rejected;
                },
                else => {
                    const detail = if (err == error.ExplainFailed and self.runner.errorCode() != sqlite.SQLITE_OK)
                        self.runner.message()
                    else
                        @errorName(err);
                    stderr.print("error: the batch write '{s}': the query plan could not be read on the {t}: {s}\n", .{ write.label, self.side, detail }) catch {};
                    failure.* = .rejected;
                },
            }
            return null;
        };
    }

    fn execute(
        self: *Session,
        write: *const Write,
        control: *db.StepControl,
        rows_out: ?*result_rows.RowCollector,
        stderr: *Io.Writer,
        failure: *ExitCode,
    ) RunOutcome {
        const execution = self.runner.execute(control, rows_out) catch |err| return switch (err) {
            error.Timeout => blk: {
                stderr.print("error: the batch write '{s}' exceeded the time limit of {d} ms on the {t}\n", .{ write.label, control.timeout_ms, self.side }) catch {};
                break :blk .timeout;
            },
            error.Interrupted => blk: {
                failure.* = cli_control.reportInterrupted(stderr);
                break :blk .{ .failed = failure.* };
            },
            error.StepFailed => blk: {
                stderr.print("error: the batch write '{s}' failed on the {t}: {s}\n", .{ write.label, self.side, self.runner.message() }) catch {};
                failure.* = .rejected;
                break :blk .{ .failed = failure.* };
            },
        };
        return .{ .measured = execution };
    }

    fn deinit(self: *Session, stderr: *Io.Writer, cleanup_failed: *bool) void {
        self.runner.finalize();
        if (!self.runner.opened) return;
        self.runner.close() catch {
            cleanup_failed.* = true;
            stderr.print("error: the database connection of the {t} could not be closed: {s}\n", .{ self.side, self.runner.message() }) catch {};
            return;
        };
    }
};

const RunOutcome = union(enum) {
    measured: cli_write_runner.Execution,
    timeout,
    failed: ExitCode,
};

fn checkDetail(err: db.CheckError, database: *const db.Db) []const u8 {
    if (database.errorCode() != sqlite.SQLITE_OK) return database.message();
    return cli_query.checkErrorMessage(err);
}

fn truncate(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var buffer: [512]u8 = undefined;
    const length = cli_control.copyUtf8(&buffer, text);
    return arena.dupe(u8, buffer[0..length]) catch "";
}

fn measurement(plan: db.Plan, execution: cli_write_runner.Execution, columns: c_int) cli_comparison.Measurement {
    return .{
        .rows = execution.rows,
        .plan = plan,
        .counters = execution.counters,
        .columns = columns,
        .changes = execution.changes,
        .total_changes = execution.total_changes,
        .executions = 1,
    };
}

fn skippedMeasurement(plan: db.Plan, columns: c_int) cli_comparison.Measurement {
    return .{
        .rows = 0,
        .plan = plan,
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 0, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = columns,
    };
}

pub fn compare(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    writes: []const Write,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    candidate: []const u8,
    context: Context,
    control: *db.StepControl,
    results: *std.ArrayList(report_batch_writes.Result),
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) Outcome {
    var failure: ExitCode = .rejected;
    var baseline: Session = .{ .side = .baseline };
    if (!baseline.open(baseline_path, stderr, &failure)) return .{ .failed = failure };
    defer baseline.deinit(stderr, cleanup_failed);

    var variant: Session = .{ .side = .variant };
    if (!variant.open(variant_path, stderr, &failure)) return .{ .failed = failure };
    defer variant.deinit(stderr, cleanup_failed);

    for (writes) |*write| {
        if (cli_control.signalPending()) return .{ .failed = cli_control.reportInterrupted(stderr) };

        var child_state = std.heap.ArenaAllocator.init(allocator);
        defer child_state.deinit();
        const child = child_state.allocator();

        var rows: cli_pair.RowBuffers = undefined;
        rows.init(child);
        defer rows.deinit();

        var entry: report_batch_writes.Result = .{
            .write = write.label,
            .candidate = candidate,
            .status = .compared,
        };

        var reason: []const u8 = "";
        if (!baseline.prepareReason(write, arena, &reason)) {
            switch (compareVariantOnly(child, arena, &variant, write, candidate, context, control, &rows, &entry, reason, stderr, &failure)) {
                .done => {},
                .failed => |code| return .{ .failed = code },
            }
            results.append(arena, entry) catch return .{ .failed = outOfMemoryCode(stderr) };
            continue;
        }
        if (!variant.prepare(write, stderr, &failure)) return .{ .failed = failure };

        const before_plan = baseline.plan(arena, write, control, stderr, &failure) orelse return .{ .failed = failure };
        const after_plan = variant.plan(arena, write, control, stderr, &failure) orelse return .{ .failed = failure };

        const sizes: report_model.Sizes = .{ .baseline = context.baseline_size, .variant = context.variant_size };
        const clues = db.Clues.merge(baseline.runner.clues(), variant.runner.clues());
        if (cli_comparison.writeIncomparable(arena, clues)) |outcome| {
            var report: report_model.Report = .{ .judgement = .{ .verdict = .not_judged }, .sizes = sizes };
            report.judgement.add("the write was not run, so the row counts are not judged");
            entry.ran = false;
            switch (renderComparison(child, &entry, write, candidate, context, skippedMeasurement(before_plan, baseline.runner.columnCount()), skippedMeasurement(after_plan, variant.runner.columnCount()), outcome, report, &variant, control, arena, stderr)) {
                .done => {},
                .failed => |code| return .{ .failed = code },
            }
            results.append(arena, entry) catch return .{ .failed = outOfMemoryCode(stderr) };
            continue;
        }

        const before_execution = switch (baseline.execute(write, control, &rows.baseline, stderr, &failure)) {
            .measured => |execution| execution,
            .timeout => return .{ .failed = .timeout },
            .failed => |code| return .{ .failed = code },
        };
        const after_execution = switch (variant.execute(write, control, &rows.variant, stderr, &failure)) {
            .measured => |execution| execution,
            .timeout => {
                entry.status = .variant_timeout;
                results.append(arena, entry) catch return .{ .failed = outOfMemoryCode(stderr) };
                continue;
            },
            .failed => |code| return .{ .failed = code },
        };

        const before = measurement(before_plan, before_execution, baseline.runner.columnCount());
        const after = measurement(after_plan, after_execution, variant.runner.columnCount());
        var outcome = cli_comparison.decide(arena, before, after, &rows.baseline, &rows.variant, .{
            .clues = .{},
            .limit_or_offset = false,
        });
        const changes_mismatch = before.changes != after.changes or before.total_changes != after.total_changes;
        if (changes_mismatch) outcome.verdict = .mismatch;

        var report: report_model.Report = .{ .judgement = .{ .verdict = .not_judged }, .sizes = sizes, .write_runs = 1 };
        if (changes_mismatch) {
            report.judgement = cli_comparison.writeChangesMismatch();
        } else if (outcome.verdict == .mismatch) {
            report.judgement.add("the RETURNING rows do not match, so the row counts are not judged");
        } else if (outcome.verdict == .incomparable) {
            report.judgement.add("the result rows cannot be compared, so the row counts are not judged");
        } else {
            report.judgement = cli_comparison.judgeMigrationWrite(before, after);
        }
        switch (renderComparison(child, &entry, write, candidate, context, before, after, outcome, report, &variant, control, arena, stderr)) {
            .done => {},
            .failed => |code| return .{ .failed = code },
        }
        entry.rows_read = .{ .baseline = before.counters.rows_read, .variant = after.counters.rows_read };
        entry.rows_written = .{ .baseline = before.counters.rows_written, .variant = after.counters.rows_written };
        results.append(arena, entry) catch return .{ .failed = outOfMemoryCode(stderr) };
    }
    return .done;
}

const Render = union(enum) {
    done,
    failed: ExitCode,
};

fn compareVariantOnly(
    child: std.mem.Allocator,
    arena: std.mem.Allocator,
    variant: *Session,
    write: *const Write,
    candidate: []const u8,
    context: Context,
    control: *db.StepControl,
    rows: *cli_pair.RowBuffers,
    entry: *report_batch_writes.Result,
    reason: []const u8,
    stderr: *Io.Writer,
    failure: *ExitCode,
) Render {
    if (!variant.prepare(write, stderr, failure)) return .{ .failed = failure.* };
    const after_plan = variant.plan(child, write, control, stderr, failure) orelse return .{ .failed = failure.* };

    const baseline_text = std.fmt.allocPrint(child, "the baseline cannot run this write before the migration: {s}", .{reason}) catch return .{ .failed = outOfMemoryCode(stderr) };
    var report: report_model.Report = .{ .judgement = .{ .verdict = .not_judged }, .sizes = .{ .baseline = context.baseline_size, .variant = context.variant_size } };
    report.judgement.add(baseline_text);
    var entry_reason = baseline_text;
    var after = skippedMeasurement(after_plan, variant.runner.columnCount());
    if (cli_comparison.writeIncomparable(arena, variant.runner.clues())) |outcome| {
        for (outcome.reasons[0..outcome.reason_count]) |item| report.judgement.add(item.text);
        report.judgement.add("the write was not run, so the row counts are not judged");
        entry_reason = std.fmt.allocPrint(child, "{s}; the write was not run: {s}", .{ baseline_text, outcome.reasons[0].text }) catch baseline_text;
        entry.ran = false;
    } else {
        const execution = switch (variant.execute(write, control, &rows.variant, stderr, failure)) {
            .measured => |value| value,
            .timeout => {
                entry.status = .variant_timeout;
                return .done;
            },
            .failed => |code| return .{ .failed = code },
        };
        after = measurement(after_plan, execution, variant.runner.columnCount());
        report.judgement.add("only the variant was run, so its plan and row counts are reported without a comparison");
        report.write_runs = 1;
    }
    report.warnings.bind_dependent_partial_index = variant.runner.database.findBindDependentPartialIndex(child, after.plan, write.sql, write.binds, control) catch null;

    const header = makeHeader(write, candidate, context, 0);
    var rendered: Io.Writer.Allocating = .init(child);
    report_json.writeJsonVariantOnlyTo(&rendered.writer, child, header, after, report, .minified) catch return .{ .failed = outOfMemoryCode(stderr) };

    entry.baseline_missing = true;
    entry.judgement = .not_judged;
    entry.variant_read = after.counters.rows_read;
    entry.variant_written = after.counters.rows_written;
    entry.reason = arena.dupe(u8, entry_reason) catch return .{ .failed = outOfMemoryCode(stderr) };
    entry.comparison = arena.dupe(u8, rendered.written()) catch return .{ .failed = outOfMemoryCode(stderr) };
    return .done;
}

fn renderComparison(
    child: std.mem.Allocator,
    entry: *report_batch_writes.Result,
    write: *const Write,
    candidate: []const u8,
    context: Context,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: report_model.Report,
    variant: *Session,
    control: *db.StepControl,
    arena: std.mem.Allocator,
    stderr: *Io.Writer,
) Render {
    var final_report = report;
    final_report.warnings.bind_dependent_partial_index = variant.runner.database.findBindDependentPartialIndex(child, after.plan, write.sql, write.binds, control) catch null;
    const header = makeHeader(write, candidate, context, cli_comparison.comparisonExitCode(outcome.verdict));
    var rendered: Io.Writer.Allocating = .init(child);
    report_json.writeJsonTo(&rendered.writer, child, header, before, after, outcome, final_report, .minified) catch return .{ .failed = outOfMemoryCode(stderr) };
    entry.outcome = outcome.verdict;
    entry.judgement = final_report.judgement.verdict;
    entry.comparison = arena.dupe(u8, rendered.written()) catch return .{ .failed = outOfMemoryCode(stderr) };
    return .done;
}

fn makeHeader(write: *const Write, candidate: []const u8, context: Context, exit_code: u8) report_model.Header {
    return .{
        .database_path = context.database_path,
        .select_path = write.label,
        .write_path = write.label,
        .index_path = candidate,
        .work_parent = context.work_parent,
        .sqlite_version = cli_query.sqliteVersion(),
        .sqlite_source_id = cli_query.sqliteSourceId(),
        .qenome_version = cli_args.version,
        .binds = write.binds,
        .show_binds = context.show_binds,
        .show_rows = context.show_rows,
        .exit_code = exit_code,
        .d1 = context.d1,
    };
}

fn outOfMemoryCode(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: out of memory\n") catch {};
    return .rejected;
}

test {
    _ = @import("batch_writes_tests.zig");
}
