const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const result = @import("../result.zig");
const cli_warnings = @import("../cli/warnings.zig");
const model = @import("model.zig");
const format = @import("format.zig");
const time = @import("time.zig");
const Header = model.Header;
const Report = model.Report;
const Warnings = model.Warnings;
const Error = model.Error;
const Measurement = model.Measurement;
const Outcome = model.Outcome;
const measure_warmup = format.measure_warmup;
const measure_order = format.measure_order;
const measure_scope = format.measure_scope;
const measure_cache = format.measure_cache;
const write_measure_warmup = format.write_measure_warmup;
const write_measure_order = format.write_measure_order;
const write_measure_scope = format.write_measure_scope;
const write_measure_cache = format.write_measure_cache;
const writeStats = format.writeStats;
const writeDuration = format.writeDuration;
const writeEvidence = time.writeEvidence;
const writeBind = format.writeBind;
const writeD1VersionNote = format.writeD1VersionNote;
const d1_caution = format.d1_caution;

pub fn writeSummary(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    header: Header,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
    report: Report,
) Error!void {
    try stdout.print("db: {s}\n", .{header.database_path});
    if (header.write_path) |path| {
        try stdout.print("write: {s}\n", .{path});
    } else {
        try stdout.print("select: {s}\n", .{header.select_path});
    }
    try stdout.print("index-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: {d}\n", .{ header.index_path, before.rows });
    try stdout.print("sqlite: {s}\nsqlite-source-id: {s}\n", .{
        header.sqlite_version, header.sqlite_source_id,
    });
    try writeD1Kv(stdout, header);
    try writePlanAndCounters(stdout, before);
    try stdout.print("measured-on: variant (candidate index applied)\nrows: {d}\n", .{after.rows});
    try writePlanAndCounters(stdout, after);
    if (header.write_path != null) {
        try stdout.print(
            "write-changes-baseline: {d}\nwrite-changes-variant: {d}\nwrite-total-changes-baseline: {d}\nwrite-total-changes-variant: {d}\nwrite-runs: {d}\n",
            .{ before.changes, after.changes, before.total_changes, after.total_changes, before.executions },
        );
    }

    if (header.write_path != null) {
        switch (outcome.verdict) {
            .match => try stdout.writeAll("result: match (RETURNING rows)\n"),
            .mismatch => try stdout.writeAll("result: mismatch (RETURNING rows; the cause is not determined)\n"),
            .incomparable => try stdout.writeAll("result: incomparable\n"),
        }
        try stdout.writeAll("result-kind: returning rows (empty without RETURNING)\n");
    } else {
        switch (outcome.verdict) {
            .match => try stdout.writeAll("result: match (row multiset)\n"),
            .mismatch => try stdout.writeAll("result: mismatch (row multiset; the cause is not determined)\n"),
            .incomparable => try stdout.writeAll("result: incomparable\n"),
        }
    }
    for (outcome.reasons[0..outcome.reason_count]) |reason| {
        try stdout.print("incomparable-reason: {s}\n", .{reason.text});
        if (reason.hint) |hint| try stdout.print("incomparable-hint: {s}\n", .{hint});
    }
    if (outcome.comparison) |comparison| if (!comparison.matched) {
        try stdout.print("baseline-only-rows: {d}\nvariant-only-rows: {d}\n", .{ comparison.baseline_only, comparison.variant_only });
        if (header.show_rows) {
            for (comparison.baselineExamples()) |row| {
                try stdout.writeAll("baseline-only-row: ");
                try result.writeRow(stdout, row);
                try stdout.writeByte('\n');
            }
            for (comparison.variantExamples()) |row| {
                try stdout.writeAll("variant-only-row: ");
                try result.writeRow(stdout, row);
                try stdout.writeByte('\n');
            }
        }
    };
    const order = if (outcome.verdict != .match)
        "not applicable"
    else if (outcome.comparison.?.same_order)
        "same (reference only; not part of the result)"
    else
        "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";
    try stdout.print("row-order: {s}\n", .{order});
    try writeFacts(stdout, allocator, header, report);
}

pub fn writeFacts(stdout: *Io.Writer, allocator: std.mem.Allocator, header: Header, report: Report) Error!void {
    if (header.binds.len == 0) try stdout.writeAll("bind: none\n");
    for (header.binds) |bind| {
        try stdout.writeAll("bind: ");
        try writeBind(stdout, bind, header.show_binds);
        try stdout.writeByte('\n');
    }
    const rounds = if (report.timing) |timing| timing.rounds else 0;
    if (header.write_path != null) {
        try stdout.print(
            \\measure-runs: {d} per copy (each run in a transaction and rolled back)
            \\measure-warmup: {s}
            \\measure-order: {s}
            \\measure-scope: {s}
            \\measure-cache: {s}
            \\work-dir-parent: {s}
            \\zig: {s}
            \\build-mode: {t}
            \\os-arch: {t}-{t}
            \\
        , .{ report.write_runs, write_measure_warmup, write_measure_order, write_measure_scope, write_measure_cache, header.work_parent, builtin.zig_version_string, builtin.mode, builtin.os.tag, builtin.cpu.arch });
    } else {
        try stdout.print(
            \\measure-runs: {d} per copy
            \\measure-warmup: {s}
            \\measure-order: {s}
            \\measure-scope: {s}
            \\measure-cache: {s}
            \\work-dir-parent: {s}
            \\zig: {s}
            \\build-mode: {t}
            \\os-arch: {t}-{t}
            \\
        , .{ rounds, measure_warmup, measure_order, measure_scope, measure_cache, header.work_parent, builtin.zig_version_string, builtin.mode, builtin.os.tag, builtin.cpu.arch });
    }
    if (header.seed) |seed| {
        try stdout.print("seed-data: {s}\nseed: {d}\nseed-rows: {d}\nseed-tables: {d}\n", .{ seed.path, seed.seed, seed.rows, seed.tables.len });
        for (seed.tables) |table| {
            try stdout.print("seed-table: {s} rows={d}\n", .{ table.table, table.rows });
        }
    }
    if (report.timing) |timing| {
        try writeStats(stdout, "time-baseline-ns", timing.baseline);
        try writeStats(stdout, "time-variant-ns", timing.variant);
        if (timing.baseline.median == 0) {
            try stdout.writeAll("time-ratio: n/a (the baseline median is 0)\n");
        } else {
            const ratio = @as(f64, @floatFromInt(timing.variant.median)) / @as(f64, @floatFromInt(timing.baseline.median));
            try stdout.print("time-ratio: {d:.3} (variant median / baseline median)\n", .{ratio});
        }
        try writeEvidence(stdout, timing.evidence);
        try stdout.print("variant-faster-rounds: {d}/{d}\n", .{ timing.variant_faster_rounds, timing.rounds });
    }
    try cli_warnings.writeWarnings(stdout, allocator, report.warnings);
    const sizes = report.sizes;
    try stdout.print(
        \\db-bytes-baseline: {d} (the snapshot file)
        \\db-bytes-variant: {d} (the snapshot file with the candidate index)
        \\db-bytes-increase: {d} (the whole database file, not the index alone)
        \\verdict: {s}
        \\
    , .{ sizes.baseline, sizes.variant, @as(i128, sizes.variant) - @as(i128, sizes.baseline), report.judgement.verdict.text() });
    for (report.judgement.reasons[0..report.judgement.reason_count]) |reason| {
        try stdout.print("verdict-reason: {s}\n", .{reason});
    }
}

fn writeD1Kv(stdout: *Io.Writer, header: Header) Io.Writer.Error!void {
    const d1 = header.d1 orelse return;
    try stdout.print(
        "d1-binding: {s}\nd1-config: {s}\nd1-database-id: {s}\nd1-local-database: {s}\nd1-sqlite-version: {s}\nd1-sqlite-version-note: ",
        .{ d1.binding, d1.config_path, d1.database_id, d1.local_path, d1.sqlite_version },
    );
    try writeD1VersionNote(stdout, header.sqlite_version, d1.sqlite_version);
    try stdout.print("\nd1-caution: {s}\n", .{d1_caution});
}

pub fn writePlanAndCounters(stdout: *Io.Writer, measurement: Measurement) Io.Writer.Error!void {
    for (measurement.plan.rows) |row| {
        try stdout.print("plan: id={d} parent={d} kind={t} covering={} automatic={} detail={s}\n", .{
            row.id, row.parent, row.label.kind, row.label.covering, row.label.automatic, row.detail,
        });
    }
    try stdout.print("rows-read: {d}\nrows-written: {d}\nfullscan-steps: {d}\nvm-steps: {d}\nsort-ops: {d}\nautoindex-rows: {d}\n", .{
        measurement.counters.rows_read, measurement.counters.rows_written, measurement.counters.fullscan_steps, measurement.counters.vm_steps, measurement.counters.sort_ops, measurement.counters.autoindex_rows,
    });
}

test {
    _ = @import("kv_tests.zig");
}
