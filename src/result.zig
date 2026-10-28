const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");

pub const max_result_bytes: usize = 64 * 1024 * 1024;

pub const max_examples = 5;

pub const max_example_value_bytes = 200;

const Tag = enum(u8) { integer = 1, real = 2, text = 3, blob = 4, null = 5 };

pub const Budget = struct {
    limit: usize = max_result_bytes,
    used: usize = 0,
};

pub const CollectFailure = enum { over_budget, out_of_memory };

const Span = struct { start: usize, len: usize };

pub const RowCollector = struct {
    allocator: std.mem.Allocator,
    budget: *Budget,
    data: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Span) = .empty,
    charged: usize = 0,
    failure: ?CollectFailure = null,

    pub fn init(allocator: std.mem.Allocator, budget: *Budget) RowCollector {
        return .{ .allocator = allocator, .budget = budget };
    }

    pub fn deinit(self: *RowCollector) void {
        self.data.deinit(self.allocator);
        self.rows.deinit(self.allocator);
    }

    pub fn rowCount(self: *const RowCollector) usize {
        return self.rows.items.len;
    }

    pub fn add(self: *RowCollector, statement: *sqlite.sqlite3_stmt) void {
        if (self.failure != null) return;
        const columns: usize = @intCast(sqlite.sqlite3_column_count(statement));

        var size: usize = 0;
        for (0..columns) |column| {
            size += valueSize(statement, @intCast(column)) orelse return self.fail(.out_of_memory);
        }
        const cost = size + @sizeOf(Span);
        if (cost > self.budget.limit - self.budget.used) return self.fail(.over_budget);
        self.data.ensureUnusedCapacity(self.allocator, size) catch return self.fail(.out_of_memory);
        self.rows.ensureUnusedCapacity(self.allocator, 1) catch return self.fail(.out_of_memory);

        const start = self.data.items.len;
        for (0..columns) |column| appendValue(&self.data, statement, @intCast(column));
        std.debug.assert(self.data.items.len - start == size);
        self.rows.appendAssumeCapacity(.{ .start = start, .len = size });
        self.budget.used += cost;
        self.charged += cost;
    }

    fn fail(self: *RowCollector, failure: CollectFailure) void {
        self.failure = failure;
        self.budget.used -= self.charged;
        self.charged = 0;
        self.data.clearAndFree(self.allocator);
        self.rows.clearAndFree(self.allocator);
    }

    fn row(self: *const RowCollector, span: Span) []const u8 {
        return self.data.items[span.start..][0..span.len];
    }
};

fn valueSize(statement: *sqlite.sqlite3_stmt, column: c_int) ?usize {
    return switch (sqlite.sqlite3_column_type(statement, column)) {
        sqlite.SQLITE_INTEGER, sqlite.SQLITE_FLOAT => 1 + 8,
        sqlite.SQLITE_TEXT => blk: {
            _ = sqlite.sqlite3_column_text(statement, column) orelse return null;
            break :blk 1 + 4 + @as(usize, @intCast(sqlite.sqlite3_column_bytes(statement, column)));
        },
        sqlite.SQLITE_BLOB => blk: {
            const blob = sqlite.sqlite3_column_blob(statement, column);
            const bytes = sqlite.sqlite3_column_bytes(statement, column);
            if (blob == null and (bytes != 0 or sqlite.sqlite3_column_type(statement, column) != sqlite.SQLITE_BLOB)) return null;
            break :blk 1 + 4 + @as(usize, @intCast(bytes));
        },
        else => 1,
    };
}

fn appendValue(data: *std.ArrayList(u8), statement: *sqlite.sqlite3_stmt, column: c_int) void {
    switch (sqlite.sqlite3_column_type(statement, column)) {
        sqlite.SQLITE_INTEGER => {
            data.appendAssumeCapacity(@backingInt(Tag.integer));
            appendInt(data, u64, @bitCast(sqlite.sqlite3_column_int64(statement, column)));
        },
        sqlite.SQLITE_FLOAT => {
            data.appendAssumeCapacity(@backingInt(Tag.real));
            appendInt(data, u64, @bitCast(sqlite.sqlite3_column_double(statement, column)));
        },
        sqlite.SQLITE_TEXT => {
            const text = sqlite.sqlite3_column_text(statement, column).?;
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, column));
            data.appendAssumeCapacity(@backingInt(Tag.text));
            appendInt(data, u32, @intCast(len));
            data.appendSliceAssumeCapacity(text[0..len]);
        },
        sqlite.SQLITE_BLOB => {
            const blob = sqlite.sqlite3_column_blob(statement, column);
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(statement, column));
            data.appendAssumeCapacity(@backingInt(Tag.blob));
            appendInt(data, u32, @intCast(len));
            if (len != 0) data.appendSliceAssumeCapacity(@as([*]const u8, @ptrCast(blob.?))[0..len]);
        },
        else => data.appendAssumeCapacity(@backingInt(Tag.null)),
    }
}

fn appendInt(data: *std.ArrayList(u8), comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    data.appendSliceAssumeCapacity(&bytes);
}

pub const Comparison = struct {
    matched: bool,
    same_order: bool,
    baseline_only: usize = 0,
    variant_only: usize = 0,
    baseline_examples: [max_examples][]const u8 = undefined,
    baseline_example_count: usize = 0,
    variant_examples: [max_examples][]const u8 = undefined,
    variant_example_count: usize = 0,

    pub fn baselineExamples(self: *const Comparison) []const []const u8 {
        return self.baseline_examples[0..self.baseline_example_count];
    }

    pub fn variantExamples(self: *const Comparison) []const []const u8 {
        return self.variant_examples[0..self.variant_example_count];
    }
};

pub fn compare(baseline: *RowCollector, variant: *RowCollector) Comparison {
    std.debug.assert(baseline.failure == null and variant.failure == null);
    var comparison: Comparison = .{
        .matched = false,
        .same_order = sameOrder(baseline, variant),
    };

    sortRows(baseline);
    sortRows(variant);
    const left = baseline.rows.items;
    const right = variant.rows.items;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        const order: std.math.Order = if (i == left.len)
            .gt
        else if (j == right.len)
            .lt
        else
            std.mem.order(u8, baseline.row(left[i]), variant.row(right[j]));
        switch (order) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                if (comparison.baseline_example_count < max_examples) {
                    comparison.baseline_examples[comparison.baseline_example_count] = baseline.row(left[i]);
                    comparison.baseline_example_count += 1;
                }
                comparison.baseline_only += 1;
                i += 1;
            },
            .gt => {
                if (comparison.variant_example_count < max_examples) {
                    comparison.variant_examples[comparison.variant_example_count] = variant.row(right[j]);
                    comparison.variant_example_count += 1;
                }
                comparison.variant_only += 1;
                j += 1;
            },
        }
    }
    comparison.matched = comparison.baseline_only == 0 and comparison.variant_only == 0;
    return comparison;
}

fn sameOrder(baseline: *const RowCollector, variant: *const RowCollector) bool {
    if (baseline.rows.items.len != variant.rows.items.len) return false;
    for (baseline.rows.items, variant.rows.items) |left, right| {
        if (!std.mem.eql(u8, baseline.row(left), variant.row(right))) return false;
    }
    return true;
}

fn sortRows(collector: *RowCollector) void {
    std.mem.sort(Span, collector.rows.items, collector.data.items, struct {
        fn lessThan(data: []const u8, a: Span, b: Span) bool {
            return std.mem.order(u8, data[a.start..][0..a.len], data[b.start..][0..b.len]) == .lt;
        }
    }.lessThan);
}

pub fn writeRow(writer: *Io.Writer, row: []const u8) Io.Writer.Error!void {
    try writer.writeByte('[');
    var rest = row;
    var first = true;
    while (rest.len != 0) {
        if (!first) try writer.writeAll(", ");
        first = false;
        const tag: Tag = @fromBackingInt(@intCast(rest[0]));
        rest = rest[1..];
        switch (tag) {
            .integer => {
                try writer.print("{d}", .{@as(i64, @bitCast(std.mem.readInt(u64, rest[0..8], .little)))});
                rest = rest[8..];
            },
            .real => {
                try writer.print("{e}", .{@as(f64, @bitCast(std.mem.readInt(u64, rest[0..8], .little)))});
                rest = rest[8..];
            },
            .text, .blob => {
                const len: usize = std.mem.readInt(u32, rest[0..4], .little);
                const value = rest[4..][0..len];
                rest = rest[4 + len ..];
                if (tag == .text) try writeText(writer, value) else try writeBlob(writer, value);
            },
            .null => try writer.writeAll("NULL"),
        }
    }
    try writer.writeByte(']');
}

pub fn writeText(writer: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    var shown = value.len;
    if (shown > max_example_value_bytes) {
        shown = max_example_value_bytes;
        while (shown > 0 and value[shown] & 0xc0 == 0x80) shown -= 1;
    }
    try writer.writeByte('\'');
    try writeEscaped(writer, value[0..shown], true);
    try writer.writeByte('\'');
    if (shown != value.len) try writer.print("...({d} bytes)", .{value.len});
}

pub fn writeEscapedText(writer: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    try writeEscaped(writer, value, false);
}

fn writeEscaped(writer: *Io.Writer, value: []const u8, escape_quote: bool) Io.Writer.Error!void {
    var rest = value;
    while (rest.len != 0) {
        const byte = rest[0];
        if (byte < 0x80) {
            switch (byte) {
                '\\' => try writer.writeAll("\\\\"),
                '\'' => if (escape_quote) try writer.writeAll("\\'") else try writer.writeByte('\''),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
                else => try writer.writeByte(byte),
            }
            rest = rest[1..];
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        const code_point = if (len != 0 and len <= rest.len) std.unicode.utf8Decode(rest[0..len]) catch null else null;
        const point = code_point orelse {
            try writer.print("\\x{x:0>2}", .{byte});
            rest = rest[1..];
            continue;
        };
        switch (point) {
            0x80...0x9f, 0x2028, 0x2029, 0x202a...0x202e, 0x2066...0x2069 => try writer.print("\\u{x:0>4}", .{point}),
            else => try writer.writeAll(rest[0..len]),
        }
        rest = rest[len..];
    }
}

fn writeBlob(writer: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    const shown = @min(value.len, max_example_value_bytes);
    try writer.print("x'{x}'", .{value[0..shown]});
    if (shown != value.len) try writer.print("...({d} bytes)", .{value.len});
}

const testing = std.testing;

fn collect(collector: *RowCollector, sql: [:0]const u8) !void {
    var handle: ?*sqlite.sqlite3 = null;
    defer _ = sqlite.sqlite3_close(handle);
    if (sqlite.sqlite3_open_v2(":memory:", &handle, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, null) != sqlite.SQLITE_OK) {
        return error.TestFixtureFailed;
    }
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(handle, sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) return error.TestFixtureFailed;
    defer _ = sqlite.sqlite3_finalize(statement);
    while (true) switch (sqlite.sqlite3_step(statement)) {
        sqlite.SQLITE_ROW => collector.add(statement.?),
        sqlite.SQLITE_DONE => return,
        else => return error.TestFixtureFailed,
    };
}

fn compareQueries(baseline_sql: [:0]const u8, variant_sql: [:0]const u8) !Comparison {
    var budget: Budget = .{};
    var baseline = RowCollector.init(testing.allocator, &budget);
    defer baseline.deinit();
    var variant = RowCollector.init(testing.allocator, &budget);
    defer variant.deinit();
    try collect(&baseline, baseline_sql);
    try collect(&variant, variant_sql);
    var comparison = compare(&baseline, &variant);
    comparison.baseline_example_count = 0;
    comparison.variant_example_count = 0;
    return comparison;
}

test "normalized rows keep type, null, and duplicates" {
    try testing.expect((try compareQueries("VALUES (1), ('1'), (NULL)", "VALUES (1), ('1'), (NULL)")).matched);
    try testing.expect(!(try compareQueries("VALUES (1)", "VALUES (1.0)")).matched);
    try testing.expect(!(try compareQueries("VALUES (1)", "VALUES ('1')")).matched);
    const duplicates = try compareQueries("VALUES (1), (1), (NULL)", "VALUES (1), (NULL), (NULL)");
    try testing.expect(!duplicates.matched);
    try testing.expectEqual(@as(usize, 1), duplicates.baseline_only);
    try testing.expectEqual(@as(usize, 1), duplicates.variant_only);
}

test "multiset match ignores row order and reports order as reference" {
    const reordered = try compareQueries("VALUES (1, 'a'), (2, 'b')", "VALUES (2, 'b'), (1, 'a')");
    try testing.expect(reordered.matched);
    try testing.expect(!reordered.same_order);

    const same = try compareQueries("VALUES (1, 'a'), (2, 'b')", "VALUES (1, 'a'), (2, 'b')");
    try testing.expect(same.matched);
    try testing.expect(same.same_order);

    const empty = try compareQueries("SELECT 1 WHERE 0", "SELECT 1 WHERE 0");
    try testing.expect(empty.matched);
}

test "mismatch lists one-sided rows with counts and capped examples" {
    var budget: Budget = .{};
    var baseline = RowCollector.init(testing.allocator, &budget);
    defer baseline.deinit();
    var variant = RowCollector.init(testing.allocator, &budget);
    defer variant.deinit();
    try collect(&baseline, "VALUES (0), (1), (2), (3), (4), (5), (6), (7)");
    try collect(&variant, "VALUES (0), (100)");

    const comparison = compare(&baseline, &variant);
    try testing.expect(!comparison.matched);
    try testing.expect(!comparison.same_order);
    try testing.expectEqual(@as(usize, 7), comparison.baseline_only);
    try testing.expectEqual(@as(usize, 1), comparison.variant_only);
    try testing.expectEqual(@as(usize, max_examples), comparison.baselineExamples().len);
    try testing.expectEqual(@as(usize, 1), comparison.variantExamples().len);

    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeRow(&writer, comparison.variantExamples()[0]);
    try testing.expectEqualStrings("[100]", writer.buffered());
}

test "collector over the byte budget is incomparable and frees its rows" {
    var budget: Budget = .{ .limit = 2 * (9 + @sizeOf(Span)) };
    var first = RowCollector.init(testing.allocator, &budget);
    defer first.deinit();
    try collect(&first, "VALUES (1), (2)");
    try testing.expectEqual(@as(?CollectFailure, null), first.failure);
    try testing.expectEqual(budget.limit, budget.used);

    var second = RowCollector.init(testing.allocator, &budget);
    defer second.deinit();
    try collect(&second, "VALUES (1)");
    try testing.expectEqual(@as(?CollectFailure, .over_budget), second.failure);
    try testing.expectEqual(@as(usize, 0), second.rowCount());

    first.fail(.over_budget);
    try testing.expectEqual(@as(usize, 0), budget.used);
    try testing.expectEqual(@as(usize, 0), first.data.capacity);
}

test "real values compare by bits" {
    try testing.expect(!(try compareQueries("SELECT 0.0", "SELECT -0.0")).matched);

    var budget: Budget = .{};
    var collector = RowCollector.init(testing.allocator, &budget);
    defer collector.deinit();
    try collect(&collector, "SELECT -0.0, 1.0, 0.1, 1");
    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeRow(&writer, collector.row(collector.rows.items[0]));
    try testing.expectEqualStrings("[-0e0, 1e0, 1e-1, 1]", writer.buffered());
}

test "empty blob, empty text, and null differ" {
    try testing.expect(!(try compareQueries("SELECT x''", "SELECT ''")).matched);
    try testing.expect(!(try compareQueries("SELECT x''", "SELECT NULL")).matched);
    try testing.expect(!(try compareQueries("SELECT ''", "SELECT NULL")).matched);
    try testing.expect((try compareQueries("SELECT x'', '', NULL", "SELECT x'', '', NULL")).matched);
}

test "text and blob examples are escaped and truncated" {
    var budget: Budget = .{};
    var collector = RowCollector.init(testing.allocator, &budget);
    defer collector.deinit();
    try collect(&collector,
        \\SELECT 'a' || char(10) || 'b''c\' || char(1) || char(9), x'00ff', NULL,
        \\  replace(hex(zeroblob(150)), '0', 'z'), zeroblob(201)
    );
    var buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeRow(&writer, collector.row(collector.rows.items[0]));
    const out = writer.buffered();
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    try testing.expect(std.mem.startsWith(u8, out, "['a\\nb\\'c\\\\\\x01\\t', x'00ff', NULL, 'zzz"));
    try testing.expect(std.mem.indexOf(u8, out, "z'...(300 bytes), x'00") != null);
    try testing.expect(std.mem.endsWith(u8, out, "00'...(201 bytes)]"));
}

test "text examples escape c1 controls, invalid utf-8, and bidi overrides" {
    var budget: Budget = .{};
    var collector = RowCollector.init(testing.allocator, &budget);
    defer collector.deinit();
    try collect(&collector,
        \\SELECT 'a' || char(0x85) || char(0x9b) || 'b', CAST(x'ff41' AS TEXT),
        \\  char(0x2028) || char(0x202e) || 'é'
    );
    var buffer: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeRow(&writer, collector.row(collector.rows.items[0]));
    try testing.expectEqualStrings("['a\\u0085\\u009bb', '\\xffA', '\\u2028\\u202eé']", writer.buffered());
}

test "columns split differently do not collide" {
    try testing.expect(!(try compareQueries("SELECT 'ab', 'c'", "SELECT 'a', 'bc'")).matched);
    try testing.expect(!(try compareQueries("SELECT x'01', x'02'", "SELECT x'0102', x''")).matched);
}
