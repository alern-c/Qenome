const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const contract = @import("../contract/values.zig");
const cli_d1_migrations = @import("../d1/migrations.zig");
const model = @import("model.zig");
const scale = @import("scale.zig");
const testing = std.testing;
const Header = model.Header;
const Measurement = model.Measurement;

const scan_line = [_]model.PlanRow{.{ .id = 2, .parent = 0, .label = .{ .kind = .scan }, .detail = "SCAN t" }};

const search_line = [_]model.PlanRow{.{ .id = 3, .parent = 0, .label = .{ .kind = .search }, .detail = "SEARCH t USING INDEX ix_a (a=?)" }};

fn measurement(rows: u64, rows_read: u64, rows_written: u64, plan: []const model.PlanRow) Measurement {
    return .{
        .rows = rows,
        .plan = .{ .rows = @constCast(plan) },
        .counters = .{
            .rows_read = @intCast(rows_read),
            .rows_written = @intCast(rows_written),
            .fullscan_steps = @intCast(rows_read),
            .vm_steps = 100,
            .sort_ops = 0,
            .autoindex_rows = 0,
        },
        .columns = 3,
    };
}

fn header(write_path: ?[]const u8) Header {
    return .{
        .database_path = "db.sqlite",
        .select_path = "select.sql",
        .write_path = write_path,
        .index_path = "index.sql",
        .work_parent = "/tmp",
        .sqlite_version = "0.0.0",
        .sqlite_source_id = "test-source-id",
        .qenome_version = "0.0.0",
        .binds = &.{},
        .show_binds = false,
    };
}

fn step(rows: u64, judgement: model.Judgement, result: model.Verdict, warnings: model.Warnings) scale.Step {
    return .{
        .rows = rows,
        .tables = &.{},
        .before = measurement(rows, rows, 0, &scan_line),
        .after = measurement(rows, 10, 0, &search_line),
        .result = result,
        .judgement = judgement,
        .plan_changed = true,
        .warnings = warnings,
        .comparison_json = "{\"schema_version\":2}",
        .exit_code = 0,
    };
}

fn render(report: scale.Report, buffer: []u8) ![]const u8 {
    var writer = Io.Writer.fixed(buffer);
    try scale.writeHumanScale(&writer, testing.allocator, report);
    return writer.buffered();
}

test "the human scale output has one row per step and the generated-data note" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{}),
        step(5000, .{ .verdict = .improved }, .match, .{}),
    };
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "scale: 1,000, 5,000 rows in 2 steps") != null);
    try testing.expect(std.mem.indexOf(u8, output, "seed-data: seed.json") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\nSteps\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\n         1,000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\n         5,000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "0.0100x") != null);
    try testing.expect(std.mem.indexOf(u8, output, "improved    match") != null);
    try testing.expect(std.mem.indexOf(u8, output, "note: these rows come from generated data") != null);
    try testing.expect(std.mem.indexOf(u8, output, "production D1 billing.") != null);
    try testing.expect(std.mem.indexOf(u8, output, "The verdict changes") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\nWarnings\n") == null);
}

test "the human scale output names a warning only where it differs between steps" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{ .data_too_small = true }),
        step(5000, .{ .verdict = .improved }, .match, .{}),
    };
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "warning at 1,000 rows: data_too_small:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "warning at 5,000 rows:") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\n  warning: data_too_small") == null);
}

test "a warning at every step is written once without a step size" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{ .no_analyze_stats = true }),
        step(5000, .{ .verdict = .improved }, .match, .{ .no_analyze_stats = true }),
    };
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "\n  warning: no_analyze_stats:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "warning at") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "no_analyze_stats:"));
}

test "the human scale output says when the verdict changes between steps" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{}),
        step(5000, .{ .verdict = .needs_check }, .match, .{}),
    };
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "The verdict changes between 1,000 and 5,000 rows.") != null);
    try testing.expect(std.mem.indexOf(u8, output, "needs-check match") != null);
}

test "the human scale output adds the rows written only with --write and the run-wide warning" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{}),
        step(5000, .{ .verdict = .improved }, .match, .{}),
    };
    steps[1].before = measurement(5000, 1500, 1, &scan_line);
    steps[1].after = measurement(5000, 2, 2, &search_line);
    const names = [_][]const u8{"0001_init.sql"};
    const report: scale.Report = .{
        .header = header("write.sql"),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
        .unapplied_migrations = .{ .binding = "DB", .names = &names },
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "write: write.sql") != null);
    try testing.expect(std.mem.indexOf(u8, output, "written") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1 -> 2") != null);
    try testing.expect(std.mem.indexOf(u8, output, contract.code.unapplied_migrations ++ ":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "0001_init.sql") != null);
}

test "the human scale output prints the binds and the differing rows only when asked" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .not_judged }, .mismatch, .{}),
        step(5000, .{ .verdict = .improved }, .match, .{}),
    };
    steps[0].baseline_only = 2;
    steps[0].variant_only = 1;
    const baseline_examples = [_][]const u8{"1|a"};
    const variant_examples = [_][]const u8{"2|b"};
    steps[0].baseline_examples = &baseline_examples;
    steps[0].variant_examples = &variant_examples;
    const binds = [_]db.BindArg{.{ .number = 1, .value = .{ .int = 7 } }};
    var scale_header = header(null);
    scale_header.binds = &binds;
    scale_header.show_binds = true;
    scale_header.show_rows = true;
    const report: scale.Report = .{
        .header = scale_header,
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    var buffer: [8192]u8 = undefined;
    const output = try render(report, &buffer);

    try testing.expect(std.mem.indexOf(u8, output, "binds: 1:int:7") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\nRows that differ\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2 only in the baseline, 1 only in the variant") != null);
    try testing.expect(std.mem.indexOf(u8, output, "baseline only: 1|a") != null);
    try testing.expect(std.mem.indexOf(u8, output, "variant only: 2|b") != null);

    scale_header.show_binds = false;
    scale_header.show_rows = false;
    const plain: scale.Report = .{
        .header = scale_header,
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
    };
    const hidden = try render(plain, &buffer);
    try testing.expect(std.mem.indexOf(u8, hidden, "binds:") == null);
    try testing.expect(std.mem.indexOf(u8, hidden, "Rows that differ") == null);
    try testing.expect(std.mem.indexOf(u8, hidden, "1|a") == null);
}

fn parse(text: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(text.len != 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

test "the JSON scale report has the version, inputs, environment, steps and warnings" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{ .data_too_small = true }),
        step(5000, .{ .verdict = .needs_check }, .match, .{}),
    };
    var tables = [_]model.SeedTable{.{ .table = "t", .rows = 1000 }};
    steps[0].tables = &tables;
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
        .exit_code = 3,
    };
    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try scale.writeJsonScale(&writer, testing.allocator, report);
    var parsed = try parse(writer.buffered());
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(i64, contract.scale_schema_version), (try field(root, "scale_schema_version")).integer);
    try testing.expectEqual(@as(i64, 3), (try field(root, "exit_code")).integer);
    const inputs = try field(root, "inputs");
    try testing.expectEqualStrings("db.sqlite", (try field(inputs, "database")).string);
    try testing.expectEqualStrings("select.sql", (try field(inputs, "select")).string);
    try testing.expectEqualStrings("index.sql", (try field(inputs, "index_sql")).string);
    try testing.expectEqualStrings("seed.json", (try field(inputs, "seed_data")).string);
    const sizes = (try field(inputs, "scale")).array;
    try testing.expectEqual(@as(usize, 2), sizes.items.len);
    try testing.expectEqual(@as(i64, 5000), sizes.items[1].integer);

    const environment = try field(root, "environment");
    try testing.expectEqualStrings("0.0.0", (try field(environment, "qenome_version")).string);

    const reported_steps = (try field(root, "steps")).array;
    try testing.expectEqual(@as(usize, 2), reported_steps.items.len);
    try testing.expectEqual(@as(i64, 1000), (try field(reported_steps.items[0], "rows")).integer);
    const reported_tables = (try field(reported_steps.items[0], "tables")).array;
    try testing.expectEqual(@as(usize, 1), reported_tables.items.len);
    try testing.expectEqual(@as(i64, 1000), (try field(reported_tables.items[0], "rows")).integer);
    const comparison = try field(reported_steps.items[0], "comparison");
    try testing.expectEqual(@as(i64, 2), (try field(comparison, "schema_version")).integer);

    const warnings = (try field(root, "warnings")).array;
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "the JSON scale report writes the unapplied migrations warning" {
    var steps = [_]scale.Step{
        step(1000, .{ .verdict = .improved }, .match, .{}),
        step(5000, .{ .verdict = .improved }, .match, .{}),
    };
    const names = [_][]const u8{"0001_init.sql"};
    const report: scale.Report = .{
        .header = header(null),
        .seed_path = "seed.json",
        .scale = &.{ 1000, 5000 },
        .steps = &steps,
        .unapplied_migrations = .{ .binding = "DB", .names = &names },
    };
    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try scale.writeJsonScale(&writer, testing.allocator, report);
    var parsed = try parse(writer.buffered());
    defer parsed.deinit();

    const warnings = (try field(parsed.value, "warnings")).array;
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
    try testing.expectEqualStrings(contract.code.unapplied_migrations, (try field(warnings.items[0], "code")).string);
    try testing.expect(std.mem.indexOf(u8, (try field(warnings.items[0], "message")).string, "0001_init.sql") != null);
}
