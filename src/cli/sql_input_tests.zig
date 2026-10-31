const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli = @import("../cli.zig");

const testing = std.testing;
const ExitCode = cli.ExitCode;

const RunResult = struct {
    code: ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn call(
    argv: []const [:0]const u8,
    stdin_text: ?[]const u8,
    temp_parent: ?[]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    var reader = Io.Reader.fixed(stdin_text orelse "");
    const context: cli.Context = .{
        .temp_parent = temp_parent,
        .stdin = if (stdin_text != null) &reader else null,
    };
    const code = cli.run(testing.io, testing.allocator, argv, context, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

const schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER);
    \\INSERT INTO t VALUES (1), (2), (3);
;

const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,
    index_path: [:0]u8,
    work_parent: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.db", .data = "" });
        const db_path = try tmp.dir.realPathFileAlloc(testing.io, "app.db", testing.allocator);
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, schema);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.sql", .data = "CREATE INDEX ix_t_a ON t(a);" });
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        return .{
            .tmp = tmp,
            .db_path = db_path,
            .index_path = try tmp.dir.realPathFileAlloc(testing.io, "index.sql", testing.allocator),
            .work_parent = try tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.index_path);
        testing.allocator.free(self.work_parent);
        self.tmp.cleanup();
    }
};

test "--sql compares one SELECT without a query file" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = call(&.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--sql",
        "SELECT a FROM t WHERE a = 1",
        "--index-sql",
        fixture.index_path,
        "--runs",
        "0",
        "--format",
        "json",
    }, null, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "\"verdict\": \"improved\""));
    try testing.expect(contains(result.stdout, "\"select\": \"--sql\""));
    try testing.expectEqualStrings("", result.stderr);
}

test "--sql with --suggest reports no index needed for a constant SELECT" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = call(&.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--sql",
        "SELECT 1",
        "--suggest",
        "--format",
        "json",
    }, null, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "\"schema_version\": 2"));
    try testing.expect(contains(result.stdout, "\"index_needed\": false"));
    try testing.expect(contains(result.stdout, "no index needed"));
    try testing.expect(contains(result.stdout, "\"rows_read\""));
    try testing.expectEqualStrings("", result.stderr);
}

test "a SELECT path of - reads the query from stdin" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = call(&.{
        "Qenome",
        fixture.db_path,
        "-",
        fixture.index_path,
        "--runs",
        "0",
        "--format",
        "json",
    }, "SELECT a FROM t WHERE a = 1\n", fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "\"select\": \"-\""));
    try testing.expectEqualStrings("", result.stderr);
}

test "--suggest from stdin reports the current plan when no index is needed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = call(&.{
        "Qenome",
        fixture.db_path,
        "-",
        "--suggest",
    }, "SELECT 1;\n", fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expect(contains(result.stdout, "no index needed\n"));
    try testing.expect(contains(result.stdout, "rows read:"));
    try testing.expect(contains(result.stdout, "plan:\n"));
    try testing.expectEqualStrings("", result.stderr);
}

test "--sql is rejected for a manifest and - is rejected for an index file" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const batch = call(&.{ "Qenome", "app.db", "--batch", "batch.json", "--sql", "SELECT 1" }, null, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, batch.code);
    try testing.expect(contains(batch.stderr, "--sql and a SELECT read from stdin"));

    const index = call(&.{ "Qenome", "app.db", "select.sql", "-" }, null, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, index.code);
    try testing.expect(contains(index.stderr, "not a path for the index"));

    const both = call(&.{ "Qenome", "app.db", "--select", "select.sql", "--sql", "SELECT 1", "index.sql" }, null, null, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.usage, both.code);
    try testing.expect(contains(both.stderr, "--sql replaces the SELECT file"));
}

test "--suggest exits 1 when the query cannot be analyzed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = call(&.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--sql",
        "SELECT * FROM missing_table",
        "--suggest",
        "--format",
        "json",
    }, null, fixture.work_parent, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(contains(result.stderr, "batch_baseline_failed"));
}
