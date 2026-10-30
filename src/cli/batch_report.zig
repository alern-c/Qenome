const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_report = @import("report.zig");
const cli_suggest = @import("suggest.zig");

const ExitCode = cli_control.ExitCode;

pub const Source = enum {
    manifest,
    suggested,
    migration,
};

pub const Migration = struct {
    path: [:0]const u8,
    sql: [:0]const u8,
    statements: []const db.MigrationStatement = &.{},
};

pub const CandidateStatus = enum {
    compared,
    index_rejected,
    index_timeout,
};

pub const ResultStatus = enum {
    compared,
    variant_timeout,
};

pub const CandidateSummary = struct {
    candidate: []const u8,
    source: Source = .manifest,
    index_sql_text: []const u8 = "",
    status: CandidateStatus = .compared,
    failure_code: []const u8 = "",
    failure_message: []const u8 = "",
    improved: u64 = 0,
    no_effect: u64 = 0,
    needs_check: u64 = 0,
    mismatch: u64 = 0,
    incomparable: u64 = 0,
    timeout: u64 = 0,
    not_judged: u64 = 0,
    partial_index_warnings: u64 = 0,
    no_analyze_stats: bool = false,
    data_too_small: bool = false,
    size_increase: i128 = 0,
};

pub const RowsRead = struct {
    baseline: u64,
    variant: u64,
};

pub const ResultEntry = struct {
    query: []const u8,
    candidate: []const u8,
    status: ResultStatus,
    outcome: ?cli_comparison.Verdict = null,
    judgement: cli_comparison.RowVerdict = .not_judged,
    rows: ?RowsRead = null,
    baseline_missing: bool = false,
    reason: []const u8 = "",
    variant_rows: ?u64 = null,
    comparison: []const u8 = "",
    partial_index: ?[]const u8 = null,
};

pub fn writeBatchJson(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    summaries: []const CandidateSummary,
    order: []const usize,
    results: []const ResultEntry,
    warnings: []const cli_suggest.Warning,
    recommended: ?usize,
    migration: ?Migration,
    seed: ?cli_report.Seed,
    code: ExitCode,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    try json.objectField("batch_schema_version");
    try json.write(contract.batch_schema_version);
    try json.objectField("exit_code");
    try json.write(@as(u8, @intCast(@backingInt(code))));
    try json.objectField("recommended");
    if (recommended) |index| {
        try cli_report.writeJsonText(&json, allocator, summaries[index].candidate);
    } else {
        try json.write(null);
    }
    if (migration) |value| {
        try json.objectField("migration");
        try json.beginObject();
        try json.objectField("path");
        try cli_report.writeJsonText(&json, allocator, value.path);
        try json.objectField("statements");
        try json.beginArray();
        for (value.statements) |statement| {
            try json.beginObject();
            try json.objectField("kind");
            try json.write(statement.kind.text());
            try json.objectField("sql");
            try cli_report.writeJsonText(&json, allocator, statement.sql);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    if (seed) |value| {
        try json.objectField("seed_data");
        try cli_report.writeJsonSeed(&json, allocator, value);
    }
    try json.objectField("summary");
    try json.beginArray();
    for (order) |index| {
        const summary = summaries[index];
        const compared = summary.status == .compared;
        try json.beginObject();
        try json.objectField("candidate");
        try cli_report.writeJsonText(&json, allocator, summary.candidate);
        try json.objectField("source");
        try json.write(@tagName(summary.source));
        try json.objectField("index_sql_text");
        try cli_report.writeJsonText(&json, allocator, summary.index_sql_text);
        try json.objectField("status");
        try json.write(@tagName(summary.status));
        try json.objectField("failure");
        if (compared) {
            try json.write(null);
        } else {
            try json.beginObject();
            try json.objectField("code");
            try json.write(summary.failure_code);
            try json.objectField("message");
            try cli_report.writeJsonText(&json, allocator, summary.failure_message);
            try json.endObject();
        }
        try json.objectField("improved");
        try writeOptionalCount(&json, compared, summary.improved);
        try json.objectField("no_effect");
        try writeOptionalCount(&json, compared, summary.no_effect);
        try json.objectField("needs_check");
        try writeOptionalCount(&json, compared, summary.needs_check);
        try json.objectField("mismatch");
        try writeOptionalCount(&json, compared, summary.mismatch);
        try json.objectField("incomparable");
        try writeOptionalCount(&json, compared, summary.incomparable);
        try json.objectField("timeout");
        try writeOptionalCount(&json, compared, summary.timeout);
        try json.objectField("not_judged");
        try writeOptionalCount(&json, compared, summary.not_judged);
        try json.objectField("size_increase");
        if (compared) try json.write(summary.size_increase) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("results");
    try json.beginArray();
    for (results) |result| {
        try json.beginObject();
        try json.objectField("query");
        try cli_report.writeJsonText(&json, allocator, result.query);
        try json.objectField("candidate");
        try cli_report.writeJsonText(&json, allocator, result.candidate);
        try json.objectField("status");
        try json.write(@tagName(result.status));
        try json.objectField("comparison");
        if (result.comparison.len == 0) {
            try json.write(null);
        } else {
            try json.print("{s}", .{result.comparison});
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("warnings");
    try json.beginArray();
    for (warnings) |warning| {
        try json.beginObject();
        try json.objectField("code");
        try json.write(warning.code);
        try json.objectField("message");
        try cli_report.writeJsonText(&json, allocator, warning.message);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

fn writeOptionalCount(json: *std.json.Stringify, compared: bool, value: u64) !void {
    if (compared) try json.write(value) else try json.write(null);
}
