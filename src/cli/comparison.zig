const std = @import("std");
const db = @import("../db.zig");
const result = @import("../result.zig");

pub const PlanRow = db.PlanRow;

pub const Side = enum { baseline, variant };

pub const Measurement = struct {
    rows: u64,
    plan: db.Plan,
    counters: db.Counters,
    columns: c_int,
    changes: u64 = 0,
    total_changes: u64 = 0,
    executions: u32 = 0,
};

pub const Verdict = enum { match, mismatch, incomparable };

pub const Outcome = struct {
    verdict: Verdict,
    comparison: ?result.Comparison = null,
    reasons: [max_reasons]Reason = undefined,
    reason_count: usize = 0,

    const max_reasons = 5;

    const Reason = struct {
        text: []const u8,
        hint: ?[]const u8,
    };

    fn addReason(self: *Outcome, text: []const u8, hint: ?[]const u8) void {
        if (self.reason_count == max_reasons) return;
        self.reasons[self.reason_count] = .{ .text = text, .hint = hint };
        self.reason_count += 1;
    }
};

pub fn writeIncomparable(arena: std.mem.Allocator, clues: db.Clues) ?Outcome {
    var outcome: Outcome = .{ .verdict = .incomparable };
    if (clues.nondeterministic_function) |name| outcome.addReason(
        print(arena, "the write calls {s}(), whose result changes between runs", name),
        print(arena, "compare the write without {s}()", name),
    );
    if (clues.time_function) |name| outcome.addReason(
        print(arena, "the write calls {s}(), which reads the current time", name),
        "remove the time function or bind a fixed value instead",
    );
    if (clues.schema_table) |name| outcome.addReason(
        print(arena, "the write reads {s}, which differs when the candidate index exists", name),
        "writes that read the schema tables are not compared",
    );
    return if (outcome.reason_count == 0) null else outcome;
}

pub fn writeRepeatMismatch(side: Side) Outcome {
    var outcome: Outcome = .{ .verdict = .incomparable };
    outcome.addReason(
        if (side == .baseline)
            "the repeated runs on the baseline reported different counts, so the write is not repeatable from the same rows"
        else
            "the repeated runs on the variant reported different counts, so the write is not repeatable from the same rows",
        "use --runs 0 to measure one run, or remove the value that changes between runs",
    );
    return outcome;
}

pub fn writeChangesMismatch() Judgement {
    var judgement: Judgement = .{ .verdict = .not_judged };
    judgement.add("the two copies changed a different number of rows, so the row counts are not judged");
    return judgement;
}

const over_budget_reason = std.fmt.comptimePrint(
    "the result rows exceed the {d} MiB kept for the comparison",
    .{result.max_result_bytes / (1024 * 1024)},
);

pub const Hints = struct {
    clues: db.Clues,
    limit_or_offset: bool,
};

pub fn decide(
    arena: std.mem.Allocator,
    before: Measurement,
    after: Measurement,
    baseline_rows: *result.RowCollector,
    variant_rows: *result.RowCollector,
    hints: Hints,
) Outcome {
    var outcome: Outcome = .{ .verdict = .incomparable };
    if (hints.clues.nondeterministic_function) |name| outcome.addReason(
        print(arena, "the SELECT calls {s}(), whose result changes between runs", name),
        print(arena, "compare the SELECT without {s}()", name),
    );
    if (hints.clues.schema_table) |name| outcome.addReason(
        print(arena, "the SELECT reads {s}, which describes the database itself", name),
        "SELECTs that read the schema tables are not compared",
    );
    if (outcome.reason_count != 0) return outcome;

    if (baseline_rows.failure orelse variant_rows.failure) |failure| {
        switch (failure) {
            .over_budget => outcome.addReason(over_budget_reason, "narrow the rows with WHERE (not LIMIT) and run again"),
            .out_of_memory => outcome.addReason("out of memory while keeping the result rows", null),
        }
        return outcome;
    }
    if (before.columns != after.columns) {
        outcome.addReason("the column count differs between the copies", null);
        return outcome;
    }

    const comparison = result.compare(baseline_rows, variant_rows);
    outcome.comparison = comparison;
    if (comparison.matched) {
        outcome.verdict = .match;
        return outcome;
    }
    if (hints.clues.time_function) |name| outcome.addReason(
        print(arena, "the rows differ, and the SELECT calls {s}(), which can read the current time ('now' or no argument)", name),
        "if the SELECT reads the current time, bind a fixed time instead and run again",
    );
    if (hints.clues.order_dependent_function) |name| outcome.addReason(
        print(arena, "the rows differ, and the SELECT calls {s}(), whose result can depend on the order rows are read in", name),
        orderHint(arena, name),
    );
    if (hints.limit_or_offset) outcome.addReason(
        "the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other rows when the order changes",
        "to compare, end the ORDER BY next to the LIMIT with a unique NOT NULL column, or drop LIMIT and OFFSET; then check that the plan still uses the candidate index",
    );
    if (hints.clues.view_or_cte) outcome.addReason(
        "the rows differ, and the SELECT reads through a view or a WITH clause, which may pick rows by their order",
        "compare the SELECT inside the view or the WITH clause directly",
    );
    if (outcome.reason_count == 0) outcome.verdict = .mismatch;
    return outcome;
}

fn orderHint(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const sums = [_][]const u8{ "sum", "avg", "total" };
    const windows = [_][]const u8{ "row_number", "ntile", "first_value", "last_value", "nth_value", "lag", "lead" };
    for (sums) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "{s}() adds REAL values in the order they are read, so the results may differ only in the last digits; rerun with --show-rows to see the rows", name);
    for (windows) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "end the ORDER BY in OVER (...) of {s}() with a unique column, so that every row has a fixed place", name);
    return print(arena, "add ORDER BY inside {s}(...), so that the rows are joined in a fixed order", name);
}

fn print(arena: std.mem.Allocator, comptime format: []const u8, name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, format, .{name}) catch format;
}

pub const RowVerdict = enum {
    improved,
    no_effect,
    needs_check,
    regressed,
    not_judged,

    pub fn text(self: RowVerdict) []const u8 {
        return switch (self) {
            .improved => "improved",
            .no_effect => "no-effect",
            .needs_check => "needs-check",
            .regressed => "regressed",
            .not_judged => "not-judged",
        };
    }
};

pub const Worsening = enum { needs_check, regressed };

pub const Judgement = struct {
    verdict: RowVerdict,
    reasons: [max_reasons][]const u8 = undefined,
    reason_count: usize = 0,

    const max_reasons = 3;

    pub fn add(self: *Judgement, reason: []const u8) void {
        if (self.reason_count == max_reasons) return;
        self.reasons[self.reason_count] = reason;
        self.reason_count += 1;
    }
};

pub fn judgeRows(before: Measurement, after: Measurement) Judgement {
    return judgeRowsWith(before, after, .needs_check);
}

pub fn judgeMigrationWrite(before: Measurement, after: Measurement) Judgement {
    var judgement: Judgement = .{ .verdict = .regressed };
    const baseline = before.counters;
    const variant = after.counters;
    if (variant.rows_read > baseline.rows_read) {
        judgement.add("the rows match, but the variant reads more rows than the baseline");
        return judgement;
    }
    if (variant.rows_written > baseline.rows_written) {
        judgement.add("the rows match, but the variant writes more rows; rows written is reported and does not change the verdict");
    } else if (variant.rows_written < baseline.rows_written) {
        judgement.add("the rows match, and the variant writes fewer rows; rows written is reported and does not change the verdict");
    }
    if (variant.rows_read == baseline.rows_read) {
        judgement.verdict = .no_effect;
        return judgement;
    }
    judgement.verdict = .improved;
    return judgement;
}

pub fn judgeRowsWith(before: Measurement, after: Measurement, worsening: Worsening) Judgement {
    var judgement: Judgement = .{ .verdict = switch (worsening) {
        .needs_check => .needs_check,
        .regressed => .regressed,
    } };
    const baseline = before.counters;
    const variant = after.counters;
    if (variant.rows_read > baseline.rows_read) {
        judgement.add("the rows match, but the variant reads more rows than the baseline");
        return judgement;
    }
    if (variant.rows_written > baseline.rows_written) {
        judgement.add(if (variant.rows_read == baseline.rows_read)
            "the rows match and both copies read the same number of rows, but the variant writes more rows"
        else
            "the rows match and the variant reads fewer rows, but the variant writes more rows");
        return judgement;
    }
    if (variant.rows_read == baseline.rows_read) {
        judgement.verdict = .no_effect;
        return judgement;
    }
    judgement.verdict = .improved;
    return judgement;
}

pub fn comparisonExitCode(verdict: Verdict) u8 {
    return switch (verdict) {
        .match => 0,
        .mismatch => 3,
        .incomparable => 4,
    };
}

pub fn samePlan(before: db.Plan, after: db.Plan) bool {
    if (before.rows.len != after.rows.len) return false;
    for (before.rows, after.rows) |b, a| {
        if (!std.mem.eql(u8, b.detail, a.detail)) return false;
        if (parentLine(before, b.parent) != parentLine(after, a.parent)) return false;
    }
    return true;
}

pub fn parentLine(plan: db.Plan, parent: i64) ?usize {
    for (plan.rows, 0..) |row, line| {
        if (row.id == parent) return line;
    }
    return null;
}

const testing = std.testing;

test "order-dependent hints follow the kind of function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const avg = orderHint(arena, "avg");
    try testing.expect(std.mem.startsWith(u8, avg, "avg() adds REAL values in the order they are read"));
    try testing.expect(std.mem.indexOf(u8, avg, "--show-rows") != null);
    try testing.expect(std.mem.indexOf(u8, avg, "baseline-only-row") == null);
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "lag"), "end the ORDER BY in OVER (...) of lag() with a unique column"));
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "json_group_array"), "add ORDER BY inside json_group_array(...)"));
}

const scan_line = [_]db.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};
const search_line = [_]db.PlanRow{.{ .id = 3, .parent = 0, .label = .{ .kind = .search }, .detail = "SEARCH t USING INDEX idx_a (a=?)" }};

fn testMeasurement(rows_read: u32, rows_written: u32) Measurement {
    return .{
        .rows = 1,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = rows_read, .rows_written = rows_written, .fullscan_steps = 0, .vm_steps = 0, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
}

fn expectJudgement(expected: RowVerdict, reason: ?[]const u8, judgement: Judgement) !void {
    try testing.expectEqual(expected, judgement.verdict);
    if (reason) |text| {
        try testing.expectEqual(@as(usize, 1), judgement.reason_count);
        try testing.expect(std.mem.indexOf(u8, judgement.reasons[0], text) != null);
    } else {
        try testing.expectEqual(@as(usize, 0), judgement.reason_count);
    }
}

test "judgeRows a variant that reads fewer rows is improved" {
    try expectJudgement(.improved, null, judgeRows(testMeasurement(100_000, 0), testMeasurement(201, 0)));
    try expectJudgement(.improved, null, judgeRows(testMeasurement(201, 4), testMeasurement(1, 0)));
}

test "judgeRows the same read count is no-effect whatever the times" {
    try expectJudgement(.no_effect, null, judgeRows(testMeasurement(1000, 0), testMeasurement(1000, 0)));
    try expectJudgement(.no_effect, null, judgeRows(testMeasurement(1000, 7), testMeasurement(1000, 2)));
}

test "judgeRows reading more rows is needs-check" {
    try expectJudgement(.needs_check, "reads more rows", judgeRows(testMeasurement(1000, 0), testMeasurement(1001, 0)));
}

test "judgeRows more rows written is needs-check" {
    try expectJudgement(.needs_check, "but the variant writes more", judgeRows(testMeasurement(1000, 0), testMeasurement(10, 1)));
    try expectJudgement(.needs_check, "the variant writes more", judgeRows(testMeasurement(1000, 5), testMeasurement(1000, 6)));
}

test "judgeRowsWith names a worse row count regressed" {
    try expectJudgement(.regressed, "reads more rows", judgeRowsWith(testMeasurement(1000, 0), testMeasurement(1001, 0), .regressed));
    try expectJudgement(.regressed, "the variant writes more", judgeRowsWith(testMeasurement(1000, 5), testMeasurement(1000, 6), .regressed));
    try expectJudgement(.improved, null, judgeRowsWith(testMeasurement(1000, 0), testMeasurement(1, 0), .regressed));
    try expectJudgement(.no_effect, null, judgeRowsWith(testMeasurement(1000, 0), testMeasurement(1000, 0), .regressed));
}

test "judgeMigrationWrite judges a write by the rows read" {
    try expectJudgement(.regressed, "reads more rows", judgeMigrationWrite(testMeasurement(10, 1), testMeasurement(2000, 1)));
    try expectJudgement(.no_effect, "writes more rows", judgeMigrationWrite(testMeasurement(10, 1), testMeasurement(10, 3)));
    try expectJudgement(.no_effect, "writes fewer rows", judgeMigrationWrite(testMeasurement(10, 3), testMeasurement(10, 1)));
    try expectJudgement(.improved, null, judgeMigrationWrite(testMeasurement(2000, 1), testMeasurement(10, 1)));
    try expectJudgement(.no_effect, null, judgeMigrationWrite(testMeasurement(10, 0), testMeasurement(10, 0)));
}

test "judgeRows ignores the plan and the times" {
    const before = testMeasurement(1000, 0);
    var after = testMeasurement(10, 0);
    after.plan = .{ .rows = @constCast(&search_line) };
    try expectJudgement(.improved, null, judgeRows(before, after));
}

test "a collector failure is incomparable with its reason" {
    const expected = [_]struct { failure: result.CollectFailure, reason: []const u8 }{
        .{ .failure = .over_budget, .reason = "the result rows exceed the 64 MiB" },
        .{ .failure = .out_of_memory, .reason = "out of memory while keeping the result rows" },
    };
    for (expected) |entry| {
        var budget: result.Budget = .{};
        var baseline = result.RowCollector.init(testing.allocator, &budget);
        defer baseline.deinit();
        baseline.failure = entry.failure;
        var variant = result.RowCollector.init(testing.allocator, &budget);
        defer variant.deinit();

        const outcome = decide(testing.allocator, testMeasurement(10, 0), testMeasurement(1, 0), &baseline, &variant, .{
            .clues = .{},
            .limit_or_offset = false,
        });
        try testing.expectEqual(Verdict.incomparable, outcome.verdict);
        try testing.expect(outcome.comparison == null);
        try testing.expectEqual(@as(usize, 1), outcome.reason_count);
        try testing.expect(std.mem.indexOf(u8, outcome.reasons[0].text, entry.reason) != null);
    }
}
