const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("../db.zig");
const result = @import("../result.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const report_json = @import("json.zig");
const testing = std.testing;
const Header = model.Header;
const Report = model.Report;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const PlanRow = model.PlanRow;
const writeJsonReport = report_json.writeJsonReport;
const writeJsonText = report_json.writeJsonText;
const measure_warmup = format.measure_warmup;
const measure_order = format.measure_order;
const measure_scope = format.measure_scope;
const measure_cache = format.measure_cache;

const scan_line = [_]model.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

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
    const binds = [_]db.BindArg{
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
        .qenome_version = "9.9.9",
        .binds = &binds,
        .show_binds = false,
        .exit_code = 0,
    };
    const search_lines = [_]model.PlanRow{
        .{ .id = 3, .parent = 0, .label = .{ .kind = .search, .covering = true }, .detail = "SEARCH t USING COVERING INDEX idx_a (a=?)" },
        .{ .id = 5, .parent = 3, .label = .{ .kind = .other }, .detail = "CORRELATED SCALAR SUBQUERY 1" },
    };
    const before: model.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: model.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&search_lines) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
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
    try writeJsonReport(&stdout, testing.allocator, header, before, after, outcome, report);

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
    try testing.expectEqualStrings("9.9.9", try jsonText(environment, "qenome_version"));
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
    const binds = [_]db.BindArg{
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
        .qenome_version = "9.9.9",
        .binds = &binds,
        .show_binds = true,
        .exit_code = 3,
    };
    const measurement: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = false, .same_order = false, .baseline_only = 1, .variant_only = 1 };
    const outcome: model.Outcome = .{ .verdict = .mismatch, .comparison = comparison };
    var report: Report = .{ .sizes = .{ .baseline = 8192, .variant = 8192 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows do not match, so the SELECT is not timed");
    try writeJsonReport(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

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
    const outcome: model.Outcome = .{ .verdict = .mismatch, .comparison = comparison };
    const measurement: model.Measurement = .{
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
            .qenome_version = "9.9.9",
            .binds = &.{},
            .show_binds = false,
            .show_rows = show_rows,
            .exit_code = 3,
        };
        try writeJsonReport(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

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
        .qenome_version = "9.9.9",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };

    var untimed_report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 2048 }, .judgement = .{ .verdict = .not_judged } };
    untimed_report.judgement.add("--runs 0 skips the timing");
    var stdout = Io.Writer.fixed(&buffer);
    try writeJsonReport(&stdout, testing.allocator, header, measurement, measurement, outcome, untimed_report);

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
    try writeJsonReport(&zero_stdout, testing.allocator, header, measurement, measurement, outcome, zero_report);

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
        .qenome_version = "9.9.9",
        .binds = &.{},
        .show_binds = false,
        .exit_code = 4,
    };
    const measurement: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&[_]model.PlanRow{.{
            .id = 2,
            .parent = 0,
            .label = .{ .kind = .scan },
            .detail = "SCAN \"t\"\n\\\x01\xff",
        }}) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: model.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "reason \"\x01\xff\"", .hint = "hint\nline" };
    outcome.reason_count = 1;
    var report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("not judged \xff");
    try writeJsonReport(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

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
        .qenome_version = "9.9.9",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var counting_buffer: [32768]u8 = undefined;
    var counting_stdout = Io.Writer.fixed(&counting_buffer);
    try writeJsonReport(&counting_stdout, counting.allocator(), header, measurement, measurement, outcome, report);
    var counting_parsed = try parseReportJson(counting_stdout.buffered());
    counting_parsed.deinit();
    const needed = counting.alloc_index;
    try testing.expect(needed != 0);

    for (0..needed) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var buffer: [32768]u8 = undefined;
        var stdout = Io.Writer.fixed(&buffer);
        if (writeJsonReport(&stdout, failing.allocator(), header, measurement, measurement, outcome, report)) |_| {
            std.debug.print("allocation {d} of {d} did not fail\n", .{ fail_index, needed });
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expect(err == error.WriteFailed or err == error.OutOfMemory);
        }
        try testing.expectEqual(@as(usize, 0), stdout.buffered().len);
    }
}

test "a small-data warning adds the table, the scan, and the next command" {
    var buffer: [65536]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "app.db",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .qenome_version = "0.0.0",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: model.Measurement = .{
        .rows = 1,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 12, .rows_written = 0, .fullscan_steps = 12, .vm_steps = 20, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
    const command = "qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000";
    const report: Report = .{
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .improved },
        .warnings = .{
            .data_too_small = true,
            .small_data = .{
                .table = "events",
                .rows = 12,
                .full_scan = true,
                .suggested = false,
                .next_command = command,
                .message = "The table \"events\" has 12 rows, fewer than 1000 rows.",
            },
        },
    };
    try writeJsonReport(&stdout, testing.allocator, header, measurement, measurement, outcome, report);
    var parsed = try parseReportJson(stdout.buffered());
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), try jsonInt(parsed.value, "schema_version"));
    try testing.expectEqualStrings("improved", try jsonText(parsed.value, "verdict"));
    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings("data_too_small", try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings("events", try jsonText(warnings[0], "table"));
    try testing.expectEqual(@as(i64, 12), try jsonInt(warnings[0], "rows"));
    try testing.expect(try jsonBool(warnings[0], "full_scan"));
    try testing.expectEqualStrings(command, try jsonText(warnings[0], "next_command"));
    try testing.expect(std.mem.indexOf(u8, try jsonText(warnings[0], "message"), "fewer than 1000 rows") != null);
}
