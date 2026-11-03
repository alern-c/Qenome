const std = @import("std");
const lint = @import("lint.zig");
const contract = @import("../contract/values.zig");
const testing = std.testing;

fn findings(sql: []const u8) ![]lint.Finding {
    return lint.lint(testing.allocator, sql, &.{});
}

fn findingsWith(sql: []const u8, binds: []const lint.Bound) ![]lint.Finding {
    return lint.lint(testing.allocator, sql, binds);
}

fn expectCodes(sql: []const u8, expected: []const []const u8) !void {
    const found = try findings(sql);
    defer testing.allocator.free(found);
    try testing.expectEqual(expected.len, found.len);
    for (expected, 0..) |code, index| {
        try testing.expectEqualStrings(code, found[index].code);
    }
}

fn expectNone(sql: []const u8) !void {
    try expectCodes(sql, &.{});
}

fn expectOne(sql: []const u8, code: []const u8) !void {
    const found = try findings(sql);
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings(code, found[0].code);
}

fn findOne(sql: []const u8, code: []const u8) !lint.Finding {
    const found = try findings(sql);
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings(code, found[0].code);
    return found[0];
}

test "select * and table.* are reported in the outermost select list only" {
    try expectOne("SELECT * FROM t", contract.code.select_star);
    try expectOne("SELECT t.* FROM t", contract.code.select_star);
    try expectOne("SELECT DISTINCT * FROM t", contract.code.select_star);
    try expectOne("SELECT a, * FROM t", contract.code.select_star);
    const finding = try findOne("SELECT * FROM t", contract.code.select_star);
    try testing.expectEqualStrings(contract.sql_warning_severity.info, finding.severity);
    try expectNone("SELECT count(*) FROM t");
    try expectNone("SELECT a * b FROM t");
    try expectNone("SELECT (a) * b FROM t");
    try expectNone("SELECT a FROM t WHERE EXISTS (SELECT * FROM u)");
    try expectNone("SELECT a FROM t WHERE id IN (SELECT * FROM u)");
    try expectNone("SELECT \"*\" FROM t");
}

test "a leading wildcard in LIKE and GLOB is reported" {
    try expectOne("SELECT id FROM t WHERE name LIKE '%x'", contract.code.leading_wildcard_like);
    try expectOne("SELECT id FROM t WHERE name LIKE '_x'", contract.code.leading_wildcard_like);
    try expectOne("SELECT id FROM t WHERE name GLOB '*x'", contract.code.leading_wildcard_like);
    try expectOne("SELECT id FROM t WHERE name GLOB '?x'", contract.code.leading_wildcard_like);
    try expectNone("SELECT id FROM t WHERE name LIKE 'x%'");
    try expectNone("SELECT id FROM t WHERE name LIKE 'x_'");
    try expectNone("SELECT id FROM t WHERE name GLOB 'x*'");
    try expectNone("SELECT id FROM t WHERE name LIKE ?");
    try expectNone("SELECT id FROM t WHERE name LIKE 'x' || '%'");
    try expectNone("SELECT name LIKE '%x' FROM t");
    try expectNone("SELECT id FROM t WHERE name LIKE '%abc' ESCAPE '%'");
    const escaped = try findingsWith("SELECT id FROM t WHERE name LIKE ? ESCAPE '\\'", &.{.{ .parameter = 1, .text = "%x" }});
    defer testing.allocator.free(escaped);
    try testing.expectEqual(@as(usize, 0), escaped.len);
}

test "a bound text value is read for a leading wildcard" {
    const leading = try findingsWith("SELECT id FROM t WHERE name LIKE ?", &.{.{ .parameter = 1, .text = "%x" }});
    defer testing.allocator.free(leading);
    try testing.expectEqual(@as(usize, 1), leading.len);
    try testing.expectEqualStrings(contract.code.leading_wildcard_like, leading[0].code);
    const prefix = try findingsWith("SELECT id FROM t WHERE name LIKE ?", &.{.{ .parameter = 1, .text = "x%" }});
    defer testing.allocator.free(prefix);
    try testing.expectEqual(@as(usize, 0), prefix.len);
    const numbered = try findingsWith("SELECT id FROM t WHERE name LIKE ?2", &.{.{ .parameter = 2, .text = "%x" }});
    defer testing.allocator.free(numbered);
    try testing.expectEqual(@as(usize, 1), numbered.len);
    const named = try findingsWith("SELECT id FROM t WHERE name LIKE :name", &.{.{ .parameter = 1, .text = "%x" }});
    defer testing.allocator.free(named);
    try testing.expectEqual(@as(usize, 0), named.len);
}

test "the pattern inside a string, a comment, or a quoted identifier is not matched" {
    try expectNone("SELECT id FROM t WHERE note = 'LIKE ''%x'''");
    try expectNone("SELECT id FROM t -- name LIKE '%x'\n");
    try expectNone("SELECT id FROM t /* name LIKE '%x' */");
    try expectNone("SELECT id FROM t WHERE \"name LIKE '%x'\" = 1");
    try expectNone("SELECT id FROM t WHERE name = 'GLOB ''*x'''");
}

test "a LIKE in WHERE, ON, or HAVING is reported" {
    try expectOne("SELECT a.id FROM a JOIN b ON b.name LIKE '%x'", contract.code.leading_wildcard_like);
    try expectOne("SELECT id FROM t GROUP BY id HAVING max(name) LIKE '%x'", contract.code.leading_wildcard_like);
    try expectCodes("SELECT id FROM t WHERE (name LIKE '%x' OR note = 'y')", &.{ contract.code.leading_wildcard_like, contract.code.or_across_columns });
}

test "ORDER BY random is reported and a window order is not" {
    try expectOne("SELECT id FROM t ORDER BY random()", contract.code.order_by_random);
    try expectOne("SELECT id FROM t ORDER BY random ( )", contract.code.order_by_random);
    try expectOne("SELECT id FROM t ORDER BY id, random()", contract.code.order_by_random);
    try expectNone("SELECT random() FROM t");
    try expectNone("SELECT id FROM t ORDER BY id");
    try expectNone("SELECT row_number() OVER (ORDER BY random()) FROM t");
    try expectNone("SELECT id FROM t ORDER BY \"random\"()");
    try expectNone("SELECT id FROM t ORDER BY (SELECT random())");
    try expectNone("SELECT id FROM t ORDER BY (WITH c AS (SELECT 1) SELECT random())");
    try expectOne("SELECT id FROM t ORDER BY (SELECT 1 FROM u ORDER BY random())", contract.code.order_by_random);
}

test "a large OFFSET is reported for a literal and a bound integer" {
    try expectOne("SELECT id FROM t LIMIT 10 OFFSET 1000", contract.code.large_offset);
    try expectOne("SELECT id FROM t LIMIT 1000, 10", contract.code.large_offset);
    try expectOne("SELECT id FROM t LIMIT 1_000, 10", contract.code.large_offset);
    try expectOne("SELECT id FROM t LIMIT 0x3E8, 10", contract.code.large_offset);
    try expectNone("SELECT id FROM t LIMIT 10 OFFSET 999");
    try expectNone("SELECT id FROM t LIMIT 999, 10");
    try expectNone("SELECT id FROM t LIMIT 10 OFFSET 1000 - 1000");
    try expectNone("SELECT id FROM t LIMIT 10 OFFSET 1000 + 0");
    try expectNone("SELECT id FROM t LIMIT 10");
    try expectNone("SELECT id FROM t LIMIT 10 OFFSET ?");
    const bound = try findingsWith("SELECT id FROM t LIMIT 10 OFFSET ?", &.{.{ .parameter = 1, .int = 1000 }});
    defer testing.allocator.free(bound);
    try testing.expectEqual(@as(usize, 1), bound.len);
    try testing.expectEqualStrings(contract.code.large_offset, bound[0].code);
    const small = try findingsWith("SELECT id FROM t LIMIT 10 OFFSET ?", &.{.{ .parameter = 1, .int = 999 }});
    defer testing.allocator.free(small);
    try testing.expectEqual(@as(usize, 0), small.len);
}

test "a function or arithmetic on a column in a comparison is reported" {
    const lower = try findOne("SELECT id FROM t WHERE lower(email) = ?", contract.code.function_on_column);
    try testing.expectEqualStrings("t", lower.table.?);
    try testing.expectEqual(lint.PlanCheck.index_on_table, lower.plan_check);
    try expectOne("SELECT id FROM t WHERE date(created_at) = ?", contract.code.function_on_column);
    const arithmetic = try findOne("SELECT id FROM t WHERE price * 2 > ?", contract.code.function_on_column);
    try testing.expectEqual(@as(usize, 29), arithmetic.offset);
    try expectOne("SELECT id FROM t WHERE ? < lower(email)", contract.code.function_on_column);
    try expectOne("SELECT id FROM t WHERE upper(name) = ?", contract.code.function_on_column);
    try expectOne("SELECT id FROM t WHERE price + 1 > ?", contract.code.function_on_column);
    try expectOne("SELECT id FROM t WHERE (price * 2) > ?", contract.code.function_on_column);
    try expectOne("SELECT id FROM t WHERE lower(email) >= 'a'", contract.code.function_on_column);
    const alias = try findOne("SELECT id FROM t x WHERE lower(x.email) = ?", contract.code.function_on_column);
    try testing.expectEqualStrings("x", alias.table.?);
}

test "a function on the parameter side or a column on both sides is not reported" {
    try expectNone("SELECT id FROM t WHERE email = lower(?)");
    try expectNone("SELECT id FROM t WHERE email = lower('x')");
    try expectNone("SELECT id FROM t WHERE email = other");
    try expectNone("SELECT id FROM t WHERE lower(email) = lower(name)");
    try expectNone("SELECT id FROM t WHERE lower(email) = nickname");
    try expectNone("SELECT id FROM t WHERE price > 2 * 100");
    try expectNone("SELECT id FROM t WHERE price = -1");
}

test "a comparison that cannot be modelled is not reported" {
    try expectNone("SELECT id FROM t WHERE CAST(price AS TEXT) = ?");
    try expectNone("SELECT id FROM t WHERE email COLLATE NOCASE = ?");
    try expectNone("SELECT id FROM t WHERE \"lower\"(email) = ?");
    try expectNone("SELECT id FROM t WHERE \"email\" = ?");
    try expectNone("SELECT id FROM t WHERE note = 'lower(email) = 1'");
    try expectNone("SELECT id FROM t /* lower(email) = ? */");
    try expectNone("SELECT id FROM t WHERE sum(price) > ?");
    try expectNone("SELECT id FROM t WHERE count(*) > ?");
    try expectNone("SELECT id FROM t WHERE a BETWEEN 1 AND 10 AND lower(x) = a");
}

test "INDEXED BY and a window function stop the plan-checked findings" {
    try expectNone("SELECT id FROM t INDEXED BY idx WHERE lower(email) = ?");
    try expectNone("SELECT row_number() OVER (ORDER BY id) FROM t WHERE lower(email) = ?");
    try expectNone("SELECT row_number() OVER (ORDER BY id) FROM t WHERE a = 1 OR b = 2");
}

test "a function inside a subquery or a CTE is analysed as its own SELECT" {
    const subquery = try findOne("SELECT id FROM t WHERE id IN (SELECT id FROM u WHERE lower(u.email) = ?)", contract.code.function_on_column);
    try testing.expectEqualStrings("u", subquery.table.?);
    const cte = try findOne("WITH c AS (SELECT id FROM u WHERE lower(u.email) = ?) SELECT id FROM c", contract.code.function_on_column);
    try testing.expectEqualStrings("u", cte.table.?);
    try expectNone("WITH c AS (SELECT id, email FROM u) SELECT id FROM c WHERE lower(c.email) = ?");
}

test "the table of a qualified column is used for the plan check" {
    const joined = try findOne("SELECT a.id FROM a JOIN b ON a.x = b.x WHERE lower(a.email) = ?", contract.code.function_on_column);
    try testing.expectEqualStrings("a", joined.table.?);
    try expectNone("SELECT a.id FROM a JOIN b ON a.x = b.x WHERE lower(email) = ?");
    try expectNone("SELECT a.id FROM a JOIN b ON lower(email) = ?");
}

test "a CTE or a derived table does not become a plan table through its alias" {
    try expectNone("WITH c AS (SELECT email FROM t) SELECT email FROM c x WHERE lower(x.email) = 'a'");
    try expectNone("WITH c AS (SELECT email FROM t) SELECT email FROM c WHERE lower(c.email) = 'a'");
    try expectNone("SELECT email FROM (SELECT email FROM t) x WHERE lower(x.email) = 'a'");
    try expectNone("WITH c AS (SELECT email FROM t) SELECT 1 FROM t JOIN c x ON x.id = t.id WHERE lower(x.email) = 'a'");
    try expectOne("SELECT email FROM t x WHERE lower(x.email) = 'a'", contract.code.function_on_column);
    const joined = try findOne("SELECT 1 FROM a JOIN b ON a.id = b.id, c WHERE lower(c.email) = 'x'", contract.code.function_on_column);
    try testing.expectEqualStrings("c", joined.table.?);
}

test "an OR across different columns is reported" {
    const found = try findOne("SELECT id FROM t WHERE a = 1 OR b = 2", contract.code.or_across_columns);
    try testing.expectEqualStrings("t", found.table.?);
    try testing.expectEqual(lint.PlanCheck.full_scan_of_table, found.plan_check);
    try expectOne("SELECT id FROM t WHERE (a = 1 OR b = 2)", contract.code.or_across_columns);
    try expectOne("SELECT id FROM t WHERE a = 1 OR 1 = b", contract.code.or_across_columns);
    try expectOne("SELECT id FROM t WHERE a = 1 OR b = 2 OR c = 3", contract.code.or_across_columns);
    try expectNone("SELECT id FROM t WHERE a = 1 OR a = 2");
    try expectNone("SELECT id FROM t WHERE a = 1 AND b = 2");
    try expectNone("SELECT id FROM t WHERE a = 1 OR b = c");
    try expectNone("SELECT id FROM t WHERE a = c OR b = 2");
    try expectOne("SELECT id FROM t WHERE a = 1 OR b = 2 OR a = 3", contract.code.or_across_columns);
    try expectNone("SELECT id FROM t WHERE a = 1 OR b = 2 AND c = 3");
    try expectNone("SELECT id FROM t INDEXED BY idx WHERE a = 1 OR b = 2");
    try expectCodes("SELECT id FROM t WHERE a = 1 OR b LIKE '%x'", &.{ contract.code.or_across_columns, contract.code.leading_wildcard_like });
    try expectOne("SELECT id FROM t WHERE a = 1 OR a LIKE '%x'", contract.code.leading_wildcard_like);
    try expectOne("SELECT id FROM t WHERE a IS NULL OR b IS NOT NULL", contract.code.or_across_columns);
    try expectNone("SELECT id FROM t WHERE a IS NULL OR a IS NOT NULL");
    try expectCodes("SELECT id FROM t WHERE lower(a) = 1 OR b LIKE '%x'", &.{ contract.code.function_on_column, contract.code.leading_wildcard_like });
    try expectNone("SELECT id FROM t WHERE a = 1 OR b LIKE 'x' || c");
    try expectOne("SELECT id FROM t WHERE a = 1 OR b LIKE '%x' ESCAPE '\\'", contract.code.or_across_columns);
}

test "an OR inside a subquery is reported for that SELECT" {
    const found = try findOne("SELECT id FROM t WHERE id IN (SELECT id FROM u WHERE a = 1 OR b = 2)", contract.code.or_across_columns);
    try testing.expectEqualStrings("u", found.table.?);
    try expectNone("SELECT id FROM t WHERE (a = 1 OR b = 2) AND c = 3");
}

test "an OR across two tables is not reported" {
    try expectNone("SELECT a.id FROM a JOIN b ON a.x = b.x WHERE a.x = 1 OR b.y = 2");
    try expectNone("SELECT a.id FROM a JOIN b ON a.x = b.x WHERE a.x = 1 OR a.y = 2 AND b.y = 3");
    try expectOne("SELECT a.id FROM a JOIN b ON a.x = b.x WHERE a.x = 1 OR a.y = 2", contract.code.or_across_columns);
}

test "several findings are sorted by offset" {
    const found = try findings("SELECT * FROM t WHERE lower(email) = ? ORDER BY random() LIMIT 10 OFFSET 5000");
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings(contract.code.select_star, found[0].code);
    try testing.expectEqualStrings(contract.code.function_on_column, found[1].code);
    try testing.expectEqualStrings(contract.code.order_by_random, found[2].code);
    try testing.expectEqualStrings(contract.code.large_offset, found[3].code);
    try testing.expect(found[0].offset < found[1].offset);
    try testing.expect(found[1].offset < found[2].offset);
    try testing.expect(found[2].offset < found[3].offset);
}

test "the codes are known" {
    for (contract.sql_warning_codes) |code| {
        try testing.expect(lint.isCode(code));
    }
    try testing.expect(!lint.isCode("implicit_conversion"));
    try testing.expect(!lint.isCode("no_such_warning"));
}

test "an INSERT with a SELECT is analysed once" {
    try expectCodes("INSERT INTO t (a) SELECT * FROM u WHERE b LIKE '%x'", &.{ contract.code.select_star, contract.code.leading_wildcard_like });
    try expectOne("UPDATE t SET a = 1 WHERE b LIKE '%x'", contract.code.leading_wildcard_like);
    try expectOne("DELETE FROM t WHERE lower(b) = ?", contract.code.function_on_column);
    try expectOne("UPDATE t SET a = 1 WHERE a = 1 OR b = 2", contract.code.or_across_columns);
}

test "the analysis of two statements keeps each SELECT separate" {
    try expectCodes("SELECT * FROM t; SELECT id FROM u WHERE a = 1 OR b = 2", &.{ contract.code.select_star, contract.code.or_across_columns });
}
