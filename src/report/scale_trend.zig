const std = @import("std");
const contract = @import("../contract/values.zig");
const cli_comparison = @import("../cli/comparison.zig");
const model = @import("model.zig");

pub const constant_max_exponent: f64 = 0.2;

pub const sublinear_max_exponent: f64 = 0.8;

pub const linear_max_exponent: f64 = 1.2;

pub const gain_factor: f64 = 2.0;

pub const wrap_floor: u64 = 1 << 31;

pub const exponent_scale: f64 = 1000.0;

pub const GrowthClass = enum {
    constant,
    sublinear,
    linear,
    superlinear,
    mixed,
    unknown,

    pub fn text(self: GrowthClass) []const u8 {
        return switch (self) {
            .constant => "constant",
            .sublinear => "sublinear",
            .linear => "linear",
            .superlinear => "superlinear",
            .mixed => "mixed",
            .unknown => "unknown",
        };
    }
};

pub const Series = struct {
    class: GrowthClass,
    exponents: []const f64,
};

pub const Trend = struct {
    baseline_rows_read: Series,
    variant_rows_read: Series,
    baseline_time: ?Series,
    variant_time: ?Series,
};

pub const Finding = struct {
    code: []const u8,
    message: []const u8,
    steps: []const u64,
};

pub const Analysis = struct {
    trend: Trend,
    findings: []const Finding,
};

const texts = struct {
    const improvement_vanishes = "the verdict was improved at the smaller step and is no longer improved at the larger step";
    const regresses_reads = "the variant reads more rows than the baseline at the larger step, after the smaller step improved or had no effect";
    const regresses_writes = "the variant writes more rows than the baseline at the larger step, after the smaller step improved or had no effect";
    const improves_only = "the variant had no effect at the smaller step and improves at the larger one; the planner may prefer a scan on the small table";
    const only_faster = "the variant was faster at the smaller step and is no longer faster at the larger one";
    const baseline_plan = "the baseline plan differs between the two steps";
    const variant_plan = "the variant plan differs between the two steps";
    const both_plans = "the baseline and the variant plans differ between the two steps";
    const gain_grows = "the variant reads a smaller share of the baseline rows at the larger improved step";
    const gain_shrinks = "the variant reads a larger share of the baseline rows at the larger improved step";
};

const SeriesKind = enum { baseline_rows_read, variant_rows_read, baseline_time, variant_time };

fn seriesValue(step: model.ScaleStep, kind: SeriesKind) ?u64 {
    return switch (kind) {
        .baseline_rows_read => step.before.counters.rows_read,
        .variant_rows_read => step.after.counters.rows_read,
        .baseline_time => if (step.timing) |timing| timing.baseline.median else null,
        .variant_time => if (step.timing) |timing| timing.variant.median else null,
    };
}

fn roundedExponent(previous_rows: u64, rows: u64, previous_value: u64, value: u64) ?f64 {
    if (previous_rows == 0 or rows == 0 or previous_rows == rows) return null;
    if (previous_value == 0 or value == 0) return null;
    const value_ratio: f64 = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(previous_value));
    const rows_ratio: f64 = @as(f64, @floatFromInt(rows)) / @as(f64, @floatFromInt(previous_rows));
    const raw = @log(value_ratio) / @log(rows_ratio);
    const scaled = @round(raw * exponent_scale);
    if (scaled == 0) return 0;
    return scaled / exponent_scale;
}

fn classify(exponents: []const f64) GrowthClass {
    if (exponents.len == 0) return .unknown;
    var smallest = exponents[0];
    var largest = exponents[0];
    for (exponents[1..]) |value| {
        smallest = @min(smallest, value);
        largest = @max(largest, value);
    }
    if (largest <= constant_max_exponent) return .constant;
    if (largest <= sublinear_max_exponent) return .sublinear;
    if (smallest > sublinear_max_exponent and largest <= linear_max_exponent) return .linear;
    if (smallest > linear_max_exponent) return .superlinear;
    return .mixed;
}

fn buildSeries(arena: std.mem.Allocator, steps: []const model.ScaleStep, kind: SeriesKind) model.Error!Series {
    var exponents: std.ArrayList(f64) = .empty;
    var known = steps.len >= 2;
    var previous_rows: u64 = 0;
    var previous_value: u64 = 0;
    for (steps, 0..) |step, index| {
        if (!known) break;
        if (step.result != .match) {
            known = false;
            break;
        }
        const value = seriesValue(step, kind) orelse {
            known = false;
            break;
        };
        if (value == 0) {
            known = false;
            break;
        }
        if (index != 0) {
            if (value < previous_value and previous_value >= wrap_floor) {
                known = false;
                break;
            }
            const exponent = roundedExponent(previous_rows, step.rows, previous_value, value) orelse {
                known = false;
                break;
            };
            try exponents.append(arena, exponent);
        }
        previous_rows = step.rows;
        previous_value = value;
    }
    if (!known) {
        exponents.deinit(arena);
        return .{ .class = .unknown, .exponents = &.{} };
    }
    const owned = try exponents.toOwnedSlice(arena);
    return .{ .class = classify(owned), .exponents = owned };
}

fn pairs(arena: std.mem.Allocator, first: u64, second: u64) model.Error![]const u64 {
    const steps = try arena.alloc(u64, 2);
    steps[0] = first;
    steps[1] = second;
    return steps;
}

fn appendFinding(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    code: []const u8,
    message: []const u8,
    first: u64,
    second: u64,
) model.Error!void {
    try findings.append(arena, .{ .code = code, .message = message, .steps = try pairs(arena, first, second) });
}

fn verdictImprovedOrNoEffect(step: model.ScaleStep) bool {
    return step.judgement.verdict == .improved or step.judgement.verdict == .no_effect;
}

fn addImprovementVanishes(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    var improved: ?usize = null;
    for (steps, 0..) |step, index| {
        if (step.judgement.verdict == .improved) {
            improved = index;
            break;
        }
    }
    const first = improved orelse return;
    for (steps[first + 1 ..]) |later| {
        const verdict = later.judgement.verdict;
        if (verdict != .no_effect and verdict != .needs_check) continue;
        try appendFinding(arena, findings, contract.code.improvement_vanishes_at_scale, texts.improvement_vanishes, steps[first].rows, later.rows);
        return;
    }
}

fn addRegresses(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    var started: ?usize = null;
    for (steps, 0..) |step, index| {
        if (verdictImprovedOrNoEffect(step)) {
            started = index;
            break;
        }
    }
    const first = started orelse return;
    for (steps[first + 1 ..]) |later| {
        const verdict = later.judgement.verdict;
        if (verdict != .needs_check and verdict != .regressed) continue;
        const reads_more = later.after.counters.rows_read > later.before.counters.rows_read;
        const writes_more = later.after.counters.rows_written > later.before.counters.rows_written;
        if (!reads_more and !writes_more) continue;
        const message = if (reads_more) texts.regresses_reads else texts.regresses_writes;
        try appendFinding(arena, findings, contract.code.regresses_at_scale, message, steps[first].rows, later.rows);
        return;
    }
}

fn addImprovesOnly(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    var improved: ?usize = null;
    for (steps, 0..) |step, index| {
        if (step.judgement.verdict == .improved) {
            improved = index;
            break;
        }
    }
    const first = improved orelse return;
    for (steps[0..first]) |smaller| {
        if (smaller.judgement.verdict != .no_effect) continue;
        try appendFinding(arena, findings, contract.code.improves_only_at_scale, texts.improves_only, smaller.rows, steps[first].rows);
        return;
    }
}

fn addOnlyFaster(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    var faster: ?usize = null;
    for (steps, 0..) |step, index| {
        const timing = step.timing orelse continue;
        if (timing.evidence.effect == .faster) {
            faster = index;
            break;
        }
    }
    const first = faster orelse return;
    for (steps[first + 1 ..]) |later| {
        const timing = later.timing orelse continue;
        const effect = timing.evidence.effect;
        if (effect != .no_difference and effect != .slower) continue;
        try appendFinding(arena, findings, contract.code.only_faster_at_small_sizes, texts.only_faster, steps[first].rows, later.rows);
        return;
    }
}

fn addPlanChanges(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    for (steps[1..], 1..) |step, index| {
        const previous = steps[index - 1];
        const baseline_changed = !cli_comparison.samePlan(previous.before.plan, step.before.plan);
        const variant_changed = !cli_comparison.samePlan(previous.after.plan, step.after.plan);
        if (!baseline_changed and !variant_changed) continue;
        const message = if (baseline_changed and variant_changed)
            texts.both_plans
        else if (baseline_changed)
            texts.baseline_plan
        else
            texts.variant_plan;
        try appendFinding(arena, findings, contract.code.plan_changes_with_scale, message, previous.rows, step.rows);
        return;
    }
}

const Gain = struct {
    first: usize,
    last: usize,
    first_gain: f64,
    last_gain: f64,
};

fn rowsReadGain(steps: []const model.ScaleStep) ?Gain {
    var first: ?usize = null;
    var last: ?usize = null;
    for (steps, 0..) |step, index| {
        if (step.judgement.verdict != .improved) continue;
        if (step.before.counters.rows_read == 0 or step.after.counters.rows_read == 0) return null;
        if (first == null) first = index;
        last = index;
    }
    const start = first orelse return null;
    const end = last orelse return null;
    if (start == end) return null;
    return .{
        .first = start,
        .last = end,
        .first_gain = @as(f64, @floatFromInt(steps[start].before.counters.rows_read)) / @as(f64, @floatFromInt(steps[start].after.counters.rows_read)),
        .last_gain = @as(f64, @floatFromInt(steps[end].before.counters.rows_read)) / @as(f64, @floatFromInt(steps[end].after.counters.rows_read)),
    };
}

fn addGainFindings(arena: std.mem.Allocator, steps: []const model.ScaleStep, findings: *std.ArrayList(Finding)) model.Error!void {
    const gain = rowsReadGain(steps) orelse return;
    if (gain.last_gain >= gain.first_gain * gain_factor) {
        try appendFinding(arena, findings, contract.code.gain_grows_with_scale, texts.gain_grows, steps[gain.first].rows, steps[gain.last].rows);
        return;
    }
    if (gain.last_gain * gain_factor <= gain.first_gain) {
        try appendFinding(arena, findings, contract.code.gain_shrinks_with_scale, texts.gain_shrinks, steps[gain.first].rows, steps[gain.last].rows);
    }
}

pub fn analyze(arena: std.mem.Allocator, steps: []const model.ScaleStep) model.Error!Analysis {
    var timed = false;
    for (steps) |step| {
        if (step.timing != null) {
            timed = true;
            break;
        }
    }
    var findings: std.ArrayList(Finding) = .empty;
    try addImprovementVanishes(arena, steps, &findings);
    try addRegresses(arena, steps, &findings);
    try addImprovesOnly(arena, steps, &findings);
    try addOnlyFaster(arena, steps, &findings);
    try addPlanChanges(arena, steps, &findings);
    try addGainFindings(arena, steps, &findings);
    return .{
        .trend = .{
            .baseline_rows_read = try buildSeries(arena, steps, .baseline_rows_read),
            .variant_rows_read = try buildSeries(arena, steps, .variant_rows_read),
            .baseline_time = if (timed) try buildSeries(arena, steps, .baseline_time) else null,
            .variant_time = if (timed) try buildSeries(arena, steps, .variant_time) else null,
        },
        .findings = try findings.toOwnedSlice(arena),
    };
}

test {
    _ = @import("scale_trend_tests.zig");
}
