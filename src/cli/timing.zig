//! The timed rounds of one comparison, the statistics of the samples, and the
//! verdict that reads the times together with the plans and counters.

const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const Side = cli_comparison.Side;
const Measurement = cli_comparison.Measurement;
const cli_query = @import("query.zig");

/// The timed runs of both copies in nanoseconds, by round.
pub const Timing = struct {
    baseline: []u64,
    variant: []u64,

    /// Counts the rounds the variant won, then sorts the samples for the
    /// quantiles, so the round order is gone afterwards.
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

/// What one timed run needs besides the two sessions.
pub const Options = struct {
    runs: u32,
    timeout_ms: u64,
    /// Least time between two progress lines of the timing (D-603). Tests
    /// set it to 0 to see every line.
    progress_interval_ns: u64 = std.time.ns_per_s,
};

/// Times the SELECT `options.runs` times on each session (D-601). A round
/// runs each session once; even rounds start with the baseline and odd rounds
/// with the variant (ABBA), so a steady drift of the machine falls on both
/// copies.
///
/// A run is `step` from the reset statement to SQLITE_DONE without reading
/// the columns, so it includes the progress checks of `stepAll` but not
/// prepare, bind, or the plan read. The binds survive the reset. The
/// statement counters are cumulative, so the ones of the first run stay the
/// reported ones. Each run gets the full time limit, and a signal is checked
/// between runs too, because a short run never reaches a progress check.
///
/// A round that ends at least `options.progress_interval_ns` after the last
/// progress line writes the next one to stderr and flushes it, outside the
/// timed part (D-603). A stderr that cannot take it gets no further progress
/// lines. Returns null after reporting a failure, with its exit code in
/// `failure`.
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
            // The result of the reset is the one of the previous run, which
            // was already checked.
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

/// Representative value and spread of one copy's timed runs, in nanoseconds.
pub const Stats = struct {
    median: u64,
    p25: u64,
    p75: u64,
    min: u64,
    max: u64,
};

/// Sorts `samples` in place and reads the quantiles by linear interpolation
/// between the closest ranks (position q x (n - 1), Hyndman-Fan type 7), so an
/// even count gets the mean of its two middle samples as the median.
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

/// How far apart two medians may be and still count as the same time:
/// testdata/README.md's measurement noise band (D-602).
const noise_band_percent = 20;

pub const TimeVerdict = enum {
    improved,
    no_effect,
    needs_check,
    not_judged,

    pub fn text(self: TimeVerdict) []const u8 {
        return switch (self) {
            .improved => "improved",
            .no_effect => "no-effect",
            .needs_check => "needs-check",
            .not_judged => "not-judged",
        };
    }
};

pub const Judgement = struct {
    verdict: TimeVerdict,
    reasons: [max_reasons][]const u8 = undefined,
    reason_count: usize = 0,

    const max_reasons = 3;

    pub fn add(self: *Judgement, reason: []const u8) void {
        if (self.reason_count == max_reasons) return;
        self.reasons[self.reason_count] = reason;
        self.reason_count += 1;
    }
};

/// Judges the times together with the plans and counters (D-602), so that
/// time alone never makes a success:
///
/// * improved: no counter grew, the VM steps went down, the variant median is
///   below the noise band under the baseline median, and the variant won
///   every round.
/// * no-effect: the plans and all counters are the same, and the medians
///   are within the noise band of the baseline median.
/// * needs-check: anything else, with the reasons.
pub fn judgeTime(before: Measurement, after: Measurement, times: TimeSummary) Judgement {
    var judgement: Judgement = .{ .verdict = .needs_check };
    const baseline = times.baseline.median;
    const variant = times.variant.median;
    if (baseline == 0) {
        judgement.add("the baseline median is 0 ns, so the times cannot be compared");
        return judgement;
    }
    const b = before.counters;
    const a = after.counters;
    const same_work = std.meta.eql(b, a) and samePlan(before.plan, after.plan);
    const less_work = a.vm_steps < b.vm_steps and a.fullscan_steps <= b.fullscan_steps and
        a.sort_ops <= b.sort_ops and a.autoindex_rows <= b.autoindex_rows;
    const difference = if (variant > baseline) variant - baseline else baseline - variant;
    const within_band = @as(u128, difference) * 100 <= @as(u128, baseline) * noise_band_percent;

    if (same_work) {
        if (within_band) {
            judgement.verdict = .no_effect;
        } else {
            judgement.add(std.fmt.comptimePrint("the plans and counters are the same, but the medians differ by more than {d}%", .{noise_band_percent}));
        }
        return judgement;
    }
    if (!less_work) {
        judgement.add("the plan or the counters changed, but not to fewer VM steps without any other counter growing");
        return judgement;
    }
    if (variant >= baseline or within_band) {
        judgement.add(std.fmt.comptimePrint("the variant runs fewer VM steps, but its median is not more than {d}% below the baseline median", .{noise_band_percent}));
    }
    if (times.variant_faster_rounds != times.rounds) {
        judgement.add("the variant runs fewer VM steps, but it was not faster in every round");
    }
    if (judgement.reason_count == 0) judgement.verdict = .improved;
    return judgement;
}

/// Two plans are the same when their lines say the same and hang under the
/// same lines. The ids themselves are positions in the VM program, which can
/// move without the plan changing, so a parent is compared by its line.
pub fn samePlan(before: db.Plan, after: db.Plan) bool {
    if (before.rows.len != after.rows.len) return false;
    for (before.rows, after.rows) |b, a| {
        if (!std.mem.eql(u8, b.detail, a.detail)) return false;
        if (parentLine(before, b.parent) != parentLine(after, a.parent)) return false;
    }
    return true;
}

/// The line number of the plan line with id `parent`, or null at the top
/// level.
pub fn parentLine(plan: db.Plan, parent: i64) ?usize {
    for (plan.rows, 0..) |row, line| {
        if (row.id == parent) return line;
    }
    return null;
}

const scan_line = [_]db.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};
const search_line = [_]db.PlanRow{.{ .id = 3, .parent = 0, .label = .{ .kind = .search }, .detail = "SEARCH t USING INDEX idx_a (a=?)" }};

/// A first run with the given plan lines and counters.
fn testMeasurement(plan: []const db.PlanRow, fullscan_steps: u32, vm_steps: u32) Measurement {
    return .{
        .rows = 1,
        .plan = .{ .rows = @constCast(plan) },
        .counters = .{ .fullscan_steps = fullscan_steps, .vm_steps = vm_steps, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
}

/// Times whose medians are `baseline` and `variant`, with the variant faster
/// in `faster` of 10 rounds.
fn testTimes(baseline: u64, variant: u64, faster: usize) TimeSummary {
    return .{
        .baseline = .{ .median = baseline, .p25 = baseline, .p75 = baseline, .min = baseline, .max = baseline },
        .variant = .{ .median = variant, .p25 = variant, .p75 = variant, .min = variant, .max = variant },
        .rounds = 10,
        .variant_faster_rounds = faster,
    };
}

fn expectJudgement(expected: TimeVerdict, reason: ?[]const u8, judgement: Judgement) !void {
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
    // Positions 0.75, 1.5 and 2.25 fall between ranks.
    var even = [_]u64{ 40, 10, 30, 20 };
    try testing.expectEqual(Stats{ .median = 25, .p25 = 18, .p75 = 33, .min = 10, .max = 40 }, summarize(&even));
}

test "summarize of one sample has no spread" {
    var one = [_]u64{7};
    try testing.expectEqual(Stats{ .median = 7, .p25 = 7, .p75 = 7, .min = 7, .max = 7 }, summarize(&one));
}

test "judgeTime improved needs fewer steps, a median below the band and every round faster" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const after = testMeasurement(&search_line, 0, 50);
    try expectJudgement(.improved, null, judgeTime(before, after, testTimes(1000, 799, 10)));
}

test "judgeTime one slower round is needs-check" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const after = testMeasurement(&search_line, 0, 50);
    try expectJudgement(.needs_check, "not faster in every round", judgeTime(before, after, testTimes(1000, 100, 9)));
}

test "judgeTime an improvement inside the noise band is needs-check" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const after = testMeasurement(&search_line, 0, 50);
    try expectJudgement(.needs_check, "not more than 20% below", judgeTime(before, after, testTimes(1000, 800, 10)));
}

test "judgeTime the same work within 20 percent is no-effect" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    // The plan id is a VM address, so it may move without the plan changing.
    const moved = [_]db.PlanRow{.{ .id = 7, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};
    const after = testMeasurement(&moved, 1000, 5000);
    try expectJudgement(.no_effect, null, judgeTime(before, after, testTimes(1000, 1200, 0)));
    try expectJudgement(.no_effect, null, judgeTime(before, after, testTimes(1000, 800, 10)));
}

test "judgeTime the same work beyond 20 percent is needs-check" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const after = testMeasurement(&scan_line, 1000, 5000);
    try expectJudgement(.needs_check, "differ by more than 20%", judgeTime(before, after, testTimes(1000, 1201, 0)));
    try expectJudgement(.needs_check, "differ by more than 20%", judgeTime(before, after, testTimes(1000, 799, 10)));
}

test "judgeTime more work on the variant is needs-check even when it is faster" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const more_scans = testMeasurement(&search_line, 1001, 50);
    try expectJudgement(.needs_check, "not to fewer VM steps", judgeTime(before, more_scans, testTimes(1000, 10, 10)));
    const same_steps_other_plan = testMeasurement(&search_line, 1000, 5000);
    try expectJudgement(.needs_check, "not to fewer VM steps", judgeTime(before, same_steps_other_plan, testTimes(1000, 10, 10)));
}

test "judgeTime a zero baseline median is needs-check" {
    const before = testMeasurement(&scan_line, 1000, 5000);
    const after = testMeasurement(&search_line, 0, 50);
    try expectJudgement(.needs_check, "median is 0 ns", judgeTime(before, after, testTimes(0, 0, 0)));
}
const testing = std.testing;

/// The schema of the fixture database the timed rounds run against.
const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

/// A temporary directory with one database in it.
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

/// Opens the fixture database twice, as a stand-in for the two copies, and
/// times its SELECT.
/// Returns false after a failure, as `timeRuns` reported it. After the timed
/// runs, each session steps once more, and its first column must be
/// `expected_first` when that is given.
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
    // Every run reached SQLITE_DONE, so each took some time.
    for (timing.baseline, timing.variant) |b, v| try testing.expect(b > 0 and v > 0);
    if (expected_first) |expected| for ([_]*cli_query.QuerySession{ &baseline, &variant }) |session| {
        try testing.expectEqual(expected, (try session.firstRowInt64()).?);
    };
    return true;
}

test "timed runs keep the binds across the resets" {
    // Without the bind, `a = NULL` would count 0 rows.
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: cli_control.ExitCode = .ok;
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .int = 2 } }};
    try testing.expect(try timeFixture(&fixture, "SELECT count(*) FROM t WHERE a = ?1", 0, &binds, 1, &stderr, &failure));
    // With no interval, every round reports its progress.
    try testing.expectEqualStrings("progress: timed round 1 of 2 done\nprogress: timed round 2 of 2 done\n", stderr.buffered());
}

test "a signal before a short timed run stops the timing" {
    // A short SELECT never reaches a progress check, so the flag is only seen
    // between runs.
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
