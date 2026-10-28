const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const db = @import("../db.zig");
const result_rows = @import("../result.zig");
const sqlite = @import("../sqlite.zig");
const cli_args = @import("args.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_d1 = @import("d1.zig");
const cli_pair = @import("pair.zig");
const cli_query = @import("query.zig");
const cli_report = @import("report.zig");
const cli_suggest = @import("suggest.zig");
const cli_workspace = @import("workspace.zig");

const ExitCode = cli_control.ExitCode;
const WorkDir = cli_workspace.WorkDir;
const QuerySession = cli_query.QuerySession;
const Measurement = cli_comparison.Measurement;

const batch_schema_version: u8 = 1;
const max_entries = 100;
const baseline_cache_bytes: usize = result_rows.max_result_bytes;

var test_baseline_selects: usize = 0;
var test_cache_limit: ?usize = null;

pub fn setTestCacheLimit(limit: ?usize) void {
    comptime std.debug.assert(builtin.is_test);
    test_cache_limit = limit;
}

pub fn takeTestBaselineSelects() usize {
    comptime std.debug.assert(builtin.is_test);
    defer test_baseline_selects = 0;
    return test_baseline_selects;
}

pub const Query = struct {
    label: []const u8,
    path: [:0]const u8,
    sql: [:0]const u8,
    binds: []const db.BindArg,
};

pub const Source = enum {
    manifest,
    suggested,
};

pub const Candidate = struct {
    label: []const u8,
    path: [:0]const u8,
    sql: [:0]const u8,
    source: Source = .manifest,
};

pub const Loaded = struct {
    queries: []const Query,
    candidates: []const Candidate,
};

const Suggested = struct {
    candidates: []const Candidate,
    rejected: usize,
};

const SuggestOutcome = union(enum) {
    ready: Suggested,
    failed: ExitCode,
};

pub const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    d1: ?cli_d1.Resolved = null,
    timeout_ms: u64,
    show_binds: bool = false,
    show_rows: bool = false,
    format: cli_args.Format = .human,
    suggest: bool = false,
    manifest: bool = true,
    work_parent: []const u8,
};

const CandidateStatus = enum {
    compared,
    index_rejected,
    index_timeout,
};

const ResultStatus = enum {
    compared,
    variant_timeout,
};

const CandidateSummary = struct {
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
    size_increase: i128 = 0,
};

const RowsRead = struct {
    baseline: u64,
    variant: u64,
};

const ResultEntry = struct {
    query: []const u8,
    candidate: []const u8,
    status: ResultStatus,
    outcome: ?cli_comparison.Verdict = null,
    judgement: cli_comparison.RowVerdict = .not_judged,
    rows: ?RowsRead = null,
    comparison: []const u8 = "",
};

pub fn load(io: Io, arena: std.mem.Allocator, path: [:0]const u8, stderr: *Io.Writer, suggest: bool) ?Loaded {
    const data = cli_args.readSqlFile(io, arena, path) catch |err| {
        switch (err) {
            error.SqlFileTooLarge => return invalidManifest(stderr, path, "the file is larger than 1 MiB", .{}),
            error.SqlFileContainsNul => return invalidManifest(stderr, path, "it contains a NUL byte", .{}),
            else => {
                stderr.print("error: cannot read the batch manifest '{s}': {s}\n", .{ path, cli_args.fileErrorMessage(err) }) catch {};
                return null;
            },
        }
    };

    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch {
        return invalidManifest(stderr, path, "it is not valid JSON", .{});
    };
    const root = switch (root_value) {
        .object => |object| object,
        else => return invalidManifest(stderr, path, "it must be a JSON object", .{}),
    };
    if (root.get("queries") == null) {
        if (suggest) return invalidManifest(stderr, path, "it must have the key queries", .{});
        return invalidManifest(stderr, path, "it must have exactly the keys queries and candidates", .{});
    }
    var root_keys = root.iterator();
    while (root_keys.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "queries")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "candidates")) continue;
        if (suggest) return invalidManifest(stderr, path, "it must have only the keys queries and candidates", .{});
        return invalidManifest(stderr, path, "it must have exactly the keys queries and candidates", .{});
    }
    if (!suggest and root.get("candidates") == null) {
        return invalidManifest(stderr, path, "it must have exactly the keys queries and candidates", .{});
    }

    const manifest_dir = std.fs.path.dirname(path) orelse ".";

    var queries: std.ArrayList(Query) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;

    const query_values = switch (root.get("queries").?) {
        .array => |array| array.items,
        else => return invalidManifest(stderr, path, "queries must be an array", .{}),
    };
    if (query_values.len < 1 or query_values.len > max_entries) {
        return invalidManifest(stderr, path, "queries must hold 1 to {d} entries", .{max_entries});
    }
    for (query_values, 0..) |query_value, index| {
        const query_object = switch (query_value) {
            .object => |object| object,
            else => return invalidManifest(stderr, path, "query {d} must be an object", .{index + 1}),
        };
        if (query_object.get("select") == null or query_object.count() < 1 or query_object.count() > 2) {
            return invalidManifest(stderr, path, "query {d} must have select and optional binds", .{index + 1});
        }
        var query_keys = query_object.iterator();
        while (query_keys.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "select") and !std.mem.eql(u8, entry.key_ptr.*, "binds")) {
                return invalidManifest(stderr, path, "query {d} must have select and optional binds", .{index + 1});
            }
        }
        const label = switch (query_object.get("select").?) {
            .string => |text| text,
            else => return invalidManifest(stderr, path, "query {d} select must be a string", .{index + 1}),
        };
        if (label.len == 0 or std.mem.indexOfScalar(u8, label, 0) != null) {
            return invalidManifest(stderr, path, "query {d} select must be a non-empty path", .{index + 1});
        }
        for (queries.items) |existing| {
            if (std.mem.eql(u8, existing.label, label)) {
                return invalidManifest(stderr, path, "the select path '{s}' appears more than once", .{label});
            }
        }

        var binds: std.ArrayList(db.BindArg) = .empty;
        if (query_object.get("binds")) |binds_value| {
            const bind_values = switch (binds_value) {
                .array => |array| array.items,
                else => return invalidManifest(stderr, path, "query {d} binds must be an array", .{index + 1}),
            };
            for (bind_values, 0..) |bind_value, bind_index| {
                const text = switch (bind_value) {
                    .string => |text| text,
                    else => return invalidManifest(stderr, path, "query {d} bind {d} must be a string", .{ index + 1, bind_index + 1 }),
                };
                if (std.mem.indexOfScalar(u8, text, 0) != null) {
                    return invalidManifest(stderr, path, "query {d} bind {d} contains a NUL byte", .{ index + 1, bind_index + 1 });
                }
                const raw = arena.dupeSentinel(u8, text, 0) catch return outOfMemory(stderr);
                const bind = cli_args.parseBind(raw) catch |err| {
                    return invalidManifest(stderr, path, "query {d} bind {d}: {s}", .{ index + 1, bind_index + 1, cli_args.parseErrorMessage(err) });
                };
                binds.append(arena, bind) catch return outOfMemory(stderr);
            }
        }

        const resolved = resolvePath(arena, manifest_dir, label) orelse return outOfMemory(stderr);
        queries.append(arena, .{ .label = label, .path = resolved, .sql = undefined, .binds = binds.items }) catch return outOfMemory(stderr);
    }

    const candidate_values: []std.json.Value = if (root.get("candidates")) |value| switch (value) {
        .array => |array| array.items,
        else => return invalidManifest(stderr, path, "candidates must be an array", .{}),
    } else &.{};
    if (suggest) {
        if (candidate_values.len > max_entries) {
            return invalidManifest(stderr, path, "candidates must hold 0 to {d} entries", .{max_entries});
        }
    } else if (candidate_values.len < 1 or candidate_values.len > max_entries) {
        return invalidManifest(stderr, path, "candidates must hold 1 to {d} entries", .{max_entries});
    }
    for (candidate_values, 0..) |candidate_value, index| {
        const candidate_object = switch (candidate_value) {
            .object => |object| object,
            else => return invalidManifest(stderr, path, "candidate {d} must be an object", .{index + 1}),
        };
        if (candidate_object.count() != 1 or candidate_object.get("index_sql") == null) {
            return invalidManifest(stderr, path, "candidate {d} must have only index_sql", .{index + 1});
        }
        const label = switch (candidate_object.get("index_sql").?) {
            .string => |text| text,
            else => return invalidManifest(stderr, path, "candidate {d} index_sql must be a string", .{index + 1}),
        };
        if (label.len == 0 or std.mem.indexOfScalar(u8, label, 0) != null) {
            return invalidManifest(stderr, path, "candidate {d} index_sql must be a non-empty path", .{index + 1});
        }
        if (suggest and std.mem.startsWith(u8, label, cli_suggest.label_prefix)) {
            return invalidManifest(stderr, path, "candidate {d} index_sql must not start with '{s}'", .{ index + 1, cli_suggest.label_prefix });
        }
        for (candidates.items) |existing| {
            if (std.mem.eql(u8, existing.label, label)) {
                return invalidManifest(stderr, path, "the index_sql path '{s}' appears more than once", .{label});
            }
        }
        const resolved = resolvePath(arena, manifest_dir, label) orelse return outOfMemory(stderr);
        candidates.append(arena, .{ .label = label, .path = resolved, .sql = undefined }) catch return outOfMemory(stderr);
    }

    for (queries.items) |*query| {
        query.sql = readSqlFile(io, arena, query.path, query.label, .query, stderr) orelse return null;
    }
    for (candidates.items) |*candidate| {
        candidate.sql = readSqlFile(io, arena, candidate.path, candidate.label, .candidate, stderr) orelse return null;
    }

    return .{
        .queries = queries.items,
        .candidates = candidates.items,
    };
}

const SqlRole = enum { query, candidate };

fn readSqlFile(
    io: Io,
    arena: std.mem.Allocator,
    path: [:0]const u8,
    label: []const u8,
    role: SqlRole,
    stderr: *Io.Writer,
) ?[:0]const u8 {
    return cli_args.readSqlFile(io, arena, path) catch |err| {
        switch (role) {
            .query => stderr.print("error: cannot read the batch SQL file '{s}' for the batch query '{s}': {s}\n", .{ path, label, cli_args.fileErrorMessage(err) }) catch {},
            .candidate => stderr.print("error: cannot read the batch SQL file '{s}' for the batch candidate '{s}': {s}\n", .{ path, label, cli_args.fileErrorMessage(err) }) catch {},
        }
        return null;
    };
}

fn resolvePath(arena: std.mem.Allocator, manifest_dir: []const u8, value: []const u8) ?[:0]const u8 {
    const resolved = std.fs.path.resolveAlloc(arena, &.{ manifest_dir, value }) catch return null;
    return arena.dupeSentinel(u8, resolved, 0) catch null;
}

fn invalidManifest(stderr: *Io.Writer, path: []const u8, comptime format: []const u8, args: anytype) ?Loaded {
    stderr.print("error: the batch manifest '{s}' is not valid: ", .{path}) catch {};
    stderr.print(format, args) catch {};
    stderr.writeByte('\n') catch {};
    return null;
}

fn outOfMemory(stderr: *Io.Writer) ?Loaded {
    stderr.writeAll("error: out of memory\n") catch {};
    return null;
}

const BaselineEntry = struct {
    cached: bool = false,
    keep_rows: bool = false,
    charged: usize = 0,
    before: Measurement = undefined,
    clues: db.Clues = .{},
    budget: result_rows.Budget = .{},
    rows: result_rows.RowCollector = undefined,
};

const BaselineCache = struct {
    entries: []BaselineEntry,
    used: usize = 0,

    fn deinit(self: *BaselineCache, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| {
            if (entry.cached) entry.rows.deinit();
        }
        allocator.free(self.entries);
    }
};

fn baselineCacheLimit() usize {
    if (comptime builtin.is_test) {
        if (test_cache_limit) |limit| return limit;
    }
    return baseline_cache_bytes;
}

fn baselineCacheFits(used: usize, charge: usize, limit: usize) bool {
    if (charge > limit) return false;
    return used <= limit - charge;
}

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    loaded: Loaded,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
    work: *const WorkDir,
) ExitCode {
    if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);

    var baseline: QuerySession = .{};
    var baseline_done = false;
    defer if (!baseline_done) baseline.deinit(.baseline, stderr, cleanup_failed);
    var baseline_failure: ExitCode = .rejected;
    {
        var capture: [2048]u8 = undefined;
        var sink = Io.Writer.fixed(&capture);
        if (!baseline.openDatabase(inputs.baseline_path, .baseline, &sink, &baseline_failure)) {
            reportCaptured(stderr, "error: the batch baseline: ", sink.buffered());
            return baseline_failure;
        }
    }

    for (loaded.queries) |*query| {
        if (!prepareQuery(&baseline, query, stderr)) return .rejected;
    }

    for (loaded.candidates) |*candidate| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        if (!checkCandidate(&baseline, candidate, stderr)) return .rejected;
    }

    var suggest_warnings: std.ArrayList(cli_suggest.Warning) = .empty;
    var candidates: []const Candidate = loaded.candidates;
    var suggested_rejected: usize = 0;
    if (inputs.suggest) {
        switch (suggestCandidates(arena, &baseline, inputs, loaded, &suggest_warnings, stderr)) {
            .ready => |suggested| {
                candidates = suggested.candidates;
                suggested_rejected = suggested.rejected;
            },
            .failed => |code| return code,
        }
    }
    if (candidates.len == 0) return reportNoCandidates(stderr, inputs.manifest, suggested_rejected);

    const tables = arena.alloc([]const u8, candidates.len) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    for (candidates, 0..) |*candidate, index| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        tables[index] = baseline.database.indexTarget(arena, candidate.sql) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return .rejected;
        };
    }

    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());
    const cache_entries = allocator.alloc(BaselineEntry, loaded.queries.len) catch return outOfMemoryCode(stderr);
    for (cache_entries) |*entry| entry.* = .{};
    var baseline_cache: BaselineCache = .{ .entries = cache_entries };
    defer baseline_cache.deinit(allocator);
    var cache_failure: ExitCode = .rejected;
    if (!fillBaselineCache(arena, allocator, &baseline_cache, &baseline, loaded.queries, &control, stderr, &cache_failure)) return cache_failure;

    const baseline_size = batchFileSize(io, inputs.baseline_path, null, stderr) orelse return .rejected;

    const summaries = arena.alloc(CandidateSummary, candidates.len) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    var results: std.ArrayList(ResultEntry) = .empty;

    for (candidates, 0..) |*candidate, index| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);

        var summary: CandidateSummary = .{
            .candidate = candidate.label,
            .source = candidate.source,
            .index_sql_text = candidate.sql,
        };

        if (!resetVariant(io, arena, inputs.baseline_path, inputs.variant_path, candidate.label, stderr)) return .rejected;

        var detail: db.SnapshotDetail = .{};
        var candidate_failed = false;
        work.applyCandidate(candidate.sql, &control, &detail) catch |err| switch (err) {
            error.Timeout => {
                summary.status = .index_timeout;
                summary.failure_code = "index_timeout";
                summary.failure_message = failureMessage(arena, "the CREATE INDEX did not finish within {d} ms", .{inputs.timeout_ms});
                candidate_failed = true;
            },
            error.Interrupted => return cli_control.reportInterrupted(stderr),
            error.ApplyFailed => {
                if (applyFailureIsCandidate(detail.error_code)) {
                    summary.status = .index_rejected;
                    summary.failure_code = "index_rejected";
                    summary.failure_message = truncateUtf8(arena, if (detail.len != 0) detail.text() else "SQLite rejected the CREATE INDEX");
                    candidate_failed = true;
                } else {
                    const reason = if (detail.len != 0) detail.text() else @errorName(err);
                    stderr.print("error: the batch candidate '{s}': the index could not be created: {s}\n", .{ candidate.label, reason }) catch {};
                    return .rejected;
                }
            },
            else => {
                const reason = if (detail.len != 0) detail.text() else @errorName(err);
                stderr.print("error: the batch candidate '{s}': the index could not be created: {s}\n", .{ candidate.label, reason }) catch {};
                return .rejected;
            },
        };

        if (candidate_failed) {
            if (!cleanupVariant(io, arena, inputs.variant_path, candidate.label, stderr)) return .rejected;
            summaries[index] = summary;
            continue;
        }

        const variant_size = batchFileSize(io, inputs.variant_path, candidate.label, stderr) orelse return .rejected;
        summary.size_increase = @as(i128, variant_size) - @as(i128, baseline_size);

        const warnings = baseline.database.tableWarnings(arena, tables[index], &control) catch |err| {
            switch (err) {
                error.Timeout => {
                    stderr.print("error: the batch diagnostics for candidate '{s}' exceeded the time limit of {d} ms\n", .{ candidate.label, inputs.timeout_ms }) catch {};
                    return .timeout;
                },
                error.Interrupted => return cli_control.reportInterrupted(stderr),
                else => {
                    stderr.print("error: the batch diagnostics for candidate '{s}' failed: {s}\n", .{ candidate.label, baseline.message() }) catch {};
                    return .rejected;
                },
            }
        };

        var variant: QuerySession = .{};
        var variant_done = false;
        defer if (!variant_done) variant.deinit(.variant, stderr, cleanup_failed);
        var open_failure: ExitCode = .rejected;
        {
            var capture: [4096]u8 = undefined;
            var sink = Io.Writer.fixed(&capture);
            if (!variant.openDatabase(inputs.variant_path, .variant, &sink, &open_failure)) {
                var prefix_buffer: [512]u8 = undefined;
                const prefix = std.fmt.bufPrint(&prefix_buffer, "error: the batch variant for candidate '{s}': ", .{candidate.label}) catch "error: the batch variant: ";
                reportCaptured(stderr, prefix, sink.buffered());
                return open_failure;
            }
        }

        for (loaded.queries, 0..) |*query, query_index| {
            if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);

            var child_state = std.heap.ArenaAllocator.init(allocator);
            defer child_state.deinit();
            const child = child_state.allocator();

            var rows: cli_pair.RowBuffers = undefined;
            rows.init(child);
            defer rows.deinit();

            const entry = &baseline_cache.entries[query_index];
            var keep_rows = false;
            var clues: db.Clues = .{};
            var before: Measurement = undefined;
            var baseline_rows: *result_rows.RowCollector = undefined;
            if (entry.cached) {
                result_rows.restoreInsertionOrder(&entry.rows);
                keep_rows = entry.keep_rows;
                clues = entry.clues;
                before = entry.before;
                baseline_rows = &entry.rows;
                rows.budget.used = entry.charged;
            } else {
                if (!prepareQuery(&baseline, query, stderr)) return .rejected;
                keep_rows = !baseline.clues().alwaysIncomparable();
                switch (measureBaseline(child, &baseline, query, &control, if (keep_rows) &rows.baseline else null, stderr)) {
                    .measured => |value| before = value,
                    .failed => |code| return code,
                }
                clues = baseline.clues();
                baseline_rows = &rows.baseline;
            }

            if (!prepareVariant(&variant, query, candidate, stderr)) return .rejected;
            const after: Measurement = switch (measureVariant(child, &variant, query, candidate, &control, if (keep_rows) &rows.variant else null, stderr)) {
                .measured => |value| value,
                .timeout => {
                    summary.timeout += 1;
                    results.append(arena, .{
                        .query = query.label,
                        .candidate = candidate.label,
                        .status = .variant_timeout,
                    }) catch return outOfMemoryCode(stderr);
                    continue;
                },
                .failed => |code| return code,
            };

            const outcome = cli_comparison.decide(child, before, after, baseline_rows, &rows.variant, .{
                .clues = db.Clues.merge(clues, variant.clues()),
                .limit_or_offset = db.mentionsLimitOrOffset(query.sql),
            });

            var report: cli_report.Report = .{ .judgement = .{ .verdict = .not_judged } };
            switch (outcome.verdict) {
                .mismatch => {
                    report.judgement.add("the result rows do not match, so the row counts are not judged");
                    summary.mismatch += 1;
                },
                .incomparable => {
                    report.judgement.add("the result rows cannot be compared, so the row counts are not judged");
                    summary.incomparable += 1;
                },
                .match => {
                    report.judgement = cli_comparison.judgeRows(before, after);
                    switch (report.judgement.verdict) {
                        .improved => summary.improved += 1,
                        .no_effect => summary.no_effect += 1,
                        .needs_check => summary.needs_check += 1,
                        .not_judged => {},
                    }
                },
            }
            report.warnings = .{ .no_analyze_stats = warnings.no_analyze_stats, .data_too_small = warnings.data_too_small };
            report.sizes = .{ .baseline = baseline_size, .variant = variant_size };

            const header: cli_report.Header = .{
                .database_path = inputs.database_path,
                .select_path = query.label,
                .index_path = candidate.label,
                .work_parent = inputs.work_parent,
                .sqlite_version = cli_query.sqliteVersion(),
                .sqlite_source_id = cli_query.sqliteSourceId(),
                .binds = query.binds,
                .show_binds = inputs.show_binds,
                .show_rows = inputs.show_rows,
                .exit_code = comparisonExitCode(outcome.verdict),
                .d1 = inputs.d1,
            };
            var rendered: Io.Writer.Allocating = .init(child);
            cli_report.writeJsonTo(&rendered.writer, child, header, before, after, outcome, report, .minified) catch return reportFailure(stderr);
            const comparison = arena.dupe(u8, rendered.written()) catch return outOfMemoryCode(stderr);
            results.append(arena, .{
                .query = query.label,
                .candidate = candidate.label,
                .status = .compared,
                .outcome = outcome.verdict,
                .judgement = report.judgement.verdict,
                .rows = .{ .baseline = before.counters.rows_read, .variant = after.counters.rows_read },
                .comparison = comparison,
            }) catch return outOfMemoryCode(stderr);
        }

        var close_capture: [2048]u8 = undefined;
        var close_sink = Io.Writer.fixed(&close_capture);
        var ignored_cleanup = false;
        variant.finalize();
        variant.close(.variant, &close_sink, &ignored_cleanup);
        variant_done = true;
        if (variant.opened) {
            var prefix_buffer: [512]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buffer, "error: the batch variant for candidate '{s}': ", .{candidate.label}) catch "error: the batch variant: ";
            reportCaptured(stderr, prefix, close_sink.buffered());
            return .rejected;
        }

        if (!cleanupVariant(io, arena, inputs.variant_path, candidate.label, stderr)) return .rejected;
        summaries[index] = summary;
    }

    var close_capture: [2048]u8 = undefined;
    var close_sink = Io.Writer.fixed(&close_capture);
    var ignored_cleanup = false;
    baseline.finalize();
    baseline.close(.baseline, &close_sink, &ignored_cleanup);
    baseline_done = true;
    if (baseline.opened) {
        reportCaptured(stderr, "error: the batch baseline: ", close_sink.buffered());
        return .rejected;
    }

    const order = summaryOrder(arena, summaries) catch return outOfMemoryCode(stderr);
    const recommended = recommendedIndex(summaries, order);
    const code = batchExitCode(summaries, results.items);

    switch (inputs.format) {
        .json => writeBatchJson(stdout, allocator, summaries, order, results.items, suggest_warnings.items, recommended, code) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .human => writeBatchHuman(stdout, inputs, loaded.queries.len, summaries, order, results.items, suggest_warnings.items, recommended) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .kv => unreachable,
    }
    return code;
}

fn fillBaselineCache(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    cache: *BaselineCache,
    session: *QuerySession,
    queries: []const Query,
    control: *db.StepControl,
    stderr: *Io.Writer,
    failure: *ExitCode,
) bool {
    for (queries, 0..) |*query, index| {
        if (cli_control.signalPending()) {
            failure.* = cli_control.reportInterrupted(stderr);
            return false;
        }
        if (!prepareQuery(session, query, stderr)) {
            failure.* = .rejected;
            return false;
        }
        const clues = session.clues();
        const keep_rows = !clues.alwaysIncomparable();
        const entry = &cache.entries[index];
        entry.rows = result_rows.RowCollector.init(allocator, &entry.budget);
        const measured = switch (measureBaseline(arena, session, query, control, if (keep_rows) &entry.rows else null, stderr)) {
            .measured => |value| value,
            .failed => |code| {
                entry.rows.deinit();
                failure.* = code;
                return false;
            },
        };
        if (keep_rows and !baselineCacheFits(cache.used, entry.rows.charged, baselineCacheLimit())) {
            entry.rows.deinit();
            continue;
        }
        entry.before = measured;
        entry.clues = clues;
        entry.keep_rows = keep_rows;
        entry.charged = entry.rows.charged;
        entry.cached = true;
        cache.used += entry.charged;
    }
    return true;
}

fn prepareQuery(session: *QuerySession, query: *const Query, stderr: *Io.Writer) bool {
    var capture: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    var failure: ExitCode = .rejected;
    if (session.prepare(query.sql, query.binds, .baseline, "", &sink, &failure)) return true;
    var prefix_buffer: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "error: the batch query '{s}': ", .{query.label}) catch "error: the batch query: ";
    reportCaptured(stderr, prefix, sink.buffered());
    return false;
}

fn suggestCandidates(
    arena: std.mem.Allocator,
    baseline: *QuerySession,
    inputs: Inputs,
    loaded: Loaded,
    warnings: *std.ArrayList(cli_suggest.Warning),
    stderr: *Io.Writer,
) SuggestOutcome {
    var queries: std.ArrayList(cli_suggest.Query) = .empty;
    for (loaded.queries) |query| {
        queries.append(arena, .{ .label = query.label, .sql = query.sql }) catch return .{ .failed = outOfMemoryCode(stderr) };
    }

    const inspection = cli_suggest.inspectSchema(arena, &baseline.database) catch |err| {
        if (err == error.OutOfMemory) return .{ .failed = outOfMemoryCode(stderr) };
        stderr.writeAll("error: sqlite3expert could not read the schema for --suggest: ") catch {};
        result_rows.writeEscapedText(stderr, baseline.message()) catch {};
        stderr.writeByte('\n') catch {};
        return .{ .failed = .rejected };
    };
    switch (inspection) {
        .ok => {},
        .rejected => |rejection| {
            reportSchemaRejection(stderr, rejection);
            return .{ .failed = .rejected };
        },
    }

    const room = max_entries - @min(loaded.candidates.len, max_entries);
    const limit = @min(cli_suggest.max_statements, room);
    const generated = cli_suggest.generate(arena, inputs.baseline_path, queries.items) catch return .{ .failed = outOfMemoryCode(stderr) };
    if (cli_control.signalPending()) return .{ .failed = cli_control.reportInterrupted(stderr) };

    switch (generated) {
        .open_failed => {
            stderr.writeAll("error: cannot open the baseline ") catch {};
            result_rows.writeText(stderr, inputs.baseline_path) catch {};
            stderr.writeAll(" read-only: the file is missing, is not a database, or is locked\n") catch {};
            return .{ .failed = .rejected };
        },
        .guard_failed => |message| {
            stderr.writeAll("error: ") catch {};
            result_rows.writeEscapedText(stderr, message) catch {};
            stderr.writeByte('\n') catch {};
            return .{ .failed = .rejected };
        },
        .failed => |message| {
            if (loaded.candidates.len == 0) {
                stderr.writeAll("error: ") catch {};
                result_rows.writeEscapedText(stderr, message) catch {};
                stderr.writeByte('\n') catch {};
                stderr.writeAll("hint: Check that the SELECTs are valid read-only queries for this database, or write a candidate CREATE INDEX yourself.\n") catch {};
                return .{ .failed = .rejected };
            }
            warnings.append(arena, .{ .code = "suggest_failed", .message = message }) catch return .{ .failed = outOfMemoryCode(stderr) };
            return .{ .ready = .{ .candidates = loaded.candidates, .rejected = 0 } };
        },
        .ready => |ready| {
            for (ready.warnings) |warning| {
                warnings.append(arena, warning) catch return .{ .failed = outOfMemoryCode(stderr) };
            }
            const build = cli_suggest.accept(arena, &baseline.database, ready.statements, limit) catch return .{ .failed = outOfMemoryCode(stderr) };
            for (build.warnings) |warning| {
                warnings.append(arena, warning) catch return .{ .failed = outOfMemoryCode(stderr) };
            }
            if (build.generated == 0) {
                warnings.append(arena, .{ .code = "no_suggestions", .message = "SQLite suggested no index for these queries" }) catch return .{ .failed = outOfMemoryCode(stderr) };
            }
            const combined = arena.alloc(Candidate, loaded.candidates.len + build.statements.len) catch return .{ .failed = outOfMemoryCode(stderr) };
            @memcpy(combined[0..loaded.candidates.len], loaded.candidates);
            for (build.statements, 0..) |sql, index| {
                const label = std.fmt.allocPrintSentinel(arena, "{s}{d}", .{ cli_suggest.label_prefix, index + 1 }, 0) catch return .{ .failed = outOfMemoryCode(stderr) };
                combined[loaded.candidates.len + index] = .{ .label = label, .path = label, .sql = sql, .source = .suggested };
            }
            return .{ .ready = .{ .candidates = combined, .rejected = build.rejected } };
        },
    }
}

fn reportSchemaRejection(stderr: *Io.Writer, rejection: cli_suggest.SchemaRejection) void {
    stderr.writeAll("error: --suggest: the schema entry is not allowed: ") catch {};
    result_rows.writeText(stderr, rejection.name) catch {};
    stderr.print(": {s}\n", .{rejection.reason}) catch {};
}

fn reportNoCandidates(stderr: *Io.Writer, manifest: bool, rejected: usize) ExitCode {
    if (rejected == 0) {
        stderr.writeAll("error: no candidate index to compare: SQLite suggested no index for these queries\n") catch {};
    } else {
        stderr.print("error: no candidate index to compare: all {d} suggested {s} were rejected\n", .{ rejected, if (rejected == 1) "index" else "indexes" }) catch {};
    }
    if (manifest) {
        stderr.writeAll("hint: Check that a SELECT has a WHERE or ORDER BY clause, or add a candidate index to the manifest.\n") catch {};
    } else {
        stderr.writeAll("hint: Check that the SELECT has a WHERE or ORDER BY clause, or write a candidate CREATE INDEX file and compare it without --suggest.\n") catch {};
    }
    return .rejected;
}

fn prepareVariant(session: *QuerySession, query: *const Query, candidate: *const Candidate, stderr: *Io.Writer) bool {
    var capture: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    var failure: ExitCode = .rejected;
    if (session.prepare(query.sql, query.binds, .variant, "", &sink, &failure)) return true;
    var prefix_buffer: [768]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "error: the batch variant for query '{s}' and candidate '{s}': ", .{ query.label, candidate.label }) catch "error: the batch variant: ";
    reportCaptured(stderr, prefix, sink.buffered());
    return false;
}

fn checkCandidate(session: *QuerySession, candidate: *const Candidate, stderr: *Io.Writer) bool {
    var capture: [2048]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    if (session.checkCreateIndex(candidate.sql, &sink)) return true;
    var prefix_buffer: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "error: the batch candidate '{s}': ", .{candidate.label}) catch "error: the batch candidate: ";
    reportCaptured(stderr, prefix, sink.buffered());
    return false;
}

fn reportCaptured(stderr: *Io.Writer, prefix: []const u8, captured: []const u8) void {
    var text = std.mem.trimEnd(u8, captured, "\n");
    if (std.mem.startsWith(u8, text, "error: ")) text = text["error: ".len..];
    if (text.len == 0) text = "the input was rejected";
    stderr.print("{s}{s}\n", .{ prefix, text }) catch {};
}

const StepResult = union(enum) {
    measured: Measurement,
    failed: ExitCode,
};

const VariantResult = union(enum) {
    measured: Measurement,
    timeout,
    failed: ExitCode,
};

fn measureBaseline(
    arena: std.mem.Allocator,
    session: *QuerySession,
    query: *const Query,
    control: *db.StepControl,
    rows_out: ?*result_rows.RowCollector,
    stderr: *Io.Writer,
) StepResult {
    const plan = session.database.explainPlan(arena, query.sql, query.binds) catch |err| {
        const detail = if (err == error.ExplainFailed and session.database.errorCode() != sqlite.SQLITE_OK)
            session.message()
        else
            @errorName(err);
        stderr.print("error: the batch query '{s}': the query plan could not be read: {s}\n", .{ query.label, detail }) catch {};
        return .{ .failed = .rejected };
    };
    if (comptime builtin.is_test) test_baseline_selects += 1;
    const rows = session.run(control, rows_out) catch |err| {
        return .{ .failed = baselineStepFailure(err, session, control, query.label, stderr) };
    };
    return .{ .measured = .{
        .rows = rows,
        .plan = plan,
        .counters = session.counters(),
        .columns = session.columnCount(),
    } };
}

fn measureVariant(
    arena: std.mem.Allocator,
    session: *QuerySession,
    query: *const Query,
    candidate: *const Candidate,
    control: *db.StepControl,
    rows_out: ?*result_rows.RowCollector,
    stderr: *Io.Writer,
) VariantResult {
    const plan = session.database.explainPlan(arena, query.sql, query.binds) catch |err| {
        const detail = if (err == error.ExplainFailed and session.database.errorCode() != sqlite.SQLITE_OK)
            session.message()
        else
            @errorName(err);
        stderr.print("error: the batch variant for query '{s}' and candidate '{s}': the query plan could not be read: {s}\n", .{ query.label, candidate.label, detail }) catch {};
        return .{ .failed = .rejected };
    };
    const rows = session.run(control, rows_out) catch |err| switch (err) {
        error.Timeout => return .timeout,
        error.Interrupted => return .{ .failed = cli_control.reportInterrupted(stderr) },
        error.StepFailed => {
            stderr.print("error: the batch variant for query '{s}' and candidate '{s}': the SELECT failed: {s}\n", .{ query.label, candidate.label, session.message() }) catch {};
            return .{ .failed = .rejected };
        },
    };
    return .{ .measured = .{
        .rows = rows,
        .plan = plan,
        .counters = session.counters(),
        .columns = session.columnCount(),
    } };
}

fn baselineStepFailure(err: db.StepError, session: *QuerySession, control: *db.StepControl, label: []const u8, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.Timeout => blk: {
            stderr.print("error: the batch baseline SELECT for query '{s}' exceeded the time limit of {d} ms\n", .{ label, control.timeout_ms }) catch {};
            break :blk .timeout;
        },
        error.Interrupted => cli_control.reportInterrupted(stderr),
        error.StepFailed => blk: {
            stderr.print("error: the batch baseline SELECT for query '{s}' failed: {s}\n", .{ label, session.message() }) catch {};
            break :blk .rejected;
        },
    };
}

fn resetVariant(
    io: Io,
    arena: std.mem.Allocator,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,
    label: []const u8,
    stderr: *Io.Writer,
) bool {
    if (!cleanupVariant(io, arena, variant_path, label, stderr)) return false;
    Io.Dir.cwd().copyFile(baseline_path, Io.Dir.cwd(), variant_path, io, .{}) catch |err| {
        stderr.print("error: the batch candidate '{s}': cannot copy the baseline to the variant: {s}\n", .{ label, @errorName(err) }) catch {};
        return false;
    };
    return true;
}

fn cleanupVariant(io: Io, arena: std.mem.Allocator, variant_path: [:0]const u8, label: []const u8, stderr: *Io.Writer) bool {
    if (!deleteIfExists(io, variant_path, label, stderr)) return false;
    const journal = std.fmt.allocPrintSentinel(arena, "{s}-journal", .{variant_path}, 0) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return false;
    };
    return deleteIfExists(io, journal, label, stderr);
}

fn deleteIfExists(io: Io, path: []const u8, label: []const u8, stderr: *Io.Writer) bool {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => {
            stderr.print("error: the batch candidate '{s}': the variant could not be removed: {s}\n", .{ label, @errorName(err) }) catch {};
            return false;
        },
    };
    return true;
}

fn batchFileSize(io: Io, path: [:0]const u8, candidate: ?[]const u8, stderr: *Io.Writer) ?u64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        if (candidate) |label| {
            stderr.print("error: the batch candidate '{s}': cannot read the size of the variant: {s}\n", .{ label, @errorName(err) }) catch {};
        } else {
            stderr.print("error: the batch baseline: cannot read the size of the baseline: {s}\n", .{@errorName(err)}) catch {};
        }
        return null;
    };
    return stat.size;
}

fn truncateUtf8(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var buffer: [512]u8 = undefined;
    const length = cli_control.copyUtf8(&buffer, text);
    return arena.dupe(u8, buffer[0..length]) catch "";
}

fn failureMessage(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, format, args) catch "";
}

fn applyFailureIsCandidate(error_code: c_int) bool {
    return error_code == sqlite.SQLITE_CONSTRAINT or error_code == sqlite.SQLITE_ERROR;
}

fn comparisonExitCode(verdict: cli_comparison.Verdict) u8 {
    return switch (verdict) {
        .match => 0,
        .mismatch => 3,
        .incomparable => 4,
    };
}

fn isEligible(summary: CandidateSummary) bool {
    return summary.status == .compared and
        summary.mismatch == 0 and
        summary.incomparable == 0 and
        summary.needs_check == 0 and
        summary.timeout == 0 and
        summary.improved >= 1;
}

fn eligibleLessThan(summaries: []const CandidateSummary, a: usize, b: usize) bool {
    const left = summaries[a];
    const right = summaries[b];
    if (left.improved != right.improved) return left.improved > right.improved;
    if (left.size_increase != right.size_increase) return left.size_increase < right.size_increase;
    return a < b;
}

fn summaryOrder(arena: std.mem.Allocator, summaries: []const CandidateSummary) ![]usize {
    var order: std.ArrayList(usize) = .empty;
    var eligible: std.ArrayList(usize) = .empty;
    for (summaries, 0..) |summary, index| {
        if (isEligible(summary)) try eligible.append(arena, index);
    }
    std.mem.sort(usize, eligible.items, @as([]const CandidateSummary, summaries), eligibleLessThan);
    for (eligible.items) |index| try order.append(arena, index);
    for (summaries, 0..) |summary, index| {
        if (summary.status == .compared and !isEligible(summary)) try order.append(arena, index);
    }
    for (summaries, 0..) |summary, index| {
        if (summary.status != .compared) try order.append(arena, index);
    }
    return order.items;
}

fn recommendedIndex(summaries: []const CandidateSummary, order: []const usize) ?usize {
    for (order) |index| {
        if (isEligible(summaries[index])) return index;
    }
    return null;
}

fn batchExitCode(summaries: []const CandidateSummary, results: []const ResultEntry) ExitCode {
    var mismatch = false;
    var incomparable = false;
    var timeout = false;
    for (results) |result| {
        switch (result.status) {
            .variant_timeout => timeout = true,
            .compared => switch (result.outcome orelse .match) {
                .mismatch => mismatch = true,
                .incomparable => incomparable = true,
                .match => {},
            },
        }
    }
    for (summaries) |summary| {
        switch (summary.status) {
            .index_timeout => timeout = true,
            .index_rejected, .compared => {},
        }
    }
    if (mismatch) return .mismatch;
    for (summaries) |summary| {
        if (summary.status == .index_rejected) return .rejected;
    }
    if (timeout) return .timeout;
    if (incomparable) return .incomparable;
    return .ok;
}

fn writeBatchJson(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    summaries: []const CandidateSummary,
    order: []const usize,
    results: []const ResultEntry,
    warnings: []const cli_suggest.Warning,
    recommended: ?usize,
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
    try json.write(batch_schema_version);
    try json.objectField("exit_code");
    try json.write(@as(u8, @intCast(@backingInt(code))));
    try json.objectField("recommended");
    if (recommended) |index| {
        try cli_report.writeJsonText(&json, allocator, summaries[index].candidate);
    } else {
        try json.write(null);
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

fn writeBatchHuman(
    stdout: *Io.Writer,
    inputs: Inputs,
    query_count: usize,
    summaries: []const CandidateSummary,
    order: []const usize,
    results: []const ResultEntry,
    warnings: []const cli_suggest.Warning,
    recommended: ?usize,
) !void {
    var candidate_width: usize = "candidate".len;
    for (summaries) |summary| candidate_width = @max(candidate_width, summary.candidate.len);
    var query_width: usize = "query".len;
    for (results) |result| query_width = @max(query_width, result.query.len);
    var result_candidate_width: usize = "candidate".len;
    for (results) |result| result_candidate_width = @max(result_candidate_width, result.candidate.len);

    try stdout.print(
        "batch: {d} {s}, {d} {s}\ndatabase: {s}\nsqlite: {s}\nwork-dir-parent: {s}\n\n",
        .{ query_count, word(query_count, "query", "queries"), summaries.len, word(summaries.len, "candidate", "candidates"), inputs.database_path, cli_query.sqliteVersion(), inputs.work_parent },
    );
    try stdout.writeAll("Summary\n  ");
    try writeCell(stdout, "candidate", candidate_width);
    for ([_][]const u8{ "status", "improved", "no-effect", "needs-check", "mismatch", "incomparable", "timeout", "size increase" }) |header| {
        try stdout.writeAll("  ");
        try writeCell(stdout, header, 12);
    }
    try stdout.writeByte('\n');
    for (order) |index| {
        const summary = summaries[index];
        try stdout.writeAll("  ");
        try writeCell(stdout, summary.candidate, candidate_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, @tagName(summary.status), 12);
        if (summary.status == .compared) {
            var buffers: [6][32]u8 = undefined;
            const counts = [_]u64{ summary.improved, summary.no_effect, summary.needs_check, summary.mismatch, summary.incomparable, summary.timeout };
            for (counts, 0..) |count, position| {
                const text = std.fmt.bufPrint(&buffers[position], "{d}", .{count}) catch "?";
                try stdout.writeAll("  ");
                try writeCell(stdout, text, 12);
            }
            var size_buffer: [48]u8 = undefined;
            const size = sizeText(&size_buffer, summary.size_increase);
            try stdout.writeAll("  ");
            try writeCell(stdout, size, 12);
        } else {
            for (0..7) |_| {
                try stdout.writeAll("  ");
                try writeCell(stdout, "-", 12);
            }
        }
        try stdout.writeByte('\n');
    }

    var suggested_printed = false;
    for (summaries) |summary| {
        if (summary.source != .suggested) continue;
        if (!suggested_printed) {
            try stdout.writeAll("\nSuggested by SQLite:\n");
            suggested_printed = true;
        }
        try stdout.print("  {s}: ", .{summary.candidate});
        try result_rows.writeEscapedText(stdout, summary.index_sql_text);
        try stdout.writeByte('\n');
    }

    try stdout.writeAll("\nRecommendation: ");
    if (recommended) |index| {
        try stdout.writeAll(summaries[index].candidate);
    } else {
        try stdout.writeAll("none");
    }
    try stdout.writeByte('\n');

    try stdout.writeAll("\nResults\n  ");
    try writeCell(stdout, "query", query_width);
    try stdout.writeAll("  ");
    try writeCell(stdout, "candidate", result_candidate_width);
    for ([_][]const u8{ "result", "verdict", "rows read" }) |header| {
        try stdout.writeAll("  ");
        try writeCell(stdout, header, 12);
    }
    try stdout.writeByte('\n');
    for (results) |result| {
        try stdout.writeAll("  ");
        try writeCell(stdout, result.query, query_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, result.candidate, result_candidate_width);
        try stdout.writeAll("  ");
        if (result.status == .variant_timeout) {
            try writeCell(stdout, "-", 12);
            try stdout.writeAll("  ");
            try writeCell(stdout, "timeout", 12);
            try stdout.writeAll("  ");
            try writeCell(stdout, "-", 12);
        } else {
            try writeCell(stdout, resultText(result.outcome orelse .match), 12);
            try stdout.writeAll("  ");
            try writeCell(stdout, result.judgement.text(), 12);
            try stdout.writeAll("  ");
            var buffer: [64]u8 = undefined;
            if (result.rows) |rows| {
                const text = std.fmt.bufPrint(&buffer, "{d} -> {d}", .{ rows.baseline, rows.variant }) catch "?";
                try writeCell(stdout, text, 12);
            } else {
                try writeCell(stdout, "-", 12);
            }
        }
        try stdout.writeByte('\n');
    }

    var failures_printed = false;
    for (order) |index| {
        const summary = summaries[index];
        if (summary.status == .compared) continue;
        if (!failures_printed) {
            try stdout.writeAll("\nRejected candidates\n");
            failures_printed = true;
        }
        try stdout.print("  {s}: {s}: ", .{ summary.candidate, @tagName(summary.status) });
        try result_rows.writeEscapedText(stdout, summary.failure_message);
        try stdout.writeByte('\n');
    }

    for (warnings) |warning| {
        try stdout.print("warning: {s}: ", .{warning.code});
        try result_rows.writeEscapedText(stdout, warning.message);
        try stdout.writeByte('\n');
    }
}

fn word(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

fn writeCell(writer: *Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writer.splatByteAll(' ', width - text.len);
}

fn sizeText(buffer: []u8, increase: i128) []const u8 {
    if (increase > -1024 and increase < 1024) {
        return std.fmt.bufPrint(buffer, "{d} B", .{increase}) catch "";
    }
    if (increase > -1024 * 1024 and increase < 1024 * 1024) {
        const kib = @as(f64, @floatFromInt(increase)) / 1024.0;
        return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{kib}) catch "";
    }
    const mib = @as(f64, @floatFromInt(increase)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buffer, "{d:.2} MiB", .{mib}) catch "";
}

fn resultText(verdict: cli_comparison.Verdict) []const u8 {
    return switch (verdict) {
        .match => "match",
        .mismatch => "mismatch",
        .incomparable => "incomparable",
    };
}

fn outOfMemoryCode(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: out of memory\n") catch {};
    return .rejected;
}

fn reportFailure(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: the report could not be written\n") catch {};
    return .rejected;
}

fn reportWriteFailure(err: anyerror, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.OutOfMemory => outOfMemoryCode(stderr),
        else => reportFailure(stderr),
    };
}

const testing = std.testing;

test "a variant timeout is a candidate failure without an error line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    const variant_path = try tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    defer testing.allocator.free(variant_path);
    try db.createTestDatabase(variant_path,
        \\CREATE TABLE t(a INTEGER);
        \\INSERT INTO t VALUES (1), (2);
    );

    const sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c";
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: ExitCode = .ok;
    var cleanup_failed = false;
    var session: QuerySession = .{};
    defer session.deinit(.variant, &stderr, &cleanup_failed);
    if (!session.open(variant_path, sql, &.{}, .variant, "", &stderr, &failure)) return error.OpenFailed;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var control = db.StepControl.init(testing.io, 1, cli_control.cancelFlag());
    const query: Query = .{ .label = "q.sql", .path = "", .sql = sql, .binds = &.{} };
    const candidate: Candidate = .{ .label = "c.sql", .path = "", .sql = "" };
    const result = measureVariant(arena_state.allocator(), &session, &query, &candidate, &control, null, &stderr);
    switch (result) {
        .timeout => {},
        else => return error.ExpectedVariantTimeout,
    }
    try testing.expectEqualStrings("", stderr.buffered());
}

test "a non-constraint apply failure is fatal" {
    try testing.expect(applyFailureIsCandidate(sqlite.SQLITE_CONSTRAINT));
    try testing.expect(applyFailureIsCandidate(sqlite.SQLITE_ERROR));
    const sqlite_nomem: c_int = 7;
    const sqlite_ioerr: c_int = 10;
    const sqlite_corrupt: c_int = 11;
    const sqlite_full: c_int = 13;
    for ([_]c_int{ 0, sqlite.SQLITE_BUSY, sqlite.SQLITE_READONLY, sqlite_nomem, sqlite_ioerr, sqlite_corrupt, sqlite_full }) |code| {
        try testing.expect(!applyFailureIsCandidate(code));
    }
}

test "summaryOrder puts eligible candidates first by improved and size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var summaries = [_]CandidateSummary{
        .{ .candidate = "first.sql", .status = .compared, .improved = 1, .no_effect = 1, .size_increase = 100 },
        .{ .candidate = "small.sql", .status = .compared, .improved = 1, .no_effect = 1, .size_increase = 50 },
        .{ .candidate = "best.sql", .status = .compared, .improved = 2, .size_increase = 300 },
        .{ .candidate = "plain.sql", .status = .compared, .improved = 0, .no_effect = 2, .size_increase = 10 },
        .{ .candidate = "rejected.sql", .status = .index_rejected, .failure_code = "index_rejected" },
        .{ .candidate = "late.sql", .status = .index_timeout, .failure_code = "index_timeout" },
    };
    const order = try summaryOrder(arena_state.allocator(), &summaries);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0, 3, 4, 5 }, order);
    try testing.expectEqual(@as(?usize, 2), recommendedIndex(&summaries, order));
}

fn batchResult(status: ResultStatus, outcome: ?cli_comparison.Verdict) ResultEntry {
    return .{ .query = "q.sql", .candidate = "c.sql", .status = status, .outcome = outcome };
}

fn batchSummary(status: CandidateStatus) CandidateSummary {
    return .{ .candidate = "c.sql", .status = status };
}

test "batchExitCode keeps 3 > 1 > 124 > 4 > 0" {
    const compared = [_]CandidateSummary{batchSummary(.compared)};
    const rejected = [_]CandidateSummary{batchSummary(.index_rejected)};
    const index_timeout = [_]CandidateSummary{batchSummary(.index_timeout)};
    const none = [_]ResultEntry{};
    const match = [_]ResultEntry{batchResult(.compared, .match)};
    const mismatch = [_]ResultEntry{batchResult(.compared, .mismatch)};
    const incomparable = [_]ResultEntry{batchResult(.compared, .incomparable)};
    const variant_timeout = [_]ResultEntry{batchResult(.variant_timeout, null)};
    const everything = [_]ResultEntry{
        batchResult(.compared, .mismatch),
        batchResult(.compared, .incomparable),
        batchResult(.variant_timeout, null),
    };

    try testing.expectEqual(ExitCode.ok, batchExitCode(&compared, &none));
    try testing.expectEqual(ExitCode.ok, batchExitCode(&compared, &match));
    try testing.expectEqual(ExitCode.incomparable, batchExitCode(&compared, &incomparable));
    try testing.expectEqual(ExitCode.timeout, batchExitCode(&compared, &variant_timeout));
    try testing.expectEqual(ExitCode.rejected, batchExitCode(&rejected, &none));
    try testing.expectEqual(ExitCode.mismatch, batchExitCode(&rejected, &mismatch));
    try testing.expectEqual(ExitCode.timeout, batchExitCode(&index_timeout, &incomparable));
    try testing.expectEqual(ExitCode.rejected, batchExitCode(&rejected, &variant_timeout));
    try testing.expectEqual(ExitCode.mismatch, batchExitCode(&rejected, &everything));
}
