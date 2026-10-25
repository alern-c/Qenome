const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const result = @import("../result.zig");
const cli_args = @import("args.zig");
const cli_comparison = @import("comparison.zig");
const cli_timing = @import("timing.zig");
const PlanRow = cli_comparison.PlanRow;
const Plan = @FieldType(cli_comparison.Measurement, "plan");

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

pub fn writeReport(
    stdout: *Io.Writer,
    format: cli_args.Format,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: TimeReport,
) Io.Writer.Error!void {
    switch (format) {
        .human => try writeHumanSummary(stdout, header, before, after, outcome, report),
        .kv => try writeSummary(stdout, header, before, after, outcome, report),
    }
}

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
        try stdout.writeAll("bind: ");
        try writeBind(stdout, bind, header.show_binds);
        try stdout.writeByte('\n');
    }
    const rounds = if (report.timing) |timing| timing.rounds else 0;
    try stdout.print(
        \\measure-runs: {d} per copy
        \\measure-warmup: {s}
        \\measure-order: {s}
        \\measure-scope: {s}
        \\measure-cache: {s}
        \\work-dir-parent: {s}
        \\zig: {s}
        \\build-mode: {t}
        \\os-arch: {t}-{t}
        \\
    , .{ rounds, measure_warmup, measure_order, measure_scope, measure_cache, header.work_parent, builtin.zig_version_string, builtin.mode, builtin.os.tag, builtin.cpu.arch });
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

const measure_warmup = "1 per copy (the run whose rows were compared, not timed)";
const measure_order = "rounds alternate baseline-variant and variant-baseline (ABBA)";
const measure_scope = "sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed";
const measure_cache = "warm; each copy reuses its connection and page cache, and its file was just written";

fn writeBind(writer: *Io.Writer, bind: cli_args.BindArg, show: bool) Io.Writer.Error!void {
    try writer.print("{d}:", .{bind.number});
    if (!show) {
        switch (bind.value) {
            .text => |value| try writer.print("text ({d} bytes)", .{value.len}),
            else => |value| try writer.print("{t}", .{value}),
        }
        return;
    }
    switch (bind.value) {
        .int => |value| try writer.print("int:{d}", .{value}),
        .real => |value| try writer.print("real:{e}", .{value}),
        .text => |value| {
            try writer.writeAll("text:");
            try result.writeText(writer, value);
        },
        .null => try writer.writeAll("null"),
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

const line_width = 80;

const value_column = 16;

const debug_note = "  debug build (no optimization): the times are slower than a release build\n";

const row_order_differs = "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";

pub fn writeHumanSummary(
    stdout: *Io.Writer,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: TimeReport,
) Io.Writer.Error!void {
    try writeOverview(stdout, header, before, after, outcome, report);
    try stdout.writeByte('\n');
    try writeSideBySide(stdout, before, after, report);
    try stdout.writeAll("\nQuery plan\n");
    try stdout.writeAll("  baseline (candidate index not applied)\n");
    try writePlan(stdout, before.plan);
    try stdout.writeAll("  variant (candidate index applied)\n");
    try writePlan(stdout, after.plan);
    if (outcome.verdict != .match or !outcome.comparison.?.same_order) {
        try stdout.writeAll("\nResult rows\n");
        try writeRowsDetail(stdout, outcome);
    }
}

fn writeOverview(
    stdout: *Io.Writer,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: TimeReport,
) Io.Writer.Error!void {
    try stdout.writeAll("Summary\n");
    try writeField(stdout, "result rows", switch (outcome.verdict) {
        .match => "match (the same rows on both copies)",
        .mismatch => "MISMATCH (the rows differ; the cause is not determined)",
        .incomparable => "INCOMPARABLE (the rows cannot be compared; see Result rows)",
    });
    try writeField(stdout, "time verdict", switch (report.judgement.verdict) {
        .improved => "improved: less work, a median more than 20% lower, and faster in every round",
        .no_effect => "no-effect: the same plan and counters, and medians within 20%",
        .needs_check => "needs-check:",
        .not_judged => "not-judged:",
    });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try writeIndent(stdout, value_column);
        try stdout.writeAll("- ");
        try writeWrapped(stdout, reason, value_column + 2, value_column + 2);
        try stdout.writeByte('\n');
    }
    try writeField(stdout, "query plan", if (cli_timing.samePlan(before.plan, after.plan))
        "the same on both copies"
    else
        "changed on the variant");

    var buffer: [256]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    if (report.timing) |timing| {
        try text.writeAll("median ");
        try writeDuration(&text, timing.baseline.median);
        try text.writeAll(" -> ");
        try writeDuration(&text, timing.variant.median);
        try text.writeAll(" (");
        try writeRatio(&text, timing.baseline.median, timing.variant.median);
        try text.print("); the variant was faster in {d} of {d} rounds", .{ timing.variant_faster_rounds, timing.rounds });
    } else {
        try text.writeAll("not measured (0 rounds)");
    }
    try writeField(stdout, "time", text.buffered());

    text = Io.Writer.fixed(&buffer);
    const increase = @as(i128, report.sizes.variant) - @as(i128, report.sizes.baseline);
    try writeSigned(&text, increase);
    try text.writeAll(" bytes (");
    try writeMebibytes(&text, increase);
    try text.writeAll("; the whole database file, not the index alone)");
    try writeField(stdout, "db size", text.buffered());

    if (header.show_binds and header.binds.len != 0) {
        try writeLabel(stdout, "binds");
        for (header.binds, 0..) |bind, at| {
            if (at != 0) try stdout.writeAll(", ");
            try writeBind(stdout, bind, true);
        }
        try stdout.writeByte('\n');
    }
    if (builtin.mode == .debug) try stdout.writeAll(debug_note);
}

fn writeSideBySide(
    stdout: *Io.Writer,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    report: TimeReport,
) Io.Writer.Error!void {
    try stdout.print("{s:<22}{s:>16}{s:>16}{s:>16}\n", .{ "Baseline vs variant", "baseline", "variant", "change" });
    try writeCountRow(stdout, "rows", before.rows, after.rows);
    try writeCountRow(stdout, "fullscan-steps", before.counters.fullscan_steps, after.counters.fullscan_steps);
    try writeCountRow(stdout, "vm-steps", before.counters.vm_steps, after.counters.vm_steps);
    if (before.counters.sort_ops != 0 or after.counters.sort_ops != 0) {
        try writeCountRow(stdout, "sort-ops", before.counters.sort_ops, after.counters.sort_ops);
    }
    if (before.counters.autoindex_rows != 0 or after.counters.autoindex_rows != 0) {
        try writeCountRow(stdout, "autoindex-rows", before.counters.autoindex_rows, after.counters.autoindex_rows);
    }
    if (report.timing) |timing| {
        try writeTimeRow(stdout, "time p25", timing.baseline.p25, timing.variant.p25, "");
        try writeTimeRow(stdout, "time p75", timing.baseline.p75, timing.variant.p75, "");
    }
    try writeCountRow(stdout, "db file bytes", report.sizes.baseline, report.sizes.variant);
}

fn writeCountRow(stdout: *Io.Writer, label: []const u8, baseline: u64, variant: u64) Io.Writer.Error!void {
    var cells: [3][32]u8 = undefined;
    var baseline_text = Io.Writer.fixed(&cells[0]);
    var variant_text = Io.Writer.fixed(&cells[1]);
    var change_text = Io.Writer.fixed(&cells[2]);
    try writeCount(&baseline_text, baseline);
    try writeCount(&variant_text, variant);
    if (baseline == variant) {
        try change_text.writeAll("same");
    } else {
        try writeSigned(&change_text, @as(i128, variant) - @as(i128, baseline));
    }
    try writeTableRow(stdout, label, baseline_text.buffered(), variant_text.buffered(), change_text.buffered());
}

fn writeTimeRow(stdout: *Io.Writer, label: []const u8, baseline: u64, variant: u64, change: []const u8) Io.Writer.Error!void {
    var cells: [2][32]u8 = undefined;
    var baseline_text = Io.Writer.fixed(&cells[0]);
    var variant_text = Io.Writer.fixed(&cells[1]);
    try writeDuration(&baseline_text, baseline);
    try writeDuration(&variant_text, variant);
    try writeTableRow(stdout, label, baseline_text.buffered(), variant_text.buffered(), change);
}

fn writeTableRow(stdout: *Io.Writer, label: []const u8, baseline: []const u8, variant: []const u8, change: []const u8) Io.Writer.Error!void {
    try stdout.print("  {s:<20}{s:>16}{s:>16}", .{ label, baseline, variant });
    if (change.len != 0) try stdout.print("{s:>16}", .{change});
    try stdout.writeByte('\n');
}

fn writeRatio(writer: *Io.Writer, baseline: u64, variant: u64) Io.Writer.Error!void {
    if (baseline == 0) return writer.writeAll("n/a");
    const ratio = @as(f64, @floatFromInt(variant)) / @as(f64, @floatFromInt(baseline));
    try writer.print("{d:.3}x", .{ratio});
}

fn writePlan(stdout: *Io.Writer, plan: Plan) Io.Writer.Error!void {
    if (plan.rows.len == 0) return stdout.writeAll("    (no plan lines)\n");
    const nested = planNested(plan);
    for (plan.rows) |row| {
        const indent = 4 + 2 * planDepth(plan, row);
        var buffer: [96]u8 = undefined;
        var labels = Io.Writer.fixed(&buffer);
        try labels.print("[{t}", .{row.label.kind});
        if (row.label.covering) try labels.writeAll(", covering");
        if (row.label.automatic) try labels.writeAll(", automatic");
        if (nested) try labels.print("; id {d}, parent {d}", .{ row.id, row.parent });
        try labels.writeByte(']');

        try writeIndent(stdout, indent);
        try stdout.writeAll(row.detail);
        if (indent + row.detail.len + 2 + labels.buffered().len > line_width) {
            try stdout.writeByte('\n');
            try writeIndent(stdout, indent + 2);
        } else {
            try stdout.writeAll("  ");
        }
        try stdout.print("{s}\n", .{labels.buffered()});
    }
}

fn planNested(plan: Plan) bool {
    for (plan.rows) |row| if (planDepth(plan, row) != 0) return true;
    return false;
}

fn planDepth(plan: Plan, row: PlanRow) usize {
    var depth: usize = 0;
    var parent = row.parent;
    while (depth < plan.rows.len) {
        const line = cli_timing.parentLine(plan, parent) orelse break;
        depth += 1;
        parent = plan.rows[line].parent;
    }
    return depth;
}

fn writeRowsDetail(stdout: *Io.Writer, outcome: cli_comparison.Outcome) Io.Writer.Error!void {
    if (outcome.verdict == .match) return writeField(stdout, "row order", row_order_differs);
    try writeIndent(stdout, 2);
    try writeWrapped(stdout, switch (outcome.verdict) {
        .mismatch => "MISMATCH: the rows differ, compared as a multiset; the cause is not determined",
        .incomparable => "INCOMPARABLE: the rows of the two copies cannot be compared",
        .match => unreachable,
    }, 2, 4);
    try stdout.writeByte('\n');
    for (outcome.reasons[0..outcome.reason_count]) |reason| {
        try stdout.writeAll("  - ");
        try writeWrapped(stdout, reason.text, 4, 4);
        try stdout.writeByte('\n');
        if (reason.hint) |hint| {
            try stdout.writeAll("    try: ");
            try writeWrapped(stdout, hint, 9, 9);
            try stdout.writeByte('\n');
        }
    }
    if (outcome.comparison) |comparison| if (!comparison.matched) {
        try writeExamples(stdout, "baseline only", comparison.baseline_only, comparison.baselineExamples());
        try writeExamples(stdout, "variant only", comparison.variant_only, comparison.variantExamples());
    };
}

fn writeExamples(stdout: *Io.Writer, label: []const u8, count: usize, examples: []const []const u8) Io.Writer.Error!void {
    var buffer: [64]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    try writeCount(&text, count);
    try text.writeAll(if (count == 1) " row" else " rows");
    if (examples.len != 0) try text.print(", the first {d} below", .{examples.len});
    try writeField(stdout, label, text.buffered());
    for (examples) |row| {
        try writeIndent(stdout, value_column);
        try result.writeRow(stdout, row);
        try stdout.writeByte('\n');
    }
}

fn writeLabel(stdout: *Io.Writer, label: []const u8) Io.Writer.Error!void {
    try stdout.print("  {s}", .{label});
    try writeIndent(stdout, value_column -| (2 + label.len));
}

fn writeField(stdout: *Io.Writer, label: []const u8, value: []const u8) Io.Writer.Error!void {
    try writeLabel(stdout, label);
    try writeWrapped(stdout, value, value_column, value_column);
    try stdout.writeByte('\n');
}

fn writeIndent(writer: *Io.Writer, count: usize) Io.Writer.Error!void {
    try writer.splatByteAll(' ', count);
}

fn writeWrapped(writer: *Io.Writer, text: []const u8, column: usize, indent: usize) Io.Writer.Error!void {
    var at = column;
    var first = true;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (!first) {
            if (at + 1 + word.len > line_width) {
                try writer.writeByte('\n');
                try writeIndent(writer, indent);
                at = indent;
            } else {
                try writer.writeByte(' ');
                at += 1;
            }
        }
        try writer.writeAll(word);
        at += word.len;
        first = false;
    }
}

pub fn writeCount(writer: *Io.Writer, value: u128) Io.Writer.Error!void {
    var digits_buffer: [40]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{value}) catch unreachable;
    for (digits, 0..) |digit, at| {
        if (at != 0 and (digits.len - at) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

pub fn writeSigned(writer: *Io.Writer, value: i128) Io.Writer.Error!void {
    if (value > 0) try writer.writeByte('+');
    if (value < 0) try writer.writeByte('-');
    try writeCount(writer, @abs(value));
}

fn writeMebibytes(writer: *Io.Writer, bytes: i128) Io.Writer.Error!void {
    const mib = @as(f64, @floatFromInt(@abs(bytes))) / (1024 * 1024);
    const sign: []const u8 = if (bytes > 0) "+" else if (bytes < 0) "-" else "";
    try writer.print("{s}{d:.2} MiB", .{ sign, mib });
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

test "counts get a comma between groups of three digits" {
    const cases = [_]struct { value: i128, text: []const u8 }{
        .{ .value = 0, .text = "0" },
        .{ .value = 999, .text = "+999" },
        .{ .value = 1000, .text = "+1,000" },
        .{ .value = -199_999, .text = "-199,999" },
        .{ .value = 2_170_880, .text = "+2,170,880" },
    };
    for (cases) |case| {
        var buffer: [48]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try writeSigned(&writer, case.value);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
}

test "wrapped text breaks at spaces within the width under its own column" {
    var buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeField(&writer, "scope", measure_scope);
    try testing.expectEqualStrings(
        \\  scope         sqlite3_step from the reset statement to SQLITE_DONE with the
        \\                interrupt checks; columns are not read; prepare, bind, and the
        \\                plan read are not timed
        \\
    , writer.buffered());
}

test "the human summary puts the conclusion first and the copies side by side" {
    var buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]cli_args.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "secret" } },
    };
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
    const search_lines = [_]cli_comparison.PlanRow{
        .{ .id = 3, .parent = 0, .label = .{ .kind = .search, .covering = true }, .detail = "SEARCH t USING COVERING INDEX idx_a (a=?)" },
        .{ .id = 5, .parent = 3, .label = .{ .kind = .other }, .detail = "CORRELATED SCALAR SUBQUERY 1 WITH A VERY LONG DETAIL THAT FILLS THE LINE" },
    };
    const before: cli_comparison.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&search_lines) },
        .counters = .{ .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeReport(&stdout, .human, header, before, after, outcome, report);

    const head =
        \\Summary
        \\  result rows   match (the same rows on both copies)
        \\  time verdict  improved: less work, a median more than 20% lower, and faster in
        \\                every round
        \\  query plan    changed on the variant
        \\  time          median 4.33 ms -> 37.29 us (0.009x); the variant was faster in
        \\                10 of 10 rounds
        \\  db size       +2,170,880 bytes (+2.07 MiB; the whole database file, not the
        \\                index alone)
        \\
    ;
    const note: []const u8 = "  debug build (no optimization): the times are slower than a release build\n";
    const tail =
        \\
        \\Baseline vs variant           baseline         variant          change
        \\  rows                           1,200           1,200            same
        \\  fullscan-steps               199,999               0        -199,999
        \\  vm-steps                     600,407             710        -599,697
        \\  time p25                     4.16 ms        33.20 us
        \\  time p75                     4.36 ms        40.42 us
        \\  db file bytes              5,087,232       7,258,112      +2,170,880
        \\
        \\Query plan
        \\  baseline (candidate index not applied)
        \\    SCAN t  [scan]
        \\  variant (candidate index applied)
        \\    SEARCH t USING COVERING INDEX idx_a (a=?)
        \\      [search, covering; id 3, parent 0]
        \\      CORRELATED SCALAR SUBQUERY 1 WITH A VERY LONG DETAIL THAT FILLS THE LINE
        \\        [other; id 5, parent 3]
        \\
    ;
    try testing.expect(std.mem.startsWith(u8, stdout.buffered(), head));
    const rest = stdout.buffered()[head.len..];
    if (builtin.mode == .debug) {
        try testing.expect(std.mem.startsWith(u8, rest, note));
        try testing.expectEqualStrings(tail, rest[note.len..]);
    } else {
        try testing.expectEqualStrings(tail, rest);
    }
    var lines = std.mem.splitScalar(u8, stdout.buffered(), '\n');
    while (lines.next()) |line| try testing.expect(line.len <= line_width);
}

test "the human summary lists the verdict reasons and says when nothing was timed" {
    var buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: cli_comparison.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "the SELECT calls random(), whose result changes between runs", .hint = "compare the SELECT without random()" };
    outcome.reason_count = 1;
    var report: TimeReport = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows cannot be compared, so the SELECT is not timed");
    try writeReport(&stdout, .human, header, measurement, measurement, outcome, report);

    const head =
        \\Summary
        \\  result rows   INCOMPARABLE (the rows cannot be compared; see Result rows)
        \\  time verdict  not-judged:
        \\                - the result rows cannot be compared, so the SELECT is not timed
        \\  query plan    the same on both copies
        \\  time          not measured (0 rounds)
        \\  db size       0 bytes (0.00 MiB; the whole database file, not the index alone)
        \\
    ;
    const note: []const u8 = "  debug build (no optimization): the times are slower than a release build\n";
    const tail =
        \\
        \\Baseline vs variant           baseline         variant          change
        \\  rows                               2               2            same
        \\  fullscan-steps                     1               1            same
        \\  vm-steps                           2               2            same
        \\  db file bytes                  4,096           4,096            same
        \\
        \\Query plan
        \\  baseline (candidate index not applied)
        \\    SCAN t  [scan]
        \\  variant (candidate index applied)
        \\    SCAN t  [scan]
        \\
        \\Result rows
        \\  INCOMPARABLE: the rows of the two copies cannot be compared
        \\  - the SELECT calls random(), whose result changes between runs
        \\    try: compare the SELECT without random()
        \\
    ;
    try testing.expect(std.mem.startsWith(u8, stdout.buffered(), head));
    const rest = stdout.buffered()[head.len..];
    if (builtin.mode == .debug) {
        try testing.expect(std.mem.startsWith(u8, rest, note));
        try testing.expectEqualStrings(tail, rest[note.len..]);
    } else {
        try testing.expectEqualStrings(tail, rest);
    }
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "  binds") == null);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), " ns ") == null);
}

test "the human summary keeps a counter row when one side is not zero" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &.{},
        .show_binds = false,
    };
    const before: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 3, .autoindex_rows = 4 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .no_effect } };
    try writeReport(&stdout, .human, header, before, after, outcome, report);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "  sort-ops") != null);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "  autoindex-rows") != null);
}

test "the human summary shows the bind values only when asked" {
    var buffer: [4096]u8 = undefined;
    const binds = [_]cli_args.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "secret" } },
    };
    var header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &binds,
        .show_binds = false,
    };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };

    var stdout = Io.Writer.fixed(&buffer);
    try writeReport(&stdout, .human, header, measurement, measurement, outcome, report);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "binds") == null);

    header.show_binds = true;
    var shown_buffer: [4096]u8 = undefined;
    var shown = Io.Writer.fixed(&shown_buffer);
    try writeReport(&shown, .human, header, measurement, measurement, outcome, report);
    try testing.expect(std.mem.indexOf(u8, shown.buffered(), "  binds         1:int:7, 2:text:'secret'\n") != null);
}

test "the human summary notes a debug build when the times were measured" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 2,
            .variant_faster_rounds = 2,
        },
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .no_effect },
    };
    try writeReport(&stdout, .human, header, measurement, measurement, outcome, report);
    const note = "  debug build (no optimization): the times are slower than a release build\n";
    if (builtin.mode == .debug) {
        try testing.expect(std.mem.indexOf(u8, stdout.buffered(), note) != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "debug build") == null);
    }
}

test "a plan whose parents loop still ends" {
    const looped = [_]cli_comparison.PlanRow{
        .{ .id = 2, .parent = 3, .label = .{ .kind = .scan }, .detail = "SCAN a" },
        .{ .id = 3, .parent = 2, .label = .{ .kind = .scan }, .detail = "SCAN b" },
        .{ .id = 4, .parent = 4, .label = .{ .kind = .scan }, .detail = "SCAN c" },
        .{ .id = 5, .parent = 99, .label = .{ .kind = .scan }, .detail = "SCAN d" },
    };
    const plan: Plan = .{ .rows = @constCast(&looped) };
    try testing.expectEqual(@as(usize, 4), planDepth(plan, looped[0]));
    try testing.expectEqual(@as(usize, 4), planDepth(plan, looped[2]));
    try testing.expectEqual(@as(usize, 0), planDepth(plan, looped[3]));
}

test "the kv summary keeps every line of the single-format summary" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]cli_args.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "secret" } },
    };
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
        .counters = .{ .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: TimeReport = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeReport(&stdout, .kv, header, before, after, outcome, report);
    try testing.expectEqualStrings(
        \\db: db.sqlite
        \\select: select.sql
        \\index-sql: index.sql
        \\measured-on: baseline (candidate index not applied)
        \\rows: 2
        \\sqlite: 0.0.0
        \\sqlite-source-id: test-source-id
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\fullscan-steps: 199999
        \\vm-steps: 600407
        \\sort-ops: 0
        \\autoindex-rows: 0
        \\measured-on: variant (candidate index applied)
        \\rows: 2
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\fullscan-steps: 0
        \\vm-steps: 710
        \\sort-ops: 0
        \\autoindex-rows: 0
        \\result: match (row multiset)
        \\row-order: same (reference only; not part of the result)
        \\bind: 1:int
        \\bind: 2:text (6 bytes)
        \\measure-runs: 10 per copy
        \\measure-warmup: 1 per copy (the run whose rows were compared, not timed)
        \\measure-order: rounds alternate baseline-variant and variant-baseline (ABBA)
        \\measure-scope: sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed
        \\measure-cache: warm; each copy reuses its connection and page cache, and its file was just written
        \\work-dir-parent: /tmp
        \\zig:
    ++ " " ++ builtin.zig_version_string ++ "\nbuild-mode: " ++ @tagName(builtin.mode) ++ "\nos-arch: " ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch) ++ "\n" ++
        \\time-baseline-ns: median=4331750 p25=4158324 p75=4364397 min=4098250 max=4465958 (median 4.33 ms)
        \\time-variant-ns: median=37292 p25=33198 p75=40417 min=28583 max=71583 (median 37.29 us)
        \\time-ratio: 0.009 (variant median / baseline median)
        \\variant-faster-rounds: 10/10
        \\db-bytes-baseline: 5087232 (the snapshot file)
        \\db-bytes-variant: 7258112 (the snapshot file with the candidate index)
        \\db-bytes-increase: 2170880 (the whole database file, not the index alone)
        \\time-verdict: improved
        \\
    , stdout.buffered());
}
