const std = @import("std");

pub const default_migrations_dir = "migrations";

pub const default_migrations_table = "d1_migrations";

pub const Entry = struct {
    binding: ?[]const u8 = null,
    database_id: ?[]const u8 = null,
    preview_database_id: ?[]const u8 = null,
    migrations_dir: ?[]const u8 = null,
    migrations_table: ?[]const u8 = null,
};

pub const Parse = union(enum) {
    entries: []const Entry,
    invalid: []const u8,
};

pub fn parseToml(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Parse {
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
        } else if (std.mem.eql(u8, key, "migrations_dir")) {
            entry.migrations_dir = (try parseTomlValue(allocator, value_text)) orelse
                return invalidLine(allocator, number, "migrations_dir must be a quoted string");
        } else if (std.mem.eql(u8, key, "migrations_table")) {
            entry.migrations_table = (try parseTomlValue(allocator, value_text)) orelse
                return invalidLine(allocator, number, "migrations_table must be a quoted string");
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

pub fn parseJsonc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Parse {
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
        if (item_object.get("migrations_dir")) |field| switch (field) {
            .string => |value_text| entry.migrations_dir = value_text,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}].migrations_dir is not a string", .{at}) },
        };
        if (item_object.get("migrations_table")) |field| switch (field) {
            .string => |value_text| entry.migrations_table = value_text,
            else => return .{ .invalid = try std.fmt.allocPrint(allocator, "d1_databases[{d}].migrations_table is not a string", .{at}) },
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

fn entriesOf(parsed: Parse) ![]const Entry {
    return switch (parsed) {
        .entries => |entries| entries,
        .invalid => |reason| {
            std.debug.print("invalid: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
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
    const entries = try entriesOf(try parseToml(arena.allocator(), text));
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
    const entries = try entriesOf(try parseToml(arena.allocator(), text));
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
    switch (try parseToml(arena.allocator(), text)) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.startsWith(u8, reason, "line 2:")),
    }
}

test "toml reads the migrations settings" {
    const text =
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_id = "x"
        \\migrations_dir = "db/migrations"
        \\migrations_table = "app_migrations"
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const entries = try entriesOf(try parseToml(arena.allocator(), text));
    try testing.expectEqualStrings("db/migrations", entries[0].migrations_dir.?);
    try testing.expectEqualStrings("app_migrations", entries[0].migrations_table.?);
}

test "toml rejects a migrations setting that is not a quoted string" {
    const text =
        \\[[d1_databases]]
        \\binding = "DB"
        \\migrations_dir = 3
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    switch (try parseToml(arena.allocator(), text)) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "migrations_dir") != null),
    }
}

test "jsonc reads the migrations settings" {
    const text =
        \\{
        \\  "d1_databases": [
        \\    { "binding": "DB", "database_id": "x", "migrations_dir": "db/migrations", "migrations_table": "app_migrations" },
        \\  ],
        \\}
        \\
    ;
    var arena = Arena.init();
    defer arena.deinit();
    const entries = try entriesOf(try parseJsonc(arena.allocator(), text));
    try testing.expectEqualStrings("db/migrations", entries[0].migrations_dir.?);
    try testing.expectEqualStrings("app_migrations", entries[0].migrations_table.?);
}

test "jsonc rejects a migrations setting that is not a string" {
    var arena = Arena.init();
    defer arena.deinit();
    switch (try parseJsonc(arena.allocator(), "{\"d1_databases\":[{\"binding\":\"DB\",\"migrations_table\":3}]}")) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "migrations_table") != null),
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
    const entries = try entriesOf(try parseJsonc(arena.allocator(), text));
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
    const entries = try entriesOf(try parseJsonc(arena.allocator(), text));
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
}

test "jsonc rejects an unterminated block comment" {
    var arena = Arena.init();
    defer arena.deinit();
    switch (try parseJsonc(arena.allocator(), "{\"d1_databases\":[]} /* open")) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "not closed") != null),
    }
}

test "toml accepts a byte order mark and CRLF line endings" {
    const text = "\xEF\xBB\xBF[[d1_databases]]\r\nbinding = \"DB\"\r\ndatabase_id = \"x\"\r\n";
    var arena = Arena.init();
    defer arena.deinit();
    const entries = try entriesOf(try parseToml(arena.allocator(), text));
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("DB", entries[0].binding.?);
}

test "jsonc rejects a d1 entry that is not an object" {
    var arena = Arena.init();
    defer arena.deinit();
    switch (try parseJsonc(arena.allocator(), "{\"d1_databases\":[3]}")) {
        .entries => return error.TestUnexpectedResult,
        .invalid => |reason| try testing.expect(std.mem.indexOf(u8, reason, "d1_databases[0]") != null),
    }
}
