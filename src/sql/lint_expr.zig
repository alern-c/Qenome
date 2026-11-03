const std = @import("std");
const contract = @import("../contract/values.zig");
const model = @import("lint_model.zig");

const Finding = model.Finding;
const Token = model.Token;
const Range = model.Range;
const Scope = model.Scope;
const ClauseStart = model.ClauseStart;
const Ctes = model.Ctes;
const rangeAfter = model.rangeAfter;
const isWord = model.isWord;
const isPunct = model.isPunct;
const isComparison = model.isComparison;
const isArithmetic = model.isArithmetic;
const isValueKeyword = model.isValueKeyword;
const isUnknownWord = model.isUnknownWord;
const isCteName = model.isCteName;
const skipNestedSelect = model.skipNestedSelect;
const matchingParen = model.matchingParen;
const appendFinding = model.appendFinding;

const SideKind = enum { plain, wrapped, literal, unknown };

const Side = struct {
    kind: SideKind,
    column: ?[]const u8 = null,
    qualifier: ?[]const u8 = null,
    wrap_offset: usize = 0,
};

fn classifySide(tokens: []const Token, range: Range) Side {
    var columns: usize = 0;
    var column: ?[]const u8 = null;
    var qualifier: ?[]const u8 = null;
    var wraps: usize = 0;
    var wrap_offset: usize = 0;
    var unknown = false;
    var index = range.start;
    while (index < range.end) : (index += 1) {
        const token = tokens[index];
        switch (token.kind) {
            .word => {
                if (isValueKeyword(token.text)) continue;
                if (isUnknownWord(token.text)) {
                    unknown = true;
                    continue;
                }
                const next = if (index + 1 < range.end) tokens[index + 1] else null;
                if (next != null and isPunct(next.?, "(") and next.?.depth == token.depth) {
                    wraps += 1;
                    if (wrap_offset == 0) wrap_offset = token.start;
                    continue;
                }
                if (next != null and isPunct(next.?, ".") and next.?.depth == token.depth) {
                    if (index + 2 < range.end and tokens[index + 2].kind == .word and tokens[index + 2].depth == token.depth) {
                        qualifier = token.text;
                    }
                    continue;
                }
                columns += 1;
                if (column == null) column = token.text;
            },
            .quoted => unknown = true,
            .operator => {
                if (isArithmetic(token.text)) {
                    wraps += 1;
                    if (wrap_offset == 0) wrap_offset = token.start;
                } else if (!std.mem.eql(u8, token.text, ".")) {
                    unknown = true;
                }
            },
            .punctuator => {
                if (isPunct(token, ".") or isPunct(token, "(") or isPunct(token, ")")) continue;
                unknown = true;
            },
            .number, .string, .blob, .parameter, .comment => {},
        }
    }
    if (unknown) return .{ .kind = .unknown };
    if (columns == 0) return .{ .kind = .literal };
    if (wraps != 0) return .{ .kind = .wrapped, .column = column, .qualifier = qualifier, .wrap_offset = wrap_offset };
    if (columns == 1) return .{ .kind = .plain, .column = column, .qualifier = qualifier };
    return .{ .kind = .unknown };
}

pub fn checkFunctionOnColumn(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    range: Range,
    sources: Sources,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (!sources.known) return;
    var index = range.start;
    while (index < range.end) : (index += 1) {
        if (skipNestedSelect(tokens, index, range.end)) |next| {
            index = next - 1;
            continue;
        }
        const token = tokens[index];
        if (token.kind != .operator or !isComparison(token.text)) continue;
        const left = classifySide(tokens, .{ .start = operandStart(tokens, range, index), .end = index });
        const right = classifySide(tokens, .{ .start = index + 1, .end = operandEnd(tokens, range, index) });
        var offset: ?usize = null;
        var qualifier: ?[]const u8 = null;
        if (left.kind == .wrapped and right.kind == .literal) {
            offset = left.wrap_offset;
            qualifier = left.qualifier;
        }
        if (right.kind == .wrapped and left.kind == .literal) {
            offset = right.wrap_offset;
            qualifier = right.qualifier;
        }
        const at = offset orelse continue;
        const table = if (qualifier) |name| blk: {
            if (!sources.matches(name)) continue;
            break :blk name;
        } else sources.single() orelse continue;
        try appendFinding(allocator, found, .{
            .code = contract.code.function_on_column,
            .severity = contract.sql_warning_severity.warning,
            .message = contract.sql_warning_messages.function_on_column,
            .offset = at,
            .table = table,
            .plan_check = .index_on_table,
        });
    }
}

fn operandStart(tokens: []const Token, range: Range, operator: usize) usize {
    const depth = tokens[operator].depth;
    var start = operator;
    while (start > range.start) {
        const token = tokens[start - 1];
        if (token.depth < depth) break;
        if (token.depth == depth and isOperandSeparator(token)) break;
        start -= 1;
    }
    return start;
}

fn operandEnd(tokens: []const Token, range: Range, operator: usize) usize {
    const depth = tokens[operator].depth;
    var end = operator + 1;
    while (end < range.end) {
        const token = tokens[end];
        if (token.depth < depth) break;
        if (token.depth == depth and isOperandSeparator(token)) break;
        end += 1;
    }
    return end;
}

fn isOperandSeparator(token: Token) bool {
    if (token.kind == .punctuator and isPunct(token, ",")) return true;
    if (token.kind == .operator and isComparison(token.text)) return true;
    if (token.kind != .word) return false;
    return isWord(token, "and") or isWord(token, "or") or isWord(token, "xor") or
        isWord(token, "where") or isWord(token, "on") or isWord(token, "having") or
        isWord(token, "order") or isWord(token, "group") or isWord(token, "limit") or
        isWord(token, "join") or isWord(token, "using") or isWord(token, "window");
}

pub fn checkOrAcrossColumns(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    range: Range,
    sources: Sources,
    found: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (!sources.known) return;
    const depth = minimumDepth(tokens, range) orelse return;
    var ors: [32]usize = undefined;
    var count: usize = 0;
    var scan = range.start;
    while (scan < range.end) {
        if (skipNestedSelect(tokens, scan, range.end)) |next| {
            scan = next;
            continue;
        }
        const token = tokens[scan];
        if (token.depth == depth and token.kind == .word and isWord(token, "or")) {
            if (count == ors.len) return;
            ors[count] = scan;
            count += 1;
        }
        scan += 1;
    }
    if (count == 0) return;
    var columns: [33]?[]const u8 = undefined;
    var qualifiers: [33]?[]const u8 = undefined;
    var branch_start = range.start;
    for (ors[0..count], 0..) |position, branch| {
        const column = branchColumn(tokens, .{ .start = branch_start, .end = position }, depth) orelse return;
        columns[branch] = column.column;
        qualifiers[branch] = column.qualifier;
        branch_start = position + 1;
    }
    const last = branchColumn(tokens, .{ .start = branch_start, .end = range.end }, depth) orelse return;
    columns[count] = last.column;
    qualifiers[count] = last.qualifier;
    const first = columns[0] orelse return;
    var differs = false;
    for (columns[1 .. count + 1]) |entry| {
        const text = entry orelse return;
        if (!std.ascii.eqlIgnoreCase(first, text)) differs = true;
    }
    if (!differs) return;
    var table: ?[]const u8 = null;
    if (qualifiers[0]) |first_qualifier| {
        for (qualifiers[1 .. count + 1]) |entry| {
            const other = entry orelse return;
            if (!std.ascii.eqlIgnoreCase(first_qualifier, other)) return;
        }
        if (!sources.matches(first_qualifier)) return;
        table = first_qualifier;
    } else {
        for (qualifiers[1 .. count + 1]) |entry| {
            if (entry != null) return;
        }
        table = sources.single() orelse return;
    }
    try appendFinding(allocator, found, .{
        .code = contract.code.or_across_columns,
        .severity = contract.sql_warning_severity.warning,
        .message = contract.sql_warning_messages.or_across_columns,
        .offset = tokens[ors[0]].start,
        .table = table,
        .plan_check = .full_scan_of_table,
    });
}

fn minimumDepth(tokens: []const Token, range: Range) ?u32 {
    var minimum: ?u32 = null;
    var index = range.start;
    while (index < range.end) {
        if (skipNestedSelect(tokens, index, range.end)) |next| {
            index = next;
            continue;
        }
        const token = tokens[index];
        if (!isPunct(token, "(") and !isPunct(token, ")")) {
            if (minimum) |value| {
                if (token.depth < value) minimum = token.depth;
            } else {
                minimum = token.depth;
            }
        }
        index += 1;
    }
    return minimum;
}

const BranchColumn = struct {
    column: ?[]const u8,
    qualifier: ?[]const u8,
};

fn branchColumn(tokens: []const Token, range: Range, depth: u32) ?BranchColumn {
    var comparisons: [4]usize = undefined;
    var count: usize = 0;
    for (range.start..range.end) |index| {
        const token = tokens[index];
        if (token.kind == .word and isWord(token, "select")) return null;
        if (token.kind == .word and (isWord(token, "and") or isWord(token, "or"))) return null;
        if (token.kind != .operator or !isComparison(token.text)) continue;
        if (count == comparisons.len) return null;
        comparisons[count] = index;
        count += 1;
    }
    if (count == 0) return filterColumn(tokens, range);
    if (count != 1) return null;
    const operator = comparisons[0];
    if (tokens[operator].depth < depth) return null;
    const left = classifySide(tokens, .{ .start = operandStart(tokens, range, operator), .end = operator });
    const right = classifySide(tokens, .{ .start = operator + 1, .end = operandEnd(tokens, range, operator) });
    if (left.kind == .plain and right.kind == .literal) return .{ .column = left.column, .qualifier = left.qualifier };
    if (right.kind == .plain and left.kind == .literal) return .{ .column = right.column, .qualifier = right.qualifier };
    return null;
}

fn filterColumn(tokens: []const Token, range: Range) ?BranchColumn {
    for (range.start..range.end) |index| {
        const token = tokens[index];
        if (token.kind != .word) continue;
        if (isWord(token, "like") or isWord(token, "glob")) {
            const left = classifySide(tokens, .{ .start = range.start, .end = index });
            var right_end = range.end;
            if (index + 2 < range.end and isWord(tokens[index + 2], "escape")) right_end = index + 2;
            const right = classifySide(tokens, .{ .start = index + 1, .end = right_end });
            if (left.kind != .plain or right.kind != .literal) return null;
            return .{ .column = left.column, .qualifier = left.qualifier };
        }
        if (isWord(token, "is")) {
            const left = classifySide(tokens, .{ .start = range.start, .end = index });
            var start = index + 1;
            if (start < range.end and isWord(tokens[start], "not")) start += 1;
            const right = classifySide(tokens, .{ .start = start, .end = range.end });
            if (left.kind != .plain or right.kind != .literal) return null;
            return .{ .column = left.column, .qualifier = left.qualifier };
        }
    }
    return null;
}

pub const Sources = struct {
    known: bool = true,
    count: usize = 0,
    names: [16][]const u8 = undefined,

    fn add(self: *Sources, name: []const u8) void {
        if (self.count == self.names.len) {
            self.known = false;
            return;
        }
        self.names[self.count] = name;
        self.count += 1;
    }

    pub fn single(self: Sources) ?[]const u8 {
        if (!self.known or self.count != 1) return null;
        return self.names[0];
    }

    pub fn matches(self: Sources, name: []const u8) bool {
        if (!self.known) return false;
        for (self.names[0..self.count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry, name)) return true;
        }
        return false;
    }
};

const Source = struct {
    plan_name: []const u8 = "",
    source_name: []const u8 = "",
    next: usize,
    derived: bool = false,
    unknown: bool = false,
};

fn parseSource(tokens: []const Token, index: usize, end: usize, depth: u32) Source {
    if (index >= end) return .{ .next = end, .unknown = true };
    const first = tokens[index];
    if (first.depth != depth) return .{ .next = end, .unknown = true };
    if (isPunct(first, "(")) {
        const close = matchingParen(tokens, index) orelse end;
        return .{ .next = @min(close + 1, end), .derived = true };
    }
    if (first.kind != .word) return .{ .next = end, .unknown = true };
    var name = first.text;
    var at = index + 1;
    if (at + 1 < end and isPunct(tokens[at], ".") and tokens[at].depth == depth) {
        if (tokens[at + 1].kind != .word or tokens[at + 1].depth != depth) return .{ .next = end, .unknown = true };
        name = tokens[at + 1].text;
        at += 2;
    }
    if (at < end and isPunct(tokens[at], "(")) return .{ .next = end, .unknown = true };
    var plan_name: []const u8 = name;
    if (at < end and tokens[at].depth == depth and tokens[at].kind == .word) {
        if (isWord(tokens[at], "as")) {
            if (at + 1 >= end or tokens[at + 1].kind != .word or tokens[at + 1].depth != depth) return .{ .next = end, .unknown = true };
            plan_name = tokens[at + 1].text;
            at += 2;
        } else if (!isSourceEndWord(tokens[at])) {
            plan_name = tokens[at].text;
            at += 1;
        }
    }
    return .{ .plan_name = plan_name, .source_name = name, .next = at };
}

fn isSourceEndWord(token: Token) bool {
    const words = [_][]const u8{
        "on",    "using",     "where",  "set",      "values",  "select",    "join",   "left",
        "right", "inner",     "outer",  "cross",    "natural", "indexed",   "not",    "order",
        "limit", "group",     "having", "window",   "union",   "intersect", "except", "and",
        "or",    "returning", "do",     "conflict",
    };
    for (words) |word| {
        if (isWord(token, word)) return true;
    }
    return false;
}

fn recordSource(sources: *Sources, source: Source, ctes: Ctes) void {
    if (source.derived or source.unknown or isCteName(ctes, source.source_name)) {
        sources.known = false;
        return;
    }
    sources.add(source.plan_name);
}

pub fn collectSources(tokens: []const Token, scope: Scope, starts: []const ClauseStart, ctes: Ctes) Sources {
    var sources: Sources = .{};
    if (ctes.unknown) sources.known = false;
    var from_begin: ?usize = null;
    var from_end: usize = scope.end;
    var last_join_source: ?usize = null;
    for (starts, 0..) |start, index| {
        switch (start.clause) {
            .from => {
                if (from_begin == null) {
                    from_begin = start.body;
                    recordSource(&sources, parseSource(tokens, start.body, rangeAfter(starts, scope, index).end, scope.depth), ctes);
                }
            },
            .join => {
                if (isWord(tokens[start.index], "using")) continue;
                var join = start.index;
                while (join < scope.end and !isWord(tokens[join], "join")) : (join += 1) {}
                if (join >= scope.end) {
                    sources.known = false;
                    continue;
                }
                if (last_join_source != null and last_join_source.? == join + 1) continue;
                last_join_source = join + 1;
                recordSource(&sources, parseSource(tokens, join + 1, scope.end, scope.depth), ctes);
            },
            .where, .having, .order, .limit, .other => {
                if (from_begin != null and from_end == scope.end) from_end = start.index;
            },
            .on => {},
        }
    }
    if (from_begin) |begin| {
        var at = begin;
        while (at < from_end) : (at += 1) {
            if (tokens[at].depth != scope.depth or !isPunct(tokens[at], ",")) continue;
            recordSource(&sources, parseSource(tokens, at + 1, from_end, scope.depth), ctes);
        }
    }
    return sources;
}

pub fn writeSources(ctes: Ctes, target: ?[]const u8) Sources {
    var sources: Sources = .{};
    if (ctes.unknown or ctes.names.len != 0) {
        sources.known = false;
        return sources;
    }
    const name = target orelse {
        sources.known = false;
        return sources;
    };
    sources.add(name);
    return sources;
}

pub fn collectCtes(allocator: std.mem.Allocator, tokens: []const Token) std.mem.Allocator.Error!Ctes {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var unknown = false;
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].kind != .word or !isWord(tokens[index], "with")) continue;
        var at = index + 1;
        if (at < tokens.len and isWord(tokens[at], "recursive")) at += 1;
        while (true) {
            if (at >= tokens.len or tokens[at].kind != .word) {
                unknown = true;
                break;
            }
            const name = tokens[at].text;
            at += 1;
            if (at < tokens.len and isPunct(tokens[at], "(")) {
                const close = matchingParen(tokens, at) orelse {
                    unknown = true;
                    break;
                };
                at = close + 1;
            }
            if (at >= tokens.len or !isWord(tokens[at], "as")) {
                unknown = true;
                break;
            }
            at += 1;
            if (at < tokens.len and isWord(tokens[at], "not")) {
                if (at + 1 >= tokens.len or !isWord(tokens[at + 1], "materialized")) {
                    unknown = true;
                    break;
                }
                at += 2;
            } else if (at < tokens.len and isWord(tokens[at], "materialized")) {
                at += 1;
            }
            if (at >= tokens.len or !isPunct(tokens[at], "(")) {
                unknown = true;
                break;
            }
            const close = matchingParen(tokens, at) orelse {
                unknown = true;
                break;
            };
            try names.append(allocator, name);
            at = close + 1;
            if (at < tokens.len and isPunct(tokens[at], ",")) {
                at += 1;
                continue;
            }
            break;
        }
    }
    const owned = try names.toOwnedSlice(allocator);
    model.sortCtesNames(owned);
    return .{ .names = owned, .unknown = unknown };
}
