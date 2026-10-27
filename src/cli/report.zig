const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const result = @import("../result.zig");
const cli_args = @import("args.zig");
const cli_d1 = @import("d1.zig");
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
    show_rows: bool = false,
    exit_code: u8 = 0,
    d1: ?cli_d1.Resolved = null,
};

pub const Sizes = struct {
    baseline: u64 = 0,
    variant: u64 = 0,
};

pub const Warnings = struct {
    no_analyze_stats: bool = false,
    data_too_small: bool = false,
};

const warning_codes = [_][]const u8{ "no_analyze_stats", "data_too_small" };
const warning_messages = [_][]const u8{
    "The candidate index table has no non-empty sqlite_stat1 entry. Test an ANALYZE'd copy with representative data; this check does not run ANALYZE.",
    "The candidate index table has fewer than 1000 rows. This heuristic does not establish representative performance; test with more representative data.",
};

fn writeWarnings(stdout: *Io.Writer, warnings: Warnings) Io.Writer.Error!void {
    const enabled = [_]bool{ warnings.no_analyze_stats, warnings.data_too_small };
    for (enabled, warning_codes, warning_messages) |active, code, message| {
        if (active) try stdout.print("warning: {s}: {s}\n", .{ code, message });
    }
}

fn writeTimeEvidence(stdout: *Io.Writer, evidence: cli_timing.Evidence) Io.Writer.Error!void {
    try stdout.print("time-effect: {s} (reference only)\ntime-median-difference-ns: {d} (variant - baseline, paired rounds)\ntime-noise-band-ns: {d} (baseline A/A absolute difference p95; {d} pairs; empirical)\n", .{ cli_timing.effectText(evidence.effect), evidence.median_difference_ns, evidence.noise_band.threshold_ns, evidence.noise_band.pairs });
    if (evidence.confidence_interval) |ci| {
        try stdout.print("time-confidence-interval-ns: [{d}, {d}] (paired median difference; nominal 95%, binomial coverage {d:.6}; assumes independent identically distributed rounds)\n", .{ ci.lower_ns, ci.upper_ns, ci.coverage });
    } else {
        try stdout.print("time-confidence-interval-ns: unavailable ({s})\n", .{evidence.unavailable_reason orelse "unavailable"});
    }
}

fn writeHumanEvidence(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var text = Io.Writer.fixed(&buffer);
    if (report.timing) |timing| try writeTimeEvidence(&text, timing.evidence);
    try writeWarnings(&text, report.warnings);
    var lines = std.mem.tokenizeScalar(u8, text.buffered(), '\n');
    while (lines.next()) |line| {
        try writeWrapped(stdout, line, 0, 2);
        try stdout.writeByte('\n');
    }
}

pub const Report = struct {
    timing: ?cli_timing.TimeSummary = null,
    sizes: Sizes = .{},
    judgement: cli_comparison.Judgement,
    warnings: Warnings = .{},
};

pub const Error = Io.Writer.Error || std.mem.Allocator.Error;

pub fn writeReport(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    format: cli_args.Format,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: Report,
) Error!void {
    switch (format) {
        .human => try writeHumanSummary(stdout, header, before, after, outcome, report),
        .kv => try writeSummary(stdout, header, before, after, outcome, report),
        .json => try writeJsonReport(stdout, allocator, header, before, after, outcome, report),
    }
}

pub fn writeSummary(
    stdout: *Io.Writer,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: Report,
) Io.Writer.Error!void {
    try stdout.print("db: {s}\nselect: {s}\nindex-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: {d}\n", .{
        header.database_path, header.select_path, header.index_path, before.rows,
    });
    try stdout.print("sqlite: {s}\nsqlite-source-id: {s}\n", .{
        header.sqlite_version, header.sqlite_source_id,
    });
    try writeD1Kv(stdout, header);
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
        if (header.show_rows) {
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
        }
    };
    const order = if (outcome.verdict != .match)
        "not applicable"
    else if (outcome.comparison.?.same_order)
        "same (reference only; not part of the result)"
    else
        "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";
    try stdout.print("row-order: {s}\n", .{order});
    try writeFacts(stdout, header, report);
}

pub fn writeFacts(stdout: *Io.Writer, header: Header, report: Report) Io.Writer.Error!void {
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
        try writeTimeEvidence(stdout, timing.evidence);
        try stdout.print("variant-faster-rounds: {d}/{d}\n", .{ timing.variant_faster_rounds, timing.rounds });
    }
    try writeWarnings(stdout, report.warnings);
    const sizes = report.sizes;
    try stdout.print(
        \\db-bytes-baseline: {d} (the snapshot file)
        \\db-bytes-variant: {d} (the snapshot file with the candidate index)
        \\db-bytes-increase: {d} (the whole database file, not the index alone)
        \\verdict: {s}
        \\
    , .{ sizes.baseline, sizes.variant, @as(i128, sizes.variant) - @as(i128, sizes.baseline), report.judgement.verdict.text() });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try stdout.print("verdict-reason: {s}\n", .{reason});
    }
}

const measure_warmup = "1 per copy (the run whose rows were compared, not timed)";
const measure_order = "each round: baseline-baseline A/A, then alternating baseline-variant or variant-baseline (ABBA)";
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

const d1_caution = "the times are measured on this local copy; they do not guarantee the speed on production D1";

fn writeD1VersionNote(writer: *Io.Writer, header: Header) Io.Writer.Error!void {
    try writer.print(
        "SQLite {s} here (bundled, runs the comparison) and SQLite {s} in D1; plans and times can differ",
        .{ header.sqlite_version, cli_d1.local_engine_sqlite_version },
    );
}

fn writeD1Kv(stdout: *Io.Writer, header: Header) Io.Writer.Error!void {
    const d1 = header.d1 orelse return;
    try stdout.print(
        "d1-binding: {s}\nd1-config: {s}\nd1-database-id: {s}\nd1-local-database: {s}\nd1-sqlite-version: {s}\nd1-sqlite-version-note: ",
        .{ d1.binding, d1.config_path, d1.database_id, d1.local_path, cli_d1.local_engine_sqlite_version },
    );
    try writeD1VersionNote(stdout, header);
    try stdout.print("\nd1-caution: {s}\n", .{d1_caution});
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
    try writeD1VersionNote(&note, header);
    try writeField(stdout, "sqlite", note.buffered());
    try writeField(stdout, "caution", d1_caution);
}

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
    try writeJsonText(json, allocator, cli_d1.local_engine_sqlite_version);
    try json.objectField("sqlite_version_note");
    const note = try std.fmt.allocPrint(
        allocator,
        "SQLite {s} here (bundled, runs the comparison) and SQLite {s} in D1; plans and times can differ",
        .{ header.sqlite_version, cli_d1.local_engine_sqlite_version },
    );
    try writeJsonText(json, allocator, note);
    try json.objectField("caution");
    try writeJsonText(json, allocator, d1_caution);
    try json.endObject();
}

const json_schema_version: u8 = 2;

pub fn writeJsonReport(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: Report,
) Error!void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(json_schema_version);
    try json.objectField("exit_code");
    try json.write(header.exit_code);
    try json.objectField("verdict");
    try json.write(report.judgement.verdict.text());
    try json.objectField("verdict_reasons");
    try json.beginArray();
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try writeJsonText(&json, allocator, reason);
    }
    try json.endArray();
    try json.objectField("result");
    try json.write(resultText(outcome.verdict));
    try json.objectField("row_order");
    try json.write(rowOrderText(outcome));
    try json.objectField("result_reasons");
    try writeJsonReasons(&json, allocator, outcome);
    try json.objectField("row_differences");
    try writeJsonRowDifferences(&json, allocator, outcome.comparison, header.show_rows);
    try json.objectField("plan_changed");
    try json.write(!cli_comparison.samePlan(before.plan, after.plan));
    try json.objectField("baseline");
    try writeJsonMeasurement(&json, allocator, before);
    try json.objectField("variant");
    try writeJsonMeasurement(&json, allocator, after);
    try json.objectField("timing");
    if (report.timing) |timing| {
        try writeJsonTiming(&json, timing);
    } else {
        try json.write(null);
    }
    try json.objectField("warnings");
    try json.beginArray();
    const enabled = [_]bool{ report.warnings.no_analyze_stats, report.warnings.data_too_small };
    for (enabled, warning_codes, warning_messages) |active, code, message| {
        if (!active) continue;
        try json.write(.{ .code = code, .message = message });
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
    try json.objectField("select");
    try writeJsonText(&json, allocator, header.select_path);
    try json.objectField("index_sql");
    try writeJsonText(&json, allocator, header.index_path);
    try json.endObject();
    try json.objectField("environment");
    try json.beginObject();
    try json.objectField("qenome_version");
    try json.write(cli_args.version);
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
    try json.write(if (report.timing) |timing| timing.rounds else 0);
    try json.objectField("warmup");
    try json.write(measure_warmup);
    try json.objectField("order");
    try json.write(measure_order);
    try json.objectField("scope");
    try json.write(measure_scope);
    try json.objectField("cache");
    try json.write(measure_cache);
    try json.endObject();
    try json.objectField("binds");
    try writeJsonBinds(&json, allocator, header);
    try json.endObject();
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

fn resultText(verdict: cli_comparison.Verdict) []const u8 {
    return switch (verdict) {
        .match => "match",
        .mismatch => "mismatch",
        .incomparable => "incomparable",
    };
}

fn rowOrderText(outcome: cli_comparison.Outcome) []const u8 {
    if (outcome.verdict != .match) return "not-applicable";
    return if (outcome.comparison.?.same_order) "same" else "differs";
}

fn writeJsonReasons(json: *std.json.Stringify, allocator: std.mem.Allocator, outcome: cli_comparison.Outcome) Error!void {
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
    measurement: cli_comparison.Measurement,
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
    try json.endObject();
}

fn writeJsonTiming(json: *std.json.Stringify, timing: cli_timing.TimeSummary) Error!void {
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

fn writeJsonStats(json: *std.json.Stringify, stats: cli_timing.Stats) Error!void {
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

fn writeJsonText(json: *std.json.Stringify, allocator: std.mem.Allocator, value: []const u8) Error!void {
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
    try stdout.print("rows-read: {d}\nrows-written: {d}\nfullscan-steps: {d}\nvm-steps: {d}\nsort-ops: {d}\nautoindex-rows: {d}\n", .{
        measurement.counters.rows_read, measurement.counters.rows_written, measurement.counters.fullscan_steps, measurement.counters.vm_steps, measurement.counters.sort_ops, measurement.counters.autoindex_rows,
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
    report: Report,
) Io.Writer.Error!void {
    try writeOverview(stdout, header, before, after, outcome, report);
    if (header.d1 != null) try writeD1Human(stdout, header);
    try stdout.writeByte('\n');
    try writeSideBySide(stdout, before, after, report);
    try stdout.writeAll("\nQuery plan\n");
    try stdout.writeAll("  baseline (candidate index not applied)\n");
    try writePlan(stdout, before.plan);
    try stdout.writeAll("  variant (candidate index applied)\n");
    try writePlan(stdout, after.plan);
    if (outcome.verdict != .match or !outcome.comparison.?.same_order) {
        try stdout.writeAll("\nResult rows\n");
        try writeRowsDetail(stdout, outcome, header.show_rows);
    }
}

fn writeOverview(
    stdout: *Io.Writer,
    header: Header,
    before: cli_comparison.Measurement,
    after: cli_comparison.Measurement,
    outcome: cli_comparison.Outcome,
    report: Report,
) Io.Writer.Error!void {
    try stdout.writeAll("Summary\n");
    try writeField(stdout, "result rows", switch (outcome.verdict) {
        .match => "match (the same rows on both copies)",
        .mismatch => "MISMATCH (the rows differ; the cause is not determined)",
        .incomparable => "INCOMPARABLE (the rows cannot be compared; see Result rows)",
    });
    var rows_buffer: [64]u8 = undefined;
    var rows_text = Io.Writer.fixed(&rows_buffer);
    try writeRowPair(&rows_text, before.counters.rows_read, after.counters.rows_read);
    try writeField(stdout, "rows read", rows_text.buffered());
    rows_text = Io.Writer.fixed(&rows_buffer);
    try writeRowPair(&rows_text, before.counters.rows_written, after.counters.rows_written);
    try writeField(stdout, "rows written", rows_text.buffered());
    try writeField(stdout, "verdict", switch (report.judgement.verdict) {
        .improved => "improved: the rows match, and the variant reads fewer rows",
        .no_effect => "no-effect: the rows match, and the variant reads the same rows",
        .needs_check => "needs-check:",
        .not_judged => "not-judged:",
    });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try writeIndent(stdout, value_column);
        try stdout.writeAll("- ");
        try writeWrapped(stdout, reason, value_column + 2, value_column + 2);
        try stdout.writeByte('\n');
    }
    try writeField(stdout, "query plan", if (cli_comparison.samePlan(before.plan, after.plan))
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
        try text.print("); the variant was faster in {d} of {d} rounds (reference only)", .{ timing.variant_faster_rounds, timing.rounds });
    } else {
        try text.writeAll("not measured (0 rounds; reference only)");
    }
    try writeField(stdout, "time", text.buffered());
    try writeHumanEvidence(stdout, report);

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
    report: Report,
) Io.Writer.Error!void {
    try stdout.print("{s:<22}{s:>16}{s:>16}{s:>16}\n", .{ "Baseline vs variant", "baseline", "variant", "change" });
    try writeCountRow(stdout, "rows read", before.counters.rows_read, after.counters.rows_read);
    try writeCountRow(stdout, "rows written", before.counters.rows_written, after.counters.rows_written);
    try writeCountRow(stdout, "result rows", before.rows, after.rows);
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

fn writeRowPair(writer: *Io.Writer, baseline: u32, variant: u32) Io.Writer.Error!void {
    try writeCount(writer, baseline);
    try writer.writeAll(" -> ");
    try writeCount(writer, variant);
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
        const line = cli_comparison.parentLine(plan, parent) orelse break;
        depth += 1;
        parent = plan.rows[line].parent;
    }
    return depth;
}

fn writeRowsDetail(stdout: *Io.Writer, outcome: cli_comparison.Outcome, show_rows: bool) Io.Writer.Error!void {
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 1, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .sizes = .{ .baseline = 4096, .variant = 8192 },
        .judgement = .{ .verdict = .not_judged },
    };
    try writeSummary(&stdout, header, before, after, outcome, report);

    const keys = [_][]const u8{
        "db: db.sqlite\nselect: select.sql\nindex-sql: index.sql\n",
        "measured-on: baseline (candidate index not applied)\nrows: 2\n",
        "sqlite: 0.0.0\nsqlite-source-id: test-source-id\n",
        "detail=SCAN t\nrows-read: 0\nrows-written: 0\n",
        "measured-on: variant (candidate index applied)\nrows: 2\n",
        "result: match (row multiset)\n",
        "row-order: ",
        "bind: 1:int\n",
        "measure-runs: 0 per copy\n",
        "verdict: not-judged\n",
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
        .counters = .{ .rows_read = 200_000, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&search_lines) },
        .counters = .{ .rows_read = 201, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeReport(&stdout, testing.allocator, .human, header, before, after, outcome, report);

    const head =
        \\Summary
        \\  result rows   match (the same rows on both copies)
        \\  rows read     200,000 -> 201
        \\  rows written  0 -> 0
        \\  verdict       improved: the rows match, and the variant reads fewer rows
        \\  query plan    changed on the variant
        \\  time          median 4.33 ms -> 37.29 us (0.009x); the variant was faster in
        \\                10 of 10 rounds (reference only)
        \\time-effect: insufficient-samples (reference only)
        \\time-median-difference-ns: 0 (variant - baseline, paired rounds)
        \\time-noise-band-ns: 0 (baseline A/A absolute difference p95; 0 pairs; empirical)
        \\time-confidence-interval-ns: unavailable (too-few-rounds)
        \\  db size       +2,170,880 bytes (+2.07 MiB; the whole database file, not the
        \\                index alone)
        \\
    ;
    const note: []const u8 = "  debug build (no optimization): the times are slower than a release build\n";
    const tail =
        \\
        \\Baseline vs variant           baseline         variant          change
        \\  rows read                    200,000             201        -199,799
        \\  rows written                       0               0            same
        \\  result rows                    1,200           1,200            same
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: cli_comparison.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "the SELECT calls random(), whose result changes between runs", .hint = "compare the SELECT without random()" };
    outcome.reason_count = 1;
    var report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows cannot be compared, so the SELECT is not timed");
    try writeReport(&stdout, testing.allocator, .human, header, measurement, measurement, outcome, report);

    const head =
        \\Summary
        \\  result rows   INCOMPARABLE (the rows cannot be compared; see Result rows)
        \\  rows read     0 -> 0
        \\  rows written  0 -> 0
        \\  verdict       not-judged:
        \\                - the result rows cannot be compared, so the SELECT is not timed
        \\  query plan    the same on both copies
        \\  time          not measured (0 rounds; reference only)
        \\  db size       0 bytes (0.00 MiB; the whole database file, not the index alone)
        \\
    ;
    const note: []const u8 = "  debug build (no optimization): the times are slower than a release build\n";
    const tail =
        \\
        \\Baseline vs variant           baseline         variant          change
        \\  rows read                          0               0            same
        \\  rows written                       0               0            same
        \\  result rows                        2               2            same
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 3, .autoindex_rows = 4 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .no_effect } };
    try writeReport(&stdout, testing.allocator, .human, header, before, after, outcome, report);
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };

    var stdout = Io.Writer.fixed(&buffer);
    try writeReport(&stdout, testing.allocator, .human, header, measurement, measurement, outcome, report);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "binds") == null);

    header.show_binds = true;
    var shown_buffer: [4096]u8 = undefined;
    var shown = Io.Writer.fixed(&shown_buffer);
    try writeReport(&shown, testing.allocator, .human, header, measurement, measurement, outcome, report);
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 2,
            .variant_faster_rounds = 2,
        },
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .no_effect },
    };
    try writeReport(&stdout, testing.allocator, .human, header, measurement, measurement, outcome, report);
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
        .counters = .{ .rows_read = 200_000, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 201, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeReport(&stdout, testing.allocator, .kv, header, before, after, outcome, report);
    try testing.expectEqualStrings(
        \\db: db.sqlite
        \\select: select.sql
        \\index-sql: index.sql
        \\measured-on: baseline (candidate index not applied)
        \\rows: 2
        \\sqlite: 0.0.0
        \\sqlite-source-id: test-source-id
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\rows-read: 200000
        \\rows-written: 0
        \\fullscan-steps: 199999
        \\vm-steps: 600407
        \\sort-ops: 0
        \\autoindex-rows: 0
        \\measured-on: variant (candidate index applied)
        \\rows: 2
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\rows-read: 201
        \\rows-written: 0
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
        \\measure-order: each round: baseline-baseline A/A, then alternating baseline-variant or variant-baseline (ABBA)
        \\measure-scope: sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed
        \\measure-cache: warm; each copy reuses its connection and page cache, and its file was just written
        \\work-dir-parent: /tmp
        \\zig:
    ++ " " ++ builtin.zig_version_string ++ "\nbuild-mode: " ++ @tagName(builtin.mode) ++ "\nos-arch: " ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch) ++ "\n" ++
        \\time-baseline-ns: median=4331750 p25=4158324 p75=4364397 min=4098250 max=4465958 (median 4.33 ms)
        \\time-variant-ns: median=37292 p25=33198 p75=40417 min=28583 max=71583 (median 37.29 us)
        \\time-ratio: 0.009 (variant median / baseline median)
        \\time-effect: insufficient-samples (reference only)
        \\time-median-difference-ns: 0 (variant - baseline, paired rounds)
        \\time-noise-band-ns: 0 (baseline A/A absolute difference p95; 0 pairs; empirical)
        \\time-confidence-interval-ns: unavailable (too-few-rounds)
        \\variant-faster-rounds: 10/10
        \\db-bytes-baseline: 5087232 (the snapshot file)
        \\db-bytes-variant: 7258112 (the snapshot file with the candidate index)
        \\db-bytes-increase: 2170880 (the whole database file, not the index alone)
        \\verdict: improved
        \\
    , stdout.buffered());
}

fn jsonGet(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

fn jsonText(value: std.json.Value, key: []const u8) ![]const u8 {
    return switch (try jsonGet(value, key)) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

fn jsonInt(value: std.json.Value, key: []const u8) !i64 {
    return switch (try jsonGet(value, key)) {
        .integer => |number| number,
        else => error.TestUnexpectedResult,
    };
}

fn jsonFloat(value: std.json.Value, key: []const u8) !f64 {
    return switch (try jsonGet(value, key)) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.TestUnexpectedResult,
    };
}

fn jsonBool(value: std.json.Value, key: []const u8) !bool {
    return switch (try jsonGet(value, key)) {
        .bool => |flag| flag,
        else => error.TestUnexpectedResult,
    };
}

fn jsonItems(value: std.json.Value, key: []const u8) ![]std.json.Value {
    return switch (try jsonGet(value, key)) {
        .array => |array| array.items,
        else => error.TestUnexpectedResult,
    };
}

fn parseReportJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

test "the json report carries the decision, the plans, the times and the sizes" {
    var buffer: [65536]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]cli_args.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "secret" } },
        .{ .number = 3, .value = .null },
        .{ .number = 4, .value = .{ .real = 1.5 } },
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
        .exit_code = 0,
    };
    const search_lines = [_]cli_comparison.PlanRow{
        .{ .id = 3, .parent = 0, .label = .{ .kind = .search, .covering = true }, .detail = "SEARCH t USING COVERING INDEX idx_a (a=?)" },
        .{ .id = 5, .parent = 3, .label = .{ .kind = .other }, .detail = "CORRELATED SCALAR SUBQUERY 1" },
    };
    const before: cli_comparison.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: cli_comparison.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&search_lines) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeReport(&stdout, testing.allocator, .json, header, before, after, outcome, report);

    var parsed = try parseReportJson(stdout.buffered());
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, 2), try jsonInt(root, "schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("improved", try jsonText(root, "verdict"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "verdict_reasons")).len);
    try testing.expectEqualStrings("match", try jsonText(root, "result"));
    try testing.expectEqualStrings("same", try jsonText(root, "row_order"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "result_reasons")).len);
    try testing.expect(try jsonBool(root, "plan_changed"));

    const differences = try jsonGet(root, "row_differences");
    try testing.expectEqual(@as(i64, 0), try jsonInt(differences, "baseline_only"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(differences, "variant_only"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(differences, "baseline_only_examples")).len);
    try testing.expectEqual(@as(usize, 0), (try jsonItems(differences, "variant_only_examples")).len);

    const baseline = try jsonGet(root, "baseline");
    try testing.expectEqual(@as(i64, 1200), try jsonInt(baseline, "rows"));
    const baseline_plan = try jsonItems(baseline, "plan");
    try testing.expectEqual(@as(usize, 1), baseline_plan.len);
    try testing.expectEqual(@as(i64, 2), try jsonInt(baseline_plan[0], "id"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(baseline_plan[0], "parent"));
    try testing.expectEqualStrings("scan", try jsonText(baseline_plan[0], "kind"));
    try testing.expect(!try jsonBool(baseline_plan[0], "covering"));
    try testing.expect(!try jsonBool(baseline_plan[0], "automatic"));
    try testing.expectEqualStrings("SCAN t", try jsonText(baseline_plan[0], "detail"));
    const baseline_counters = try jsonGet(baseline, "counters");
    try testing.expectEqual(@as(i64, 199_999), try jsonInt(baseline_counters, "fullscan_steps"));
    try testing.expectEqual(@as(i64, 600_407), try jsonInt(baseline_counters, "vm_steps"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(baseline_counters, "sort_ops"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(baseline_counters, "autoindex_rows"));

    const variant = try jsonGet(root, "variant");
    const variant_plan = try jsonItems(variant, "plan");
    try testing.expectEqual(@as(usize, 2), variant_plan.len);
    try testing.expectEqualStrings("search", try jsonText(variant_plan[0], "kind"));
    try testing.expect(try jsonBool(variant_plan[0], "covering"));
    try testing.expectEqual(@as(i64, 3), try jsonInt(variant_plan[1], "parent"));
    try testing.expectEqualStrings("other", try jsonText(variant_plan[1], "kind"));
    try testing.expectEqual(@as(i64, 710), try jsonInt(try jsonGet(variant, "counters"), "vm_steps"));

    const timing = try jsonGet(root, "timing");
    try testing.expectEqual(@as(i64, 10), try jsonInt(timing, "rounds"));
    try testing.expectEqual(@as(i64, 10), try jsonInt(timing, "variant_faster_rounds"));
    try testing.expectApproxEqRel(@as(f64, 37_292.0 / 4_331_750.0), try jsonFloat(timing, "ratio"), 1e-9);
    const baseline_stats = try jsonGet(timing, "baseline");
    try testing.expectEqual(@as(i64, 4_331_750), try jsonInt(baseline_stats, "median_ns"));
    try testing.expectEqual(@as(i64, 4_158_324), try jsonInt(baseline_stats, "p25_ns"));
    try testing.expectEqual(@as(i64, 4_364_397), try jsonInt(baseline_stats, "p75_ns"));
    try testing.expectEqual(@as(i64, 4_098_250), try jsonInt(baseline_stats, "min_ns"));
    try testing.expectEqual(@as(i64, 4_465_958), try jsonInt(baseline_stats, "max_ns"));
    try testing.expectEqual(@as(i64, 37_292), try jsonInt(try jsonGet(timing, "variant"), "median_ns"));

    const sizes = try jsonGet(root, "size_bytes");
    try testing.expectEqual(@as(i64, 5_087_232), try jsonInt(sizes, "baseline"));
    try testing.expectEqual(@as(i64, 7_258_112), try jsonInt(sizes, "variant"));
    try testing.expectEqual(@as(i64, 2_170_880), try jsonInt(sizes, "increase"));

    const inputs = try jsonGet(root, "inputs");
    try testing.expectEqualStrings("db.sqlite", try jsonText(inputs, "database"));
    try testing.expectEqualStrings("select.sql", try jsonText(inputs, "select"));
    try testing.expectEqualStrings("index.sql", try jsonText(inputs, "index_sql"));

    const environment = try jsonGet(root, "environment");
    try testing.expectEqualStrings(cli_args.version, try jsonText(environment, "qenome_version"));
    try testing.expectEqualStrings("0.0.0", try jsonText(environment, "sqlite_version"));
    try testing.expectEqualStrings("test-source-id", try jsonText(environment, "sqlite_source_id"));
    try testing.expectEqualStrings(builtin.zig_version_string, try jsonText(environment, "zig_version"));
    try testing.expectEqualStrings(@tagName(builtin.mode), try jsonText(environment, "build_mode"));
    try testing.expectEqualStrings(@tagName(builtin.os.tag), try jsonText(environment, "os"));
    try testing.expectEqualStrings(@tagName(builtin.cpu.arch), try jsonText(environment, "arch"));
    try testing.expectEqualStrings("/tmp", try jsonText(environment, "work_dir_parent"));

    const measurement = try jsonGet(root, "measurement");
    try testing.expectEqual(@as(i64, 10), try jsonInt(measurement, "runs_per_copy"));
    try testing.expectEqualStrings(measure_warmup, try jsonText(measurement, "warmup"));
    try testing.expectEqualStrings(measure_order, try jsonText(measurement, "order"));
    try testing.expectEqualStrings(measure_scope, try jsonText(measurement, "scope"));
    try testing.expectEqualStrings(measure_cache, try jsonText(measurement, "cache"));

    const binds_json = try jsonItems(root, "binds");
    try testing.expectEqual(@as(usize, 4), binds_json.len);
    try testing.expectEqual(@as(i64, 1), try jsonInt(binds_json[0], "number"));
    try testing.expectEqualStrings("int", try jsonText(binds_json[0], "type"));
    try testing.expectEqualStrings("text", try jsonText(binds_json[1], "type"));
    try testing.expectEqual(@as(i64, 6), try jsonInt(binds_json[1], "text_bytes"));
    try testing.expectEqualStrings("null", try jsonText(binds_json[2], "type"));
    try testing.expectEqualStrings("real", try jsonText(binds_json[3], "type"));
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "\"value\"") == null);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "secret") == null);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "1.5") == null);
    try testing.expect(std.unicode.utf8ValidateSlice(stdout.buffered()));
}

test "the json report shows the bind values only when asked" {
    var buffer: [32768]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]cli_args.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "sec'ret\n\xff" } },
        .{ .number = 3, .value = .null },
        .{ .number = 4, .value = .{ .real = 1.5 } },
        .{ .number = 5, .value = .{ .real = std.math.inf(f64) } },
    };
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &binds,
        .show_binds = true,
        .exit_code = 3,
    };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = false, .same_order = false, .baseline_only = 1, .variant_only = 1 };
    const outcome: cli_comparison.Outcome = .{ .verdict = .mismatch, .comparison = comparison };
    var report: Report = .{ .sizes = .{ .baseline = 8192, .variant = 8192 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows do not match, so the SELECT is not timed");
    try writeReport(&stdout, testing.allocator, .json, header, measurement, measurement, outcome, report);

    var parsed = try parseReportJson(stdout.buffered());
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, 3), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("not-judged", try jsonText(root, "verdict"));
    const reasons = try jsonItems(root, "verdict_reasons");
    try testing.expectEqual(@as(usize, 1), reasons.len);
    try testing.expectEqualStrings("the result rows do not match, so the SELECT is not timed", reasons[0].string);
    try testing.expect(try jsonGet(root, "timing") == .null);
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(root, "measurement"), "runs_per_copy"));
    try testing.expectEqualStrings("mismatch", try jsonText(root, "result"));
    try testing.expectEqualStrings("not-applicable", try jsonText(root, "row_order"));

    const differences = try jsonGet(root, "row_differences");
    try testing.expectEqual(@as(i64, 1), try jsonInt(differences, "baseline_only"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(differences, "variant_only"));

    const binds_json = try jsonItems(root, "binds");
    try testing.expectEqual(@as(usize, 5), binds_json.len);
    try testing.expectEqual(@as(i64, 7), try jsonInt(binds_json[0], "value"));
    try testing.expectEqualStrings("sec'ret\n\\xff", try jsonText(binds_json[1], "value"));
    try testing.expect(try jsonGet(binds_json[2], "value") == .null);
    try testing.expectEqual(@as(f64, 1.5), try jsonFloat(binds_json[3], "value"));
    try testing.expectEqualStrings("inf", try jsonText(binds_json[4], "value"));
}

test "the json report omits one-sided row values unless asked" {
    const email = "ada@example.com";
    const person = "Ada Lovelace";
    var baseline_row: [1 + 4 + email.len]u8 = undefined;
    baseline_row[0] = 3;
    std.mem.writeInt(u32, baseline_row[1..5], email.len, .little);
    @memcpy(baseline_row[5..], email);
    var variant_row: [1 + 4 + person.len]u8 = undefined;
    variant_row[0] = 3;
    std.mem.writeInt(u32, variant_row[1..5], person.len, .little);
    @memcpy(variant_row[5..], person);

    var comparison: result.Comparison = .{
        .matched = false,
        .same_order = false,
        .baseline_only = 2,
        .variant_only = 1,
    };
    comparison.baseline_examples[0] = &baseline_row;
    comparison.baseline_example_count = 1;
    comparison.variant_examples[0] = &variant_row;
    comparison.variant_example_count = 1;
    const outcome: cli_comparison.Outcome = .{ .verdict = .mismatch, .comparison = comparison };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var report: Report = .{ .sizes = .{ .baseline = 8192, .variant = 12288 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows do not match, so the SELECT is not timed");

    for ([_]bool{ false, true }) |show_rows| {
        var buffer: [16384]u8 = undefined;
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
            .show_rows = show_rows,
            .exit_code = 3,
        };
        try writeReport(&stdout, testing.allocator, .json, header, measurement, measurement, outcome, report);

        var parsed = try parseReportJson(stdout.buffered());
        defer parsed.deinit();
        const differences = try jsonGet(parsed.value, "row_differences");
        try testing.expectEqual(@as(i64, 2), try jsonInt(differences, "baseline_only"));
        try testing.expectEqual(@as(i64, 1), try jsonInt(differences, "variant_only"));
        const baseline_examples = try jsonItems(differences, "baseline_only_examples");
        const variant_examples = try jsonItems(differences, "variant_only_examples");
        if (show_rows) {
            try testing.expectEqual(@as(usize, 1), baseline_examples.len);
            try testing.expectEqual(@as(usize, 1), variant_examples.len);
            try testing.expectEqualStrings("['" ++ email ++ "']", baseline_examples[0].string);
            try testing.expectEqualStrings("['" ++ person ++ "']", variant_examples[0].string);
        } else {
            try testing.expectEqual(@as(usize, 0), baseline_examples.len);
            try testing.expectEqual(@as(usize, 0), variant_examples.len);
            try testing.expect(std.mem.indexOf(u8, stdout.buffered(), email) == null);
            try testing.expect(std.mem.indexOf(u8, stdout.buffered(), person) == null);
        }
    }
}

test "the json report has a null timing and a null ratio when nothing was timed or the baseline is zero" {
    var buffer: [16384]u8 = undefined;
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };

    var untimed_report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 2048 }, .judgement = .{ .verdict = .not_judged } };
    untimed_report.judgement.add("--runs 0 skips the timing");
    var stdout = Io.Writer.fixed(&buffer);
    try writeReport(&stdout, testing.allocator, .json, header, measurement, measurement, outcome, untimed_report);

    var parsed = try parseReportJson(stdout.buffered());
    defer parsed.deinit();
    try testing.expect(try jsonGet(parsed.value, "timing") == .null);
    try testing.expectEqual(@as(i64, 2048), try jsonInt(try jsonGet(parsed.value, "size_bytes"), "variant"));
    try testing.expectEqual(@as(i64, -2048), try jsonInt(try jsonGet(parsed.value, "size_bytes"), "increase"));
    try testing.expectEqualStrings("not-judged", try jsonText(parsed.value, "verdict"));

    var zero_buffer: [16384]u8 = undefined;
    var zero_stdout = Io.Writer.fixed(&zero_buffer);
    var zero_report: Report = .{
        .timing = .{
            .baseline = .{ .median = 0, .p25 = 0, .p75 = 0, .min = 0, .max = 0 },
            .variant = .{ .median = 7, .p25 = 6, .p75 = 8, .min = 5, .max = 9 },
            .rounds = 2,
            .variant_faster_rounds = 2,
        },
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .needs_check },
    };
    zero_report.judgement.add("the baseline median is 0 ns, so the times cannot be compared");
    try writeReport(&zero_stdout, testing.allocator, .json, header, measurement, measurement, outcome, zero_report);

    var zero_parsed = try parseReportJson(zero_stdout.buffered());
    defer zero_parsed.deinit();
    const timing = try jsonGet(zero_parsed.value, "timing");
    try testing.expect(try jsonGet(timing, "ratio") == .null);
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(timing, "baseline"), "median_ns"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(timing, "rounds"));
    try testing.expectEqualStrings("needs-check", try jsonText(zero_parsed.value, "verdict"));
}

test "the json report escapes quotes, controls and non-utf8 text" {
    var buffer: [32768]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const bad_path = "db\"\n\\\x01\x7f\u{9b}\u{202e}\u{1f600}\xff.sqlite";
    const header: Header = .{
        .database_path = bad_path,
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .binds = &.{},
        .show_binds = false,
        .exit_code = 4,
    };
    const measurement: cli_comparison.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&[_]cli_comparison.PlanRow{.{
            .id = 2,
            .parent = 0,
            .label = .{ .kind = .scan },
            .detail = "SCAN \"t\"\n\\\x01\xff",
        }}) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: cli_comparison.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "reason \"\x01\xff\"", .hint = "hint\nline" };
    outcome.reason_count = 1;
    var report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("not judged \xff");
    try writeReport(&stdout, testing.allocator, .json, header, measurement, measurement, outcome, report);

    try testing.expect(std.unicode.utf8ValidateSlice(stdout.buffered()));
    try testing.expect(std.mem.indexOfScalar(u8, stdout.buffered(), 0x01) == null);
    try testing.expect(std.mem.indexOfScalar(u8, stdout.buffered(), 0x7f) == null);
    try testing.expect(std.mem.indexOfScalar(u8, stdout.buffered(), 0xff) == null);
    for (stdout.buffered()) |byte| try testing.expect(byte < 0x80);

    var parsed = try parseReportJson(stdout.buffered());
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqualStrings("incomparable", try jsonText(root, "result"));
    try testing.expectEqualStrings("not-applicable", try jsonText(root, "row_order"));
    try testing.expectEqualStrings("db\"\n\\\\\x01\x7f\u{9b}\u{202e}\u{1f600}\\xff.sqlite", try jsonText(try jsonGet(root, "inputs"), "database"));
    const plan = try jsonItems(try jsonGet(root, "baseline"), "plan");
    try testing.expectEqualStrings("SCAN \"t\"\n\\\\\x01\\xff", try jsonText(plan[0], "detail"));
    const reasons = try jsonItems(root, "result_reasons");
    try testing.expectEqual(@as(usize, 1), reasons.len);
    try testing.expectEqualStrings("reason \"\x01\\xff\"", try jsonText(reasons[0], "text"));
    try testing.expectEqualStrings("hint\nline", try jsonText(reasons[0], "hint"));
    const verdict_reasons = try jsonItems(root, "verdict_reasons");
    try testing.expectEqual(@as(usize, 1), verdict_reasons.len);
    try testing.expectEqualStrings("not judged \\xff", verdict_reasons[0].string);
}

test "a literal backslash sequence and the byte 0xFF are different json strings" {
    try expectJsonText("\\xff", "\\\\xff");
    try expectJsonText("\xff", "\\xff");
    try expectJsonText("\\\xff", "\\\\\\xff");
    try expectJsonText("db.sqlite", "db.sqlite");
}

fn expectJsonText(input: []const u8, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &stdout, .options = .{ .escape_unicode = true } };
    try writeJsonText(&json, testing.allocator, input);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, stdout.buffered(), .{});
    defer parsed.deinit();
    const text = switch (parsed.value) {
        .string => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(expected, text);
}

test "the json report leaves stdout empty when a temporary allocation fails" {
    const header: Header = .{
        .database_path = "db\xff.sqlite",
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
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: cli_comparison.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var counting_buffer: [32768]u8 = undefined;
    var counting_stdout = Io.Writer.fixed(&counting_buffer);
    try writeReport(&counting_stdout, counting.allocator(), .json, header, measurement, measurement, outcome, report);
    var counting_parsed = try parseReportJson(counting_stdout.buffered());
    counting_parsed.deinit();
    const needed = counting.alloc_index;
    try testing.expect(needed != 0);

    for (0..needed) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var buffer: [32768]u8 = undefined;
        var stdout = Io.Writer.fixed(&buffer);
        if (writeReport(&stdout, failing.allocator(), .json, header, measurement, measurement, outcome, report)) |_| {
            std.debug.print("allocation {d} of {d} did not fail\n", .{ fail_index, needed });
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expect(err == error.WriteFailed or err == error.OutOfMemory);
        }
        try testing.expectEqual(@as(usize, 0), stdout.buffered().len);
    }
}
