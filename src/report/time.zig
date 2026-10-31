const std = @import("std");
const Io = std.Io;
const cli_timing = @import("../cli/timing.zig");

pub fn writeEvidence(stdout: *Io.Writer, evidence: cli_timing.Evidence) Io.Writer.Error!void {
    try stdout.print("time-effect: {s} (reference only)\ntime-median-difference-ns: {d} (variant - baseline, paired rounds)\ntime-noise-band-ns: {d} (baseline A/A absolute difference p95; {d} pairs; empirical)\n", .{ cli_timing.effectText(evidence.effect), evidence.median_difference_ns, evidence.noise_band.threshold_ns, evidence.noise_band.pairs });
    if (evidence.confidence_interval) |ci| {
        try stdout.print("time-confidence-interval-ns: [{d}, {d}] (paired median difference; nominal 95%, binomial coverage {d:.6}; assumes independent identically distributed rounds)\n", .{ ci.lower_ns, ci.upper_ns, ci.coverage });
    } else {
        try stdout.print("time-confidence-interval-ns: unavailable ({s})\n", .{evidence.unavailable_reason orelse "unavailable"});
    }
}
