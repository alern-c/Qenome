const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_batch_writes = @import("batch_writes.zig");
const report_batch_writes = @import("../report/batch_writes.zig");

const testing = std.testing;

const Temp = struct {
    dir: testing.TmpDir,
    path: [:0]u8,

    fn init() !Temp {
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .dir = dir, .path = path };
    }

    fn deinit(self: *Temp) void {
        testing.allocator.free(self.path);
        self.dir.cleanup();
    }

    fn write(self: *Temp, name: []const u8, data: []const u8) !void {
        try self.dir.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }
};

const Result = struct {
    writes: ?[]const cli_batch_writes.Write,
    stderr: []const u8,
};

fn load(temp: *Temp, text: []const u8, migration: bool) !Result {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    var capture: [512]u8 = undefined;
    var sink = Io.Writer.fixed(&capture);
    const writes = cli_batch_writes.loadManifest(testing.io, arena, value.object, temp.path, "batch.json", migration, &sink);
    const copied = try testing.allocator.dupe(u8, sink.buffered());
    return .{ .writes = if (writes) |_| &.{} else null, .stderr = copied };
}

fn freeResult(result: Result) void {
    testing.allocator.free(result.stderr);
}

test "a manifest without writes holds none" {
    var temp = try Temp.init();
    defer temp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"queries\":[]}", .{});
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    const writes = cli_batch_writes.loadManifest(testing.io, arena, value.object, temp.path, "batch.json", true, &stderr).?;
    try testing.expectEqual(@as(usize, 0), writes.len);
    try testing.expectEqualStrings("", stderr.buffered());
}

test "a migration manifest loads a write with its binds" {
    var temp = try Temp.init();
    defer temp.deinit();
    try temp.write("w.sql", "UPDATE t SET a = ?1 WHERE id = ?2;");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"writes":[{"write":"w.sql","binds":["1:int:7","2:int:3"]}]}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    const writes = cli_batch_writes.loadManifest(testing.io, arena, value.object, temp.path, "batch.json", true, &stderr).?;
    try testing.expectEqualStrings("", stderr.buffered());
    try testing.expectEqual(@as(usize, 1), writes.len);
    try testing.expectEqualStrings("w.sql", writes[0].label);
    try testing.expectEqualStrings("UPDATE t SET a = ?1 WHERE id = ?2;", writes[0].sql);
    try testing.expectEqual(@as(usize, 2), writes[0].binds.len);
    try testing.expectEqual(@as(u32, 1), writes[0].binds[0].number);
    try testing.expectEqual(db.BindValue{ .int = 7 }, writes[0].binds[0].value);
    try testing.expectEqual(@as(u32, 2), writes[0].binds[1].number);
    try testing.expectEqual(db.BindValue{ .int = 3 }, writes[0].binds[1].value);
}

test "writes without --migration stop the manifest" {
    var temp = try Temp.init();
    defer temp.deinit();
    try temp.write("w.sql", "DELETE FROM t;");
    const result = try load(&temp, "{\"writes\":[{\"write\":\"w.sql\"}]}", false);
    defer freeResult(result);
    try testing.expect(result.writes == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "the writes key needs --migration") != null);
}

test "a repeated write path stops the manifest" {
    var temp = try Temp.init();
    defer temp.deinit();
    try temp.write("w.sql", "DELETE FROM t;");
    const result = try load(&temp, "{\"writes\":[{\"write\":\"w.sql\"},{\"write\":\"w.sql\"}]}", true);
    defer freeResult(result);
    try testing.expect(result.writes == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "appears more than once") != null);
}

test "a write entry with another key stops the manifest" {
    var temp = try Temp.init();
    defer temp.deinit();
    try temp.write("w.sql", "DELETE FROM t;");
    const result = try load(&temp, "{\"writes\":[{\"write\":\"w.sql\",\"select\":\"q.sql\"}]}", true);
    defer freeResult(result);
    try testing.expect(result.writes == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "must have write and optional binds") != null);
}

test "an empty write list stops the manifest" {
    var temp = try Temp.init();
    defer temp.deinit();
    const result = try load(&temp, "{\"writes\":[]}", true);
    defer freeResult(result);
    try testing.expect(result.writes == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "writes must hold 1 to 100 entries") != null);
}

test "a write whose SQL file is missing stops with its label" {
    var temp = try Temp.init();
    defer temp.deinit();
    const result = try load(&temp, "{\"writes\":[{\"write\":\"gone.sql\"}]}", true);
    defer freeResult(result);
    try testing.expect(result.writes == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "cannot read the batch SQL file") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "for the batch write 'gone.sql'") != null);
}

fn comparedResult(judgement: cli_comparison.RowVerdict) report_batch_writes.Result {
    return .{ .write = "w.sql", .candidate = "m.sql", .status = .compared, .outcome = .match, .judgement = judgement };
}

test "severity reports the write conditions that change the batch exit code" {
    try testing.expectEqual(cli_batch_writes.Severity{}, cli_batch_writes.severity(&.{}));
    const slower = [_]report_batch_writes.Result{comparedResult(.regressed)};
    try testing.expect(cli_batch_writes.severity(&slower).regression);
    try testing.expect(!cli_batch_writes.severity(&slower).mismatch);
    const more_writes = [_]report_batch_writes.Result{comparedResult(.no_effect)};
    try testing.expectEqual(cli_batch_writes.Severity{}, cli_batch_writes.severity(&more_writes));
    const timed_out = [_]report_batch_writes.Result{.{ .write = "w.sql", .candidate = "m.sql", .status = .variant_timeout }};
    try testing.expect(cli_batch_writes.severity(&timed_out).timeout);
    const mismatch = [_]report_batch_writes.Result{.{
        .write = "w.sql",
        .candidate = "m.sql",
        .status = .compared,
        .outcome = .mismatch,
        .judgement = .not_judged,
    }};
    try testing.expect(cli_batch_writes.severity(&mismatch).mismatch);
    const incomparable = [_]report_batch_writes.Result{.{
        .write = "w.sql",
        .candidate = "m.sql",
        .status = .compared,
        .outcome = .incomparable,
        .judgement = .not_judged,
    }};
    try testing.expect(cli_batch_writes.severity(&incomparable).incomparable);
    const variant_only = [_]report_batch_writes.Result{.{
        .write = "w.sql",
        .candidate = "m.sql",
        .status = .compared,
        .baseline_missing = true,
        .judgement = .not_judged,
    }};
    try testing.expectEqual(cli_batch_writes.Severity{}, cli_batch_writes.severity(&variant_only));
}

test "a regressed write keeps the migration from being recommended" {
    try testing.expect(!cli_batch_writes.blocksRecommendation(&.{}));
    try testing.expect(!cli_batch_writes.blocksRecommendation(&[_]report_batch_writes.Result{comparedResult(.no_effect)}));
    try testing.expect(cli_batch_writes.blocksRecommendation(&[_]report_batch_writes.Result{comparedResult(.regressed)}));
    const mismatch = [_]report_batch_writes.Result{.{
        .write = "w.sql",
        .candidate = "m.sql",
        .status = .compared,
        .outcome = .mismatch,
        .judgement = .not_judged,
    }};
    try testing.expect(cli_batch_writes.blocksRecommendation(&mismatch));
    const timed_out = [_]report_batch_writes.Result{.{ .write = "w.sql", .candidate = "m.sql", .status = .variant_timeout }};
    try testing.expect(cli_batch_writes.blocksRecommendation(&timed_out));
    const variant_only = [_]report_batch_writes.Result{.{
        .write = "w.sql",
        .candidate = "m.sql",
        .status = .compared,
        .baseline_missing = true,
        .judgement = .not_judged,
    }};
    try testing.expect(!cli_batch_writes.blocksRecommendation(&variant_only));
}

fn createPair(tmp: *testing.TmpDir, baseline_schema: [:0]const u8, variant_schema: [:0]const u8, baseline_path: *[:0]u8, variant_path: *[:0]u8) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "baseline.db", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "variant.db", .data = "" });
    baseline_path.* = try tmp.dir.realPathFileAlloc(testing.io, "baseline.db", testing.allocator);
    variant_path.* = try tmp.dir.realPathFileAlloc(testing.io, "variant.db", testing.allocator);
    try db.createTestDatabase(baseline_path.*, baseline_schema);
    try db.createTestDatabase(variant_path.*, variant_schema);
}

const pair_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT, c INTEGER);
    \\INSERT INTO t VALUES (1, 'x', 0), (2, 'y', 0);
;
const pair_table_only: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
;

fn randomWrite() cli_batch_writes.Write {
    return .{
        .label = "w.sql",
        .path = "w.sql",
        .sql = "UPDATE t SET c = random() WHERE a = ?1",
        .binds = &.{.{ .number = 1, .value = .{ .int = 1 } }},
    };
}

test "a nondeterministic write is not run when both copies can prepare it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var baseline_path: [:0]u8 = undefined;
    var variant_path: [:0]u8 = undefined;
    try createPair(&tmp, pair_schema, pair_schema, &baseline_path, &variant_path);
    defer testing.allocator.free(baseline_path);
    defer testing.allocator.free(variant_path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var control = db.StepControl.init(testing.io, 0, &cancel);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var cleanup_failed = false;
    var results: std.ArrayList(report_batch_writes.Result) = .empty;
    const writes = [_]cli_batch_writes.Write{randomWrite()};
    switch (cli_batch_writes.compare(arena_state.allocator(), testing.allocator, &writes, baseline_path, variant_path, "m.sql", .{
        .database_path = "db.sqlite",
        .work_parent = "/tmp",
    }, &control, &results, &stderr, &cleanup_failed)) {
        .done => {},
        .failed => return error.UnexpectedFailure,
    }
    try testing.expect(!cleanup_failed);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    const entry = results.items[0];
    try testing.expectEqual(cli_comparison.Verdict.incomparable, entry.outcome.?);
    try testing.expect(!entry.ran);
    try testing.expect(entry.rows_read == null);
    try testing.expect(std.mem.indexOf(u8, entry.comparison, "\"result\":\"incomparable\"") != null);
}

test "a nondeterministic write the baseline cannot prepare is not run on the variant" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var baseline_path: [:0]u8 = undefined;
    var variant_path: [:0]u8 = undefined;
    try createPair(&tmp, pair_table_only, pair_schema, &baseline_path, &variant_path);
    defer testing.allocator.free(baseline_path);
    defer testing.allocator.free(variant_path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var control = db.StepControl.init(testing.io, 0, &cancel);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var cleanup_failed = false;
    var results: std.ArrayList(report_batch_writes.Result) = .empty;
    const writes = [_]cli_batch_writes.Write{randomWrite()};
    switch (cli_batch_writes.compare(arena_state.allocator(), testing.allocator, &writes, baseline_path, variant_path, "m.sql", .{
        .database_path = "db.sqlite",
        .work_parent = "/tmp",
    }, &control, &results, &stderr, &cleanup_failed)) {
        .done => {},
        .failed => return error.UnexpectedFailure,
    }
    try testing.expect(!cleanup_failed);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    const entry = results.items[0];
    try testing.expect(entry.baseline_missing);
    try testing.expect(!entry.ran);
    try testing.expectEqual(@as(u64, 0), entry.variant_read);
    try testing.expectEqual(@as(u64, 0), entry.variant_written);
    try testing.expect(std.mem.indexOf(u8, entry.comparison, "\"baseline\":null") != null);
    try testing.expect(std.mem.indexOf(u8, entry.comparison, "random()") != null);
}
