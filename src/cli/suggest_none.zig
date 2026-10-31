const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_args = @import("args.zig");
const cli_control = @import("control.zig");
const cli_query = @import("query.zig");
const cli_suggest = @import("suggest.zig");
const report_suggest = @import("../report/suggest_none.zig");

const ExitCode = cli_control.ExitCode;
const QuerySession = cli_query.QuerySession;

pub const Select = struct {
    label: []const u8,
    sql: [:0]const u8,
    binds: []const db.BindArg,
};

pub fn report(
    io: Io,
    arena: std.mem.Allocator,
    baseline: *QuerySession,
    database_path: []const u8,
    timeout_ms: u64,
    format: cli_args.Format,
    queries: []const Select,
    warnings: []const cli_suggest.Warning,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    if (queries.len == 0) {
        stderr.writeAll("error: no candidate index to compare: SQLite suggested no index for these queries\n") catch {};
        return .rejected;
    }
    const measured = arena.alloc(report_suggest.Query, queries.len) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    var control = db.StepControl.init(io, timeout_ms, cli_control.cancelFlag());
    for (queries, 0..) |query, index| {
        var failure: ExitCode = .rejected;
        if (!baseline.prepare(query.sql, query.binds, .baseline, "", stderr, &failure)) return failure;
        const value = cli_query.measure(arena, baseline, query.sql, query.binds, &control, null, .baseline, stderr, &failure) orelse return failure;
        measured[index] = .{
            .label = query.label,
            .rows = value.rows,
            .plan = value.plan,
            .counters = value.counters,
        };
    }
    const copied = arena.alloc(report_suggest.Warning, warnings.len) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    for (warnings, 0..) |warning, index| copied[index] = .{ .code = warning.code, .message = warning.message };
    const body: report_suggest.Report = .{
        .database_path = database_path,
        .queries = measured,
        .warnings = copied,
    };
    const written = switch (format) {
        .human => report_suggest.writeHuman(stdout, body),
        .json => report_suggest.writeJson(stdout, body),
        .kv => return .usage,
    };
    written catch |err| {
        stderr.print("error: the summary could not be written: {s}\n", .{@errorName(err)}) catch {};
        return .rejected;
    };
    return .ok;
}
