const std = @import("std");
const Io = std.Io;
const sqlite = @import("../sqlite.zig");

pub const Pending = struct {
    binding: []const u8,
    names: []const []const u8,
};

pub const max_applied_names: usize = 10_000;

pub const max_directory_entries: usize = 10_000;

pub const max_name_bytes: usize = 4096;

const progress_opcodes: c_int = 1000;

const progress_budget: c_int = 1000;

pub fn find(
    io: Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    migrations_dir: []const u8,
    migrations_table: []const u8,
    local_path: []const u8,
    binding: []const u8,
) ?Pending {
    return detect(io, allocator, config_path, migrations_dir, migrations_table, local_path, binding) catch null;
}

fn detect(
    io: Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    migrations_dir: []const u8,
    migrations_table: []const u8,
    local_path: []const u8,
    binding: []const u8,
) !?Pending {
    const directory = if (std.fs.path.isAbsolute(migrations_dir))
        try allocator.dupe(u8, migrations_dir)
    else
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(config_path) orelse ".", migrations_dir });
    const files = try migrationFiles(io, allocator, directory);
    if (files.len == 0) return null;
    const applied = try appliedNames(allocator, migrations_table, local_path);
    var pending: std.ArrayList([]const u8) = .empty;
    for (files) |name| {
        if (isApplied(applied, name)) continue;
        try pending.append(allocator, name);
    }
    if (pending.items.len == 0) return null;
    return .{ .binding = binding, .names = try pending.toOwnedSlice(allocator) };
}

fn migrationFiles(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var directory = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
    defer directory.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = directory.iterate();
    var scanned: usize = 0;
    while (try entries.next(io)) |entry| {
        scanned += 1;
        if (scanned > max_directory_entries) return error.TooManyEntries;
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        if (entry.name.len > max_name_bytes) return error.NameTooLong;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    const files = try names.toOwnedSlice(allocator);
    std.mem.sort([]const u8, files, {}, fileLessThan);
    return files;
}

fn appliedNames(allocator: std.mem.Allocator, table: []const u8, local_path: []const u8) ![]const []const u8 {
    const path = try allocator.dupeSentinel(u8, local_path, 0);
    var handle: ?*sqlite.sqlite3 = null;
    const rc = sqlite.sqlite3_open_v2(path.ptr, &handle, sqlite.SQLITE_OPEN_READONLY, null);
    const connection = handle orelse return error.DatabaseUnavailable;
    defer _ = sqlite.sqlite3_close(connection);
    if (rc != sqlite.SQLITE_OK) return error.DatabaseUnavailable;
    _ = sqlite.sqlite3_limit(connection, sqlite.SQLITE_LIMIT_LENGTH, @intCast(max_name_bytes));
    const query = try tableQuery(allocator, table);
    var handle_statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(connection, query.ptr, -1, &handle_statement, null) != sqlite.SQLITE_OK) return error.TableUnavailable;
    const statement = handle_statement orelse return error.TableUnavailable;
    defer _ = sqlite.sqlite3_finalize(statement);
    var budget = progress_budget;
    sqlite.sqlite3_progress_handler(connection, progress_opcodes, budgetHandler, &budget);
    defer sqlite.sqlite3_progress_handler(connection, 0, null, null);
    var names: std.ArrayList([]const u8) = .empty;
    var rows: usize = 0;
    while (true) {
        switch (sqlite.sqlite3_step(statement)) {
            sqlite.SQLITE_ROW => {
                rows += 1;
                if (rows > max_applied_names) return error.TooManyNames;
                const text = sqlite.sqlite3_column_text(statement, 0) orelse continue;
                const length: usize = @intCast(sqlite.sqlite3_column_bytes(statement, 0));
                if (length > max_name_bytes) return error.NameTooLong;
                try names.append(allocator, try allocator.dupe(u8, text[0..length]));
            },
            sqlite.SQLITE_DONE => break,
            else => return error.StepFailed,
        }
    }
    return try names.toOwnedSlice(allocator);
}

fn budgetHandler(user_data: ?*anyopaque) callconv(.c) c_int {
    const budget: *c_int = @ptrCast(@alignCast(user_data orelse return 1));
    budget.* -= 1;
    return if (budget.* <= 0) 1 else 0;
}

fn tableQuery(allocator: std.mem.Allocator, table: []const u8) ![:0]u8 {
    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try text.writer.writeAll("SELECT name FROM \"");
    for (table) |byte| {
        try text.writer.writeByte(byte);
        if (byte == '"') try text.writer.writeByte(byte);
    }
    try text.writer.writeByte('"');
    return allocator.dupeSentinel(u8, text.written(), 0);
}

fn isApplied(applied: []const []const u8, name: []const u8) bool {
    for (applied) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn fileLessThan(_: void, left: []const u8, right: []const u8) bool {
    const left_number = leadingNumber(left);
    const right_number = leadingNumber(right);
    if (left_number != null and right_number != null) {
        if (left_number.? != right_number.?) return left_number.? < right_number.?;
    } else if (left_number != null) {
        return true;
    } else if (right_number != null) {
        return false;
    }
    return std.mem.lessThan(u8, left, right);
}

fn leadingNumber(name: []const u8) ?i64 {
    var start: usize = 0;
    while (start < name.len and std.ascii.isWhitespace(name[start])) : (start += 1) {}
    var end = start;
    if (end < name.len and (name[end] == '-' or name[end] == '+')) end += 1;
    const digits = end;
    while (end < name.len and std.ascii.isDigit(name[end])) : (end += 1) {}
    if (end == digits) return null;
    return std.fmt.parseInt(i64, name[start..end], 10) catch null;
}

const testing = std.testing;

fn writeDatabase(path: [:0]const u8, sql: [:0]const u8) !void {
    var handle: ?*sqlite.sqlite3 = null;
    const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE;
    if (sqlite.sqlite3_open_v2(path, &handle, flags, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    const connection = handle orelse return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_close(connection);
    if (sqlite.sqlite3_exec(connection, sql, null, null, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init(allocator: std.mem.Allocator, schema: [:0]const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
        errdefer allocator.free(root);
        if (schema.len != 0) {
            const path = try std.fs.path.joinZ(allocator, &.{ root, "local.sqlite" });
            defer allocator.free(path);
            try writeDatabase(path, schema);
        }
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn configPath(self: *Fixture, allocator: std.mem.Allocator) ![:0]u8 {
        return std.fs.path.joinZ(allocator, &.{ self.root, "wrangler.toml" });
    }

    fn localPath(self: *Fixture, allocator: std.mem.Allocator) ![:0]u8 {
        return std.fs.path.joinZ(allocator, &.{ self.root, "local.sqlite" });
    }

    fn addMigration(self: *Fixture, name: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "migrations");
        const path = try std.fmt.allocPrint(testing.allocator, "migrations/{s}", .{name});
        defer testing.allocator.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "SELECT 1;" });
    }
};

const record_schema: [:0]const u8 =
    \\CREATE TABLE d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL);
;

const applied_schema: [:0]const u8 =
    record_schema ++
    \\INSERT INTO d1_migrations(name) VALUES ('0001_a.sql'), ('0004_d.sql');
    ;

test "the files the record table does not name are pending, in wrangler order" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, applied_schema);
    defer fixture.deinit(allocator);
    try fixture.addMigration("0010_j.sql");
    try fixture.addMigration("0004_d.sql");
    try fixture.addMigration("0002_b.sql");
    try fixture.addMigration("0010_j.txt");
    try fixture.addMigration("init.sql");
    try fixture.addMigration(".hidden.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const pending = find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB").?;
    try testing.expectEqualStrings("DB", pending.binding);
    try testing.expectEqual(@as(usize, 3), pending.names.len);
    try testing.expectEqualStrings("0002_b.sql", pending.names[0]);
    try testing.expectEqualStrings("0010_j.sql", pending.names[1]);
    try testing.expectEqualStrings("init.sql", pending.names[2]);
}

test "an empty migrations directory leaves nothing pending" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, record_schema);
    defer fixture.deinit(allocator);
    try fixture.tmp.dir.createDirPath(testing.io, "migrations");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a missing migrations directory is not an error" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, record_schema);
    defer fixture.deinit(allocator);
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a database without the record table is not an error" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, "CREATE TABLE t(a INTEGER);");
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a missing local database is not an error" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a custom record table is read and its name is escaped" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator,
        \\CREATE TABLE "weird""table"(name TEXT);
    );
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    try fixture.addMigration("0002_b.sql");
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var handle: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(local_path.ptr, &handle, sqlite.SQLITE_OPEN_READWRITE, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_close(handle);
    if (sqlite.sqlite3_exec(handle, "INSERT INTO \"weird\"\"table\"(name) VALUES ('0001_a.sql')", null, null, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const pending = find(testing.io, arena.allocator(), config_path, "migrations", "weird\"table", local_path, "DB").?;
    try testing.expectEqual(@as(usize, 1), pending.names.len);
    try testing.expectEqualStrings("0002_b.sql", pending.names[0]);
}

test "the search reads the local database without changing it" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, record_schema);
    defer fixture.deinit(allocator);
    try fixture.addMigration("0002_b.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    const before = try Io.Dir.cwd().readFileAlloc(testing.io, local_path, allocator, .unlimited);
    defer allocator.free(before);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const pending = find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB").?;
    try testing.expectEqual(@as(usize, 1), pending.names.len);
    const after = try Io.Dir.cwd().readFileAlloc(testing.io, local_path, allocator, .unlimited);
    defer allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "a record table past the bound is not read" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(
        allocator,
        record_schema ++ "\nINSERT INTO d1_migrations(name) WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 10001) SELECT 'm' || value FROM n;",
    );
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a record table of null names past the bound is not read" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(
        allocator,
        record_schema ++ "\nINSERT INTO d1_migrations(name) WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 10001) SELECT NULL FROM n;",
    );
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a record name past the bound is not read" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(
        allocator,
        record_schema ++ "\nINSERT INTO d1_migrations(name) SELECT printf('%.*c', 5000, 'x');",
    );
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "a record view with an oversized value is not read" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, "CREATE VIEW d1_migrations AS SELECT hex(zeroblob(3000)) AS name;");
    defer fixture.deinit(allocator);
    try fixture.addMigration("0001_a.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect(find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB") == null);
}

test "the order follows the leading number of wrangler, including a sign" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, record_schema);
    defer fixture.deinit(allocator);
    try fixture.addMigration("2_b.sql");
    try fixture.addMigration("+2_next.sql");
    try fixture.addMigration("0001_a.sql");
    try fixture.addMigration("-1_first.sql");
    try fixture.addMigration("init.sql");
    const config_path = try fixture.configPath(allocator);
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const pending = find(testing.io, arena.allocator(), config_path, "migrations", "d1_migrations", local_path, "DB").?;
    try testing.expectEqual(@as(usize, 5), pending.names.len);
    try testing.expectEqualStrings("-1_first.sql", pending.names[0]);
    try testing.expectEqualStrings("0001_a.sql", pending.names[1]);
    try testing.expectEqualStrings("+2_next.sql", pending.names[2]);
    try testing.expectEqualStrings("2_b.sql", pending.names[3]);
    try testing.expectEqualStrings("init.sql", pending.names[4]);
}

test "a migrations directory beside the config is resolved from the config path" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator, record_schema);
    defer fixture.deinit(allocator);
    try fixture.tmp.dir.createDirPath(testing.io, "project/db/migrations");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/db/migrations/0002_b.sql", .data = "SELECT 1;" });
    const config_path = try std.fs.path.joinZ(allocator, &.{ fixture.root, "project", "wrangler.toml" });
    defer allocator.free(config_path);
    const local_path = try fixture.localPath(allocator);
    defer allocator.free(local_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const pending = find(testing.io, arena.allocator(), config_path, "db/migrations", "d1_migrations", local_path, "DB").?;
    try testing.expectEqualStrings("0002_b.sql", pending.names[0]);
}
