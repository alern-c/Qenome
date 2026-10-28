const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const cli_args = @import("args.zig");
const cli_control = @import("control.zig");

pub const max_log_bytes: usize = 16 * 1024 * 1024;
pub const max_sql_bytes: usize = cli_args.max_sql_bytes;
pub const max_manifest_bytes: usize = 1024 * 1024;
pub const max_queries: usize = 100;
pub const record_marker = "QENOME_D1_RECORD ";

const record_version: i64 = 1;

const ExitCode = cli_control.ExitCode;

const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

const TokenKind = enum {
    word,
    number,
    string,
    blob,
    quoted,
    parameter,
    operator,
    punctuator,
    comment,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

const BindValue = union(enum) {
    int: i64,
    real: f64,
    text: []const u8,
    null: void,
};

const Query = struct {
    sql: []const u8,
    binds: []const BindValue,
    executions: u64,
};

const Skipped = struct {
    writes: u64 = 0,
    exec: u64 = 0,
    other: u64 = 0,
    blob: u64 = 0,
    unsupported: u64 = 0,
    nul: u64 = 0,
    large: u64 = 0,
    malformed: u64 = 0,
    version: u64 = 0,

    fn total(self: Skipped) u64 {
        return self.writes + self.exec + self.other + self.blob + self.unsupported + self.nul + self.large + self.malformed + self.version;
    }
};

const Collected = struct {
    records: u64 = 0,
    executions: u64 = 0,
    queries: []const Query = &.{},
    skipped: Skipped = .{},
};

const StatementKind = enum {
    read,
    write,
    other,
};

const ParsedRecord = struct {
    op: []const u8,
    sql: []const u8,
    binds: []const BindValue,
    blob: bool = false,
    unsupported: bool = false,
    nul: bool = false,
};

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    log_path: [:0]const u8,
    out_path: [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    var token_buffer: std.ArrayList(Token) = .empty;
    defer token_buffer.deinit(arena);
    var key_buffer: std.ArrayList(u8) = .empty;
    defer key_buffer.deinit(arena);

    const log = Io.Dir.cwd().readFileAllocOptions(io, log_path, arena, .limited(max_log_bytes + 1), .of(u8), 0) catch |err| {
        if (err == error.StreamTooLong) {
            stderr.print("error: the record log '{s}' is larger than 16 MiB; narrow the session or split the log\n", .{log_path}) catch {};
        } else {
            stderr.print("error: cannot read the record log '{s}': {s}\n", .{ log_path, cli_args.fileErrorMessage(err) }) catch {};
        }
        return .rejected;
    };
    if (log.len > max_log_bytes) {
        stderr.print("error: the record log '{s}' is larger than 16 MiB; narrow the session or split the log\n", .{log_path}) catch {};
        return .rejected;
    }

    const collected = collect(arena, log, &token_buffer, &key_buffer) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };

    if (collected.records == 0) {
        stderr.print("error: the record log '{s}' holds no readable records; check that the app used qenome/d1 and keep its output\n", .{log_path}) catch {};
        return .rejected;
    }
    if (collected.queries.len == 0) {
        stderr.writeAll("error: the record log holds no read-only statement to put in a manifest\n") catch {};
        printSkippedSummary(stderr, collected.skipped) catch {};
        return .rejected;
    }
    if (collected.queries.len > max_queries) {
        stderr.print(
            "error: the record log holds {d} distinct read-only statements; a manifest holds at most {d}; narrow the session or split the log\n",
            .{ collected.queries.len, max_queries },
        ) catch {};
        return .rejected;
    }

    const manifest = buildManifest(arena, collected.queries) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    if (manifest.len > max_manifest_bytes) {
        stderr.writeAll("error: the manifest would be larger than 1 MiB; narrow the session\n") catch {};
        return .rejected;
    }

    if (writeOutput(io, arena, out_path, collected.queries, manifest, stderr)) |failure| return failure;

    warnLogPermissions(io, log_path, stderr);
    printSummary(stdout, out_path, collected) catch {
        stderr.writeAll("error: the summary could not be written\n") catch {};
        return .rejected;
    };
    return .ok;
}

fn collect(
    arena: std.mem.Allocator,
    log: []const u8,
    token_buffer: *std.ArrayList(Token),
    key_buffer: *std.ArrayList(u8),
) !Collected {
    var collected: Collected = .{};
    var queries: std.ArrayList(Query) = .empty;
    var index: std.StringHashMap(usize) = .init(arena);
    defer index.deinit();

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, record_marker) orelse continue;
        collected.records += 1;
        const payload = std.mem.trimEnd(u8, line[at + record_marker.len ..], " \t\r");
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch {
            collected.skipped.malformed += 1;
            continue;
        };
        const object = switch (value) {
            .object => |object| object,
            else => {
                collected.skipped.malformed += 1;
                continue;
            },
        };
        const version = switch (object.get("v") orelse std.json.Value{ .null = {} }) {
            .integer => |number| number,
            else => {
                collected.skipped.malformed += 1;
                continue;
            },
        };
        if (version != record_version) {
            collected.skipped.version += 1;
            continue;
        }
        const record = parseRecord(arena, object) catch {
            collected.skipped.malformed += 1;
            continue;
        };
        if (record.nul) {
            collected.skipped.nul += 1;
            continue;
        }
        if (record.sql.len > max_sql_bytes) {
            collected.skipped.large += 1;
            continue;
        }
        if (std.mem.eql(u8, record.op, "exec")) {
            collected.skipped.exec += 1;
            continue;
        }
        if (record.blob) {
            collected.skipped.blob += 1;
            continue;
        }
        if (record.unsupported) {
            collected.skipped.unsupported += 1;
            continue;
        }

        token_buffer.clearRetainingCapacity();
        try tokenize(token_buffer, arena, record.sql);
        switch (classify(token_buffer.items)) {
            .read => {},
            .write => {
                collected.skipped.writes += 1;
                continue;
            },
            .other => {
                collected.skipped.other += 1;
                continue;
            },
        }

        key_buffer.clearRetainingCapacity();
        try tokenKey(arena, key_buffer, token_buffer.items);
        if (index.get(key_buffer.items)) |existing| {
            queries.items[existing].executions += 1;
            collected.executions += 1;
            continue;
        }
        const key = try arena.dupe(u8, key_buffer.items);
        try queries.append(arena, .{ .sql = record.sql, .binds = record.binds, .executions = 1 });
        try index.put(key, queries.items.len - 1);
        collected.executions += 1;
    }

    collected.queries = queries.items;
    return collected;
}

fn parseRecord(arena: std.mem.Allocator, object: std.json.ObjectMap) !ParsedRecord {
    const op = try objectString(object, "op");
    const sql = try objectString(object, "sql");
    if (sql.len == 0) return error.MalformedRecord;
    const types_value = object.get("types") orelse return error.MalformedRecord;
    const binds_value = object.get("binds") orelse return error.MalformedRecord;
    const types = switch (types_value) {
        .array => |array| array.items,
        else => return error.MalformedRecord,
    };
    const values = switch (binds_value) {
        .array => |array| array.items,
        else => return error.MalformedRecord,
    };
    if (types.len != values.len) return error.MalformedRecord;

    var binds: std.ArrayList(BindValue) = .empty;
    var blob = false;
    var unsupported = false;
    var nul = std.mem.indexOfScalar(u8, sql, 0) != null;
    for (types, values) |type_value, value| {
        const type_name = switch (type_value) {
            .string => |text| text,
            else => return error.MalformedRecord,
        };
        if (std.mem.eql(u8, type_name, "int")) {
            const number = switch (value) {
                .integer => |number| number,
                else => return error.MalformedRecord,
            };
            try binds.append(arena, .{ .int = number });
        } else if (std.mem.eql(u8, type_name, "real")) {
            const number: f64 = switch (value) {
                .float => |number| number,
                .integer => |number| @floatFromInt(number),
                else => return error.MalformedRecord,
            };
            if (!std.math.isFinite(number)) {
                unsupported = true;
                try binds.append(arena, .{ .null = {} });
            } else {
                try binds.append(arena, .{ .real = number });
            }
        } else if (std.mem.eql(u8, type_name, "text")) {
            const text = switch (value) {
                .string => |text| text,
                else => return error.MalformedRecord,
            };
            if (std.mem.indexOfScalar(u8, text, 0) != null) nul = true;
            try binds.append(arena, .{ .text = text });
        } else if (std.mem.eql(u8, type_name, "null")) {
            switch (value) {
                .null => {},
                else => return error.MalformedRecord,
            }
            try binds.append(arena, .{ .null = {} });
        } else if (std.mem.eql(u8, type_name, "blob")) {
            blob = true;
            try binds.append(arena, .{ .null = {} });
        } else if (std.mem.eql(u8, type_name, "other")) {
            unsupported = true;
            try binds.append(arena, .{ .null = {} });
        } else {
            return error.MalformedRecord;
        }
    }

    return .{
        .op = op,
        .sql = sql,
        .binds = binds.items,
        .blob = blob,
        .unsupported = unsupported,
        .nul = nul,
    };
}

fn isKnownOp(op: []const u8) bool {
    const known = [_][]const u8{ "all", "run", "first", "raw", "batch", "exec" };
    for (known) |name| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}

fn objectString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MalformedRecord;
    return switch (value) {
        .string => |text| text,
        else => error.MalformedRecord,
    };
}

fn tokenize(list: *std.ArrayList(Token), arena: std.mem.Allocator, sql: []const u8) !void {
    var index: usize = 0;
    if (std.mem.startsWith(u8, sql, "\xef\xbb\xbf")) index = 3;
    while (index < sql.len) {
        const at = index;
        const byte = sql[index];
        if (isSpace(byte)) {
            index += 1;
            continue;
        }
        if (byte == '-' and index + 1 < sql.len and sql[index + 1] == '-') {
            var end = index + 2;
            while (end < sql.len and sql[end] != '\n') : (end += 1) {}
            var text = sql[index..end];
            if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
            try list.append(arena, .{ .kind = .comment, .text = text });
            index = end;
            continue;
        }
        if (byte == '/' and index + 1 < sql.len and sql[index + 1] == '*') {
            var end = index + 2;
            while (end + 1 < sql.len and !(sql[end] == '*' and sql[end + 1] == '/')) : (end += 1) {}
            const stop = if (end + 1 < sql.len) end + 2 else sql.len;
            try list.append(arena, .{ .kind = .comment, .text = sql[index..stop] });
            index = stop;
            continue;
        }
        if ((byte == 'x' or byte == 'X') and index + 1 < sql.len and sql[index + 1] == '\'') {
            index = try scanQuoted(sql, index + 1, '\'');
            try list.append(arena, .{ .kind = .blob, .text = sql[at..index] });
            continue;
        }
        if (byte == '\'') {
            index = try scanQuoted(sql, index, '\'');
            try list.append(arena, .{ .kind = .string, .text = sql[at..index] });
            continue;
        }
        if (byte == '"' or byte == '`') {
            index = try scanQuoted(sql, index, byte);
            try list.append(arena, .{ .kind = .quoted, .text = sql[at..index] });
            continue;
        }
        if (byte == '[') {
            index += 1;
            while (index < sql.len and sql[index] != ']') : (index += 1) {}
            if (index < sql.len) index += 1;
            try list.append(arena, .{ .kind = .quoted, .text = sql[at..index] });
            continue;
        }
        if (byte == '?') {
            index += 1;
            while (index < sql.len and std.ascii.isDigit(sql[index])) : (index += 1) {}
            try list.append(arena, .{ .kind = .parameter, .text = sql[at..index] });
            continue;
        }
        if ((byte == ':' or byte == '@' or byte == '$') and index + 1 < sql.len and isWordStart(sql[index + 1])) {
            index += 2;
            while (index < sql.len and isWordChar(sql[index])) : (index += 1) {}
            try list.append(arena, .{ .kind = .parameter, .text = sql[at..index] });
            continue;
        }
        if (std.ascii.isDigit(byte)) {
            index = scanNumber(sql, index);
            try list.append(arena, .{ .kind = .number, .text = sql[at..index] });
            continue;
        }
        if (isWordStart(byte)) {
            index += 1;
            while (index < sql.len and isWordChar(sql[index])) : (index += 1) {}
            try list.append(arena, .{ .kind = .word, .text = sql[at..index] });
            continue;
        }
        if (operatorLength(sql[index..])) |length| {
            index += length;
            try list.append(arena, .{ .kind = .operator, .text = sql[at..index] });
            continue;
        }
        index += 1;
        try list.append(arena, .{ .kind = .punctuator, .text = sql[at..index] });
    }
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

fn isWordChar(byte: u8) bool {
    return isWordStart(byte) or std.ascii.isDigit(byte);
}

fn scanQuoted(sql: []const u8, open: usize, quote: u8) !usize {
    var index = open + 1;
    while (index < sql.len) {
        if (sql[index] != quote) {
            index += 1;
            continue;
        }
        if (index + 1 < sql.len and sql[index + 1] == quote) {
            index += 2;
            continue;
        }
        return index + 1;
    }
    return sql.len;
}

fn scanNumber(sql: []const u8, start: usize) usize {
    var index = start;
    if (index + 1 < sql.len and sql[index] == '0' and (sql[index + 1] == 'x' or sql[index + 1] == 'X')) {
        index += 2;
        while (index < sql.len) {
            const byte = sql[index];
            if (std.ascii.isHex(byte)) {
                index += 1;
                continue;
            }
            if (byte == '_' and index + 1 < sql.len and std.ascii.isHex(sql[index + 1])) {
                index += 1;
                continue;
            }
            break;
        }
        return index;
    }
    while (index < sql.len) {
        const byte = sql[index];
        if (std.ascii.isDigit(byte)) {
            index += 1;
            continue;
        }
        if (byte == '_' and index + 1 < sql.len and std.ascii.isDigit(sql[index + 1])) {
            index += 1;
            continue;
        }
        break;
    }
    if (index < sql.len and sql[index] == '.') {
        index += 1;
        while (index < sql.len) {
            const byte = sql[index];
            if (std.ascii.isDigit(byte)) {
                index += 1;
                continue;
            }
            if (byte == '_' and index + 1 < sql.len and std.ascii.isDigit(sql[index + 1])) {
                index += 1;
                continue;
            }
            break;
        }
    }
    if (index < sql.len and (sql[index] == 'e' or sql[index] == 'E')) {
        var exponent = index + 1;
        if (exponent < sql.len and (sql[exponent] == '+' or sql[exponent] == '-')) exponent += 1;
        if (exponent < sql.len and std.ascii.isDigit(sql[exponent])) {
            index = exponent + 1;
            while (index < sql.len) {
                const byte = sql[index];
                if (std.ascii.isDigit(byte)) {
                    index += 1;
                    continue;
                }
                if (byte == '_' and index + 1 < sql.len and std.ascii.isDigit(sql[index + 1])) {
                    index += 1;
                    continue;
                }
                break;
            }
        }
    }
    return index;
}

fn operatorLength(rest: []const u8) ?usize {
    const operators = [_][]const u8{
        "->>", "->", "||", "<<", ">>", "<=", ">=", "==", "!=", "<>", "!<", "!>",
        "+",   "-",  "*",  "/",  "%",  "=",  "<",  ">",  "&",  "|",  "~",
    };
    for (operators) |operator| {
        if (std.mem.startsWith(u8, rest, operator)) return operator.len;
    }
    return null;
}

fn tokenKey(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), tokens: []const Token) !void {
    for (tokens) |token| {
        try buffer.print(allocator, "{d}:{d}:", .{ @backingInt(token.kind), token.text.len });
        try buffer.appendSlice(allocator, token.text);
    }
}

fn classify(tokens: []const Token) StatementKind {
    const first_index = nextCode(tokens, 0) orelse return .other;
    const first = tokens[first_index];
    if (first.kind != .word) return .other;
    if (sameWord(first.text, "select") or sameWord(first.text, "values")) return .read;
    if (sameWord(first.text, "with")) return mainAfterCtes(tokens, first_index + 1);
    if (isWriteWord(first.text)) return .write;
    return .other;
}

fn isWriteWord(text: []const u8) bool {
    return sameWord(text, "insert") or
        sameWord(text, "update") or
        sameWord(text, "delete") or
        sameWord(text, "replace");
}

fn mainAfterCtes(tokens: []const Token, start: usize) StatementKind {
    var index = nextCode(tokens, start) orelse return .other;
    if (sameWord(tokens[index].text, "recursive")) {
        index = nextCode(tokens, index + 1) orelse return .other;
    }
    while (true) {
        if (!isName(tokens[index])) return .other;
        index = nextCode(tokens, index + 1) orelse return .other;
        if (isPunctuator(tokens[index], "(")) {
            index = skipParens(tokens, index) orelse return .other;
            index = nextCode(tokens, index) orelse return .other;
        }
        if (!sameWord(tokens[index].text, "as")) return .other;
        index = nextCode(tokens, index + 1) orelse return .other;
        if (sameWord(tokens[index].text, "not")) {
            index = nextCode(tokens, index + 1) orelse return .other;
            if (!sameWord(tokens[index].text, "materialized")) return .other;
            index = nextCode(tokens, index + 1) orelse return .other;
        } else if (sameWord(tokens[index].text, "materialized")) {
            index = nextCode(tokens, index + 1) orelse return .other;
        }
        if (!isPunctuator(tokens[index], "(")) return .other;
        index = skipParens(tokens, index) orelse return .other;
        index = nextCode(tokens, index) orelse return .other;
        if (isPunctuator(tokens[index], ",")) {
            index = nextCode(tokens, index + 1) orelse return .other;
            continue;
        }
        break;
    }
    if (tokens[index].kind != .word) return .other;
    if (sameWord(tokens[index].text, "select") or sameWord(tokens[index].text, "values")) return .read;
    if (isWriteWord(tokens[index].text)) return .write;
    return .other;
}

fn nextCode(tokens: []const Token, start: usize) ?usize {
    var index = start;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].kind != .comment) return index;
    }
    return null;
}

fn skipParens(tokens: []const Token, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (token.kind == .comment) continue;
        if (isPunctuator(token, "(")) {
            depth += 1;
            continue;
        }
        if (isPunctuator(token, ")")) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return index + 1;
        }
    }
    return null;
}

fn isName(token: Token) bool {
    return token.kind == .word or token.kind == .quoted or token.kind == .string;
}

fn isPunctuator(token: Token, text: []const u8) bool {
    return token.kind == .punctuator and std.mem.eql(u8, token.text, text);
}

fn sameWord(text: []const u8, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, word);
}

fn buildManifest(arena: std.mem.Allocator, queries: []const Query) ![]u8 {
    var out: Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("queries");
    try json.beginArray();
    for (queries, 0..) |query, position| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "queries/q{d:0>3}.sql", .{position + 1});
        try json.beginObject();
        try json.objectField("select");
        try json.write(name);
        if (query.binds.len != 0) {
            try json.objectField("binds");
            try json.beginArray();
            var bind_buffer: std.ArrayList(u8) = .empty;
            defer bind_buffer.deinit(arena);
            for (query.binds, 0..) |bind, bind_position| {
                bind_buffer.clearRetainingCapacity();
                try writeBind(&bind_buffer, arena, bind_position + 1, bind);
                try json.write(bind_buffer.items);
            }
            try json.endArray();
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}

fn writeBind(buffer: *std.ArrayList(u8), arena: std.mem.Allocator, number: usize, bind: BindValue) !void {
    switch (bind) {
        .int => |value| try buffer.print(arena, "{d}:int:{d}", .{ number, value }),
        .real => |value| try buffer.print(arena, "{d}:real:{d}", .{ number, value }),
        .text => |value| try buffer.print(arena, "{d}:text:{s}", .{ number, value }),
        .null => try buffer.print(arena, "{d}:null", .{number}),
    }
}

fn writeOutput(
    io: Io,
    arena: std.mem.Allocator,
    out_path: []const u8,
    queries: []const Query,
    manifest: []const u8,
    stderr: *Io.Writer,
) ?ExitCode {
    Io.Dir.cwd().createDir(io, out_path, dir_permissions) catch |err| {
        if (err == error.PathAlreadyExists) {
            stderr.print("error: the output directory '{s}' already exists; choose a new path\n", .{out_path}) catch {};
        } else {
            stderr.print("error: cannot create the output directory '{s}': {s}\n", .{ out_path, @errorName(err) }) catch {};
        }
        return .rejected;
    };
    var created = true;
    defer if (created) {
        Io.Dir.cwd().deleteTree(io, out_path) catch |err| {
            stderr.print("error: the output directory '{s}' could not be removed: {s}\n", .{ out_path, @errorName(err) }) catch {};
        };
    };

    const queries_path = std.fmt.allocPrint(arena, "{s}/queries", .{out_path}) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    Io.Dir.cwd().createDir(io, queries_path, dir_permissions) catch |err| {
        stderr.print("error: cannot create the output directory '{s}': {s}\n", .{ queries_path, @errorName(err) }) catch {};
        return .rejected;
    };

    for (queries, 0..) |query, position| {
        const path = std.fmt.allocPrint(arena, "{s}/queries/q{d:0>3}.sql", .{ out_path, position + 1 }) catch {
            stderr.writeAll("error: out of memory\n") catch {};
            return .rejected;
        };
        Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = query.sql,
            .flags = .{ .permissions = file_permissions },
        }) catch |err| {
            stderr.print("error: cannot write '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            return .rejected;
        };
    }

    const manifest_path = std.fmt.allocPrint(arena, "{s}/manifest.json", .{out_path}) catch {
        stderr.writeAll("error: out of memory\n") catch {};
        return .rejected;
    };
    Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = manifest,
        .flags = .{ .permissions = file_permissions },
    }) catch |err| {
        stderr.print("error: cannot write '{s}': {s}\n", .{ manifest_path, @errorName(err) }) catch {};
        return .rejected;
    };

    created = false;
    return null;
}

fn warnLogPermissions(io: Io, log_path: []const u8, stderr: *Io.Writer) void {
    if (builtin.os.tag == .windows) return;
    const stat = Io.Dir.cwd().statFile(io, log_path, .{}) catch return;
    const mode = stat.permissions.toMode() & 0o777;
    if (mode & 0o077 == 0) return;
    stderr.print(
        "warning: the record log '{s}' is readable by other users; create a new log with umask 077 and delete it after this run\n",
        .{log_path},
    ) catch {};
}

fn printSummary(stdout: *Io.Writer, out_path: []const u8, collected: Collected) !void {
    try stdout.print("record: {d} record lines\n", .{collected.records});
    try stdout.print("manifest: {s}/manifest.json\n", .{out_path});
    try stdout.print(
        "queries: {d} distinct read-only {s} ({d} {s})\n",
        .{
            collected.queries.len,
            if (collected.queries.len == 1) "statement" else "statements",
            collected.executions,
            if (collected.executions == 1) "execution" else "executions",
        },
    );
    for (collected.queries, 0..) |query, position| {
        try stdout.print("  queries/q{d:0>3}.sql  {d} execution{s}\n", .{ position + 1, query.executions, if (query.executions == 1) "" else "s" });
    }
    try printSkippedSummary(stdout, collected.skipped);
    try stdout.writeAll("warning: the manifest holds bind values; keep it local and do not commit it\n");
}

fn printSkippedSummary(writer: *Io.Writer, skipped: Skipped) !void {
    try writer.writeAll("skipped: ");
    if (skipped.total() == 0) {
        try writer.writeAll("none\n");
        return;
    }
    const labels = [_]struct { label: []const u8, count: u64 }{
        .{ .label = "writes", .count = skipped.writes },
        .{ .label = "exec", .count = skipped.exec },
        .{ .label = "other statements", .count = skipped.other },
        .{ .label = "blob binds", .count = skipped.blob },
        .{ .label = "unsupported binds", .count = skipped.unsupported },
        .{ .label = "NUL text", .count = skipped.nul },
        .{ .label = "large SQL", .count = skipped.large },
        .{ .label = "unreadable records", .count = skipped.malformed },
        .{ .label = "other versions", .count = skipped.version },
    };
    var first = true;
    for (labels) |entry| {
        if (entry.count == 0) continue;
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.print("{d} {s}", .{ entry.count, entry.label });
    }
    try writer.writeAll("\n");
}

const testing = std.testing;

fn tokenKeyOf(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    try tokenize(&tokens, allocator, sql);
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try tokenKey(allocator, &key, tokens.items);
    return key.toOwnedSlice(allocator);
}

fn expectSameKey(first: []const u8, second: []const u8) !void {
    const key_a = try tokenKeyOf(testing.allocator, first);
    defer testing.allocator.free(key_a);
    const key_b = try tokenKeyOf(testing.allocator, second);
    defer testing.allocator.free(key_b);
    try testing.expectEqualStrings(key_a, key_b);
}

fn expectDifferentKey(first: []const u8, second: []const u8) !void {
    const key_a = try tokenKeyOf(testing.allocator, first);
    defer testing.allocator.free(key_a);
    const key_b = try tokenKeyOf(testing.allocator, second);
    defer testing.allocator.free(key_b);
    try testing.expect(!std.mem.eql(u8, key_a, key_b));
}

test "the tokenizer makes whitespace outside strings and comments the same" {
    try expectSameKey("SELECT 1", "SELECT   1");
    try expectSameKey("SELECT ?+?", "SELECT ? + ?");
    try expectSameKey("SELECT 'a  b'", "SELECT 'a  b'");
    try expectSameKey("SELECT 1 -- x", "SELECT 1 -- x\n");
    try expectSameKey("SELECT 1 -- x\n", "SELECT 1 -- x\r\n");
    try expectSameKey("\xef\xbb\xbfSELECT 1", "SELECT 1");
    try expectSameKey("SELECT /* a */ 1", "SELECT /* a */ 1");
    try expectSameKey("SELECT a.b", "SELECT a . b");
}

test "the tokenizer keeps different SQLs apart" {
    try expectDifferentKey("SELECT x'4142' FROM (SELECT 7 AS x)", "SELECT x '4142' FROM (SELECT 7 AS x)");
    try expectDifferentKey("SELECT a || b", "SELECT a | | b");
    try expectDifferentKey("SELECT ?1", "SELECT ? 1");
    try expectDifferentKey("SELECT 1 -- x\n + 2", "SELECT 1 -- x + 2");
    try expectDifferentKey("SELECT `a``b`", "SELECT `a` `b`");
    try expectDifferentKey("SELECT 1_000", "SELECT 1 _000");
    try expectDifferentKey("SELECT 1", "SELECT 1 -- x");
    try expectDifferentKey("SELECT 1 -- x + 2", "SELECT 1 -- x +  2");
    try expectDifferentKey("SELECT 'a b'", "SELECT 'a  b'");
}

fn expectKind(sql: []const u8, expected: StatementKind) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(arena);
    try tokenize(&tokens, arena, sql);
    try testing.expectEqual(expected, classify(tokens.items));
}

test "the classifier finds the main statement" {
    try expectKind("SELECT 1", .read);
    try expectKind("  select 1", .read);
    try expectKind("SELECT(1)", .read);
    try expectKind("VALUES(1)", .read);
    try expectKind("WITH x AS(SELECT 1)SELECT*FROM x", .read);
    try expectKind("WITH replace AS (SELECT 1 AS n) SELECT * FROM replace", .read);
    try expectKind("WITH 'x' AS (SELECT 1 AS n) SELECT * FROM 'x'", .read);
    try expectKind("WITH RECURSIVE replace(n) AS (SELECT 1) SELECT * FROM replace", .read);
    try expectKind("WITH x AS (SELECT 1), y AS (SELECT 2) SELECT * FROM y", .read);
    try expectKind("WITH x AS NOT MATERIALIZED (SELECT 1) SELECT * FROM x", .read);
    try expectKind("WITH /* c */ replace /* c */ AS /* c */ (SELECT 1) SELECT * FROM replace", .read);
    try expectKind("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", .write);
    try expectKind("INSERT INTO t VALUES (1)", .write);
    try expectKind("UPDATE t SET a = 1", .write);
    try expectKind("DELETE FROM t", .write);
    try expectKind("REPLACE INTO t VALUES (1)", .write);
    try expectKind("PRAGMA foreign_keys = ON", .other);
    try expectKind("CREATE TABLE t(a)", .other);
    try expectKind("EXPLAIN SELECT 1", .other);
}

test "the collector groups the same SQL and keeps the first binds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(arena);
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(arena);

    const log =
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE id = ?\",\"types\":[\"int\"],\"binds\":[1]}\n" ++
        "[wrangler:info] QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT a FROM t WHERE id = ?\",\"types\":[\"int\"],\"binds\":[2]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"first\",\"sql\":\"SELECT  a FROM t WHERE id = ?\",\"types\":[\"int\"],\"binds\":[3]}\n";
    const collected = try collect(arena, log, &tokens, &key);
    try testing.expectEqual(@as(u64, 3), collected.records);
    try testing.expectEqual(@as(u64, 3), collected.executions);
    try testing.expectEqual(@as(usize, 1), collected.queries.len);
    try testing.expectEqual(@as(u64, 3), collected.queries[0].executions);
    try testing.expectEqualStrings("SELECT a FROM t WHERE id = ?", collected.queries[0].sql);
    try testing.expectEqual(BindValue{ .int = 1 }, collected.queries[0].binds[0]);
}

test "the collector counts what it does not put in the manifest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(arena);
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(arena);

    const log =
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"run\",\"sql\":\"INSERT INTO t VALUES (?)\",\"types\":[\"int\"],\"binds\":[1]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"exec\",\"sql\":\"CREATE TABLE t(a)\",\"types\":[],\"binds\":[]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"blob\"],\"binds\":[null]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"other\"],\"binds\":[true]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"PRAGMA foreign_keys\",\"types\":[],\"binds\":[]}\n" ++
        "QENOME_D1_RECORD {\"v\":2,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[],\"binds\":[]}\n" ++
        "QENOME_D1_RECORD not json\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT 1\",\"types\":[\"int\"],\"binds\":[]}\n" ++
        "plain output\n";
    const collected = try collect(arena, log, &tokens, &key);
    try testing.expectEqual(@as(u64, 8), collected.records);
    try testing.expectEqual(@as(usize, 0), collected.queries.len);
    try testing.expectEqual(@as(u64, 1), collected.skipped.writes);
    try testing.expectEqual(@as(u64, 1), collected.skipped.exec);
    try testing.expectEqual(@as(u64, 1), collected.skipped.blob);
    try testing.expectEqual(@as(u64, 1), collected.skipped.other);
    try testing.expectEqual(@as(u64, 1), collected.skipped.version);
    try testing.expectEqual(@as(u64, 2), collected.skipped.malformed);
    try testing.expectEqual(@as(u64, 1), collected.skipped.unsupported);
}

test "the collector refuses NUL text and reports a mismatch as unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(arena);
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(arena);

    const log =
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"text\"],\"binds\":[\"a\\u0000b\"]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"int\"],\"binds\":[\"x\"]}\n" ++
        "QENOME_D1_RECORD {\"v\":1,\"op\":\"all\",\"sql\":\"SELECT ?\",\"types\":[\"int\",\"int\"],\"binds\":[1]}\n";
    const collected = try collect(arena, log, &tokens, &key);
    try testing.expectEqual(@as(u64, 3), collected.records);
    try testing.expectEqual(@as(usize, 0), collected.queries.len);
    try testing.expectEqual(@as(u64, 1), collected.skipped.nul);
    try testing.expectEqual(@as(u64, 2), collected.skipped.malformed);
}

test "the manifest is a queries-only batch manifest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const queries = [_]Query{
        .{
            .sql = "SELECT a FROM t WHERE id = ?",
            .binds = &.{ .{ .int = 1 }, .{ .text = "a:b" } },
            .executions = 3,
        },
        .{ .sql = "SELECT count(*) FROM t", .binds = &.{}, .executions = 1 },
    };
    const manifest = try buildManifest(arena, &queries);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, manifest, .{});
    const root = switch (parsed) {
        .object => |object| object,
        else => return error.NotObject,
    };
    try testing.expectEqual(@as(usize, 1), root.count());
    const list = switch (root.get("queries").?) {
        .array => |array| array.items,
        else => return error.NotArray,
    };
    try testing.expectEqual(@as(usize, 2), list.len);
    const first = switch (list[0]) {
        .object => |object| object,
        else => return error.NotObject,
    };
    try testing.expectEqualStrings("queries/q001.sql", first.get("select").?.string);
    const binds = first.get("binds").?.array.items;
    try testing.expectEqual(@as(usize, 2), binds.len);
    try testing.expectEqualStrings("1:int:1", binds[0].string);
    try testing.expectEqualStrings("2:text:a:b", binds[1].string);
    const second = switch (list[1]) {
        .object => |object| object,
        else => return error.NotObject,
    };
    try testing.expect(second.get("binds") == null);
}

test "the output directory is private and the manifest is written once" {
    if (builtin.os.tag == .windows) return;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const out = try std.fmt.allocPrint(arena, "{s}/manifest-dir", .{base});

    const queries = [_]Query{.{ .sql = "SELECT 1", .binds = &.{}, .executions = 1 }};
    const manifest = try buildManifest(arena, &queries);
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    try testing.expect(writeOutput(testing.io, arena, out, &queries, manifest, &stderr) == null);

    const dir_stat = try Io.Dir.cwd().statFile(testing.io, out, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    const sql_stat = try Io.Dir.cwd().statFile(testing.io, try std.fmt.allocPrint(arena, "{s}/queries/q001.sql", .{out}), .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), sql_stat.permissions.toMode() & 0o777);
    const manifest_stat = try Io.Dir.cwd().statFile(testing.io, try std.fmt.allocPrint(arena, "{s}/manifest.json", .{out}), .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), manifest_stat.permissions.toMode() & 0o777);

    try testing.expect(writeOutput(testing.io, arena, out, &queries, manifest, &stderr) == .rejected);
    const unchanged = try Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(arena, "{s}/manifest.json", .{out}), arena, .limited(1024));
    try testing.expectEqualStrings(manifest, unchanged);
}
