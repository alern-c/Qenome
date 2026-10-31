const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const db = @import("../db.zig");
const result_rows = @import("../result.zig");

pub const Warning = struct {
    code: []const u8,
    message: []const u8,
};

pub const Query = struct {
    label: []const u8,
    rows: u64,
    plan: db.Plan,
    counters: db.Counters,
};

pub const Report = struct {
    database_path: []const u8,
    queries: []const Query,
    warnings: []const Warning = &.{},
};

pub fn writeHuman(stdout: *Io.Writer, report: Report) Io.Writer.Error!void {
    try stdout.writeAll("no index needed\n");
    try stdout.print("database: {s}\n", .{report.database_path});
    try stdout.print("queries: {d}\n", .{report.queries.len});
    for (report.queries) |query| {
        try stdout.writeByte('\n');
        try result_rows.writeText(stdout, query.label);
        try stdout.print("\nrows read: {d}\n", .{query.counters.rows_read});
        try stdout.writeAll("plan:\n");
        for (query.plan.rows) |row| {
            try stdout.writeAll("  ");
            try result_rows.writeEscapedText(stdout, row.detail);
            try stdout.writeByte('\n');
        }
    }
    if (report.warnings.len != 0) {
        try stdout.writeAll("\nwarnings:\n");
        for (report.warnings) |warning| {
            try stdout.print("  {s}: ", .{warning.code});
            try result_rows.writeEscapedText(stdout, warning.message);
            try stdout.writeByte('\n');
        }
    }
}

pub fn writeJson(stdout: *Io.Writer, report: Report) !void {
    var json: std.json.Stringify = .{
        .writer = stdout,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    const first = report.queries[0];
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(contract.schema_version);
    try json.objectField("exit_code");
    try json.write(@as(u8, 0));
    try json.objectField("statement");
    try json.write("select");
    try json.objectField("verdict");
    try json.write("no-effect");
    try json.objectField("verdict_reasons");
    try json.beginArray();
    try json.write("no index needed");
    try json.endArray();
    try json.objectField("result");
    try json.write(contract.code.no_index_needed);
    try json.objectField("plan_changed");
    try json.write(false);
    try json.objectField("index_needed");
    try json.write(false);
    try json.objectField("baseline");
    try writeMeasurement(&json, first);
    try json.objectField("variant");
    try json.write(null);
    try json.objectField("timing");
    try json.write(null);
    try json.objectField("warnings");
    try writeWarnings(&json, report.warnings);
    try json.objectField("queries");
    try json.beginArray();
    for (report.queries) |query| {
        try json.beginObject();
        try json.objectField("query");
        try json.write(query.label);
        try json.objectField("rows_read");
        try json.write(query.counters.rows_read);
        try json.objectField("plan");
        try writePlan(&json, query.plan);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("inputs");
    try json.beginObject();
    try json.objectField("database");
    try json.write(report.database_path);
    try json.objectField("select");
    try json.write(first.label);
    try json.endObject();
    try json.endObject();
    try stdout.writeByte('\n');
}

fn writeMeasurement(json: *std.json.Stringify, query: Query) !void {
    try json.beginObject();
    try json.objectField("rows");
    try json.write(query.rows);
    try json.objectField("plan");
    try writePlan(json, query.plan);
    try json.objectField("counters");
    try json.beginObject();
    try json.objectField("rows_read");
    try json.write(query.counters.rows_read);
    try json.objectField("rows_written");
    try json.write(query.counters.rows_written);
    try json.objectField("fullscan_steps");
    try json.write(query.counters.fullscan_steps);
    try json.objectField("vm_steps");
    try json.write(query.counters.vm_steps);
    try json.objectField("sort_ops");
    try json.write(query.counters.sort_ops);
    try json.objectField("autoindex_rows");
    try json.write(query.counters.autoindex_rows);
    try json.endObject();
    try json.endObject();
}

fn writePlan(json: *std.json.Stringify, plan: db.Plan) !void {
    try json.beginArray();
    for (plan.rows) |row| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(row.id);
        try json.objectField("parent");
        try json.write(row.parent);
        try json.objectField("kind");
        try json.write(@tagName(row.label.kind));
        try json.objectField("covering");
        try json.write(row.label.covering);
        try json.objectField("automatic");
        try json.write(row.label.automatic);
        try json.objectField("detail");
        try json.write(row.detail);
        try json.endObject();
    }
    try json.endArray();
}

fn writeWarnings(json: *std.json.Stringify, warnings: []const Warning) !void {
    try json.beginArray();
    for (warnings) |warning| {
        try json.beginObject();
        try json.objectField("code");
        try json.write(warning.code);
        try json.objectField("message");
        try json.write(warning.message);
        try json.endObject();
    }
    try json.endArray();
}
