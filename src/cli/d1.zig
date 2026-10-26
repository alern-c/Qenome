const std = @import("std");
const Io = std.Io;

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
};

pub const Outcome = union(enum) {
    resolved: Resolved,
    failure: Failure,
};

const Entry = struct {
    binding: ?[]const u8 = null,
    database_id: ?[]const u8 = null,
    preview_database_id: ?[]const u8 = null,
};

const Parse = union(enum) {
    entries: []const Entry,
    invalid: []const u8,
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
        .toml => try parseToml(allocator, text),
        .jsonc => try parseJsonc(allocator, text),
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

    var matched: ?*const Entry = null;
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

fn bindingList(allocator: std.mem.Allocator, entries: []const Entry) std.mem.Allocator.Error![]const u8 {
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

fn parseToml(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Parse {
    var entries: std.ArrayList(Entry) = .empty;
    var active: ?usize = null;
    const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var number: usize = 0;
    while (lines.next()) |raw_line| {
        number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const header = (try parseTableHeader(allocator, line)) orelse
                return invalidLine(allocator, number, "the table header is malformed");
            if (header.array and header.names.len == 1 and std.mem.eql(u8, header.names[0], "d1_databases")) {
                try entries.append(allocator, .{});
                active = entries.items.len - 1;
            } else {
                active = null;
            }
            continue;
        }
        const index = active orelse continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse
            return invalidLine(allocator, number, "expected key = value");
        var key_text = std.mem.trim(u8, line[0..equals], " \t");
        const key = (try parseKey(allocator, &key_text)) orelse
            return invalidLine(allocator, number, "the key is malformed");
        if (std.mem.trim(u8, key_text, " \t").len != 0) return invalidLine(allocator, number, "the key is malformed");
        const value_text = line[equals + 1 ..];
        const entry = &entries.items[index];
        if (std.mem.eql(u8, key, "binding")) {
            entry.binding = (try parseTomlValue(allocator, value_text)) orelse
                return invalidLine(allocator, number, "binding must be a quoted string");
        } else if (std.mem.eql(u8, key, "database_id")) {
            entry.database_id = (try parseTomlValue(allocator, value_text)) orelse
                return invalidLine(allocator, number, "database_id must be a quoted string");
        } else if (std.mem.eql(u8, key, "preview_database_id")) {
            entry.preview_database_id = (try parseTomlValue(allocator, value_text)) orelse
                return invalidLine(allocator, number, "preview_database_id must be a quoted string");
        }
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn invalidLine(allocator: std.mem.Allocator, number: usize, reason: []const u8) std.mem.Allocator.Error!Parse {
    return .{ .invalid = try std.fmt.allocPrint(allocator, "line {d}: {s}", .{ number, reason }) };
}

const TableHeader = struct {
    names: []const []const u8,
    array: bool,
};

fn parseTableHeader(allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!?TableHeader {
    if (line.len < 3) return null;
    var index: usize = 1;
    const array = line[index] == '[';
    if (array) index += 1;
    const start = index;
    var quote: u8 = 0;
    var close: ?usize = null;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote != 0) {
            if (byte == '\\' and quote == '"') {
                index += 1;
                continue;
            }
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == ']') {
            close = index;
            break;
        }
    }
    const close_index = close orelse return null;
    const inside = line[start..close_index];
    var rest_index = close_index + 1;
    if (array) {
        if (rest_index >= line.len or line[rest_index] != ']') return null;
        rest_index += 1;
    }
    const rest = std.mem.trim(u8, line[rest_index..], " \t");
    if (rest.len != 0 and rest[0] != '#') return null;
    const names = (try splitKeyPath(allocator, inside)) orelse return null;
    if (names.len == 0) return null;
    return .{ .names = names, .array = array };
}

fn splitKeyPath(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, text, " \t");
    if (rest.len == 0) return null;
    while (true) {
        const part = (try parseKey(allocator, &rest)) orelse return null;
        try parts.append(allocator, part);
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0) break;
        if (rest[0] != '.') return null;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        if (rest.len == 0) return null;
    }
    return try parts.toOwnedSlice(allocator);
}

fn parseKey(allocator: std.mem.Allocator, rest: *[]const u8) std.mem.Allocator.Error!?[]const u8 {
    const text = rest.*;
    if (text.len == 0) return null;
    if (text[0] == '"' or text[0] == '\'') {
        const quote = text[0];
        var index: usize = 1;
        while (index < text.len) : (index += 1) {
            if (quote == '"' and text[index] == '\\') {
                index += 1;
                continue;
            }
            if (text[index] == quote) break;
        }
        if (index >= text.len) return null;
        const raw = text[0 .. index + 1];
        rest.* = text[index + 1 ..];
        return try unquoteToml(allocator, raw);
    }
    var end: usize = 0;
    while (end < text.len and isBareKeyByte(text[end])) : (end += 1) {}
    if (end == 0) return null;
    rest.* = text[end..];
    return text[0..end];
}

fn isBareKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn parseTomlValue(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 2) return null;
    if (std.mem.startsWith(u8, trimmed, "\"\"\"") or std.mem.startsWith(u8, trimmed, "'''")) return null;
    const quote = trimmed[0];
    if (quote != '"' and quote != '\'') return null;
    var index: usize = 1;
    while (index < trimmed.len) : (index += 1) {
        if (quote == '"' and trimmed[index] == '\\') {
            index += 1;
            continue;
        }
        if (trimmed[index] == quote) break;
    }
    if (index >= trimmed.len) return null;
    const after = std.mem.trim(u8, trimmed[index + 1 ..], " \t");
    if (after.len != 0 and after[0] != '#') return null;
    return try unquoteToml(allocator, trimmed[0 .. index + 1]);
}

fn unquoteToml(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (raw.len < 2) return null;
    const quote = raw[0];
    if (raw[raw.len - 1] != quote) return null;
    const inner = raw[1 .. raw.len - 1];
    if (quote == '\'') return inner;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < inner.len) : (index += 1) {
        const byte = inner[index];
        if (byte != '\\') {
            try out.append(allocator, byte);
            continue;
        }
        index += 1;
        if (index >= inner.len) return null;
        switch (inner[index]) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0C),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u', 'U' => {
                const width: usize = if (inner[index] == 'u') 4 else 8;
                if (index + width >= inner.len) return null;
                const digits = inner[index + 1 .. index + 1 + width];
                for (digits) |digit| {
                    if (!std.ascii.isHex(digit)) return null;
                }
                const code = std.fmt.parseUnsigned(u32, digits, 16) catch return null;
                if (code > 0x10FFFF) return null;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(@intCast(code), &buffer) catch return null;
                try out.appendSlice(allocator, buffer[0..length]);
                index += width;
            },
            else => return null,
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseJsonc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Parse {
    const stripped = try stripJsonc(allocator, text);
    const cleaned = switch (stripped) {
        .cleaned => |cleaned| cleaned,
        .invalid => |reason| return .{ .invalid = reason },
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, cleaned, .{}) catch |err| {
        return .{ .invalid = try std.fmt.allocPrint(allocator, "the JSON is invalid ({s})", .{@errorName(err)}) };
    };
    const object = switch (value) {
        .object => |object| object,
        else => return .{ .invalid = "the top level is not a JSON object" },
    };
    const listed = object.get("d1_databases") orelse return .{ .entries = &.{} };
    const list = switch (listed) {
        .array => |array| array,
        else => return .{ .invalid = "\"d1_databases\" is not an array" },
    };
    var entries: std.ArrayList(Entry) = .empty;
    for (list.items, 0..) |item, at| {
        const item_object = switch (item) {
            .object => |item_object| item_object,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}] is not an object", .{at}) },
        };
        var entry: Entry = .{};
        if (item_object.get("binding")) |field| switch (field) {
            .string => |value_text| entry.binding = value_text,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}].binding is not a string", .{at}) },
        };
        if (item_object.get("database_id")) |field| switch (field) {
            .string => |value_text| entry.database_id = value_text,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}].database_id is not a string", .{at}) },
        };
        if (item_object.get("preview_database_id")) |field| switch (field) {
            .string => |value_text| entry.preview_database_id = value_text,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}].preview_database_id is not a string", .{at}) },
        };
        try entries.append(allocator, entry);
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

const Strip = union(enum) {
    cleaned: []const u8,
    invalid: []const u8,
};

fn stripJsonc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Strip {
    var uncommented: std.ArrayList(u8) = .empty;
    var index: usize = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) 3 else 0;
    var in_string = false;
    var escaped = false;
    while (index < text.len) {
        const byte = text[index];
        if (in_string) {
            try uncommented.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if (byte == '"') {
            in_string = true;
            try uncommented.append(allocator, byte);
            index += 1;
            continue;
        }
        if (byte == '/' and index + 1 < text.len) {
            if (text[index + 1] == '/') {
                index += 2;
                while (index < text.len and text[index] != '\n') index += 1;
                continue;
            }
            if (text[index + 1] == '*') {
                index += 2;
                while (index + 1 < text.len and !(text[index] == '*' and text[index + 1] == '/')) : (index += 1) {
                    if (text[index] == '\n') try uncommented.append(allocator, '\n');
                }
                if (index + 1 >= text.len) {
                    return .{ .invalid = "the block comment that starts with /* is not closed" };
                }
                index += 2;
                continue;
            }
        }
        try uncommented.append(allocator, byte);
        index += 1;
    }
    return .{ .cleaned = try stripTrailingCommas(allocator, uncommented.items) };
}

fn stripTrailingCommas(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    var escaped = false;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (in_string) {
            try out.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
            try out.append(allocator, byte);
            continue;
        }
        if (byte == ',') {
            var look = index + 1;
            while (look < text.len and std.ascii.isWhitespace(text[look])) : (look += 1) {}
            if (look < text.len and (text[look] == '}' or text[look] == ']')) continue;
        }
        try out.append(allocator, byte);
    }
    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

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

test "toml reads top-level d1_databases and ignores env tables" {
    const text =
        \\name = "app"
        \\# a comment
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_name = "app-db"
        \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        \\
        \\[[d1_databases]]
        \\binding = 'PREVIEW'
        \\preview_database_id = "11111111-2222-3333-4444-555555555555"
        \\
        \\[[env.production.d1_databases]]
        \\binding = "DB"
        \\database_id = "deadbeef-0000-0000-0000-000000000000"
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseToml(arena.allocator(), text);
    const entries = switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| {
            std.debug.print("invalid: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
    try testing.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", entries[0].database_id.?);
    try testing.expect(entries[0].preview_database_id == null);
    try testing.expectEqualStrings("PREVIEW", entries[1].binding.?);
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", entries[1].preview_database_id.?);
}

test "toml keeps a trailing comment and an escaped value" {
    const text =
        \\[[d1_databases]]   # the database
        \\binding = "DB"     # the binding
        \\database_id = "aaaa\u002dbbbb"
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseToml(arena.allocator(), text);
    const entries = switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| {
            std.debug.print("invalid: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
    try testing.expectEqualStrings("aaaa-bbbb", entries[0].database_id.?);
}

test "toml rejects a malformed d1 table" {
    const text =
        \\[[d1_databases]]
        \\binding DB
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseToml(arena.allocator(), text);
    switch (parsed) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.startsWith(u8, reason, "line 2:")),
    }
}

test "jsonc allows comments, trailing commas and comment-like text in strings" {
    const text =
        \\{
        \\  // the schema
        \\  "$schema": "node_modules/wrangler/config-schema.json",
        \\  /* d1 */
        \\  "name": "app",
        \\  "url": "https://example.com/a//b",
        \\  "d1_databases": [
        \\    {
        \\      "binding": "DB",
        \\      "database_name": "app-db",
        \\      "database_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        \\    },
        \\    {
        \\      "binding": "PREVIEW",
        \\      "preview_database_id": "11111111-2222-3333-4444-555555555555",
        \\    },
        \\  ],
        \\}
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseJsonc(arena.allocator(), text);
    const entries = switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| {
            std.debug.print("invalid: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
    try testing.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", entries[0].database_id.?);
    try testing.expectEqualStrings("PREVIEW", entries[1].binding.?);
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", entries[1].preview_database_id.?);
}

test "jsonc skips a byte order mark" {
    const text = "\xEF\xBB\xBF{\"d1_databases\":[{\"binding\":\"DB\",\"database_id\":\"x\"}]}";
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseJsonc(arena.allocator(), text);
    switch (parsed) {
        .entries => |entries| {
            try testing.expectEqual(@as(usize, 1), entries.len);
            try testing.expectEqualStrings("DB", entries[0].binding.?);
        },
        .invalid => return error.TestUnexpectedResult,
    }
}

test "jsonc rejects an unterminated block comment" {
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseJsonc(arena.allocator(), "{\"d1_databases\":[]} /* open");
    switch (parsed) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "not closed") != null),
    }
}

test "toml accepts a byte order mark and CRLF line endings" {
    const text = "\xEF\xBB\xBF[[d1_databases]]\r\nbinding = \"DB\"\r\ndatabase_id = \"x\"\r\n";
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseToml(arena.allocator(), text);
    const entries = switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| {
            std.debug.print("invalid: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
}

test "jsonc rejects a d1 entry that is not an object" {
    var arena = Arena.init();
    defer arena.deinit();
    const parsed = try parseJsonc(arena.allocator(), "{\"d1_databases\":[3]}");
    switch (parsed) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "d1_databases[0]") != null),
    }
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
