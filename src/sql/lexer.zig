const std = @import("std");

pub const TokenKind = enum {
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

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    start: usize,
    terminated: bool = true,
};

pub const Word = struct {
    text: []const u8,
    end: usize,
};

pub const Span = struct {
    end: usize,
    terminated: bool = true,
};

pub const Options = struct {
    vertical_tab_is_space: bool = true,
    dollar_is_word: bool = true,
};

pub const Lexer = struct {
    text: []const u8,
    index: usize = 0,
    options: Options = .{},

    pub fn init(text: []const u8) Lexer {
        return .{ .text = text };
    }

    pub fn initWith(text: []const u8, options: Options) Lexer {
        return .{ .text = text, .options = options };
    }

    pub fn next(self: *Lexer) ?Token {
        self.skipSpace();
        const text = self.text;
        if (self.index >= text.len) return null;
        const at = self.index;
        const byte = text[at];
        if (byte == '-' and at + 1 < text.len and text[at + 1] == '-') {
            return self.commentToken(at);
        }
        if (byte == '/' and at + 1 < text.len and text[at + 1] == '*') {
            return self.commentToken(at);
        }
        if ((byte == 'x' or byte == 'X') and at + 1 < text.len and text[at + 1] == '\'') {
            const span = quotedSpan(text, at + 1);
            self.index = span.end;
            return .{ .kind = .blob, .text = text[at..span.end], .start = at, .terminated = span.terminated };
        }
        if (byte == '\'') return self.quotedToken(at, .string);
        if (byte == '"' or byte == '`') return self.quotedToken(at, .quoted);
        if (byte == '[') return self.quotedToken(at, .quoted);
        if (byte == '?') {
            var end = at + 1;
            while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
            self.index = end;
            return .{ .kind = .parameter, .text = text[at..end], .start = at };
        }
        if ((byte == ':' or byte == '@' or byte == '$') and at + 1 < text.len and isWordStart(text[at + 1])) {
            var end = at + 2;
            while (end < text.len and wordContains(text[end], self.options.dollar_is_word)) : (end += 1) {}
            self.index = end;
            return .{ .kind = .parameter, .text = text[at..end], .start = at };
        }
        if (std.ascii.isDigit(byte)) {
            const end = numberEnd(text, at);
            self.index = end;
            return .{ .kind = .number, .text = text[at..end], .start = at };
        }
        if (isWordStart(byte)) {
            const end = wordEnd(text, at, self.options.dollar_is_word);
            self.index = end;
            return .{ .kind = .word, .text = text[at..end], .start = at };
        }
        if (operatorLength(text[at..])) |length| {
            self.index = at + length;
            return .{ .kind = .operator, .text = text[at..][0..length], .start = at };
        }
        self.index = at + 1;
        return .{ .kind = .punctuator, .text = text[at..][0..1], .start = at };
    }

    fn skipSpace(self: *Lexer) void {
        const text = self.text;
        while (self.index < text.len and isSpace(text[self.index])) {
            if (!self.options.vertical_tab_is_space and text[self.index] == 0x0b) return;
            self.index += 1;
        }
    }

    fn commentToken(self: *Lexer, at: usize) Token {
        const text = self.text;
        const span = commentSpan(text, at);
        self.index = span.end;
        var body = text[at..span.end];
        const line_comment = text[at] == '-' and at + 1 < text.len and text[at + 1] == '-';
        if (line_comment and body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
        return .{ .kind = .comment, .text = body, .start = at, .terminated = span.terminated };
    }

    fn quotedToken(self: *Lexer, at: usize, kind: TokenKind) Token {
        const span = quotedSpan(self.text, at);
        self.index = span.end;
        return .{ .kind = kind, .text = self.text[at..span.end], .start = at, .terminated = span.terminated };
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

pub fn isWordByte(byte: u8) bool {
    return isWordStart(byte) or std.ascii.isDigit(byte) or byte == '$';
}

pub fn wordAt(text: []const u8, start: usize) Word {
    const end = wordEnd(text, start, true);
    return .{ .text = text[start..end], .end = end };
}

fn wordEnd(text: []const u8, start: usize, dollar_is_word: bool) usize {
    var end = start;
    while (end < text.len and wordContains(text[end], dollar_is_word)) : (end += 1) {}
    return end;
}

fn wordContains(byte: u8, dollar_is_word: bool) bool {
    return isWordStart(byte) or std.ascii.isDigit(byte) or (dollar_is_word and byte == '$');
}

pub fn isQuote(byte: u8) bool {
    return byte == '\'' or byte == '"' or byte == '`' or byte == '[';
}

pub fn keywordAt(text: []const u8, start: usize) Word {
    var end = start;
    while (end < text.len and (std.ascii.isAlphabetic(text[end]) or text[end] == '_')) : (end += 1) {}
    return .{ .text = text[start..end], .end = end };
}

pub fn quotedSpan(text: []const u8, start: usize) Span {
    const close: u8 = switch (text[start]) {
        '"' => '"',
        '\'' => '\'',
        '`' => '`',
        '[' => ']',
        else => return .{ .end = start + 1 },
    };
    var index = start + 1;
    while (index < text.len) {
        if (text[index] != close) {
            index += 1;
            continue;
        }
        if (close != ']' and index + 1 < text.len and text[index + 1] == close) {
            index += 2;
            continue;
        }
        return .{ .end = index + 1 };
    }
    return .{ .end = text.len, .terminated = false };
}

pub fn commentSpan(text: []const u8, start: usize) Span {
    if (start + 1 >= text.len) return .{ .end = start + 1 };
    const limit = text.len - 1;
    if (text[start] == '-' and text[start + 1] == '-') {
        var index = start + 2;
        while (index < text.len and text[index] != '\n') : (index += 1) {}
        return .{ .end = index };
    }
    if (text[start] == '/' and text[start + 1] == '*') {
        var index = start + 2;
        while (index < limit and !(text[index] == '*' and text[index + 1] == '/')) : (index += 1) {}
        if (index < text.len and text[index] == '*' and index + 1 < text.len and text[index + 1] == '/') {
            return .{ .end = index + 2 };
        }
        return .{ .end = text.len, .terminated = false };
    }
    return .{ .end = start + 1 };
}

pub fn skipTrivia(text: []const u8, start: usize) usize {
    return skipTriviaWith(text, start, .{});
}

pub fn skipTriviaWith(text: []const u8, start: usize, options: Options) usize {
    var index = start;
    while (index < text.len) {
        if (isSpace(text[index]) and (options.vertical_tab_is_space or text[index] != 0x0b)) {
            index += 1;
            continue;
        }
        const opens_comment = (text[index] == '-' and index + 1 < text.len and text[index + 1] == '-') or
            (text[index] == '/' and index + 1 < text.len and text[index + 1] == '*');
        if (!opens_comment) break;
        index = commentSpan(text, index).end;
    }
    return index;
}

pub fn statementEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    while (index < text.len) {
        switch (text[index]) {
            ';' => return index,
            '\'', '"', '`', '[' => index = quotedSpan(text, index).end,
            '-', '/' => index = commentSpan(text, index).end,
            else => index += 1,
        }
    }
    return null;
}

fn numberEnd(text: []const u8, start: usize) usize {
    var index = start;
    if (index + 1 < text.len and text[index] == '0' and (text[index + 1] == 'x' or text[index + 1] == 'X')) {
        index += 2;
        while (index < text.len) {
            const byte = text[index];
            if (std.ascii.isHex(byte)) {
                index += 1;
                continue;
            }
            if (byte == '_' and index + 1 < text.len and std.ascii.isHex(text[index + 1])) {
                index += 1;
                continue;
            }
            break;
        }
        return index;
    }
    while (index < text.len) {
        const byte = text[index];
        if (std.ascii.isDigit(byte)) {
            index += 1;
            continue;
        }
        if (byte == '_' and index + 1 < text.len and std.ascii.isDigit(text[index + 1])) {
            index += 1;
            continue;
        }
        break;
    }
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len) {
            const byte = text[index];
            if (std.ascii.isDigit(byte)) {
                index += 1;
                continue;
            }
            if (byte == '_' and index + 1 < text.len and std.ascii.isDigit(text[index + 1])) {
                index += 1;
                continue;
            }
            break;
        }
    }
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        var exponent = index + 1;
        if (exponent < text.len and (text[exponent] == '+' or text[exponent] == '-')) exponent += 1;
        if (exponent < text.len and std.ascii.isDigit(text[exponent])) {
            index = exponent + 1;
            while (index < text.len) {
                const byte = text[index];
                if (std.ascii.isDigit(byte)) {
                    index += 1;
                    continue;
                }
                if (byte == '_' and index + 1 < text.len and std.ascii.isDigit(text[index + 1])) {
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

const testing = std.testing;

fn expectKinds(text: []const u8, expected: []const TokenKind) !void {
    var lexer: Lexer = .init(text);
    var collected: [32]TokenKind = undefined;
    var count: usize = 0;
    while (lexer.next()) |token| {
        try testing.expect(count < collected.len);
        collected[count] = token.kind;
        count += 1;
    }
    try testing.expectEqualSlices(TokenKind, expected, collected[0..count]);
}

test "the lexer reads every token kind" {
    try expectKinds("SELECT a$b, 1_000, 0xFF, 1.5e-3", &.{ .word, .word, .punctuator, .number, .punctuator, .number, .punctuator, .number });
    try expectKinds("x'4142' 'text' \"name\" `name` [name]", &.{ .blob, .string, .quoted, .quoted, .quoted });
    try expectKinds("?1 ? :name @name $name", &.{ .parameter, .parameter, .parameter, .parameter, .parameter });
    try expectKinds("a ->> b || c <> d !", &.{ .word, .operator, .word, .operator, .word, .operator, .word, .punctuator });
    try expectKinds("-- line\n/* block */ 1", &.{ .comment, .comment, .number });
}

test "a dollar can end a word where the caller asks" {
    var lexer: Lexer = .initWith("a$b $c", .{ .dollar_is_word = false });
    const first = lexer.next().?;
    try testing.expectEqualStrings("a", first.text);
    const second = lexer.next().?;
    try testing.expectEqual(TokenKind.parameter, second.kind);
    try testing.expectEqualStrings("$b", second.text);
    const third = lexer.next().?;
    try testing.expectEqual(TokenKind.parameter, third.kind);
    try testing.expectEqualStrings("$c", third.text);

    var legacy: Lexer = .initWith(":a$b @a$b $a$b", .{ .dollar_is_word = false });
    const expected = [_][]const u8{ ":a", "$b", "@a", "$b", "$a", "$b" };
    for (expected) |text| {
        try testing.expectEqualStrings(text, legacy.next().?.text);
    }
    try testing.expect(legacy.next() == null);

    var canonical: Lexer = .init(":a$b @a$b $a$b");
    const whole = [_][]const u8{ ":a$b", "@a$b", "$a$b" };
    for (whole) |text| {
        try testing.expectEqualStrings(text, canonical.next().?.text);
    }
    try testing.expect(canonical.next() == null);
}

test "the lexer treats sqlite whitespace as whitespace" {
    try expectKinds(" \t\r\n\x0b\x0c1", &.{.number});
    var lexer: Lexer = .initWith("1\x0b2", .{ .vertical_tab_is_space = false });
    const first = lexer.next().?;
    try testing.expectEqual(TokenKind.number, first.kind);
    const second = lexer.next().?;
    try testing.expectEqual(TokenKind.punctuator, second.kind);
    try testing.expectEqualStrings("\x0b", second.text);
}

test "the lexer keeps an unterminated span visible" {
    var lexer: Lexer = .init("'open");
    try testing.expect(!lexer.next().?.terminated);
    lexer = .init("/* open");
    const comment = lexer.next().?;
    try testing.expectEqual(TokenKind.comment, comment.kind);
    try testing.expect(!comment.terminated);
    lexer = .init("[open");
    try testing.expect(!lexer.next().?.terminated);
    lexer = .init("-- line");
    try testing.expect(lexer.next().?.terminated);
}

test "a line comment drops the carriage return and keeps the newline in the stream" {
    var lexer: Lexer = .init("-- x\r\n1");
    const comment = lexer.next().?;
    try testing.expectEqualStrings("-- x", comment.text);
    try testing.expectEqual(TokenKind.number, lexer.next().?.kind);
}

test "a block comment keeps a trailing carriage return" {
    var lexer: Lexer = .init("/* x\r");
    const comment = lexer.next().?;
    try testing.expectEqualStrings("/* x\r", comment.text);
    try testing.expect(!comment.terminated);
    lexer = .init("/* x */");
    try testing.expectEqualStrings("/* x */", lexer.next().?.text);
}

test "whitespace outside strings and comments does not change the token stream" {
    const pairs = [_][2][]const u8{
        .{ "SELECT 1", "SELECT   1" },
        .{ "SELECT ?+?", "SELECT ? + ?" },
        .{ "SELECT 'a  b'", "SELECT 'a  b'" },
        .{ "SELECT 1 -- x", "SELECT 1 -- x\n" },
        .{ "SELECT 1 -- x\n", "SELECT 1 -- x\r\n" },
        .{ "SELECT /* a */ 1", "SELECT /* a */ 1" },
        .{ "SELECT a.b", "SELECT a . b" },
    };
    for (pairs) |pair| {
        var first: Lexer = .init(pair[0]);
        var second: Lexer = .init(pair[1]);
        while (true) {
            const left = first.next();
            const right = second.next();
            if (left == null or right == null) {
                try testing.expect(left == null and right == null);
                break;
            }
            try testing.expectEqual(left.?.kind, right.?.kind);
            try testing.expectEqualStrings(left.?.text, right.?.text);
        }
    }
}

test "different SQL keeps a different token stream" {
    const pairs = [_][2][]const u8{
        .{ "SELECT x'4142' FROM (SELECT 7 AS x)", "SELECT x '4142' FROM (SELECT 7 AS x)" },
        .{ "SELECT a || b", "SELECT a | | b" },
        .{ "SELECT ?1", "SELECT ? 1" },
        .{ "SELECT 1 -- x\n + 2", "SELECT 1 -- x + 2" },
        .{ "SELECT `a``b`", "SELECT `a` `b`" },
        .{ "SELECT 1_000", "SELECT 1 _000" },
        .{ "SELECT 'a b'", "SELECT 'a  b'" },
    };
    for (pairs) |pair| {
        var first: Lexer = .init(pair[0]);
        var second: Lexer = .init(pair[1]);
        var same = true;
        while (true) {
            const left = first.next();
            const right = second.next();
            if (left == null or right == null) {
                same = left == null and right == null;
                break;
            }
            if (left.?.kind != right.?.kind or !std.mem.eql(u8, left.?.text, right.?.text)) {
                same = false;
                break;
            }
        }
        try testing.expect(!same);
    }
}

test "a word follows the sqlite identifier rule" {
    try testing.expectEqualStrings("a$b", wordAt("a$b c", 0).text);
    try testing.expectEqualStrings("c", wordAt("a$b c", 4).text);
    try testing.expectEqualStrings("\xc3\xa9t\xc3\xa9", wordAt("\xc3\xa9t\xc3\xa9 x", 0).text);
    try testing.expectEqualStrings("$x", wordAt("$x", 0).text);
    try testing.expectEqualStrings("CREATE", keywordAt("CREATE2 x", 0).text);
    try testing.expectEqualStrings("a", keywordAt("a$b", 0).text);
}

test "a quoted span keeps a doubled quote inside" {
    try testing.expectEqual(@as(usize, 6), quotedSpan("'a''b'", 0).end);
    try testing.expectEqual(@as(usize, 3), quotedSpan("[a]]", 0).end);
    try testing.expect(!quotedSpan("'a''b", 0).terminated);
}

test "skipTrivia follows the caller's whitespace rule" {
    try testing.expectEqual(@as(usize, 1), skipTriviaWith(" \x0by", 0, .{ .vertical_tab_is_space = false }));
    try testing.expectEqual(@as(usize, 0), skipTriviaWith("\x0b y", 0, .{ .vertical_tab_is_space = false }));
    try testing.expectEqual(@as(usize, 2), skipTriviaWith("\x0b y", 0, .{}));
}

test "skipTrivia crosses whitespace and comments" {
    try testing.expectEqual(@as(usize, 9), skipTrivia("  -- x\n  y", 0));
    try testing.expectEqual(@as(usize, 8), skipTrivia("/* a */ y", 0));
    try testing.expectEqual(@as(usize, 5), skipTrivia("/* a ", 0));
    try testing.expectEqual(@as(usize, 0), skipTrivia("y /* a */", 0));
    try testing.expectEqual(@as(usize, 2), skipTrivia(" \x0by", 0));
}

test "a statement ends at the top level semicolon" {
    try testing.expectEqual(@as(?usize, 1), statementEnd("a;b", 0));
    try testing.expectEqual(@as(?usize, null), statementEnd("a;b", 2));
    try testing.expectEqual(@as(?usize, 5), statementEnd("'a;b';c", 0));
    try testing.expectEqual(@as(?usize, 5), statementEnd("\"a;b\";c", 0));
    try testing.expectEqual(@as(?usize, 5), statementEnd("[a;b];c", 0));
    try testing.expectEqual(@as(?usize, 7), statementEnd("-- a;b\n;c", 0));
    try testing.expectEqual(@as(?usize, 8), statementEnd("/* a; */;c", 0));
    try testing.expectEqual(@as(?usize, null), statementEnd("/* a; ;", 0));
}
