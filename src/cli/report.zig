const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const result = @import("../result.zig");
const cli_args = @import("args.zig");
const cli_comparison = @import("comparison.zig");
const cli_timing = @import("timing.zig");

pub const Header = struct {
    database_path: []const u8,
    select_path: []const u8,
    index_path: []const u8,
    work_parent: []const u8,
    sqlite_version: [*:0]const u8,
    sqlite_source_id: [*:0]const u8,
    binds: []const cli_args.BindArg,
    show_binds: bool,
};

pub const Sizes = struct {
    baseline: u64 = 0,
    variant: u64 = 0,
};

pub const TimeReport = struct {
    timing: ?cli_timing.TimeSummary = null,
    sizes: Sizes = .{},
    judgement: cli_timing.Judgement,
};

pub fn writeSummary(
    stdout: *Io.Writer,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: TimeReport,
) Io.Writer.Error!void {
    try stdout.print("db: {s}\nselect: {s}\nindex-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: {d}\n", .{
        header.database_path, header.select_path, header.index_path, before.rows,
    });
    try stdout.print("sqlite: {s}\nsqlite-source-id: {s}\n", .{
        header.sqlite_version, header.sqlite_source_id,
    });
    try writePlanAndCounters(stdout, before);
    try stdout.print("measured-on: variant (candidate index applied)\nrows: {d}\n", .{after.rows});
    try writePlanAndCounters(stdout, after);

    switch (outcome.verdict) {
        .match => try stdout.writeAll("result: match (row multiset)\n"),
        .mismatch => try stdout.writeAll("result: mismatch (row multiset; the cause is not determined)\n"),
        .incomparable => try stdout.writeAll("result: incomparable\n"),
    }
    for (outcome.reasons[0..outcome.reason_count]) |reason| {
        try stdout.print("incomparable-reason: {s}\n", .{reason.text});
        if (reason.hint) |hint| try stdout.print("incomparable-hint: {s}\n", .{hint});
    }
    if (outcome.comparison) |comparison| if (!comparison.matched) {
        try stdout.print("baseline-only-rows: {d}\nvariant-only-rows: {d}\n", .{ comparison.baseline_only, comparison.variant_only });
        for (comparison.baselineExamples()) |row| {
            try stdout.writeAll("baseline-only-row: ");
            try result.writeRow(stdout, row);
            try stdout.writeByte('\n');
        }
        for (comparison.variantExamples()) |row| {
            try stdout.writeAll("variant-only-row: ");
            try result.writeRow(stdout, row);
            try stdout.writeByte('\n');
        }
    };
    const order = if (outcome.verdict != .match)
        "not applicable"
    else if (outcome.comparison.?.same_order)
        "same (reference only; not part of the result)"
    else
        "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";
    try stdout.print("row-order: {s}\n", .{order});
    try writeTimeReport(stdout, header, report);
}

pub fn writeTimeReport(stdout: *Io.Writer, header: Header, report: TimeReport) Io.Writer.Error!void {
    if (header.binds.len == 0) try stdout.writeAll("bind: none\n");
    for (header.binds) |bind| {
        try stdout.print("bind: {d}:", .{bind.number});
        if (!header.show_binds) {
            switch (bind.value) {
                .text => |value| try stdout.print("text ({d} bytes)\n", .{value.len}),
                else => |value| try stdout.print("{t}\n", .{value}),
            }
            continue;
        }
        switch (bind.value) {
            .int => |value| try stdout.print("int:{d}", .{value}),
            .real => |value| try stdout.print("real:{e}", .{value}),
            .text => |value| {
                try stdout.writeAll("text:");
                try result.writeText(stdout, value);
            },
            .null => try stdout.writeAll("null"),
        }
        try stdout.writeByte('\n');
    }
    const rounds = if (report.timing) |timing| timing.rounds else 0;
    try stdout.print(
        \\measure-runs: {d} per copy
        \\measure-warmup: 1 per copy (the run whose rows were compared, not timed)
        \\measure-order: rounds alternate baseline-variant and variant-baseline (ABBA)
        \\measure-scope: sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed
        \\measure-cache: warm; each copy reuses its connection and page cache, and its file was just written
        \\work-dir-parent: {s}
        \\zig: {s}
        \\build-mode: {t}
        \\os-arch: {t}-{t}
        \\
    , .{ rounds, header.work_parent, builtin.zig_version_string, builtin.mode, builtin.os.tag, builtin.cpu.arch });
    if (report.timing) |timing| {
        try writeStats(stdout, "time-baseline-ns", timing.baseline);
        try writeStats(stdout, "time-variant-ns", timing.variant);
        if (timing.baseline.median == 0) {
            try stdout.writeAll("time-ratio: n/a (the baseline median is 0)\n");
        } else {
            const ratio = @as(f64, @floatFromInt(timing.variant.median)) / @as(f64, @floatFromInt(timing.baseline.median));
            try stdout.print("time-ratio: {d:.3} (variant median / baseline median)\n", .{ratio});
        }
        try stdout.print("variant-faster-rounds: {d}/{d}\n", .{ timing.variant_faster_rounds, timing.rounds });
    }
    const sizes = report.sizes;
    try stdout.print(
        \\db-bytes-baseline: {d} (the snapshot file)
        \\db-bytes-variant: {d} (the snapshot file with the candidate index)
        \\db-bytes-increase: {d} (the whole database file, not the index alone)
        \\time-verdict: {s}
        \\
    , .{ sizes.baseline, sizes.variant, @as(i128, sizes.variant) - @as(i128, sizes.baseline), report.judgement.verdict.text() });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try stdout.print("time-verdict-reason: {s}\n", .{reason});
    }
}

pub fn writeStats(stdout: *Io.Writer, key: []const u8, stats: cli_timing.Stats) Io.Writer.Error!void {
    try stdout.print("{s}: median={d} p25={d} p75={d} min={d} max={d} (median ", .{ key, stats.median, stats.p25, stats.p75, stats.min, stats.max });
    try writeDuration(stdout, stats.median);
    try stdout.writeAll(")\n");
}

pub fn writeDuration(writer: *Io.Writer, ns: u64) Io.Writer.Error!void {
    if (ns < 1000) return writer.print("{d} ns", .{ns});
    const units = [_]struct { name: []const u8, ns: f64 }{
        .{ .name = "us", .ns = 1e3 },
        .{ .name = "ms", .ns = 1e6 },
    };
    const value: f64 = @floatFromInt(ns);
    for (units) |unit| {
        const hundredths = @round(value / unit.ns * 100);
        if (hundredths < 100_000) return writer.print("{d:.2} {s}", .{ hundredths / 100, unit.name });
    }
    return writer.print("{d:.2} s", .{value / 1e9});
}

pub fn writePlanAndCounters(stdout: *Io.Writer, measurement: cli_comparison.Measurement) Io.Writer.Error!void {
    for (measurement.plan.rows) |row| {
        try stdout.print("plan: id={d} parent={d} kind={t} covering={} automatic={} detail={s}\n", .{
            row.id, row.parent, row.label.kind, row.label.covering, row.label.automatic, row.detail,
        });
    }
    try stdout.print("fullscan-steps: {d}\nvm-steps: {d}\nsort-ops: {d}\nautoindex-rows: {d}\n", .{
        measurement.counters.fullscan_steps, measurement.counters.vm_steps, measurement.counters.sort_ops, measurement.counters.autoindex_rows,
    });
}

const testing = std.testing;

test "a duration keeps under 1000 of its unit after rounding" {
    const cases = [_]struct { ns: u64, text: []const u8 }{
        .{ .ns = 0, .text = "0 ns" },
        .{ .ns = 999, .text = "999 ns" },
        .{ .ns = 1000, .text = "1.00 us" },
        .{ .ns = 26_521, .text = "26.52 us" },
        .{ .ns = 999_994, .text = "999.99 us" },
        .{ .ns = 999_999, .text = "1.00 ms" },
        .{ .ns = 3_006_771, .text = "3.01 ms" },
        .{ .ns = 999_999_999, .text = "1.00 s" },
        .{ .ns = 61_500_000_000, .text = "61.50 s" },
    };
    for (cases) |case| {
        var buffer: [32]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try writeDuration(&writer, case.ns);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
}

const scan_line = [_]cli_comparison.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

test "the summary keeps its block order without a database" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]cli_args.BindArg{.{ .number = 1, .value = .{ .int = 7 } }};
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &binds,
        .show_binds = false,
    };
    const before: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 0, .vm_steps = 1, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{
        .sizes = .{ .baseline = 4096, .variant = 8192 },
        .judgement = .{ .verdict = .not_judged },
    };
    try writeSummary(&stdout, header, before, after, outcome, report);

    const keys = [_][]const u8{
        "db: db.sqlite\nselect: select.sql\nindex-sql: index.sql\n",
        "measured-on: baseline (candidate index not applied)\nrows: 2\n",
        "sqlite: 0.0.0\nsqlite-source-id: test-source-id\n",
        "detail=SCAN t\n",
        "measured-on: variant (candidate index applied)\nrows: 2\n",
        "result: match (row multiset)\n",
        "row-order: ",
        "bind: 1:int\n",
        "measure-runs: 0 per copy\n",
        "time-verdict: not-judged\n",
    };
    var from: usize = 0;
    for (keys) |key| {
        const at = std.mem.indexOfPos(u8, stdout.buffered(), from, key) orelse {
            std.debug.print("missing or out of order: {s}\n", .{key});
            return error.TestUnexpectedResult;
        };
        from = at + key.len;
    }
}
