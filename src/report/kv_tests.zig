const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("../db.zig");
const result = @import("../result.zig");
const model = @import("model.zig");
const kv = @import("kv.zig");
const testing = std.testing;
const Header = model.Header;
const Report = model.Report;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const writeSummary = kv.writeSummary;

const scan_line = [_]model.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

test "the kv summary keeps every line of the single-format summary" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]db.BindArg{
        .{ .number = 1, .value = .{ .int = 7 } },
        .{ .number = 2, .value = .{ .text = "secret" } },
    };
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .qenome_version = "0.0.0",
        .binds = &binds,
        .show_binds = false,
    };
    const before: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 200_000, .rows_written = 0, .fullscan_steps = 199_999, .vm_steps = 600_407, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 201, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 710, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .timing = .{
            .baseline = .{ .median = 4_331_750, .p25 = 4_158_324, .p75 = 4_364_397, .min = 4_098_250, .max = 4_465_958 },
            .variant = .{ .median = 37_292, .p25 = 33_198, .p75 = 40_417, .min = 28_583, .max = 71_583 },
            .rounds = 10,
            .variant_faster_rounds = 10,
        },
        .sizes = .{ .baseline = 5_087_232, .variant = 7_258_112 },
        .judgement = .{ .verdict = .improved },
    };
    try writeSummary(&stdout, testing.allocator, header, before, after, outcome, report);
    try testing.expectEqualStrings(
        \\db: db.sqlite
        \\select: select.sql
        \\index-sql: index.sql
        \\measured-on: baseline (candidate index not applied)
        \\rows: 2
        \\sqlite: 0.0.0
        \\sqlite-source-id: test-source-id
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\rows-read: 200000
        \\rows-written: 0
        \\fullscan-steps: 199999
        \\vm-steps: 600407
        \\sort-ops: 0
        \\autoindex-rows: 0
        \\measured-on: variant (candidate index applied)
        \\rows: 2
        \\plan: id=2 parent=0 kind=scan covering=false automatic=false detail=SCAN t
        \\rows-read: 201
        \\rows-written: 0
        \\fullscan-steps: 0
        \\vm-steps: 710
        \\sort-ops: 0
        \\autoindex-rows: 0
        \\result: match (row multiset)
        \\row-order: same (reference only; not part of the result)
        \\bind: 1:int
        \\bind: 2:text (6 bytes)
        \\measure-runs: 10 per copy
        \\measure-warmup: 1 per copy (the run whose rows were compared, not timed)
        \\measure-order: each round: baseline-baseline A/A, then alternating baseline-variant or variant-baseline (ABBA)
        \\measure-scope: sqlite3_step from the reset statement to SQLITE_DONE with the interrupt checks; columns are not read; prepare, bind, and the plan read are not timed
        \\measure-cache: warm; each copy reuses its connection and page cache, and its file was just written
        \\work-dir-parent: /tmp
        \\zig:
    ++ " " ++ builtin.zig_version_string ++ "\nbuild-mode: " ++ @tagName(builtin.mode) ++ "\nos-arch: " ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch) ++ "\n" ++
        \\time-baseline-ns: median=4331750 p25=4158324 p75=4364397 min=4098250 max=4465958 (median 4.33 ms)
        \\time-variant-ns: median=37292 p25=33198 p75=40417 min=28583 max=71583 (median 37.29 us)
        \\time-ratio: 0.009 (variant median / baseline median)
        \\time-effect: insufficient-samples (reference only)
        \\time-median-difference-ns: 0 (variant - baseline, paired rounds)
        \\time-noise-band-ns: 0 (baseline A/A absolute difference p95; 0 pairs; empirical)
        \\time-confidence-interval-ns: unavailable (too-few-rounds)
        \\variant-faster-rounds: 10/10
        \\db-bytes-baseline: 5087232 (the snapshot file)
        \\db-bytes-variant: 7258112 (the snapshot file with the candidate index)
        \\db-bytes-increase: 2170880 (the whole database file, not the index alone)
        \\verdict: improved
        \\
    , stdout.buffered());
}

test "the summary keeps its block order without a database" {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&buffer);
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .int = 7 } }};
    const header: Header = .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .qenome_version = "0.0.0",
        .binds = &binds,
        .show_binds = false,
    };
    const before: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 1, .vm_steps = 2, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const after: model.Measurement = .{
        .rows = 2,
        .plan = .{ .rows = @constCast(&scan_line) },
        .counters = .{ .rows_read = 0, .rows_written = 0, .fullscan_steps = 0, .vm_steps = 1, .sort_ops = 0, .autoindex_rows = 0 },
        .columns = 1,
    };
    const comparison: result.Comparison = .{ .matched = true, .same_order = true };
    const outcome: model.Outcome = .{ .verdict = .match, .comparison = comparison };
    const report: Report = .{
        .sizes = .{ .baseline = 4096, .variant = 8192 },
        .judgement = .{ .verdict = .not_judged },
    };
    try writeSummary(&stdout, testing.allocator, header, before, after, outcome, report);

    const keys = [_][]const u8{
        "db: db.sqlite\nselect: select.sql\nindex-sql: index.sql\n",
        "measured-on: baseline (candidate index not applied)\nrows: 2\n",
        "sqlite: 0.0.0\nsqlite-source-id: test-source-id\n",
        "detail=SCAN t\nrows-read: 0\nrows-written: 0\n",
        "measured-on: variant (candidate index applied)\nrows: 2\n",
        "result: match (row multiset)\n",
        "row-order: ",
        "bind: 1:int\n",
        "measure-runs: 0 per copy\n",
        "verdict: not-judged\n",
    };
    var from: usize = 0;
    for (keys) |key| {
        const at = std.mem.indexOfPos(u8, stdout.buffered(), from, key) orelse {
            std.debug.print("missing or out of order: {s}\n", .{key});
            return error.TestUnexpectedResult;
        };
        from = at + key.len;
    }
}
