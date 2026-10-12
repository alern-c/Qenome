//! The tests that drive the whole CLI: arguments in, summary and exit code
//! out, on a real database, with the temporary directory of each run watched.
//!
//! This file is imported from `cli.zig`'s test block only, so a normal build
//! never compiles it.

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

/// A temporary directory that hands out absolute paths for fixture files.
const Fixture = struct {
    tmp: testing.TmpDir,

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    /// Writes `data` and returns the absolute path, owned by the tester.
    fn file(self: *Fixture, sub_path: []const u8, data: []const u8) ![:0]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
        return self.tmp.dir.realPathFileAlloc(testing.io, sub_path, testing.allocator);
    }
};

/// A database, a SELECT file, a candidate DDL file, and an empty parent for
/// the temporary directory of one CLI run.
const CliFixture = struct {
    dir: Fixture,
    db_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    /// Passed as `TMPDIR`, so a test can see what a run leaves behind.
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

    /// Runs the CLI on this fixture with `extra` arguments after the required
    /// ones.
    fn run(self: *CliFixture, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [24][:0]const u8 = undefined;
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, "--select", self.select_path, "--index-sql", self.index_path };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(testing.allocator, argv[0 .. required.len + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }

    /// Fails unless the run removed its temporary directory again.
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

/// The part of a summary that one copy reported, from its `measured-on` line
/// up to the next block, so that a check cannot match the other copy.
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

/// Calls `run` with the given output buffers and reports what it wrote.
/// `temp_parent` stands in for `TMPDIR`.
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

/// Rows stored with `a` as 3, 1, 2, 3, 1, 2, so an index on `a` hands them out
/// in another order. Summing `r` in the order of an index on `r` puts -1e16
/// and 1e16 at the ends, which changes the last digits of the sum even with
/// SQLite's compensated summation.
const reordered_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT, r REAL);
    \\INSERT INTO t VALUES (3, 'z', 0.1), (1, 'x', 0.2), (2, 'y', 0.3), (3, 'v', 1e16), (1, 'w', -1e16), (2, 'u', 0.7);
;

/// The value after `key=` on the first line that starts with `line_key: `.
fn reportValue(stdout: []const u8, line_key: []const u8, key: []const u8) !u64 {
    const line_start = std.mem.indexOf(u8, stdout, line_key) orelse return error.MissingLine;
    const line_end = std.mem.indexOfScalarPos(u8, stdout, line_start, '\n') orelse stdout.len;
    const line = stdout[line_start..line_end];
    const at = std.mem.indexOf(u8, line, key) orelse return error.MissingKey;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " /\n") orelse rest.len;
    return std.fmt.parseUnsigned(u64, rest[0..end], 10);
}

test "usage error for missing required arguments" {
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{"Qenome"}, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--db") != null);
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
    for ([_][:0]const u8{ "1001", "-1", "x", "", "4294967296" }) |raw| {
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
        try testing.expect(std.mem.indexOf(u8, result.stdout, "usage: Qenome") != null);
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
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    // Every value after `measured-on` comes from the baseline snapshot, so
    // the line sits between the inputs and `rows` (D-304).
    const expected_head = try std.fmt.allocPrint(
        testing.allocator,
        "index-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: 1\n",
        .{fixture.index_path},
    );
    defer testing.allocator.free(expected_head);
    try testing.expect(std.mem.indexOf(u8, result.stdout, expected_head) != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite: " ++ sqlite.pinned_version ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite-source-id: " ++ sqlite.pinned_source_id ++ "\n") != null);
    // The labels come before the raw detail, which ends the line.
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
    // The empty statement never reached the engine, so its placeholder message
    // must not be printed.
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
    // SQLite re-prepares this statement on the first step because the bound
    // LIKE value decides the plan; the authorizer must allow it again.
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

    // The database itself never got the index, so a second run can create
    // it again.
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
    // The rows are stored as 3, 1, 2; the index hands them out as 1, 2, 3.
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
    // `b` is not grouped, so SQLite returns it from one row of the group,
    // picked by the order it reads them in; the index reverses that order
    // (D-505).
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
    try testing.expect(contains(run_result.stdout, "result: mismatch (row multiset; the cause is not determined)\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
    try testing.expect(contains(run_result.stdout, "baseline-only-row: [1, 'x']\nvariant-only-row: [1, 'y']\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "indexed by the candidate index is rejected with exit 1" {
    const cases = [_]struct { select: []const u8, index: []const u8, expected: []const u8 }{
        .{ .select = "SELECT a FROM t INDEXED BY IDX_NEW WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "names the candidate index 'idx_new' in INDEXED BY" },
        .{ .select = "SELECT a FROM t INDEXED BY \"Idx New\" WHERE a = 1", .index = "CREATE INDEX \"Idx New\" ON t(a)", .expected = "names the candidate index 'Idx New' in INDEXED BY" },
        // Another missing index keeps the engine message.
        .{ .select = "SELECT a FROM t INDEXED BY nope WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "no such index: nope" },
        // A CTE cannot use any index; SQLite quotes the name then, so it is
        // not mistaken for the candidate.
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
    // A second row with a = 1 lives in the database before the run.
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
    // 70 rows of 1 MiB each do not fit into the 64 MiB budget.
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
    // The rows were never compared, so no one-sided rows are shown.
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
        // The one-sided rows are still shown for a mismatch that the LIMIT
        // explains.
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
        try testing.expect(contains(run_result.stdout, "incomparable-reason: the rows differ, and the SELECT calls sum(), whose result can depend on the order rows are read in\nincomparable-hint: sum() adds REAL values in the order they are read, so the results may differ only in the last digits; check the baseline-only-row and variant-only-row lines\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
    }
}

test "a date function is compared, and a difference with it exits 4 with a hint" {
    {
        // An expression index on date(...) can be tried: the rows match.
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
        // The bare column `b` differs; the date function in the SELECT makes
        // that incomparable instead of a mismatch (D-512).
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
    // The bare column `b` makes the rows differ; the SELECT also has an
    // aggregate, a LIMIT, and a WITH clause, so all three reasons apply.
    var fixture = try CliFixture.initWithSchema("WITH c AS (SELECT a, b FROM t) SELECT a, b, sum(a) FROM c GROUP BY a LIMIT 5", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    // Each reason is followed by its own hint.
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
    try testing.expect(std.mem.indexOf(u8, result.stderr, "temporary directory") != null);
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
    // The table exists only as WAL frames, so every row must come through
    // the snapshot.
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
    // The snapshot holds the same pages as the database.
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
