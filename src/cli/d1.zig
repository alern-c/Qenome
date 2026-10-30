const std = @import("std");
const Io = std.Io;
const config = @import("../d1/config.zig");

pub const local_engine_sqlite_version = "3.53.4";

const namespace = "miniflare-D1DatabaseObject";

pub const config_names = [_][]const u8{ "wrangler.toml", "wrangler.jsonc", "wrangler.json" };

pub const max_config_bytes = 1024 * 1024;

pub const Kind = enum {
    config_not_found,
    config_ambiguous,
    config_unreadable,
    config_unsupported,
    config_invalid,
    binding_not_found,
    binding_ambiguous,
    database_id_missing,
    local_file_missing,
    local_file_unreadable,
};

pub const Failure = struct {
    kind: Kind,
    binding: []const u8 = "",
    config_path: []const u8 = "",
    local_path: []const u8 = "",
    detail: []const u8 = "",
    other: ?anyerror = null,
};

pub const Resolved = struct {
    binding: []const u8,
    config_path: []const u8,
    database_id: []const u8,
    local_path: []const u8,
    migrations_dir: []const u8,
    migrations_table: []const u8,
};

pub const Outcome = union(enum) {
    resolved: Resolved,
    failure: Failure,
};

const ConfigFormat = enum {
    toml,
    jsonc,
};

pub fn resolve(
    io: Io,
    allocator: std.mem.Allocator,
    base: Io.Dir,
    binding: []const u8,
    config_option: ?[]const u8,
) std.mem.Allocator.Error!Outcome {
    const config_path = if (config_option) |given| given else value: {
        const found = try discoverConfigs(io, allocator, base);
        if (found.unreadable) |problem| {
            return .{ .failure = .{
                .kind = .config_unreadable,
                .binding = binding,
                .config_path = problem.name,
                .other = problem.err,
            } };
        }
        if (found.names.len == 0) return .{ .failure = .{ .kind = .config_not_found, .binding = binding } };
        if (found.names.len > 1) {
            return .{ .failure = .{
                .kind = .config_ambiguous,
                .binding = binding,
                .detail = try std.mem.join(allocator, ", ", found.names),
            } };
        }
        break :value found.names[0];
    };

    const format = configFormat(config_path) orelse return .{ .failure = .{
        .kind = .config_unsupported,
        .binding = binding,
        .config_path = config_path,
    } };

    const text = base.readFileAllocOptions(
        io,
        config_path,
        allocator,
        .limited(max_config_bytes + 1),
        .of(u8),
        0,
    ) catch |err| {
        if (err == error.StreamTooLong) {
            return .{ .failure = .{
                .kind = .config_invalid,
                .binding = binding,
                .config_path = config_path,
                .detail = "the file is larger than 1 MiB",
            } };
        }
        return .{ .failure = .{
            .kind = .config_unreadable,
            .binding = binding,
            .config_path = config_path,
            .other = err,
        } };
    };

    const parsed = switch (format) {
        .toml => try config.parseToml(allocator, text),
        .jsonc => try config.parseJsonc(allocator, text),
    };
    const entries = switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| return .{ .failure = .{
            .kind = .config_invalid,
            .binding = binding,
            .config_path = config_path,
            .detail = reason,
        } },
    };

    var matched: ?*const config.Entry = null;
    var matches: usize = 0;
    for (entries) |*entry| {
        const name = entry.binding orelse continue;
        if (!std.mem.eql(u8, name, binding)) continue;
        matched = entry;
        matches += 1;
    }
    if (matches == 0) {
        return .{ .failure = .{
            .kind = .binding_not_found,
            .binding = binding,
            .config_path = config_path,
            .detail = try bindingList(allocator, entries),
        } };
    }
    if (matches > 1) {
        return .{ .failure = .{
            .kind = .binding_ambiguous,
            .binding = binding,
            .config_path = config_path,
            .detail = try std.fmt.allocPrint(allocator, "{d} entries use this name", .{matches}),
        } };
    }

    const entry = matched.?;
    const database_id = entry.preview_database_id orelse entry.database_id orelse return .{ .failure = .{
        .kind = .database_id_missing,
        .binding = binding,
        .config_path = config_path,
    } };

    const file_name = try localFileName(allocator, database_id);
    const local_path = try localDatabasePath(allocator, config_path, file_name);
    const file = base.openFile(io, local_path, .{}) catch |err| {
        return .{ .failure = .{
            .kind = if (err == error.FileNotFound) .local_file_missing else .local_file_unreadable,
            .binding = binding,
            .config_path = config_path,
            .local_path = local_path,
            .other = err,
        } };
    };
    file.close(io);

    return .{ .resolved = .{
        .binding = binding,
        .config_path = config_path,
        .database_id = database_id,
        .local_path = local_path,
        .migrations_dir = entry.migrations_dir orelse config.default_migrations_dir,
        .migrations_table = entry.migrations_table orelse config.default_migrations_table,
    } };
}

const Discovered = struct {
    names: []const []const u8,
    unreadable: ?struct { name: []const u8, err: anyerror } = null,
};

fn discoverConfigs(io: Io, allocator: std.mem.Allocator, base: Io.Dir) std.mem.Allocator.Error!Discovered {
    var names: std.ArrayList([]const u8) = .empty;
    for (config_names) |name| {
        const file = base.openFile(io, name, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            return .{ .names = &.{}, .unreadable = .{ .name = name, .err = err } };
        };
        file.close(io);
        try names.append(allocator, name);
    }
    return .{ .names = try names.toOwnedSlice(allocator) };
}

fn configFormat(path: []const u8) ?ConfigFormat {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".toml")) return .toml;
    if (std.mem.eql(u8, extension, ".jsonc")) return .jsonc;
    if (std.mem.eql(u8, extension, ".json")) return .jsonc;
    return null;
}

fn bindingList(allocator: std.mem.Allocator, entries: []const config.Entry) std.mem.Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        const name = entry.binding orelse continue;
        try names.append(allocator, name);
    }
    if (names.items.len == 0) return "the config has no top-level d1_databases entries";
    const joined = try std.mem.join(allocator, ", ", names.items);
    return std.fmt.allocPrint(allocator, "known bindings: {s}", .{joined});
}

pub fn localFileName(allocator: std.mem.Allocator, database_id: []const u8) std.mem.Allocator.Error![]const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var key: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(namespace, &key, .{});
    var first: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&first, database_id, &key);
    var second: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&second, first[0..16], &key);
    var id: [32]u8 = undefined;
    @memcpy(id[0..16], first[0..16]);
    @memcpy(id[16..], second[0..16]);
    const hex = std.fmt.bytesToHex(id, .lower);
    return std.fmt.allocPrint(allocator, "{s}.sqlite", .{hex});
}

pub fn localDatabasePath(allocator: std.mem.Allocator, config_path: []const u8, file_name: []const u8) std.mem.Allocator.Error![]const u8 {
    const directory = std.fs.path.dirname(config_path);
    if (directory == null or directory.?.len == 0) {
        return std.fs.path.join(allocator, &.{ ".wrangler", "state", "v3", "d1", namespace, file_name });
    }
    return std.fs.path.join(allocator, &.{ directory.?, ".wrangler", "state", "v3", "d1", namespace, file_name });
}

const testing = std.testing;

test {
    _ = @import("d1_tests.zig");
}

const Arena = struct {
    state: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Arena) void {
        self.state.deinit();
    }

    fn allocator(self: *Arena) std.mem.Allocator {
        return self.state.allocator();
    }
};

fn writeFactory(allocator: std.mem.Allocator, database_id: []const u8) ![]const u8 {
    const file_name = try localFileName(allocator, database_id);
    return std.fs.path.join(allocator, &.{ ".wrangler", "state", "v3", "d1", namespace, file_name });
}

fn addLocalDatabase(dir: Io.Dir, allocator: std.mem.Allocator, database_id: []const u8) !void {
    const path = try writeFactory(allocator, database_id);
    defer allocator.free(path);
    const directory = std.fs.path.dirname(path).?;
    try dir.createDirPath(testing.io, directory);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = "" });
}

test "the local file name is the one wrangler created" {
    const allocator = testing.allocator;
    const cases = [_]struct { database_id: []const u8, expected: []const u8 }{
        .{
            .database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            .expected = "b4b7ee9bc0328fad0039fd55bcee866dbb7978adad944643b49c9071c8746c37.sqlite",
        },
        .{
            .database_id = "11111111-2222-3333-4444-555555555555",
            .expected = "f023adf8de81e80d62670e09f086149af129cccda34c51f26517069258c53e8c.sqlite",
        },
    };
    for (cases) |case| {
        const actual = try localFileName(allocator, case.database_id);
        defer allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "the local path sits beside the config file" {
    const allocator = testing.allocator;
    const same = try localDatabasePath(allocator, "wrangler.toml", "x.sqlite");
    defer allocator.free(same);
    const same_expected = try std.fs.path.join(allocator, &.{ ".wrangler", "state", "v3", "d1", namespace, "x.sqlite" });
    defer allocator.free(same_expected);
    try testing.expectEqualStrings(same_expected, same);

    const elsewhere = try localDatabasePath(allocator, "../proj/wrangler.jsonc", "x.sqlite");
    defer allocator.free(elsewhere);
    const elsewhere_expected = try std.fs.path.join(
        allocator,
        &.{ std.fs.path.dirname("../proj/wrangler.jsonc").?, ".wrangler", "state", "v3", "d1", namespace, "x.sqlite" },
    );
    defer allocator.free(elsewhere_expected);
    try testing.expectEqualStrings(elsewhere_expected, elsewhere);
}

test "resolve finds the local database from a toml config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data =
        \\name = "app"
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        \\
    });
    try addLocalDatabase(tmp.dir, allocator, database_id);

    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    const resolved = switch (outcome) {
        .resolved => |resolved| resolved,
        .failure => |failure| {
            std.debug.print("failure: {t}\n", .{failure.kind});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("DB", resolved.binding);
    try testing.expectEqualStrings("wrangler.toml", resolved.config_path);
    try testing.expectEqualStrings(database_id, resolved.database_id);
    try testing.expectEqualStrings(config.default_migrations_dir, resolved.migrations_dir);
    try testing.expectEqualStrings(config.default_migrations_table, resolved.migrations_table);
    const expected = try writeFactory(allocator, database_id);
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, resolved.local_path);
}

test "resolve finds the local database from a jsonc config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const database_id = "11111111-2222-3333-4444-555555555555";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.jsonc", .data =
        \\{
        \\  // local development
        \\  "d1_databases": [
        \\    { "binding": "DB", "preview_database_id": "11111111-2222-3333-4444-555555555555" },
        \\  ],
        \\}
        \\
    });
    try addLocalDatabase(tmp.dir, allocator, database_id);

    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    const resolved = switch (outcome) {
        .resolved => |resolved| resolved,
        .failure => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("wrangler.jsonc", resolved.config_path);
    try testing.expectEqualStrings(database_id, resolved.database_id);
}

test "resolve keeps the migrations settings of the binding" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data =
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        \\migrations_dir = "db/migrations"
        \\migrations_table = "app_migrations"
        \\
    });
    try addLocalDatabase(tmp.dir, allocator, database_id);

    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    const resolved = switch (outcome) {
        .resolved => |resolved| resolved,
        .failure => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("db/migrations", resolved.migrations_dir);
    try testing.expectEqualStrings("app_migrations", resolved.migrations_table);
}

test "resolve uses the directory of an explicit config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "project");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/wrangler.json", .data =
        \\{"d1_databases":[{"binding":"DB","database_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","preview_database_id":"11111111-2222-3333-4444-555555555555"}]}
        \\
    });
    var project = try tmp.dir.openDir(testing.io, "project", .{});
    defer project.close(testing.io);
    try addLocalDatabase(project, allocator, "11111111-2222-3333-4444-555555555555");

    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", "project/wrangler.json");
    const resolved = switch (outcome) {
        .resolved => |resolved| resolved,
        .failure => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", resolved.database_id);
    const file_name = try localFileName(allocator, "11111111-2222-3333-4444-555555555555");
    const expected = try std.fs.path.join(allocator, &.{ "project", ".wrangler", "state", "v3", "d1", namespace, file_name });
    try testing.expectEqualStrings(expected, resolved.local_path);
}

test "resolve stops when there is no config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(Kind.config_not_found, failure.kind),
    }
}

test "resolve stops when two configs are present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data = "name = \"app\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.jsonc", .data = "{}\n" });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(Kind.config_ambiguous, failure.kind);
            try testing.expect(std.mem.indexOf(u8, failure.detail, "wrangler.toml") != null);
            try testing.expect(std.mem.indexOf(u8, failure.detail, "wrangler.jsonc") != null);
        },
    }
}

test "resolve stops when the binding is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data =
        \\[[d1_databases]]
        \\binding = "OTHER"
        \\database_id = "x"
        \\
    });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(Kind.binding_not_found, failure.kind);
            try testing.expect(std.mem.indexOf(u8, failure.detail, "OTHER") != null);
        },
    }
}

test "resolve stops when the binding appears twice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data =
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "a"
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "b"
        \\
    });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(Kind.binding_ambiguous, failure.kind),
    }
}

test "resolve stops when the binding has no database id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data =
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_name = "app-db"
        \\
    });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(Kind.database_id_missing, failure.kind),
    }
}

test "resolve stops when the local file does not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.jsonc", .data =
        \\{"d1_databases":[{"binding":"DB","database_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}
        \\
    });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", null);
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(Kind.local_file_missing, failure.kind),
    }
}

test "resolve reports an unsupported config extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.conf", .data = "{}" });
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", "wrangler.conf");
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(Kind.config_unsupported, failure.kind),
    }
}

test "resolve reports an unreadable explicit config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const outcome = try resolve(testing.io, allocator, tmp.dir, "DB", "wrangler.toml");
    switch (outcome) {
        .resolved => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(Kind.config_unreadable, failure.kind);
            try testing.expectEqualStrings("wrangler.toml", failure.config_path);
        },
    }
}
