const std = @import("std");
const contract = @import("../contract/values.zig");
const model = @import("model.zig");
const trend = @import("scale_trend.zig");
const testing = std.testing;

const scan_line = [_]model.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

const search_line = [_]model.PlanRow{.{ .id = 3, .parent = 0, .label = .{ .kind = .search }, .detail = "SEARCH t USING INDEX ix_a (a=?)" }};

const covering_line = [_]model.PlanRow{.{ .id = 4, .parent = 0, .label = .{ .kind = .search }, .detail = "SEARCH t USING COVERING INDEX ix_a (a=?)" }};

fn measurement(rows_read: u64, rows_written: u64, plan: []const model.PlanRow) model.Measurement {
    return .{
        .rows = 1,
        .plan = .{ .rows = @constCast(plan) },
        .counters = .{
            .rows_read = @intCast(rows_read),
            .rows_written = @intCast(rows_written),
            .fullscan_steps = 0,
            .vm_steps = 0,
            .sort_ops = 0,
            .autoindex_rows = 0,
        },
        .columns = 1,
    };
}

fn stats(ns: u64) model.Stats {
    return .{ .median = ns, .p25 = ns, .p75 = ns, .min = ns, .max = ns };
}

fn timing(baseline_ns: u64, variant_ns: u64, effect: model.TimeEffect) model.TimeSummary {
    return .{
        .baseline = stats(baseline_ns),
        .variant = stats(variant_ns),
        .rounds = 3,
        .variant_faster_rounds = 0,
        .evidence = .{ .effect = effect },
    };
}

const StepSpec = struct {
    rows: u64,
    baseline_read: u64,
    variant_read: u64,
    baseline_written: u64 = 0,
    variant_written: u64 = 0,
    verdict: model.RowVerdict = .improved,
    result: model.Verdict = .match,
    baseline_plan: []const model.PlanRow = &scan_line,
    variant_plan: []const model.PlanRow = &search_line,
    timing: ?model.TimeSummary = null,
};

fn analyze(arena: std.mem.Allocator, specs: []const StepSpec) !trend.Analysis {
    const steps = try arena.alloc(model.ScaleStep, specs.len);
    for (specs, 0..) |spec, index| {
        steps[index] = .{
            .rows = spec.rows,
            .tables = &.{},
            .before = measurement(spec.baseline_read, spec.baseline_written, spec.baseline_plan),
            .after = measurement(spec.variant_read, spec.variant_written, spec.variant_plan),
            .result = spec.result,
            .judgement = .{ .verdict = spec.verdict },
            .plan_changed = true,
            .timing = spec.timing,
            .comparison_json = "{}",
        };
    }
    return trend.analyze(arena, steps);
}

fn finding(analysis: trend.Analysis, code: []const u8) ?trend.Finding {
    for (analysis.findings) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry;
    }
    return null;
}

fn count(analysis: trend.Analysis, code: []const u8) usize {
    var total: usize = 0;
    for (analysis.findings) |entry| {
        if (std.mem.eql(u8, entry.code, code)) total += 1;
    }
    return total;
}

fn expectSeries(expected: trend.GrowthClass, values: []const f64, series: trend.Series) !void {
    try testing.expectEqual(expected, series.class);
    try testing.expectEqual(values.len, series.exponents.len);
    for (values, series.exponents) |want, got| try testing.expectApproxEqAbs(want, got, 1e-9);
}

test "the rows-read trend names constant, sublinear, linear and superlinear" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const constant = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 50 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 50 },
    });
    try expectSeries(.constant, &.{0.0}, constant.trend.variant_rows_read);
    try expectSeries(.linear, &.{1.0}, constant.trend.baseline_rows_read);

    const sublinear = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 100, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 300, .variant_read = 300 },
    });
    try expectSeries(.sublinear, &.{0.477}, sublinear.trend.baseline_rows_read);

    const superlinear = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 100, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 2000, .variant_read = 2000 },
    });
    try expectSeries(.superlinear, &.{1.301}, superlinear.trend.baseline_rows_read);
}

test "a series that spans two bands is mixed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mixed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 100, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 316, .variant_read = 316 },
        .{ .rows = 100000, .baseline_read = 3160, .variant_read = 3160 },
    });
    try expectSeries(.mixed, &.{ 0.5, 1.0 }, mixed.trend.baseline_rows_read);

    const sublinear_pair = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 100, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 200, .variant_read = 200 },
        .{ .rows = 100000, .baseline_read = 300, .variant_read = 300 },
    });
    try expectSeries(.sublinear, &.{ 0.301, 0.176 }, sublinear_pair.trend.baseline_rows_read);
}

test "a zero value or a step that is not a match makes the series unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zeroed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 0, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10 },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, zeroed.trend.baseline_rows_read.class);
    try testing.expectEqual(@as(usize, 0), zeroed.trend.baseline_rows_read.exponents.len);
    try testing.expectEqual(trend.GrowthClass.constant, zeroed.trend.variant_rows_read.class);

    const mismatched = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .result = .mismatch },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, mismatched.trend.baseline_rows_read.class);
    try testing.expectEqual(trend.GrowthClass.unknown, mismatched.trend.variant_rows_read.class);

    const single = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, single.trend.baseline_rows_read.class);
}

test "a possible 32-bit wrap makes the series unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wrapped = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 10000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 4000000000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 12, .variant_read = 10 },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, wrapped.trend.baseline_rows_read.class);

    const plan_change = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 10000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 500, .variant_read = 10 },
    });
    try expectSeries(.constant, &.{-1.301}, plan_change.trend.baseline_rows_read);
}

test "the time trend is absent without timing and classified when timed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const untimed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10 },
    });
    try testing.expect(untimed.trend.baseline_time == null);
    try testing.expect(untimed.trend.variant_time == null);

    const timed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(1_000_000, 1_000_000, .faster) },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .timing = timing(100_000_000, 2_000_000, .no_difference) },
    });
    try expectSeries(.superlinear, &.{2.0}, timed.trend.baseline_time.?);
    try expectSeries(.sublinear, &.{0.301}, timed.trend.variant_time.?);

    const partial = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(1_000_000, 1_000_000, .faster) },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10 },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, partial.trend.baseline_time.?.class);
    try testing.expectEqual(@as(usize, 0), partial.trend.baseline_time.?.exponents.len);

    const zero_median = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(0, 0, .no_difference) },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .timing = timing(0, 0, .no_difference) },
    });
    try testing.expectEqual(trend.GrowthClass.unknown, zero_median.trend.baseline_time.?.class);
}

test "improvement_vanishes_at_scale names the improved step and the later one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const vanished = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 100000, .verdict = .no_effect },
    });
    const found = finding(vanished, contract.code.improvement_vanishes_at_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), found.steps.len);
    try testing.expectEqual(@as(u64, 1000), found.steps[0]);
    try testing.expectEqual(@as(u64, 100000), found.steps[1]);
    try testing.expect(found.message.len != 0);

    const needs_check = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 200000, .verdict = .needs_check },
    });
    try testing.expect(count(needs_check, contract.code.improvement_vanishes_at_scale) == 1);

    const steady = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10 },
    });
    try testing.expect(count(steady, contract.code.improvement_vanishes_at_scale) == 0);
}

test "regresses_at_scale needs a later step that costs more" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const regressed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 100001, .verdict = .needs_check },
    });
    const found = finding(regressed, contract.code.regresses_at_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), found.steps[0]);
    try testing.expectEqual(@as(u64, 100000), found.steps[1]);

    const writes_more = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .baseline_written = 1, .variant_written = 1 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10, .baseline_written = 1, .variant_written = 2, .verdict = .needs_check },
    });
    const written = finding(writes_more, contract.code.regresses_at_scale) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, written.message, "writes") != null);

    const already_bad = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 2000, .verdict = .needs_check },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 200000, .verdict = .needs_check },
    });
    try testing.expect(count(already_bad, contract.code.regresses_at_scale) == 0);
}

test "improves_only_at_scale names a small no-effect step and a later improved one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const late = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 1000, .verdict = .no_effect },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10 },
    });
    const found = finding(late, contract.code.improves_only_at_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), found.steps[0]);
    try testing.expectEqual(@as(u64, 100000), found.steps[1]);

    const never = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 1000, .verdict = .no_effect },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 100000, .verdict = .no_effect },
    });
    try testing.expect(count(never, contract.code.improves_only_at_scale) == 0);
}

test "only_faster_at_small_sizes reads the time effect of each step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const slower_later = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(1_000_000, 500_000, .faster) },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10, .timing = timing(10_000_000, 20_000_000, .slower) },
    });
    const found = finding(slower_later, contract.code.only_faster_at_small_sizes) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), found.steps[0]);
    try testing.expectEqual(@as(u64, 100000), found.steps[1]);

    const same_later = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(1_000_000, 500_000, .faster) },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10, .timing = timing(10_000_000, 10_000_000, .no_difference) },
    });
    try testing.expect(count(same_later, contract.code.only_faster_at_small_sizes) == 1);

    const faster_everywhere = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10, .timing = timing(1_000_000, 500_000, .faster) },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10, .timing = timing(10_000_000, 5_000_000, .faster) },
    });
    try testing.expect(count(faster_everywhere, contract.code.only_faster_at_small_sizes) == 0);

    const untimed = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10 },
    });
    try testing.expect(count(untimed, contract.code.only_faster_at_small_sizes) == 0);
}

test "plan_changes_with_scale names the side and the first change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stable = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10 },
    });
    try testing.expect(count(stable, contract.code.plan_changes_with_scale) == 0);

    const variant_change = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .variant_plan = &covering_line },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10, .variant_plan = &covering_line },
    });
    const changed = finding(variant_change, contract.code.plan_changes_with_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), changed.steps.len);
    try testing.expectEqual(@as(u64, 1000), changed.steps[0]);
    try testing.expectEqual(@as(u64, 10000), changed.steps[1]);
    try testing.expect(std.mem.indexOf(u8, changed.message, "variant") != null);
    try testing.expect(std.mem.indexOf(u8, changed.message, "baseline") == null);

    const baseline_change = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 1000, .variant_read = 10, .baseline_plan = &covering_line },
    });
    const baseline_changed = finding(baseline_change, contract.code.plan_changes_with_scale) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, baseline_changed.message, "baseline") != null);
    try testing.expect(std.mem.indexOf(u8, baseline_changed.message, "variant") == null);

    const both_change = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .baseline_plan = &covering_line, .variant_plan = &covering_line },
    });
    const both = finding(both_change, contract.code.plan_changes_with_scale) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, both.message, "baseline and the variant") != null);
}

test "the rows-read gain is reported when it grows or shrinks between improved steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const grows = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 1000 },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 1000 },
    });
    const grown = finding(grows, contract.code.gain_grows_with_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), grown.steps[0]);
    try testing.expectEqual(@as(u64, 100000), grown.steps[1]);
    try testing.expect(count(grows, contract.code.gain_shrinks_with_scale) == 0);

    const shrinks = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 8000 },
    });
    const shrunk = finding(shrinks, contract.code.gain_shrinks_with_scale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), shrunk.steps[0]);
    try testing.expectEqual(@as(u64, 10000), shrunk.steps[1]);
    try testing.expect(count(shrinks, contract.code.gain_grows_with_scale) == 0);

    const steady = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 1000 },
    });
    try testing.expect(count(steady, contract.code.gain_grows_with_scale) == 0);
    try testing.expect(count(steady, contract.code.gain_shrinks_with_scale) == 0);

    const not_improved = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 1000, .verdict = .no_effect },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10 },
    });
    try testing.expect(count(not_improved, contract.code.gain_grows_with_scale) == 0);
    try testing.expect(count(not_improved, contract.code.gain_shrinks_with_scale) == 0);
}

test "the findings keep a stable order and no duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const analysis = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 1000, .verdict = .no_effect, .timing = timing(1_000_000, 500_000, .faster) },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10, .baseline_plan = &covering_line, .variant_plan = &covering_line, .timing = timing(10_000_000, 20_000_000, .slower) },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 200000, .verdict = .needs_check, .timing = timing(10_000_000, 10_000_000, .no_difference) },
    });
    try testing.expectEqual(@as(usize, 5), analysis.findings.len);
    try testing.expectEqualStrings(contract.code.improvement_vanishes_at_scale, analysis.findings[0].code);
    try testing.expectEqualStrings(contract.code.regresses_at_scale, analysis.findings[1].code);
    try testing.expectEqualStrings(contract.code.improves_only_at_scale, analysis.findings[2].code);
    try testing.expectEqualStrings(contract.code.only_faster_at_small_sizes, analysis.findings[3].code);
    try testing.expectEqualStrings(contract.code.plan_changes_with_scale, analysis.findings[4].code);
}

test "the band boundaries follow the rounded exponent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { value: u64, expected: trend.GrowthClass }{
        .{ .value = 1584, .expected = .constant },
        .{ .value = 1587, .expected = .sublinear },
        .{ .value = 6303, .expected = .sublinear },
        .{ .value = 6317, .expected = .linear },
        .{ .value = 15831, .expected = .linear },
        .{ .value = 15868, .expected = .superlinear },
    };
    for (cases) |case| {
        const analysis = try analyze(arena, &.{
            .{ .rows = 1000, .baseline_read = 1000, .variant_read = 500 },
            .{ .rows = 10000, .baseline_read = case.value, .variant_read = case.value / 2 },
        });
        try testing.expectEqual(case.expected, analysis.trend.baseline_rows_read.class);
    }
}

test "the gain findings include the exact 2x boundary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exactly_grows = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 500 },
    });
    try testing.expect(count(exactly_grows, contract.code.gain_grows_with_scale) == 1);

    const just_under = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 501 },
    });
    try testing.expect(count(just_under, contract.code.gain_grows_with_scale) == 0);

    const exactly_shrinks = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 2000 },
    });
    try testing.expect(count(exactly_shrinks, contract.code.gain_shrinks_with_scale) == 1);

    const just_over = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 100 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 1999 },
    });
    try testing.expect(count(just_over, contract.code.gain_shrinks_with_scale) == 0);
}

test "improves_only_at_scale needs the no-effect step before the first improvement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const improvement_returns = try analyze(arena, &.{
        .{ .rows = 1000, .baseline_read = 1000, .variant_read = 10 },
        .{ .rows = 10000, .baseline_read = 10000, .variant_read = 10000, .verdict = .no_effect },
        .{ .rows = 100000, .baseline_read = 100000, .variant_read = 10 },
    });
    try testing.expect(count(improvement_returns, contract.code.improves_only_at_scale) == 0);
    try testing.expect(count(improvement_returns, contract.code.improvement_vanishes_at_scale) == 1);
}
