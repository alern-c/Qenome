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
