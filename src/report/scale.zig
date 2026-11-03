const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const result = @import("../result.zig");
const cli_warnings = @import("../cli/warnings.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const report_json = @import("json.zig");
const scale_trend = @import("scale_trend.zig");

const Verdict = model.Verdict;
const Warnings = model.Warnings;
const Step = model.ScaleStep;
const Report = model.ScaleReport;
const Error = model.Error;
const writeField = format.writeField;
const writeCount = format.writeCount;
const writeDuration = format.writeDuration;
const writeIndent = format.writeIndent;
const writeWrapped = format.writeWrapped;

const note = "note: the rows and the trend come from generated data measured on this machine; they are not production D1 billing.";

const value_column = 22;

const value_indent = 22;

const Found = struct {
    code: []const u8,
    text: []const u8,
    named: bool = false,
};

fn writeStepCounts(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    try stdout.writeAll("scale: ");
    for (report.scale, 0..) |value, index| {
        if (index != 0) try stdout.writeAll(", ");
        try writeCount(stdout, value);
    }
    try stdout.print(" rows in {d} steps\n", .{report.steps.len});
}

fn writeInputs(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    try writeStepCounts(stdout, report);
    try stdout.print("database: {s}\n", .{report.header.database_path});
    if (report.header.write_path) |path| {
        try stdout.print("write: {s}\n", .{path});
    } else {
        try stdout.print("select: {s}\n", .{report.header.select_path});
    }
    try stdout.print("index: {s}\n", .{report.header.index_path});
    try stdout.print("seed-data: {s}\n", .{report.seed_path});
    try stdout.print("sqlite: {s}\n", .{report.header.sqlite_version});
    try stdout.print("work-dir-parent: {s}\n", .{report.header.work_parent});
    if (report.header.show_binds and report.header.binds.len != 0) {
        try stdout.writeAll("binds: ");
        for (report.header.binds, 0..) |bind, index| {
            if (index != 0) try stdout.writeAll(", ");
            try format.writeBind(stdout, bind, true);
        }
        try stdout.writeByte('\n');
    }
}

fn resultText(verdict: Verdict) []const u8 {
    return switch (verdict) {
        .match => "match",
        .mismatch => "mismatch",
        .incomparable => "incomparable",
    };
}

fn cell(writer: *Io.Writer, baseline: u64, variant: u64, separator: []const u8) Io.Writer.Error!void {
    try writeCount(writer, baseline);
    try writer.writeAll(separator);
    try writeCount(writer, variant);
}

fn writeRatio(writer: *Io.Writer, baseline: u64, variant: u64) Io.Writer.Error!void {
    if (baseline == 0) return writer.writeAll("n/a");
    const ratio = @as(f64, @floatFromInt(variant)) / @as(f64, @floatFromInt(baseline));
    if (ratio >= 1) return writer.print("{d:.2}x", .{ratio});
    if (ratio >= 0.1) return writer.print("{d:.3}x", .{ratio});
    return writer.print("{d:.4}x", .{ratio});
}

fn writeTable(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    const write = report.header.write_path != null;
    try stdout.writeAll("\nSteps\n");
    try stdout.print("  {s:>12}{s:>14}{s:>13}{s:>8}", .{ "rows", "baseline read", "variant read", "ratio" });
    if (write) try stdout.print("{s:>16}", .{"written"});
    try stdout.print("  {s:<12}{s:<13}{s:<8}{s}\n", .{ "verdict", "result", "plan", "median" });

    for (report.steps) |step| {
        var cells: [5][48]u8 = undefined;
        var rows_text = Io.Writer.fixed(&cells[0]);
        var baseline_text = Io.Writer.fixed(&cells[1]);
        var variant_text = Io.Writer.fixed(&cells[2]);
        var ratio_text = Io.Writer.fixed(&cells[3]);
        var written_text = Io.Writer.fixed(&cells[4]);
        try writeCount(&rows_text, step.rows);
        try writeCount(&baseline_text, step.before.counters.rows_read);
        try writeCount(&variant_text, step.after.counters.rows_read);
        try writeRatio(&ratio_text, step.before.counters.rows_read, step.after.counters.rows_read);
        if (write) try cell(&written_text, step.before.counters.rows_written, step.after.counters.rows_written, " -> ");
        try stdout.print("  {s:>12}{s:>14}{s:>13}{s:>8}", .{
            rows_text.buffered(),
            baseline_text.buffered(),
            variant_text.buffered(),
            ratio_text.buffered(),
        });
        if (write) try stdout.print("{s:>16}", .{written_text.buffered()});
        var median_buffer: [64]u8 = undefined;
        var median_text = Io.Writer.fixed(&median_buffer);
        if (step.timing) |timing| {
            try writeDuration(&median_text, timing.baseline.median);
            try median_text.writeAll(" -> ");
            try writeDuration(&median_text, timing.variant.median);
        } else {
            try median_text.writeAll("-");
        }
        try stdout.print("  {s:<12}{s:<13}{s:<8}{s}\n", .{
            step.judgement.verdict.text(),
            resultText(step.result),
            if (step.plan_changed) "changed" else "same",
            median_text.buffered(),
        });
    }
}

fn foundAt(warnings: Warnings, code: []const u8) ?Found {
    if (std.mem.eql(u8, code, contract.warning_codes[0])) {
        if (!warnings.no_analyze_stats) return null;
        return .{ .code = code, .text = contract.warning_messages[0] };
    }
    if (std.mem.eql(u8, code, contract.warning_codes[1])) {
        if (!warnings.data_too_small) return null;
        if (warnings.small_data) |detail| return .{ .code = code, .text = detail.message };
        return .{ .code = code, .text = contract.warning_messages[1] };
    }
    const name = warnings.bind_dependent_partial_index orelse return null;
    return .{ .code = code, .text = name, .named = true };
}

fn sameFound(a: Found, b: Found) bool {
    return a.named == b.named and std.mem.eql(u8, a.text, b.text);
}

fn writeWarning(stdout: *Io.Writer, allocator: std.mem.Allocator, rows: ?u64, found: Found) Error!void {
    const message = if (found.named) try cli_warnings.bindDependentPartialIndexMessage(allocator, found.text) else found.text;
    defer if (found.named) allocator.free(message);
    var prefix_buffer: [64]u8 = undefined;
    var prefix = Io.Writer.fixed(&prefix_buffer);
    if (rows) |value| {
        try prefix.writeAll("warning at ");
        try writeCount(&prefix, value);
        try prefix.writeAll(" rows: ");
    } else {
        try prefix.writeAll("warning: ");
    }
    const line = try std.fmt.allocPrint(allocator, "{s}{s}: {s}", .{ prefix.buffered(), found.code, message });
    defer allocator.free(line);
    try writeIndent(stdout, 2);
    try writeWrapped(stdout, line, 2, 4);
    try stdout.writeByte('\n');
}

fn writeWarnings(stdout: *Io.Writer, allocator: std.mem.Allocator, report: Report) Error!void {
    var any = report.unapplied_migrations != null;
    for (report.steps) |step| {
        if (cli_warnings.anyWarnings(step.warnings)) any = true;
    }
    if (!any) return;
    try stdout.writeAll("\nWarnings\n");
    if (report.unapplied_migrations) |pending| {
        const message = try cli_warnings.unappliedMigrationsText(allocator, pending);
        defer allocator.free(message);
        try writeWarning(stdout, allocator, null, .{ .code = contract.code.unapplied_migrations, .text = message });
    }
    for ([_][]const u8{ contract.warning_codes[0], contract.warning_codes[1], contract.code.bind_dependent_partial_index }) |code| {
        var first: ?Found = null;
        var everywhere = true;
        for (report.steps) |step| {
            const found = foundAt(step.warnings, code) orelse {
                everywhere = false;
                continue;
            };
            if (first) |previous| {
                if (!sameFound(previous, found)) everywhere = false;
            } else {
                first = found;
            }
        }
        const found = first orelse continue;
        if (everywhere) {
            try writeWarning(stdout, allocator, null, found);
            continue;
        }
        for (report.steps) |step| {
            const step_found = foundAt(step.warnings, code) orelse continue;
            try writeWarning(stdout, allocator, step.rows, step_found);
        }
    }
}

fn writeRowDifferences(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    if (!report.header.show_rows) return;
    var any = false;
    for (report.steps) |step| {
        if (step.baseline_examples.len != 0 or step.variant_examples.len != 0) any = true;
    }
    if (!any) return;
    try stdout.writeAll("\nRows that differ\n");
    for (report.steps) |step| {
        if (step.result == .match) continue;
        var counts: [96]u8 = undefined;
        var text = Io.Writer.fixed(&counts);
        try writeCount(&text, step.baseline_only);
        try text.writeAll(" only in the baseline, ");
        try writeCount(&text, step.variant_only);
        try text.writeAll(" only in the variant");
        try stdout.print("  {d} rows: {s}\n", .{ step.rows, text.buffered() });
        for (step.baseline_examples) |row| {
            try stdout.writeAll("    baseline only: ");
            try stdout.writeAll(row);
            try stdout.writeByte('\n');
        }
        for (step.variant_examples) |row| {
            try stdout.writeAll("    variant only: ");
            try stdout.writeAll(row);
            try stdout.writeByte('\n');
        }
    }
}

fn writeSeriesValue(stdout: *Io.Writer, label: []const u8, value: []const u8) Io.Writer.Error!void {
    try stdout.print("  {s:<20}", .{label});
    try writeWrapped(stdout, value, value_column, value_indent);
    try stdout.writeByte('\n');
}

fn writeSeriesLine(stdout: *Io.Writer, label: []const u8, series: scale_trend.Series) Io.Writer.Error!void {
    var value_buffer: [256]u8 = undefined;
    var value = Io.Writer.fixed(&value_buffer);
    try value.writeAll(series.class.text());
    if (series.exponents.len != 0) {
        try value.writeAll(" (exponents ");
        for (series.exponents, 0..) |exponent, index| {
            if (index != 0) try value.writeAll(", ");
            try value.print("{d:.3}", .{exponent});
        }
        try value.writeByte(')');
    }
    try writeSeriesValue(stdout, label, value.buffered());
}

fn writeFindings(stdout: *Io.Writer, findings: []const scale_trend.Finding) Error!void {
    if (findings.len == 0) return;
    try stdout.writeAll("\nFindings\n");
    for (findings) |entry| {
        var line_buffer: [512]u8 = undefined;
        var line = Io.Writer.fixed(&line_buffer);
        try line.print("{s}: {s} (steps ", .{ entry.code, entry.message });
        try writeCount(&line, entry.steps[0]);
        try line.writeAll(" and ");
        try writeCount(&line, entry.steps[1]);
        try line.writeByte(')');
        try writeIndent(stdout, 2);
        try writeWrapped(stdout, line.buffered(), 2, 4);
        try stdout.writeByte('\n');
    }
}

fn writeAnalysis(stdout: *Io.Writer, allocator: std.mem.Allocator, report: Report) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const analysis = try scale_trend.analyze(arena_state.allocator(), report.steps);
    try stdout.writeAll("\nTrend\n");
    try writeSeriesLine(stdout, "baseline rows read:", analysis.trend.baseline_rows_read);
    try writeSeriesLine(stdout, "variant rows read:", analysis.trend.variant_rows_read);
    if (analysis.trend.baseline_time) |series| {
        try writeSeriesLine(stdout, "baseline time:", series);
    } else {
        try writeSeriesValue(stdout, "baseline time:", "not timed");
    }
    if (analysis.trend.variant_time) |series| {
        try writeSeriesLine(stdout, "variant time:", series);
    } else {
        try writeSeriesValue(stdout, "variant time:", "not timed");
    }
    try writeFindings(stdout, analysis.findings);
}

fn verdictChanges(report: Report) bool {
    if (report.steps.len == 0) return false;
    const first = report.steps[0].judgement.verdict;
    for (report.steps) |step| {
        if (step.judgement.verdict != first) return true;
    }
    return false;
}

fn writeVerdictChange(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    if (!verdictChanges(report)) return;
    var rows_buffer: [64]u8 = undefined;
    var rows_text = Io.Writer.fixed(&rows_buffer);
    try writeCount(&rows_text, report.steps[0].rows);
    try rows_text.writeAll(" and ");
    try writeCount(&rows_text, report.steps[report.steps.len - 1].rows);
    try stdout.print("\nThe verdict changes between {s} rows.\n", .{rows_text.buffered()});
}

pub fn writeHumanScale(stdout: *Io.Writer, allocator: std.mem.Allocator, report: Report) Error!void {
    try writeInputs(stdout, report);
    try writeTable(stdout, report);
    try writeRowDifferences(stdout, report);
    try writeAnalysis(stdout, allocator, report);
    try writeWarnings(stdout, allocator, report);
    try writeVerdictChange(stdout, report);
    try stdout.writeByte('\n');
    try writeWrapped(stdout, note, 0, 0);
    try stdout.writeByte('\n');
}

fn writeJsonEntry(json: *std.json.Stringify, allocator: std.mem.Allocator, entry: Found) Error!void {
    try json.beginObject();
    try json.objectField("code");
    try report_json.writeJsonText(json, allocator, entry.code);
    try json.objectField("message");
    try report_json.writeJsonText(json, allocator, entry.text);
    try json.endObject();
}

fn writeJsonInputs(json: *std.json.Stringify, allocator: std.mem.Allocator, report: Report) Error!void {
    try json.beginObject();
    try json.objectField("database");
    try report_json.writeJsonText(json, allocator, report.header.database_path);
    if (report.header.write_path) |path| {
        try json.objectField("write");
        try report_json.writeJsonText(json, allocator, path);
    } else {
        try json.objectField("select");
        try report_json.writeJsonText(json, allocator, report.header.select_path);
    }
    try json.objectField("index_sql");
    try report_json.writeJsonText(json, allocator, report.header.index_path);
    try json.objectField("seed_data");
    try report_json.writeJsonText(json, allocator, report.seed_path);
    try json.objectField("scale");
    try json.beginArray();
    for (report.scale) |value| try json.write(value);
    try json.endArray();
    try json.endObject();
}

fn writeJsonStep(json: *std.json.Stringify, allocator: std.mem.Allocator, step: Step) Error!void {
    try json.beginObject();
    try json.objectField("rows");
    try json.write(step.rows);
    try json.objectField("tables");
    try json.beginArray();
    for (step.tables) |table| {
        try json.beginObject();
        try json.objectField("table");
        try report_json.writeJsonText(json, allocator, table.table);
        try json.objectField("rows");
        try json.write(table.rows);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("comparison");
    try json.print("{s}", .{step.comparison_json});
    try json.endObject();
}

fn writeJsonSeries(json: *std.json.Stringify, series: scale_trend.Series) Error!void {
    try json.beginObject();
    try json.objectField("class");
    try json.write(series.class.text());
    try json.objectField("exponents");
    try json.beginArray();
    for (series.exponents) |value| try json.write(value);
    try json.endArray();
    try json.endObject();
}

fn writeAnalysisJson(json: *std.json.Stringify, allocator: std.mem.Allocator, steps: []const Step) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const analysis = try scale_trend.analyze(arena_state.allocator(), steps);
    try json.objectField("trend");
    try json.beginObject();
    try json.objectField("baseline_rows_read");
    try writeJsonSeries(json, analysis.trend.baseline_rows_read);
    try json.objectField("variant_rows_read");
    try writeJsonSeries(json, analysis.trend.variant_rows_read);
    try json.objectField("baseline_time");
    if (analysis.trend.baseline_time) |series| try writeJsonSeries(json, series) else try json.write(null);
    try json.objectField("variant_time");
    if (analysis.trend.variant_time) |series| try writeJsonSeries(json, series) else try json.write(null);
    try json.endObject();
    try json.objectField("findings");
    try json.beginArray();
    for (analysis.findings) |entry| {
        try json.beginObject();
        try json.objectField("code");
        try report_json.writeJsonText(json, allocator, entry.code);
        try json.objectField("message");
        try report_json.writeJsonText(json, allocator, entry.message);
        try json.objectField("steps");
        try json.beginArray();
        for (entry.steps) |value| try json.write(value);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

pub fn writeJsonScale(stdout: *Io.Writer, allocator: std.mem.Allocator, report: Report) Error!void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    try json.objectField("scale_schema_version");
    try json.write(contract.scale_schema_version);
    try json.objectField("exit_code");
    try json.write(report.exit_code);
    try json.objectField("inputs");
    try writeJsonInputs(&json, allocator, report);
    try json.objectField("environment");
    try report_json.writeJsonEnvironment(&json, allocator, report.header);
    try json.objectField("steps");
    try json.beginArray();
    for (report.steps) |step| try writeJsonStep(&json, allocator, step);
    try json.endArray();
    try writeAnalysisJson(&json, allocator, report.steps);
    try json.objectField("warnings");
    try json.beginArray();
    if (report.unapplied_migrations) |pending| {
        const message = try cli_warnings.unappliedMigrationsMessage(allocator, pending);
        defer allocator.free(message);
        try writeJsonEntry(&json, allocator, .{ .code = contract.code.unapplied_migrations, .text = message });
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

test {
    _ = @import("scale_tests.zig");
}
