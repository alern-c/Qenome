const std = @import("std");
const db = @import("../db.zig");
const sqlite = @import("../sqlite.zig");

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
        if (inspectSql(entry.sql)) |reason| {
            return .{ .rejected = .{ .name = entry.name, .reason = reason } };
        }
    }
    return .ok;
}

pub fn inspectSql(sql: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return "it contains a NUL byte";

    var statement_end = sql.len;
    if (completeEnd(sql)) |end| {
        if (!onlyTrivia(sql[end..])) return "it holds more than one statement";
        statement_end = end;
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

pub fn completeEnd(sql: []const u8) ?usize {
    var state: u8 = 0;
    var index: usize = 0;
    while (index < sql.len) {
        const token: u8 = switch (sql[index]) {
            ';' => 0,
            ' ', '\r', '\t', '\n', 0x0c => 1,
            '/' => blk: {
                if (index + 1 >= sql.len or sql[index + 1] != '*') break :blk 2;
                index += 2;
                while (index < sql.len and !(sql[index] == '*' and index + 1 < sql.len and sql[index + 1] == '/')) index += 1;
                if (index >= sql.len) return null;
                index += 1;
                break :blk 1;
            },
            '-' => blk: {
                if (index + 1 >= sql.len or sql[index + 1] != '-') break :blk 2;
                while (index < sql.len and sql[index] != '\n') index += 1;
                break :blk 1;
            },
            '[' => blk: {
                index += 1;
                while (index < sql.len and sql[index] != ']') index += 1;
                if (index >= sql.len) return null;
                break :blk 2;
            },
            '`', '"', '\'' => blk: {
                const quote = sql[index];
                index += 1;
                while (index < sql.len and sql[index] != quote) index += 1;
                if (index >= sql.len) return null;
                break :blk 2;
            },
            else => blk: {
                if (!isWordByte(sql[index])) break :blk 2;
                var end = index + 1;
                while (end < sql.len and isWordByte(sql[end])) end += 1;
                const token = wordToken(sql[index..end]);
                index = end - 1;
                break :blk token;
            },
        };
        state = transition[state][token];
        if (token == 0 and state == 1) return index + 1;
        index += 1;
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
            .code = "suggest_query_skipped",
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
            .code = "suggestions_truncated",
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
                .code = "suggestion_rejected",
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
        error.StatementNotCreateIndex => "the statement is not one CREATE INDEX",
    };
}

const Tokens = struct {
    text: []const u8,
    index: usize = 0,

    fn skipTrivia(self: *Tokens) void {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (isSpace(byte)) {
                self.index += 1;
                continue;
            }
            if (byte == '-' and self.index + 1 < self.text.len and self.text[self.index + 1] == '-') {
                self.index += 2;
                while (self.index < self.text.len and self.text[self.index] != '\n') self.index += 1;
                continue;
            }
            if (byte == '/' and self.index + 1 < self.text.len and self.text[self.index + 1] == '*') {
                self.index += 2;
                if (std.mem.indexOfPos(u8, self.text, self.index, "*/")) |close| {
                    self.index = close + 2;
                } else {
                    self.index = self.text.len;
                }
                continue;
            }
            break;
        }
    }

    fn nextWord(self: *Tokens) ?[]const u8 {
        while (true) {
            self.skipTrivia();
            if (self.index >= self.text.len) return null;
            const start = self.index;
            while (self.index < self.text.len and isWordByte(self.text[self.index])) self.index += 1;
            if (self.index != start) return self.text[start..self.index];
            if (isQuote(self.text[self.index])) {
                _ = self.quoted();
                continue;
            }
            self.index += 1;
        }
    }

    fn nextIdentifier(self: *Tokens) ?[]const u8 {
        self.skipTrivia();
        if (self.index >= self.text.len) return null;
        if (isQuote(self.text[self.index])) return self.quoted();
        const start = self.index;
        while (self.index < self.text.len and isWordByte(self.text[self.index])) self.index += 1;
        if (self.index == start) return null;
        return self.text[start..self.index];
    }

    fn quoted(self: *Tokens) ?[]const u8 {
        const close: u8 = switch (self.text[self.index]) {
            '"' => '"',
            '\'' => '\'',
            '`' => '`',
            '[' => ']',
            else => return null,
        };
        const start = self.index + 1;
        var index = start;
        while (index < self.text.len) {
            if (self.text[index] != close) {
                index += 1;
                continue;
            }
            if (close != ']' and index + 1 < self.text.len and self.text[index + 1] == close) {
                index += 2;
                continue;
            }
            self.index = index + 1;
            return self.text[start..index];
        }
        self.index = self.text.len;
        return null;
    }
};

fn onlyTrivia(text: []const u8) bool {
    var tokens: Tokens = .{ .text = text };
    tokens.skipTrivia();
    return tokens.index >= text.len;
}

fn allowedCreate(statement: []const u8) bool {
    var tokens: Tokens = .{ .text = statement };
    const first = tokens.nextWord() orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "CREATE")) return false;
    const second = tokens.nextWord() orelse return false;
    if (std.ascii.eqlIgnoreCase(second, "TABLE")) return true;
    if (std.ascii.eqlIgnoreCase(second, "INDEX")) return true;
    if (std.ascii.eqlIgnoreCase(second, "VIEW")) return true;
    if (std.ascii.eqlIgnoreCase(second, "TRIGGER")) return true;
    if (std.ascii.eqlIgnoreCase(second, "UNIQUE")) return isWord(tokens.nextWord(), "INDEX");
    if (std.ascii.eqlIgnoreCase(second, "VIRTUAL")) return isWord(tokens.nextWord(), "TABLE");
    return false;
}

fn usesExpertModule(statement: []const u8) bool {
    var tokens: Tokens = .{ .text = statement };
    if (!isWord(tokens.nextWord(), "CREATE")) return false;
    if (!isWord(tokens.nextWord(), "VIRTUAL")) return false;
    if (!isWord(tokens.nextWord(), "TABLE")) return false;

    const before_if = tokens.index;
    if (isWord(tokens.nextWord(), "IF")) {
        if (!isWord(tokens.nextWord(), "NOT")) return false;
        if (!isWord(tokens.nextWord(), "EXISTS")) return false;
    } else {
        tokens.index = before_if;
    }

    _ = tokens.nextIdentifier() orelse return false;
    tokens.skipTrivia();
    if (tokens.index < tokens.text.len and tokens.text[tokens.index] == '.') {
        tokens.index += 1;
        _ = tokens.nextIdentifier() orelse return false;
    }

    if (!isWord(tokens.nextWord(), "USING")) return false;
    const module = tokens.nextIdentifier() orelse return false;
    return std.ascii.eqlIgnoreCase(module, "expert");
}

fn isWord(value: ?[]const u8, expected: []const u8) bool {
    const word = value orelse return false;
    return std.ascii.eqlIgnoreCase(word, expected);
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c;
}

fn isQuote(byte: u8) bool {
    return byte == '"' or byte == '\'' or byte == '`' or byte == '[';
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
        "CREATE VIRTUAL TABLE t USING fts5(a)",
        "CREATE VIRTUAL TABLE using$foo USING fts5(a)",
        "CREATE VIRTUAL TABLE usingé USING fts5(a)",
        "CREATE VIRTUAL TABLE main.t USING fts5(a)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS t USING fts5(a)",
        "CREATE\nTABLE\nt(a)",
        "/* lead */ CREATE TABLE t(a)",
        "CREATE TABLE \"CREATE\"(a)",
    };
    for (accepted) |sql| {
        try testing.expectEqual(@as(?[]const u8, null), inspectSql(sql));
    }
}

test "the preflight rejects extra statements and non CREATE rows" {
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
    };
    for (cases) |case| {
        const reason = inspectSql(case.sql) orelse return error.ExpectedRejection;
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
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "CREATE VIEW v AS SELECT '");
    for (0..20000) |_| try text.append(testing.allocator, ';');
    try text.appendSlice(testing.allocator, "' FROM t");
    try testing.expectEqual(@as(?[]const u8, null), inspectSql(text.items));

    var trigger: std.ArrayList(u8) = .empty;
    defer trigger.deinit(testing.allocator);
    try trigger.appendSlice(testing.allocator, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN ");
    for (0..2000) |_| try trigger.appendSlice(testing.allocator, "UPDATE t SET a = a; ");
    try trigger.appendSlice(testing.allocator, "END");
    try testing.expectEqual(@as(?[]const u8, null), inspectSql(trigger.items));
}
