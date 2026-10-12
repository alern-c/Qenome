//! Comparing the two runs: whether the result rows match, differ, or cannot
//! be compared, and what to try next when they do not.
//!
//! Nothing here opens a connection or writes to a stream: the stage receives
//! finished measurements and row collectors.

const std = @import("std");
const db = @import("../db.zig");
const result = @import("../result.zig");

/// One line of a query plan, as the measurement carries it.
pub const PlanRow = db.PlanRow;

/// Which copy a SELECT ran on, for messages and the summary.
pub const Side = enum { baseline, variant };

/// What one SELECT run on one copy reported.
pub const Measurement = struct {
    rows: u64,
    plan: db.Plan,
    counters: db.Counters,
    columns: c_int,
};

pub const Verdict = enum { match, mismatch, incomparable };

/// The comparison result of the two runs (D-501, D-503, D-506).
pub const Outcome = struct {
    verdict: Verdict,
    /// Null when the rows were not compared.
    comparison: ?result.Comparison = null,
    /// Why the results cannot be compared, one line each, with what to try
    /// next (D-513).
    reasons: [max_reasons]Reason = undefined,
    reason_count: usize = 0,

    const max_reasons = 5;

    const Reason = struct {
        text: []const u8,
        /// Null when there is nothing the user can change in the SELECT.
        hint: ?[]const u8,
    };

    fn addReason(self: *Outcome, text: []const u8, hint: ?[]const u8) void {
        if (self.reason_count == max_reasons) return;
        self.reasons[self.reason_count] = .{ .text = text, .hint = hint };
        self.reason_count += 1;
    }
};

const over_budget_reason = std.fmt.comptimePrint(
    "the result rows exceed the {d} MiB kept for the comparison",
    .{result.max_result_bytes / (1024 * 1024)},
);

/// What the SQL says about how its rows may legitimately differ.
pub const Hints = struct {
    clues: db.Clues,
    /// The SELECT text holds LIMIT or OFFSET (D-504).
    limit_or_offset: bool,
};

/// Turns two finished runs into the result (D-501, D-502, D-504, D-505,
/// D-506, D-507, D-512), in this order:
///
/// 1. A SELECT that changes between runs or reads the schema is never
///    compared.
/// 2. Rows that could not be kept are never reported as a match.
/// 3. Equal rows are a match, whatever the SQL looks like: the match was
///    observed.
/// 4. Differing rows are incomparable when the SQL can read the clock or pick
///    or compute rows by their order, and a mismatch otherwise. The
///    one-sided rows are shown in both cases.
///
/// Every reason comes with a hint on what to try next (D-513), except where
/// the SELECT cannot help. A changed SELECT is another SELECT: the LIMIT hint
/// asks to check its plan again, and the docs say so for every hint. Texts
/// that name a function or a table live in `arena`.
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

/// What to try for an order-dependent function, by its kind (D-513).
fn orderHint(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const sums = [_][]const u8{ "sum", "avg", "total" };
    const windows = [_][]const u8{ "row_number", "ntile", "first_value", "last_value", "nth_value", "lag", "lead" };
    for (sums) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "{s}() adds REAL values in the order they are read, so the results may differ only in the last digits; check the baseline-only-row and variant-only-row lines", name);
    for (windows) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "end the ORDER BY in OVER (...) of {s}() with a unique column, so that every row has a fixed place", name);
    return print(arena, "add ORDER BY inside {s}(...), so that the rows are joined in a fixed order", name);
}

/// Formats one reason or hint that names a function or a table. Running out
/// of memory here prints the format itself, with `{s}` in place of the name;
/// the line stays one `key: value` line.
fn print(arena: std.mem.Allocator, comptime format: []const u8, name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, format, .{name}) catch format;
}

const testing = std.testing;

test "order-dependent hints follow the kind of function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "avg"), "avg() adds REAL values in the order they are read"));
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "lag"), "end the ORDER BY in OVER (...) of lag() with a unique column"));
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "json_group_array"), "add ORDER BY inside json_group_array(...)"));
}
