const std = @import("std");
const lexer = @import("lexer.zig");
const contract = @import("../contract/values.zig");
const model = @import("lint_model.zig");
const expr = @import("lint_expr.zig");

pub const PlanCheck = model.PlanCheck;
pub const Finding = model.Finding;

const Token = model.Token;
const Range = model.Range;
const Scope = model.Scope;
const Clause = model.Clause;
const ClauseStart = model.ClauseStart;
const Ctes = model.Ctes;
const isWord = model.isWord;
const isPunct = model.isPunct;
const skipNestedSelect = model.skipNestedSelect;
const appendFinding = model.appendFinding;
const rangeAfter = model.rangeAfter;

pub const Bound = struct {
    parameter: u64,
    text: ?[]const u8 = null,
    int: ?i64 = null,
};

pub fn isCode(value: []const u8) bool {
    for (contract.sql_warning_codes) |known| {
        if (std.mem.eql(u8, known, value)) return true;
    }
    return false;
}

const ParameterTable = struct {
    named: bool = false,
};

const Binding = struct {
    bounds: []const Bound,
    table: ParameterTable,
};

const Context = struct {
    indexed_by: bool = false,
    ctes: Ctes = .{ .names = &.{}, .unknown = false },
};

pub fn lint(allocator: std.mem.Allocator, sql: []const u8, binds: []const Bound) std.mem.Allocator.Error![]Finding {
    const tokens = try tokenize(allocator, sql);
    defer allocator.free(tokens);
    try assignParens(allocator, tokens);
    const scopes = try collectScopes(allocator, tokens);
    defer allocator.free(scopes);
    const write_scope = if (hasTopLevelSelect(tokens)) null else writeStatement(tokens);
    const starts = try allocator.alloc(ClauseStart, tokens.len);
    defer allocator.free(starts);
    const ctes = try expr.collectCtes(allocator, tokens);
    defer allocator.free(ctes.names);
    var bindings: Binding = .{
        .bounds = binds,
        .table = .{ .named = hasNamedParameter(tokens) },
    };
    assignParameters(tokens, bindings.table);
    const context: Context = .{ .indexed_by = hasIndexedBy(tokens), .ctes = ctes };
    var found: std.ArrayList(Finding) = .empty;
    errdefer found.deinit(allocator);
    for (scopes) |scope| {
        const count = clauseStarts(tokens, scope, starts);
        try analyzeScope(allocator, tokens, scope, starts[0..count], &bindings, context, &found);
    }
    if (write_scope) |scope| {
        const count = clauseStarts(tokens, scope, starts);
        try analyzeScope(allocator, tokens, scope, starts[0..count], &bindings, context, &found);
    }
    std.mem.sort(Finding, found.items, {}, findingLessThan);
    return found.toOwnedSlice(allocator);
}

fn findingLessThan(_: void, left: Finding, right: Finding) bool {
    return left.offset < right.offset;
}

fn tokenize(allocator: std.mem.Allocator, sql: []const u8) std.mem.Allocator.Error![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    var source: lexer.Lexer = .init(sql);
    var depth: u32 = 0;
    while (source.next()) |raw| {
        if (raw.kind == .comment) continue;
        var token_depth = depth;
        if (raw.kind == .punctuator) {
            if (std.mem.eql(u8, raw.text, "(")) {
                token_depth = depth;
                depth += 1;
            } else if (std.mem.eql(u8, raw.text, ")")) {
                token_depth = if (depth == 0) 0 else depth - 1;
                depth -|= 1;
            }
        }
        try tokens.append(allocator, .{
            .kind = raw.kind,
            .text = raw.text,
            .start = raw.start,
            .depth = token_depth,
        });
    }
    return tokens.toOwnedSlice(allocator);
}

fn assignParens(allocator: std.mem.Allocator, tokens: []Token) std.mem.Allocator.Error!void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);
    for (tokens, 0..) |token, index| {
        if (!isPunct(token, "(") and !isPunct(token, ")")) continue;
        if (isPunct(token, "(")) {
            try stack.append(allocator, index);
            continue;
        }
        const open = stack.pop() orelse continue;
        tokens[open].close = @intCast(index);
    }
}

fn hasNamedParameter(tokens: []const Token) bool {
    for (tokens) |token| {
        if (token.kind == .parameter and token.text[0] != '?') return true;
    }
    return false;
}

fn assignParameters(tokens: []Token, table: ParameterTable) void {
    if (table.named) return;
    var largest: u64 = 0;
    for (tokens) |*token| {
        if (token.kind != .parameter) continue;
        if (token.text.len == 1) {
            largest += 1;
            token.parameter = largest;
            continue;
        }
        const number = std.fmt.parseUnsigned(u64, token.text[1..], 10) catch {
            token.parameter = 0;
            continue;
        };
        token.parameter = number;
        if (number > largest) largest = number;
    }
}

fn hasIndexedBy(tokens: []const Token) bool {
    for (tokens, 0..) |token, index| {
        if (token.kind != .word or !isWord(token, "indexed")) continue;
        if (index + 1 >= tokens.len) continue;
        if (isWord(tokens[index + 1], "by")) return true;
    }
    return false;
}

fn hasTopLevelSelect(tokens: []const Token) bool {
    for (tokens) |token| {
        if (token.depth == 0 and token.kind == .word and isWord(token, "select")) return true;
    }
    return false;
}

fn collectScopes(allocator: std.mem.Allocator, tokens: []const Token) std.mem.Allocator.Error![]Scope {
    var scopes: std.ArrayList(Scope) = .empty;
    errdefer scopes.deinit(allocator);
    for (tokens, 0..) |token, index| {
        if (token.kind != .word or !isWord(token, "select")) continue;
        var end = tokens.len;
        var at = index + 1;
        while (at < tokens.len) {
            const current = tokens[at];
            if (current.depth < token.depth or isPunct(current, ";")) {
                end = at;
                break;
            }
            if (current.depth != token.depth) {
                at += 1;
                continue;
            }
            if (isWord(current, "select") or isWord(current, "union") or
                isWord(current, "intersect") or isWord(current, "except"))
            {
                end = at;
                break;
            }
            if (isPunct(current, "(") and current.close != 0) {
                at = current.close + 1;
                continue;
            }
            at += 1;
        }
        try scopes.append(allocator, .{ .select = index, .end = end, .depth = token.depth });
    }
    return scopes.toOwnedSlice(allocator);
}

fn writeStatement(tokens: []const Token) ?Scope {
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (token.depth != 0 or token.kind != .word) continue;
        if (isWord(token, "select")) return null;
        if (!isWord(token, "insert") and !isWord(token, "update") and
            !isWord(token, "delete") and !isWord(token, "replace"))
        {
            continue;
        }
        var end = tokens.len;
        for (tokens[index..], index..) |current, at| {
            if (isPunct(current, ";")) {
                end = at;
                break;
            }
        }
        return .{ .select = index, .end = end, .depth = 0, .kind = .write };
    }
    return null;
}

fn clauseStarts(tokens: []const Token, scope: Scope, buffer: []ClauseStart) usize {
    var count: usize = 0;
    var index = scope.select + 1;
    while (index < scope.end) {
        const token = tokens[index];
        if (token.depth == scope.depth and isPunct(token, "(") and token.close != 0) {
            index = token.close + 1;
            continue;
        }
        const next = index + 1;
        if (token.depth == scope.depth and token.kind == .word) {
            var clause: ?Clause = null;
            var body = next;
            if (isWord(token, "from")) {
                clause = .from;
            } else if (isWord(token, "where")) {
                clause = .where;
            } else if (isWord(token, "having")) {
                clause = .having;
            } else if (isWord(token, "limit")) {
                clause = .limit;
            } else if (isWord(token, "on")) {
                clause = .on;
            } else if (isWord(token, "order")) {
                if (index + 1 < scope.end and isWord(tokens[index + 1], "by")) {
                    clause = .order;
                    body = index + 2;
                }
            } else if (isWord(token, "group") or isWord(token, "window")) {
                clause = .other;
            } else if (isWord(token, "using")) {
                clause = .join;
            } else if (isJoinPrefix(tokens, index, scope.end)) {
                clause = .join;
            }
            if (clause) |active| {
                if (count == buffer.len) return count;
                buffer[count] = .{ .index = index, .body = body, .clause = active };
                count += 1;
            }
        }
        index = next;
    }
    return count;
}

fn isJoinPrefix(tokens: []const Token, index: usize, end: usize) bool {
    if (!isWord(tokens[index], "left") and !isWord(tokens[index], "right") and
        !isWord(tokens[index], "inner") and !isWord(tokens[index], "cross") and
        !isWord(tokens[index], "natural") and !isWord(tokens[index], "full") and
        !isWord(tokens[index], "join"))
    {
        return false;
    }
    if (isWord(tokens[index], "join")) return true;
    var at = index + 1;
    if (at < end and isWord(tokens[at], "outer")) at += 1;
    if (isWord(tokens[index], "natural")) {
        while (at < end and (isWord(tokens[at], "left") or isWord(tokens[at], "right") or isWord(tokens[at], "inner") or isWord(tokens[at], "outer") or isWord(tokens[at], "cross"))) {
            at += 1;
        }
    }
    return at < end and isWord(tokens[at], "join");
}

fn writeTarget(tokens: []const Token, keyword: usize, end: usize) ?[]const u8 {
    var index = keyword + 1;
    if (isWord(tokens[keyword], "delete")) {
        if (index >= end or !isWord(tokens[index], "from")) return null;
        index += 1;
    } else {
        if (index < end and isWord(tokens[index], "or")) index += 2;
        if (isWord(tokens[keyword], "insert") or isWord(tokens[keyword], "replace")) {
            if (index >= end or !isWord(tokens[index], "into")) return null;
            index += 1;
        }
    }
    if (index >= end or tokens[index].kind != .word) return null;
    var name = tokens[index].text;
    index += 1;
    if (index + 1 < end and isPunct(tokens[index], ".")) {
        if (tokens[index + 1].kind != .word) return null;
        name = tokens[index + 1].text;
        index += 2;
    }
    if (index < end and isWord(tokens[index], "as")) {
        index += 1;
        if (index >= end or tokens[index].kind != .word) return null;
        name = tokens[index].text;
        index += 1;
    } else if (index < end and tokens[index].kind == .word and
        !isWord(tokens[index], "set") and !isWord(tokens[index], "where") and
        !isWord(tokens[index], "values") and !isWord(tokens[index], "select") and
        !isWord(tokens[index], "using") and !isWord(tokens[index], "on") and
        !isWord(tokens[index], "order") and !isWord(tokens[index], "limit"))
    {
        name = tokens[index].text;
        index += 1;
    }
    return name;
}

fn firstStart(starts: []const ClauseStart, fallback: usize) usize {
    if (starts.len == 0) return fallback;
    return starts[0].index;
}

fn analyzeScope(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    scope: Scope,
    starts: []const ClauseStart,
    bindings: *Binding,
    context: Context,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (scope.kind == .select) try checkSelectStar(allocator, tokens, scope, starts, found);
    const sources = if (scope.kind == .write)
        expr.writeSources(context.ctes, writeTarget(tokens, scope.select, scope.end))
    else
        expr.collectSources(tokens, scope, starts, context.ctes);
    var has_window = false;
    var scan = scope.select + 1;
    while (scan < scope.end) {
        const token = tokens[scan];
        if (token.depth == scope.depth and isPunct(token, "(") and token.close != 0) {
            scan = token.close + 1;
            continue;
        }
        if (token.depth == scope.depth and token.kind == .word and isWord(token, "over")) {
            has_window = true;
            break;
        }
        scan += 1;
    }
    for (starts, 0..) |start, index| {
        const range = rangeAfter(starts, scope, index);
        switch (start.clause) {
            .where => {
                try checkLeadingWildcard(allocator, tokens, range, bindings, found);
                if (!has_window and !context.indexed_by) try expr.checkFunctionOnColumn(allocator, tokens, range, sources, found);
                if (!has_window and !context.indexed_by) try expr.checkOrAcrossColumns(allocator, tokens, range, sources, found);
            },
            .having, .on => {
                try checkLeadingWildcard(allocator, tokens, range, bindings, found);
                if (!has_window and !context.indexed_by) try expr.checkFunctionOnColumn(allocator, tokens, range, sources, found);
            },
            .order => try checkOrderByRandom(allocator, tokens, range, found),
            .limit => try checkLargeOffset(allocator, tokens, range, bindings, found),
            else => {},
        }
    }
}

fn checkSelectStar(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    scope: Scope,
    starts: []const ClauseStart,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (scope.depth != 0) return;
    const end = firstStart(starts, scope.end);
    var index = scope.select + 1;
    while (index < end) : (index += 1) {
        const token = tokens[index];
        if (token.depth != scope.depth) continue;
        if (token.kind != .operator or !std.mem.eql(u8, token.text, "*")) continue;
        if (!isWildcardStar(tokens, scope.select, index, scope.depth)) continue;
        try appendFinding(allocator, found, .{
            .code = contract.code.select_star,
            .severity = contract.sql_warning_severity.info,
            .message = contract.sql_warning_messages.select_star,
            .offset = token.start,
        });
        return;
    }
}

fn isWildcardStar(tokens: []const Token, select: usize, star: usize, depth: u32) bool {
    var at = star;
    while (at > select) {
        at -= 1;
        const token = tokens[at];
        if (token.depth != depth) continue;
        if (token.kind == .word and
            (isWord(token, "select") or isWord(token, "distinct") or isWord(token, "all")))
        {
            return true;
        }
        if (isPunct(token, ",")) return true;
        if (isPunct(token, ".")) return true;
        return false;
    }
    return false;
}

fn checkLeadingWildcard(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    range: Range,
    bindings: *const Binding,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    var index = range.start;
    while (index < range.end) : (index += 1) {
        if (skipNestedSelect(tokens, index, range.end)) |next| {
            index = next - 1;
            continue;
        }
        const token = tokens[index];
        if (token.kind != .word) continue;
        const like = isWord(token, "like");
        if (!like and !isWord(token, "glob")) continue;
        if (index + 1 >= range.end) continue;
        const pattern = tokens[index + 1];
        if (pattern.depth != token.depth) continue;
        if (index + 2 < range.end and isWord(tokens[index + 2], "escape")) continue;
        var first: ?u8 = null;
        switch (pattern.kind) {
            .string => {
                if (pattern.text.len >= 2) first = pattern.text[1];
            },
            .parameter => {
                if (boundValue(pattern, bindings)) |value| {
                    if (value.text) |text| {
                        if (text.len != 0) first = text[0];
                    }
                }
            },
            else => {},
        }
        const byte = first orelse continue;
        const wildcard = if (like) byte == '%' or byte == '_' else byte == '*' or byte == '?';
        if (!wildcard) continue;
        try appendFinding(allocator, found, .{
            .code = contract.code.leading_wildcard_like,
            .severity = contract.sql_warning_severity.warning,
            .message = contract.sql_warning_messages.leading_wildcard_like,
            .offset = pattern.start,
        });
    }
}

fn checkOrderByRandom(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    range: Range,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    var index = range.start;
    while (index + 2 < range.end) : (index += 1) {
        if (skipNestedSelect(tokens, index, range.end)) |next| {
            index = next - 1;
            continue;
        }
        const token = tokens[index];
        if (token.kind != .word or !isWord(token, "random")) continue;
        if (!isPunct(tokens[index + 1], "(") or !isPunct(tokens[index + 2], ")")) continue;
        try appendFinding(allocator, found, .{
            .code = contract.code.order_by_random,
            .severity = contract.sql_warning_severity.warning,
            .message = contract.sql_warning_messages.order_by_random,
            .offset = token.start,
        });
        return;
    }
}

fn checkLargeOffset(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    range: Range,
    bindings: *const Binding,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (range.start >= range.end) return;
    const first = tokens[range.start];
    if (!isValueToken(first)) return;
    var offset_index: ?usize = null;
    var must_end = false;
    if (range.start + 1 < range.end and isPunct(tokens[range.start + 1], ",")) {
        offset_index = range.start;
    } else if (range.start + 1 < range.end and isWord(tokens[range.start + 1], "offset")) {
        if (range.start + 2 < range.end and isValueToken(tokens[range.start + 2])) {
            offset_index = range.start + 2;
            must_end = true;
        }
    }
    const at = offset_index orelse return;
    if (must_end and at + 1 != range.end) return;
    const value = integerValue(tokens[at], bindings) orelse return;
    if (value < 1000) return;
    try appendFinding(allocator, found, .{
        .code = contract.code.large_offset,
        .severity = contract.sql_warning_severity.warning,
        .message = contract.sql_warning_messages.large_offset,
        .offset = tokens[at].start,
    });
}

fn isValueToken(token: Token) bool {
    return token.kind == .number or token.kind == .parameter;
}

fn integerValue(token: Token, bindings: *const Binding) ?u64 {
    if (token.kind == .number) return parseInteger(token.text);
    if (token.kind != .parameter) return null;
    const value = boundValue(token, bindings) orelse return null;
    const number = value.int orelse return null;
    if (number < 0) return null;
    return @intCast(number);
}

fn parseInteger(text: []const u8) ?u64 {
    var buffer: [32]u8 = undefined;
    var length: usize = 0;
    var index: usize = 0;
    var base: u8 = 10;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        index = 2;
    }
    while (index < text.len) : (index += 1) {
        if (text[index] == '_') continue;
        if (length == buffer.len) return null;
        buffer[length] = text[index];
        length += 1;
    }
    if (length == 0) return null;
    return std.fmt.parseUnsigned(u64, buffer[0..length], base) catch null;
}

fn boundValue(token: Token, bindings: *const Binding) ?Bound {
    if (bindings.table.named or token.parameter == 0) return null;
    for (bindings.bounds) |bound| {
        if (bound.parameter == token.parameter) return bound;
    }
    return null;
}

test {
    _ = @import("lint_tests.zig");
}
