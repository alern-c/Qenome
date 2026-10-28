const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const cli = @import("../cli.zig");
const cli_batch = @import("batch.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_suggest = @import("suggest.zig");

const run = cli.run;
const runChecked = cli.runChecked;
const readSqlFile = cli.readSqlFile;
const parseArgs = cli.parseArgs;
const usage = cli.usage;
const ExitCode = cli.ExitCode;
const finalExitCode = cli.finalExitCode;
const default_runs = cli.default_runs;
const default_timeout_ms = cli.default_timeout_ms;
const max_runs = cli.max_runs;
const Side = cli_comparison.Side;

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn file(self: *Fixture, sub_path: []const u8, data: []const u8) ![:0]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
        return self.tmp.dir.realPathFileAlloc(testing.io, sub_path, testing.allocator);
    }
};

const CliFixture = struct {
    dir: Fixture,
    db_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    work_parent: [:0]u8,

    fn init(select_sql: []const u8, index_sql: []const u8) !CliFixture {
        return initWithSchema(select_sql, index_sql, fixture_schema);
    }

    fn initWithSchema(select_sql: []const u8, index_sql: []const u8, schema: [:0]const u8) !CliFixture {
        var dir = try Fixture.init();
        errdefer dir.deinit();
        const db_path = try dir.file("fixture.db", "");
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, schema);
        const select_path = try dir.file("select.sql", select_sql);
        errdefer testing.allocator.free(select_path);
        const index_path = try dir.file("index.sql", index_sql);
        errdefer testing.allocator.free(index_path);
        try dir.tmp.dir.createDir(testing.io, "work", .default_dir);
        const work_parent = try dir.tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator);
        return .{
            .dir = dir,
            .db_path = db_path,
            .select_path = select_path,
            .index_path = index_path,
            .work_parent = work_parent,
        };
    }

    fn deinit(self: *CliFixture) void {
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.select_path);
        testing.allocator.free(self.index_path);
        testing.allocator.free(self.work_parent);
        self.dir.deinit();
    }

    fn run(self: *CliFixture, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        return self.runFormat("kv", extra, stdout_buffer, stderr_buffer);
    }

    fn runFormat(self: *CliFixture, format: [:0]const u8, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [26][:0]const u8 = undefined;
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, "--select", self.select_path, "--index-sql", self.index_path, "--format", format };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(testing.allocator, argv[0 .. required.len + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }

    fn writeFile(self: *CliFixture, sub_path: []const u8, data: []const u8) !void {
        try self.dir.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn runBatch(self: *CliFixture, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) !RunResult {
        const manifest = try self.dir.tmp.dir.realPathFileAlloc(testing.io, "batch.json", testing.allocator);
        defer testing.allocator.free(manifest);
        return self.runBatchPath(manifest, extra, stdout_buffer, stderr_buffer);
    }

    fn runBatchPath(self: *CliFixture, manifest: [:0]const u8, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [26][:0]const u8 = undefined;
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, "--batch", manifest };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(testing.allocator, argv[0 .. required.len + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }

    fn expectNoLeftovers(self: *CliFixture) !void {
        var parent = try self.dir.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
        defer parent.close(testing.io);
        var it = parent.iterate();
        if (try it.next(testing.io)) |entry| {
            std.debug.print("left behind: {s}\n", .{entry.name});
            return error.TemporaryDirectoryLeft;
        }
    }
};

const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

const RunResult = struct {
    code: ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

fn summaryBlock(stdout: []const u8, side: Side) []const u8 {
    const variant_at = std.mem.indexOf(u8, stdout, "measured-on: variant") orelse stdout.len;
    if (side == .baseline) {
        const start = std.mem.indexOf(u8, stdout, "measured-on: baseline") orelse return "";
        return stdout[start..variant_at];
    }
    const end = std.mem.indexOf(u8, stdout, "result: ") orelse stdout.len;
    return stdout[variant_at..end];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn callRun(
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    temp_parent: ?[]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = run(testing.io, allocator, argv, temp_parent, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

const reordered_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT, r REAL);
    \\INSERT INTO t VALUES (3, 'z', 0.1), (1, 'x', 0.2), (2, 'y', 0.3), (3, 'v', 1e16), (1, 'w', -1e16), (2, 'u', 0.7);
;

fn reportValue(stdout: []const u8, line_key: []const u8, key: []const u8) !u64 {
    const line_start = std.mem.indexOf(u8, stdout, line_key) orelse return error.MissingLine;
    const line_end = std.mem.indexOfScalarPos(u8, stdout, line_start, '\n') orelse stdout.len;
    const line = stdout[line_start..line_end];
    const at = std.mem.indexOf(u8, line, key) orelse return error.MissingKey;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " /\n") orelse rest.len;
    return std.fmt.parseUnsigned(u64, rest[0..end], 10);
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

fn expectJsonFailure(stderr: []const u8, code: []const u8, exit_code: i64) !void {
    var parsed = try parseJson(stderr);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), try jsonInt(parsed.value, "schema_version"));
    try testing.expectEqual(exit_code, try jsonInt(parsed.value, "exit_code"));
    const failure = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings(code, try jsonText(failure, "code"));
    try testing.expect((try jsonText(failure, "message")).len != 0);
    try testing.expect((try jsonText(failure, "hint")).len != 0);
}

fn jsonBool(value: std.json.Value, key: []const u8) !bool {
    return switch (try jsonGet(value, key)) {
        .bool => |flag| flag,
        else => error.TestUnexpectedResult,
    };
}

fn jsonItems(value: std.json.Value, key: []const u8) ![]std.json.Value {
    return switch (try jsonGet(value, key)) {
        .array => |array| array.items,
        else => error.TestUnexpectedResult,
    };
}

fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

test "a bare invocation shows the synopsis and every missing option" {
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{"Qenome"}, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings(
        "usage: qenome <DB> <SELECT_FILE> <INDEX_FILE> [options]\n" ++
            "       qenome --d1 <BINDING> <SELECT_FILE> <INDEX_FILE> [options]\n" ++
            "error: missing: the database (a path, --db or --d1), the SELECT file (a path or --select), the CREATE INDEX file (a path or --index-sql) (see --help)\n",
        result.stderr,
    );
}

test "the remaining required options are listed together" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{
            .argv = &.{ "Qenome", "--db", "x" },
            .stderr = "error: missing: the SELECT file (a path or --select), the CREATE INDEX file (a path or --index-sql) (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--db", "x", "--select", "y" },
            .stderr = "error: missing: the CREATE INDEX file (a path or --index-sql) (see --help)\n",
        },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "unknown option" {
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--nope" }, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown option") != null);
}

test "bind format error" {
    const invalid = [_][:0]const u8{
        "1",
        "x:int:1",
        ":int:1",
        "1:blob:zzz",
        "1:int",
        "1:int:abc",
        "1:real:abc",
        "1:real:nan",
        "1:real:NaN",
        "1:text",
        "1:null:value",
    };
    for (invalid) |raw| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", "--bind", raw }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "--bind") != null);
    }
}

test "runs parsing accepts 0 to 1000 and rejects the rest" {
    for ([_][:0]const u8{ "0", "1", "1000" }) |raw| {
        const args = try parseArgs(testing.allocator, &.{ "Qenome", "--runs", raw });
        defer testing.allocator.free(args.binds);
        try testing.expectEqual(try std.fmt.parseUnsigned(u32, raw, 10), args.runs);
    }
    for ([_][:0]const u8{ "1001", "-1", "x", "4294967296" }) |raw| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", "--runs", raw }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings("error: --runs expects an integer from 0 to 1000\n", result.stderr);
    }
    const args = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(args.binds);
    try testing.expectEqual(default_runs, args.runs);
}

test "help exits 0" {
    const options = [_][:0]const u8{ "--help", "-h" };
    for (options) |option| {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", option }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expectEqualStrings("", result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "usage: qenome") != null);
    }
}

test "version exits 0" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--version" }, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("qenome " ++ cli.version ++ "\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "version wins over other argument errors and help wins over version" {
    const version_wins = [_][]const [:0]const u8{
        &.{ "Qenome", "--version", "--nope" },
        &.{ "Qenome", "--db", "--version" },
    };
    for (version_wins) |argv| {
        var stdout_buffer: [256]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expectEqualStrings("qenome " ++ cli.version ++ "\n", result.stdout);
        try testing.expectEqualStrings("", result.stderr);
    }

    const help_wins = [_][]const [:0]const u8{
        &.{ "Qenome", "--version", "--help" },
        &.{ "Qenome", "--help", "--version" },
    };
    for (help_wins) |argv| {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expect(std.mem.startsWith(u8, result.stdout, "usage: qenome"));
        try testing.expect(!std.mem.startsWith(u8, result.stdout, "qenome " ++ cli.version));
        try testing.expectEqualStrings("", result.stderr);
    }
}

test "a version after the double dash is a path" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--", "--version" }, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings(
        "error: missing: the SELECT file (a path or --select), the CREATE INDEX file (a path or --index-sql) (see --help)\n",
        result.stderr,
    );
}

test "the short version flags are unknown options" {
    for ([_][:0]const u8{ "-V", "-v" }) |flag| {
        var stdout_buffer: [256]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", flag }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown option") != null);
    }
}

test "accepted run prints summary on stdout and nothing on stderr (exit 0)" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:int:1",
        "--format",
        "kv",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, fixture.db_path) != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, fixture.index_path) != null);
    try fixture.expectNoLeftovers();
}

test "accepted run prints plan and counters" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE b = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:text:x",
        "--format",
        "kv",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    const expected_head = try std.fmt.allocPrint(
        testing.allocator,
        "index-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: 1\n",
        .{fixture.index_path},
    );
    defer testing.allocator.free(expected_head);
    try testing.expect(std.mem.indexOf(u8, result.stdout, expected_head) != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite: " ++ sqlite.pinned_version ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite-source-id: " ++ sqlite.pinned_source_id ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "kind=search covering=false automatic=false detail=SEARCH t USING INDEX idx_b") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "fullscan-steps: 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "vm-steps: ") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sort-ops: 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "autoindex-rows: 0\n") != null);
}

test "rejected run prints error on stderr (exit 1)" {
    var fixture = try CliFixture.init("INSERT INTO t VALUES (3, 'z')", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.startsWith(u8, result.stderr, "error: --select:"));
    try fixture.expectNoLeftovers();
}

test "engine details appear only when SQLite reported an error" {
    var fixture = try CliFixture.init("-- nothing to run\n", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "holds no statement") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "not an error") == null);
}

test "an invalid statement reports the engine message" {
    var fixture = try CliFixture.init("SELECT nope FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "no such column: nope") != null);
}

test "bind mismatch is a rejection, not a usage error" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "2:int:1",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.startsWith(u8, result.stderr, "error: --bind:"));
}

test "a select whose plan depends on a bound parameter is accepted" {
    var fixture = try CliFixture.init("SELECT b FROM t WHERE b LIKE ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:text:x%",
        "--format",
        "kv",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 1") != null);
}

test "accepted run applies the index to the variant only" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_new ON t(a)");
    defer fixture.deinit();
    const before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const first = fixture.run(&.{ "--bind", "1:int:1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, first.code);
    try testing.expectEqualStrings("", first.stderr);
    const baseline_block = summaryBlock(first.stdout, .baseline);
    const variant_block = summaryBlock(first.stdout, .variant);
    try testing.expect(contains(baseline_block, "rows: 1\n"));
    try testing.expect(contains(baseline_block, "detail=SCAN t\n"));
    try testing.expect(contains(variant_block, "measured-on: variant (candidate index applied)\nrows: 1\n"));
    try testing.expect(contains(variant_block, "detail=SEARCH t USING COVERING INDEX idx_new (a=?)\n"));
    try testing.expect(contains(variant_block, "fullscan-steps: 0\n"));
    try testing.expect(contains(first.stdout, "result: match (row multiset)\nrow-order: same (reference only; not part of the result)\n"));
    try fixture.expectNoLeftovers();

    const after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    var second_stdout: [4096]u8 = undefined;
    var second_stderr: [1024]u8 = undefined;
    const second = fixture.run(&.{ "--bind", "1:int:1" }, &second_stdout, &second_stderr);
    try testing.expectEqual(ExitCode.ok, second.code);
    try testing.expectEqualStrings("", second.stderr);
}

test "an order-only difference is still a match with exit 0" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > ?1", "CREATE INDEX idx_a ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (3, 'z'), (1, 'x'), (2, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{ "--bind", "1:int:0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, run_result.code);
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "USING COVERING INDEX idx_a"));
    try testing.expect(contains(run_result.stdout, "result: match (row multiset)\nrow-order: differs (reference only;"));
}

test "a bare-column group by that differs exits 3" {
    var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(run_result.stdout, "result: mismatch (row multiset; the cause is not determined)\nbaseline-only-rows: 1\nvariant-only-rows: 1\nrow-order: not applicable\n"));
    try testing.expect(!contains(run_result.stdout, "baseline-only-row:"));
    try testing.expect(!contains(run_result.stdout, "variant-only-row:"));
    try testing.expect(!contains(run_result.stdout, "[1, 'x']"));
    try testing.expect(!contains(run_result.stdout, "[1, 'y']"));

    var shown_stdout: [4096]u8 = undefined;
    var shown_stderr: [1024]u8 = undefined;
    const shown = fixture.run(&.{"--show-rows"}, &shown_stdout, &shown_stderr);
    try testing.expectEqual(ExitCode.mismatch, shown.code);
    try testing.expect(contains(shown.stdout, "baseline-only-rows: 1\nvariant-only-rows: 1\nbaseline-only-row: [1, 'x']\nvariant-only-row: [1, 'y']\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "indexed by the candidate index is rejected with exit 1" {
    const cases = [_]struct { select: []const u8, index: []const u8, expected: []const u8 }{
        .{ .select = "SELECT a FROM t INDEXED BY IDX_NEW WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "names the candidate index 'idx_new' in INDEXED BY" },
        .{ .select = "SELECT a FROM t INDEXED BY \"Idx New\" WHERE a = 1", .index = "CREATE INDEX \"Idx New\" ON t(a)", .expected = "names the candidate index 'Idx New' in INDEXED BY" },
        .{ .select = "SELECT a FROM t INDEXED BY nope WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "no such index: nope" },
        .{ .select = "WITH c AS (SELECT a FROM t) SELECT a FROM c INDEXED BY idx_new", .index = "CREATE INDEX idx_new ON t(a)", .expected = "no such index: \"idx_new\"" },
    };
    for (cases) |case| {
        var fixture = try CliFixture.init(case.select, case.index);
        defer fixture.deinit();
        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.rejected, run_result.code);
        try testing.expectEqualStrings("", run_result.stdout);
        try testing.expect(std.mem.startsWith(u8, run_result.stderr, "error: --select: "));
        try testing.expect(contains(run_result.stderr, case.expected));
        try fixture.expectNoLeftovers();
    }
}

test "a unique index over duplicate rows exits 1" {
    var fixture = try CliFixture.init("SELECT a FROM t", "CREATE UNIQUE INDEX idx_b2 ON t(a)");
    defer fixture.deinit();
    const writer = try db.openTestWriter(fixture.db_path, "INSERT INTO t VALUES (1, 'z')");
    _ = sqlite.sqlite3_close(writer);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, run_result.code);
    try testing.expectEqualStrings("", run_result.stdout);
    try testing.expect(contains(run_result.stderr, "error: --index-sql: the index could not be created on the variant: UNIQUE constraint failed"));
    try fixture.expectNoLeftovers();
}

test "an index build over the time limit exits 124 and leaves no temporary directory" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_b ON t(b)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
    );
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{ "--timeout-ms", "1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.timeout, run_result.code);
    try testing.expectEqualStrings("", run_result.stdout);
    try testing.expectEqualStrings("error: --index-sql exceeded the time limit of 1 ms\n", run_result.stderr);
    try fixture.expectNoLeftovers();
}

test "result rows over the byte budget exit 4" {
    var fixture = try CliFixture.init(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 70) SELECT zeroblob(1048576) FROM c",
        "CREATE INDEX idx_a ON t(a)",
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(summaryBlock(run_result.stdout, .baseline), "rows: 70\n"));
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "rows: 70\n"));
    try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the result rows exceed the 64 MiB kept for the comparison\nincomparable-hint: narrow the rows with WHERE (not LIMIT) and run again\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "a nondeterministic select exits 4 and still prints both plans" {
    var fixture = try CliFixture.init("SELECT a, random() FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(summaryBlock(run_result.stdout, .baseline), "detail=SCAN t\n"));
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "detail=SEARCH t USING COVERING INDEX idx_a (a=?)\n"));
    try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the SELECT calls random(), whose result changes between runs\nincomparable-hint: compare the SELECT without random()\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "a schema table select exits 4" {
    var fixture = try CliFixture.init("SELECT count(*) FROM sqlite_master", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expect(contains(run_result.stdout, "incomparable-reason: the SELECT reads sqlite_master, which describes the database itself\nincomparable-hint: SELECTs that read the schema tables are not compared\n"));
}

test "a limit select whose rows differ exits 4 and one that matches exits 0" {
    {
        var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > 0 LIMIT 2", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other rows when the order changes\nincomparable-hint: to compare, end the ORDER BY next to the LIMIT with a unique NOT NULL column, or drop LIMIT and OFFSET; then check that the plan still uses the candidate index\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
        try testing.expect(contains(run_result.stdout, "row-order: not applicable\n"));
    }
    {
        var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t ORDER BY a, b LIMIT 2", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
}

test "a cte select whose rows differ exits 4" {
    var fixture = try CliFixture.initWithSchema("WITH c AS (SELECT a, b FROM t) SELECT a, b FROM c GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expect(contains(run_result.stdout, "incomparable-reason: the rows differ, and the SELECT reads through a view or a WITH clause, which may pick rows by their order\nincomparable-hint: compare the SELECT inside the view or the WITH clause directly\n"));
}

test "an integer-only sum that matches exits 0 and a real sum that differs exits 4" {
    {
        var fixture = try CliFixture.initWithSchema("SELECT sum(a) FROM t", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
    {
        var fixture = try CliFixture.initWithSchema("SELECT sum(r) FROM t", "CREATE INDEX idx_r ON t(r)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        try testing.expect(contains(run_result.stdout, "incomparable-reason: the rows differ, and the SELECT calls sum(), whose result can depend on the order rows are read in\nincomparable-hint: sum() adds REAL values in the order they are read, so the results may differ only in the last digits; rerun with --show-rows to see the rows\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
        try testing.expect(!contains(run_result.stdout, "baseline-only-row:"));
    }
}

test "a date function is compared, and a difference with it exits 4 with a hint" {
    {
        var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE date(b) = ?1", "CREATE INDEX idx_db ON t(date(b))",
            \\CREATE TABLE t(a INTEGER, b TEXT);
            \\INSERT INTO t VALUES (1, '2026-03-15 10:00:00'), (2, '2026-03-16 09:00:00'), (3, '2026-03-15 23:59:59');
        );
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{ "--bind", "1:text:2026-03-15" }, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "USING INDEX idx_db"));
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
    {
        var fixture = try CliFixture.initWithSchema("SELECT a, b, date('2026-01-01') FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
            \\CREATE TABLE t(a INTEGER, b TEXT);
            \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
        );
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the rows differ, and the SELECT calls date(), which can read the current time ('now' or no argument)\nincomparable-hint: if the SELECT reads the current time, bind a fixed time instead and run again\nbaseline-only-rows: 1\n"));
    }
}

test "several reasons come in pairs with their hints" {
    var fixture = try CliFixture.initWithSchema("WITH c AS (SELECT a, b FROM t) SELECT a, b, sum(a) FROM c GROUP BY a LIMIT 5", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, run_result.stdout, "incomparable-reason: "));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, run_result.stdout, "incomparable-hint: "));
    try testing.expect(contains(run_result.stdout, "sum(), whose result can depend on the order rows are read in\nincomparable-hint: sum() adds REAL values"));
    try testing.expect(contains(run_result.stdout, "LIMIT or OFFSET, which can pick other rows when the order changes\nincomparable-hint: to compare"));
    try testing.expect(contains(run_result.stdout, "WITH clause, which may pick rows by their order\nincomparable-hint: compare the SELECT inside"));
}

test "timeout exits 124" {
    var fixture = try CliFixture.init(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c",
        "CREATE INDEX idx_a ON t(a)",
    );
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--timeout-ms",
        "1",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.timeout, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "time limit") != null);
    try fixture.expectNoLeftovers();
}

test "pre-set cancel flag exits 130" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    cli_control.cancelFlag().store(true, .release);
    defer cli_control.clearSignals();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.interrupted, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "SIGINT") != null);
    try fixture.expectNoLeftovers();
}

test "pre-set SIGTERM and SIGHUP exit 143 and 129" {
    const cases = [_]struct { sig: std.posix.SIG, code: ExitCode, name: []const u8 }{
        .{ .sig = .TERM, .code = .terminated, .name = "SIGTERM" },
        .{ .sig = .HUP, .code = .hangup, .name = "SIGHUP" },
    };
    for (cases) |case| {
        var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
        defer fixture.deinit();

        cli_control.clearSignals();
        cli_control.handleSignal(case.sig);
        defer cli_control.clearSignals();

        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const result = callRun(testing.allocator, &.{
            "Qenome",
            "--db",
            fixture.db_path,
            "--select",
            fixture.select_path,
            "--index-sql",
            fixture.index_path,
        }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

        try testing.expectEqual(case.code, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, case.name) != null);
        try fixture.expectNoLeftovers();
    }
}

test "a missing temporary directory parent exits 1" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/nope", .{fixture.work_parent});
    defer testing.allocator.free(missing);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, missing, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "temporary directory"));
    try testing.expect(contains(result.stderr, ": no such file\n"));
    try testing.expect(!contains(result.stderr, "FileNotFound"));
}

test "a missing database exits 1 and leaves no temporary directory" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const missing = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/missing.db", .{fixture.work_parent}, 0);
    defer testing.allocator.free(missing);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        missing,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "cannot open") != null);
    try fixture.expectNoLeftovers();
}

test "a run on a wal database counts rows that are still in the wal" {
    var fixture = try CliFixture.init("SELECT a FROM w", "CREATE INDEX idx_w ON w(a)");
    defer fixture.deinit();
    const wal_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/../wal.db", .{fixture.work_parent}, 0);
    defer testing.allocator.free(wal_path);
    const writer = try db.openTestWriter(wal_path,
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA wal_autocheckpoint=0;
        \\CREATE TABLE w(a INTEGER);
        \\INSERT INTO w VALUES (1), (2), (3);
    );
    defer _ = sqlite.sqlite3_close(writer);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        wal_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--format",
        "kv",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 3\n") != null);
    try fixture.expectNoLeftovers();
}

fn readFixtureFile(fixture: *CliFixture, name: []const u8) ![]u8 {
    return fixture.dir.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
}

test "a comparison leaves the source database and its wal bytes unchanged" {
    var fixture = try CliFixture.init("SELECT a FROM w", "CREATE INDEX idx_w ON w(a)");
    defer fixture.deinit();
    const wal_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/../wal.db", .{fixture.work_parent}, 0);
    defer testing.allocator.free(wal_path);
    const writer = try db.openTestWriter(wal_path,
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA wal_autocheckpoint=0;
        \\CREATE TABLE w(a INTEGER);
        \\INSERT INTO w VALUES (1), (2), (3);
    );
    defer _ = sqlite.sqlite3_close(writer);

    const main_before = try readFixtureFile(&fixture, "wal.db");
    defer testing.allocator.free(main_before);
    const wal_before = try readFixtureFile(&fixture, "wal.db-wal");
    defer testing.allocator.free(wal_before);
    try testing.expect(wal_before.len > 0);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        wal_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    const main_after = try readFixtureFile(&fixture, "wal.db");
    defer testing.allocator.free(main_after);
    const wal_after = try readFixtureFile(&fixture, "wal.db-wal");
    defer testing.allocator.free(wal_after);
    try testing.expectEqualSlices(u8, main_before, main_after);
    try testing.expectEqualSlices(u8, wal_before, wal_after);
    try fixture.expectNoLeftovers();
}

test "runs 3 prints binds, conditions, versions, times, sizes and the verdict after row-order" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE b = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.run(&.{ "--bind", "1:text:x\n", "--runs", "3" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    const keys = [_][]const u8{
        "row-order: ",
        "bind: 1:text (2 bytes)\n",
        "measure-runs: 3 per copy\n",
        "measure-warmup: 1 per copy",
        "measure-order: ",
        "measure-scope: ",
        "measure-cache: ",
        "work-dir-parent: ",
        "zig: " ++ builtin.zig_version_string ++ "\n",
        "build-mode: ",
        "os-arch: ",
        "time-baseline-ns: median=",
        "time-variant-ns: median=",
        "time-ratio: ",
        "variant-faster-rounds: ",
        "db-bytes-baseline: ",
        "db-bytes-variant: ",
        "db-bytes-increase: ",
        "verdict: ",
    };
    var from: usize = 0;
    for (keys) |key| {
        const at = std.mem.indexOfPos(u8, result.stdout, from, key) orelse {
            std.debug.print("missing or out of order: {s}\n", .{key});
            return error.TestUnexpectedResult;
        };
        from = at + key.len;
    }
    try testing.expect(contains(result.stdout, fixture.work_parent));
    for ([_][]const u8{ "time-baseline-ns: ", "time-variant-ns: " }) |line| {
        const min = try reportValue(result.stdout, line, "min=");
        const p25 = try reportValue(result.stdout, line, "p25=");
        const median = try reportValue(result.stdout, line, "median=");
        const p75 = try reportValue(result.stdout, line, "p75=");
        const max = try reportValue(result.stdout, line, "max=");
        try testing.expect(min <= p25 and p25 <= median and median <= p75 and p75 <= max);
        const line_start = std.mem.indexOf(u8, result.stdout, line).?;
        const line_end = std.mem.indexOfScalarPos(u8, result.stdout, line_start, '\n').?;
        const tail = result.stdout[line_start..line_end];
        try testing.expect(contains(tail, " (median ") and tail[tail.len - 1] == ')');
    }
    try testing.expect(try reportValue(result.stdout, "variant-faster-rounds: ", "variant-faster-rounds: ") <= 3);
    try fixture.expectNoLeftovers();
}

test "runs 0 skips the timing and keeps exit 0" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.run(&.{ "--bind", "1:int:1", "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "bind: 1:int\nmeasure-runs: 0 per copy\n"));
    try testing.expect(!contains(result.stdout, "time-baseline-ns"));
    try testing.expect(contains(result.stdout, "rows-read: 2\nrows-written: 0\n"));
    try testing.expect(contains(result.stdout, "verdict: no-effect\n"));
    try testing.expect(!contains(result.stdout, "verdict-reason"));
    try fixture.expectNoLeftovers();
}

test "a mismatch is not timed and keeps exit 3" {
    var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, result.code);
    try testing.expect(contains(result.stdout, "bind: none\nmeasure-runs: 0 per copy\n"));
    try testing.expect(!contains(result.stdout, "time-baseline-ns"));
    try testing.expect(contains(result.stdout, "verdict: not-judged\nverdict-reason: the result rows do not match, so the row counts are not judged\n"));
}

test "the size increase is the variant size minus the snapshot size" {
    var fixture = try CliFixture.init("SELECT a FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.run(&.{ "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    const baseline = try reportValue(result.stdout, "db-bytes-baseline: ", "db-bytes-baseline: ");
    const variant = try reportValue(result.stdout, "db-bytes-variant: ", "db-bytes-variant: ");
    const increase = try reportValue(result.stdout, "db-bytes-increase: ", "db-bytes-increase: ");
    const stat = try Io.Dir.cwd().statFile(testing.io, fixture.db_path, .{});
    try testing.expectEqual(stat.size, baseline);
    try testing.expect(variant > baseline);
    try testing.expectEqual(variant - baseline, increase);
}

test "an incomparable select is not timed and keeps exit 4" {
    var fixture = try CliFixture.init("SELECT a, random() FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expect(contains(result.stdout, "measure-runs: 0 per copy\n"));
    try testing.expect(!contains(result.stdout, "time-baseline-ns"));
    try testing.expect(contains(result.stdout, "verdict: not-judged\nverdict-reason: the result rows cannot be compared, so the row counts are not judged\n"));
}

test "binds show only their shape unless --show-binds is given" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1 AND b <> ?2 AND ?3 IS NULL AND ?4 < 9", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const binds = [_][:0]const u8{ "--bind", "1:int:1", "--bind", "2:text:secret", "--bind", "3:null", "--bind", "4:real:1.5", "--runs", "0" };

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const hidden = fixture.run(&binds, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, hidden.code);
    try testing.expect(contains(hidden.stdout, "bind: 1:int\nbind: 2:text (6 bytes)\nbind: 3:null\nbind: 4:real\n"));
    try testing.expect(!contains(hidden.stdout, "secret"));
    try testing.expect(!contains(hidden.stdout, "1.5"));

    var shown_stdout_buffer: [8192]u8 = undefined;
    var shown_stderr_buffer: [1024]u8 = undefined;
    const shown = fixture.run(&(binds ++ [_][:0]const u8{"--show-binds"}), &shown_stdout_buffer, &shown_stderr_buffer);
    try testing.expectEqual(ExitCode.ok, shown.code);
    try testing.expect(contains(shown.stdout, "bind: 1:int:1\nbind: 2:text:'secret'\nbind: 3:null\nbind: 4:real:1.5e0\n"));
}

fn expectNarrow(text: []const u8, raw: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    next: while (lines.next()) |line| {
        if (line.len <= 80) continue;
        for (raw) |allowed| if (contains(line, allowed)) continue :next;
        std.debug.print("wider than 80 columns: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
}

test "the default summary puts the conclusion first and the copies side by side" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:int:1",
        "--runs",
        "2",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.startsWith(u8, result.stdout,
        \\Summary
        \\  result rows   match (the same rows on both copies)
        \\  rows read     2 -> 2
        \\  rows written  0 -> 0
        \\  verdict       no-effect: the rows match, and the variant reads the same rows
        \\
    ));

    const in_order = [_][]const u8{
        "  query plan    changed on the variant\n",
        "  time          median ",
        "  db size       +",
        "\nBaseline vs variant           baseline         variant          change\n",
        "  rows read                          2               2            same\n",
        "  rows written                       0               0            same\n",
        "  result rows                        1               1            same\n",
        "  fullscan-steps                     1               0              -1\n",
        "  time p25 ",
        "  time p75 ",
        "  db file bytes ",
        "\nQuery plan\n  baseline (candidate index not applied)\n    SCAN t  [scan]\n",
        "  variant (candidate index applied)\n    SEARCH t USING COVERING INDEX idx_a (a=?)  [search, covering]\n",
    };
    var from: usize = 0;
    for (in_order) |part| {
        const at = std.mem.indexOfPos(u8, result.stdout, from, part) orelse {
            std.debug.print("missing or out of order: {s}\n", .{part});
            return error.TestUnexpectedResult;
        };
        from = at + part.len;
    }
    for ([_][]const u8{ "Timing", "Run\n", "Result rows", "time median", "binds", "work dir", "source id", fixture.db_path }) |gone| {
        try testing.expect(!contains(result.stdout, gone));
    }
    try expectNarrow(result.stdout, &.{});
    try fixture.expectNoLeftovers();
}

test "the default summary of a mismatch hides the one-sided rows unless --show-rows is given" {
    var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("human", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.startsWith(u8, result.stdout,
        \\Summary
        \\  result rows   MISMATCH (the rows differ; the cause is not determined)
        \\  rows read     4 -> 2
        \\  rows written  0 -> 0
        \\  verdict       not-judged:
        \\                - the result rows do not match, so the row counts are not judged
        \\
    ));
    try testing.expect(contains(result.stdout, "  time          not measured (0 rounds; reference only)\n"));
    try testing.expect(contains(result.stdout, "\nResult rows\n" ++
        \\  MISMATCH: the rows differ, compared as a multiset; the cause is not determined
        \\  baseline only 1 row
        \\  variant only  1 row
        \\  examples      rerun with --show-rows to see them
        \\
    ));
    try testing.expect(!contains(result.stdout, "[1, 'x']"));
    try testing.expect(!contains(result.stdout, "[1, 'y']"));
    try testing.expect(!contains(result.stdout, "time median"));
    try testing.expect(!contains(result.stdout, "row order"));
    try expectNarrow(result.stdout, &.{});

    var shown_stdout: [8192]u8 = undefined;
    var shown_stderr: [1024]u8 = undefined;
    const shown = fixture.runFormat("human", &.{"--show-rows"}, &shown_stdout, &shown_stderr);
    try testing.expectEqual(ExitCode.mismatch, shown.code);
    try testing.expect(contains(shown.stdout, "\nResult rows\n" ++
        \\  MISMATCH: the rows differ, compared as a multiset; the cause is not determined
        \\  baseline only 1 row, the first 1 below
        \\                [1, 'x']
        \\  variant only  1 row, the first 1 below
        \\                [1, 'y']
        \\
    ));
    try testing.expect(!contains(shown.stdout, "rerun with --show-rows"));
    try expectNarrow(shown.stdout, &.{});
    try fixture.expectNoLeftovers();
}

test "the default summary of an incomparable select pairs each reason with its hint" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > 0 LIMIT 2", "CREATE INDEX idx_a ON t(a)", reordered_schema);
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("human", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "Summary\n  result rows   INCOMPARABLE (the rows cannot be compared; see Result rows)\n"));
    try testing.expect(contains(result.stdout, "\nResult rows\n" ++
        \\  INCOMPARABLE: the rows of the two copies cannot be compared
        \\  - the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other
        \\    rows when the order changes
        \\    try: to compare, end the ORDER BY next to the LIMIT with a unique NOT NULL
        \\         column, or drop LIMIT and OFFSET; then check that the plan still uses
        \\         the candidate index
        \\  baseline only 1 row
        \\  variant only  1 row
        \\  examples      rerun with --show-rows to see them
        \\
    ));
    try testing.expect(!contains(result.stdout, "the first "));
    try testing.expect(!contains(result.stdout, "row order"));
    try expectNarrow(result.stdout, &.{});
}

test "the default summary hides the bind values unless --show-binds is given" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1 AND b <> ?2 AND ?3 IS NULL AND ?4 < 9", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const binds = [_][:0]const u8{ "--bind", "1:int:1", "--bind", "2:text:secret", "--bind", "3:null", "--bind", "4:real:1.5", "--runs", "0" };

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const hidden = fixture.runFormat("human", &binds, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, hidden.code);
    try testing.expect(!contains(hidden.stdout, "binds"));
    try testing.expect(!contains(hidden.stdout, "secret"));
    try testing.expect(!contains(hidden.stdout, "1.5"));

    var shown_stdout_buffer: [8192]u8 = undefined;
    var shown_stderr_buffer: [1024]u8 = undefined;
    const shown = fixture.runFormat("human", &(binds ++ [_][:0]const u8{"--show-binds"}), &shown_stdout_buffer, &shown_stderr_buffer);
    try testing.expectEqual(ExitCode.ok, shown.code);
    try testing.expect(contains(shown.stdout, "  binds         1:int:1, 2:text:'secret', 3:null, 4:real:1.5e0\n"));
}

test "the default summary notes rows in a different order" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > ?1", "CREATE INDEX idx_a ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (3, 'z'), (1, 'x'), (2, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("human", &.{ "--bind", "1:int:0", "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "\nResult rows\n  row order     differs (reference only;"));
    try testing.expect(!contains(result.stdout, "same (reference only"));
    try expectNarrow(result.stdout, &.{});
    try fixture.expectNoLeftovers();
}

test "a usage error names the argument it is about" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{ .argv = &.{ "Qenome", "--nope" }, .stderr = "error: unknown option '--nope' (see --help)\n" },
        .{ .argv = &.{ "Qenome", "--\x1b[2J" }, .stderr = "error: unknown option '--\\x1b[2J' (see --help)\n" },
        .{ .argv = &.{ "Qenome", "d", "s", "i", "extra" }, .stderr = "error: unexpected argument 'extra'; paths are the database, the SELECT file and the CREATE INDEX file, at most 3 (see --help)\n" },
        .{ .argv = &.{ "Qenome", "", "s", "i" }, .stderr = "error: a path cannot be empty (see --help)\n" },
        .{ .argv = &.{ "Qenome", "--db" }, .stderr = "error: --db needs a value (see --help)\n" },
        .{ .argv = &.{ "Qenome", "--format", "JSON" }, .stderr = "error: --format expects human, kv or json\n" },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "an unknown option suggests the closest known name" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{
            .argv = &.{ "Qenome", "--run", "3" },
            .stderr = "error: unknown option '--run'; did you mean '--runs'? (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--indexsql=x" },
            .stderr = "error: unknown option '--indexsql=x'; did you mean '--index-sql'? (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "-db", "x" },
            .stderr = "error: unknown option '-db'; did you mean '--db'? (see --help)\n",
        },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "a flag does not take an inline value" {
    const cases = [_]struct { arg: [:0]const u8, stderr: []const u8 }{
        .{ .arg = "--show-binds=1", .stderr = "error: --show-binds does not take a value (see --help)\n" },
        .{ .arg = "--show-rows=1", .stderr = "error: --show-rows does not take a value (see --help)\n" },
        .{ .arg = "--help=1", .stderr = "error: --help does not take a value (see --help)\n" },
        .{ .arg = "--version=1", .stderr = "error: --version does not take a value (see --help)\n" },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", case.arg }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "an empty value is a usage error" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{
            .argv = &.{ "Qenome", "--db=", "--select", "s", "--index-sql", "i" },
            .stderr = "error: --db needs a value (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--db", "", "--select", "s", "--index-sql", "i" },
            .stderr = "error: --db needs a value (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--format=", "--db", "d", "--select", "s", "--index-sql", "i" },
            .stderr = "error: --format needs a value (see --help)\n",
        },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "a missing value is not taken from the next option" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{
            .argv = &.{ "Qenome", "--db", "--select", "s.sql", "--index-sql", "i.sql" },
            .stderr = "error: --db needs a value (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--db", "d.db", "--select", "--index-sql", "i.sql" },
            .stderr = "error: --select needs a value (see --help)\n",
        },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "a repeated single-value option is a usage error" {
    const cases = [_]struct { argv: []const [:0]const u8, stderr: []const u8 }{
        .{
            .argv = &.{ "Qenome", "--db", "a", "--db", "b" },
            .stderr = "error: --db was given more than once (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--select=a", "--select=b" },
            .stderr = "error: --select was given more than once (see --help)\n",
        },
        .{
            .argv = &.{ "Qenome", "--index-sql", "a", "--index-sql=b" },
            .stderr = "error: --index-sql was given more than once (see --help)\n",
        },
    };
    for (cases) |case| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, case.argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "help wins over other argument errors" {
    const cases = [_][]const [:0]const u8{
        &.{ "Qenome", "-h", "--db" },
        &.{ "Qenome", "--help", "--nope" },
        &.{ "Qenome", "--db=", "--help" },
        &.{ "Qenome", "--db", "a", "--db", "b", "-h" },
    };
    for (cases) |argv| {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, argv, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expect(std.mem.startsWith(u8, result.stdout, "usage: qenome"));
        try testing.expectEqualStrings("", result.stderr);
    }
}

test "the equals form runs a comparison" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var db_buffer: [1024]u8 = undefined;
    var select_buffer: [1024]u8 = undefined;
    var index_buffer: [1024]u8 = undefined;
    const db_arg = try std.mem.printSentinel(&db_buffer, "--db={s}", .{fixture.db_path}, 0);
    const select_arg = try std.mem.printSentinel(&select_buffer, "--select={s}", .{fixture.select_path}, 0);
    const index_arg = try std.mem.printSentinel(&index_buffer, "--index-sql={s}", .{fixture.index_path}, 0);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", db_arg, select_arg, index_arg, "--runs=0", "--format=kv" },
        fixture.work_parent,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "result: match (row multiset)\n"));
    try testing.expectEqualStrings("", result.stderr);
    try fixture.expectNoLeftovers();
}

test "sql text in place of a file path gets a hint" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", "--db", "d", "--select", "SELECT 1", "--index-sql", "i" },
        null,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings(
        "error: cannot read --select file 'SELECT 1': no such file; --select takes a path to a file holding the SQL, not the SQL text\n",
        result.stderr,
    );
}

test "sql text in place of the index file gets a hint" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", "--db", fixture.db_path, "--select", fixture.select_path, "--index-sql", "CREATE INDEX idx_a ON t(a)" },
        fixture.work_parent,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings(
        "error: cannot read --index-sql file 'CREATE INDEX idx_a ON t(a)': no such file; --index-sql takes a path to a file holding the SQL, not the SQL text\n",
        result.stderr,
    );
}

test "a directory in place of a file says it is a directory" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", "--db", fixture.db_path, "--select", fixture.work_parent, "--index-sql", fixture.index_path },
        null,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, ": is a directory\n"));
    try testing.expect(!contains(result.stderr, "IsDir"));
}

test "bind count errors name the problem and the next step" {
    const cases = [_]struct {
        select_sql: [:0]const u8,
        index_sql: [:0]const u8,
        extra: []const [:0]const u8,
        stderr: []const u8,
    }{
        .{
            .select_sql = "SELECT a FROM t WHERE a = ?1 AND b = ?2",
            .index_sql = "CREATE INDEX idx_a ON t(a)",
            .extra = &.{ "--bind", "2:int:1" },
            .stderr = "error: --bind: the SELECT has 2 parameters but --bind is missing parameter 1; add one per parameter, e.g. --bind 1:int:1234 (parameters in the SELECT: 2; --bind given: 1)\n",
        },
        .{
            .select_sql = "SELECT a FROM t WHERE a = ?1 AND b = ?2",
            .index_sql = "CREATE INDEX idx_a ON t(a)",
            .extra = &.{ "--bind", "1:int:1", "--bind", "1:text:x" },
            .stderr = "error: --bind: bind number 1 is given more than once; give each parameter once, e.g. --bind 1:int:1234 (parameters in the SELECT: 2; --bind given: 2)\n",
        },
        .{
            .select_sql = "SELECT a FROM t WHERE a = ?1 AND b = ?2",
            .index_sql = "CREATE INDEX idx_a ON t(a)",
            .extra = &.{ "--bind", "3:int:1" },
            .stderr = "error: --bind: bind number 3 is outside 1..2; use the parameter numbers 1 to 2, e.g. --bind 2:int:1234 (parameters in the SELECT: 2; --bind given: 1)\n",
        },
        .{
            .select_sql = "SELECT a FROM t WHERE a = ?1",
            .index_sql = "CREATE INDEX idx_a ON t(a)",
            .extra = &.{ "--bind", "1:int:1", "--bind", "1:int:2" },
            .stderr = "error: --bind: the SELECT has 1 parameter but 2 --bind values were given; bind number 1 is repeated (give exactly one per parameter); e.g. --bind 1:int:1234 (parameters in the SELECT: 1; --bind given: 2)\n",
        },
        .{
            .select_sql = "SELECT 1",
            .index_sql = "CREATE INDEX idx_a ON t(a)",
            .extra = &.{ "--bind", "1:int:1" },
            .stderr = "error: --bind: the SELECT has no parameters but --bind was given; remove the --bind values (parameters in the SELECT: 0; --bind given: 1)\n",
        },
    };
    for (cases) |case| {
        var fixture = try CliFixture.init(case.select_sql, case.index_sql);
        defer fixture.deinit();
        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [2048]u8 = undefined;
        const result = fixture.run(case.extra, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.rejected, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
        try fixture.expectNoLeftovers();
    }
}

test "positional paths run a comparison" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", fixture.db_path, fixture.select_path, fixture.index_path, "--runs=0", "--format=kv" },
        fixture.work_parent,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "result: match (row multiset)\n"));
    try testing.expectEqualStrings("", result.stderr);
    try fixture.expectNoLeftovers();
}

test "positional and named paths can be mixed" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var first_stdout: [4096]u8 = undefined;
    var first_stderr: [512]u8 = undefined;
    const first = callRun(
        testing.allocator,
        &.{ "Qenome", fixture.db_path, "--select", fixture.select_path, "--index-sql", fixture.index_path, "--runs=0", "--format=kv" },
        fixture.work_parent,
        &first_stdout,
        &first_stderr,
    );
    try testing.expectEqual(ExitCode.ok, first.code);
    try testing.expect(contains(first.stdout, "result: match (row multiset)\n"));
    try testing.expectEqualStrings("", first.stderr);
    try fixture.expectNoLeftovers();

    var second_stdout: [4096]u8 = undefined;
    var second_stderr: [512]u8 = undefined;
    const second = callRun(
        testing.allocator,
        &.{ "Qenome", "--db", fixture.db_path, fixture.select_path, fixture.index_path, "--runs=0", "--format=kv" },
        fixture.work_parent,
        &second_stdout,
        &second_stderr,
    );
    try testing.expectEqual(ExitCode.ok, second.code);
    try testing.expect(contains(second.stdout, "result: match (row multiset)\n"));
    try testing.expectEqualStrings("", second.stderr);
    try fixture.expectNoLeftovers();
}

test "a duplicate path and named option is a usage error" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", fixture.db_path, "--db", "other.db", "--select", fixture.select_path, "--index-sql", fixture.index_path },
        null,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("error: --db was given more than once (see --help)\n", result.stderr);
}

test "a fourth path is a usage error" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(
        testing.allocator,
        &.{ "Qenome", fixture.db_path, fixture.select_path, fixture.index_path, "extra" },
        null,
        &stdout_buffer,
        &stderr_buffer,
    );
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("error: unexpected argument 'extra'; paths are the database, the SELECT file and the CREATE INDEX file, at most 3 (see --help)\n", result.stderr);
}

test "swapped SELECT and CREATE INDEX files get a hint" {
    var forward = try CliFixture.init("CREATE INDEX idx_a ON t(a)", "SELECT a FROM t");
    defer forward.deinit();

    var forward_stdout: [512]u8 = undefined;
    var forward_stderr: [1024]u8 = undefined;
    const forward_result = forward.run(&.{}, &forward_stdout, &forward_stderr);
    try testing.expectEqual(ExitCode.rejected, forward_result.code);
    try testing.expectEqualStrings("", forward_result.stdout);
    try testing.expectEqualStrings(
        "error: --select: the statement is not allowed here: not authorized\nhint: the SELECT and CREATE INDEX files may be swapped\n",
        forward_result.stderr,
    );
    try forward.expectNoLeftovers();

    var backward = try CliFixture.init("SELECT a FROM t", "SELECT a FROM t");
    defer backward.deinit();

    var backward_stdout: [512]u8 = undefined;
    var backward_stderr: [1024]u8 = undefined;
    const backward_result = backward.run(&.{}, &backward_stdout, &backward_stderr);
    try testing.expectEqual(ExitCode.rejected, backward_result.code);
    try testing.expectEqualStrings("", backward_result.stdout);
    try testing.expectEqualStrings(
        "error: --index-sql: the statement is not allowed here: not authorized\nhint: the SELECT and CREATE INDEX files may be swapped\n",
        backward_result.stderr,
    );
    try backward.expectNoLeftovers();

    var insert = try CliFixture.init("INSERT INTO t VALUES (1)", "CREATE INDEX idx_a ON t(a)");
    defer insert.deinit();

    var insert_stdout: [512]u8 = undefined;
    var insert_stderr: [1024]u8 = undefined;
    const insert_result = insert.run(&.{}, &insert_stdout, &insert_stderr);
    try testing.expectEqual(ExitCode.rejected, insert_result.code);
    try testing.expectEqualStrings("", insert_result.stdout);
    try testing.expectEqualStrings("error: --select: the statement is not allowed here: not authorized\n", insert_result.stderr);
    try insert.expectNoLeftovers();
}

test "named and numbered parameters use SQLite's parameter numbers" {
    var mixed = try CliFixture.init("SELECT a FROM t WHERE a = ?2 OR a = :cid", "CREATE INDEX idx_a ON t(a)");
    defer mixed.deinit();
    var mixed_stdout: [4096]u8 = undefined;
    var mixed_stderr: [512]u8 = undefined;
    const mixed_result = mixed.run(&.{ "--bind", "1:null", "--bind", "2:int:1", "--bind", "3:int:2", "--runs", "0" }, &mixed_stdout, &mixed_stderr);
    try testing.expectEqual(ExitCode.ok, mixed_result.code);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, mixed_result.stdout, "rows: 2\n"));
    try testing.expectEqualStrings("", mixed_result.stderr);
    try mixed.expectNoLeftovers();

    var repeated = try CliFixture.init("SELECT a FROM t WHERE a = :cid OR a = :cid", "CREATE INDEX idx_a ON t(a)");
    defer repeated.deinit();
    var repeated_stdout: [4096]u8 = undefined;
    var repeated_stderr: [512]u8 = undefined;
    const repeated_result = repeated.run(&.{ "--bind", "1:int:1", "--runs", "0" }, &repeated_stdout, &repeated_stderr);
    try testing.expectEqual(ExitCode.ok, repeated_result.code);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, repeated_result.stdout, "rows: 1\n"));
    try testing.expectEqualStrings("", repeated_result.stderr);
    try repeated.expectNoLeftovers();
}

test "a bind error says how many parameters the SELECT has" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("human", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("error: --bind: the SELECT has 1 parameter but no --bind was given; add one per parameter, e.g. --bind 1:int:1234 (parameters in the SELECT: 1; --bind given: 0)\n", result.stderr);
    try fixture.expectNoLeftovers();
}

test "help fits in 80 columns and names the formats" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--help" }, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  --format <FORMAT>    human (default), kv or json\n"));
    try testing.expect(contains(result.stdout, "  --show-rows          print the example rows that only one copy"));
    try testing.expect(contains(result.stdout, "exit status:"));
    try expectNarrow(result.stdout, &.{});
}

test "help puts the usage, options, examples and exit status before the details" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--help" }, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);

    var last: usize = 0;
    for ([_][]const u8{ "usage: qenome", "options", "examples:", "exit status:", "output (stdout" }) |needle| {
        const at = std.mem.indexOf(u8, result.stdout, needle) orelse return error.MissingText;
        try testing.expect(at >= last);
        last = at;
    }
    try testing.expect(contains(result.stdout, "  qenome app.db select.sql index.sql\n"));
    try testing.expect(contains(result.stdout, "--bind 1:int:1234"));
    try testing.expect(contains(result.stdout, "--format kv"));
    try testing.expect(contains(result.stdout, "The same paths can be given as --db, --select and --index-sql."));
    try testing.expect(contains(result.stdout, "named parameters"));
    try testing.expect(contains(result.stdout, "share the number of their first appearance"));
    try testing.expect(contains(result.stdout, "two baseline A/A runs; 0 skips"));
    try testing.expect(contains(result.stdout, "the timing but keeps the row counts and verdict"));
    try testing.expect(contains(result.stdout, "--runs 0 is still judged"));
    try testing.expect(!contains(result.stdout, "or --runs 0"));
    try testing.expect(!contains(result.stdout, "Time verdict"));
    try expectNarrow(result.stdout, &.{});
}

test "json format parses and carries the decision keys" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("json", &.{ "--bind", "1:int:1", "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, 2), try jsonInt(root, "schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("no-effect", try jsonText(root, "verdict"));
    const verdict_reasons = try jsonItems(root, "verdict_reasons");
    try testing.expectEqual(@as(usize, 0), verdict_reasons.len);
    try testing.expectEqualStrings("match", try jsonText(root, "result"));
    try testing.expectEqualStrings("same", try jsonText(root, "row_order"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "result_reasons")).len);
    try testing.expect(try jsonBool(root, "plan_changed"));
    try testing.expect(try jsonGet(root, "timing") == .null);
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(root, "measurement"), "runs_per_copy"));

    const baseline = try jsonGet(root, "baseline");
    const variant = try jsonGet(root, "variant");
    try testing.expectEqual(@as(i64, 1), try jsonInt(baseline, "rows"));
    try testing.expectEqualStrings("SCAN t", try jsonText((try jsonItems(baseline, "plan"))[0], "detail"));
    try testing.expectEqualStrings("search", try jsonText((try jsonItems(variant, "plan"))[0], "kind"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(variant, "counters"), "fullscan_steps"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(try jsonGet(baseline, "counters"), "rows_read"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(try jsonGet(variant, "counters"), "rows_read"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(baseline, "counters"), "rows_written"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(try jsonGet(variant, "counters"), "rows_written"));

    const sizes = try jsonGet(root, "size_bytes");
    const baseline_size = try jsonInt(sizes, "baseline");
    const variant_size = try jsonInt(sizes, "variant");
    try testing.expect(variant_size > baseline_size);
    try testing.expectEqual(variant_size - baseline_size, try jsonInt(sizes, "increase"));

    const inputs = try jsonGet(root, "inputs");
    try testing.expectEqualStrings(fixture.db_path, try jsonText(inputs, "database"));
    try testing.expectEqualStrings(fixture.select_path, try jsonText(inputs, "select"));
    try testing.expectEqualStrings(fixture.index_path, try jsonText(inputs, "index_sql"));

    const environment = try jsonGet(root, "environment");
    try testing.expectEqualStrings(cli.version, try jsonText(environment, "qenome_version"));
    try testing.expectEqualStrings(sqlite.pinned_version, try jsonText(environment, "sqlite_version"));
    try testing.expectEqualStrings(sqlite.pinned_source_id, try jsonText(environment, "sqlite_source_id"));
    try testing.expectEqualStrings(builtin.zig_version_string, try jsonText(environment, "zig_version"));
    try testing.expectEqualStrings(@tagName(builtin.mode), try jsonText(environment, "build_mode"));
    try testing.expectEqualStrings(@tagName(builtin.os.tag), try jsonText(environment, "os"));
    try testing.expectEqualStrings(@tagName(builtin.cpu.arch), try jsonText(environment, "arch"));
    try testing.expectEqualStrings(fixture.work_parent, try jsonText(environment, "work_dir_parent"));

    const binds = try jsonItems(root, "binds");
    try testing.expectEqual(@as(usize, 1), binds.len);
    try testing.expectEqualStrings("int", try jsonText(binds[0], "type"));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\"value\"") == null);
    try fixture.expectNoLeftovers();
}

test "json format hides bind values unless --show-binds is given" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE b = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const binds = [_][:0]const u8{ "--bind", "1:text:secret", "--runs", "0" };

    var hidden_buffer: [32768]u8 = undefined;
    var hidden_stderr: [1024]u8 = undefined;
    const hidden = fixture.runFormat("json", &binds, &hidden_buffer, &hidden_stderr);
    try testing.expectEqual(ExitCode.ok, hidden.code);
    try testing.expect(std.mem.indexOf(u8, hidden.stdout, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, hidden.stdout, "\"value\"") == null);

    var parsed_hidden = try parseJson(hidden.stdout);
    defer parsed_hidden.deinit();
    const hidden_bind = (try jsonItems(parsed_hidden.value, "binds"))[0];
    try testing.expectEqualStrings("text", try jsonText(hidden_bind, "type"));
    try testing.expectEqual(@as(i64, 6), try jsonInt(hidden_bind, "text_bytes"));

    var shown_buffer: [32768]u8 = undefined;
    var shown_stderr: [1024]u8 = undefined;
    const shown = fixture.runFormat("json", &(binds ++ [_][:0]const u8{"--show-binds"}), &shown_buffer, &shown_stderr);
    try testing.expectEqual(ExitCode.ok, shown.code);

    var parsed_shown = try parseJson(shown.stdout);
    defer parsed_shown.deinit();
    const shown_bind = (try jsonItems(parsed_shown.value, "binds"))[0];
    try testing.expectEqualStrings("secret", try jsonText(shown_bind, "value"));
    try fixture.expectNoLeftovers();
}

test "json format on a mismatch keeps the counts and hides example rows unless --show-rows is given" {
    var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, CAST(x'00ff' AS TEXT)), (1, x'00ff');
    );
    defer fixture.deinit();

    const weird_path = try fixture.dir.file("sel\"ect\\\npath.sql", "SELECT a, b FROM t GROUP BY a");
    defer testing.allocator.free(weird_path);

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        weird_path,
        "--index-sql",
        fixture.index_path,
        "--format",
        "json",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, 3), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("mismatch", try jsonText(root, "result"));
    try testing.expectEqualStrings("not-applicable", try jsonText(root, "row_order"));
    try testing.expectEqualStrings("not-judged", try jsonText(root, "verdict"));
    try testing.expect(try jsonGet(root, "timing") == .null);
    const select_text = try jsonText(try jsonGet(root, "inputs"), "select");
    const expected_select = try testing.allocator.alloc(u8, weird_path.len + std.mem.count(u8, weird_path, "\\"));
    defer testing.allocator.free(expected_select);
    _ = std.mem.replace(u8, weird_path, "\\", "\\\\", expected_select);
    try testing.expectEqualStrings(expected_select, select_text);
    try testing.expect(std.mem.indexOfScalar(u8, weird_path, '\\') != null);

    const differences = try jsonGet(root, "row_differences");
    try testing.expectEqual(@as(i64, 1), try jsonInt(differences, "baseline_only"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(differences, "variant_only"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(differences, "baseline_only_examples")).len);
    try testing.expectEqual(@as(usize, 0), (try jsonItems(differences, "variant_only_examples")).len);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\\x00") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "x'00ff'") == null);

    var shown_buffer: [32768]u8 = undefined;
    var shown_stderr: [1024]u8 = undefined;
    const shown = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        weird_path,
        "--index-sql",
        fixture.index_path,
        "--format",
        "json",
        "--show-rows",
    }, fixture.work_parent, &shown_buffer, &shown_stderr);
    try testing.expectEqual(ExitCode.mismatch, shown.code);
    try testing.expectEqualStrings("", shown.stderr);

    var shown_parsed = try parseJson(shown.stdout);
    defer shown_parsed.deinit();
    const shown_differences = try jsonGet(shown_parsed.value, "row_differences");
    try testing.expectEqual(@as(i64, 1), try jsonInt(shown_differences, "baseline_only"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(shown_differences, "variant_only"));
    const baseline_examples = try jsonItems(shown_differences, "baseline_only_examples");
    const variant_examples = try jsonItems(shown_differences, "variant_only_examples");
    try testing.expectEqual(@as(usize, 1), baseline_examples.len);
    try testing.expectEqual(@as(usize, 1), variant_examples.len);
    try testing.expectEqualStrings("[1, '\\x00\\xff']", baseline_examples[0].string);
    try testing.expectEqualStrings("[1, x'00ff']", variant_examples[0].string);
    try fixture.expectNoLeftovers();
}

test "json format on an incomparable select pairs each reason with its hint" {
    var fixture = try CliFixture.init("SELECT a, random() FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = fixture.runFormat("json", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, 4), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("incomparable", try jsonText(root, "result"));
    try testing.expectEqualStrings("not-applicable", try jsonText(root, "row_order"));
    try testing.expectEqualStrings("not-judged", try jsonText(root, "verdict"));
    try testing.expect(try jsonGet(root, "timing") == .null);

    const reasons = try jsonItems(root, "result_reasons");
    try testing.expect(reasons.len != 0);
    try testing.expect(contains(try jsonText(reasons[0], "text"), "random()"));
    try testing.expect(contains(try jsonText(reasons[0], "hint"), "random()"));
    try fixture.expectNoLeftovers();
}

test "json format keeps stdout empty when the select is rejected" {
    var fixture = try CliFixture.init("INSERT INTO t VALUES (3, 'z')", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.runFormat("json", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "statement_rejected", 1);
    try testing.expect(contains(result.stderr, "--select:"));
    try fixture.expectNoLeftovers();
}

test "json format reports a repeated bind number as bind_rejected" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1 AND b = ?2", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runFormat("json", &.{ "--bind", "1:int:1", "--bind", "1:text:x" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "bind_rejected", 1);
    try testing.expect(contains(result.stderr, "bind number 1 is given more than once"));
    try fixture.expectNoLeftovers();
}

const d1_database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

const d1_file_name = "b4b7ee9bc0328fad0039fd55bcee866dbb7978adad944643b49c9071c8746c37.sqlite";

const d1_state_dir = ".wrangler/state/v3/d1/miniflare-D1DatabaseObject";

fn joinSentinel(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![:0]u8 {
    return std.fs.path.joinZ(allocator, &.{ directory, name });
}

const Cwd = struct {
    original: [:0]u8,

    fn enter(allocator: std.mem.Allocator, path: []const u8) !Cwd {
        const original = try std.process.currentPathAlloc(testing.io, allocator);
        try std.process.setCurrentPath(testing.io, path);
        return .{ .original = original };
    }

    fn restore(self: *Cwd, allocator: std.mem.Allocator) void {
        std.process.setCurrentPath(testing.io, self.original) catch {};
        allocator.free(self.original);
    }
};

const D1Fixture = struct {
    dir: Fixture,
    root: [:0]u8,
    config_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    work_parent: [:0]u8,
    local_path: [:0]u8,

    fn init(
        allocator: std.mem.Allocator,
        config_name: []const u8,
        config_text: []const u8,
        create_local: bool,
    ) !D1Fixture {
        var dir = try Fixture.init();
        errdefer dir.deinit();
        const root = try dir.tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
        errdefer allocator.free(root);
        const config_path = try joinSentinel(allocator, root, config_name);
        errdefer allocator.free(config_path);
        try dir.tmp.dir.writeFile(testing.io, .{ .sub_path = config_name, .data = config_text });
        try dir.tmp.dir.createDirPath(testing.io, d1_state_dir);
        const local_path = try joinSentinel(allocator, root, d1_state_dir ++ "/" ++ d1_file_name);
        errdefer allocator.free(local_path);
        if (create_local) try db.createTestDatabase(local_path, fixture_schema);
        const select_path = try dir.file("select.sql", "SELECT b FROM t WHERE b = 'x'");
        errdefer allocator.free(select_path);
        const index_path = try dir.file("index.sql", "CREATE INDEX idx_b2 ON t(b)");
        errdefer allocator.free(index_path);
        try dir.tmp.dir.createDir(testing.io, "work", .default_dir);
        const work_parent = try dir.tmp.dir.realPathFileAlloc(testing.io, "work", allocator);
        return .{
            .dir = dir,
            .root = root,
            .config_path = config_path,
            .select_path = select_path,
            .index_path = index_path,
            .work_parent = work_parent,
            .local_path = local_path,
        };
    }

    fn deinit(self: *D1Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.config_path);
        allocator.free(self.select_path);
        allocator.free(self.index_path);
        allocator.free(self.work_parent);
        allocator.free(self.local_path);
        self.dir.deinit();
    }

    fn expectNoLeftovers(self: *D1Fixture) !void {
        var parent = try self.dir.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
        defer parent.close(testing.io);
        var it = parent.iterate();
        if (try it.next(testing.io)) |entry| {
            std.debug.print("left behind: {s}\n", .{entry.name});
            return error.TemporaryDirectoryLeft;
        }
    }

    fn run(
        self: *D1Fixture,
        allocator: std.mem.Allocator,
        binding: [:0]const u8,
        with_config: bool,
        format: [:0]const u8,
        extra: []const [:0]const u8,
        stdout_buffer: []u8,
        stderr_buffer: []u8,
    ) RunResult {
        var argv: [24][:0]const u8 = undefined;
        argv[0] = "Qenome";
        argv[1] = "--d1";
        argv[2] = binding;
        var count: usize = 3;
        if (with_config) {
            argv[count] = "--config";
            argv[count + 1] = self.config_path;
            count += 2;
        }
        argv[count] = "--select";
        argv[count + 1] = self.select_path;
        argv[count + 2] = "--index-sql";
        argv[count + 3] = self.index_path;
        argv[count + 4] = "--format";
        argv[count + 5] = format;
        count += 6;
        @memcpy(argv[count..][0..extra.len], extra);
        return callRun(allocator, argv[0 .. count + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }
};

const d1_toml =
    \\name = "app"
    \\compatibility_date = "2024-01-01"
    \\
    \\# the local database
    \\[[d1_databases]]
    \\binding = "DB"
    \\database_name = "app-db"
    \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    \\
;

const d1_jsonc =
    \\{
    \\  // local development
    \\  "name": "app",
    \\  "d1_databases": [
    \\    {
    \\      "binding": "DB",
    \\      "database_name": "app-db",
    \\      "database_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    \\    },
    \\  ],
    \\}
    \\
;

test "d1 with a wrangler.toml compares the local database (kv)" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", d1_toml, true);
    defer fixture.deinit(testing.allocator);

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.run(testing.allocator, "DB", true, "kv", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "d1-binding: DB\n"));
    try testing.expect(contains(result.stdout, "d1-config: "));
    try testing.expect(contains(result.stdout, "d1-database-id: " ++ d1_database_id ++ "\n"));
    try testing.expect(contains(result.stdout, "d1-local-database: "));
    try testing.expect(contains(result.stdout, d1_file_name));
    try testing.expect(contains(result.stdout, "d1-sqlite-version: 3.53.4\n"));
    try testing.expect(contains(result.stdout, "SQLite " ++ sqlite.pinned_version));
    try testing.expect(contains(result.stdout, "plans and times can differ"));
    try testing.expect(contains(result.stdout, "d1-caution: "));
    try testing.expect(contains(result.stdout, "production D1"));
    try testing.expect(contains(result.stdout, "result: match"));
    try fixture.expectNoLeftovers();
}

test "d1 with a wrangler.jsonc shows the same notes in human and json" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.jsonc", d1_jsonc, true);
    defer fixture.deinit(testing.allocator);

    var human_buffer: [32768]u8 = undefined;
    var human_error: [2048]u8 = undefined;
    const human = fixture.run(testing.allocator, "DB", true, "human", &.{}, &human_buffer, &human_error);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(contains(human.stdout, "\nD1\n"));
    try testing.expect(contains(human.stdout, "binding"));
    try testing.expect(contains(human.stdout, "local file"));
    try testing.expect(contains(human.stdout, sqlite.pinned_version));
    try testing.expect(contains(human.stdout, "in D1"));
    try testing.expect(contains(human.stdout, "3.53.4"));
    try testing.expect(contains(human.stdout, "production D1"));

    var json_buffer: [65536]u8 = undefined;
    var json_error: [2048]u8 = undefined;
    const json = fixture.run(testing.allocator, "DB", true, "json", &.{}, &json_buffer, &json_error);
    try testing.expectEqual(ExitCode.ok, json.code);
    try testing.expectEqualStrings("", json.stderr);

    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 2), try jsonInt(root, "schema_version"));
    try testing.expectEqualStrings("match", try jsonText(root, "result"));
    const d1 = try jsonGet(root, "d1");
    try testing.expectEqualStrings("DB", try jsonText(d1, "binding"));
    try testing.expectEqualStrings(d1_database_id, try jsonText(d1, "database_id"));
    try testing.expectEqualStrings("3.53.4", try jsonText(d1, "sqlite_version"));
    try testing.expect(contains(try jsonText(d1, "sqlite_version_note"), sqlite.pinned_version));
    try testing.expect(contains(try jsonText(d1, "caution"), "production D1"));
    try testing.expectEqualStrings(fixture.local_path, try jsonText(d1, "local_database"));
}

test "d1 finds the config in the current directory" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", d1_toml, true);
    defer fixture.deinit(testing.allocator);

    var cwd = try Cwd.enter(testing.allocator, fixture.root);
    defer cwd.restore(testing.allocator);

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.run(testing.allocator, "DB", false, "kv", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "d1-config: wrangler.toml\n"));
    const expected = try std.fs.path.join(testing.allocator, &.{ ".wrangler", "state", "v3", "d1", "miniflare-D1DatabaseObject", d1_file_name });
    defer testing.allocator.free(expected);
    var line_buffer: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "d1-local-database: {s}\n", .{expected});
    try testing.expect(contains(result.stdout, line));
    try fixture.expectNoLeftovers();
}

test "d1 accepts the positional paths before --d1" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", d1_toml, true);
    defer fixture.deinit(testing.allocator);

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",   fixture.select_path, fixture.index_path, "--d1", "DB",
        "--config", fixture.config_path, "--format",         "kv",   "--runs",
        "0",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "d1-binding: DB\n"));
    try testing.expect(contains(result.stdout, "result: match"));
    try fixture.expectNoLeftovers();
}

test "d1 stops with status 4 when no wrangler config is present" {
    var dir = try Fixture.init();
    defer dir.deinit();
    const select_path = try dir.file("select.sql", "SELECT 1");
    defer testing.allocator.free(select_path);
    const index_path = try dir.file("index.sql", "CREATE INDEX idx_a ON t(a)");
    defer testing.allocator.free(index_path);

    const root = try dir.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var cwd = try Cwd.enter(testing.allocator, root);
    defer cwd.restore(testing.allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome", "--d1", "DB", "--select", select_path, "--index-sql", index_path, "--format", "json",
    }, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "d1_config_not_found", 4);
    try testing.expect(contains(result.stderr, "no wrangler config in the current directory"));
    try testing.expect(contains(result.stderr, "wrangler.toml"));
    try testing.expect(contains(result.stderr, "--config"));
}

test "d1 stops with status 4 when the binding is missing" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", d1_toml, true);
    defer fixture.deinit(testing.allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.run(testing.allocator, "MISSING", true, "kv", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "no top-level d1_databases binding named 'MISSING'"));
    try testing.expect(contains(result.stderr, "known bindings: DB"));
    try fixture.expectNoLeftovers();
}

test "d1 stops with status 4 when two config files are present" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", d1_toml, true);
    defer fixture.deinit(testing.allocator);
    try fixture.dir.tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.jsonc", .data = d1_jsonc });

    var cwd = try Cwd.enter(testing.allocator, fixture.root);
    defer cwd.restore(testing.allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.run(testing.allocator, "DB", false, "kv", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "more than one wrangler config"));
    try testing.expect(contains(result.stderr, "wrangler.toml, wrangler.jsonc"));
}

test "d1 stops with status 4 when the binding is duplicated" {
    const duplicated =
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "11111111-2222-3333-4444-555555555555"
        \\
    ;
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.toml", duplicated, true);
    defer fixture.deinit(testing.allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = fixture.run(testing.allocator, "DB", true, "kv", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "more than one d1_databases binding named 'DB'"));
}

test "d1 stops with status 4 when the local database does not exist yet" {
    var fixture = try D1Fixture.init(testing.allocator, "wrangler.jsonc", d1_jsonc, false);
    defer fixture.deinit(testing.allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.run(testing.allocator, "DB", true, "json", &.{}, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "d1_local_file_missing", 4);
    try testing.expect(contains(result.stderr, "no local D1 database at"));
    try testing.expect(contains(result.stderr, d1_file_name));
    try testing.expect(contains(result.stderr, "wrangler d1 execute"));
    try fixture.expectNoLeftovers();
}

test "a plain --db run prints no D1 facts in any format" {
    var fixture = try CliFixture.init("SELECT b FROM t WHERE b = 'x'", "CREATE INDEX idx_b2 ON t(b)");
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;

    const human = fixture.runFormat("human", &.{ "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(!contains(human.stdout, "\nD1\n"));
    try testing.expect(!contains(human.stdout, "production D1"));
    try testing.expect(!contains(human.stdout, "in D1"));

    const kv = fixture.runFormat("kv", &.{ "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, kv.code);
    for ([_][]const u8{ "d1-binding: ", "d1-config: ", "d1-database-id: ", "d1-local-database: ", "d1-sqlite-version: ", "d1-caution: " }) |key| {
        try testing.expect(!contains(kv.stdout, key));
    }
    try testing.expect(!contains(kv.stdout, "in D1"));
    try testing.expect(!contains(kv.stdout, "sqlite_version_note"));

    const json = fixture.runFormat("json", &.{ "--runs", "0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), try jsonInt(parsed.value, "schema_version"));
    try testing.expectError(error.TestUnexpectedResult, jsonGet(parsed.value, "d1"));
    try testing.expect(!contains(json.stdout, "sqlite_version_note"));
}

test "warnings describe candidate table and preserve counters verdict and exit across formats" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    var output: [32768]u8 = undefined;
    var errors: [1024]u8 = undefined;
    const json_result = fixture.runFormat("json", &.{ "--runs", "0" }, &output, &errors);
    try testing.expectEqual(ExitCode.ok, json_result.code);
    var parsed = try parseJson(json_result.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 2), warnings.len);
    try testing.expectEqualStrings("no_analyze_stats", try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings("data_too_small", try jsonText(warnings[1], "code"));
    try testing.expectEqualStrings("no-effect", try jsonText(parsed.value, "verdict"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(try jsonGet(try jsonGet(parsed.value, "baseline"), "counters"), "rows_read"));
    for ([_][:0]const u8{ "human", "kv" }) |format| {
        const text_result = fixture.runFormat(format, &.{ "--runs", "0" }, &output, &errors);
        try testing.expectEqual(ExitCode.ok, text_result.code);
        for (warnings) |warning| {
            const code = try jsonText(warning, "code");
            try testing.expect(contains(text_result.stdout, code));
            if (std.mem.eql(u8, format, "kv")) {
                try testing.expect(contains(text_result.stdout, try jsonText(warning, "message")));
            } else {
                const snippet = if (std.mem.eql(u8, code, "no_analyze_stats")) "sqlite_stat1 entry" else "fewer than 1000 rows";
                try testing.expect(contains(text_result.stdout, snippet));
            }
        }
    }
    const timed = fixture.runFormat("json", &.{ "--runs", "6" }, &output, &errors);
    try testing.expectEqual(ExitCode.ok, timed.code);
    var timed_json = try parseJson(timed.stdout);
    defer timed_json.deinit();
    try testing.expectEqualStrings("no-effect", try jsonText(timed_json.value, "verdict"));
    const timing = try jsonGet(timed_json.value, "timing");
    try testing.expectEqual(@as(i64, 6), try jsonInt(try jsonGet(timing, "noise_band"), "pairs"));
    _ = try jsonGet(timing, "confidence_interval");
    _ = try jsonGet(timing, "effect");
    try testing.expectEqual(@as(i64, 2), try jsonInt(try jsonGet(try jsonGet(timed_json.value, "baseline"), "counters"), "rows_read"));
    try fixture.expectNoLeftovers();
}

test "small table warning boundary and missing target stats ignore unrelated ANALYZE" {
    for ([_]usize{ 999, 1000 }) |rows| {
        var buffer: [1024]u8 = undefined;
        const schema = try std.fmt.bufPrintSentinel(&buffer, "CREATE TABLE t(a INTEGER); CREATE TABLE unrelated(a INTEGER); INSERT INTO unrelated VALUES (1); ANALYZE unrelated; WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<{d}) INSERT INTO t SELECT x FROM c;", .{rows}, 0);
        var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)", schema);
        defer fixture.deinit();
        var output: [32768]u8 = undefined;
        var errors: [1024]u8 = undefined;
        const result = fixture.runFormat("json", &.{ "--runs", "0" }, &output, &errors);
        try testing.expectEqual(ExitCode.ok, result.code);
        var parsed = try parseJson(result.stdout);
        defer parsed.deinit();
        const warnings = try jsonItems(parsed.value, "warnings");
        try testing.expectEqual(@as(usize, if (rows == 999) 2 else 1), warnings.len);
        try testing.expectEqualStrings("no_analyze_stats", try jsonText(warnings[0], "code"));
        try testing.expectEqualStrings("improved", try jsonText(parsed.value, "verdict"));
    }
}

test "analyzed large quoted target emits no warnings and long index names remain accepted" {
    const schema =
        \\CREATE TABLE "odd""table"(a INTEGER PRIMARY KEY) WITHOUT ROWID;
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000) INSERT INTO "odd""table" SELECT x FROM c;
        \\ANALYZE;
    ;
    const name: [300]u8 = @splat('i');
    var sql_buffer: [512]u8 = undefined;
    const index_sql = try std.fmt.bufPrint(&sql_buffer, "CREATE INDEX {s} ON \"odd\"\"table\"(a)", .{name});
    var fixture = try CliFixture.initWithSchema("SELECT a FROM \"odd\"\"table\" WHERE a=1", index_sql, schema);
    defer fixture.deinit();
    var output: [32768]u8 = undefined;
    var errors: [1024]u8 = undefined;
    const result = fixture.runFormat("json", &.{ "--runs", "0" }, &output, &errors);
    try testing.expectEqual(ExitCode.ok, result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(parsed.value, "warnings")).len);
    try testing.expectEqualStrings("match", try jsonText(parsed.value, "result"));
    try fixture.expectNoLeftovers();
}

const migration_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2000)
    \\INSERT INTO t SELECT x, 'v' || x FROM c;
    \\CREATE INDEX idx_a ON t(a);
    \\ANALYZE;
;

fn initMigrationFixture() !CliFixture {
    var fixture = try CliFixture.initWithSchema("SELECT b FROM t WHERE a = ?1", "CREATE INDEX unused ON t(a)", migration_schema);
    errdefer fixture.deinit();
    try fixture.writeFile("q.sql", "SELECT b FROM t WHERE a = ?1;");
    try fixture.writeFile("qb.sql", "SELECT a FROM t WHERE b = ?1;");
    try fixture.writeFile("queries.json", "{\"queries\":[{\"select\":\"q.sql\",\"binds\":[\"1:int:1234\"]}]}");
    try fixture.writeFile("queries_b.json", "{\"queries\":[{\"select\":\"qb.sql\",\"binds\":[\"1:text:v1234\"]}]}");
    try fixture.writeFile("replace.sql", "DROP INDEX idx_a;\nCREATE INDEX idx_ab ON t(a, b);\n");
    try fixture.writeFile("replace_same.sql", "DROP INDEX idx_a;\nCREATE UNIQUE INDEX idx_a ON t(a, b);\n");
    try fixture.writeFile("create.sql", "CREATE INDEX idx_b ON t(b);\n");
    try fixture.writeFile("drop.sql", "DROP INDEX idx_a;\n");
    try fixture.writeFile("data.sql", "DELETE FROM t;\n");
    try fixture.writeFile("missing.sql", "DROP INDEX missing_idx;\n");
    try fixture.writeFile("empty.sql", "-- nothing\n");
    return fixture;
}

fn runMigration(
    fixture: *CliFixture,
    manifest_name: []const u8,
    migration_name: []const u8,
    extra: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) !RunResult {
    const manifest = try fixture.dir.tmp.dir.realPathFileAlloc(testing.io, manifest_name, testing.allocator);
    defer testing.allocator.free(manifest);
    const migration = try fixture.dir.tmp.dir.realPathFileAlloc(testing.io, migration_name, testing.allocator);
    defer testing.allocator.free(migration);
    var argv: [32][:0]const u8 = undefined;
    const required = [_][:0]const u8{ "Qenome", "--db", fixture.db_path, "--batch", manifest, "--migration", migration };
    @memcpy(argv[0..required.len], &required);
    @memcpy(argv[required.len..][0..extra.len], extra);
    return callRun(testing.allocator, argv[0 .. required.len + extra.len], fixture.work_parent, stdout_buffer, stderr_buffer);
}

fn queryInt64(database: *db.Db, sql: [:0]const u8) !i64 {
    const statement = try database.prepareSelect(sql);
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_step(statement) != sqlite.SQLITE_ROW) return error.TestUnexpectedResult;
    return sqlite.sqlite3_column_int64(statement, 0);
}

test "a migration replaces an index and reports every statement" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();
    const before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "replace.sql", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "batch: 1 query, 1 migration (2 statements)\n"));
    try testing.expect(contains(result.stdout, "migration: "));
    try testing.expect(contains(result.stdout, "  1: DROP INDEX idx_a\n"));
    try testing.expect(contains(result.stdout, "  2: CREATE INDEX idx_ab ON t(a, b)\n"));
    try testing.expect(contains(result.stdout, "replace.sql  compared"));
    try testing.expect(contains(result.stdout, "match         no-effect"));
    try fixture.expectNoLeftovers();

    const after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);

    var source: db.Db = .{};
    try source.openReadOnly(fixture.db_path);
    defer source.close() catch unreachable;
    try testing.expectEqual(@as(i64, 1), try queryInt64(&source, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_a'"));
    try testing.expectEqual(@as(i64, 0), try queryInt64(&source, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_ab'"));
}

test "a migration may drop and recreate the same index name" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "replace_same.sql", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "  1: DROP INDEX idx_a\n"));
    try testing.expect(contains(result.stdout, "  2: CREATE UNIQUE INDEX idx_a ON t(a, b)\n"));
    try testing.expect(contains(result.stdout, "replace_same.sql  compared"));
    try fixture.expectNoLeftovers();
}

test "a migration that creates an index can be recommended" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries_b.json", "create.sql", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 0), try jsonInt(parsed.value, "exit_code"));
    try testing.expect(contains(try jsonText(parsed.value, "recommended"), "create.sql"));
    const migration = try jsonGet(parsed.value, "migration");
    try testing.expect(contains(try jsonText(migration, "path"), "create.sql"));
    const statements = try jsonItems(migration, "statements");
    try testing.expectEqual(@as(usize, 1), statements.len);
    try testing.expectEqualStrings("create_index", try jsonText(statements[0], "kind"));
    try testing.expectEqualStrings("CREATE INDEX idx_b ON t(b)", try jsonText(statements[0], "sql"));
    const summary = try jsonItems(parsed.value, "summary");
    try testing.expectEqualStrings("migration", try jsonText(summary[0], "source"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "improved"));
    const results = try jsonItems(parsed.value, "results");
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("improved", try jsonText(comparison, "verdict"));
    try fixture.expectNoLeftovers();
}

test "a migration that drops a useful index exits 6" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "drop.sql", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.regression, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 6), try jsonInt(parsed.value, "exit_code"));
    const summary = try jsonItems(parsed.value, "summary");
    try testing.expectEqualStrings("migration", try jsonText(summary[0], "source"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "needs_check"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "improved"));
    const results = try jsonItems(parsed.value, "results");
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("regressed", try jsonText(comparison, "verdict"));
    try fixture.expectNoLeftovers();
}

test "a migration that drops an index reports the freed bytes as a negative size" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const human = try runMigration(&fixture, "queries.json", "drop.sql", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.regression, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(contains(human.stdout, "match         regressed"));
    try testing.expect(!contains(human.stdout, "needs-check"));

    var summary_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, human.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "drop.sql") == null) continue;
        if (std.mem.indexOf(u8, line, "compared") == null) continue;
        summary_line = line;
    }
    try testing.expect(summary_line != null);
    const size_at = std.mem.indexOf(u8, summary_line.?, " -") orelse return error.TestUnexpectedResult;
    try testing.expect(size_at + 2 < summary_line.?.len);
    try testing.expect(std.ascii.isDigit(summary_line.?[size_at + 2]));

    var stdout_json: [65536]u8 = undefined;
    var stderr_json: [2048]u8 = undefined;
    const json = try runMigration(&fixture, "queries.json", "drop.sql", &.{ "--format", "json" }, &stdout_json, &stderr_json);
    try testing.expectEqual(ExitCode.regression, json.code);
    try testing.expectEqualStrings("", json.stderr);

    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const summary = try jsonItems(parsed.value, "summary");
    const increase = try jsonInt(summary[0], "size_increase");
    try testing.expect(increase < 0);
    const results = try jsonItems(parsed.value, "results");
    const sizes = try jsonGet(try jsonGet(results[0], "comparison"), "size_bytes");
    try testing.expectEqual(increase, try jsonInt(sizes, "increase"));
    try testing.expect(try jsonInt(sizes, "baseline") > try jsonInt(sizes, "variant"));
    try fixture.expectNoLeftovers();
}

test "a migration rejects a data change before touching the variant" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "data.sql", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "migration_statement_rejected", 1);
    try fixture.expectNoLeftovers();
}

test "a migration that fails to apply is kept in the report" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "missing.sql", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "\nMigration failure\n"));
    try testing.expect(contains(result.stdout, "statement 1: no such index: missing_idx"));
    try fixture.expectNoLeftovers();
}

test "an empty migration is rejected with a stable error code" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "queries.json", "empty.sql", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "migration_empty", 1);
    try fixture.expectNoLeftovers();
}

test "a migration manifest must not name candidates" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();
    try fixture.writeFile("with_candidates.json",
        \\{"queries":[{"select":"q.sql","binds":["1:int:1234"]}],"candidates":[{"index_sql":"create.sql"}]}
    );

    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runMigration(&fixture, "with_candidates.json", "create.sql", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "candidates must be omitted or empty with --migration"));
    try fixture.expectNoLeftovers();
}

test "--migration without --batch is a usage error" {
    var fixture = try initMigrationFixture();
    defer fixture.deinit();
    const migration = try fixture.dir.tmp.dir.realPathFileAlloc(testing.io, "replace.sql", testing.allocator);
    defer testing.allocator.free(migration);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--db", fixture.db_path, "--select", fixture.select_path, "--migration", migration }, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "--migration needs --batch"));
    try fixture.expectNoLeftovers();
}

const batch_happy_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
;

fn initBatchHappy() !CliFixture {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    errdefer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT a FROM t WHERE b = ?1;");
    try fixture.writeFile("q2.sql", "SELECT count(*) FROM t WHERE b = 'x';");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("c2.sql", "CREATE INDEX ix_a ON t(a);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]},{"select":"q2.sql"}],
        \\ "candidates":[{"index_sql":"c1.sql"},{"index_sql":"c2.sql"}]}
    );
    return fixture;
}

test "a batch compares every query with every candidate and recommends one" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "batch: 2 queries, 2 candidates\n"));
    try testing.expect(contains(result.stdout, "Recommendation: c1.sql\n"));
    try testing.expect(contains(result.stdout, "\nResults\n"));
    try testing.expect(contains(result.stdout, "q1.sql"));
    try testing.expect(contains(result.stdout, "q2.sql"));
    try testing.expect(contains(result.stdout, "c1.sql"));
    try testing.expect(contains(result.stdout, "c2.sql"));
    try fixture.expectNoLeftovers();
}

test "a batch json report carries the batch contract and embeds the comparisons" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "batch_schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("c1.sql", try jsonText(root, "recommended"));

    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 2), summary.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("compared", try jsonText(summary[0], "status"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(summary[0], "improved"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "no_effect"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "timeout"));
    try testing.expect((try jsonGet(summary[0], "failure")) == .null);
    try testing.expect(try jsonInt(summary[0], "size_increase") >= 0);
    try testing.expectEqualStrings("c2.sql", try jsonText(summary[1], "candidate"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[1], "improved"));
    try testing.expectEqual(@as(i64, 2), try jsonInt(summary[1], "no_effect"));

    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 4), results.len);
    try testing.expectEqualStrings("q1.sql", try jsonText(results[0], "query"));
    try testing.expectEqualStrings("c1.sql", try jsonText(results[0], "candidate"));
    try testing.expectEqualStrings("q2.sql", try jsonText(results[1], "query"));
    try testing.expectEqualStrings("c1.sql", try jsonText(results[1], "candidate"));
    try testing.expectEqualStrings("q1.sql", try jsonText(results[2], "query"));
    try testing.expectEqualStrings("c2.sql", try jsonText(results[2], "candidate"));
    try testing.expectEqualStrings("q2.sql", try jsonText(results[3], "query"));
    try testing.expectEqualStrings("c2.sql", try jsonText(results[3], "candidate"));

    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqual(@as(i64, 2), try jsonInt(comparison, "schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(comparison, "exit_code"));
    try testing.expectEqualStrings("improved", try jsonText(comparison, "verdict"));
    const inputs = try jsonGet(comparison, "inputs");
    try testing.expectEqualStrings("q1.sql", try jsonText(inputs, "select"));
    try testing.expectEqualStrings("c1.sql", try jsonText(inputs, "index_sql"));
    const measurement = try jsonGet(comparison, "measurement");
    try testing.expectEqual(@as(i64, 0), try jsonInt(measurement, "runs_per_copy"));
    try fixture.expectNoLeftovers();
}

test "a rejected candidate is recorded and the batch continues" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y'), (2, 'z');
    );
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT a FROM t WHERE b = 'x';");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("cu.sql", "CREATE UNIQUE INDEX u_a ON t(a);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"},{"index_sql":"cu.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("c1.sql", try jsonText(root, "recommended"));

    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 2), summary.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("index_rejected", try jsonText(summary[1], "status"));
    const failure = try jsonGet(summary[1], "failure");
    try testing.expectEqualStrings("index_rejected", try jsonText(failure, "code"));
    try testing.expect(contains(try jsonText(failure, "message"), "UNIQUE constraint failed"));
    try testing.expect((try jsonGet(summary[1], "improved")) == .null);
    try testing.expect((try jsonGet(summary[1], "size_increase")) == .null);

    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(results[0], "candidate"));
    try fixture.expectNoLeftovers();
}

test "a mismatch outranks a rejected candidate in the batch exit code" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT a, b FROM t GROUP BY a;");
    try fixture.writeFile("c1.sql", "CREATE INDEX idx_ab ON t(a, b DESC);");
    try fixture.writeFile("cu.sql", "CREATE UNIQUE INDEX u_a ON t(a);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"},{"index_sql":"cu.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 3), try jsonInt(root, "exit_code"));
    try testing.expect((try jsonGet(root, "recommended")) == .null);
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "mismatch"));
    try testing.expectEqualStrings("index_rejected", try jsonText(summary[1], "status"));
    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 1), results.len);
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("mismatch", try jsonText(comparison, "result"));
    try fixture.expectNoLeftovers();
}

test "a batch whose only compared result is incomparable exits 4" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT a FROM t ORDER BY random() LIMIT 1;");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 4), try jsonInt(root, "exit_code"));
    try testing.expect((try jsonGet(root, "recommended")) == .null);
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "incomparable"));
    const results = try jsonItems(root, "results");
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("incomparable", try jsonText(comparison, "result"));
    try fixture.expectNoLeftovers();
}

fn expectBatchManifestError(fixture: *CliFixture, manifest: []const u8, expected: []const u8) !void {
    try fixture.writeFile("batch.json", manifest);
    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "batch_manifest_invalid", 1);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const failure = try jsonGet(parsed.value, "error");
    try testing.expect(contains(try jsonText(failure, "message"), expected));
}

test "a batch manifest with the wrong shape is rejected" {
    var fixture = try CliFixture.init("SELECT 1", "CREATE INDEX i ON t(a)");
    defer fixture.deinit();

    try expectBatchManifestError(&fixture, "{\"queries\":[],\"candidates\":[]}", "queries must hold 1 to 100 entries");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\"}],\"candidates\":[]}", "candidates must hold 1 to 100 entries");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\"}],\"candidates\":[{\"index_sql\":\"c1.sql\"}],\"extra\":1}", "exactly the keys queries and candidates");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\",\"extra\":1}],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}", "must have select and optional binds");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\"},{\"select\":\"q1.sql\"}],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}", "appears more than once");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\"}],\"candidates\":[{\"index_sql\":\"c1.sql\"},{\"index_sql\":\"c1.sql\"}]}", "appears more than once");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\",\"binds\":[\"1\"]}],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}", "--bind expects");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\",\"binds\":[\"1:text:a\\u0000b\"]}],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}", "contains a NUL byte");
    try expectBatchManifestError(&fixture, "{", "not valid JSON");
    try expectBatchManifestError(&fixture, "{\"queries\":[{\"select\":\"q1.sql\x00\"}],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}", "contains a NUL byte");
}

test "a batch manifest over 100 entries is rejected" {
    var fixture = try CliFixture.init("SELECT 1", "CREATE INDEX i ON t(a)");
    defer fixture.deinit();

    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("{\"queries\":[");
    for (0..101) |index| {
        if (index != 0) try text.writer.writeByte(',');
        try text.writer.print("{{\"select\":\"q{d}.sql\"}}", .{index});
    }
    try text.writer.writeAll("],\"candidates\":[{\"index_sql\":\"c1.sql\"}]}");
    try expectBatchManifestError(&fixture, text.written(), "queries must hold 1 to 100 entries");
}

test "a missing batch SQL file stops with an empty stdout" {
    var fixture = try CliFixture.init("SELECT 1", "CREATE INDEX i ON t(a)");
    defer fixture.deinit();
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "batch_sql_unreadable", 1);
    try fixture.expectNoLeftovers();
}

test "a batch preflight rejects a swapped SELECT and candidate before running" {
    var fixture = try CliFixture.init("SELECT 1", "CREATE INDEX i ON t(a)");
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "batch_baseline_failed", 1);
    try testing.expect(contains(result.stderr, "the batch query 'q1.sql'"));

    try fixture.writeFile("q1.sql", "SELECT a FROM t;");
    try fixture.writeFile("c1.sql", "SELECT a FROM t;");
    const second = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, second.code);
    try testing.expectEqualStrings("", second.stdout);
    try expectJsonFailure(second.stderr, "batch_index_failed", 1);
    try testing.expect(contains(second.stderr, "the batch candidate 'c1.sql'"));
    try fixture.expectNoLeftovers();
}

test "a batch baseline timeout stops before the candidate loop" {
    var fixture = try CliFixture.init("SELECT 1", "CREATE INDEX i ON t(a)");
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json", "--timeout-ms", "1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.timeout, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "batch_baseline_timeout", 124);
    try fixture.expectNoLeftovers();
}

test "a batch index timeout is recorded without results and keeps stderr empty" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
    );
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT 1;");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json", "--timeout-ms", "1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.timeout, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "batch_schema_version"));
    try testing.expectEqual(@as(i64, 124), try jsonInt(root, "exit_code"));
    try testing.expect((try jsonGet(root, "recommended")) == .null);
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 1), summary.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("index_timeout", try jsonText(summary[0], "status"));
    const failure = try jsonGet(summary[0], "failure");
    try testing.expectEqualStrings("index_timeout", try jsonText(failure, "code"));
    try testing.expect((try jsonText(failure, "message")).len != 0);
    try testing.expect((try jsonGet(summary[0], "improved")) == .null);
    try testing.expect((try jsonGet(summary[0], "size_increase")) == .null);
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "results")).len);
    try fixture.expectNoLeftovers();
}

test "a batch variant timeout keeps the other queries of the candidate" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b INTEGER, c TEXT);
        \\WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 5000)
        \\INSERT INTO t SELECT x, x % 2, 'v' || x FROM n;
    );
    defer fixture.deinit();
    try fixture.writeFile("heavy.sql", "SELECT a FROM t WHERE b >= 1 AND length(hex(zeroblob(1000000 + (a > 0)))) > 0 ORDER BY a LIMIT 1;");
    try fixture.writeFile("light.sql", "SELECT count(*) FROM t WHERE a = 1;");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"heavy.sql"},{"select":"light.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json", "--timeout-ms", "500" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.timeout, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 124), try jsonInt(root, "exit_code"));
    try testing.expect((try jsonGet(root, "recommended")) == .null);
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 1), summary.len);
    try testing.expectEqualStrings("compared", try jsonText(summary[0], "status"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "improved"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "no_effect"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "needs_check"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(summary[0], "mismatch"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(summary[0], "timeout"));

    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("heavy.sql", try jsonText(results[0], "query"));
    try testing.expectEqualStrings("variant_timeout", try jsonText(results[0], "status"));
    try testing.expect((try jsonGet(results[0], "comparison")) == .null);
    try testing.expectEqualStrings("light.sql", try jsonText(results[1], "query"));
    try testing.expectEqualStrings("compared", try jsonText(results[1], "status"));
    const comparison = try jsonGet(results[1], "comparison");
    try testing.expectEqualStrings("match", try jsonText(comparison, "result"));
    try fixture.expectNoLeftovers();
}

test "a rejected first candidate leaves a clean variant for the next candidate" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y'), (2, 'z');
    );
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT a FROM t WHERE b = 'x';");
    try fixture.writeFile("cu.sql", "CREATE UNIQUE INDEX u_a ON t(a);");
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"cu.sql"},{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("c1.sql", try jsonText(root, "recommended"));
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 2), summary.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("compared", try jsonText(summary[0], "status"));
    try testing.expectEqualStrings("cu.sql", try jsonText(summary[1], "candidate"));
    try testing.expectEqualStrings("index_rejected", try jsonText(summary[1], "status"));

    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("q1.sql", try jsonText(results[0], "query"));
    try testing.expectEqualStrings("c1.sql", try jsonText(results[0], "candidate"));
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("match", try jsonText(comparison, "result"));
    try testing.expectEqualStrings("improved", try jsonText(comparison, "verdict"));
    try fixture.expectNoLeftovers();
}

const baseline_order_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b INTEGER, c INTEGER);
    \\INSERT INTO t VALUES (1, 3, 0), (2, 2, 0), (3, 1, 0);
;

test "a cached baseline keeps the original row order for later candidates" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)", baseline_order_schema);
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT b, a FROM t WHERE b > 0;");
    try fixture.writeFile("cb1.sql", "CREATE INDEX ix_b ON t(b);");
    try fixture.writeFile("cb2.sql", "CREATE INDEX ix_b2 ON t(b);");
    try fixture.writeFile("cu.sql", "CREATE INDEX ix_c ON t(c);");
    try fixture.writeFile("batch-order.json",
        \\{"queries":[{"select":"q1.sql"}],
        \\ "candidates":[{"index_sql":"cb1.sql"},{"index_sql":"cb2.sql"},{"index_sql":"cu.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runBatchNamed(&fixture, "batch-order.json", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const results = try jsonItems(parsed.value, "results");
    try testing.expectEqual(@as(usize, 3), results.len);
    const expected = [_][]const u8{ "differs", "differs", "same" };
    for (results, expected) |entry, order| {
        const comparison = try jsonGet(entry, "comparison");
        try testing.expectEqualStrings("match", try jsonText(comparison, "result"));
        try testing.expectEqualStrings(order, try jsonText(comparison, "row_order"));
    }
    try fixture.expectNoLeftovers();
}

test "a batch measures each baseline once whatever the number of candidates" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();
    try fixture.writeFile("c3.sql", "CREATE INDEX ix_ab ON t(a, b);");
    try fixture.writeFile("c4.sql", "CREATE INDEX ix_ba ON t(b, a);");
    try fixture.writeFile("c5.sql", "CREATE INDEX ix_ab2 ON t(a, b);");
    try fixture.writeFile("batch-one.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]},{"select":"q2.sql"}],
        \\ "candidates":[{"index_sql":"c1.sql"}]}
    );
    try fixture.writeFile("batch-five.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]},{"select":"q2.sql"}],
        \\ "candidates":[{"index_sql":"c1.sql"},{"index_sql":"c2.sql"},{"index_sql":"c3.sql"},
        \\   {"index_sql":"c4.sql"},{"index_sql":"c5.sql"}]}
    );

    var one_stdout: [131072]u8 = undefined;
    var one_stderr: [2048]u8 = undefined;
    _ = cli_batch.takeTestBaselineSelects();
    const one = try runBatchNamed(&fixture, "batch-one.json", &.{ "--format", "json" }, &one_stdout, &one_stderr);
    try testing.expectEqual(ExitCode.ok, one.code);
    try testing.expectEqualStrings("", one.stderr);
    try testing.expectEqual(@as(usize, 2), cli_batch.takeTestBaselineSelects());

    var five_stdout: [262144]u8 = undefined;
    var five_stderr: [2048]u8 = undefined;
    const five = try runBatchNamed(&fixture, "batch-five.json", &.{ "--format", "json" }, &five_stdout, &five_stderr);
    try testing.expectEqual(ExitCode.ok, five.code);
    try testing.expectEqualStrings("", five.stderr);
    try testing.expectEqual(@as(usize, 2), cli_batch.takeTestBaselineSelects());
    try fixture.expectNoLeftovers();
}

test "a batch without the baseline cache gives the same report" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();

    var cached_stdout: [131072]u8 = undefined;
    var cached_stderr: [2048]u8 = undefined;
    _ = cli_batch.takeTestBaselineSelects();
    const cached = try fixture.runBatch(&.{ "--format", "json" }, &cached_stdout, &cached_stderr);
    try testing.expectEqual(@as(usize, 2), cli_batch.takeTestBaselineSelects());

    cli_batch.setTestCacheLimit(0);
    defer cli_batch.setTestCacheLimit(null);
    var uncached_stdout: [131072]u8 = undefined;
    var uncached_stderr: [2048]u8 = undefined;
    const uncached = try fixture.runBatch(&.{ "--format", "json" }, &uncached_stdout, &uncached_stderr);
    try testing.expectEqual(@as(usize, 6), cli_batch.takeTestBaselineSelects());

    try testing.expectEqual(cached.code, uncached.code);
    try testing.expectEqualStrings(cached.stdout, uncached.stdout);
    try testing.expectEqualStrings(cached.stderr, uncached.stderr);
    try fixture.expectNoLeftovers();
}

test "a batch runs every baseline before the candidate loop even when the cache is full" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();
    try fixture.writeFile("q1.sql", "SELECT 1;");
    try fixture.writeFile("q2.sql", "SELECT abs(-9223372036854775808);");
    try fixture.writeFile("cu.sql", "CREATE UNIQUE INDEX u_a ON t(a);");
    try fixture.writeFile("batch-fail.json",
        \\{"queries":[{"select":"q1.sql"},{"select":"q2.sql"}],"candidates":[{"index_sql":"cu.sql"}]}
    );

    cli_batch.setTestCacheLimit(0);
    defer cli_batch.setTestCacheLimit(null);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try runBatchNamed(&fixture, "batch-fail.json", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "the batch baseline SELECT for query 'q2.sql' failed"));
    try fixture.expectNoLeftovers();
}

test "a cached baseline keeps the shared row budget boundary" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();
    try fixture.writeFile("q1.sql",
        \\WITH RECURSIVE n(x) AS (VALUES (1) UNION ALL SELECT x + 1 FROM n WHERE x < 30)
        \\SELECT zeroblob(2000000) FROM n;
    );
    try fixture.writeFile("c1.sql", "CREATE INDEX ix_a ON t(a);");
    try fixture.writeFile("c2.sql", "CREATE INDEX ix_a2 ON t(a);");
    try fixture.writeFile("batch-budget.json",
        \\{"queries":[{"select":"q1.sql"}],"candidates":[{"index_sql":"c1.sql"},{"index_sql":"c2.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runBatchNamed(&fixture, "batch-budget.json", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 4), try jsonInt(root, "exit_code"));
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 2), summary.len);
    for (summary) |entry| {
        try testing.expectEqual(@as(i64, 1), try jsonInt(entry, "incomparable"));
    }
    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |entry| {
        const comparison = try jsonGet(entry, "comparison");
        try testing.expectEqualStrings("incomparable", try jsonText(comparison, "result"));
        const reasons = try jsonItems(comparison, "result_reasons");
        try testing.expectEqual(@as(usize, 1), reasons.len);
        try testing.expect(contains(try jsonText(reasons[0], "text"), "the result rows exceed the 64 MiB"));
    }
    try fixture.expectNoLeftovers();
}

fn runBatchNamed(fixture: *CliFixture, name: []const u8, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) !RunResult {
    const manifest = try fixture.dir.tmp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    defer testing.allocator.free(manifest);
    return fixture.runBatchPath(manifest, extra, stdout_buffer, stderr_buffer);
}

fn runSuggest(fixture: *CliFixture, format: [:0]const u8, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
    var argv: [16][:0]const u8 = undefined;
    const required = [_][:0]const u8{ "Qenome", "--db", fixture.db_path, "--select", fixture.select_path, "--suggest", "--format", format };
    @memcpy(argv[0..required.len], &required);
    @memcpy(argv[required.len..][0..extra.len], extra);
    return callRun(testing.allocator, argv[0 .. required.len + extra.len], fixture.work_parent, stdout_buffer, stderr_buffer);
}

test "a one-SELECT --suggest compares what SQLite proposes with the binds" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE b = ?1;", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = runSuggest(&fixture, "json", &.{ "--bind", "1:text:x" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "batch_schema_version"));
    try testing.expectEqualStrings("suggested:1", try jsonText(root, "recommended"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "warnings")).len);

    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 1), summary.len);
    try testing.expectEqualStrings("suggested:1", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("suggested", try jsonText(summary[0], "source"));
    const index_sql = try jsonText(summary[0], "index_sql_text");
    try testing.expect(contains(index_sql, "CREATE INDEX"));
    try testing.expect(contains(index_sql, "t("));
    try testing.expect(!contains(index_sql, "stat1"));

    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings(fixture.select_path, try jsonText(results[0], "query"));
    const comparison = try jsonGet(results[0], "comparison");
    try testing.expectEqualStrings("improved", try jsonText(comparison, "verdict"));
    try testing.expectEqualStrings(fixture.select_path, try jsonText(try jsonGet(comparison, "inputs"), "select"));
    try testing.expectEqualStrings("suggested:1", try jsonText(try jsonGet(comparison, "inputs"), "index_sql"));
    try fixture.expectNoLeftovers();
}

test "a one-SELECT --suggest marks the proposal in human output" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE b = ?1;", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = runSuggest(&fixture, "human", &.{ "--bind", "1:text:x" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(contains(result.stdout, "\nSuggested by SQLite:\n  suggested:1: CREATE INDEX "));
    try testing.expect(contains(result.stdout, ";\n"));
    try testing.expect(contains(result.stdout, "\nRecommendation: suggested:1\n"));
    try testing.expect(!contains(result.stdout, "warning:"));
    try fixture.expectNoLeftovers();
}

test "--suggest with nothing to compare stops with no_candidates" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(&fixture, "json", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "no_candidates", 1);
    try testing.expect(contains(result.stderr, "without --suggest"));
    try fixture.expectNoLeftovers();
}

test "--suggest with no proposal keeps the manifest candidates" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();
    try fixture.writeFile("q3.sql", "SELECT 1;");
    try fixture.writeFile("batch-suggest.json",
        \\{"queries":[{"select":"q3.sql"}],"candidates":[{"index_sql":"c1.sql"}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try runBatchNamed(&fixture, "batch-suggest.json", &.{ "--suggest", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expect(try jsonGet(root, "recommended") == .null);
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 1), summary.len);
    try testing.expectEqualStrings("c1.sql", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("manifest", try jsonText(summary[0], "source"));
    try testing.expectEqualStrings("CREATE INDEX ix_b ON t(b);", try jsonText(summary[0], "index_sql_text"));
    const warnings = try jsonItems(root, "warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings("no_suggestions", try jsonText(warnings[0], "code"));
    try fixture.expectNoLeftovers();
}

test "--suggest may omit the manifest candidates and adds its proposal last" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();
    try fixture.writeFile("batch-two.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]}],"candidates":[{"index_sql":"c2.sql"}]}
    );
    try fixture.writeFile("batch-none.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]}]}
    );

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const with_manifest = try runBatchNamed(&fixture, "batch-two.json", &.{ "--suggest", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, with_manifest.code);
    var parsed = try parseJson(with_manifest.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqualStrings("suggested:1", try jsonText(root, "recommended"));
    const summary = try jsonItems(root, "summary");
    try testing.expectEqual(@as(usize, 2), summary.len);
    try testing.expectEqualStrings("suggested:1", try jsonText(summary[0], "candidate"));
    try testing.expectEqualStrings("c2.sql", try jsonText(summary[1], "candidate"));
    try testing.expectEqualStrings("manifest", try jsonText(summary[1], "source"));
    try testing.expectEqualStrings("CREATE INDEX ix_a ON t(a);", try jsonText(summary[1], "index_sql_text"));
    const results = try jsonItems(root, "results");
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("c2.sql", try jsonText(results[0], "candidate"));
    try testing.expectEqualStrings("suggested:1", try jsonText(results[1], "candidate"));
    try testing.expectEqual(@as(usize, 0), (try jsonItems(root, "warnings")).len);

    stdout_buffer = undefined;
    stderr_buffer = undefined;
    const without_manifest = try runBatchNamed(&fixture, "batch-none.json", &.{ "--suggest", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, without_manifest.code);
    var second = try parseJson(without_manifest.stdout);
    defer second.deinit();
    try testing.expectEqualStrings("suggested:1", try jsonText(second.value, "recommended"));
    try testing.expectEqual(@as(usize, 1), (try jsonItems(second.value, "summary")).len);
    try fixture.expectNoLeftovers();
}

test "--suggest rejects a manifest candidate named suggested and only then" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();
    try fixture.writeFile("batch-bad.json",
        \\{"queries":[{"select":"q1.sql","binds":["1:text:x"]}],"candidates":[{"index_sql":"suggested:1"}]}
    );

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const with_suggest = try runBatchNamed(&fixture, "batch-bad.json", &.{ "--suggest", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, with_suggest.code);
    try testing.expectEqualStrings("", with_suggest.stdout);
    try expectJsonFailure(with_suggest.stderr, "batch_manifest_invalid", 1);
    try testing.expect(contains(with_suggest.stderr, "must not start with 'suggested:'"));

    stdout_buffer = undefined;
    stderr_buffer = undefined;
    const without_suggest = try runBatchNamed(&fixture, "batch-bad.json", &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, without_suggest.code);
    try expectJsonFailure(without_suggest.stderr, "batch_sql_unreadable", 1);
    try fixture.expectNoLeftovers();
}

fn victimPath(fixture: *CliFixture, name: []const u8) ![:0]const u8 {
    try fixture.writeFile("anchor", "");
    const anchor = try fixture.dir.tmp.dir.realPathFileAlloc(testing.io, "anchor", testing.allocator);
    defer testing.allocator.free(anchor);
    const directory = std.fs.path.dirname(anchor) orelse ".";
    return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ directory, name }, 0);
}

fn rewriteSchemaRow(fixture: *CliFixture, payload: []const u8) !void {
    const update = try std.fmt.allocPrintSentinel(testing.allocator, "PRAGMA writable_schema=ON; UPDATE sqlite_schema SET sql = 'CREATE TABLE t(a); {s}' WHERE name = 't';", .{payload}, 0);
    defer testing.allocator.free(update);
    const writer = try db.openTestWriter(fixture.db_path, update);
    _ = sqlite.sqlite3_close(writer);
}

fn expectNoFile(path: []const u8) !void {
    _ = Io.Dir.cwd().statFile(testing.io, path, .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.ExpectedMissingFile;
}

fn expectSchemaRejected(fixture: *CliFixture, victim: ?[]const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(fixture, "json", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "suggest_schema_rejected", 1);
    try testing.expect(contains(result.stderr, "the schema entry is not allowed"));
    if (victim) |path| try expectNoFile(path);
    try fixture.expectNoLeftovers();
}

test "--suggest rejects a schema that attaches another database" {
    var fixture = try CliFixture.initWithSchema("SELECT * FROM t WHERE a = 1", "CREATE INDEX unused ON t(a)", "CREATE TABLE t(a); INSERT INTO t VALUES (1);");
    defer fixture.deinit();
    const victim = try victimPath(&fixture, "attached.db");
    defer testing.allocator.free(victim);
    try expectNoFile(victim);
    const payload = try std.fmt.allocPrintSentinel(testing.allocator, "ATTACH DATABASE ''{s}'' AS v;", .{victim}, 0);
    defer testing.allocator.free(payload);
    try rewriteSchemaRow(&fixture, payload);

    try expectSchemaRejected(&fixture, victim);
}

test "--suggest rejects a schema that runs VACUUM INTO" {
    var fixture = try CliFixture.initWithSchema("SELECT * FROM t WHERE a = 1", "CREATE INDEX unused ON t(a)", "CREATE TABLE t(a); INSERT INTO t VALUES (1);");
    defer fixture.deinit();
    const victim = try victimPath(&fixture, "vacuum.db");
    defer testing.allocator.free(victim);
    try expectNoFile(victim);
    const payload = try std.fmt.allocPrintSentinel(testing.allocator, "VACUUM INTO ''{s}'';", .{victim}, 0);
    defer testing.allocator.free(payload);
    try rewriteSchemaRow(&fixture, payload);

    try expectSchemaRejected(&fixture, victim);
}

test "--suggest rejects a schema that sets a PRAGMA" {
    var fixture = try CliFixture.initWithSchema("SELECT * FROM t WHERE a = 1", "CREATE INDEX unused ON t(a)", "CREATE TABLE t(a); INSERT INTO t VALUES (1);");
    defer fixture.deinit();
    try rewriteSchemaRow(&fixture, "PRAGMA temp_store_directory=''.'';");

    try expectSchemaRejected(&fixture, null);
}

test "--suggest accepts a normal schema with a trigger, a view and quoted names" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE \"x;y\" = 'v'", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER, "x;y" TEXT);
        \\CREATE VIEW v AS SELECT a FROM t;
        \\CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = a; END;
        \\CREATE INDEX "idx;one" ON t(a);
        \\INSERT INTO t VALUES (1, 'v'), (2, 'w');
    );
    defer fixture.deinit();

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(&fixture, "json", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), try jsonInt(parsed.value, "batch_schema_version"));
    const summary = try jsonItems(parsed.value, "summary");
    try testing.expectEqual(@as(usize, 1), summary.len);
    try testing.expectEqualStrings("suggested", try jsonText(summary[0], "source"));
    try fixture.expectNoLeftovers();
}

test "--suggest accepts the D1 example schema with the local D1 tables" {
    const example = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/d1-toml/schema.sql", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(example);
    const schema = try std.fmt.allocPrintSentinel(testing.allocator, "{s}\nCREATE TABLE _cf_METADATA(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;\nCREATE TABLE _cf_KV(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;", .{example}, 0);
    defer testing.allocator.free(schema);
    var fixture = try CliFixture.initWithSchema(
        "SELECT id, status, note FROM events WHERE customer_id = ?1",
        "CREATE INDEX unused ON events(customer_id)",
        schema,
    );
    defer fixture.deinit();

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(&fixture, "json", &.{ "--bind", "1:int:1234" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try testing.expectEqualStrings("suggested:1", try jsonText(parsed.value, "recommended"));
    try fixture.expectNoLeftovers();
}

test "--suggest escapes control characters in a human warning" {
    var fixture = try CliFixture.initWithSchema("SELECT 1", "CREATE INDEX unused ON t(a)",
        \\CREATE TABLE t(a INTEGER);
        \\INSERT INTO t VALUES (1);
        \\CREATE INDEX t_a ON t(a);
        \\ANALYZE;
    );
    defer fixture.deinit();
    try fixture.writeFile("q\x1b.sql", "SELECT * FROM sqlite_stat1;");
    try fixture.writeFile("c.sql", "CREATE INDEX c ON t(a);");
    try fixture.writeFile("batch.json",
        \\{"queries":[{"select":"q\u001b.sql"}],"candidates":[{"index_sql":"c.sql"}]}
    );

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    const result = try fixture.runBatch(&.{"--suggest"}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, result.code);
    try testing.expectEqualStrings("", result.stderr);

    const at = std.mem.indexOf(u8, result.stdout, "warning: suggest_query_skipped:") orelse return error.MissingWarning;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, at, '\n') orelse result.stdout.len;
    const line = result.stdout[at..end];
    try testing.expect(contains(line, "q\\x1b.sql"));
    try testing.expect(!contains(line, "\x1b"));
    try fixture.expectNoLeftovers();
}

test "--suggest escapes control characters in a human schema error" {
    const table = "bad\x1bname";
    const schema: [:0]const u8 = "CREATE TABLE \"bad\x1bname\"(a INTEGER);\nINSERT INTO \"bad\x1bname\" VALUES (1);";
    var fixture = try CliFixture.initWithSchema(
        "SELECT * FROM \"bad\x1bname\" WHERE a = 1",
        "CREATE INDEX unused ON t(a)",
        schema,
    );
    defer fixture.deinit();
    const victim = try victimPath(&fixture, "victim.db");
    defer testing.allocator.free(victim);
    const update = try std.fmt.allocPrintSentinel(testing.allocator, "PRAGMA writable_schema=ON; UPDATE sqlite_schema SET sql = 'CREATE TABLE \"{0s}\"(a INTEGER); ATTACH DATABASE ''{1s}'' AS v;' WHERE name = '{0s}';", .{ table, victim }, 0);
    defer testing.allocator.free(update);
    const writer = try db.openTestWriter(fixture.db_path, update);
    _ = sqlite.sqlite3_close(writer);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(&fixture, "human", &.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "'bad\\x1bname'"));
    try testing.expect(!contains(result.stderr, "\x1b"));
    try expectNoFile(victim);
    try fixture.expectNoLeftovers();
}

test "--suggest keeps the manifest candidates when the expert fails" {
    var fixture = try initBatchHappy();
    defer fixture.deinit();
    cli_suggest.setTestExpertFailure("sqlite3expert could not analyze the queries: injected failure");
    defer cli_suggest.setTestExpertFailure(null);

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = try fixture.runBatch(&.{ "--suggest", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings("suggest_failed", try jsonText(warnings[0], "code"));
    try testing.expect(contains(try jsonText(warnings[0], "message"), "injected failure"));
    try testing.expectEqual(@as(usize, 2), (try jsonItems(parsed.value, "summary")).len);
    try testing.expectEqual(@as(usize, 4), (try jsonItems(parsed.value, "results")).len);
    try fixture.expectNoLeftovers();
}

test "--suggest stops when the expert fails and no candidate remains" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE b = ?1;", "CREATE INDEX unused ON t(a)", batch_happy_schema);
    defer fixture.deinit();
    cli_suggest.setTestExpertFailure("sqlite3expert could not analyze the queries: injected failure");
    defer cli_suggest.setTestExpertFailure(null);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = runSuggest(&fixture, "json", &.{ "--bind", "1:text:x" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try expectJsonFailure(result.stderr, "suggest_failed", 1);
    try testing.expect(contains(result.stderr, "injected failure"));
    try fixture.expectNoLeftovers();
}
