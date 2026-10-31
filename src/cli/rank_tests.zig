const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const contract = @import("../contract/values.zig");
const db = @import("../db.zig");
const cli_rank = @import("rank.zig");

const testing = std.testing;

const ExitCode = cli.ExitCode;

const schema: [:0]const u8 =
    \\CREATE TABLE events(id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL, note TEXT NOT NULL);
    \\CREATE INDEX idx_events_customer ON events(customer_id);
    \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 80)
    \\INSERT INTO events(customer_id, note) SELECT x, 'n' FROM c;
    \\ANALYZE;
;

const RunResult = struct {
    code: ExitCode,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    work: [:0]u8,
    db_path: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        const work = try tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator);
        errdefer testing.allocator.free(work);
        const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/app.db", .{root}, 0);
        try db.createTestDatabase(db_path, schema);
        return .{ .tmp = tmp, .root = root, .work = work, .db_path = db_path };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        testing.allocator.free(self.work);
        testing.allocator.free(self.db_path);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn path(self: *Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ self.root, name }, 0);
    }

    fn run(self: *Fixture, extra: []const [:0]const u8) !RunResult {
        const manifest = try self.path("batch.json");
        defer testing.allocator.free(manifest);
        var argv: [12][:0]const u8 = undefined;
        const head = [_][:0]const u8{ "Qenome", "--db", self.db_path, "--batch", manifest };
        @memcpy(argv[0..head.len], &head);
        @memcpy(argv[head.len..][0..extra.len], extra);
        return call(self.work, argv[0 .. head.len + extra.len]);
    }
};

fn call(work: [:0]const u8, argv: []const [:0]const u8) !RunResult {
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [8192]u8 = undefined;
    var stdout = Io.Writer.fixed(&stdout_buffer);
    var stderr = Io.Writer.fixed(&stderr_buffer);
    const code = cli.run(testing.io, testing.allocator, argv, .{ .temp_parent = work }, &stdout, &stderr);
    return .{
        .code = code,
        .stdout = try testing.allocator.dupe(u8, stdout.buffered()),
        .stderr = try testing.allocator.dupe(u8, stderr.buffered()),
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn billIsOnlyANote(text: []const u8) bool {
    if (contains(text, "cost")) return false;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "bill")) |at| {
        if (at < 6 or !std.mem.eql(u8, rest[at - 6 .. at + 4], "not a bill")) return false;
        rest = rest[at + 4 ..];
    }
    return true;
}

fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0 and text[text.len - 1] == '\n');
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

fn jsonGet(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

test "a table scan is a SCAN step that does not use an index" {
    try testing.expect(cli_rank.isTableScan("SCAN events"));
    try testing.expect(!cli_rank.isTableScan("SCAN events USING INDEX idx_events_customer"));
    try testing.expect(!cli_rank.isTableScan("SCAN CONSTANT ROW"));
    try testing.expect(!cli_rank.isTableScan("SEARCH events USING INDEX idx_events_customer"));
}

test "a full scan ranks above an indexed query and is flagged" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("scan.sql", "SELECT note FROM events WHERE note = 'missing'\n");
    try fixture.write("indexed.sql", "SELECT note FROM events WHERE id = 1\n");
    try fixture.write("batch.json",
        \\{"queries":[{"select":"indexed.sql"},{"select":"scan.sql"}]}
        \\
    );

    var human = try fixture.run(&.{"--rank"});
    defer human.deinit();
    try testing.expectEqual(ExitCode.likely_full_scan, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(contains(human.stdout, "#1  scan.sql\n"));
    try testing.expect(contains(human.stdout, "#2  indexed.sql\n"));
    try testing.expect(contains(human.stdout, "flag: likely full scan\n"));
    try testing.expect(contains(human.stdout, "likely full scans: 1\n"));
    try testing.expect(contains(human.stdout, "next: qenome <DB> scan.sql --suggest\n"));
    try testing.expect(billIsOnlyANote(human.stdout));

    var json_run = try fixture.run(&.{ "--rank", "--format", "json" });
    defer json_run.deinit();
    try testing.expectEqual(ExitCode.likely_full_scan, json_run.code);
    var parsed = try parseJson(json_run.stdout);
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 2), (try jsonGet(root, "schema_version")).integer);
    try testing.expectEqual(@as(i64, contract.rank_schema_version), (try jsonGet(root, "rank_schema_version")).integer);
    try testing.expectEqual(@as(i64, 7), (try jsonGet(root, "exit_code")).integer);
    try testing.expectEqual(@as(i64, 1), (try jsonGet(root, "likely_full_scans")).integer);
    try testing.expect(contains((try jsonGet(root, "note")).string, "not a bill"));
    const queries = (try jsonGet(root, "queries")).array.items;
    try testing.expectEqual(@as(usize, 2), queries.len);
    try testing.expectEqualStrings("scan.sql", (try jsonGet(queries[0], "select")).string);
    try testing.expect((try jsonGet(queries[0], "likely_full_scan")).bool);
    try testing.expect(!(try jsonGet(queries[1], "likely_full_scan")).bool);
    try testing.expectEqual(std.json.Value.null, try jsonGet(queries[0], "relative_rows"));
    try testing.expect((try jsonGet(queries[0], "rows_read")).integer > (try jsonGet(queries[1], "rows_read")).integer);
    try testing.expect(billIsOnlyANote(json_run.stdout));
}

test "a manifest of indexed queries reports no likely full scan" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("by_id.sql", "SELECT note FROM events WHERE id = 1\n");
    try fixture.write("by_customer.sql", "SELECT note FROM events WHERE customer_id = 7\n");
    try fixture.write("batch.json",
        \\{"queries":[{"select":"by_id.sql"},{"select":"by_customer.sql"}]}
        \\
    );
    var human = try fixture.run(&.{"--rank"});
    defer human.deinit();
    try testing.expectEqual(ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "likely full scans: 0\n"));
    try testing.expect(!contains(human.stdout, "flag: likely full scan\n"));
    try testing.expect(billIsOnlyANote(human.stdout));
}

test "executions from the manifest weight the rank and stay out of a comparison" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a.sql", "SELECT note FROM events WHERE id = 1\n");
    try fixture.write("b.sql", "SELECT note FROM events WHERE id = 2\n");
    try fixture.write("batch.json",
        \\{"queries":[{"select":"b.sql","executions":1},{"select":"a.sql","executions":30}]}
        \\
    );
    var ranked = try fixture.run(&.{ "--rank", "--format", "json" });
    defer ranked.deinit();
    try testing.expectEqual(ExitCode.ok, ranked.code);
    var parsed = try parseJson(ranked.stdout);
    defer parsed.deinit();
    const queries = (try jsonGet(parsed.value, "queries")).array.items;
    try testing.expectEqualStrings("a.sql", (try jsonGet(queries[0], "select")).string);
    try testing.expectEqual(@as(i64, 30), (try jsonGet(queries[0], "executions")).integer);
    const rows_read = (try jsonGet(queries[0], "rows_read")).integer;
    try testing.expectEqual(rows_read * 30, (try jsonGet(queries[0], "relative_rows")).integer);
    try testing.expect(contains(ranked.stdout, "not a bill"));

    try fixture.write("index.sql", "CREATE INDEX idx_events_note ON events(note)\n");
    try fixture.write("batch.json",
        \\{"queries":[{"select":"a.sql","binds":[],"executions":4}],"candidates":[{"index_sql":"index.sql"}]}
        \\
    );
    var compared = try fixture.run(&.{});
    defer compared.deinit();
    try testing.expectEqual(ExitCode.ok, compared.code);
    try testing.expect(!contains(compared.stderr, "executions"));
    try testing.expect(contains(compared.stdout, "rows read"));
}

test "a rank manifest rejects a zero execution count" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a.sql", "SELECT note FROM events WHERE id = 1\n");
    try fixture.write("batch.json",
        \\{"queries":[{"select":"a.sql","executions":0}]}
        \\
    );
    var run_result = try fixture.run(&.{"--rank"});
    defer run_result.deinit();
    try testing.expectEqual(ExitCode.rejected, run_result.code);
    try testing.expect(contains(run_result.stderr, "executions must be at least 1"));
    try testing.expectEqualStrings("", run_result.stdout);
}

test "--rank without a manifest is a usage error" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var run_result = try call(fixture.work, &.{ "Qenome", "--db", fixture.db_path, "--rank", "--format", "json" });
    defer run_result.deinit();
    try testing.expectEqual(ExitCode.usage, run_result.code);
    try testing.expect(contains(run_result.stderr, "usage_rank_conflict"));
    try testing.expect(contains(run_result.stderr, "--rank needs --batch"));
}
