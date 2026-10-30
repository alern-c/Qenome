const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const contract = @import("../contract/values.zig");
const cli_record = @import("record.zig");
const cli_record_shapes = @import("record_shapes.zig");

const testing = std.testing;

const ExitCode = cli.ExitCode;

const RunResult = struct {
    code: ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

const RecordFixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    work_parent: [:0]u8,

    fn init() !RecordFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        const work_parent = try tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator);
        return .{ .tmp = tmp, .root = root, .work_parent = work_parent };
    }

    fn deinit(self: *RecordFixture) void {
        testing.allocator.free(self.root);
        testing.allocator.free(self.work_parent);
        self.tmp.cleanup();
    }

    fn path(self: *RecordFixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ self.root, name }, 0);
    }

    fn writeLog(self: *RecordFixture, name: []const u8, data: []const u8, mode: std.posix.mode_t) ![:0]u8 {
        const permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(mode);
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = name,
            .data = data,
            .flags = .{ .permissions = permissions },
        });
        return self.path(name);
    }

    fn call(self: *RecordFixture, argv: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var stdout = Io.Writer.fixed(stdout_buffer);
        var stderr = Io.Writer.fixed(stderr_buffer);
        const code = cli.run(testing.io, testing.allocator, argv, .{ .temp_parent = self.work_parent }, &stdout, &stderr);
        return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

fn jsonGet(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

fn jsonText(value: std.json.Value, key: []const u8) ![]const u8 {
    return switch (try jsonGet(value, key)) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

fn jsonInt(value: std.json.Value, key: []const u8) !i64 {
    return switch (try jsonGet(value, key)) {
        .integer => |number| number,
        else => error.TestUnexpectedResult,
    };
}

fn jsonItems(value: std.json.Value, key: []const u8) ![]std.json.Value {
    return switch (try jsonGet(value, key)) {
        .array => |array| array.items,
        else => error.TestUnexpectedResult,
    };
}

test "record reports a parameter loop as one repeated shape" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..50) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"text\"],\"binds\":[\"row{d}\"]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("loop.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-loop");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "repeated shapes:\n"));
    try testing.expect(contains(result.stdout, "  queries/q002.sql  shape: 50 executions, 50 different values, longest run 50 (possible N+1; fetch the rows in one query with IN (...) or a JOIN, or send the statements with db.batch())\n"));
    try testing.expect(!contains(result.stdout, "row49"));
    try testing.expect(!contains(result.stderr, "row49"));
}

test "record reports an inlined literal loop and names the shape at the cap" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..40) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = {d}\",\"types\":[],\"binds\":[]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("literals.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-literals");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  queries/q002.sql  shape: 40 executions, 40 different values, longest run 40"));

    log.clearRetainingCapacity();
    for (0..120) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = {d}\",\"types\":[],\"binds\":[]}}\n", .{index});
    }
    const many_path = try fixture.writeLog("many-literals.log", log.items, 0o600);
    defer testing.allocator.free(many_path);
    const many_out = try fixture.path("manifest-many-literals");
    defer testing.allocator.free(many_out);
    const many = fixture.call(&.{ "Qenome", "--record", many_path, "--out", many_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, many.code);
    try testing.expect(contains(many.stderr, "at most 100"));
    try testing.expect(contains(many.stderr, "; 120 of them share the shape: SELECT a FROM t WHERE b = 0"));
    try testing.expectEqualStrings("", many.stdout);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "manifest-many-literals", .{}));
}

test "record reports a write loop with a write hint" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..15) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"run\",\"sql\":\"INSERT INTO t (a) VALUES (?)\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("write-loop.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-write-loop");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "repeated shapes:\n"));
    try testing.expect(contains(result.stdout, "  shape: 15 executions, 15 different values, longest run 15, write: INSERT INTO t (a) VALUES (?) (possible N+1; use a multi-row INSERT, or db.batch())\n"));
    try testing.expect(contains(result.stdout, "skipped: 15 writes\n"));
}

test "record does not flag a db.batch loop" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    for (0..30) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"batch\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"text\"],\"binds\":[\"batch{d}\"]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("batch-loop.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-batch-loop");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "repeated shapes: none\n"));
    try testing.expect(!contains(result.stdout, "possible N+1"));
}

test "record shows the batch count in the human shapes block" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..10) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{index});
    }
    for (0..20) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"batch\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("mixed-batch.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-mixed-batch");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  queries/q002.sql  shape: 30 executions, 10 different values, longest run 30, 20 batched (possible N+1; fetch the rows in one query with IN (...) or a JOIN, or send the statements with db.batch())\n"));
}

test "record names the most repeated read shape at the cap whatever the threshold" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    for (0..101) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = {d}\",\"types\":[],\"binds\":[]}}\n", .{index});
    }
    for (0..120) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"run\",\"sql\":\"UPDATE t SET a = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("cap-shape.log", log.items, 0o600);
    defer testing.allocator.free(log_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const off_out = try fixture.path("manifest-cap-off");
    defer testing.allocator.free(off_out);
    const off = fixture.call(&.{ "Qenome", "--record", log_path, "--out", off_out, "--n-plus-one-threshold", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, off.code);
    try testing.expect(contains(off.stderr, "at most 100"));
    try testing.expect(contains(off.stderr, "; 101 of them share the shape: SELECT a FROM t WHERE b = 0"));
    try testing.expect(!contains(off.stderr, "UPDATE"));
    try testing.expectEqualStrings("", off.stdout);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "manifest-cap-off", .{}));
}

test "record changes the report with the threshold and turns it off at zero" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..3) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("small.log", log.items, 0o600);
    defer testing.allocator.free(log_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const default_out = try fixture.path("manifest-default");
    defer testing.allocator.free(default_out);
    const default = fixture.call(&.{ "Qenome", "--record", log_path, "--out", default_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, default.code);
    try testing.expect(contains(default.stdout, "repeated shapes: none\n"));

    const low_out = try fixture.path("manifest-low");
    defer testing.allocator.free(low_out);
    const low = fixture.call(&.{ "Qenome", "--record", log_path, "--out", low_out, "--n-plus-one-threshold", "2" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, low.code);
    try testing.expect(contains(low.stdout, "  queries/q002.sql  shape: 3 executions, 3 different values, longest run 3"));

    const off_out = try fixture.path("manifest-off");
    defer testing.allocator.free(off_out);
    const off = fixture.call(&.{ "Qenome", "--record", log_path, "--out", off_out, "--n-plus-one-threshold", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, off.code);
    try testing.expect(contains(off.stdout, "repeated shapes: off\n"));
    try testing.expect(!contains(off.stdout, "possible N+1"));
}

test "record keeps the top 20 shapes and says how many it dropped" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    for (0..22) |table| {
        for (0..10) |value| {
            try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t{d} WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{ table, value });
        }
    }
    const log_path = try fixture.writeLog("wide.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-wide-shapes");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  queries/q020.sql  shape: 10 executions, 10 different values, longest run 10"));
    try testing.expect(!contains(result.stdout, "queries/q021.sql  shape:"));
    try testing.expect(contains(result.stdout, "  2 more shapes dropped (the report keeps at most 20)\n"));
}

test "record writes one record object in json without bind values" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT id FROM t\",\"types\":[],\"binds\":[]}\n");
    for (0..12) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"text\"],\"binds\":[\"value{d}\"]}}\n", .{index});
    }
    for (0..5) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"batch\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"text\"],\"binds\":[\"batched{d}\"]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("json.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-json");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(!contains(result.stdout, "value11"));
    try testing.expect(!contains(result.stdout, "batched4"));

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), try jsonInt(parsed.value, "record_schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(parsed.value, "exit_code"));
    try testing.expectEqual(@as(i64, 18), try jsonInt(parsed.value, "records"));
    try testing.expect(contains(try jsonText(parsed.value, "manifest"), "manifest-json/manifest.json"));

    const queries = try jsonItems(parsed.value, "queries");
    try testing.expectEqual(@as(usize, 2), queries.len);
    try testing.expectEqualStrings("queries/q001.sql", try jsonText(queries[0], "select"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(queries[0], "executions"));
    try testing.expectEqualStrings("queries/q002.sql", try jsonText(queries[1], "select"));
    try testing.expectEqual(@as(i64, 17), try jsonInt(queries[1], "executions"));

    const skipped = try jsonGet(parsed.value, "skipped");
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "writes"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "exec"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "other"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "blob"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "unsupported"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "nul"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "large"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "malformed"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(skipped, "version"));

    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings(contract.code.record_manifest_binds, try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings(contract.record_manifest_binds_message, try jsonText(warnings[0], "message"));

    const shapes = try jsonItems(parsed.value, "repeated_shapes");
    try testing.expectEqual(@as(usize, 1), shapes.len);
    try testing.expectEqualStrings("read", try jsonText(shapes[0], "kind"));
    try testing.expectEqual(@as(i64, 17), try jsonInt(shapes[0], "executions"));
    try testing.expectEqual(@as(i64, 12), try jsonInt(shapes[0], "distinct_values"));
    try testing.expectEqual(@as(i64, 17), try jsonInt(shapes[0], "longest_run"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(shapes[0], "statements"));
    try testing.expectEqual(@as(i64, 5), try jsonInt(shapes[0], "batched"));
    try testing.expectEqualStrings("SELECT a FROM t WHERE b = ?", try jsonText(shapes[0], "example"));
    try testing.expectEqualStrings("SELECT id FROM t", try jsonText(shapes[0], "previous_shape_example"));
    try testing.expectEqualStrings("queries/q002.sql", try jsonText(shapes[0], "manifest_select"));
    try testing.expect(contains(try jsonText(shapes[0], "hint"), "db.batch()"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(parsed.value, "repeated_shapes_dropped"));
}

test "record json reports a world-readable log and the manifest binds as warnings" {
    if (builtin.os.tag == .windows) return;
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    const log_path = try fixture.writeLog("json-loose.log", "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[],\"binds\":[]}\n", 0o644);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-json-loose");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 2), warnings.len);
    try testing.expectEqualStrings(contract.code.record_log_permissions, try jsonText(warnings[0], "code"));
    const message = try jsonText(warnings[0], "message");
    try testing.expect(contains(message, "readable by other users"));
    try testing.expect(contains(message, log_path));
    try testing.expectEqualStrings(contract.code.record_manifest_binds, try jsonText(warnings[1], "code"));
    try testing.expectEqualStrings(contract.record_manifest_binds_message, try jsonText(warnings[1], "message"));
}

test "record json escapes a non UTF-8 log path in the warnings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shapes = cli_record_shapes.Shapes.init(arena);
    const queries = [_]cli_record_shapes.QueryLine{.{ .index = 0, .executions = 1 }};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.Writer.fixed(&stdout_buffer);
    try cli_record_shapes.printSummary(&stdout, arena, .{
        .out_path = "manifest",
        .log_path = "log-\xff.log",
        .log_permissions = true,
        .json = true,
        .records = 1,
        .executions = 1,
        .queries = &queries,
        .skipped = .{},
        .shapes = &shapes,
    });

    var parsed = try parseJson(stdout.buffered());
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 2), warnings.len);
    const message = try jsonText(warnings[0], "message");
    try testing.expect(contains(message, "readable by other users"));
    try testing.expect(contains(message, "\\xff"));
}

test "record json keeps the skipped breakdown when the log holds no SELECT" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    const log_path = try fixture.writeLog("json-no-select.log", "QENOME_D1_RECORD {\"v\":1,\"op\":\"run\",\"sql\":\"INSERT INTO t VALUES (1)\",\"types\":[],\"binds\":[]}\n", 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-json-no-select");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);

    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), try jsonInt(parsed.value, "schema_version"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(parsed.value, "exit_code"));
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings("record_log_invalid", try jsonText(failure, "code"));
    const message = try jsonText(failure, "message");
    try testing.expect(contains(message, "holds no read-only statement"));
    try testing.expect(contains(message, "skipped: 1 writes"));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "manifest-json-no-select", .{}));
}

test "record classifies an invalid threshold apart from the record conflict" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    const log_path = try fixture.writeLog("threshold.log", "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[],\"binds\":[]}\n", 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-threshold");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const invalid = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--n-plus-one-threshold", "1", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, invalid.code);
    var parsed = try parseJson(invalid.stderr);
    defer parsed.deinit();
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings("usage_n_plus_one_threshold", try jsonText(failure, "code"));
    const hint = try jsonText(failure, "hint");
    try testing.expect(contains(hint, "Use 0 to turn the report off"));
    try testing.expect(contains(hint, "2 to 1000000"));

    const without_record = fixture.call(&.{ "Qenome", "--n-plus-one-threshold", "5", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, without_record.code);
    var conflict = try parseJson(without_record.stderr);
    defer conflict.deinit();
    const conflict_failure = try jsonGet(conflict.value, "error");
    try testing.expectEqualStrings("usage_record_conflict", try jsonText(conflict_failure, "code"));
    try testing.expect(contains(try jsonText(conflict_failure, "hint"), "--record"));
}

test "record refuses more than 100 statements before it writes anything" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    for (0..101) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT {d}\",\"types\":[],\"binds\":[]}}\n", .{index});
    }
    const log_path = try fixture.writeLog("many.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-many");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(contains(result.stderr, "at most 100"));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "manifest-many", .{}));
}

test "record reports unreadable records and counts what it skipped" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    const log_path = try fixture.writeLog("mixed.log", "QENOME_D1_RECORD not json\n" ++
        "QENOME_D1_RECORD {\"v\":2,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[],\"binds\":[]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"blob\"],\"binds\":[null]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"PRAGMA foreign_keys\",\"types\":[],\"binds\":[]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[],\"binds\":[]}\n", 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-mixed");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "1 unreadable records"));
    try testing.expect(contains(result.stdout, "1 other versions"));
    try testing.expect(contains(result.stdout, "1 blob binds"));
    try testing.expect(contains(result.stdout, "1 other statements"));
}

test "record skips a statement at the SQL size limit and refuses a manifest over 1 MiB" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"");
    try log.appendNTimes(testing.allocator, ' ', cli.max_sql_bytes + 1 - "SELECT 1".len);
    try log.appendSlice(testing.allocator, "SELECT 1\",\"types\":[],\"binds\":[]}\n");
    const large_path = try fixture.writeLog("large.log", log.items, 0o600);
    defer testing.allocator.free(large_path);
    const large_out = try fixture.path("manifest-large");
    defer testing.allocator.free(large_out);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const large = fixture.call(&.{ "Qenome", "--record", large_path, "--out", large_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, large.code);
    try testing.expect(contains(large.stderr, "1 large SQL"));

    log.clearRetainingCapacity();
    for (0..100) |index| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT {d}, ?\",\"types\":[\"text\"],\"binds\":[\"", .{index});
        try log.appendNTimes(testing.allocator, 'a', 12_000);
        try log.appendSlice(testing.allocator, "\"]}\n");
    }
    const wide_path = try fixture.writeLog("wide.log", log.items, 0o600);
    defer testing.allocator.free(wide_path);
    const wide_out = try fixture.path("manifest-wide");
    defer testing.allocator.free(wide_out);
    const wide = fixture.call(&.{ "Qenome", "--record", wide_path, "--out", wide_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, wide.code);
    try testing.expect(contains(wide.stderr, "manifest would be larger than 1 MiB"));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "manifest-wide", .{}));
}

test "record accepts a log at the size limit and refuses one byte more" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendNTimes(testing.allocator, 'x', cli_record.max_log_bytes);
    const exact_path = try fixture.writeLog("exact.log", big.items, 0o600);
    defer testing.allocator.free(exact_path);
    const exact_out = try fixture.path("manifest-exact");
    defer testing.allocator.free(exact_out);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const exact = fixture.call(&.{ "Qenome", "--record", exact_path, "--out", exact_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, exact.code);
    try testing.expect(contains(exact.stderr, "holds no readable records"));
    try testing.expect(!contains(exact.stderr, "larger than 16 MiB"));

    try big.append(testing.allocator, 'x');
    const over_path = try fixture.writeLog("over.log", big.items, 0o600);
    defer testing.allocator.free(over_path);
    const over_out = try fixture.path("manifest-over");
    defer testing.allocator.free(over_out);
    const over = fixture.call(&.{ "Qenome", "--record", over_path, "--out", over_out }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, over.code);
    try testing.expect(contains(over.stderr, "larger than 16 MiB"));
}

test "record counts bind values with delimiter-like text apart" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ? AND c = ?\",\"types\":[\"text\",\"text\"],\"binds\":[\"a2:text:b\",\"c\"]}\n");
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ? AND c = ?\",\"types\":[\"text\",\"text\"],\"binds\":[\"a\",\"b2:text:c\"]}\n");
    const log_path = try fixture.writeLog("binds.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-binds");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--n-plus-one-threshold", "2" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  queries/q001.sql  shape: 2 executions, 2 different values, longest run 2"));
    try testing.expect(!contains(result.stdout, "a2:text:b"));
}

test "record breaks a run at a record it skips" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"int\"],\"binds\":[1]}\n");
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"PRAGMA foreign_keys\",\"types\":[],\"binds\":[]}\n");
    try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE b = ?\",\"types\":[\"int\"],\"binds\":[2]}\n");
    const log_path = try fixture.writeLog("gap.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-gap");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path, "--n-plus-one-threshold", "2" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  queries/q001.sql  shape: 2 executions, 2 different values, longest run 1"));
    try testing.expect(contains(result.stdout, "skipped: 1 other statements\n"));
}

test "record orders the shapes by values, then executions, then first appearance" {
    var fixture = try RecordFixture.init();
    defer fixture.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    for (0..10) |value| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t0 WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{value});
    }
    for (0..10) |value| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t1 WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{value});
    }
    for (0..5) |_| {
        try log.appendSlice(testing.allocator, "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t1 WHERE b = ?\",\"types\":[\"int\"],\"binds\":[0]}\n");
    }
    for (0..12) |value| {
        try log.print(testing.allocator, "QENOME_D1_RECORD {{\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t2 WHERE b = ?\",\"types\":[\"int\"],\"binds\":[{d}]}}\n", .{value});
    }
    const log_path = try fixture.writeLog("order.log", log.items, 0o600);
    defer testing.allocator.free(log_path);
    const out_path = try fixture.path("manifest-order");
    defer testing.allocator.free(out_path);

    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.call(&.{ "Qenome", "--record", log_path, "--out", out_path }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    const twelve = std.mem.indexOf(u8, result.stdout, "queries/q003.sql  shape: 12 executions, 12 different values") orelse return error.MissingText;
    const fifteen = std.mem.indexOf(u8, result.stdout, "queries/q002.sql  shape: 15 executions, 10 different values") orelse return error.MissingText;
    const ten = std.mem.indexOf(u8, result.stdout, "queries/q001.sql  shape: 10 executions, 10 different values") orelse return error.MissingText;
    try testing.expect(twelve < fifteen);
    try testing.expect(fifteen < ten);
}
