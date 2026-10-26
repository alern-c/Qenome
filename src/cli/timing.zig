const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const Side = cli_comparison.Side;
const Measurement = cli_comparison.Measurement;
const cli_query = @import("query.zig");

pub const Timing = struct {
    baseline: []u64,
    variant: []u64,

    pub fn summary(self: Timing) TimeSummary {
        var faster: usize = 0;
        for (self.baseline, self.variant) |baseline, variant| {
            if (variant < baseline) faster += 1;
        }
        return .{
            .baseline = summarize(self.baseline),
            .variant = summarize(self.variant),
            .rounds = self.baseline.len,
            .variant_faster_rounds = faster,
        };
    }
};

pub const Options = struct {
    runs: u32,
    timeout_ms: u64,
    progress_interval_ns: u64 = std.time.ns_per_s,
};

pub fn timeRuns(
    io: Io,
    arena: std.mem.Allocator,
    baseline: *cli_query.QuerySession,
    variant: *cli_query.QuerySession,
    options: Options,
    control: *db.StepControl,
    stderr: *Io.Writer,
    failure: *cli_control.ExitCode,
) ?Timing {
    const timing: Timing = .{
        .baseline = arena.alloc(u64, options.runs) catch return outOfMemory(stderr, failure),
        .variant = arena.alloc(u64, options.runs) catch return outOfMemory(stderr, failure),
    };
    var last_progress = Io.Clock.now(.awake, io).nanoseconds;
    var progress_works = true;
    for (0..options.runs) |round| {
        const order: [2]Side = if (round % 2 == 0) .{ .baseline, .variant } else .{ .variant, .baseline };
        for (order) |side| {
            if (cli_control.signalPending()) {
                failure.* = cli_control.reportInterrupted(stderr);
                return null;
            }
            const session = if (side == .baseline) baseline else variant;
            session.reset();
            const start = Io.Clock.now(.awake, io).nanoseconds;
            _ = session.step(control) catch |err| {
                failure.* = cli_query.reportStepFailure(err, session, options.timeout_ms, side, round + 1, stderr);
                return null;
            };
            const elapsed: u64 = @intCast(Io.Clock.now(.awake, io).nanoseconds - start);
            if (side == .baseline) timing.baseline[round] = elapsed else timing.variant[round] = elapsed;
        }
        const now = Io.Clock.now(.awake, io).nanoseconds;
        if (progress_works and now - last_progress >= options.progress_interval_ns) {
            last_progress = now;
            stderr.print("progress: timed round {d} of {d} done\n", .{ round + 1, options.runs }) catch {
                progress_works = false;
            };
            if (progress_works) stderr.flush() catch {
                progress_works = false;
            };
        }
    }
    return timing;
}

fn outOfMemory(stderr: *Io.Writer, failure: *cli_control.ExitCode) ?Timing {
    stderr.writeAll("error: out of memory\n") catch {};
    failure.* = .rejected;
    return null;
}

pub const Stats = struct {
    median: u64,
    p25: u64,
    p75: u64,
    min: u64,
    max: u64,
};

pub fn summarize(samples: []u64) Stats {
    std.debug.assert(samples.len != 0);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .median = quantile(samples, 0.5),
        .p25 = quantile(samples, 0.25),
        .p75 = quantile(samples, 0.75),
        .min = samples[0],
        .max = samples[samples.len - 1],
    };
}

pub fn quantile(sorted: []const u64, q: f64) u64 {
    const position = q * @as(f64, @floatFromInt(sorted.len - 1));
    const low: usize = @intFromFloat(@floor(position));
    const high = @min(low + 1, sorted.len - 1);
    const low_value: f64 = @floatFromInt(sorted[low]);
    const high_value: f64 = @floatFromInt(sorted[high]);
    return @intFromFloat(@round(low_value + (high_value - low_value) * (position - @floor(position))));
}

pub const TimeSummary = struct {
    baseline: Stats,
    variant: Stats,
    rounds: usize,
    variant_faster_rounds: usize,
};

pub const RowVerdict = enum {
    improved,
    no_effect,
    needs_check,
    not_judged,

    pub fn text(self: RowVerdict) []const u8 {
        return switch (self) {
            .improved => "improved",
            .no_effect => "no-effect",
            .needs_check => "needs-check",
            .not_judged => "not-judged",
        };
    }
};

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
    var judgement: Judgement = .{ .verdict = .needs_check };
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

test "summarize gives the median and quartiles for odd and even counts" {
    var odd = [_]u64{ 50, 10, 40, 20, 30 };
    try testing.expectEqual(Stats{ .median = 30, .p25 = 20, .p75 = 40, .min = 10, .max = 50 }, summarize(&odd));
    var even = [_]u64{ 40, 10, 30, 20 };
    try testing.expectEqual(Stats{ .median = 25, .p25 = 18, .p75 = 33, .min = 10, .max = 40 }, summarize(&even));
}

test "summarize of one sample has no spread" {
    var one = [_]u64{7};
    try testing.expectEqual(Stats{ .median = 7, .p25 = 7, .p75 = 7, .min = 7, .max = 7 }, summarize(&one));
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

test "judgeRows ignores the plan and the times" {
    const before = testMeasurement(1000, 0);
    var after = testMeasurement(10, 0);
    after.plan = .{ .rows = @constCast(&search_line) };
    try expectJudgement(.improved, null, judgeRows(before, after));
}

const testing = std.testing;

const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,

    fn init() !Fixture {
        var fixture: Fixture = .{ .tmp = testing.tmpDir(.{}), .db_path = undefined };
        errdefer fixture.tmp.cleanup();
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "fixture.db", .data = "" });
        fixture.db_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "fixture.db", testing.allocator);
        errdefer testing.allocator.free(fixture.db_path);
        try db.createTestDatabase(fixture.db_path, fixture_schema);
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        self.tmp.cleanup();
    }
};

fn timeFixture(fixture: *Fixture, select_sql: [:0]const u8, timeout_ms: u64, binds: []const db.BindArg, expected_first: ?i64, stderr: *Io.Writer, failure: *cli_control.ExitCode) !bool {
    var cleanup_failed = false;
    var baseline: cli_query.QuerySession = .{};
    defer baseline.close(.baseline, stderr, &cleanup_failed);
    defer baseline.finalize();
    if (!baseline.open(fixture.db_path, select_sql, binds, .baseline, "", stderr, failure)) return false;
    var variant: cli_query.QuerySession = .{};
    defer variant.close(.variant, stderr, &cleanup_failed);
    defer variant.finalize();
    if (!variant.open(fixture.db_path, select_sql, binds, .variant, "", stderr, failure)) return false;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var control = db.StepControl.init(testing.io, timeout_ms, cli_control.cancelFlag());
    const timing = timeRuns(testing.io, arena_state.allocator(), &baseline, &variant, .{
        .runs = 2,
        .timeout_ms = timeout_ms,
        .progress_interval_ns = 0,
    }, &control, stderr, failure) orelse return false;
    for (timing.baseline, timing.variant) |b, v| try testing.expect(b > 0 and v > 0);
    if (expected_first) |expected| for ([_]*cli_query.QuerySession{ &baseline, &variant }) |session| {
        try testing.expectEqual(expected, (try session.firstRowInt64()).?);
    };
    return true;
}

test "timed runs keep the binds across the resets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .int = 2 } }};
    try testing.expect(try timeFixture(&fixture, "SELECT count(*) FROM t WHERE a = ?1", 0, &binds, 1, &stderr, &failure));
    try testing.expectEqualStrings("progress: timed round 1 of 2 done\nprogress: timed round 2 of 2 done\n", stderr.buffered());
}

test "a signal before a short timed run stops the timing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    cli_control.cancelFlag().store(true, .release);
    defer cli_control.clearSignals();
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    try testing.expect(!try timeFixture(&fixture, "SELECT count(*) FROM t", 0, &.{}, null, &stderr, &failure));
    try testing.expectEqual(cli_control.ExitCode.interrupted, failure);
    try testing.expectEqualStrings("error: interrupted by SIGINT\n", stderr.buffered());
}

test "a timed run over the time limit names the copy and the run" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    const sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c";
    try testing.expect(!try timeFixture(&fixture, sql, 1, &.{}, null, &stderr, &failure));
    try testing.expectEqual(cli_control.ExitCode.timeout, failure);
    try testing.expectEqualStrings("error: --select exceeded the time limit of 1 ms on the baseline (timed run 1)\n", stderr.buffered());
}
