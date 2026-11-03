const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli = @import("../cli.zig");
const contract = @import("../contract/values.zig");
const model = @import("../report/model.zig");
const sql_lint = @import("../sql/lint.zig");
const sql_warnings = @import("sql_warnings.zig");
const testing = std.testing;

fn plan(rows: []const db.PlanRow) db.Plan {
    return .{ .rows = @constCast(rows) };
}

fn planRow(detail: []const u8) db.PlanRow {
    const kind: db.PlanKind = if (std.mem.startsWith(u8, detail, "SEARCH ")) .search else .scan;
    return .{ .id = 2, .parent = 0, .label = .{ .kind = kind }, .detail = detail };
}

fn expectPosition(sql: []const u8, offset: usize, line: u32, column: u32) !void {
    const at = sql_warnings.position(sql, offset);
    try testing.expectEqual(line, at.line);
    try testing.expectEqual(column, at.column);
}

test "the position counts lines and bytes from one" {
    try expectPosition("SELECT 1", 0, 1, 1);
    try expectPosition("SELECT id\nFROM t\nWHERE lower(email) = ?", 24, 3, 8);
    try expectPosition("SELECT id\n", 10, 2, 1);
}

test "the plan check keeps a function on a column unless the table uses an index" {
    const sql = "SELECT id FROM t WHERE lower(email) = ?";
    const scan = [_]db.PlanRow{planRow("SCAN t")};
    const kept = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&scan) });
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(kept[0].plan_checked);

    const index = [_]db.PlanRow{planRow("SEARCH t USING INDEX ix_lower (lower(email)=?)")};
    const indexed = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&index) });
    defer testing.allocator.free(indexed);
    try testing.expectEqual(@as(usize, 0), indexed.len);

    const covering = [_]db.PlanRow{planRow("SCAN t USING COVERING INDEX ix_lower")};
    const covered = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&covering) });
    defer testing.allocator.free(covered);
    try testing.expectEqual(@as(usize, 0), covered.len);

    const primary = [_]db.PlanRow{planRow("SEARCH t USING INTEGER PRIMARY KEY (rowid=?)")};
    const primary_key = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&primary) });
    defer testing.allocator.free(primary_key);
    try testing.expectEqual(@as(usize, 1), primary_key.len);

    const automatic = [_]db.PlanRow{planRow("SEARCH t USING AUTOMATIC COVERING INDEX (id=?)")};
    const auto = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&automatic) });
    defer testing.allocator.free(auto);
    try testing.expectEqual(@as(usize, 1), auto.len);

    const other = [_]db.PlanRow{planRow("SEARCH u USING INDEX ix_email (email=?)")};
    const another = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&other) });
    defer testing.allocator.free(another);
    try testing.expectEqual(@as(usize, 1), another.len);
}

test "a function finding without a plan is kept and not plan checked" {
    const kept = try sql_warnings.collect(testing.allocator, .{ .sql = "SELECT id FROM t WHERE lower(email) = ?" });
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(!kept[0].plan_checked);
}

test "the OR finding needs a full scan of its table" {
    const sql = "SELECT id FROM t WHERE a = 1 OR b = 2";
    const scan = [_]db.PlanRow{planRow("SCAN t")};
    const kept = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&scan) });
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(kept[0].plan_checked);

    const covering = [_]db.PlanRow{planRow("SCAN t USING COVERING INDEX ix_a")};
    const covered = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&covering) });
    defer testing.allocator.free(covered);
    try testing.expectEqual(@as(usize, 0), covered.len);

    const search = [_]db.PlanRow{planRow("SEARCH t USING INDEX ix_a (a=?)")};
    const searched = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&search) });
    defer testing.allocator.free(searched);
    try testing.expectEqual(@as(usize, 0), searched.len);

    const other = [_]db.PlanRow{planRow("SCAN u")};
    const another = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&other) });
    defer testing.allocator.free(another);
    try testing.expectEqual(@as(usize, 0), another.len);

    const no_plan = try sql_warnings.collect(testing.allocator, .{ .sql = sql });
    defer testing.allocator.free(no_plan);
    try testing.expectEqual(@as(usize, 0), no_plan.len);
}

test "the flags turn the warnings off" {
    const sql = "SELECT * FROM t WHERE a = 1 OR b = 2";
    const scan = [_]db.PlanRow{planRow("SCAN t")};
    const both = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&scan) });
    defer testing.allocator.free(both);
    try testing.expectEqual(@as(usize, 2), both.len);

    const disabled = try sql_warnings.collect(testing.allocator, .{ .sql = sql, .plan = plan(&scan), .enabled = false });
    defer testing.allocator.free(disabled);
    try testing.expectEqual(@as(usize, 0), disabled.len);

    const ignored = try sql_warnings.collect(testing.allocator, .{
        .sql = sql,
        .plan = plan(&scan),
        .ignored = &.{contract.code.select_star},
    });
    defer testing.allocator.free(ignored);
    try testing.expectEqual(@as(usize, 1), ignored.len);
    try testing.expectEqualStrings(contract.code.or_across_columns, ignored[0].code);
}

test "the bind values reach the lint" {
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .text = "%x" } }};
    const found = try sql_warnings.collect(testing.allocator, .{
        .sql = "SELECT id FROM t WHERE name LIKE ?",
        .binds = &binds,
    });
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings(contract.code.leading_wildcard_like, found[0].code);
    try testing.expectEqual(@as(u32, 1), found[0].line);
    try testing.expectEqual(@as(u32, 34), found[0].column);
}

const RunResult = struct {
    code: cli.ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

const Mode = enum { select, write };

fn relativePath(allocator: std.mem.Allocator, tmp: *const testing.TmpDir, sub_path: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}/{s}", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path, sub_path }, 0);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    work_parent: [:0]u8,

    fn init(schema: [:0]const u8, select_sql: []const u8, index_sql: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const db_path = try relativePath(testing.allocator, &tmp, "fixture.db");
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, schema);
        const select_path = try file(&tmp, "select.sql", select_sql);
        errdefer testing.allocator.free(select_path);
        const index_path = try file(&tmp, "index.sql", index_sql);
        errdefer testing.allocator.free(index_path);
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        const work_parent = try relativePath(testing.allocator, &tmp, "work");
        return .{ .tmp = tmp, .db_path = db_path, .select_path = select_path, .index_path = index_path, .work_parent = work_parent };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.select_path);
        testing.allocator.free(self.index_path);
        testing.allocator.free(self.work_parent);
        self.tmp.cleanup();
    }

    fn run(
        self: *Fixture,
        mode: Mode,
        format: [:0]const u8,
        extra: []const [:0]const u8,
        stdout_buffer: []u8,
        stderr_buffer: []u8,
    ) RunResult {
        var argv: [32][:0]const u8 = undefined;
        const role: [:0]const u8 = if (mode == .write) "--write" else "--select";
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, role, self.select_path, "--index-sql", self.index_path, "--format", format };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        var stdout = Io.Writer.fixed(stdout_buffer);
        var stderr = Io.Writer.fixed(stderr_buffer);
        const code = cli.run(testing.io, testing.allocator, argv[0 .. required.len + extra.len], .{ .temp_parent = self.work_parent }, &stdout, &stderr);
        return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
    }
};

fn file(tmp: *testing.TmpDir, sub_path: []const u8, data: []const u8) ![:0]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    return relativePath(testing.allocator, tmp, sub_path);
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

fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

const plain_schema: [:0]const u8 =
    \\CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
;

const indexed_schema: [:0]const u8 =
    \\CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
    \\CREATE INDEX idx_a ON t(a);
    \\CREATE INDEX idx_b ON t(b);
;

test "the pair report lists the SQL warnings in human, kv and json" {
    var fixture = try Fixture.init(plain_schema, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = fixture.run(.select, "human", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "\nSQL warnings\n") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "select_star:") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "leading_wildcard_like:") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "select.sql:1:8:") != null);

    const kv = fixture.run(.select, "kv", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, kv.code);
    try testing.expect(std.mem.indexOf(u8, kv.stdout, "sql-warning: select_star info ") != null);
    try testing.expect(std.mem.indexOf(u8, kv.stdout, "sql-warning: leading_wildcard_like warning ") != null);

    const json = fixture.run(.select, "json", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 2), warnings.len);
    try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings(contract.sql_warning_severity.info, try jsonText(warnings[0], "severity"));
    try testing.expectEqualStrings(contract.sql_warning_messages.select_star, try jsonText(warnings[0], "message"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(warnings[0], "line"));
    try testing.expectEqual(@as(i64, 8), try jsonInt(warnings[0], "column"));
    try testing.expect(!try jsonBool(warnings[0], "plan_checked"));
    try testing.expectEqualStrings(contract.code.leading_wildcard_like, try jsonText(warnings[1], "code"));
}

fn jsonBool(value: std.json.Value, key: []const u8) !bool {
    return switch (try jsonGet(value, key)) {
        .bool => |flag| flag,
        else => error.TestUnexpectedResult,
    };
}

test "the SQL warnings never change the verdict, the result, or the exit" {
    var fixture = try Fixture.init(plain_schema, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;

    var parsed_plain = try parseJson(fixture.run(.select, "json", &.{}, &out, &err).stdout);
    defer parsed_plain.deinit();
    var parsed_off = try parseJson(fixture.run(.select, "json", &.{"--no-sql-warnings"}, &out, &err).stdout);
    defer parsed_off.deinit();
    try testing.expectEqual(try jsonGet(parsed_plain.value, "exit_code"), try jsonGet(parsed_off.value, "exit_code"));
    try testing.expectEqualStrings(try jsonText(parsed_plain.value, "verdict"), try jsonText(parsed_off.value, "verdict"));
    try testing.expectEqualStrings(try jsonText(parsed_plain.value, "result"), try jsonText(parsed_off.value, "result"));
}

test "--no-sql-warnings turns every SQL warning off" {
    var fixture = try Fixture.init(plain_schema, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = fixture.run(.select, "human", &.{"--no-sql-warnings"}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "SQL warnings") == null);

    var parsed = try parseJson(fixture.run(.select, "json", &.{"--no-sql-warnings"}, &out, &err).stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(parsed.value, "sql_warnings")).len);
}

test "--ignore-sql-warning turns one code off and repeats" {
    var fixture = try Fixture.init(plain_schema, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;

    const one = fixture.run(.select, "human", &.{ "--ignore-sql-warning", "select_star" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, one.code);
    try testing.expect(std.mem.indexOf(u8, one.stdout, "select_star") == null);
    try testing.expect(std.mem.indexOf(u8, one.stdout, "leading_wildcard_like") != null);

    const all = fixture.run(.select, "human", &.{ "--ignore-sql-warning", "select_star", "--ignore-sql-warning", "leading_wildcard_like" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, all.code);
    try testing.expect(std.mem.indexOf(u8, all.stdout, "SQL warnings") == null);
}

test "an unknown SQL warning code is a usage error" {
    var fixture = try Fixture.init(plain_schema, "SELECT * FROM t", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = fixture.run(.select, "human", &.{"--ignore-sql-warning"}, &out, &err);
    try testing.expectEqual(cli.ExitCode.usage, human.code);

    const json = fixture.run(.select, "json", &.{ "--ignore-sql-warning", "nope" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.usage, json.code);
    var parsed = try parseJson(json.stderr);
    defer parsed.deinit();
    const error_value = try jsonGet(parsed.value, "error");
    try testing.expectEqualStrings(contract.code.usage_sql_warning, try jsonText(error_value, "code"));
}

test "the plan check drops a function on a column when the baseline uses an expression index" {
    var plain = try Fixture.init(plain_schema, "SELECT id FROM t WHERE lower(b) = ?", "CREATE INDEX idx_lower ON t(lower(b));");
    defer plain.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;
    const kept = plain.run(.select, "human", &.{ "--bind", "1:text:x", "--runs", "0" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, kept.code);
    try testing.expect(std.mem.indexOf(u8, kept.stdout, "function_on_column") != null);

    const expression_schema: [:0]const u8 =
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
        \\CREATE INDEX idx_lower ON t(lower(b));
    ;
    var indexed = try Fixture.init(expression_schema, "SELECT id FROM t WHERE lower(b) = ?", "CREATE INDEX idx_b ON t(b);");
    defer indexed.deinit();
    const dropped = indexed.run(.select, "human", &.{ "--bind", "1:text:x", "--runs", "0" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, dropped.code);
    try testing.expect(std.mem.indexOf(u8, dropped.stdout, "SQL warnings") == null);
}

test "the plan check keeps the OR warning only for a full scan" {
    const select_sql = "SELECT id FROM t WHERE a = 1 OR b = 2";
    var plain = try Fixture.init(plain_schema, select_sql, "CREATE INDEX idx_a ON t(a);");
    defer plain.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;
    const kept_run = plain.run(.select, "human", &.{ "--runs", "0" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, kept_run.code);
    try testing.expect(std.mem.indexOf(u8, kept_run.stdout, "or_across_columns") != null);

    var indexed = try Fixture.init(indexed_schema, select_sql, "CREATE INDEX idx_ab ON t(a, b);");
    defer indexed.deinit();
    const dropped = indexed.run(.select, "human", &.{ "--runs", "0" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, dropped.code);
    try testing.expect(std.mem.indexOf(u8, dropped.stdout, "or_across_columns") == null);
}

test "the write comparison reports the SQL warnings" {
    var fixture = try Fixture.init(plain_schema, "UPDATE t SET a = 1 WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    var out: [65536]u8 = undefined;
    var err: [65536]u8 = undefined;
    const human = fixture.run(.write, "human", &.{ "--runs", "1" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "SQL warnings") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "leading_wildcard_like") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "select.sql:1:") != null);
}

const batch_sql = "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);";

const batch_manifest =
    \\{"queries":[{"select":"select.sql"},{"select":"select2.sql"}],"candidates":[{"index_sql":"index.sql"},{"index_sql":"index2.sql"}]}
;

const one_candidate_manifest =
    \\{"queries":[{"select":"select.sql","binds":["1:text:x"]}],"candidates":[{"index_sql":"index.sql"}]}
;

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |at| {
        total += 1;
        start = at + needle.len;
    }
    return total;
}

fn runBatchMode(
    fixture: *Fixture,
    manifest: [:0]const u8,
    format: [:0]const u8,
    extra: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var argv: [20][:0]const u8 = undefined;
    const required = [_][:0]const u8{ "Qenome", "--db", fixture.db_path, "--batch", manifest, "--format", format };
    @memcpy(argv[0..required.len], &required);
    @memcpy(argv[required.len..][0..extra.len], extra);
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = cli.run(testing.io, testing.allocator, argv[0 .. required.len + extra.len], .{ .temp_parent = fixture.work_parent }, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

fn expectSameJsonText(a: std.json.Value, b: std.json.Value, key: []const u8) !void {
    const left = try jsonGet(a, key);
    const right = try jsonGet(b, key);
    try testing.expectEqual(left == .null, right == .null);
    if (left == .null) return;
    try testing.expectEqualStrings(try jsonText(a, key), try jsonText(b, key));
}

fn prepareBatch(fixture: *Fixture) ![:0]u8 {
    const second_select = try file(&fixture.tmp, "select2.sql", "SELECT * FROM t WHERE a = 1");
    testing.allocator.free(second_select);
    return file(&fixture.tmp, "batch.json", batch_manifest);
}

fn runSuggestMode(
    fixture: *Fixture,
    format: [:0]const u8,
    extra: []const [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var argv: [20][:0]const u8 = undefined;
    const required = [_][:0]const u8{ "Qenome", "--db", fixture.db_path, "--select", fixture.select_path, "--suggest", "--format", format };
    @memcpy(argv[0..required.len], &required);
    @memcpy(argv[required.len..][0..extra.len], extra);
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = cli.run(testing.io, testing.allocator, argv[0 .. required.len + extra.len], .{ .temp_parent = fixture.work_parent }, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

test "a batch report lints each baseline SELECT once and lists the warnings" {
    var fixture = try Fixture.init(batch_sql, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    const second_index = try file(&fixture.tmp, "index2.sql", "CREATE INDEX idx_a ON t(a);");
    defer testing.allocator.free(second_index);
    const manifest = try prepareBatch(&fixture);
    defer testing.allocator.free(manifest);
    var out: [262144]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = runBatchMode(&fixture, manifest, "human", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "\nSQL warnings\n") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "  select.sql:1:8: info: select_star:") != null);
    try testing.expectEqual(@as(usize, 1), count(human.stdout, "leading_wildcard_like:"));

    const json = runBatchMode(&fixture, manifest, "json", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 3), warnings.len);
    try testing.expectEqualStrings("select.sql", try jsonText(warnings[0], "query"));
    try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings(contract.sql_warning_severity.info, try jsonText(warnings[0], "severity"));
    try testing.expectEqual(@as(i64, 1), try jsonInt(warnings[0], "line"));
    try testing.expectEqual(@as(i64, 8), try jsonInt(warnings[0], "column"));
    try testing.expect(!try jsonBool(warnings[0], "plan_checked"));
    try testing.expectEqualStrings(contract.code.leading_wildcard_like, try jsonText(warnings[1], "code"));
    try testing.expectEqualStrings("select2.sql", try jsonText(warnings[2], "query"));
    try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[2], "code"));
    const results = try jsonItems(parsed.value, "results");
    try testing.expectEqual(@as(usize, 4), results.len);
    for (results) |entry| {
        const comparison = try jsonGet(entry, "comparison");
        try testing.expectError(error.TestUnexpectedResult, jsonGet(comparison, "sql_warnings"));
    }

    const off_json = runBatchMode(&fixture, manifest, "json", &.{"--no-sql-warnings"}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, off_json.code);
    var off = try parseJson(off_json.stdout);
    defer off.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(off.value, "sql_warnings")).len);
    try testing.expectEqual(try jsonInt(parsed.value, "exit_code"), try jsonInt(off.value, "exit_code"));
    try expectSameJsonText(parsed.value, off.value, "recommended");
    const on_summary = try jsonItems(parsed.value, "summary");
    const off_summary = try jsonItems(off.value, "summary");
    try testing.expectEqual(on_summary.len, off_summary.len);
    for (on_summary, off_summary) |on_entry, off_entry| {
        for ([_][]const u8{ "improved", "no_effect", "needs_check", "mismatch", "incomparable", "timeout" }) |key| {
            try testing.expectEqual(try jsonInt(on_entry, key), try jsonInt(off_entry, key));
        }
    }
}

test "the batch plan check drops a function on a column when the baseline uses an expression index" {
    const select_sql = "SELECT id FROM t WHERE lower(b) = ?";
    var plain = try Fixture.init(batch_sql, select_sql, "CREATE INDEX idx_b ON t(b);");
    defer plain.deinit();
    const plain_manifest = try file(&plain.tmp, "batch.json", one_candidate_manifest);
    defer testing.allocator.free(plain_manifest);
    var out: [262144]u8 = undefined;
    var err: [65536]u8 = undefined;

    const kept = runBatchMode(&plain, plain_manifest, "human", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, kept.code);
    try testing.expect(std.mem.indexOf(u8, kept.stdout, "\nSQL warnings\n") != null);
    try testing.expect(std.mem.indexOf(u8, kept.stdout, "function_on_column") != null);

    const expression_sql: [:0]const u8 =
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
        \\CREATE INDEX idx_lower ON t(lower(b));
    ;
    var indexed = try Fixture.init(expression_sql, select_sql, "CREATE INDEX idx_b ON t(b);");
    defer indexed.deinit();
    const indexed_manifest = try file(&indexed.tmp, "batch.json", one_candidate_manifest);
    defer testing.allocator.free(indexed_manifest);

    const dropped = runBatchMode(&indexed, indexed_manifest, "human", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, dropped.code);
    try testing.expect(std.mem.indexOf(u8, dropped.stdout, "SQL warnings") == null);

    const dropped_json = runBatchMode(&indexed, indexed_manifest, "json", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, dropped_json.code);
    var parsed = try parseJson(dropped_json.stdout);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(parsed.value, "sql_warnings")).len);
}

test "a batch honours --ignore-sql-warning for one code" {
    var fixture = try Fixture.init(batch_sql, "SELECT * FROM t WHERE b LIKE '%x'", "CREATE INDEX idx_b ON t(b);");
    defer fixture.deinit();
    const second_index = try file(&fixture.tmp, "index2.sql", "CREATE INDEX idx_a ON t(a);");
    defer testing.allocator.free(second_index);
    const manifest = try prepareBatch(&fixture);
    defer testing.allocator.free(manifest);
    var out: [262144]u8 = undefined;
    var err: [65536]u8 = undefined;

    const ignored = runBatchMode(&fixture, manifest, "json", &.{ "--ignore-sql-warning", contract.code.select_star }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, ignored.code);
    var parsed = try parseJson(ignored.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings(contract.code.leading_wildcard_like, try jsonText(warnings[0], "code"));

    const human = runBatchMode(&fixture, manifest, "human", &.{ "--ignore-sql-warning", contract.code.select_star }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "\nSQL warnings\n") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "select_star") == null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "leading_wildcard_like") != null);
}

test "--suggest reports the SQL warnings in human and json" {
    var fixture = try Fixture.init(batch_sql, "SELECT * FROM t WHERE a = ?", "CREATE INDEX idx_a ON t(a);");
    defer fixture.deinit();
    var out: [262144]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = runSuggestMode(&fixture, "human", &.{ "--bind", "1:int:1" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "\nSQL warnings\n") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "info: select_star:") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, fixture.select_path) != null);

    const json = runSuggestMode(&fixture, "json", &.{ "--bind", "1:int:1" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const warnings = try jsonItems(parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqualStrings(fixture.select_path, try jsonText(warnings[0], "query"));
    try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[0], "code"));

    const off = runSuggestMode(&fixture, "json", &.{ "--bind", "1:int:1", "--no-sql-warnings" }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, off.code);
    var off_parsed = try parseJson(off.stdout);
    defer off_parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(off_parsed.value, "sql_warnings")).len);
    try testing.expectEqual(try jsonInt(parsed.value, "exit_code"), try jsonInt(off_parsed.value, "exit_code"));
    try testing.expectEqualStrings(try jsonText(parsed.value, "recommended"), try jsonText(off_parsed.value, "recommended"));
}

test "--suggest reports the SQL warnings when no index is needed" {
    var fixture = try Fixture.init(batch_sql, "SELECT * FROM t ORDER BY random() LIMIT 10", "CREATE INDEX idx_a ON t(a);");
    defer fixture.deinit();
    var out: [262144]u8 = undefined;
    var err: [65536]u8 = undefined;

    const human = runSuggestMode(&fixture, "human", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expectEqualStrings("", human.stderr);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "no index needed") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "\nsql warnings:\n") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "info: select_star:") != null);
    try testing.expect(std.mem.indexOf(u8, human.stdout, "warning: order_by_random:") != null);

    const json = runSuggestMode(&fixture, "json", &.{}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    try testing.expect(!try jsonBool(parsed.value, "index_needed"));
    const warnings = try jsonItems(parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 2), warnings.len);
    try testing.expectEqualStrings(fixture.select_path, try jsonText(warnings[0], "query"));
    try testing.expectEqualStrings(contract.code.select_star, try jsonText(warnings[0], "code"));
    try testing.expectEqualStrings(contract.code.order_by_random, try jsonText(warnings[1], "code"));

    const off = runSuggestMode(&fixture, "json", &.{"--no-sql-warnings"}, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, off.code);
    var off_parsed = try parseJson(off.stdout);
    defer off_parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try jsonItems(off_parsed.value, "sql_warnings")).len);
    try testing.expectEqual(try jsonInt(parsed.value, "exit_code"), try jsonInt(off_parsed.value, "exit_code"));

    const ignored = runSuggestMode(&fixture, "json", &.{ "--ignore-sql-warning", contract.code.select_star }, &out, &err);
    try testing.expectEqual(cli.ExitCode.ok, ignored.code);
    var ignored_parsed = try parseJson(ignored.stdout);
    defer ignored_parsed.deinit();
    const remaining = try jsonItems(ignored_parsed.value, "sql_warnings");
    try testing.expectEqual(@as(usize, 1), remaining.len);
    try testing.expectEqualStrings(contract.code.order_by_random, try jsonText(remaining[0], "code"));
}
