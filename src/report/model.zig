const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("../cli/comparison.zig");
const cli_timing = @import("../cli/timing.zig");
const cli_warnings = @import("../cli/warnings.zig");

pub const Measurement = cli_comparison.Measurement;
pub const Outcome = cli_comparison.Outcome;
pub const Judgement = cli_comparison.Judgement;
pub const Verdict = cli_comparison.Verdict;
pub const Plan = @FieldType(cli_comparison.Measurement, "plan");
pub const PlanRow = cli_comparison.PlanRow;
pub const Warnings = cli_warnings.Warnings;
pub const TimeSummary = cli_timing.TimeSummary;
pub const Stats = cli_timing.Stats;
pub const TimeEffect = cli_timing.TimeEffect;

pub const D1 = struct {
    binding: []const u8,
    config_path: []const u8,
    database_id: []const u8,
    local_path: []const u8,
    sqlite_version: []const u8,
};

pub const SeedTable = struct {
    table: []const u8,
    rows: u64,
};

pub const Seed = struct {
    path: []const u8,
    seed: u64,
    rows: u64,
    tables: []const SeedTable,
};

pub const Header = struct {
    database_path: []const u8,
    select_path: []const u8,
    write_path: ?[]const u8 = null,
    index_path: []const u8,
    work_parent: []const u8,
    sqlite_version: [*:0]const u8,
    sqlite_source_id: [*:0]const u8,
    qenome_version: []const u8,
    binds: []const db.BindArg,
    show_binds: bool,
    show_rows: bool = false,
    exit_code: u8 = 0,
    d1: ?D1 = null,
    seed: ?Seed = null,
};

pub const Sizes = struct {
    baseline: u64 = 0,
    variant: u64 = 0,
};

pub const Report = struct {
    timing: ?TimeSummary = null,
    sizes: Sizes = .{},
    judgement: Judgement,
    warnings: Warnings = .{},
    write_runs: u32 = 0,
};

pub const Error = Io.Writer.Error || std.mem.Allocator.Error;
