const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const contract = @import("../contract/values.zig");
const cli_report = @import("report.zig");

pub const max_findings: usize = 20;

pub const example_width: usize = 80;

pub const Kind = enum {
    read,
    write,
};

pub const hint = struct {
    pub const read = "fetch the rows in one query with IN (...) or a JOIN, or send the statements with db.batch()";
    pub const write = "use a multi-row INSERT, or db.batch()";
};

pub const Skipped = struct {
    writes: u64 = 0,
    exec: u64 = 0,
    other: u64 = 0,
    blob: u64 = 0,
    unsupported: u64 = 0,
    nul: u64 = 0,
    large: u64 = 0,
    malformed: u64 = 0,
    version: u64 = 0,

    pub fn total(self: Skipped) u64 {
        return self.writes + self.exec + self.other + self.blob + self.unsupported + self.nul + self.large + self.malformed + self.version;
    }
};

pub const Observation = struct {
    shape: []const u8,
    values: []const u8,
    sql: []const u8,
    kind: Kind,
    batched: bool = false,
    manifest_index: ?usize = null,
};

pub const Finding = struct {
    kind: Kind,
    executions: u64,
    distinct_values: u64,
    longest_run: u64,
    statements: u64,
    batched: u64,
    example: []const u8,
    previous_shape_example: ?[]const u8,
    manifest_index: ?usize,
};

pub const QueryLine = struct {
    index: usize,
    executions: u64,
};

const Entry = struct {
    kind: Kind,
    example: []const u8,
    executions: u64 = 0,
    batched: u64 = 0,
    run: u64 = 0,
    longest: u64 = 0,
    values: std.StringHashMap(void),
    statements: std.StringHashMap(void),
    previous: std.AutoHashMap(usize, u64),
    manifest_index: ?usize = null,
};

pub const Shapes = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    index: std.StringHashMap(usize),
    findings: []const Finding = &.{},
    dropped: usize = 0,
    threshold: u32 = 0,
    last: ?usize = null,

    pub fn init(arena: std.mem.Allocator) Shapes {
        return .{ .arena = arena, .index = .init(arena) };
    }

    pub fn add(self: *Shapes, observation: Observation) !void {
        const at = self.index.get(observation.shape) orelse block: {
            try self.entries.append(self.arena, .{
                .kind = observation.kind,
                .example = observation.sql,
                .values = .init(self.arena),
                .statements = .init(self.arena),
                .previous = .init(self.arena),
            });
            const created = self.entries.items.len - 1;
            try self.index.put(try self.arena.dupe(u8, observation.shape), created);
            break :block created;
        };
        const entry = &self.entries.items[at];
        entry.executions += 1;
        if (observation.batched) {
            entry.batched += 1;
        } else {
            try entry.values.put(try self.arena.dupe(u8, observation.values), {});
        }
        try entry.statements.put(observation.sql, {});
        if (entry.manifest_index == null) entry.manifest_index = observation.manifest_index;
        if (self.last) |previous| {
            if (previous == at) {
                entry.run += 1;
            } else {
                entry.run = 1;
                try entry.previous.put(previous, (entry.previous.get(previous) orelse 0) + 1);
            }
        } else {
            entry.run = 1;
        }
        entry.longest = @max(entry.longest, entry.run);
        self.last = at;
    }

    pub fn interrupt(self: *Shapes) void {
        self.last = null;
    }

    pub fn finish(self: *Shapes, threshold: u32) !void {
        self.threshold = threshold;
        if (threshold == 0) {
            self.findings = &.{};
            self.dropped = 0;
            return;
        }
        var chosen: std.ArrayList(usize) = .empty;
        for (self.entries.items, 0..) |entry, at| {
            if (entry.values.count() >= threshold) try chosen.append(self.arena, at);
        }
        std.mem.sort(usize, chosen.items, self.entries.items, lessFrequent);
        const shown = @min(chosen.items.len, max_findings);
        var findings: std.ArrayList(Finding) = .empty;
        for (chosen.items[0..shown]) |at| {
            const entry = &self.entries.items[at];
            try findings.append(self.arena, .{
                .kind = entry.kind,
                .executions = entry.executions,
                .distinct_values = @intCast(entry.values.count()),
                .longest_run = entry.longest,
                .statements = @intCast(entry.statements.count()),
                .batched = entry.batched,
                .example = entry.example,
                .previous_shape_example = mostPrevious(self.entries.items, entry),
                .manifest_index = entry.manifest_index,
            });
        }
        self.findings = try findings.toOwnedSlice(self.arena);
        self.dropped = chosen.items.len - shown;
    }

    pub fn topReadStatements(self: *const Shapes) ?Statements {
        var best: ?usize = null;
        var best_count: usize = 0;
        for (self.entries.items, 0..) |entry, at| {
            if (entry.kind != .read) continue;
            const count = entry.statements.count();
            if (best == null or count > best_count) {
                best = at;
                best_count = count;
            }
        }
        const at = best orelse return null;
        return .{ .count = best_count, .example = self.entries.items[at].example };
    }
};

pub const Statements = struct {
    count: usize,
    example: []const u8,
};

fn lessFrequent(entries: []const Entry, first: usize, second: usize) bool {
    const left = entries[first];
    const right = entries[second];
    if (left.values.count() != right.values.count()) return left.values.count() > right.values.count();
    if (left.executions != right.executions) return left.executions > right.executions;
    return first < second;
}

fn mostPrevious(entries: []const Entry, entry: *const Entry) ?[]const u8 {
    var best: ?usize = null;
    var best_count: u64 = 0;
    var iterator = entry.previous.iterator();
    while (iterator.next()) |pair| {
        const at = pair.key_ptr.*;
        const count = pair.value_ptr.*;
        if (best == null or count > best_count or (count == best_count and at < best.?)) {
            best = at;
            best_count = count;
        }
    }
    const at = best orelse return null;
    return entries[at].example;
}

pub fn selectPath(buffer: *[32]u8, index: usize) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "queries/q{d:0>3}.sql", .{index + 1}) catch null;
}

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn kindHint(kind: Kind) []const u8 {
    return switch (kind) {
        .read => hint.read,
        .write => hint.write,
    };
}

pub fn printExample(writer: *Io.Writer, sql: []const u8, width: usize) Io.Writer.Error!void {
    var written: usize = 0;
    var pending_space = false;
    for (sql) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = written != 0;
            continue;
        }
        if (written >= width) {
            try writer.writeAll("...");
            return;
        }
        if (pending_space) {
            try writer.writeByte(' ');
            written += 1;
            pending_space = false;
        }
        try writer.writeByte(byte);
        written += 1;
    }
}

pub fn printShapes(writer: *Io.Writer, shapes: *const Shapes) Io.Writer.Error!void {
    if (shapes.threshold == 0) {
        try writer.writeAll("repeated shapes: off\n");
        return;
    }
    if (shapes.findings.len == 0) {
        try writer.writeAll("repeated shapes: none\n");
        return;
    }
    try writer.writeAll("repeated shapes:\n");
    for (shapes.findings) |finding| {
        try writer.writeAll("  ");
        if (finding.manifest_index) |index| {
            var buffer: [32]u8 = undefined;
            if (selectPath(&buffer, index)) |path| {
                try writer.writeAll(path);
                try writer.writeAll("  ");
            }
        }
        try writer.print(
            "shape: {d} execution{s}, {d} different value{s}, longest run {d}",
            .{
                finding.executions,
                plural(finding.executions),
                finding.distinct_values,
                plural(finding.distinct_values),
                finding.longest_run,
            },
        );
        if (finding.batched != 0) {
            try writer.print(", {d} batched", .{finding.batched});
        }
        if (finding.kind == .write) {
            try writer.writeAll(", write: ");
            try printExample(writer, finding.example, example_width);
        }
        try writer.print(" (possible N+1; {s})\n", .{kindHint(finding.kind)});
    }
    if (shapes.dropped != 0) {
        try writer.print(
            "  {d} more shape{s} dropped (the report keeps at most {d})\n",
            .{ shapes.dropped, plural(@intCast(shapes.dropped)), max_findings },
        );
    }
}

pub fn printSkippedSummary(writer: *Io.Writer, skipped: Skipped) Io.Writer.Error!void {
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

pub fn logPermissionsExposed(io: Io, log_path: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const stat = Io.Dir.cwd().statFile(io, log_path, .{}) catch return false;
    const mode = stat.permissions.toMode() & 0o777;
    return mode & 0o077 != 0;
}

pub fn printLogPermissionsWarning(writer: *Io.Writer, log_path: []const u8) Io.Writer.Error!void {
    try writer.print("warning: " ++ contract.record_log_permissions_message ++ "\n", .{log_path});
}

pub const Summary = struct {
    out_path: []const u8,
    log_path: []const u8,
    log_permissions: bool,
    json: bool,
    records: u64,
    executions: u64,
    queries: []const QueryLine,
    skipped: Skipped,
    shapes: *const Shapes,
};

pub const Report = struct {
    manifest: []const u8,
    log_path: []const u8,
    log_permissions: bool,
    records: u64,
    queries: []const QueryLine,
    skipped: Skipped,
    findings: []const Finding,
    dropped: usize,
};

pub fn printSummary(writer: *Io.Writer, arena: std.mem.Allocator, summary: Summary) cli_report.Error!void {
    const manifest = try std.fmt.allocPrint(arena, "{s}/manifest.json", .{summary.out_path});
    if (summary.json) {
        return writeJson(writer, arena, .{
            .manifest = manifest,
            .log_path = summary.log_path,
            .log_permissions = summary.log_permissions,
            .records = summary.records,
            .queries = summary.queries,
            .skipped = summary.skipped,
            .findings = summary.shapes.findings,
            .dropped = summary.shapes.dropped,
        });
    }
    try writer.print("record: {d} record lines\n", .{summary.records});
    try writer.print("manifest: {s}\n", .{manifest});
    try writer.print(
        "queries: {d} distinct read-only {s} ({d} {s})\n",
        .{
            summary.queries.len,
            if (summary.queries.len == 1) "statement" else "statements",
            summary.executions,
            if (summary.executions == 1) "execution" else "executions",
        },
    );
    for (summary.queries) |line| {
        var buffer: [32]u8 = undefined;
        const path = selectPath(&buffer, line.index) orelse continue;
        try writer.print("  {s}  {d} execution{s}\n", .{ path, line.executions, plural(line.executions) });
    }
    try printShapes(writer, summary.shapes);
    try printSkippedSummary(writer, summary.skipped);
    try writer.print("warning: " ++ contract.record_manifest_binds_message ++ "\n", .{});
}

pub fn printDistinctLimit(writer: *Io.Writer, count: usize, limit: usize, shapes: *const Shapes) Io.Writer.Error!void {
    try writer.print(
        "error: the record log holds {d} distinct read-only statements; a manifest holds at most {d}; narrow the session or split the log",
        .{ count, limit },
    );
    if (shapes.topReadStatements()) |top| {
        try writer.print("; {d} of them share the shape: ", .{top.count});
        try printExample(writer, top.example, example_width);
    }
    try writer.writeAll("\n");
}

fn writeWarning(json: *std.json.Stringify, allocator: std.mem.Allocator, code: []const u8, message: []const u8) cli_report.Error!void {
    try json.beginObject();
    try json.objectField("code");
    try json.write(code);
    try json.objectField("message");
    try cli_report.writeJsonText(json, allocator, message);
    try json.endObject();
}

fn writeJson(writer: *Io.Writer, allocator: std.mem.Allocator, report: Report) cli_report.Error!void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .minified },
    };
    try json.beginObject();
    try json.objectField("record_schema_version");
    try json.write(contract.record_schema_version);
    try json.objectField("exit_code");
    try json.write(@as(u8, 0));
    try json.objectField("manifest");
    try cli_report.writeJsonText(&json, allocator, report.manifest);
    try json.objectField("records");
    try json.write(report.records);
    try json.objectField("queries");
    try json.beginArray();
    for (report.queries) |line| {
        var buffer: [32]u8 = undefined;
        try json.beginObject();
        try json.objectField("select");
        try cli_report.writeJsonText(&json, allocator, selectPath(&buffer, line.index) orelse "");
        try json.objectField("executions");
        try json.write(line.executions);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("skipped");
    try json.beginObject();
    try json.objectField("writes");
    try json.write(report.skipped.writes);
    try json.objectField("exec");
    try json.write(report.skipped.exec);
    try json.objectField("other");
    try json.write(report.skipped.other);
    try json.objectField("blob");
    try json.write(report.skipped.blob);
    try json.objectField("unsupported");
    try json.write(report.skipped.unsupported);
    try json.objectField("nul");
    try json.write(report.skipped.nul);
    try json.objectField("large");
    try json.write(report.skipped.large);
    try json.objectField("malformed");
    try json.write(report.skipped.malformed);
    try json.objectField("version");
    try json.write(report.skipped.version);
    try json.endObject();
    try json.objectField("warnings");
    try json.beginArray();
    if (report.log_permissions) {
        const message = try std.fmt.allocPrint(allocator, contract.record_log_permissions_message, .{report.log_path});
        defer allocator.free(message);
        try writeWarning(&json, allocator, contract.code.record_log_permissions, message);
    }
    try writeWarning(&json, allocator, contract.code.record_manifest_binds, contract.record_manifest_binds_message);
    try json.endArray();
    try json.objectField("repeated_shapes");
    try json.beginArray();
    for (report.findings) |finding| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(kindName(finding.kind));
        try json.objectField("executions");
        try json.write(finding.executions);
        try json.objectField("distinct_values");
        try json.write(finding.distinct_values);
        try json.objectField("longest_run");
        try json.write(finding.longest_run);
        try json.objectField("statements");
        try json.write(finding.statements);
        try json.objectField("batched");
        try json.write(finding.batched);
        try json.objectField("example");
        try cli_report.writeJsonText(&json, allocator, finding.example);
        try json.objectField("previous_shape_example");
        if (finding.previous_shape_example) |sql| {
            try cli_report.writeJsonText(&json, allocator, sql);
        } else {
            try json.write(null);
        }
        try json.objectField("manifest_select");
        if (finding.manifest_index) |index| {
            var buffer: [32]u8 = undefined;
            try cli_report.writeJsonText(&json, allocator, selectPath(&buffer, index) orelse "");
        } else {
            try json.write(null);
        }
        try json.objectField("hint");
        try cli_report.writeJsonText(&json, allocator, kindHint(finding.kind));
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("repeated_shapes_dropped");
    try json.write(report.dropped);
    try json.endObject();
    try writer.writeByte('\n');
}

fn plural(count: u64) []const u8 {
    return if (count == 1) "" else "s";
}
