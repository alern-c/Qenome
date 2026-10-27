const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const Side = cli_comparison.Side;
const cli_query = @import("query.zig");

pub const Timing = struct {
    baseline: []u64,
    variant: []u64,
    aa_first: []u64,
    aa_second: []u64,

    pub fn summary(self: Timing) TimeSummary {
        var faster: usize = 0;
        for (self.baseline, self.variant) |baseline, variant| {
            if (variant < baseline) faster += 1;
        }
        const evidence = timingEvidence(self.baseline, self.variant, self.aa_first, self.aa_second);
        return .{
            .evidence = evidence,
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
        .aa_first = arena.alloc(u64, options.runs) catch return outOfMemory(stderr, failure),
        .aa_second = arena.alloc(u64, options.runs) catch return outOfMemory(stderr, failure),
    };
    var last_progress = Io.Clock.now(.awake, io).nanoseconds;
    var progress_works = true;
    for (0..options.runs) |round| {
        const order: [2]Side = if (round % 2 == 0) .{ .baseline, .variant } else .{ .variant, .baseline };
        for (0..4) |slot| {
            const side: Side = if (slot < 2) .baseline else order[slot - 2];
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
            if (slot == 0) timing.aa_first[round] = elapsed else if (slot == 1) timing.aa_second[round] = elapsed else if (side == .baseline) timing.baseline[round] = elapsed else timing.variant[round] = elapsed;
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
    evidence: Evidence = .{},
};

pub const ConfidenceInterval = struct {
    method: []const u8 = "paired-sign-median",
    level: f64 = 0.95,
    coverage: f64,
    lower_ns: f64,
    upper_ns: f64,
};

pub const NoiseBand = struct {
    method: []const u8 = "baseline-aa-absolute-difference-p95",
    pairs: usize = 0,
    threshold_ns: u64 = 0,
};

pub const TimeEffect = enum { faster, slower, no_difference, insufficient_samples };

pub fn effectText(effect: TimeEffect) []const u8 {
    return switch (effect) {
        .faster => "faster",
        .slower => "slower",
        .no_difference => "no-difference",
        .insufficient_samples => "insufficient-samples",
    };
}

pub const Evidence = struct {
    noise_band: NoiseBand = .{},
    confidence_interval: ?ConfidenceInterval = null,
    median_difference_ns: f64 = 0,
    effect: TimeEffect = .insufficient_samples,
    unavailable_reason: ?[]const u8 = "too-few-rounds",
};

pub fn timingEvidence(baseline: []const u64, variant: []const u64, aa_first: []const u64, aa_second: []const u64) Evidence {
    std.debug.assert(baseline.len > 0 and baseline.len <= 1000);
    std.debug.assert(baseline.len == variant.len and baseline.len == aa_first.len and baseline.len == aa_second.len);
    var differences: [1000]f64 = undefined;
    var noise: [1000]u64 = undefined;
    for (baseline, variant, aa_first, aa_second, 0..) |b, v, first, second, i| {
        differences[i] = @floatFromInt(@as(i128, v) - @as(i128, b));
        noise[i] = if (first > second) first - second else second - first;
    }
    const n = baseline.len;
    std.mem.sort(f64, differences[0..n], {}, std.sort.asc(f64));
    std.mem.sort(u64, noise[0..n], {}, std.sort.asc(u64));
    const median = if (n % 2 == 0) (differences[n / 2 - 1] + differences[n / 2]) / 2 else differences[n / 2];
    var evidence: Evidence = .{
        .noise_band = .{ .pairs = n, .threshold_ns = noise[(95 * n + 99) / 100 - 1] },
        .median_difference_ns = median,
        .confidence_interval = medianInterval(differences[0..n]),
        .unavailable_reason = if (n < 6) "too-few-rounds" else null,
    };
    for (baseline, variant, aa_first, aa_second) |b, v, first, second| {
        if (b == 0 or v == 0 or first == 0 or second == 0) {
            evidence.confidence_interval = null;
            evidence.unavailable_reason = "zero-duration";
            break;
        }
    }
    if (evidence.unavailable_reason == null and differences[0] == differences[n - 1]) {
        evidence.confidence_interval = null;
        evidence.unavailable_reason = "no-observed-variation";
    }
    if (evidence.confidence_interval) |interval| {
        const threshold: f64 = @floatFromInt(evidence.noise_band.threshold_ns);
        evidence.effect = if (@abs(median) <= threshold or (interval.lower_ns <= 0 and interval.upper_ns >= 0))
            .no_difference
        else if (interval.upper_ns < 0)
            .faster
        else
            .slower;
    }
    return evidence;
}

pub fn medianInterval(sorted: []const f64) ?ConfidenceInterval {
    const n = sorted.len;
    if (n < 6) return null;
    var probability = std.math.pow(f64, 0.5, @floatFromInt(n));
    var tail: f64 = 0;
    var selected: ?usize = null;
    var coverage: f64 = 0;
    for (0..n / 2) |k| {
        const next = tail + probability;
        if (next > 0.025) break;
        tail = next;
        selected = k;
        coverage = 1 - 2 * tail;
        probability *= @as(f64, @floatFromInt(n - k)) / @as(f64, @floatFromInt(k + 1));
    }
    const k = selected orelse return null;
    return .{ .coverage = coverage, .lower_ns = sorted[k], .upper_ns = sorted[n - k - 1] };
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

test "median interval needs six observations and reports conservative coverage" {
    try testing.expect(medianInterval(&.{ 1, 2, 3, 4, 5 }) == null);
    const ci = medianInterval(&.{ 1, 2, 3, 4, 5, 6 }).?;
    try testing.expectEqual(@as(f64, 1), ci.lower_ns);
    try testing.expectEqual(@as(f64, 6), ci.upper_ns);
    try testing.expectEqual(@as(f64, 0.96875), ci.coverage);
    try testing.expectEqual(@as(f64, 0.95), ci.level);
    var values: [1000]f64 = undefined;
    for (&values, 0..) |*v, i| v.* = @floatFromInt(i);
    const large = medianInterval(&values).?;
    try testing.expect(large.coverage >= 0.95 and large.coverage < 0.96);
    try testing.expect(large.lower_ns < 500 and large.upper_ns > 500);
}

test "time evidence uses paired differences and measured AA noise without mutating pairs" {
    const b = [_]u64{ 100, 200, 300, 400, 500, 600 };
    const v = [_]u64{ 70, 160, 250, 340, 430, 520 };
    const aa = [_]u64{ 100, 100, 100, 100, 100, 100 };
    const quiet = [_]u64{ 101, 101, 101, 101, 101, 101 };
    const noisy = [_]u64{ 200, 200, 200, 200, 200, 200 };
    const faster = timingEvidence(&b, &v, &aa, &quiet);
    try testing.expectEqual(TimeEffect.faster, faster.effect);
    try testing.expectEqual(@as(f64, -55), faster.median_difference_ns);
    try testing.expectEqual(@as(u64, 1), faster.noise_band.threshold_ns);
    try testing.expectEqual(TimeEffect.slower, timingEvidence(&v, &b, &aa, &quiet).effect);
    try testing.expectEqual(TimeEffect.no_difference, timingEvidence(&b, &v, &aa, &noisy).effect);
    try testing.expectEqualSlices(u64, &.{ 100, 200, 300, 400, 500, 600 }, &b);
    const crossed = [_]u64{ 99, 202, 297, 404, 495, 606 };
    try testing.expectEqual(TimeEffect.no_difference, timingEvidence(&b, &crossed, &aa, &quiet).effect);
}

test "time evidence handles too few samples zero duration and resolution ties" {
    const short = timingEvidence(&.{10}, &.{5}, &.{10}, &.{11});
    try testing.expect(short.confidence_interval == null);
    try testing.expectEqualStrings("too-few-rounds", short.unavailable_reason.?);
    const b = [_]u64{ 10, 20, 30, 40, 50, 60 };
    const v = [_]u64{ 5, 15, 25, 35, 45, 55 };
    const tied = timingEvidence(&b, &v, &b, &b);
    try testing.expect(tied.confidence_interval == null);
    try testing.expectEqualStrings("no-observed-variation", tied.unavailable_reason.?);
    const zero = timingEvidence(&b, &.{ 0, 1, 2, 3, 4, 5 }, &b, &b);
    try testing.expect(zero.confidence_interval == null);
    try testing.expectEqualStrings("zero-duration", zero.unavailable_reason.?);
    try testing.expectEqual(TimeEffect.insufficient_samples, zero.effect);
}

test "paired median differs from the difference of medians and AA uses nearest rank" {
    const evidence = timingEvidence(&.{ 10, 20, 30, 40, 50, 60 }, &.{ 100, 1, 2, 3, 4, 5 }, &.{ 10, 10, 10, 10, 10, 10 }, &.{ 11, 11, 11, 11, 11, 11 });
    try testing.expectEqual(@as(f64, -32.5), evidence.median_difference_ns);
    var baseline: [20]u64 = @splat(100);
    var variant: [20]u64 = undefined;
    for (&variant, 0..) |*value, i| value.* = 100 + @as(u64, @intCast(i));
    const ranked = timingEvidence(&baseline, &variant, &baseline, &variant);
    try testing.expectEqual(@as(u64, 18), ranked.noise_band.threshold_ns);
}
