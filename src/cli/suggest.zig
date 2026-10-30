const std = @import("std");
const builtin = @import("builtin");
const contract = @import("../contract/values.zig");
const sql_lexer = @import("../sql/lexer.zig");
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");

var test_expert_failure: ?[]const u8 = null;

pub fn setTestExpertFailure(message: ?[]const u8) void {
    comptime std.debug.assert(builtin.is_test);
    test_expert_failure = message;
}

pub const max_statements = 20;

pub const label_prefix = "suggested:";

pub const Warning = struct {
    code: []const u8,
    message: []const u8,
};

pub const Query = struct {
    label: []const u8,
    sql: [:0]const u8,
};

pub const Build = struct {
    statements: []const [:0]const u8,
    warnings: []const Warning,
    generated: usize,
    rejected: usize,
};

pub const Ready = struct {
    statements: []const [:0]const u8,
    warnings: []const Warning,
};

pub const Generated = union(enum) {
    ready: Ready,
    failed: []const u8,
    guard_failed: []const u8,
    open_failed,
};

const Session = struct {
    handle: ?*sqlite.sqlite3 = null,

    fn open(self: *Session, path: [:0]const u8) bool {
        var handle: ?*sqlite.sqlite3 = null;
        const rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.SQLITE_OPEN_READONLY, null);
        const conn = handle orelse return false;
        if (rc != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(conn);
            return false;
        }
        self.handle = conn;
        return true;
    }

    fn close(self: *Session) void {
        const conn = self.handle orelse return;
        _ = sqlite.sqlite3_close(conn);
        self.handle = null;
    }
};

const guard_entry: sqlite.AutoExtensionFn = &guardInit;

fn guardInit(handle: ?*sqlite.sqlite3, pzErr: ?*?[*:0]u8, api: ?*const anyopaque) callconv(.c) c_int {
    _ = pzErr;
    _ = api;
    const conn = handle orelse return sqlite.SQLITE_ERROR;
    if (sqlite.sqlite3_set_authorizer(conn, guardAuthorizer, null) != sqlite.SQLITE_OK) return sqlite.SQLITE_ERROR;
    if (sqlite.sqlite3_limit(conn, sqlite.SQLITE_LIMIT_ATTACHED, 0) < 0) return sqlite.SQLITE_ERROR;
    return sqlite.SQLITE_OK;
}

fn guardAuthorizer(
    user_data: ?*anyopaque,
    action: c_int,
    arg1: ?[*:0]const u8,
    arg2: ?[*:0]const u8,
    arg3: ?[*:0]const u8,
    arg4: ?[*:0]const u8,
) callconv(.c) c_int {
    _ = user_data;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    return switch (action) {
        sqlite.SQLITE_ATTACH, sqlite.SQLITE_DETACH => sqlite.SQLITE_DENY,
        sqlite.SQLITE_PRAGMA => if (allowedPragma(arg1)) sqlite.SQLITE_OK else sqlite.SQLITE_DENY,
        else => sqlite.SQLITE_OK,
    };
}

fn allowedPragma(name: ?[*:0]const u8) bool {
    const text = std.mem.span(name orelse return false);
    return std.ascii.eqlIgnoreCase(text, "index_list") or std.ascii.eqlIgnoreCase(text, "index_xinfo");
}

pub const SchemaRejection = struct {
    name: []const u8,
    reason: []const u8,
};

pub const SchemaInspection = union(enum) {
    ok,
    rejected: SchemaRejection,
};

pub fn inspectSchema(arena: std.mem.Allocator, handle: *db.Db) !SchemaInspection {
    const entries = try handle.readSchemaEntries(arena);
    for (entries) |entry| {
        if (std.mem.indexOfScalar(u8, entry.name, 0) != null) {
            return .{ .rejected = .{ .name = entry.name, .reason = "it contains a NUL byte" } };
        }
        if (try inspectSql(arena, entry.sql)) |reason| {
            return .{ .rejected = .{ .name = entry.name, .reason = reason } };
        }
    }
    return .ok;
}

pub fn inspectSql(arena: std.mem.Allocator, sql: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return "it contains a NUL byte";

    const probe = try arena.allocSentinel(u8, sql.len + 1, 0);
    @memcpy(probe[0..sql.len], sql);
    probe[sql.len] = ';';

    const end = completeEnd(probe) orelse return "it is not one complete statement";
    var statement_end = sql.len;
    if (end <= sql.len) {
        switch (tailKind(sql[end..])) {
            .trivia => statement_end = end,
            .statement => return "it holds more than one statement",
            .unterminated_comment => return "it holds an unterminated comment",
        }
    }

    const statement = std.mem.trim(u8, sql[0..statement_end], " \t\r\n\x0c");
    if (statement.len == 0) return "it holds no statement";
    if (!allowedCreate(statement)) return "it does not start with a CREATE statement";
    if (usesExpertModule(statement)) return "it creates a virtual table with the expert module";
    return null;
}

const transition = [8][8]u8{
    .{ 1, 0, 2, 3, 4, 2, 2, 2 },
    .{ 1, 1, 2, 3, 4, 2, 2, 2 },
    .{ 1, 2, 2, 2, 2, 2, 2, 2 },
    .{ 1, 3, 3, 2, 4, 2, 2, 2 },
    .{ 1, 4, 2, 2, 2, 4, 5, 2 },
    .{ 6, 5, 5, 5, 5, 5, 5, 5 },
    .{ 6, 6, 5, 5, 5, 5, 5, 7 },
    .{ 1, 7, 5, 5, 5, 5, 5, 5 },
};

const preflight_options: sql_lexer.Options = .{ .vertical_tab_is_space = false };

pub fn completeEnd(sql: []const u8) ?usize {
    var lexer: sql_lexer.Lexer = .initWith(sql, preflight_options);
    var state: u8 = 0;
    while (lexer.next()) |token| {
        if (!token.terminated) return null;
        const class: u8 = switch (token.kind) {
            .comment => 1,
            .word => wordToken(token.text),
            .punctuator => if (std.mem.eql(u8, token.text, ";")) 0 else 2,
            else => 2,
        };
        state = transition[state][class];
        if (class == 0 and state == 1) return token.start + 1;
    }
    return null;
}

fn wordToken(word: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(word, "create")) return 4;
    if (std.ascii.eqlIgnoreCase(word, "temp") or std.ascii.eqlIgnoreCase(word, "temporary")) return 5;
    if (std.ascii.eqlIgnoreCase(word, "trigger")) return 6;
    if (std.ascii.eqlIgnoreCase(word, "end")) return 7;
    if (std.ascii.eqlIgnoreCase(word, "explain")) return 3;
    return 2;
}

pub fn generate(
    arena: std.mem.Allocator,
    baseline_path: [:0]const u8,
    queries: []const Query,
) std.mem.Allocator.Error!Generated {
    var session: Session = .{};
    if (!session.open(baseline_path)) return .open_failed;
    defer session.close();

    if (sqlite.sqlite3_auto_extension(guard_entry) != sqlite.SQLITE_OK) {
        return .{ .guard_failed = "sqlite3expert could not be guarded" };
    }
    defer _ = sqlite.sqlite3_cancel_auto_extension(guard_entry);

    if (comptime builtin.is_test) {
        if (test_expert_failure) |message| return .{ .failed = message };
    }

    var err: ?[*:0]u8 = null;
    const expert = sqlite.sqlite3_expert_new(session.handle, &err);
    if (expert == null) return .{ .failed = try startFailure(arena, &err) };
    defer sqlite.sqlite3_expert_destroy(expert);
    if (sqlite.sqlite3_expert_config(expert, sqlite.EXPERT_CONFIG_SAMPLE, @as(c_int, 0)) != sqlite.SQLITE_OK) {
        return .{ .failed = "sqlite3expert could not be configured" };
    }

    var warnings: std.ArrayList(Warning) = .empty;
    for (queries) |query| {
        err = null;
        if (sqlite.sqlite3_expert_sql(expert, query.sql, &err) == sqlite.SQLITE_OK) continue;
        const reason = try takeError(arena, &err);
        try warnings.append(arena, .{
            .code = contract.code.suggest_query_skipped,
            .message = try std.fmt.allocPrint(arena, "SQLite could not analyze the query '{s}': {s}", .{
                query.label,
                reason orelse "unknown error",
            }),
        });
    }

    err = null;
    if (sqlite.sqlite3_expert_analyze(expert, &err) != sqlite.SQLITE_OK) {
        const reason = try takeError(arena, &err);
        return .{ .failed = if (reason) |detail|
            try std.fmt.allocPrint(arena, "sqlite3expert could not analyze the queries: {s}", .{detail})
        else
            "sqlite3expert could not analyze the queries" };
    }

    const report = sqlite.sqlite3_expert_report(expert, 0, sqlite.EXPERT_REPORT_CANDIDATES);
    const text = if (report) |pointer| try arena.dupe(u8, std.mem.span(pointer)) else "";
    return .{ .ready = .{
        .statements = try splitReport(arena, text),
        .warnings = warnings.items,
    } };
}

pub fn splitReport(arena: std.mem.Allocator, report: []const u8) std.mem.Allocator.Error![]const [:0]const u8 {
    var statements: std.ArrayList([:0]const u8) = .empty;
    var start: usize = 0;
    for (report, 0..) |byte, index| {
        if (byte != ';') continue;
        const candidate = try arena.dupeSentinel(u8, report[start .. index + 1], 0);
        if (sqlite.sqlite3_complete(candidate) == 0) continue;
        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        if (trimmed.len != 0) try statements.append(arena, try arena.dupeSentinel(u8, trimmed, 0));
        start = index + 1;
    }
    return statements.items;
}

pub fn accept(
    arena: std.mem.Allocator,
    handle: *db.Db,
    raw: []const [:0]const u8,
    limit: usize,
) std.mem.Allocator.Error!Build {
    var warnings: std.ArrayList(Warning) = .empty;
    const keep = @min(raw.len, limit);
    if (keep < raw.len) {
        try warnings.append(arena, .{
            .code = contract.code.suggestions_truncated,
            .message = try std.fmt.allocPrint(arena, "kept the first {d} of {d} suggestions; dropped {d}", .{
                keep,
                raw.len,
                raw.len - keep,
            }),
        });
    }

    var statements: std.ArrayList([:0]const u8) = .empty;
    var rejected: usize = 0;
    for (raw[0..keep]) |sql| {
        handle.checkCreateIndex(sql) catch |err| {
            rejected += 1;
            try warnings.append(arena, .{
                .code = contract.code.suggestion_rejected,
                .message = try std.fmt.allocPrint(arena, "\"{s}\": {s}", .{ sql, checkReason(handle, err) }),
            });
            continue;
        };
        try statements.append(arena, sql);
    }

    return .{
        .statements = statements.items,
        .warnings = warnings.items,
        .generated = raw.len,
        .rejected = rejected,
    };
}

fn startFailure(arena: std.mem.Allocator, err: *?[*:0]u8) std.mem.Allocator.Error![]const u8 {
    const reason = try takeError(arena, err);
    return if (reason) |detail|
        try std.fmt.allocPrint(arena, "sqlite3expert could not start: {s}", .{detail})
    else
        "sqlite3expert could not start";
}

fn takeError(arena: std.mem.Allocator, err: *?[*:0]u8) std.mem.Allocator.Error!?[]const u8 {
    const pointer = err.* orelse return null;
    err.* = null;
    const message = std.mem.span(pointer);
    const copy = arena.dupe(u8, message) catch |alloc_error| {
        sqlite.sqlite3_free(pointer);
        return alloc_error;
    };
    sqlite.sqlite3_free(pointer);
    return copy;
}

fn checkReason(handle: *db.Db, err: db.CheckError) []const u8 {
    if (handle.errorCode() != sqlite.SQLITE_OK) return handle.message();
    return switch (err) {
        error.EmptyStatement => "the statement is empty",
        error.MultipleStatements => "the text holds more than one statement",
        error.StatementRejected => "the statement is not allowed here",
        error.StatementInvalid => "the statement is not valid for this database",
        error.StatementNotReadOnly => "the statement is not read-only",
        error.StatementNotWrite => "the statement is not one INSERT, UPDATE, DELETE, or REPLACE",
        error.StatementNotCreateIndex => "the statement is not one CREATE INDEX",
    };
}

fn nextWord(text: []const u8, at: *usize) ?[]const u8 {
    while (true) {
        at.* = sql_lexer.skipTriviaWith(text, at.*, preflight_options);
        if (at.* >= text.len) return null;
        const word = sql_lexer.wordAt(text, at.*);
        if (word.end != at.*) {
            at.* = word.end;
            return word.text;
        }
        if (sql_lexer.isQuote(text[at.*])) {
            at.* = sql_lexer.quotedSpan(text, at.*).end;
            continue;
        }
        at.* += 1;
    }
}

fn nextIdentifier(text: []const u8, at: *usize) ?[]const u8 {
    at.* = sql_lexer.skipTriviaWith(text, at.*, preflight_options);
    if (at.* >= text.len) return null;
    if (sql_lexer.isQuote(text[at.*])) {
        const span = sql_lexer.quotedSpan(text, at.*);
        if (!span.terminated) {
            at.* = span.end;
            return null;
        }
        const inner = text[at.* + 1 .. span.end - 1];
        at.* = span.end;
        return inner;
    }
    const word = sql_lexer.wordAt(text, at.*);
    if (word.end == at.*) return null;
    at.* = word.end;
    return word.text;
}

fn tailKind(text: []const u8) Tail {
    var lexer: sql_lexer.Lexer = .initWith(text, preflight_options);
    while (lexer.next()) |token| {
        if (token.kind != .comment) return .statement;
        if (!token.terminated) return .unterminated_comment;
    }
    return .trivia;
}

const Tail = enum { trivia, statement, unterminated_comment };

fn allowedCreate(statement: []const u8) bool {
    var at: usize = 0;
    const first = nextWord(statement, &at) orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "CREATE")) return false;
    const second = nextWord(statement, &at) orelse return false;
    if (std.ascii.eqlIgnoreCase(second, "TABLE")) return true;
    if (std.ascii.eqlIgnoreCase(second, "INDEX")) return true;
    if (std.ascii.eqlIgnoreCase(second, "VIEW")) return true;
    if (std.ascii.eqlIgnoreCase(second, "TRIGGER")) return true;
    if (std.ascii.eqlIgnoreCase(second, "UNIQUE")) return isWord(nextWord(statement, &at), "INDEX");
    if (std.ascii.eqlIgnoreCase(second, "VIRTUAL")) return isWord(nextWord(statement, &at), "TABLE");
    return false;
}

fn usesExpertModule(statement: []const u8) bool {
    var at: usize = 0;
    if (!isWord(nextWord(statement, &at), "CREATE")) return false;
    if (!isWord(nextWord(statement, &at), "VIRTUAL")) return false;
    if (!isWord(nextWord(statement, &at), "TABLE")) return false;

    const before_if = at;
    if (isWord(nextWord(statement, &at), "IF")) {
        if (!isWord(nextWord(statement, &at), "NOT")) return false;
        if (!isWord(nextWord(statement, &at), "EXISTS")) return false;
    } else {
        at = before_if;
    }

    _ = nextIdentifier(statement, &at) orelse return false;
    at = sql_lexer.skipTriviaWith(statement, at, preflight_options);
    if (at < statement.len and statement[at] == '.') {
        at += 1;
        _ = nextIdentifier(statement, &at) orelse return false;
    }

    if (!isWord(nextWord(statement, &at), "USING")) return false;
    const module = nextIdentifier(statement, &at) orelse return false;
    return std.ascii.eqlIgnoreCase(module, "expert");
}

fn isWord(value: ?[]const u8, expected: []const u8) bool {
    const word = value orelse return false;
    return std.ascii.eqlIgnoreCase(word, expected);
}

const testing = std.testing;

fn createFixture(tmp: *testing.TmpDir, arena: std.mem.Allocator) ![:0]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "suggest.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "suggest.db", testing.allocator);
    defer testing.allocator.free(path);
    const copy = try arena.dupeSentinel(u8, path, 0);
    try db.createTestDatabase(copy,
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
    );
    return copy;
}

test "the report splits at statement ends, not inside a quoted name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report =
        \\CREATE INDEX t_idx_1 ON t('x;y');
        \\CREATE INDEX t_idx_2 ON t(b);
        \\
    ;
    const statements = try splitReport(arena, report);
    try testing.expectEqual(@as(usize, 2), statements.len);
    try testing.expectEqualStrings("CREATE INDEX t_idx_1 ON t('x;y');", statements[0]);
    try testing.expectEqualStrings("CREATE INDEX t_idx_2 ON t(b);", statements[1]);
}

test "an empty report has no statements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try splitReport(arena_state.allocator(), "")).len);
    try testing.expectEqual(@as(usize, 0), (try splitReport(arena_state.allocator(), "  \n")).len);
}

test "sampling is zero and a query SQLite cannot analyze is a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);

    const generated = try generate(arena, path, &.{
        .{ .label = "bad.sql", .sql = "SELECT * FROM nope WHERE a = 1" },
        .{ .label = "q.sql", .sql = "SELECT * FROM t WHERE a = 1" },
    });
    switch (generated) {
        .ready => |ready| {
            try testing.expectEqual(@as(usize, 1), ready.statements.len);
            try testing.expect(std.mem.indexOf(u8, ready.statements[0], "CREATE INDEX") != null);
            try testing.expect(std.mem.indexOf(u8, ready.statements[0], "stat1") == null);
            try testing.expectEqual(@as(usize, 1), ready.warnings.len);
            try testing.expectEqualStrings("suggest_query_skipped", ready.warnings[0].code);
            try testing.expect(std.mem.indexOf(u8, ready.warnings[0].message, "bad.sql") != null);
        },
        else => return error.ExpectedReady,
    }
}

test "a query with no suggestion produces an empty report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);

    const generated = try generate(arena, path, &.{.{ .label = "q.sql", .sql = "SELECT 1" }});
    switch (generated) {
        .ready => |ready| {
            try testing.expectEqual(@as(usize, 0), ready.statements.len);
            try testing.expectEqual(@as(usize, 0), ready.warnings.len);
        },
        else => return error.ExpectedReady,
    }
}

test "the limit is applied first and the preflight drops what it rejects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);

    var handle: db.Db = .{};
    try handle.openReadOnly(path);
    defer handle.close() catch {};

    const raw = [_][:0]const u8{
        "CREATE INDEX a_idx ON t(a)",
        "CREATE TABLE bad(x)",
        "CREATE INDEX b_idx ON t(b)",
    };

    const capped = try accept(arena, &handle, &raw, 2);
    try testing.expectEqual(@as(usize, 1), capped.statements.len);
    try testing.expectEqualStrings("CREATE INDEX a_idx ON t(a)", capped.statements[0]);
    try testing.expectEqual(@as(usize, 3), capped.generated);
    try testing.expectEqual(@as(usize, 1), capped.rejected);
    try testing.expectEqual(@as(usize, 2), capped.warnings.len);
    try testing.expectEqualStrings("suggestions_truncated", capped.warnings[0].code);
    try testing.expectEqualStrings("suggestion_rejected", capped.warnings[1].code);
    try testing.expect(std.mem.indexOf(u8, capped.warnings[1].message, "CREATE TABLE bad(x)") != null);

    const full = try accept(arena, &handle, &raw, 20);
    try testing.expectEqual(@as(usize, 2), full.statements.len);
    try testing.expectEqual(@as(usize, 1), full.rejected);
    try testing.expectEqual(@as(usize, 1), full.warnings.len);
    try testing.expectEqualStrings("suggestion_rejected", full.warnings[0].code);
}

fn siblingPath(arena: std.mem.Allocator, path: []const u8, name: []const u8) ![:0]const u8 {
    const directory = std.fs.path.dirname(path) orelse ".";
    return std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, name }, 0);
}

fn rewriteSchema(arena: std.mem.Allocator, path: [:0]const u8, payload: []const u8) !void {
    const update = try std.fmt.allocPrintSentinel(arena, "PRAGMA writable_schema=ON; UPDATE sqlite_schema SET sql = 'CREATE TABLE t(a); {s}' WHERE name = 't';", .{payload}, 0);
    const writer = try db.openTestWriter(path, update);
    _ = sqlite.sqlite3_close(writer);
}

fn expectMissing(path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(testing.io, path, .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.ExpectedMissing;
}

fn expectAttachAllowed() !void {
    var handle: ?*sqlite.sqlite3 = null;
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open_v2(":memory:", &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, null));
    defer _ = sqlite.sqlite3_close(handle);
    try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_exec(handle, "ATTACH ':memory:' AS x", null, null, null));
}

test "the preflight accepts the statements SQLite stores in the schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const accepted = [_][]const u8{
        "CREATE TABLE t(a)",
        "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL)",
        "CREATE TABLE t(a); -- trailing comment",
        "CREATE INDEX i ON t(a)",
        "CREATE UNIQUE INDEX i ON t(a)",
        "CREATE INDEX i ON t(a) WHERE a > 1",
        "CREATE VIEW v AS SELECT 'a;b' FROM t",
        "CREATE VIEW v AS SELECT * FROM \"x;y\"",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = a; INSERT INTO t VALUES (2); END",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; SELECT 2; END",
        "CREATE TABLE t(a) /* trailing */",
        "CREATE TABLE t(a); /* closed */",
        "CREATE TABLE t(a);\n-- trailing",
        "CREATE VIRTUAL TABLE t USING fts5(a)",
        "CREATE VIRTUAL TABLE using$foo USING fts5(a)",
        "CREATE VIRTUAL TABLE usingé USING fts5(a)",
        "CREATE VIRTUAL TABLE main.t USING fts5(a)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS t USING fts5(a)",
        "CREATE\nTABLE\nt(a)",
        "/* lead */ CREATE TABLE t(a)",
        "CREATE TABLE \"CREATE\"(a)",
        "\n]:CREATE:INDEX",
        "@CREATE:-TABLE\x0b",
    };
    for (accepted) |sql| {
        try testing.expectEqual(@as(?[]const u8, null), try inspectSql(arena, sql));
    }
}

test "the preflight rejects extra statements and non CREATE rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { sql: []const u8, reason: []const u8 }{
        .{ .sql = "CREATE TABLE t(a); ATTACH DATABASE 'x' AS v", .reason = "more than one statement" },
        .{ .sql = "CREATE TABLE t(a); VACUUM INTO 'x'", .reason = "more than one statement" },
        .{ .sql = "CREATE TABLE t(a); PRAGMA temp_store_directory='x'", .reason = "more than one statement" },
        .{ .sql = "CREATE TABLE t(a);;", .reason = "more than one statement" },
        .{ .sql = "PRAGMA temp_store_directory='x'", .reason = "does not start with a CREATE statement" },
        .{ .sql = "CREATE TEMP TABLE t(a)", .reason = "does not start with a CREATE statement" },
        .{ .sql = "CREATE UNIQUE VIEW v AS SELECT 1", .reason = "does not start with a CREATE statement" },
        .{ .sql = "SELECT 1", .reason = "does not start with a CREATE statement" },
        .{ .sql = "CREATE VIRTUAL TABLE t USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE t USING \"expert\"(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE t USING [expert](x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE t USING 'expert'(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE using$foo USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE usingé USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE using USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE main.t USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE VIRTUAL TABLE IF NOT EXISTS t USING expert(x)", .reason = "expert module" },
        .{ .sql = "CREATE TABLE t(a)\x00", .reason = "NUL byte" },
        .{ .sql = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1", .reason = "not one complete statement" },
        .{ .sql = "CREATE TABLE t(a) /* unterminated", .reason = "not one complete statement" },
        .{ .sql = "CREATE TABLE t(a); /* unterminated", .reason = "unterminated comment" },
        .{ .sql = "CREATE TABLE t(a, 'x)", .reason = "not one complete statement" },
        .{ .sql = "CREATE TABLE t([x)", .reason = "not one complete statement" },
        .{ .sql = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END\x0b; ATTACH DATABASE 'x' AS v", .reason = "not one complete statement" },
    };
    for (cases) |case| {
        const reason = (try inspectSql(arena, case.sql)) orelse return error.ExpectedRejection;
        try testing.expect(std.mem.indexOf(u8, reason, case.reason) != null);
    }
}

test "the schema preflight accepts triggers, views and quoted names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "schema.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "schema.db", testing.allocator);
    defer testing.allocator.free(path);
    try db.createTestDatabase(path,
        \\CREATE TABLE t(a INTEGER, "x;y" TEXT);
        \\CREATE VIEW v AS SELECT a FROM t;
        \\CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = a; END;
        \\CREATE INDEX "idx;one" ON t(a);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    );
    var handle: db.Db = .{};
    try handle.openReadOnly(path);
    defer handle.close() catch {};

    switch (try inspectSchema(arena, &handle)) {
        .ok => {},
        .rejected => |rejection| {
            std.debug.print("rejected {s}: {s}\n", .{ rejection.name, rejection.reason });
            return error.ExpectedAcceptance;
        },
    }
}

test "the schema preflight accepts the D1 example and the local D1 tables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d1.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "d1.db", testing.allocator);
    defer testing.allocator.free(path);
    try db.createTestDatabase(path,
        \\CREATE TABLE events (
        \\  id          INTEGER PRIMARY KEY,
        \\  customer_id INTEGER,
        \\  status      TEXT NOT NULL,
        \\  note        TEXT
        \\);
        \\CREATE TABLE _cf_METADATA(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;
        \\CREATE TABLE _cf_KV(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;
        \\INSERT INTO events (id, customer_id, status, note) VALUES (1, 1234, 'ok', 'note-1');
    );
    var handle: db.Db = .{};
    try handle.openReadOnly(path);
    defer handle.close() catch {};

    switch (try inspectSchema(arena, &handle)) {
        .ok => {},
        .rejected => return error.ExpectedAcceptance,
    }
}

test "the guard denies ATTACH without the preflight and is cancelled after the expert" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);
    const victim = try siblingPath(arena, path, "attached.db");
    try expectMissing(victim);
    const payload = try std.fmt.allocPrintSentinel(arena, "ATTACH DATABASE ''{s}'' AS v;", .{victim}, 0);
    try rewriteSchema(arena, path, payload);

    const generated = try generate(arena, path, &.{.{ .label = "q.sql", .sql = "SELECT * FROM t WHERE a = 1" }});
    try testing.expect(generated == .failed);
    try expectMissing(victim);
    try expectAttachAllowed();
}

test "the guard denies VACUUM INTO without the preflight" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);
    const victim = try siblingPath(arena, path, "vacuum.db");
    try expectMissing(victim);
    const payload = try std.fmt.allocPrintSentinel(arena, "VACUUM INTO ''{s}'';", .{victim}, 0);
    try rewriteSchema(arena, path, payload);

    const generated = try generate(arena, path, &.{.{ .label = "q.sql", .sql = "SELECT * FROM t WHERE a = 1" }});
    try testing.expect(generated == .failed);
    try expectMissing(victim);
    try expectAttachAllowed();
}

test "the guard denies a PRAGMA outside the allowlist without the preflight" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);
    const payload = "PRAGMA temp_store_directory=''.'';";
    try rewriteSchema(arena, path, payload);

    const generated = try generate(arena, path, &.{.{ .label = "q.sql", .sql = "SELECT * FROM t WHERE a = 1" }});
    try testing.expect(generated == .failed);
    try expectAttachAllowed();
}

test "a normal database keeps its suggestions and leaves no guard behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createFixture(&tmp, arena);

    const generated = try generate(arena, path, &.{.{ .label = "q.sql", .sql = "SELECT * FROM t WHERE a = 1" }});
    switch (generated) {
        .ready => |ready| try testing.expect(ready.statements.len != 0),
        else => return error.ExpectedReady,
    }
    try expectAttachAllowed();
}

test "the preflight scans a large statement once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "CREATE VIEW v AS SELECT '");
    for (0..20000) |_| try text.append(testing.allocator, ';');
    try text.appendSlice(testing.allocator, "' FROM t");
    try testing.expectEqual(@as(?[]const u8, null), try inspectSql(arena, text.items));

    var trigger: std.ArrayList(u8) = .empty;
    defer trigger.deinit(testing.allocator);
    try trigger.appendSlice(testing.allocator, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN ");
    for (0..2000) |_| try trigger.appendSlice(testing.allocator, "UPDATE t SET a = a; ");
    try trigger.appendSlice(testing.allocator, "END");
    try testing.expectEqual(@as(?[]const u8, null), try inspectSql(arena, trigger.items));
}

fn probeSql(arena: std.mem.Allocator, sql: []const u8) ![:0]const u8 {
    const probe = try arena.allocSentinel(u8, sql.len + 1, 0);
    @memcpy(probe[0..sql.len], sql);
    probe[sql.len] = ';';
    return probe;
}

fn referenceCompleteEnd(arena: std.mem.Allocator, probe: []const u8) !?usize {
    var index: usize = 0;
    while (index < probe.len) : (index += 1) {
        if (probe[index] != ';') continue;
        const prefix = try arena.dupeSentinel(u8, probe[0 .. index + 1], 0);
        if (sqlite.sqlite3_complete(prefix) != 0) return index + 1;
    }
    return null;
}

test "the statement end port agrees with sqlite3_complete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_][]const u8{
        "CREATE TABLE t(a)",
        "CREATE TABLE t(a);",
        "CREATE TABLE t(a) /* trailing */",
        "CREATE TABLE t(a) -- trailing",
        "CREATE TABLE t(a); -- trailing",
        "CREATE TABLE t(a); ATTACH DATABASE 'x' AS v",
        "CREATE TABLE t(a);;",
        "CREATE TABLE t(a, 'x;y')",
        "CREATE VIEW v AS SELECT 'a;b' FROM t",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; SELECT 2; END",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END; ATTACH DATABASE 'x' AS v",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END\x0b; ATTACH DATABASE 'x' AS v",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1",
        "CREATE TABLE t(a) /* unterminated",
        "CREATE TABLE t(a, 'x)",
        "CREATE TABLE t([x)",
    };
    for (cases) |sql| {
        const probe = try probeSql(arena, sql);
        try testing.expectEqual(try referenceCompleteEnd(arena, probe), completeEnd(probe));
    }
}
