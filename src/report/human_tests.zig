const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("../db.zig");
const result = @import("../result.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const human = @import("human.zig");
const testing = std.testing;
const Header = model.Header;
const Report = model.Report;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const Plan = model.Plan;
const PlanRow = model.PlanRow;
const writeHumanSummary = human.writeHumanSummary;
const writeTimeAssessment = human.writeTimeAssessment;
const planDepth = human.planDepth;
const line_width = format.line_width;

test "the human time assessment follows the timing effect" {
    const cases = [_]struct { effect: model.TimeEffect, baseline: u64, variant: u64, text: []const u8 }{
        .{ .effect = .faster, .baseline = 230_000, .variant = 1_000, .text = "230x faster (reference only)" },
        .{ .effect = .slower, .baseline = 1_000, .variant = 1_800, .text = "1.80x slower (reference only)" },
        .{ .effect = .faster, .baseline = 1_000, .variant = 990, .text = "1.01x faster (reference only)" },
        .{ .effect = .faster, .baseline = 1_000, .variant = 1_200, .text = "faster in the paired rounds (the medians differ in the other direction; reference only)" },
        .{ .effect = .slower, .baseline = 1_800, .variant = 1_000, .text = "slower in the paired rounds (the medians differ in the other direction; reference only)" },
        .{ .effect = .faster, .baseline = 1_000, .variant = 1_000, .text = "faster in the paired rounds (the medians are equal; reference only)" },
        .{ .effect = .slower, .baseline = 1_000, .variant = 1_000, .text = "slower in the paired rounds (the medians are equal; reference only)" },
        .{ .effect = .no_difference, .baseline = 1_000, .variant = 1_200, .text = "no clear difference in the paired rounds (reference only)" },
        .{ .effect = .insufficient_samples, .baseline = 1_000, .variant = 1_200, .text = "median ratio 1.20x (the paired rounds cannot judge the direction; reference only)" },
        .{ .effect = .insufficient_samples, .baseline = 0, .variant = 1_200, .text = "median ratio n/a (the paired rounds cannot judge the direction; reference only)" },
        .{ .effect = .insufficient_samples, .baseline = 1_000, .variant = 0, .text = "median ratio n/a (the paired rounds cannot judge the direction; reference only)" },
    };
    for (cases) |case| {
        var buffer: [192]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try writeTimeAssessment(&writer, case.baseline, case.variant, case.effect);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
}

const scan_line = [_]model.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

test "the human summary puts the conclusion first and the copies side by side" {
    var buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]db.BindArg{
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
        .qenome_version = "0.0.0",
        .binds = &binds,
        .show_binds = false,
    };
    const search_lines = [_]model.PlanRow{
        .{ .id = 3, .parent = 0, .label = .{ .kind = .search, .covering = true }, .detail = "SEARCH t USING COVERING INDEX idx_a (a=?)" },
        .{ .id = 5, .parent = 3, .label = .{ .kind = .other }, .detail = "CORRELATED SCALAR SUBQUERY 1 WITH A VERY LONG DETAIL THAT FILLS THE LINE" },
    };
    const before: model.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 200_000, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: model.Measurement = .{
        .rows = 1200,
        .plan = .{ .rows = @constCast(&search_lines) },
        .counters = .{ .rows_read = 201, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
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
            .evidence = .{ .effect = .faster },
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeHumanSummary(&stdout, testing.allocator, header, before, after, outcome, report);

    const head =
        \\Summary
        \\  result rows   match (the same rows on both copies)
        \\  rows read     200,000 -> 201
        \\  rows written  0 -> 0
        \\  verdict       improved: the rows match, and the variant reads fewer rows
        \\  query plan    changed on the variant
        \\  time          median 4.33 ms -> 37.29 us; 116x faster (reference only)
        \\  time noise    A/A p95 0 ns over 0 pairs (empirical; reference only)
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

test "the human summary keeps the timing evidence fields and warnings out of the summary" {
    var buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "db.sqlite",
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
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
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
            .evidence = .{ .effect = .faster, .noise_band = .{ .threshold_ns = 500_000, .pairs = 10 } },
        },
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .no_effect },
        .warnings = .{ .no_analyze_stats = true },
    };
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

    const output = stdout.buffered();
    const summary_end = std.mem.indexOf(u8, output, "\n\n") orelse return error.TestUnexpectedResult;
    var summary_lines = std.mem.splitScalar(u8, output[0..summary_end], '\n');
    try testing.expectEqualStrings("Summary", summary_lines.next().?);
    while (summary_lines.next()) |line| {
        try testing.expect(std.mem.startsWith(u8, line, "  "));
        try testing.expect(std.mem.indexOf(u8, line, "time-") == null);
        try testing.expect(std.mem.indexOf(u8, line, "warning:") == null);
    }
    try testing.expect(std.mem.indexOf(u8, output, "  time          median 4.33 ms -> 37.29 us; 116x faster") != null);
    try testing.expect(std.mem.indexOf(u8, output, "  time noise    A/A p95 500.00 us over 10 pairs (empirical; reference only)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "time-effect:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "time-median-difference-ns:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "time-noise-band-ns:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "time-confidence-interval-ns:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\nWarnings\n  warning: no_analyze_stats: ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\n    sqlite_stat1 entry") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sqlite_stat1 entry") != null);
}

test "the human warnings also follow an incomparable summary" {
    var buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const header: Header = .{
        .database_path = "db.sqlite",
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
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: model.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "the SELECT calls random(), whose result changes between runs", .hint = "compare the SELECT without random()" };
    outcome.reason_count = 1;
    const report: Report = .{
        .sizes = .{ .baseline = 4096, .variant = 4096 },
        .judgement = .{ .verdict = .not_judged },
        .warnings = .{ .no_analyze_stats = true, .data_too_small = true },
    };
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

    const output = stdout.buffered();
    const summary_end = std.mem.indexOf(u8, output, "\n\n") orelse return error.TestUnexpectedResult;
    var summary_lines = std.mem.splitScalar(u8, output[0..summary_end], '\n');
    try testing.expectEqualStrings("Summary", summary_lines.next().?);
    while (summary_lines.next()) |line| {
        try testing.expect(std.mem.startsWith(u8, line, "  "));
        try testing.expect(std.mem.indexOf(u8, line, "time-") == null);
        try testing.expect(std.mem.indexOf(u8, line, "warning:") == null);
    }
    try testing.expect(std.mem.indexOf(u8, output, "\nWarnings\n  warning: no_analyze_stats: ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "warning: data_too_small: ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\n    sqlite_stat1 entry") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sqlite_stat1 entry") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fewer than 1000 rows") != null);
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
        .qenome_version = "0.0.0",
        .binds = &.{},
        .show_binds = false,
    };
    const measurement: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    var outcome: model.Outcome = .{ .verdict = .incomparable };
    outcome.reasons[0] = .{ .text = "the SELECT calls random(), whose result changes between runs", .hint = "compare the SELECT without random()" };
    outcome.reason_count = 1;
    var report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .not_judged } };
    report.judgement.add("the result rows cannot be compared, so the SELECT is not timed");
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);

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
        .qenome_version = "0.0.0",
        .binds = &.{},
        .show_binds = false,
    };
    const before: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 3, .autoindex_rows = 4 },
        .columns = 1,
    };
    const after: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{ .sizes = .{ .baseline = 4096, .variant = 4096 }, .judgement = .{ .verdict = .no_effect } };
    try writeHumanSummary(&stdout, testing.allocator, header, before, after, outcome, report);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "  sort-ops") != null);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "  autoindex-rows") != null);
}

test "the human summary shows the bind values only when asked" {
    var buffer: [4096]u8 = undefined;
    const binds = [_]db.BindArg{
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
        .qenome_version = "0.0.0",
        .binds = &binds,
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

    var stdout = Io.Writer.fixed(&buffer);
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);
    try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "binds") == null);

    header.show_binds = true;
    var shown_buffer: [4096]u8 = undefined;
    var shown = Io.Writer.fixed(&shown_buffer);
    try writeHumanSummary(&shown, testing.allocator, header, measurement, measurement, outcome, report);
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
        .qenome_version = "0.0.0",
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
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);
    const note = "  debug build (no optimization): the times are slower than a release build\n";
    if (builtin.mode == .debug) {
        try testing.expect(std.mem.indexOf(u8, stdout.buffered(), note) != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, stdout.buffered(), "debug build") == null);
    }
}

test "a plan whose parents loop still ends" {
    const looped = [_]model.PlanRow{
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

test "small data is named in the summary with the scale command" {
    var buffer: [8192]u8 = undefined;
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
    const message = "The table \"events\" has 12 rows, fewer than 1000 rows, so this result is not meaningful yet.";
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
                .message = message,
            },
        },
    };
    try writeHumanSummary(&stdout, testing.allocator, header, measurement, measurement, outcome, report);
    const output = stdout.buffered();
    const summary_end = std.mem.indexOf(u8, output, "\n\n") orelse return error.TestUnexpectedResult;
    const summary = output[0..summary_end];
    try testing.expect(std.mem.indexOf(u8, summary, "verdict       improved") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "events has 12 rows, fewer than 1000 rows.") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "full scan") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "--scale") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "1000,10000") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "warning:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "warning: data_too_small: ") != null);
}
