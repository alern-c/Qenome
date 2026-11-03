const std = @import("std");
const lexer = @import("lexer.zig");

pub const PlanCheck = enum { none, index_on_table, full_scan_of_table };

pub const Finding = struct {
    code: []const u8,
    severity: []const u8,
    message: []const u8,
    offset: usize,
    table: ?[]const u8 = null,
    plan_check: PlanCheck = .none,
};

pub const Token = struct {
    kind: lexer.TokenKind,
    text: []const u8,
    start: usize,
    depth: u32,
    parameter: u64 = 0,
    close: u32 = 0,
};

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Scope = struct {
    select: usize,
    end: usize,
    depth: u32,
    kind: Kind = .select,

    pub const Kind = enum { select, write };
};

pub const Clause = enum { from, where, having, order, limit, on, join, other };

pub const ClauseStart = struct {
    index: usize,
    body: usize,
    clause: Clause,
};

pub const Ctes = struct {
    names: []const []const u8,
    unknown: bool,
};

pub fn isWord(token: Token, word: []const u8) bool {
    return token.kind == .word and std.ascii.eqlIgnoreCase(token.text, word);
}

pub fn isPunct(token: Token, text: []const u8) bool {
    return token.kind == .punctuator and std.mem.eql(u8, token.text, text);
}

pub fn isComparison(text: []const u8) bool {
    const operators = [_][]const u8{ "=", "==", "!=", "<>", "<", ">", "<=", ">=" };
    for (operators) |operator| {
        if (std.mem.eql(u8, text, operator)) return true;
    }
    return false;
}

pub fn isArithmetic(text: []const u8) bool {
    const operators = [_][]const u8{ "+", "-", "*", "/", "%" };
    for (operators) |operator| {
        if (std.mem.eql(u8, text, operator)) return true;
    }
    return false;
}

pub fn isValueKeyword(text: []const u8) bool {
    const keywords = [_][]const u8{
        "null",         "true",         "false",
        "current_date", "current_time", "current_timestamp",
    };
    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(text, keyword)) return true;
    }
    return false;
}

pub fn isUnknownWord(text: []const u8) bool {
    const keywords = [_][]const u8{
        "select",     "exists",           "case",              "cast",  "collate", "as",    "in",   "is",
        "not",        "between",          "like",              "glob",  "escape",  "nulls", "over", "filter",
        "distinct",   "all",              "any",               "some",  "when",    "then",  "else", "end",
        "interval",   "count",            "sum",               "total", "avg",     "min",   "max",  "group_concat",
        "string_agg", "json_group_array", "json_group_object",
    };
    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(text, keyword)) return true;
    }
    return false;
}

pub fn matchingParen(tokens: []const Token, open: usize) ?usize {
    if (tokens[open].close == 0) return null;
    return tokens[open].close;
}

pub fn skipNestedSelect(tokens: []const Token, index: usize, end: usize) ?usize {
    if (index + 1 >= end) return null;
    if (!isPunct(tokens[index], "(")) return null;
    if (tokens[index + 1].kind != .word or
        (!isWord(tokens[index + 1], "select") and !isWord(tokens[index + 1], "with"))) return null;
    if (tokens[index].close == 0) return end;
    if (tokens[index].close >= end) return end;
    return tokens[index].close + 1;
}

pub fn rangeAfter(starts: []const ClauseStart, scope: Scope, index: usize) Range {
    const end = if (index + 1 < starts.len) starts[index + 1].index else scope.end;
    return .{ .start = starts[index].body, .end = end };
}

fn cteLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(left, right);
}

pub fn sortCtesNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, cteLessThan);
}

pub fn isCteName(ctes: Ctes, name: []const u8) bool {
    var low: usize = 0;
    var high: usize = ctes.names.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.ascii.orderIgnoreCase(name, ctes.names[middle])) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return true,
        }
    }
    return false;
}

pub fn appendFinding(allocator: std.mem.Allocator, found: *std.ArrayList(Finding), finding: Finding) std.mem.Allocator.Error!void {
    try found.append(allocator, finding);
}
