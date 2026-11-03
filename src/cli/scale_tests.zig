const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const contract = @import("../contract/values.zig");
const cli = @import("../cli.zig");
const cli_seed = @import("seed.zig");
const cli_scale = @import("scale.zig");

const testing = std.testing;
const ExitCode = cli.ExitCode;

const RunResult = struct {
    code: ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

fn callRun(argv: []const [:0]const u8, temp_parent: ?[]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = cli.run(testing.io, testing.allocator, argv, .{ .temp_parent = temp_parent }, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |at| {
        total += 1;
        start = at + needle.len;
    }
    return total;
}

fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

fn jsonGet(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

fn jsonInt(value: std.json.Value, key: []const u8) !i64 {
    return switch (try jsonGet(value, key)) {
        .integer => |number| number,
        else => error.TestUnexpectedResult,
    };
}

fn jsonText(value: std.json.Value, key: []const u8) ![]const u8 {
    return switch (try jsonGet(value, key)) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

fn jsonItems(value: std.json.Value, key: []const u8) ![]std.json.Value {
    return switch (try jsonGet(value, key)) {
        .array => |array| array.items,
        else => error.TestUnexpectedResult,
    };
}

const schema = "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);";

const seed_two_columns =
    \\{"seed": 9, "tables": {"t": {"rows": 1000, "columns": {
    \\  "a": {"kind": "sequence"},
    \\  "b": {"kind": "fixed", "value": "x"}}}}}
;

const lookup_select = "SELECT id, b FROM t WHERE a = 1500;";

const lookup_at_500 = "SELECT id, b FROM t WHERE a = 500;";

const lookup_index = "CREATE INDEX ix_t_a ON t(a);";

const conditional_insert = "INSERT INTO t(a, b) SELECT 1500, 'z' WHERE EXISTS (SELECT 1 FROM t WHERE a = 1500)";

const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    seed_path: [:0]u8,
    work_parent: [:0]u8,

    fn init(select_sql: []const u8, index_sql: []const u8, seed_json: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "fixture.db", .data = "" });
        const db_path = try tmp.dir.realPathFileAlloc(testing.io, "fixture.db", testing.allocator);
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, schema);
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        return .{
            .tmp = tmp,
            .db_path = db_path,
            .select_path = try file(&tmp, "select.sql", select_sql),
            .index_path = try file(&tmp, "index.sql", index_sql),
            .seed_path = try file(&tmp, "seed.json", seed_json),
            .work_parent = try tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator),
        };
    }

    fn file(tmp: *testing.TmpDir, name: []const u8, data: []const u8) ![:0]u8 {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        return tmp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.select_path);
        testing.allocator.free(self.index_path);
        testing.allocator.free(self.seed_path);
        testing.allocator.free(self.work_parent);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, extra: []const [:0]const u8, format: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [24][:0]const u8 = undefined;
        return self.call(&argv, false, extra, format, stdout_buffer, stderr_buffer);
    }

    fn runWrite(self: *Fixture, extra: []const [:0]const u8, format: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [24][:0]const u8 = undefined;
        return self.call(&argv, true, extra, format, stdout_buffer, stderr_buffer);
    }

    fn call(self: *Fixture, argv: *[24][:0]const u8, write: bool, extra: []const [:0]const u8, format: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        const role: [:0]const u8 = if (write) "--write" else "--select";
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, role, self.select_path, "--index-sql", self.index_path, "--format", format };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(argv[0 .. required.len + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }
};

fn scalarOn(path: [:0]const u8, sql: [:0]const u8) !i64 {
    var database: db.Db = .{};
    try database.openReadOnly(path);
    defer database.close() catch {};
    const statement = try database.prepareSelect(sql);
    defer _ = sqlite.sqlite3_finalize(statement);
    return switch (sqlite.sqlite3_step(statement)) {
        sqlite.SQLITE_ROW => sqlite.sqlite3_column_int64(statement, 0),
        else => error.TestUnexpectedResult,
    };
}

test "scaling a spec keeps the ratio, rounds, and keeps at least one row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec: cli_seed.Spec = .{
        .path = "seed.json",
        .seed = 3,
        .tables = &.{
            .{ .name = "big", .rows = 1000, .columns = &.{} },
            .{ .name = "small", .rows = 100, .columns = &.{} },
            .{ .name = "tiny", .rows = 1, .columns = &.{} },
            .{ .name = "empty", .rows = 0, .columns = &.{} },
        },
    };
    const scaled = try cli_scale.scaleSpec(arena, spec, 5000);
    try testing.expectEqual(@as(u64, 5000), scaled.tables[0].rows);
    try testing.expectEqual(@as(u64, 500), scaled.tables[1].rows);
    try testing.expectEqual(@as(u64, 5), scaled.tables[2].rows);
    try testing.expectEqual(@as(u64, 1), scaled.tables[3].rows);
    try testing.expectEqualStrings("big", scaled.tables[0].name);

    const small: cli_seed.Spec = .{
        .path = "seed.json",
        .seed = 3,
        .tables = &.{
            .{ .name = "big", .rows = 1000, .columns = &.{} },
            .{ .name = "tiny", .rows = 1, .columns = &.{} },
        },
    };
    const rounded = try cli_scale.scaleSpec(arena, small, 100);
    try testing.expectEqual(@as(u64, 1), rounded.tables[1].rows);

    const three: cli_seed.Spec = .{
        .path = "seed.json",
        .seed = 3,
        .tables = &.{
            .{ .name = "big", .rows = 3, .columns = &.{} },
            .{ .name = "two", .rows = 2, .columns = &.{} },
        },
    };
    const rounded_middle = try cli_scale.scaleSpec(arena, three, 1000);
    try testing.expectEqual(@as(u64, 1000), rounded_middle.tables[0].rows);
    try testing.expectEqual(@as(u64, 667), rounded_middle.tables[1].rows);

    const zeros: cli_seed.Spec = .{
        .path = "seed.json",
        .seed = 3,
        .tables = &.{
            .{ .name = "a", .rows = 0, .columns = &.{} },
            .{ .name = "b", .rows = 0, .columns = &.{} },
        },
    };
    const zero_scaled = try cli_scale.scaleSpec(arena, zeros, 1000);
    try testing.expectEqual(@as(u64, 1000), zero_scaled.tables[0].rows);
    try testing.expectEqual(@as(u64, 1000), zero_scaled.tables[1].rows);
}

test "the scale run compares an equality lookup at two sizes and leaves the database unchanged" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const result = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, contract.scale_schema_version), try jsonInt(root, "scale_schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(root, "exit_code"));
    const inputs = try jsonGet(root, "inputs");
    try testing.expectEqualStrings(fixture.seed_path, try jsonText(inputs, "seed_data"));
    const sizes = try jsonItems(inputs, "scale");
    try testing.expectEqual(@as(usize, 2), sizes.len);
    try testing.expectEqual(@as(i64, 1000), sizes[0].integer);
    try testing.expectEqual(@as(i64, 5000), sizes[1].integer);

    const steps = try jsonItems(root, "steps");
    try testing.expectEqual(@as(usize, 2), steps.len);
    try testing.expectEqual(@as(i64, 1000), try jsonInt(steps[0], "rows"));
    try testing.expectEqual(@as(i64, 5000), try jsonInt(steps[1], "rows"));
    for (steps) |step| {
        const comparison = try jsonGet(step, "comparison");
        try testing.expectEqual(@as(i64, 2), try jsonInt(comparison, "schema_version"));
        try testing.expectEqualStrings("improved", try jsonText(comparison, "verdict"));
        try testing.expectEqualStrings("match", try jsonText(comparison, "result"));
        try testing.expectEqual(@as(i64, 0), try jsonInt(comparison, "exit_code"));
    }
    const tables = try jsonItems(steps[1], "tables");
    try testing.expectEqual(@as(i64, 5000), try jsonInt(tables[0], "rows"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "warnings")).len);
    try testing.expectEqual(@as(i64, 0), try scalarOn(fixture.db_path, "SELECT count(*) FROM t"));
}

test "a scale step below 1000 rows does not ask for another --scale run" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "100,5000", "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(contains(human.stdout, "warning at 100 rows: data_too_small:"));
    try testing.expect(contains(human.stdout, "1000 rows"));
    try testing.expect(contains(human.stdout, "larger step"));
    try testing.expect(!contains(human.stdout, "Write a seed spec"));
    try testing.expect(!contains(human.stdout, "--seed-data"));
    try testing.expect(!contains(human.stdout, "warning at 5,000 rows:"));

    const json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "100,5000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    try testing.expectEqualStrings("", json.stderr);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const steps = try jsonItems(parsed.value, "steps");
    try testing.expectEqual(@as(usize, 2), steps.len);
    const first = try jsonItems(try jsonGet(steps[0], "comparison"), "warnings");
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings(contract.code.data_too_small, try jsonText(first[0], "code"));
    try testing.expectEqualStrings("t", try jsonText(first[0], "table"));
    try testing.expectEqual(@as(i64, 100), try jsonInt(first[0], "rows"));
    try testing.expect((try jsonGet(first[0], "full_scan")) == .bool);
    try testing.expect(contains(try jsonText(first[0], "message"), "fewer than 1000 rows"));
    try testing.expect(contains(try jsonText(first[0], "message"), "larger step"));
    try testing.expect(!contains(try jsonText(first[0], "message"), "--seed-data"));
    try testing.expectError(error.TestUnexpectedResult, jsonGet(first[0], "next_command"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(try jsonGet(steps[1], "comparison"), "warnings")).len);
}

test "the scale run measures three to six sizes and rejects seven" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const cases = [_]struct { scale: [:0]const u8, count: usize, text: []const u8 }{
        .{ .scale = "1000,2000,3000", .count = 3, .text = "rows in 3 steps" },
        .{ .scale = "1000,2000,3000,4000", .count = 4, .text = "rows in 4 steps" },
        .{ .scale = "1000,2000,3000,4000,5000", .count = 5, .text = "rows in 5 steps" },
        .{ .scale = "1000,2000,3000,4000,5000,6000", .count = 6, .text = "rows in 6 steps" },
    };
    for (cases) |case| {
        const result = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", case.scale, "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expectEqualStrings("", result.stderr);
        var parsed = try parseJson(result.stdout);
        defer parsed.deinit();
        const sizes = try jsonItems(try jsonGet(parsed.value, "inputs"), "scale");
        try testing.expectEqual(case.count, sizes.len);
        const steps = try jsonItems(parsed.value, "steps");
        try testing.expectEqual(case.count, steps.len);
        for (steps, 1..) |step, expected| {
            try testing.expectEqual(@as(i64, @intCast(expected * 1000)), try jsonInt(step, "rows"));
            try testing.expectEqualStrings("improved", try jsonText(try jsonGet(step, "comparison"), "verdict"));
        }

        const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", case.scale, "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, human.code);
        try testing.expect(contains(human.stdout, case.text));
        try testing.expectEqual(case.count, count(human.stdout, "changed"));
    }

    const seven = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,2000,3000,4000,5000,6000,7000", "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, seven.code);
    try testing.expectEqualStrings("", seven.stdout);
    try testing.expect(contains(seven.stderr, "expects 2 to 6"));

    const seven_json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,2000,3000,4000,5000,6000,7000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, seven_json.code);
    try testing.expectEqualStrings("", seven_json.stdout);
    var parsed = try parseJson(seven_json.stderr);
    defer parsed.deinit();
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings(contract.code.usage_scale, try jsonText(failure, "code"));
    try testing.expect(contains(try jsonText(failure, "message"), "expects 2 to 6"));
}

test "the scale run names the size where the verdict changes" {
    var fixture = try Fixture.init(conditional_insert, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const human = fixture.runWrite(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "The verdict changes between 1,000 and 5,000 rows."));
    try testing.expect(contains(human.stdout, "improved"));
    try testing.expect(contains(human.stdout, "needs-check"));
    try testing.expect(contains(human.stdout, "1 -> 2"));

    const json = fixture.runWrite(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const steps = try jsonItems(parsed.value, "steps");
    try testing.expectEqualStrings("improved", try jsonText(try jsonGet(steps[0], "comparison"), "verdict"));
    try testing.expectEqualStrings("needs-check", try jsonText(try jsonGet(steps[1], "comparison"), "verdict"));
}

test "the scale run reports the median times when it is timed" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [16384]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const result = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "2", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const steps = try jsonItems(parsed.value, "steps");
    for (steps) |step| {
        const comparison = try jsonGet(step, "comparison");
        const timing = try jsonGet(comparison, "timing");
        try testing.expectEqual(@as(i64, 2), try jsonInt(timing, "rounds"));
    }

    const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "2" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, " -> "));
}

test "scale usage errors exit 2 with the scale code" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const cases = [_]struct { extra: []const [:0]const u8, message: []const u8 }{
        .{ .extra = &.{ "--scale", "1000,5000" }, .message = "--scale needs --seed-data" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000" }, .message = "--scale expects 2 to 6" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,2000,3000,4000,5000,6000,7000" }, .message = "--scale expects 2 to 6" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "5000,1000" }, .message = "--scale expects 2 to 6" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,1000" }, .message = "--scale expects 2 to 6" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,10000001" }, .message = "must not exceed the seed limit" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,5000", "--format", "kv" }, .message = "--scale does not take --format" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,5000", "--suggest" }, .message = "--scale does not take --suggest" },
        .{ .extra = &.{ "--seed-data", "seed.json", "--scale", "1000,5000", "--migration", "m.sql" }, .message = "--scale does not take --migration" },
    };
    for (cases) |case| {
        var buffer: [8][:0]const u8 = undefined;
        const extra = withSeed(case.extra, &buffer, fixture.seed_path);
        const result = fixture.run(extra, "human", &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expect(contains(result.stderr, case.message));
        try testing.expectEqualStrings("", result.stdout);
    }
}

fn withSeed(extra: []const [:0]const u8, buffer: *[8][:0]const u8, seed: [:0]u8) []const [:0]const u8 {
    @memcpy(buffer[0..extra.len], extra);
    for (buffer[0..extra.len]) |*arg| {
        if (std.mem.eql(u8, arg.*, "seed.json")) arg.* = seed;
    }
    return buffer[0..extra.len];
}

test "the scale usage error is a usage_scale object in JSON" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const result = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings(contract.code.usage_scale, try jsonText(failure, "code"));
    try testing.expect(contains(try jsonText(failure, "hint"), "--seed-data"));
}

test "a scaled spec over the total row limit is a usage error before any copy is made" {
    var fixture = try Fixture.init(lookup_select, lookup_index,
        \\{"tables": {"a": {"rows": 1000000}, "b": {"rows": 1000000}, "c": {"rows": 1000000}}}
    );
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const result = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "5000000,10000000", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings(contract.code.usage_scale, try jsonText(failure, "code"));
    try testing.expect(contains(try jsonText(failure, "message"), "over the seed limit"));
}

test "scale with --batch or --record is a usage error" {
    var fixture = try Fixture.init(lookup_select, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const with_batch = callRun(&.{
        "Qenome", "--db", fixture.db_path, "--batch", "batch.json", "--seed-data", fixture.seed_path, "--scale", "1000,5000",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, with_batch.code);
    try testing.expect(contains(with_batch.stderr, "--scale does not take --batch"));

    const positional_batch = callRun(&.{
        "Qenome", fixture.db_path, fixture.select_path, fixture.index_path, "--batch", "batch.json", "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--format", "json",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, positional_batch.code);
    try testing.expectEqualStrings("", positional_batch.stdout);
    var parsed = try parseJson(positional_batch.stderr);
    defer parsed.deinit();
    try testing.expectEqualStrings(contract.code.usage_scale, try jsonText(try jsonGet(parsed.value, "error"), "code"));

    const positional_suggest = callRun(&.{
        "Qenome", fixture.db_path, fixture.select_path, fixture.index_path, "--suggest", "--seed-data", fixture.seed_path, "--scale", "1000,5000",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, positional_suggest.code);
    try testing.expect(contains(positional_suggest.stderr, "--scale does not take --suggest"));

    const with_record = callRun(&.{
        "Qenome", "--record", "log.txt", "--out", "out", "--seed-data", fixture.seed_path, "--scale", "1000,5000",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, with_record.code);
    try testing.expect(contains(with_record.stderr, "--scale does not take --record"));
}

test "the scale run reports the rows-read trend and the findings" {
    var fixture = try Fixture.init(lookup_at_500, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    try testing.expectEqualStrings("", json.stderr);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value;

    const trend = try jsonGet(root, "trend");
    const baseline = try jsonGet(trend, "baseline_rows_read");
    try testing.expectEqualStrings("linear", try jsonText(baseline, "class"));
    try testing.expectEqual(@as(usize, 1), (try jsonItems(baseline, "exponents")).len);
    const variant = try jsonGet(trend, "variant_rows_read");
    try testing.expectEqualStrings("constant", try jsonText(variant, "class"));
    try testing.expect((try jsonGet(trend, "baseline_time")) == .null);
    try testing.expect((try jsonGet(trend, "variant_time")) == .null);

    const findings = try jsonItems(root, "findings");
    try testing.expect(findings.len != 0);
    var gain_found = false;
    for (findings) |entry| {
        const code = try jsonText(entry, "code");
        if (std.mem.eql(u8, contract.code.gain_grows_with_scale, code)) gain_found = true;
        const steps = try jsonItems(entry, "steps");
        try testing.expectEqual(@as(usize, 2), steps.len);
        try testing.expectEqual(@as(i64, 1000), steps[0].integer);
        try testing.expectEqual(@as(i64, 5000), steps[1].integer);
        try testing.expect((try jsonText(entry, "message")).len != 0);
    }
    try testing.expect(gain_found);

    const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "\nTrend\n"));
    try testing.expect(contains(human.stdout, "baseline rows read: linear (exponents 1.000)"));
    try testing.expect(contains(human.stdout, "variant rows read:  constant (exponents 0.000)"));
    try testing.expect(contains(human.stdout, "baseline time:      not timed"));
    try testing.expect(contains(human.stdout, "\nFindings\n"));
    try testing.expect(contains(human.stdout, contract.code.gain_grows_with_scale));
}

test "the scale run classifies the medians only when it is timed" {
    var fixture = try Fixture.init(lookup_at_500, lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "2", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const trend = try jsonGet(parsed.value, "trend");
    const baseline_time = try jsonGet(trend, "baseline_time");
    try testing.expect(baseline_time != .null);
    const classes = [_][]const u8{ "constant", "sublinear", "linear", "superlinear", "mixed", "unknown" };
    var known = false;
    for (classes) |name| {
        if (std.mem.eql(u8, name, try jsonText(baseline_time, "class"))) known = true;
    }
    try testing.expect(known);
    try testing.expect((try jsonGet(trend, "variant_time")) != .null);

    const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "2" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expect(!contains(human.stdout, "baseline time:      not timed"));
    try testing.expect(!contains(human.stdout, "variant time:       not timed"));
}

test "the scale run reports the SQL warnings of the SELECT in human and json" {
    var fixture = try Fixture.init("SELECT * FROM t WHERE a = 1500;", lookup_index, seed_two_columns);
    defer fixture.deinit();
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    const human = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(contains(human.stdout, "\nSQL warnings\n"));
    try testing.expect(contains(human.stdout, "info: select_star:"));
    try testing.expectEqual(@as(usize, 1), count(human.stdout, "select_star:"));

    const json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    try testing.expectEqualStrings("", json.stderr);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    try testing.expectError(error.TestUnexpectedResult, jsonGet(parsed.value, "sql_warnings"));
    const steps = try jsonItems(parsed.value, "steps");
    try testing.expectEqual(@as(usize, 2), steps.len);
    for (steps) |entry| {
        const comparison = try jsonGet(entry, "comparison");
        const warnings = try jsonItems(comparison, "sql_warnings");
        try testing.expectEqual(@as(usize, 1), warnings.len);
        try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[0], "code"));
        try testing.expectEqualStrings(contract.sql_warning_severity.info, try jsonText(warnings[0], "severity"));
        try testing.expectEqual(@as(i64, 1), try jsonInt(warnings[0], "line"));
        try testing.expectEqual(@as(i64, 8), try jsonInt(warnings[0], "column"));
    }

    const off = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--no-sql-warnings" }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, off.code);
    try testing.expect(!contains(off.stdout, "SQL warnings"));

    const ignored = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--ignore-sql-warning", contract.code.select_star }, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, ignored.code);
    try testing.expect(!contains(ignored.stdout, "SQL warnings"));

    const off_json = fixture.run(&.{ "--seed-data", fixture.seed_path, "--scale", "1000,5000", "--runs", "0", "--no-sql-warnings", "--format", "json" }, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, off_json.code);
    var off_parsed = try parseJson(off_json.stdout);
    defer off_parsed.deinit();
    const off_steps = try jsonItems(off_parsed.value, "steps");
    for (off_steps) |entry| {
        try testing.expectEqual(@as(usize, 0), (try jsonItems(try jsonGet(entry, "comparison"), "sql_warnings")).len);
    }
    try testing.expectEqual(try jsonGet(parsed.value, "exit_code"), try jsonGet(off_parsed.value, "exit_code"));
}
