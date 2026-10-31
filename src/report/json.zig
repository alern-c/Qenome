const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const contract = @import("../contract/values.zig");
const result = @import("../result.zig");
const cli_comparison = @import("../cli/comparison.zig");
const cli_timing = @import("../cli/timing.zig");
const cli_warnings = @import("../cli/warnings.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const Header = model.Header;
const Report = model.Report;
const Seed = model.Seed;
const Error = model.Error;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const Verdict = model.Verdict;
const d1_caution = format.d1_caution;
const measure_warmup = format.measure_warmup;
const measure_order = format.measure_order;
const measure_scope = format.measure_scope;
const measure_cache = format.measure_cache;
const write_measure_warmup = format.write_measure_warmup;
const write_measure_order = format.write_measure_order;
const write_measure_scope = format.write_measure_scope;
const write_measure_cache = format.write_measure_cache;

fn writeJsonD1(json: *std.json.Stringify, allocator: std.mem.Allocator, header: Header) Error!void {
    const d1 = header.d1 orelse return;
    try json.beginObject();
    try json.objectField("binding");
    try writeJsonText(json, allocator, d1.binding);
    try json.objectField("config");
    try writeJsonText(json, allocator, d1.config_path);
    try json.objectField("database_id");
    try writeJsonText(json, allocator, d1.database_id);
    try json.objectField("local_database");
    try writeJsonText(json, allocator, d1.local_path);
    try json.objectField("sqlite_version");
    try writeJsonText(json, allocator, d1.sqlite_version);
    try json.objectField("sqlite_version_note");
    const note = try std.fmt.allocPrint(
        allocator,
        "SQLite {s} here (bundled, runs the comparison) and SQLite {s} in D1; plans and times can differ",
        .{ header.sqlite_version, d1.sqlite_version },
    );
    try writeJsonText(json, allocator, note);
    try json.objectField("caution");
    try writeJsonText(json, allocator, d1_caution);
    try json.endObject();
}

pub const JsonStyle = enum { indented, minified };

pub fn writeJsonReport(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
    report: Report,
) Error!void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonTo(&out.writer, allocator, header, before, after, outcome, report, .indented);
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

pub fn writeJsonTo(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
    report: Report,
    style: JsonStyle,
) Error!void {
    return writeJsonComparison(writer, allocator, header, before, after, outcome, report, style);
}

pub fn writeJsonVariantOnlyTo(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    after: Measurement,
    report: Report,
    style: JsonStyle,
) Error!void {
    return writeJsonComparison(writer, allocator, header, null, after, null, report, style);
}

fn writeJsonComparison(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: ?Measurement,
    after: Measurement,
    outcome: ?Outcome,
    report: Report,
    style: JsonStyle,
) Error!void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{
            .whitespace = if (style == .indented) .indent_2 else .minified,
            .escape_unicode = true,
        },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(contract.schema_version);
    try json.objectField("exit_code");
    try json.write(header.exit_code);
    try json.objectField("statement");
    try json.write(if (header.write_path != null) "write" else "select");
    try json.objectField("verdict");
    try json.write(report.judgement.verdict.text());
    try json.objectField("verdict_reasons");
    try json.beginArray();
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try writeJsonText(&json, allocator, reason);
    }
    try json.endArray();
    try json.objectField("result");
    try json.write(if (outcome) |value| resultText(value.verdict) else "incomparable");
    try json.objectField("row_order");
    try json.write(if (outcome) |value| rowOrderText(value) else "not-applicable");
    try json.objectField("result_reasons");
    if (outcome) |value| {
        try writeJsonReasons(&json, allocator, value);
    } else {
        try json.beginArray();
        try json.endArray();
    }
    try json.objectField("row_differences");
    try writeJsonRowDifferences(&json, allocator, if (outcome) |value| value.comparison else null, header.show_rows);
    try json.objectField("plan_changed");
    try json.write(if (before) |value| !cli_comparison.samePlan(value.plan, after.plan) else true);
    try json.objectField("baseline");
    if (before) |value| {
        try writeJsonMeasurement(&json, allocator, value, header.write_path != null);
    } else {
        try json.write(null);
    }
    try json.objectField("variant");
    try writeJsonMeasurement(&json, allocator, after, header.write_path != null);
    try json.objectField("timing");
    if (report.timing) |timing| {
        try writeJsonTiming(&json, timing);
    } else {
        try json.write(null);
    }
    try json.objectField("warnings");
    try json.beginArray();
    const enabled = [_]bool{ report.warnings.no_analyze_stats, report.warnings.data_too_small };
    for (enabled, contract.warning_codes, contract.warning_messages) |active, code, message| {
        if (!active) continue;
        try json.write(.{ .code = code, .message = message });
    }
    if (report.warnings.bind_dependent_partial_index) |name| {
        const message = try std.fmt.allocPrint(allocator, contract.bind_dependent_partial_index_message, .{name});
        defer allocator.free(message);
        try json.beginObject();
        try json.objectField("code");
        try json.write(contract.code.bind_dependent_partial_index);
        try json.objectField("message");
        try writeJsonText(&json, allocator, message);
        try json.endObject();
    }
    if (report.warnings.unapplied_migrations) |pending| {
        const message = try cli_warnings.unappliedMigrationsMessage(allocator, pending);
        defer allocator.free(message);
        try json.beginObject();
        try json.objectField("code");
        try json.write(contract.code.unapplied_migrations);
        try json.objectField("message");
        try writeJsonText(&json, allocator, message);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("size_bytes");
    try json.beginObject();
    try json.objectField("baseline");
    try json.write(report.sizes.baseline);
    try json.objectField("variant");
    try json.write(report.sizes.variant);
    try json.objectField("increase");
    try json.write(@as(i128, report.sizes.variant) - @as(i128, report.sizes.baseline));
    try json.endObject();
    try json.objectField("inputs");
    try json.beginObject();
    try json.objectField("database");
    try writeJsonText(&json, allocator, header.database_path);
    if (header.write_path) |path| {
        try json.objectField("write");
        try writeJsonText(&json, allocator, path);
    } else {
        try json.objectField("select");
        try writeJsonText(&json, allocator, header.select_path);
    }
    try json.objectField("index_sql");
    try writeJsonText(&json, allocator, header.index_path);
    try json.endObject();
    if (header.seed) |seed| {
        try json.objectField("seed_data");
        try writeJsonSeed(&json, allocator, seed);
    }
    try json.objectField("environment");
    try json.beginObject();
    try json.objectField("qenome_version");
    try json.write(header.qenome_version);
    try json.objectField("sqlite_version");
    try writeJsonText(&json, allocator, std.mem.span(header.sqlite_version));
    try json.objectField("sqlite_source_id");
    try writeJsonText(&json, allocator, std.mem.span(header.sqlite_source_id));
    try json.objectField("zig_version");
    try json.write(builtin.zig_version_string);
    try json.objectField("build_mode");
    try json.write(@tagName(builtin.mode));
    try json.objectField("os");
    try json.write(@tagName(builtin.os.tag));
    try json.objectField("arch");
    try json.write(@tagName(builtin.cpu.arch));
    try json.objectField("work_dir_parent");
    try writeJsonText(&json, allocator, header.work_parent);
    try json.endObject();
    if (header.d1 != null) {
        try json.objectField("d1");
        try writeJsonD1(&json, allocator, header);
    }
    try json.objectField("measurement");
    try json.beginObject();
    try json.objectField("runs_per_copy");
    try json.write(if (header.write_path != null)
        report.write_runs
    else if (report.timing) |timing|
        timing.rounds
    else
        0);
    try json.objectField("warmup");
    try json.write(if (header.write_path != null) write_measure_warmup else measure_warmup);
    try json.objectField("order");
    try json.write(if (header.write_path != null) write_measure_order else measure_order);
    try json.objectField("scope");
    try json.write(if (header.write_path != null) write_measure_scope else measure_scope);
    try json.objectField("cache");
    try json.write(if (header.write_path != null) write_measure_cache else measure_cache);
    try json.endObject();
    try json.objectField("binds");
    try writeJsonBinds(&json, allocator, header);
    try json.endObject();
}

fn resultText(verdict: Verdict) []const u8 {
    return switch (verdict) {
        .match => "match",
        .mismatch => "mismatch",
        .incomparable => "incomparable",
    };
}

fn rowOrderText(outcome: Outcome) []const u8 {
    if (outcome.verdict != .match) return "not-applicable";
    return if (outcome.comparison.?.same_order) "same" else "differs";
}

pub fn writeJsonSeed(json: *std.json.Stringify, allocator: std.mem.Allocator, seed: Seed) Error!void {
    try json.beginObject();
    try json.objectField("path");
    try writeJsonText(json, allocator, seed.path);
    try json.objectField("seed");
    try json.write(seed.seed);
    try json.objectField("rows");
    try json.write(seed.rows);
    try json.objectField("tables");
    try json.beginArray();
    for (seed.tables) |table| {
        try json.beginObject();
        try json.objectField("table");
        try writeJsonText(json, allocator, table.table);
        try json.objectField("rows");
        try json.write(table.rows);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn writeJsonReasons(json: *std.json.Stringify, allocator: std.mem.Allocator, outcome: Outcome) Error!void {
    try json.beginArray();
    for (outcome.reasons[0..outcome.reason_count]) |reason| {
        try json.beginObject();
        try json.objectField("text");
        try writeJsonText(json, allocator, reason.text);
        try json.objectField("hint");
        if (reason.hint) |hint| {
            try writeJsonText(json, allocator, hint);
        } else {
            try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn writeJsonRowDifferences(
    json: *std.json.Stringify,
    allocator: std.mem.Allocator,
    comparison: ?result.Comparison,
    show_rows: bool,
) Error!void {
    try json.beginObject();
    try json.objectField("baseline_only");
    try json.write(if (comparison) |value| value.baseline_only else 0);
    try json.objectField("variant_only");
    try json.write(if (comparison) |value| value.variant_only else 0);
    try json.objectField("baseline_only_examples");
    try json.beginArray();
    if (show_rows) {
        if (comparison) |value| {
            for (value.baselineExamples()) |row| try writeJsonRow(json, allocator, row);
        }
    }
    try json.endArray();
    try json.objectField("variant_only_examples");
    try json.beginArray();
    if (show_rows) {
        if (comparison) |value| {
            for (value.variantExamples()) |row| try writeJsonRow(json, allocator, row);
        }
    }
    try json.endArray();
    try json.endObject();
}

fn writeJsonRow(json: *std.json.Stringify, allocator: std.mem.Allocator, row: []const u8) Error!void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try result.writeRow(&out.writer, row);
    try json.write(out.written());
}

fn writeJsonMeasurement(
    json: *std.json.Stringify,
    allocator: std.mem.Allocator,
    measurement: Measurement,
    write: bool,
) Error!void {
    try json.beginObject();
    try json.objectField("rows");
    try json.write(measurement.rows);
    try json.objectField("plan");
    try json.beginArray();
    for (measurement.plan.rows) |row| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(row.id);
        try json.objectField("parent");
        try json.write(row.parent);
        try json.objectField("kind");
        try json.write(@tagName(row.label.kind));
        try json.objectField("covering");
        try json.write(row.label.covering);
        try json.objectField("automatic");
        try json.write(row.label.automatic);
        try json.objectField("detail");
        try writeJsonText(json, allocator, row.detail);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("counters");
    try json.beginObject();
    try json.objectField("rows_read");
    try json.write(measurement.counters.rows_read);
    try json.objectField("rows_written");
    try json.write(measurement.counters.rows_written);
    try json.objectField("fullscan_steps");
    try json.write(measurement.counters.fullscan_steps);
    try json.objectField("vm_steps");
    try json.write(measurement.counters.vm_steps);
    try json.objectField("sort_ops");
    try json.write(measurement.counters.sort_ops);
    try json.objectField("autoindex_rows");
    try json.write(measurement.counters.autoindex_rows);
    try json.endObject();
    if (write) {
        try json.objectField("changes");
        try json.write(measurement.changes);
        try json.objectField("total_changes");
        try json.write(measurement.total_changes);
        try json.objectField("executions");
        try json.write(measurement.executions);
    }
    try json.endObject();
}

fn writeJsonTiming(json: *std.json.Stringify, timing: model.TimeSummary) Error!void {
    try json.beginObject();
    try json.objectField("rounds");
    try json.write(timing.rounds);
    try json.objectField("noise_band");
    try json.write(timing.evidence.noise_band);
    try json.objectField("confidence_interval");
    try json.write(timing.evidence.confidence_interval);
    try json.objectField("median_difference_ns");
    try json.write(timing.evidence.median_difference_ns);
    try json.objectField("effect");
    try json.write(cli_timing.effectText(timing.evidence.effect));
    try json.objectField("unavailable_reason");
    try json.write(timing.evidence.unavailable_reason);
    try json.objectField("variant_faster_rounds");
    try json.write(timing.variant_faster_rounds);
    try json.objectField("ratio");
    if (timing.baseline.median == 0) {
        try json.write(null);
    } else {
        const ratio = @as(f64, @floatFromInt(timing.variant.median)) / @as(f64, @floatFromInt(timing.baseline.median));
        try json.write(ratio);
    }
    try json.objectField("baseline");
    try writeJsonStats(json, timing.baseline);
    try json.objectField("variant");
    try writeJsonStats(json, timing.variant);
    try json.endObject();
}

fn writeJsonStats(json: *std.json.Stringify, stats: model.Stats) Error!void {
    try json.beginObject();
    try json.objectField("median_ns");
    try json.write(stats.median);
    try json.objectField("p25_ns");
    try json.write(stats.p25);
    try json.objectField("p75_ns");
    try json.write(stats.p75);
    try json.objectField("min_ns");
    try json.write(stats.min);
    try json.objectField("max_ns");
    try json.write(stats.max);
    try json.endObject();
}

fn writeJsonBinds(json: *std.json.Stringify, allocator: std.mem.Allocator, header: Header) Error!void {
    try json.beginArray();
    for (header.binds) |bind| {
        try json.beginObject();
        try json.objectField("number");
        try json.write(bind.number);
        try json.objectField("type");
        switch (bind.value) {
            .int => |value| {
                try json.write("int");
                if (header.show_binds) {
                    try json.objectField("value");
                    try json.write(value);
                }
            },
            .real => |value| {
                try json.write("real");
                if (header.show_binds) {
                    try json.objectField("value");
                    if (std.math.isFinite(value)) {
                        try json.write(value);
                    } else {
                        try writeJsonText(json, allocator, nonFiniteRealText(value));
                    }
                }
            },
            .text => |value| {
                try json.write("text");
                try json.objectField("text_bytes");
                try json.write(value.len);
                if (header.show_binds) {
                    try json.objectField("value");
                    try writeJsonText(json, allocator, value);
                }
            },
            .null => {
                try json.write("null");
                if (header.show_binds) {
                    try json.objectField("value");
                    try json.write(null);
                }
            },
        }
        try json.endObject();
    }
    try json.endArray();
}

fn nonFiniteRealText(value: f64) []const u8 {
    if (std.math.isNan(value)) return "nan";
    return if (value > 0) "inf" else "-inf";
}

pub fn writeJsonText(json: *std.json.Stringify, allocator: std.mem.Allocator, value: []const u8) Error!void {
    if (std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, '\\') == null) {
        try json.write(value);
        return;
    }
    const escaped = try escapeInvalidUtf8(allocator, value);
    defer allocator.free(escaped);
    try json.write(escaped);
}

fn escapeInvalidUtf8(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var rest = value;
    while (rest.len != 0) {
        const byte = rest[0];
        if (byte < 0x80) {
            if (byte == '\\') try out.writer.writeAll("\\\\") else try out.writer.writeByte(byte);
            rest = rest[1..];
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (len != 0 and len <= rest.len and std.unicode.utf8ValidateSlice(rest[0..len])) {
            try out.writer.writeAll(rest[0..len]);
            rest = rest[len..];
            continue;
        }
        var digits: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "\\x{x:0>2}", .{byte}) catch unreachable;
        try out.writer.writeAll(text);
        rest = rest[1..];
    }
    return try out.toOwnedSlice();
}

test {
    _ = @import("json_tests.zig");
}
