const std = @import("std");
const lexer = @import("lexer.zig");

pub const Token = lexer.Token;

const Tag = enum(u8) {
    word = 1,
    quoted = 2,
    operator = 3,
    punctuator = 4,
    comment = 5,
    placeholder = 6,
    list = 7,
    literal = 8,
};

pub fn key(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), tokens: []const Token) !void {
    var index: usize = 0;
    var after_value = false;
    while (index < tokens.len) {
        const token = tokens[index];
        switch (token.kind) {
            .comment => {
                try segment(allocator, buffer, .comment, token.text);
                index += 1;
            },
            .word => {
                if (sameWord(token.text, "in")) {
                    if (openParen(tokens, index + 1)) |open| {
                        if (listEnd(tokens, open)) |end| {
                            try segment(allocator, buffer, .list, "");
                            after_value = true;
                            index = end;
                            continue;
                        }
                    }
                }
                try lowerSegment(allocator, buffer, token.text);
                after_value = true;
                index += 1;
            },
            .quoted => {
                try segment(allocator, buffer, .quoted, token.text);
                after_value = true;
                index += 1;
            },
            .operator => {
                if (isSign(token.text) and !after_value) {
                    if (numberAt(tokens, index + 1)) |number_index| {
                        try segment(allocator, buffer, .placeholder, "");
                        after_value = true;
                        index = number_index + 1;
                        continue;
                    }
                }
                try segment(allocator, buffer, .operator, token.text);
                after_value = false;
                index += 1;
            },
            .punctuator => {
                try segment(allocator, buffer, .punctuator, token.text);
                after_value = isClosing(token.text);
                index += 1;
            },
            .number, .string, .blob, .parameter => {
                try segment(allocator, buffer, .placeholder, "");
                after_value = true;
                index += 1;
            },
        }
    }
}

pub fn literalKey(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), tokens: []const Token) !void {
    var index: usize = 0;
    var after_value = false;
    while (index < tokens.len) {
        const token = tokens[index];
        switch (token.kind) {
            .comment => index += 1,
            .word => {
                after_value = true;
                index += 1;
            },
            .quoted => {
                after_value = true;
                index += 1;
            },
            .punctuator => {
                after_value = isClosing(token.text);
                index += 1;
            },
            .operator => {
                if (isSign(token.text) and !after_value) {
                    if (numberAt(tokens, index + 1)) |number_index| {
                        try literal(allocator, buffer, token.text, tokens[number_index].text);
                        after_value = true;
                        index = number_index + 1;
                        continue;
                    }
                }
                after_value = false;
                index += 1;
            },
            .number, .string, .blob => {
                try literal(allocator, buffer, "", token.text);
                after_value = true;
                index += 1;
            },
            .parameter => {
                after_value = true;
                index += 1;
            },
        }
    }
}

fn segment(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), tag: Tag, text: []const u8) !void {
    try buffer.print(allocator, "{d}:{d}:", .{ @backingInt(tag), text.len });
    try buffer.appendSlice(allocator, text);
}

fn lowerSegment(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), text: []const u8) !void {
    try buffer.print(allocator, "{d}:{d}:", .{ @backingInt(Tag.word), text.len });
    for (text) |byte| try buffer.append(allocator, std.ascii.toLower(byte));
}

fn literal(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), sign: []const u8, text: []const u8) !void {
    try buffer.print(allocator, "{d}:{d}:", .{ @backingInt(Tag.literal), sign.len + text.len });
    try buffer.appendSlice(allocator, sign);
    try buffer.appendSlice(allocator, text);
}

fn openParen(tokens: []const Token, start: usize) ?usize {
    if (start >= tokens.len) return null;
    return if (isPunctuator(tokens[start], "(")) start else null;
}

fn numberAt(tokens: []const Token, start: usize) ?usize {
    if (start >= tokens.len) return null;
    return if (tokens[start].kind == .number) start else null;
}

fn listEnd(tokens: []const Token, open: usize) ?usize {
    var index = open + 1;
    var count: usize = 0;
    var expect_value = true;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (token.kind == .comment) return null;
        if (isPunctuator(token, ")")) {
            if (count == 0 or expect_value) return null;
            return index + 1;
        }
        if (expect_value) {
            if (token.kind == .operator and isSign(token.text)) {
                const next = numberAt(tokens, index + 1) orelse return null;
                count += 1;
                expect_value = false;
                index = next;
                continue;
            }
            if (!isValue(token)) return null;
            count += 1;
            expect_value = false;
            continue;
        }
        if (!isPunctuator(token, ",")) return null;
        expect_value = true;
    }
    return null;
}

fn isValue(token: Token) bool {
    return switch (token.kind) {
        .number, .string, .blob, .parameter => true,
        else => false,
    };
}

fn isSign(text: []const u8) bool {
    return std.mem.eql(u8, text, "-") or std.mem.eql(u8, text, "+");
}

fn isClosing(text: []const u8) bool {
    return std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]");
}

fn isPunctuator(token: Token, text: []const u8) bool {
    return token.kind == .punctuator and std.mem.eql(u8, token.text, text);
}

fn sameWord(text: []const u8, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, word);
}

const testing = std.testing;

fn keyOf(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    var lex: lexer.Lexer = .initWith(sql, .{ .dollar_is_word = false });
    while (lex.next()) |token| try tokens.append(allocator, token);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    try key(allocator, &buffer, tokens.items);
    return buffer.toOwnedSlice(allocator);
}

fn literalsOf(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    var lex: lexer.Lexer = .initWith(sql, .{ .dollar_is_word = false });
    while (lex.next()) |token| try tokens.append(allocator, token);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    try literalKey(allocator, &buffer, tokens.items);
    return buffer.toOwnedSlice(allocator);
}

fn expectSameKey(first: []const u8, second: []const u8) !void {
    const key_a = try keyOf(testing.allocator, first);
    defer testing.allocator.free(key_a);
    const key_b = try keyOf(testing.allocator, second);
    defer testing.allocator.free(key_b);
    try testing.expectEqualStrings(key_a, key_b);
}

fn expectDifferentKey(first: []const u8, second: []const u8) !void {
    const key_a = try keyOf(testing.allocator, first);
    defer testing.allocator.free(key_a);
    const key_b = try keyOf(testing.allocator, second);
    defer testing.allocator.free(key_b);
    try testing.expect(!std.mem.eql(u8, key_a, key_b));
}

test "a value token becomes one placeholder" {
    try expectSameKey("SELECT a FROM t WHERE b = ?", "SELECT a FROM t WHERE b = 17");
    try expectSameKey("SELECT a FROM t WHERE b = ?", "SELECT a FROM t WHERE b = 'text'");
    try expectSameKey("SELECT a FROM t WHERE b = ?1", "SELECT a FROM t WHERE b = :id");
    try expectSameKey("SELECT a FROM t WHERE b = @id", "SELECT a FROM t WHERE b = $id");
    try expectSameKey("SELECT a FROM t WHERE b = x'4142'", "SELECT a FROM t WHERE b = 1.5e-3");
    try expectSameKey("SELECT a FROM t WHERE b = ?", "SELECT  a\tFROM t\nWHERE b = ?");
}

test "keyword case is folded and the other tokens stay" {
    try expectSameKey("select a from t where b = ?", "SELECT a FROM t WHERE b = ?");
    try expectDifferentKey("SELECT \"a\" FROM t", "SELECT \"b\" FROM t");
    try expectDifferentKey("SELECT a FROM t", "SELECT a FROM t2");
    try expectDifferentKey("SELECT a FROM t WHERE b > 1", "SELECT a FROM t WHERE b = 1");
    try expectDifferentKey("SELECT a FROM t WHERE b = 1", "SELECT a FROM t WHERE c = 1");
    try expectDifferentKey("SELECT a FROM t -- x", "SELECT a FROM t -- y");
    try expectSameKey("SELECT `a``b` FROM t", "SELECT `a``b` FROM t");
}

test "strings and comments keep their own digits and question marks" {
    try expectSameKey("SELECT '1' FROM t", "SELECT '2' FROM t");
    try expectSameKey("SELECT a FROM t WHERE b = '1'", "SELECT a FROM t WHERE b = 1");
    try expectDifferentKey("SELECT '?' FROM t", "SELECT '?' FROM t -- ?");
    try expectSameKey("SELECT '?' FROM t", "SELECT '?' FROM t");
    try expectDifferentKey("SELECT /* 1 */ a FROM t", "SELECT /* 2 */ a FROM t");
    try expectDifferentKey("SELECT 1 FROM t -- 1", "SELECT 1 FROM t -- 2");
}

test "an IN list of placeholders collapses to one list" {
    try expectSameKey("SELECT a FROM t WHERE b IN (?, ?)", "SELECT a FROM t WHERE b IN (?, ?, ?)");
    try expectSameKey("SELECT a FROM t WHERE b IN (?)", "SELECT a FROM t WHERE b IN (?1, :id, ?)");
    try expectSameKey("SELECT a FROM t WHERE b IN (1, 2)", "SELECT a FROM t WHERE b IN (?, ?)");
    try expectSameKey("SELECT a FROM t WHERE b IN ('a', 'b')", "SELECT a FROM t WHERE b IN (?, ?)");
    try expectSameKey("SELECT a FROM t WHERE b IN (-1, -2)", "SELECT a FROM t WHERE b IN (?, ?)");
    try expectSameKey("SELECT a FROM t WHERE b NOT IN (?, ?)", "SELECT a FROM t WHERE b NOT IN (?, ?)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?, ?)", "SELECT a FROM t WHERE c IN (?, ?)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?, ?)", "SELECT a FROM t WHERE b IN (SELECT 1)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?, ?)", "SELECT a FROM t WHERE b IN ((?))");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?)", "SELECT a FROM t WHERE b IN (?, 'x' || ?)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?)", "SELECT a FROM t WHERE b IN (?,)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?)", "SELECT a FROM t WHERE b IN (");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?)", "SELECT a FROM t WHERE b IN ()");
}

test "a binary operator after a collapsed list keeps the statements apart" {
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?) - 2", "SELECT a FROM t WHERE b IN (?) + 2");
    try expectSameKey("SELECT a FROM t WHERE b IN (?) - 2", "SELECT a FROM t WHERE b IN (?) - 3");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?) - 2", "SELECT a FROM t WHERE b IN (?) = -2");
}

test "a comment inside a collapsed list or a sign keeps the statements apart" {
    try expectDifferentKey("SELECT a FROM t WHERE b IN (1 /* first */)", "SELECT a FROM t WHERE b IN (2 /* second */)");
    try expectDifferentKey("SELECT a FROM t WHERE b = - /* first */ 1", "SELECT a FROM t WHERE b = - /* second */ 2");
    try expectDifferentKey("SELECT a FROM t WHERE b IN /* x */ (?, ?)", "SELECT a FROM t WHERE b IN /* y */ (?, ?)");
    try expectDifferentKey("SELECT a FROM t WHERE b IN (?, /* x */ ?)", "SELECT a FROM t WHERE b IN (?, ?)");
    try expectSameKey("SELECT a FROM t WHERE b = -1", "SELECT a FROM t WHERE b = -2");
}

test "a negative number is one placeholder but subtraction keeps the operator" {
    try expectSameKey("SELECT a FROM t WHERE b = -1", "SELECT a FROM t WHERE b = -2");
    try expectSameKey("SELECT a FROM t WHERE b = -1", "SELECT a FROM t WHERE b = ?");
    try expectSameKey("SELECT a FROM t WHERE b = +1", "SELECT a FROM t WHERE b = 1");
    try expectDifferentKey("SELECT a FROM t WHERE b - 1 = 0", "SELECT a FROM t WHERE b + 1 = 0");
    try expectSameKey("SELECT a FROM t WHERE b - 1 = 0", "SELECT a FROM t WHERE b - 2 = 0");
    try expectDifferentKey("SELECT a FROM t WHERE b = -1", "SELECT a FROM t WHERE b = -'a'");
    try expectDifferentKey("SELECT -1", "SELECT 1");
}

test "a limit and an offset keep their position" {
    try expectSameKey("SELECT a FROM t LIMIT ? OFFSET ?", "SELECT a FROM t LIMIT 10 OFFSET 20");
    try expectDifferentKey("SELECT a FROM t LIMIT ? OFFSET ?", "SELECT a FROM t LIMIT ?");
    try expectSameKey("SELECT a FROM t LIMIT -1", "SELECT a FROM t LIMIT -1");
}

test "the values key names the inlined literals and the signs" {
    const first = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b = 17");
    defer testing.allocator.free(first);
    const second = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b = 18");
    defer testing.allocator.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));

    const parameter = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b = ?");
    defer testing.allocator.free(parameter);
    try testing.expectEqualStrings("", parameter);

    const negative = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b = -1");
    defer testing.allocator.free(negative);
    const positive = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b = 1");
    defer testing.allocator.free(positive);
    try testing.expect(!std.mem.eql(u8, negative, positive));

    const one = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b IN (1, 2)");
    defer testing.allocator.free(one);
    const twelve = try literalsOf(testing.allocator, "SELECT a FROM t WHERE b IN (12)");
    defer testing.allocator.free(twelve);
    try testing.expect(!std.mem.eql(u8, one, twelve));
}
