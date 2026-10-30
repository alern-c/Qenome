const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const sql_lexer = @import("../sql/lexer.zig");
const db = @import("../db.zig");
const result_rows = @import("../result.zig");
const cli_args = @import("args.zig");
const cli_batch = @import("batch.zig");
const cli_control = @import("control.zig");
const cli_query = @import("query.zig");
const cli_report = @import("report.zig");

const ExitCode = cli_control.ExitCode;
const QuerySession = cli_query.QuerySession;

const rowid_primary_key_name = "INTEGER PRIMARY KEY";

pub const Inputs = struct {
    database_path: [:0]const u8,
    baseline_path: [:0]const u8,
    timeout_ms: u64,
    format: cli_args.Format = .human,
    work_parent: []const u8,
};

const Entry = struct {
    info: db.IndexInfo,
    used: bool = false,
    redundant_by: ?[]const u8 = null,
};

const Cover = struct {
    table: []const u8,
    name: []const u8,
    columns: []const db.IndexColumn,
    partial: bool = false,
    unreadable: bool = false,
    constraint: bool = false,
    synthetic: bool = false,
};

const View = struct {
    table: []const u8,
    name: []const u8,
    columns: []const u8,
    used: bool,
    constraint: ?[]const u8,
    redundant_by: ?[]const u8,
};

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    queries: []const cli_batch.Query,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) ExitCode {
    if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);

    var session: QuerySession = .{};
    defer session.deinit(.baseline, stderr, cleanup_failed);
    {
        var capture: [2048]u8 = undefined;
        var sink = Io.Writer.fixed(&capture);
        var failure: ExitCode = .rejected;
        if (!session.openDatabase(inputs.baseline_path, .baseline, &sink, &failure)) {
            reportCaptured(stderr, "error: the index audit baseline: ", sink.buffered());
            return failure;
        }
    }

    var control = db.StepControl.init(io, inputs.timeout_ms, cli_control.cancelFlag());
    const catalog = session.database.readIndexCatalog(arena, &control) catch |err| {
        return reportCatalogFailure(err, &session, inputs.timeout_ms, stderr);
    };

    const entries = arena.alloc(Entry, catalog.indexes.len) catch return outOfMemoryCode(stderr);
    for (catalog.indexes, 0..) |info, index| entries[index] = .{ .info = info };
    std.mem.sort(Entry, entries, {}, entryLessThan);
    const names = arena.alloc([]const u8, entries.len) catch return outOfMemoryCode(stderr);
    for (entries, 0..) |entry, index| names[index] = entry.info.name;

    var indexed_by = false;
    for (queries) |query| {
        if (cli_control.signalPending()) return cli_control.reportInterrupted(stderr);
        if (!prepareQuery(&session, query, stderr)) return .rejected;
        if (mentionsIndexedBy(query.sql)) indexed_by = true;
        const plan = session.database.explainPlanBounded(arena, query.sql, query.binds, &control) catch |err| {
            return reportPlanFailure(err, &session, query, inputs.timeout_ms, stderr);
        };
        for (plan.rows) |row| {
            const name = db.usedIndexName(row.detail, names) orelse continue;
            for (entries) |*entry| {
                if (std.mem.eql(u8, entry.info.name, name)) {
                    entry.used = true;
                    break;
                }
            }
        }
        plan.deinit(arena);
    }

    if (!indexed_by) markRedundant(arena, entries, catalog) catch return outOfMemoryCode(stderr);

    switch (inputs.format) {
        .json => writeJson(stdout, allocator, inputs, queries.len, entries, !indexed_by) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .human => writeHuman(stdout, arena, inputs, queries.len, entries, !indexed_by) catch |err| {
            return reportWriteFailure(err, stderr);
        },
        .kv => unreachable,
    }
    return .ok;
}

fn isBoundaryByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn mentionsIndexedBy(sql: []const u8) bool {
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(sql, at, "indexed")) |found| {
        at = found + 1;
        if (found != 0 and isBoundaryByte(sql[found - 1])) continue;
        const index = sql_lexer.skipTrivia(sql, found + "indexed".len);
        if (index + 2 > sql.len) continue;
        if (!std.ascii.eqlIgnoreCase(sql[index .. index + 2], "by")) continue;
        const after = index + 2;
        if (after == sql.len or !isBoundaryByte(sql[after])) return true;
    }
    return false;
}

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    const table_order = std.mem.order(u8, left.info.table, right.info.table);
    if (table_order != .eq) return table_order == .lt;
    return std.mem.order(u8, left.info.name, right.info.name) == .lt;
}

fn isConstraint(info: db.IndexInfo) bool {
    return info.unique or info.origin == .primary_key;
}

fn constraintTag(info: db.IndexInfo) ?[]const u8 {
    if (info.origin == .primary_key) return "primary_key";
    if (info.unique) return "unique";
    return null;
}

fn constraintLabel(info: db.IndexInfo) ?[]const u8 {
    if (info.origin == .primary_key) return "PRIMARY KEY";
    if (info.unique) return "UNIQUE";
    return null;
}

fn markRedundant(arena: std.mem.Allocator, entries: []Entry, catalog: db.IndexCatalog) !void {
    const covers = try arena.alloc(Cover, catalog.indexes.len + catalog.rowid_primary_keys.len);
    var at: usize = 0;
    for (entries) |entry| {
        covers[at] = .{
            .table = entry.info.table,
            .name = entry.info.name,
            .columns = entry.info.columns,
            .partial = entry.info.partial,
            .unreadable = entry.info.unreadable,
            .constraint = isConstraint(entry.info),
        };
        at += 1;
    }
    for (catalog.rowid_primary_keys) |key| {
        const columns = try arena.alloc(db.IndexColumn, 1);
        columns[0] = .{ .name = key.column, .collation = "BINARY", .descending = false };
        covers[at] = .{
            .table = key.table,
            .name = rowid_primary_key_name,
            .columns = columns,
            .constraint = true,
            .synthetic = true,
        };
        at += 1;
    }

    for (entries) |*entry| {
        if (isConstraint(entry.info)) continue;
        if (entry.info.partial or entry.info.unreadable) continue;
        for (covers) |cover| {
            if (!std.ascii.eqlIgnoreCase(cover.table, entry.info.table)) continue;
            if (!cover.synthetic and std.mem.eql(u8, cover.name, entry.info.name)) continue;
            if (!coveredBy(entry.info, cover)) continue;
            entry.redundant_by = cover.name;
            break;
        }
    }
}

fn coveredBy(info: db.IndexInfo, cover: Cover) bool {
    if (cover.partial or cover.unreadable) return false;
    if (info.columns.len == 0 or cover.columns.len < info.columns.len) return false;
    for (info.columns, cover.columns[0..info.columns.len]) |left, right| {
        if (!std.ascii.eqlIgnoreCase(left.name, right.name)) return false;
        if (left.descending != right.descending) return false;
        if (!std.ascii.eqlIgnoreCase(left.collation, right.collation)) return false;
    }
    if (info.columns.len < cover.columns.len) return true;
    if (cover.synthetic or cover.constraint) return true;
    return std.mem.order(u8, info.name, cover.name) == .gt;
}

fn prepareQuery(session: *QuerySession, query: cli_batch.Query, stderr: *Io.Writer) bool {
    var capture: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    var failure: ExitCode = .rejected;
    if (session.prepare(query.sql, query.binds, .baseline, "", &sink, &failure)) return true;
    stderr.writeAll("error: the index audit query '") catch {};
    result_rows.writeEscapedText(stderr, query.label) catch {};
    reportCaptured(stderr, "': ", sink.buffered());
    return false;
}

fn reportCaptured(stderr: *Io.Writer, prefix: []const u8, captured: []const u8) void {
    var text = std.mem.trimEnd(u8, captured, "\n");
    if (std.mem.startsWith(u8, text, "error: ")) text = text["error: ".len..];
    if (text.len == 0) text = "the input was rejected";
    stderr.print("{s}{s}\n", .{ prefix, text }) catch {};
}

fn reportCatalogFailure(err: anyerror, session: *QuerySession, timeout_ms: u64, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.OutOfMemory => outOfMemoryCode(stderr),
        error.Timeout => {
            stderr.print("error: the index audit could not read the index catalog within the time limit of {d} ms\n", .{timeout_ms}) catch {};
            return .timeout;
        },
        error.Interrupted => cli_control.reportInterrupted(stderr),
        else => {
            const detail = if (session.database.message().len != 0) session.database.message() else @errorName(err);
            stderr.print("error: the index audit could not read the index catalog: {s}\n", .{detail}) catch {};
            return .rejected;
        },
    };
}

fn reportPlanFailure(err: anyerror, session: *QuerySession, query: cli_batch.Query, timeout_ms: u64, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.OutOfMemory => outOfMemoryCode(stderr),
        error.Interrupted => cli_control.reportInterrupted(stderr),
        error.Timeout => {
            stderr.writeAll("error: the index audit query '") catch {};
            result_rows.writeEscapedText(stderr, query.label) catch {};
            stderr.print("' exceeded the time limit of {d} ms\n", .{timeout_ms}) catch {};
            return .timeout;
        },
        else => {
            const detail = if (session.database.message().len != 0) session.database.message() else @errorName(err);
            stderr.writeAll("error: the index audit query '") catch {};
            result_rows.writeEscapedText(stderr, query.label) catch {};
            stderr.print("': the query plan could not be read: {s}\n", .{detail}) catch {};
            return .rejected;
        },
    };
}

fn escapedCopy(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try result_rows.writeEscapedText(&out.writer, text);
    return allocator.dupe(u8, out.written());
}

fn columnsText(allocator: std.mem.Allocator, columns: []const db.IndexColumn) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('(');
    for (columns, 0..) |column, index| {
        if (index != 0) try out.writer.writeAll(", ");
        try result_rows.writeEscapedText(&out.writer, column.name);
    }
    try out.writer.writeByte(')');
    return allocator.dupe(u8, out.written());
}

fn unusedNote(info: db.IndexInfo) []const u8 {
    if (info.partial and info.unreadable) return "partial and expression index; not compared with other indexes";
    if (info.partial) return "partial index; a different bound value may use it";
    if (info.unreadable) return "expression index; not compared with other indexes";
    return "-";
}

fn writeHuman(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    query_count: usize,
    entries: []const Entry,
    redundancy_judged: bool,
) !void {
    const views = try allocator.alloc(View, entries.len);
    for (entries, 0..) |entry, index| {
        views[index] = .{
            .table = try escapedCopy(allocator, entry.info.table),
            .name = try escapedCopy(allocator, entry.info.name),
            .columns = try columnsText(allocator, entry.info.columns),
            .used = entry.used,
            .constraint = constraintLabel(entry.info),
            .redundant_by = if (entry.redundant_by) |name| try escapedCopy(allocator, name) else null,
        };
    }

    try stdout.print("index audit: {d} {s}, {d} {s}\n", .{
        query_count,
        word(query_count, "query", "queries"),
        entries.len,
        word(entries.len, "index", "indexes"),
    });
    try stdout.print("database: {s}\nsqlite: {s}\nwork-dir-parent: {s}\n", .{ inputs.database_path, cli_query.sqliteVersion(), inputs.work_parent });

    try stdout.writeAll("\nUnused in this manifest\n");
    var unused_printed = false;
    var unused_table_width: usize = "table".len;
    var unused_name_width: usize = "index".len;
    var unused_columns_width: usize = "columns".len;
    for (views) |view| {
        if (view.constraint != null or view.used) continue;
        unused_printed = true;
        unused_table_width = @max(unused_table_width, view.table.len);
        unused_name_width = @max(unused_name_width, view.name.len);
        unused_columns_width = @max(unused_columns_width, view.columns.len);
    }
    if (unused_printed) {
        try stdout.writeAll("  ");
        try writeCell(stdout, "table", unused_table_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, "index", unused_name_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, "columns", unused_columns_width);
        try stdout.writeAll("  note\n");
        for (entries, views) |entry, view| {
            if (view.constraint != null or view.used) continue;
            try stdout.writeAll("  ");
            try writeCell(stdout, view.table, unused_table_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, view.name, unused_name_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, view.columns, unused_columns_width);
            try stdout.print("  {s}\n", .{unusedNote(entry.info)});
        }
    } else {
        try stdout.writeAll("  (none)\n");
    }

    try stdout.writeAll("\nRedundant candidates\n");
    if (!redundancy_judged) {
        try stdout.writeAll("  (not judged: a manifest SELECT uses INDEXED BY)\n");
    } else {
        var redundant_printed = false;
        var redundant_table_width: usize = "table".len;
        var redundant_name_width: usize = "index".len;
        var redundant_columns_width: usize = "columns".len;
        var redundant_cover_width: usize = "covered by".len;
        for (views) |view| {
            if (view.constraint != null) continue;
            const cover = view.redundant_by orelse continue;
            redundant_printed = true;
            redundant_table_width = @max(redundant_table_width, view.table.len);
            redundant_name_width = @max(redundant_name_width, view.name.len);
            redundant_columns_width = @max(redundant_columns_width, view.columns.len);
            redundant_cover_width = @max(redundant_cover_width, cover.len);
        }
        if (redundant_printed) {
            try stdout.writeAll("  ");
            try writeCell(stdout, "table", redundant_table_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, "index", redundant_name_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, "columns", redundant_columns_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, "covered by", redundant_cover_width);
            try stdout.writeByte('\n');
            for (views) |view| {
                if (view.constraint != null) continue;
                const cover = view.redundant_by orelse continue;
                try stdout.writeAll("  ");
                try writeCell(stdout, view.table, redundant_table_width);
                try stdout.writeAll("  ");
                try writeCell(stdout, view.name, redundant_name_width);
                try stdout.writeAll("  ");
                try writeCell(stdout, view.columns, redundant_columns_width);
                try stdout.writeAll("  ");
                try writeCell(stdout, cover, redundant_cover_width);
                try stdout.writeByte('\n');
            }
        } else {
            try stdout.writeAll("  (none)\n");
        }
    }

    try stdout.writeAll("\nKept for constraints\n");
    var constraint_printed = false;
    var constraint_table_width: usize = "table".len;
    var constraint_name_width: usize = "index".len;
    var constraint_kind_width: usize = "constraint".len;
    var constraint_columns_width: usize = "columns".len;
    for (views) |view| {
        const kind = view.constraint orelse continue;
        constraint_printed = true;
        constraint_table_width = @max(constraint_table_width, view.table.len);
        constraint_name_width = @max(constraint_name_width, view.name.len);
        constraint_kind_width = @max(constraint_kind_width, kind.len);
        constraint_columns_width = @max(constraint_columns_width, view.columns.len);
    }
    if (constraint_printed) {
        try stdout.writeAll("  ");
        try writeCell(stdout, "table", constraint_table_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, "index", constraint_name_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, "constraint", constraint_kind_width);
        try stdout.writeAll("  ");
        try writeCell(stdout, "columns", constraint_columns_width);
        try stdout.writeByte('\n');
        for (views) |view| {
            const kind = view.constraint orelse continue;
            try stdout.writeAll("  ");
            try writeCell(stdout, view.table, constraint_table_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, view.name, constraint_name_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, kind, constraint_kind_width);
            try stdout.writeAll("  ");
            try writeCell(stdout, view.columns, constraint_columns_width);
            try stdout.writeByte('\n');
        }
    } else {
        try stdout.writeAll("  (none)\n");
    }

    try stdout.writeAll(
        \\
        \\Notes
        \\  Unused means the plans for this manifest did not name the index. It is not
        \\  a drop instruction: UPDATE, DELETE, foreign-key maintenance, and queries
        \\  outside this manifest are not planned here. An index used only for ORDER BY
        \\  or GROUP BY appears in these plans, so it is not listed as unused.
        \\  A partial index was unused for these bound values, and a different value
        \\  can change the plan.
        \\  A redundant candidate can be replaced by the index in "covered by": its
        \\  key columns are a prefix of that index with the same collation and order.
        \\
    );
}

fn writeJson(
    stdout: *Io.Writer,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    query_count: usize,
    entries: []const Entry,
    redundancy_judged: bool,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    try json.objectField("audit_schema_version");
    try json.write(contract.audit_schema_version);
    try json.objectField("exit_code");
    try json.write(@as(u8, 0));
    try json.objectField("database");
    try cli_report.writeJsonText(&json, allocator, inputs.database_path);
    try json.objectField("queries");
    try json.write(query_count);
    try json.objectField("redundancy_judged");
    try json.write(redundancy_judged);
    try json.objectField("indexes");
    try json.beginArray();
    for (entries) |entry| {
        const constraint = constraintTag(entry.info);
        try json.beginObject();
        try json.objectField("name");
        try cli_report.writeJsonText(&json, allocator, entry.info.name);
        try json.objectField("table");
        try cli_report.writeJsonText(&json, allocator, entry.info.table);
        try json.objectField("columns");
        try json.beginArray();
        for (entry.info.columns) |column| {
            try cli_report.writeJsonText(&json, allocator, column.name);
        }
        try json.endArray();
        try json.objectField("unique");
        try json.write(entry.info.unique);
        try json.objectField("partial");
        try json.write(entry.info.partial);
        try json.objectField("expression");
        try json.write(entry.info.unreadable);
        try json.objectField("constraint");
        if (constraint) |tag| try json.write(tag) else try json.write(null);
        try json.objectField("used");
        if (constraint != null) try json.write(null) else try json.write(entry.used);
        try json.objectField("redundant_by");
        if (entry.redundant_by) |name| try cli_report.writeJsonText(&json, allocator, name) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeByte('\n');
    try stdout.writeAll(out.written());
}

fn word(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

fn writeCell(writer: *Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writer.splatByteAll(' ', width - text.len);
}

fn outOfMemoryCode(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: out of memory\n") catch {};
    return .rejected;
}

fn reportFailure(stderr: *Io.Writer) ExitCode {
    stderr.writeAll("error: the index audit report could not be written\n") catch {};
    return .rejected;
}

fn reportWriteFailure(err: anyerror, stderr: *Io.Writer) ExitCode {
    return switch (err) {
        error.OutOfMemory => outOfMemoryCode(stderr),
        else => reportFailure(stderr),
    };
}

const testing = std.testing;

fn testEntry(name: []const u8, table: []const u8, columns: []db.IndexColumn, options: struct {
    unique: bool = false,
    partial: bool = false,
    unreadable: bool = false,
    origin: db.IndexOrigin = .created,
}) Entry {
    return .{ .info = .{
        .name = name,
        .table = table,
        .origin = options.origin,
        .unique = options.unique,
        .partial = options.partial,
        .unreadable = options.unreadable,
        .columns = columns,
    } };
}

test "a prefix with the same collation and order is a redundancy candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = [_]db.IndexColumn{.{ .name = "a", .collation = "BINARY", .descending = false }};
    const ab = [_]db.IndexColumn{
        .{ .name = "a", .collation = "BINARY", .descending = false },
        .{ .name = "b", .collation = "BINARY", .descending = false },
    };
    const entries = try arena.alloc(Entry, 2);
    entries[0] = testEntry("ix_a", "t", @constCast(&a), .{});
    entries[1] = testEntry("ix_ab", "t", @constCast(&ab), .{});
    const catalog: db.IndexCatalog = .{ .indexes = try arena.dupe(db.IndexInfo, &[_]db.IndexInfo{ entries[0].info, entries[1].info }) };
    try markRedundant(arena, entries, catalog);
    try testing.expectEqualStrings("ix_ab", entries[0].redundant_by.?);
    try testing.expect(entries[1].redundant_by == null);
}

test "a collation, order, partial, or unique index is not a plain redundancy candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = [_]db.IndexColumn{.{ .name = "a", .collation = "BINARY", .descending = false }};
    const a_desc = [_]db.IndexColumn{.{ .name = "a", .collation = "BINARY", .descending = true }};
    const a_nocase = [_]db.IndexColumn{.{ .name = "a", .collation = "NOCASE", .descending = false }};
    const a_text = [_]db.IndexColumn{.{ .name = "a", .collation = "BINARY", .descending = false }};
    const entries = try arena.alloc(Entry, 5);
    entries[0] = testEntry("ix_a", "t", @constCast(&a), .{});
    entries[1] = testEntry("ix_desc", "t", @constCast(&a_desc), .{});
    entries[2] = testEntry("ix_nocase", "t", @constCast(&a_nocase), .{});
    entries[3] = testEntry("ix_part", "t", @constCast(&a_text), .{ .partial = true });
    entries[4] = testEntry("ix_unique", "t", @constCast(&a_text), .{ .unique = true });
    const catalog: db.IndexCatalog = .{ .indexes = try arena.dupe(db.IndexInfo, &[_]db.IndexInfo{
        entries[0].info,
        entries[1].info,
        entries[2].info,
        entries[3].info,
        entries[4].info,
    }) };
    try markRedundant(arena, entries, catalog);
    try testing.expectEqualStrings("ix_unique", entries[0].redundant_by.?);
    try testing.expect(entries[1].redundant_by == null);
    try testing.expect(entries[2].redundant_by == null);
    try testing.expect(entries[3].redundant_by == null);
    try testing.expect(entries[4].redundant_by == null);
}

test "an equal index is reported once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = [_]db.IndexColumn{.{ .name = "a", .collation = "BINARY", .descending = false }};
    const entries = try arena.alloc(Entry, 2);
    entries[0] = testEntry("ix_second", "t", @constCast(&a), .{});
    entries[1] = testEntry("ix_first", "t", @constCast(&a), .{});
    std.mem.sort(Entry, entries, {}, entryLessThan);
    const catalog: db.IndexCatalog = .{ .indexes = try arena.dupe(db.IndexInfo, &[_]db.IndexInfo{ entries[0].info, entries[1].info }) };
    try markRedundant(arena, entries, catalog);
    try testing.expect(entries[0].redundant_by == null);
    try testing.expectEqualStrings("ix_first", entries[1].redundant_by.?);
}

test "a rowid primary key covers an index on its column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]db.IndexColumn{.{ .name = "id", .collation = "BINARY", .descending = false }};
    const entries = try arena.alloc(Entry, 1);
    entries[0] = testEntry("ix_id", "t", @constCast(&id), .{});
    const catalog: db.IndexCatalog = .{
        .indexes = try arena.dupe(db.IndexInfo, &[_]db.IndexInfo{entries[0].info}),
        .rowid_primary_keys = try arena.dupe(db.RowidPrimaryKey, &[_]db.RowidPrimaryKey{.{ .table = "t", .column = "id" }}),
    };
    try markRedundant(arena, entries, catalog);
    try testing.expectEqualStrings(rowid_primary_key_name, entries[0].redundant_by.?);
}

test "the INDEXED BY detector accepts spaces and stays conservative" {
    try testing.expect(mentionsIndexedBy("SELECT * FROM t INDEXED BY ix_a"));
    try testing.expect(mentionsIndexedBy("SELECT * FROM t indexed\n  by ix_a"));
    try testing.expect(mentionsIndexedBy("SELECT * FROM t INDEXED /* hint */ BY ix_a"));
    try testing.expect(mentionsIndexedBy("SELECT * FROM t INDEXED -- hint\n BY ix_a"));
    try testing.expect(mentionsIndexedBy("SELECT * FROM t WHERE b = 'indexed by'"));
    try testing.expect(!mentionsIndexedBy("SELECT * FROM t -- unindexed by the planner"));
    try testing.expect(!mentionsIndexedBy("SELECT * FROM indexed_by"));
}
