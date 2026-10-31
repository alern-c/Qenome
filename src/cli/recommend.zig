const std = @import("std");
const db = @import("../db.zig");
const cli_batch_report = @import("batch_report.zig");

const CandidateSummary = cli_batch_report.CandidateSummary;
const ResultEntry = cli_batch_report.ResultEntry;

const Key = struct {
    rows_read: u64 = 0,
    sorts_removed: u64 = 0,
    size_increase: i128 = 0,
};

pub fn planHasTempBtree(plan: db.Plan) bool {
    for (plan.rows) |row| {
        if (row.label.kind == .temp_btree) return true;
    }
    return false;
}

pub fn isEligible(summary: CandidateSummary) bool {
    return summary.status == .compared and
        summary.mismatch == 0 and
        summary.incomparable == 0 and
        summary.needs_check == 0 and
        summary.timeout == 0 and
        summary.improved >= 1;
}

pub fn order(
    arena: std.mem.Allocator,
    summaries: []const CandidateSummary,
    results: []const ResultEntry,
) ![]usize {
    const keys = try arena.alloc(Key, summaries.len);
    for (summaries, 0..) |summary, index| keys[index] = keyOf(summary, results);

    var ranked: std.ArrayList(usize) = .empty;
    var eligible: std.ArrayList(usize) = .empty;
    for (summaries, 0..) |summary, index| {
        if (isEligible(summary)) try eligible.append(arena, index);
    }
    std.mem.sort(usize, eligible.items, keys, lessThan);
    for (eligible.items) |index| try ranked.append(arena, index);
    for (summaries, 0..) |summary, index| {
        if (summary.status == .compared and !isEligible(summary)) try ranked.append(arena, index);
    }
    for (summaries, 0..) |summary, index| {
        if (summary.status != .compared) try ranked.append(arena, index);
    }
    return ranked.items;
}

pub fn pick(summaries: []const CandidateSummary, ranked: []const usize) ?usize {
    for (ranked) |index| {
        if (isEligible(summaries[index])) return index;
    }
    return null;
}

fn keyOf(summary: CandidateSummary, results: []const ResultEntry) Key {
    var key: Key = .{ .size_increase = summary.size_increase };
    for (results) |result| {
        if (!std.mem.eql(u8, result.candidate, summary.candidate)) continue;
        if (result.rows) |rows| key.rows_read += rows.variant;
        if (result.baseline_temp_btree and !result.variant_temp_btree) key.sorts_removed += 1;
    }
    return key;
}

fn lessThan(keys: []const Key, a: usize, b: usize) bool {
    const left = keys[a];
    const right = keys[b];
    if (left.rows_read != right.rows_read) return left.rows_read < right.rows_read;
    if (left.sorts_removed != right.sorts_removed) return left.sorts_removed > right.sorts_removed;
    if (left.size_increase != right.size_increase) return left.size_increase < right.size_increase;
    return a < b;
}

const testing = std.testing;

test "eligible candidates are ordered by rows read, then a removed sort, then size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const summaries = [_]CandidateSummary{
        .{ .candidate = "large-read.sql", .status = .compared, .improved = 2, .size_increase = 10 },
        .{ .candidate = "small-read.sql", .status = .compared, .improved = 1, .size_increase = 900 },
        .{ .candidate = "small-read-sorted.sql", .status = .compared, .improved = 1, .size_increase = 5000 },
        .{ .candidate = "plain.sql", .status = .compared, .improved = 0, .size_increase = 1 },
        .{ .candidate = "rejected.sql", .status = .index_rejected },
    };
    const results = [_]ResultEntry{
        .{ .query = "q.sql", .candidate = "large-read.sql", .status = .compared, .rows = .{ .baseline = 100, .variant = 80 } },
        .{ .query = "q.sql", .candidate = "small-read.sql", .status = .compared, .rows = .{ .baseline = 100, .variant = 20 } },
        .{
            .query = "q.sql",
            .candidate = "small-read-sorted.sql",
            .status = .compared,
            .rows = .{ .baseline = 100, .variant = 20 },
            .baseline_temp_btree = true,
            .variant_temp_btree = false,
        },
    };
    const ranked = try order(arena_state.allocator(), &summaries, &results);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0, 3, 4 }, ranked);
    try testing.expectEqual(@as(?usize, 2), pick(&summaries, ranked));
}

test "equal rows and no sort fall back to the smaller index, then input order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const summaries = [_]CandidateSummary{
        .{ .candidate = "first.sql", .status = .compared, .improved = 1, .size_increase = 100 },
        .{ .candidate = "small.sql", .status = .compared, .improved = 1, .size_increase = 50 },
        .{ .candidate = "best-count.sql", .status = .compared, .improved = 2, .size_increase = 300 },
        .{ .candidate = "plain.sql", .status = .compared, .improved = 0, .size_increase = 10 },
        .{ .candidate = "rejected.sql", .status = .index_rejected },
        .{ .candidate = "late.sql", .status = .index_timeout },
    };
    const ranked = try order(arena_state.allocator(), &summaries, &.{});
    try testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3, 4, 5 }, ranked);
    try testing.expectEqual(@as(?usize, 1), pick(&summaries, ranked));
}

test "a removed temp b-tree is detected from the plan kind" {
    const sort = [_]db.PlanRow{.{ .id = 1, .parent = 0, .label = .{ .kind = .temp_btree }, .detail = "USE TEMP B-TREE FOR ORDER BY" }};
    const scan = [_]db.PlanRow{.{ .id = 1, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};
    try testing.expect(planHasTempBtree(.{ .rows = @constCast(&sort) }));
    try testing.expect(!planHasTempBtree(.{ .rows = @constCast(&scan) }));
}
