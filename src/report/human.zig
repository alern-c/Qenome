const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const contract = @import("../contract/values.zig");
const result = @import("../result.zig");
const cli_comparison = @import("../cli/comparison.zig");
const cli_warnings = @import("../cli/warnings.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const Header = model.Header;
const Report = model.Report;
const Warnings = model.Warnings;
const Error = model.Error;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const Plan = model.Plan;
const PlanRow = model.PlanRow;
const TimeEffect = model.TimeEffect;
const improved_select = std.fmt.comptimePrint(
    "improved: the rows match and at least {d}% fewer rows were read",
    .{contract.min_read_gain_percent},
);
const improved_write = std.fmt.comptimePrint(
    "improved: the RETURNING rows match and at least {d}% fewer rows were read",
    .{contract.min_read_gain_percent},
);
const below_min_select = std.fmt.comptimePrint(
    "no-effect: the rows match, but the read reduction is below {d}%",
    .{contract.min_read_gain_percent},
);
const below_min_write = std.fmt.comptimePrint(
    "no-effect: the RETURNING rows match, but the read reduction is below {d}%",
    .{contract.min_read_gain_percent},
);
const line_width = format.line_width;
const value_column = format.value_column;
const d1_caution = format.d1_caution;
const writeD1VersionNote = format.writeD1VersionNote;
const writeBind = format.writeBind;
const writeIndent = format.writeIndent;
const writeWrapped = format.writeWrapped;
const writeLabel = format.writeLabel;
const writeField = format.writeField;
const writeCount = format.writeCount;
const writeSigned = format.writeSigned;
const writeMebibytes = format.writeMebibytes;
const writeDuration = format.writeDuration;

const debug_note = "  debug build (no optimization): the times are slower than a release build\n";

const row_order_differs = "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";

fn writeHumanWarnings(stdout: *Io.Writer, allocator: std.mem.Allocator, warnings: Warnings) Error!void {
    if (!cli_warnings.anyWarnings(warnings)) return;
    try stdout.writeAll("\nWarnings\n");
    const enabled = [_]bool{ warnings.no_analyze_stats, warnings.data_too_small };
    for (enabled, contract.warning_codes, contract.warning_messages) |active, code, message| {
        if (!active) continue;
        const text = if (std.mem.eql(u8, code, contract.code.data_too_small))
            if (warnings.small_data) |detail| detail.message else message
        else
            message;
        try writeHumanWarning(stdout, allocator, code, text);
    }
    if (warnings.bind_dependent_partial_index) |name| {
        const message = try cli_warnings.bindDependentPartialIndexMessage(allocator, name);
        defer allocator.free(message);
        try writeHumanWarning(stdout, allocator, contract.code.bind_dependent_partial_index, message);
    }
    if (warnings.unapplied_migrations) |pending| {
        const message = try cli_warnings.unappliedMigrationsText(allocator, pending);
        defer allocator.free(message);
        try writeHumanWarning(stdout, allocator, contract.code.unapplied_migrations, message);
    }
}

pub fn writeHumanWarning(stdout: *Io.Writer, allocator: std.mem.Allocator, code: []const u8, message: []const u8) Error!void {
    const line = try std.fmt.allocPrint(allocator, "warning: {s}: {s}", .{ code, message });
    defer allocator.free(line);
    try writeIndent(stdout, 2);
    try writeWrapped(stdout, line, 2, 4);
    try stdout.writeByte('\n');
}

fn writeD1Human(stdout: *Io.Writer, header: Header) Io.Writer.Error!void {
    const d1 = header.d1 orelse return;
    try stdout.writeAll("\nD1\n");
    try writeField(stdout, "binding", d1.binding);
    try writeField(stdout, "config", d1.config_path);
    try writeField(stdout, "database id", d1.database_id);
    try writeField(stdout, "local file", d1.local_path);
    var buffer: [512]u8 = undefined;
    var note = Io.Writer.fixed(&buffer);
    try writeD1VersionNote(&note, header.sqlite_version, d1.sqlite_version);
    try writeField(stdout, "sqlite", note.buffered());
    try writeField(stdout, "caution", d1_caution);
}

pub fn writeHumanSummary(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
    report: Report,
) Error!void {
    try writeOverview(stdout, header, before, after, outcome, report);
    if (header.d1 != null) try writeD1Human(stdout, header);
    try stdout.writeByte('\n');
    try writeSideBySide(stdout, before, after, report, header.write_path != null);
    try stdout.writeAll("\nQuery plan\n");
    try stdout.writeAll("  baseline (candidate index not applied)\n");
    try writePlan(stdout, before.plan);
    try stdout.writeAll("  variant (candidate index applied)\n");
    try writePlan(stdout, after.plan);
    if (outcome.verdict != .match or !outcome.comparison.?.same_order) {
        try stdout.writeAll("\nResult rows\n");
        try writeRowsDetail(stdout, outcome, header.show_rows);
    }
    try writeHumanWarnings(stdout, allocator, report.warnings);
}

fn writeOverview(
    stdout: *Io.Writer,
    header: Header,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
    report: Report,
) Io.Writer.Error!void {
    try stdout.writeAll("Summary\n");
    if (header.write_path) |path| try writeField(stdout, "write", path);
    try writeField(stdout, "result rows", switch (outcome.verdict) {
        .match => "match (the same rows on both copies)",
        .mismatch => "MISMATCH (the rows differ; the cause is not determined)",
        .incomparable => "INCOMPARABLE (the rows cannot be compared; see Result rows)",
    });
    var rows_buffer: [64]u8 = undefined;
    var rows_text = Io.Writer.fixed(&rows_buffer);
    if (header.write_path != null) {
        try writeRowPair(&rows_text, before.rows, after.rows);
        try writeField(stdout, "returning rows", rows_text.buffered());
        rows_text = Io.Writer.fixed(&rows_buffer);
    }
    try writeRowPair(&rows_text, before.counters.rows_read, after.counters.rows_read);
    try writeField(stdout, "rows read", rows_text.buffered());
    rows_text = Io.Writer.fixed(&rows_buffer);
    try writeRowPair(&rows_text, before.counters.rows_written, after.counters.rows_written);
    try writeField(stdout, "rows written", rows_text.buffered());
    if (header.write_path != null) {
        rows_text = Io.Writer.fixed(&rows_buffer);
        try writeRowPair(&rows_text, before.changes, after.changes);
        try writeField(stdout, "rows changed", rows_text.buffered());
        rows_text = Io.Writer.fixed(&rows_buffer);
        try writeRowPair(&rows_text, before.total_changes, after.total_changes);
        try writeField(stdout, "total changed", rows_text.buffered());
        rows_text = Io.Writer.fixed(&rows_buffer);
        try rows_text.print("{d} per copy (each run rolled back)", .{before.executions});
        try writeField(stdout, "write runs", rows_text.buffered());
    }
    const writing = header.write_path != null;
    const same_reads = before.counters.rows_read == after.counters.rows_read;
    try writeField(stdout, "verdict", switch (report.judgement.verdict) {
        .improved => if (writing) improved_write else improved_select,
        .no_effect => if (writing and same_reads)
            "no-effect: the RETURNING rows match, and both copies read and write the same rows"
        else if (writing)
            below_min_write
        else if (same_reads)
            "no-effect: the rows match, and the variant reads the same rows"
        else
            below_min_select,
        .needs_check => "needs-check:",
        .regressed => "regressed:",
        .not_judged => "not-judged:",
    });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try writeIndent(stdout, value_column);
        try stdout.writeAll("- ");
        try writeWrapped(stdout, reason, value_column + 2, value_column + 2);
        try stdout.writeByte('\n');
    }
    if (report.warnings.small_data) |detail| {
        var buffer: [768]u8 = undefined;
        var text = Io.Writer.fixed(&buffer);
        const scan = if (detail.full_scan) " A full scan reads every row, so this count does not mean a missing index is harmless." else "";
        if (text.print("{s} has {d} rows, fewer than 1000 rows.{s}", .{ detail.table, detail.rows, scan })) {
            try writeField(stdout, "data", text.buffered());
        } else |_| {
            try writeField(stdout, "data", "TOO SMALL: fewer than 1000 rows");
        }
        try writeField(stdout, "next", detail.next_command);
    }
    try writeField(stdout, "query plan", if (cli_comparison.samePlan(before.plan, after.plan))
        "the same on both copies"
    else
        "changed on the variant");
    if (header.seed) |seed| {
        try writeField(stdout, "seed data", seed.path);
        var seed_buffer: [256]u8 = undefined;
        var seed_text = Io.Writer.fixed(&seed_buffer);
        const table_word = if (seed.tables.len == 1) "table" else "tables";
        try seed_text.print("seed {d}, {d} rows in {d} {s}", .{ seed.seed, seed.rows, seed.tables.len, table_word });
        try writeField(stdout, "seed", seed_text.buffered());
    }

    var buffer: [256]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    if (report.timing) |timing| {
        try text.writeAll("median ");
        try writeDuration(&text, timing.baseline.median);
        try text.writeAll(" -> ");
        try writeDuration(&text, timing.variant.median);
        try text.writeAll("; ");
        try writeTimeAssessment(&text, timing.baseline.median, timing.variant.median, timing.evidence.effect);
    } else if (header.write_path != null) {
        try text.writeAll("not timed (write mode; every run is rolled back and no timing rounds are run)");
    } else {
        try text.writeAll("not measured (0 rounds; reference only)");
    }
    try writeField(stdout, "time", text.buffered());
    if (report.timing) |timing| {
        text = Io.Writer.fixed(&buffer);
        try text.writeAll("A/A p95 ");
        try writeDuration(&text, timing.evidence.noise_band.threshold_ns);
        try text.print(" over {d} pairs (empirical; reference only)", .{timing.evidence.noise_band.pairs});
        try writeField(stdout, "time noise", text.buffered());
    }

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
    before: Measurement,
    after: Measurement,
    report: Report,
    write: bool,
) Io.Writer.Error!void {
    try stdout.print("{s:<22}{s:>16}{s:>16}{s:>16}\n", .{ "Baseline vs variant", "baseline", "variant", "change" });
    try writeCountRow(stdout, "rows read", before.counters.rows_read, after.counters.rows_read);
    try writeCountRow(stdout, "rows written", before.counters.rows_written, after.counters.rows_written);
    if (write) {
        try writeCountRow(stdout, "rows changed", before.changes, after.changes);
        try writeCountRow(stdout, "total changed", before.total_changes, after.total_changes);
    }
    try writeCountRow(stdout, if (write) "returning rows" else "result rows", before.rows, after.rows);
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

fn writeRowPair(writer: *Io.Writer, baseline: u64, variant: u64) Io.Writer.Error!void {
    try writeCount(writer, baseline);
    try writer.writeAll(" -> ");
    try writeCount(writer, variant);
}

pub fn writeTimeAssessment(writer: *Io.Writer, baseline: u64, variant: u64, effect: TimeEffect) Io.Writer.Error!void {
    switch (effect) {
        .faster, .slower => {
            const direction: []const u8 = if (effect == .faster) "faster" else "slower";
            if (baseline == variant) {
                try writer.print("{s} in the paired rounds (the medians are equal; reference only)", .{direction});
                return;
            }
            const same_direction = if (effect == .faster) variant < baseline else variant > baseline;
            if (!same_direction) {
                try writer.print("{s} in the paired rounds (the medians differ in the other direction; reference only)", .{direction});
                return;
            }
            try writeRatioMagnitude(writer, baseline, variant);
            try writer.print(" {s} (reference only)", .{direction});
        },
        .no_difference => try writer.writeAll("no clear difference in the paired rounds (reference only)"),
        .insufficient_samples => {
            if (baseline == 0 or variant == 0) {
                try writer.writeAll("median ratio n/a (the paired rounds cannot judge the direction; reference only)");
                return;
            }
            try writer.writeAll("median ratio ");
            try writeRatioMagnitude(writer, baseline, variant);
            try writer.writeAll(" (the paired rounds cannot judge the direction; reference only)");
        },
    }
}

fn writeRatioMagnitude(writer: *Io.Writer, baseline: u64, variant: u64) Io.Writer.Error!void {
    const larger = @max(baseline, variant);
    const smaller = @min(baseline, variant);
    const ratio = @as(f64, @floatFromInt(larger)) / @as(f64, @floatFromInt(smaller));
    if (ratio >= 10) return writer.print("{d:.0}x", .{ratio});
    if (ratio >= 2) return writer.print("{d:.1}x", .{ratio});
    return writer.print("{d:.2}x", .{ratio});
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

pub fn planDepth(plan: Plan, row: PlanRow) usize {
    var depth: usize = 0;
    var parent = row.parent;
    while (depth < plan.rows.len) {
        const line = cli_comparison.parentLine(plan, parent) orelse break;
        depth += 1;
        parent = plan.rows[line].parent;
    }
    return depth;
}

fn writeRowsDetail(stdout: *Io.Writer, outcome: Outcome, show_rows: bool) Io.Writer.Error!void {
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
        try writeExamples(stdout, "baseline only", comparison.baseline_only, comparison.baselineExamples(), show_rows);
        try writeExamples(stdout, "variant only", comparison.variant_only, comparison.variantExamples(), show_rows);
        if (!show_rows and (comparison.baselineExamples().len != 0 or comparison.variantExamples().len != 0)) {
            try writeField(stdout, "examples", "rerun with --show-rows to see them");
        }
    };
}

fn writeExamples(stdout: *Io.Writer, label: []const u8, count: usize, examples: []const []const u8, show_rows: bool) Io.Writer.Error!void {
    var buffer: [64]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    try writeCount(&text, count);
    try text.writeAll(if (count == 1) " row" else " rows");
    if (show_rows and examples.len != 0) try text.print(", the first {d} below", .{examples.len});
    try writeField(stdout, label, text.buffered());
    if (!show_rows) return;
    for (examples) |row| {
        try writeIndent(stdout, value_column);
        try result.writeRow(stdout, row);
        try stdout.writeByte('\n');
    }
}

test {
    _ = @import("human_tests.zig");
}
