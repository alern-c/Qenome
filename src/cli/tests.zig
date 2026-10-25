const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");
const cli = @import("../cli.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");

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
            "error: missing: the database (a path or --db), the SELECT file (a path or --select), the CREATE INDEX file (a path or --index-sql) (see --help)\n",
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
        "time-verdict: ",
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
    try testing.expect(contains(result.stdout, "time-verdict: not-judged\ntime-verdict-reason: --runs 0 skips the timing\n"));
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
    try testing.expect(contains(result.stdout, "time-verdict: not-judged\ntime-verdict-reason: the result rows do not match, so the SELECT is not timed\n"));
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
    try testing.expect(contains(result.stdout, "time-verdict: not-judged\ntime-verdict-reason: the result rows cannot be compared, so the SELECT is not timed\n"));
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
    try testing.expect(std.mem.startsWith(u8, result.stdout, "Summary\n  result rows   match (the same rows on both copies)\n  time verdict  "));

    const in_order = [_][]const u8{
        "  query plan    changed on the variant\n",
        "  time          median ",
        "  db size       +",
        "\nBaseline vs variant           baseline         variant          change\n",
        "  rows                               1               1            same\n",
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
    for ([_][]const u8{ "Timing", "Run\n", "Result rows", "time median", "binds", "work dir", "source id", " sqlite", fixture.db_path }) |gone| {
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
        \\  time verdict  not-judged:
        \\                - the result rows do not match, so the SELECT is not timed
        \\
    ));
    try testing.expect(contains(result.stdout, "  time          not measured (0 rounds)\n"));
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
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--help" }, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "  --format <FORMAT>    human (default), kv or json\n"));
    try testing.expect(contains(result.stdout, "  --show-rows          print the example rows that only one copy"));
    try testing.expect(contains(result.stdout, "exit status:"));
    try expectNarrow(result.stdout, &.{});
}

test "help puts the usage, options, examples and exit status before the details" {
    var stdout_buffer: [8192]u8 = undefined;
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

    try testing.expectEqual(@as(i64, 1), try jsonInt(root, "schema_version"));
    try testing.expectEqual(@as(i64, 0), try jsonInt(root, "exit_code"));
    try testing.expectEqualStrings("not-judged", try jsonText(root, "verdict"));
    const verdict_reasons = try jsonItems(root, "verdict_reasons");
    try testing.expectEqual(@as(usize, 1), verdict_reasons.len);
    try testing.expectEqualStrings("--runs 0 skips the timing", verdict_reasons[0].string);
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
    try testing.expect(std.mem.startsWith(u8, result.stderr, "error: --select: "));
    try fixture.expectNoLeftovers();
}
