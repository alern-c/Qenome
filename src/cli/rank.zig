const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const db = @import("../db.zig");
const result_rows = @import("../result.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const cli_args = @import("args.zig");
const cli_batch = @import("batch.zig");
const cli_control = @import("control.zig");
const cli_query = @import("query.zig");
const report_human = @import("../report/human.zig");
const report_json = @import("../report/json.zig");
const cli_warnings = @import("warnings.zig");

const ExitCode = cli_control.ExitCode;
const QuerySession = cli_query.QuerySession;

pub const note_text = "rows read x runs is a relative indicator, not a bill";

pub const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    unapplied_migrations: ?cli_d1_migrations.Pending = null,
    timeout_ms: u64,
    format: cli_args.Format = .human,
    work_parent: []const u8,
    seed_path: ?[]const u8 = null,
};

const Measured = struct {
    label: []const u8,
    rows_read: u64,
    rows_returned: u64,
    fullscan_steps: u64,
    scan_steps: []const []const u8,
    likely_full_scan: bool,
    executions: ?u64,
    relative_rows: ?u64,
    input_index: usize,
};

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    queries: []const cli_batch.Query,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) ExitCode {
    if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);

    var session: QuerySession = .{};
    defer session.deinit(.baseline, stderr, cleanup_failed);
    var failure: ExitCode = .rejected;
    if (!session.openDatabase(inputs.baseline_path, .baseline, stderr, &failure)) return failure;

    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());
    const measured = arena.alloc(Measured, queries.len) catch return outOfMemory(stderr);
    for (queries, 0..) |query, index| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        if (!prepareQuery(&session, query, stderr)) return .rejected;
        measured[index] = measureQuery(arena, &session, &control, inputs.timeout_ms, query, index, stderr, &failure) orelse return failure;
    }

    std.mem.sort(Measured, measured, {}, rankLessThan);
    var likely: usize = 0;
    for (measured) |row| {
        if (row.likely_full_scan) likely += 1;
    }
    const code: ExitCode = if (likely == 0) .ok else .likely_full_scan;

    switch (inputs.format) {
        .json => writeJson(stdout, allocator, inputs, measured, likely, code) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .human => writeHuman(stdout, arena, inputs, measured, likely) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .kv => unreachable,
    }
    return code;
}

fn rankLessThan(_: void, left: Measured, right: Measured) bool {
    const left_weight = weightOf(left);
    const right_weight = weightOf(right);
    if (left_weight != right_weight) return left_weight > right_weight;
    if (left.likely_full_scan != right.likely_full_scan) return left.likely_full_scan;
    if (readRatioRanksBefore(left.rows_read, left.rows_returned, right.rows_read, right.rows_returned)) return true;
    if (readRatioRanksBefore(right.rows_read, right.rows_returned, left.rows_read, left.rows_returned)) return false;
    return left.input_index < right.input_index;
}

fn weightOf(row: Measured) u128 {
    const reads: u128 = row.rows_read;
    if (row.executions) |count| return reads * @as(u128, count);
    return reads;
}

pub fn readRatioRanksBefore(left_read: u64, left_returned: u64, right_read: u64, right_returned: u64) bool {
    if (left_returned == 0) return false;
    if (right_returned == 0) return true;
    return @as(u128, left_read) * @as(u128, right_returned) > @as(u128, right_read) * @as(u128, left_returned);
}

fn relativeProduct(rows_read: u64, executions: ?u64) ?u64 {
    const count = executions orelse return null;
    return std.math.mul(u64, rows_read, count) catch null;
}

pub fn isTableScan(detail: []const u8, coroutines: []const []const u8) bool {
    if (!std.mem.startsWith(u8, detail, "SCAN ")) return false;
    if (std.mem.indexOf(u8, detail, " USING ") != null) return false;
    const name = detail["SCAN ".len..];
    if (std.mem.endsWith(u8, name, "CONSTANT ROW")) return false;
    if (std.mem.endsWith(u8, name, "VALUES CLAUSE")) return false;
    if (std.mem.startsWith(u8, name, "SUBQUERY ")) return false;
    if (std.mem.startsWith(u8, name, "(subquery-")) return false;
    for (coroutines) |coroutine| {
        if (std.mem.eql(u8, name, coroutine)) return false;
    }
    return true;
}

const coroutine_prefix = "CO-ROUTINE ";

fn collectCoroutines(arena: std.mem.Allocator, rows: []const db.PlanRow) ?[]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.detail, coroutine_prefix)) continue;
        const name = std.mem.trim(u8, row.detail[coroutine_prefix.len..], " \t");
        if (name.len == 0) continue;
        const copy = arena.dupe(u8, name) catch return null;
        names.append(arena, copy) catch return null;
    }
    return names.toOwnedSlice(arena) catch null;
}

fn measureQuery(
    arena: std.mem.Allocator,
    session: *QuerySession,
    control: *db.StepControl,
    timeout_ms: u64,
    query: cli_batch.Query,
    input_index: usize,
    stderr: *Io.Writer,
    failure: *ExitCode,
) ?Measured {
    const plan = session.database.explainPlanBounded(arena, query.sql, query.binds, control) catch |err| {
        failure.* = switch (err) {
            error.OutOfMemory => outOfMemory(stderr),
            error.Interrupted => cli_control.reportInterrupted(stderr),
            error.Timeout => rankTimeout(stderr, query.label, timeout_ms),
            else => blk: {
                const detail = if (session.message().len != 0) session.message() else @errorName(err);
                break :blk rankFailed(stderr, query.label, detail);
            },
        };
        return null;
    };
    defer plan.deinit(arena);

    const rows_returned = session.run(control, null) catch |err| {
        failure.* = switch (err) {
            error.Timeout => rankTimeout(stderr, query.label, timeout_ms),
            error.Interrupted => cli_control.reportInterrupted(stderr),
            error.StepFailed => blk: {
                const detail = if (session.message().len != 0) session.message() else "the SELECT failed";
                break :blk rankFailed(stderr, query.label, detail);
            },
        };
        return null;
    };

    const coroutines = collectCoroutines(arena, plan.rows) orelse {
        failure.* = outOfMemory(stderr);
        return null;
    };
    const counters = session.counters();
    var steps: std.ArrayList([]const u8) = .empty;
    for (plan.rows) |row| {
        if (!isTableScan(row.detail, coroutines)) continue;
        const copy = arena.dupe(u8, row.detail) catch {
            failure.* = outOfMemory(stderr);
            return null;
        };
        steps.append(arena, copy) catch {
            failure.* = outOfMemory(stderr);
            return null;
        };
    }
    const scan_steps = steps.toOwnedSlice(arena) catch {
        failure.* = outOfMemory(stderr);
        return null;
    };
    const rows_read: u64 = counters.rows_read;
    const fullscan_steps: u64 = counters.fullscan_steps;
    return .{
        .label = query.label,
        .rows_read = rows_read,
        .rows_returned = rows_returned,
        .fullscan_steps = fullscan_steps,
        .scan_steps = scan_steps,
        .likely_full_scan = fullscan_steps > 0 or scan_steps.len > 0,
        .executions = query.executions,
        .relative_rows = relativeProduct(rows_read, query.executions),
        .input_index = input_index,
    };
}

fn prepareQuery(session: *QuerySession, query: cli_batch.Query, stderr: *Io.Writer) bool {
    var capture: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    var failure: ExitCode = .rejected;
    if (session.prepare(query.sql, query.binds, .baseline, "", &sink, &failure)) return true;
    stderr.writeAll("error: the rank query '") catch {};
    result_rows.writeEscapedText(stderr, query.label) catch {};
    reportCaptured(stderr, "': ", sink.buffered());
    return false;
}

fn reportCaptured(stderr: *Io.Writer, prefix: []const u8, captured: []const u8) void {
    var text = std.mem.trimEnd(u8, captured, "\n");
    if (std.mem.startsWith(u8, text, "error: ")) text = text["error: ".len..];
    if (text.len == 0) text = "the input was rejected";
    stderr.print("{s}{s}\n", .{ prefix, text }) catch {};
}

fn rankTimeout(stderr: *Io.Writer, label: []const u8, timeout_ms: u64) ExitCode {
    stderr.writeAll("error: the rank query '") catch {};
    result_rows.writeEscapedText(stderr, label) catch {};
    stderr.print("' exceeded the time limit of {d} ms\n", .{timeout_ms}) catch {};
    return .timeout;
}

fn rankFailed(stderr: *Io.Writer, label: []const u8, detail: []const u8) ExitCode {
    stderr.writeAll("error: the rank query '") catch {};
    result_rows.writeEscapedText(stderr, label) catch {};
    stderr.print("': {s}\n", .{detail}) catch {};
    return .rejected;
}

fn writeHuman(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    measured: []const Measured,
    likely: usize,
) !void {
    try stdout.print("baseline rank: {d} {s}\n", .{ measured.len, word(measured.len, "query", "queries") });
    try stdout.print("database: {s}\nsqlite: {s}\nwork-dir-parent: {s}\n", .{
        inputs.database_path,
        cli_query.sqliteVersion(),
        inputs.work_parent,
    });
    if (inputs.seed_path) |path| try stdout.print("seed data: {s}\n", .{path});
    try stdout.print("likely full scans: {d}\nnote: {s}\n\n", .{ likely, note_text });
    for (measured, 0..) |row, index| {
        try stdout.print("#{d}  ", .{index + 1});
        try result_rows.writeEscapedText(stdout, row.label);
        try stdout.writeByte('\n');
        if (row.likely_full_scan) try stdout.writeAll("  flag: likely full scan\n");
        try stdout.print("  rows read: {d}\n  rows returned: {d}\n  rows read / rows returned: ", .{
            row.rows_read,
            row.rows_returned,
        });
        try writeRatio(stdout, row.rows_read, row.rows_returned);
        try stdout.print("\n  fullscan steps: {d}\n  scan: ", .{row.fullscan_steps});
        try writeScanList(stdout, row.scan_steps);
        try stdout.writeByte('\n');
        if (row.executions) |count| {
            try stdout.print("  runs: {d}\n", .{count});
            try stdout.writeAll("  rows read x runs (not a bill): ");
            if (row.relative_rows) |product| {
                try stdout.print("{d}\n", .{product});
            } else {
                try stdout.writeAll("n/a\n");
            }
        }
        if (index + 1 != measured.len) try stdout.writeByte('\n');
    }
    const top = measured[0];
    try stdout.writeAll("\nnext: qenome <DB> ");
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    try cli_warnings.appendToken(&token, allocator, top.label);
    try stdout.writeAll(token.items);
    try stdout.writeAll(" --suggest\n");
    if (inputs.unapplied_migrations) |pending| {
        try stdout.writeAll("\nWarnings\n");
        const message = try cli_warnings.unappliedMigrationsText(allocator, pending);
        try report_human.writeHumanWarning(stdout, allocator, contract.code.unapplied_migrations, message);
    }
}

fn writeRatio(writer: *Io.Writer, rows_read: u64, rows_returned: u64) !void {
    if (rows_returned == 0) {
        try writer.writeAll("n/a");
        return;
    }
    if (rows_read % rows_returned == 0) {
        try writer.print("{d}", .{rows_read / rows_returned});
        return;
    }
    try writer.print("{d}/{d}", .{ rows_read, rows_returned });
}

fn writeScanList(writer: *Io.Writer, steps: []const []const u8) !void {
    if (steps.len == 0) {
        try writer.writeAll("none");
        return;
    }
    for (steps, 0..) |step, index| {
        if (index != 0) try writer.writeAll(", ");
        try result_rows.writeEscapedText(writer, step);
    }
}

fn writeJson(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    measured: []const Measured,
    likely: usize,
    code: ExitCode,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(contract.schema_version);
    try json.objectField("rank_schema_version");
    try json.write(contract.rank_schema_version);
    try json.objectField("exit_code");
    try json.write(@backingInt(code));
    try json.objectField("database");
    try report_json.writeJsonText(&json, allocator, inputs.database_path);
    try json.objectField("sqlite_version");
    try report_json.writeJsonText(&json, allocator, std.mem.span(cli_query.sqliteVersion()));
    try json.objectField("work_dir_parent");
    try report_json.writeJsonText(&json, allocator, inputs.work_parent);
    if (inputs.seed_path) |path| {
        try json.objectField("seed_data");
        try report_json.writeJsonText(&json, allocator, path);
    }
    try json.objectField("likely_full_scans");
    try json.write(likely);
    try json.objectField("note");
    try json.write(note_text);
    try json.objectField("next");
    try json.beginObject();
    try json.objectField("select");
    try report_json.writeJsonText(&json, allocator, measured[0].label);
    try json.objectField("command");
    try json.write("--suggest");
    try json.objectField("hint");
    try json.write("Run qenome with this SELECT and --suggest. The path is relative to the manifest.");
    try json.endObject();
    try json.objectField("queries");
    try json.beginArray();
    for (measured, 0..) |row, index| {
        try json.beginObject();
        try json.objectField("rank");
        try json.write(index + 1);
        try json.objectField("select");
        try report_json.writeJsonText(&json, allocator, row.label);
        try json.objectField("rows_read");
        try json.write(row.rows_read);
        try json.objectField("rows_returned");
        try json.write(row.rows_returned);
        try json.objectField("read_ratio");
        try writeReadRatio(&json, row.rows_read, row.rows_returned);
        try json.objectField("fullscan_steps");
        try json.write(row.fullscan_steps);
        try json.objectField("scan_steps");
        try json.beginArray();
        for (row.scan_steps) |step| try report_json.writeJsonText(&json, allocator, step);
        try json.endArray();
        try json.objectField("likely_full_scan");
        try json.write(row.likely_full_scan);
        try json.objectField("executions");
        if (row.executions) |count| try json.write(count) else try json.write(null);
        try json.objectField("relative_rows");
        if (row.relative_rows) |product| try json.write(product) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("warnings");
    try json.beginArray();
    if (inputs.unapplied_migrations) |pending| {
        const message = try cli_warnings.unappliedMigrationsMessage(allocator, pending);
        defer allocator.free(message);
        try json.beginObject();
        try json.objectField("code");
        try json.write(contract.code.unapplied_migrations);
        try json.objectField("message");
        try report_json.writeJsonText(&json, allocator, message);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

fn writeReadRatio(json: *std.json.Stringify, rows_read: u64, rows_returned: u64) !void {
    if (rows_returned == 0) {
        try json.write(null);
        return;
    }
    if (rows_read % rows_returned == 0) {
        try json.write(rows_read / rows_returned);
        return;
    }
    const ratio = @as(f64, @floatFromInt(rows_read)) / @as(f64, @floatFromInt(rows_returned));
    try json.write(ratio);
}

fn word(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

fn outOfMemory(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: out of memory\n") catch {};
    return .rejected;
}

fn reportWriteFailure(err: anyerror, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.OutOfMemory => outOfMemory(stderr),
        else => {
            stderr.writeAll("error: the rank report could not be written\n") catch {};
            return .rejected;
        },
    };
}

test {
    _ = @import("rank_tests.zig");
}
