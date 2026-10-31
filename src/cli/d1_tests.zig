const std = @import("std");
const Io = std.Io;
const contract = @import("../contract/values.zig");
const db = @import("../db.zig");
const cli = @import("../cli.zig");

const testing = std.testing;

const database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

const local_file_name = "b4b7ee9bc0328fad0039fd55bcee866dbb7978adad944643b49c9071c8746c37.sqlite";

const state_dir = ".wrangler/state/v3/d1/miniflare-D1DatabaseObject";

const base_schema = "CREATE TABLE t(a INTEGER, b TEXT);\nINSERT INTO t VALUES (1, 'x'), (2, 'y');\nCREATE INDEX idx_b ON t(b);";

const record_schema = "CREATE TABLE d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL);";

const applied_schema = record_schema ++ "\nINSERT INTO d1_migrations(name) VALUES ('0001_a.sql'), ('0002_b.sql');";

const RunResult = struct {
    code: cli.ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

fn callRun(
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    temp_parent: [:0]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = cli.run(testing.io, allocator, argv, .{ .temp_parent = temp_parent }, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    config: [:0]u8,
    select: [:0]u8,
    index: [:0]u8,
    work: [:0]u8,
    local: [:0]u8,

    fn init(allocator: std.mem.Allocator, config_extra: []const u8, record: ?[]const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
        errdefer allocator.free(root);
        const config_text = try std.fmt.allocPrint(allocator,
            \\name = "app"
            \\[[d1_databases]]
            \\binding = "DB"
            \\database_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            \\{s}
        , .{config_extra});
        defer allocator.free(config_text);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "wrangler.toml", .data = config_text });
        const config = try std.fs.path.joinZ(allocator, &.{ root, "wrangler.toml" });
        errdefer allocator.free(config);
        try tmp.dir.createDirPath(testing.io, state_dir);
        const local = try std.fs.path.joinZ(allocator, &.{ root, state_dir, local_file_name });
        errdefer allocator.free(local);
        const schema_text = if (record) |table| try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ base_schema, table }) else try allocator.dupe(u8, base_schema);
        defer allocator.free(schema_text);
        const schema = try allocator.dupeSentinel(u8, schema_text, 0);
        defer allocator.free(schema);
        try db.createTestDatabase(local, schema);
        const select = try std.fs.path.joinZ(allocator, &.{ root, "select.sql" });
        errdefer allocator.free(select);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "select.sql", .data = "SELECT b FROM t WHERE b = 'x'" });
        const index = try std.fs.path.joinZ(allocator, &.{ root, "index.sql" });
        errdefer allocator.free(index);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.sql", .data = "CREATE INDEX idx_b2 ON t(b)" });
        try tmp.dir.createDir(testing.io, "work", .default_dir);
        const work = try std.fs.path.joinZ(allocator, &.{ root, "work" });
        return .{ .tmp = tmp, .root = root, .config = config, .select = select, .index = index, .work = work, .local = local };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.config);
        allocator.free(self.select);
        allocator.free(self.index);
        allocator.free(self.work);
        allocator.free(self.local);
        self.tmp.cleanup();
    }

    fn addMigration(self: *Fixture, name: []const u8) !void {
        try self.addMigrationAt("migrations", name);
    }

    fn addMigrationAt(self: *Fixture, directory: []const u8, name: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, directory);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ directory, name });
        defer testing.allocator.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "SELECT 1;" });
    }

    fn file(self: *Fixture, allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![:0]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        return std.fs.path.joinZ(allocator, &.{ self.root, name });
    }

    fn manifest(self: *Fixture) ![:0]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "manifest.json", .data =
            \\{"queries":[{"select":"select.sql"}],"candidates":[{"index_sql":"index.sql"}]}
        });
        return std.fs.path.joinZ(testing.allocator, &.{ self.root, "manifest.json" });
    }

    fn runComparison(self: *Fixture, allocator: std.mem.Allocator, format: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        const argv = [_][:0]const u8{ "Qenome", "--d1", "DB", "--config", self.config, "--select", self.select, "--index-sql", self.index, "--format", format };
        return callRun(allocator, &argv, self.work, stdout_buffer, stderr_buffer);
    }

    fn runWrite(self: *Fixture, allocator: std.mem.Allocator, write_path: [:0]const u8, index_path: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        const argv = [_][:0]const u8{ "Qenome", "--d1", "DB", "--config", self.config, "--write", write_path, "--index-sql", index_path, "--format", "json" };
        return callRun(allocator, &argv, self.work, stdout_buffer, stderr_buffer);
    }

    fn runSuggest(self: *Fixture, allocator: std.mem.Allocator, select_path: [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        const argv = [_][:0]const u8{ "Qenome", "--d1", "DB", "--config", self.config, "--select", select_path, "--suggest", "--format", "json" };
        return callRun(allocator, &argv, self.work, stdout_buffer, stderr_buffer);
    }

    fn runBatch(self: *Fixture, allocator: std.mem.Allocator, manifest_path: [:0]const u8, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [16][:0]const u8 = undefined;
        const required = [_][:0]const u8{ "Qenome", "--d1", "DB", "--config", self.config, "--batch", manifest_path };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(allocator, argv[0 .. required.len + extra.len], self.work, stdout_buffer, stderr_buffer);
    }
};

fn parseReport(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    if (parsed.value.object.get("warnings") == null) {
        parsed.deinit();
        return error.MissingWarnings;
    }
    return parsed;
}

fn warningField(warning: std.json.Value, key: []const u8) ![]const u8 {
    return warning.object.get(key).?.string;
}

fn unappliedWarning(parsed: std.json.Parsed(std.json.Value)) !?std.json.Value {
    for (parsed.value.object.get("warnings").?.array.items) |warning| {
        if (std.mem.eql(u8, try warningField(warning, "code"), contract.code.unapplied_migrations)) return warning;
    }
    return null;
}

test "the json comparison warns about the migrations wrangler has not applied" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0002_b.sql");
    try fixture.addMigration("0001_a.sql");
    const before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.local, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runComparison(testing.allocator, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    const message = try warningField(warning, "message");
    try testing.expect(contains(message, "0001_a.sql, 0002_b.sql"));
    try testing.expect(contains(message, "wrangler d1 migrations apply DB --local"));
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("exit_code").?.integer);

    const after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.local, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "the human and kv reports show the unapplied migrations" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0003_c.sql");

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const human = fixture.runComparison(testing.allocator, "human", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "\nWarnings\n"));
    try testing.expect(contains(human.stdout, "warning: " ++ contract.code.unapplied_migrations ++ ": "));
    try testing.expect(contains(human.stdout, "0003_c.sql"));

    var kv_buffer: [65536]u8 = undefined;
    const kv = fixture.runComparison(testing.allocator, "kv", &kv_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, kv.code);
    try testing.expect(contains(kv.stdout, "warning: " ++ contract.code.unapplied_migrations ++ ": "));
    try testing.expect(contains(kv.stdout, "0003_c.sql"));
}

test "the warning does not change the verdict or the exit status" {
    var quiet = try Fixture.init(testing.allocator, "", record_schema);
    defer quiet.deinit(testing.allocator);
    var stale = try Fixture.init(testing.allocator, "", record_schema);
    defer stale.deinit(testing.allocator);
    try stale.addMigration("0001_a.sql");

    var quiet_buffer: [65536]u8 = undefined;
    var stale_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const quiet_result = quiet.runComparison(testing.allocator, "json", &quiet_buffer, &stderr_buffer);
    const stale_result = stale.runComparison(testing.allocator, "json", &stale_buffer, &stderr_buffer);
    try testing.expectEqual(quiet_result.code, stale_result.code);

    var quiet_json = try parseReport(testing.allocator, quiet_result.stdout);
    defer quiet_json.deinit();
    var stale_json = try parseReport(testing.allocator, stale_result.stdout);
    defer stale_json.deinit();
    try testing.expect(try unappliedWarning(quiet_json) == null);
    try testing.expect(try unappliedWarning(stale_json) != null);
    try testing.expectEqualStrings(quiet_json.value.object.get("verdict").?.string, stale_json.value.object.get("verdict").?.string);
    try testing.expectEqualStrings(quiet_json.value.object.get("result").?.string, stale_json.value.object.get("result").?.string);
    try testing.expectEqual(quiet_json.value.object.get("schema_version").?.integer, stale_json.value.object.get("schema_version").?.integer);
    try testing.expectEqual(quiet_json.value.object.get("exit_code").?.integer, stale_json.value.object.get("exit_code").?.integer);
}

test "every applied migration leaves no warning" {
    var fixture = try Fixture.init(testing.allocator, "", applied_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0002_b.sql");
    try fixture.addMigration("0001_a.sql");

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runComparison(testing.allocator, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    try testing.expect(try unappliedWarning(parsed) == null);
}

test "a database without the record table or a migrations directory has no warning" {
    var no_table = try Fixture.init(testing.allocator, "", null);
    defer no_table.deinit(testing.allocator);
    try no_table.addMigration("0001_a.sql");

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const table_result = no_table.runComparison(testing.allocator, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, table_result.code);
    var table_json = try parseReport(testing.allocator, table_result.stdout);
    defer table_json.deinit();
    try testing.expect(try unappliedWarning(table_json) == null);

    var no_directory = try Fixture.init(testing.allocator, "", record_schema);
    defer no_directory.deinit(testing.allocator);
    var directory_buffer: [65536]u8 = undefined;
    const directory_result = no_directory.runComparison(testing.allocator, "json", &directory_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, directory_result.code);
    var directory_json = try parseReport(testing.allocator, directory_result.stdout);
    defer directory_json.deinit();
    try testing.expect(try unappliedWarning(directory_json) == null);
}

test "the config chooses the migrations directory and the record table" {
    var fixture = try Fixture.init(
        testing.allocator,
        "migrations_dir = \"db/migrations\"\nmigrations_table = \"app_migrations\"\n",
        "CREATE TABLE app_migrations(name TEXT);\nINSERT INTO app_migrations(name) VALUES ('0001_a.sql');",
    );
    defer fixture.deinit(testing.allocator);
    try fixture.addMigrationAt("db/migrations", "0001_a.sql");
    try fixture.addMigrationAt("db/migrations", "0002_b.sql");
    try fixture.addMigrationAt("migrations", "0003_c.sql");

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runComparison(testing.allocator, "json", &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    const message = try warningField(warning, "message");
    try testing.expect(contains(message, "0002_b.sql"));
    try testing.expect(!contains(message, "0001_a.sql"));
    try testing.expect(!contains(message, "0003_c.sql"));
}

test "a batch reports the unapplied migrations in json and human" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0001_a.sql");
    const manifest = try fixture.manifest();
    defer testing.allocator.free(manifest);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const json = fixture.runBatch(testing.allocator, manifest, &.{ "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseReport(testing.allocator, json.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    try testing.expect(contains(try warningField(warning, "message"), "0001_a.sql"));

    var human_buffer: [65536]u8 = undefined;
    const human = fixture.runBatch(testing.allocator, manifest, &.{}, &human_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "warning: " ++ contract.code.unapplied_migrations ++ ": "));
    try testing.expect(contains(human.stdout, "0001_a.sql"));
}

test "the index audit reports the unapplied migrations" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0001_a.sql");
    const manifest = try fixture.manifest();
    defer testing.allocator.free(manifest);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const json = fixture.runBatch(testing.allocator, manifest, &.{ "--audit-indexes", "--format", "json" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, json.code);
    var parsed = try parseReport(testing.allocator, json.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    try testing.expect(contains(try warningField(warning, "message"), "0001_a.sql"));

    var human_buffer: [65536]u8 = undefined;
    const human = fixture.runBatch(testing.allocator, manifest, &.{"--audit-indexes"}, &human_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, human.code);
    try testing.expect(contains(human.stdout, "\nWarnings\n"));
    try testing.expect(contains(human.stdout, "warning: " ++ contract.code.unapplied_migrations ++ ": "));
}

test "a write comparison reports the unapplied migrations" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0001_a.sql");
    const write_path = try fixture.file(testing.allocator, "write.sql", "UPDATE t SET b = 'z' WHERE a = 1");
    defer testing.allocator.free(write_path);
    const index_path = try fixture.file(testing.allocator, "index_a.sql", "CREATE INDEX idx_a2 ON t(a)");
    defer testing.allocator.free(index_path);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runWrite(testing.allocator, write_path, index_path, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    try testing.expect(contains(try warningField(warning, "message"), "0001_a.sql"));
}

test "the scale run with a D1 header writes the D1 note for every step" {
    var fixture = try Fixture.init(testing.allocator, "", null);
    defer fixture.deinit(testing.allocator);
    const seed = try fixture.file(testing.allocator, "seed.json",
        \\{"seed": 9, "tables": {"t": {"rows": 10, "columns": {"a": {"kind": "sequence"}, "b": {"kind": "fixed", "value": "x"}}}}}
    );
    defer testing.allocator.free(seed);

    const argv = [_][:0]const u8{
        "Qenome",      "--d1",        "DB",          "--config", fixture.config, "--select", fixture.select,
        "--index-sql", fixture.index, "--seed-data", seed,       "--scale",      "100,500",  "--runs",
        "0",           "--format",    "json",
    };
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = callRun(testing.allocator, &argv, fixture.work, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);

    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    const steps = parsed.value.object.get("steps").?.array.items;
    try testing.expectEqual(@as(usize, 2), steps.len);
    for (steps) |step| {
        const d1 = step.object.get("comparison").?.object.get("d1") orelse return error.TestUnexpectedResult;
        const note = d1.object.get("sqlite_version_note") orelse return error.TestUnexpectedResult;
        try testing.expect(contains(note.string, " in D1; plans and times can differ"));
    }
}

test "a suggest run reports the unapplied migrations" {
    var fixture = try Fixture.init(testing.allocator, "", record_schema);
    defer fixture.deinit(testing.allocator);
    try fixture.addMigration("0001_a.sql");
    const select_path = try fixture.file(testing.allocator, "query.sql", "SELECT a FROM t WHERE a = 1");
    defer testing.allocator.free(select_path);

    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const result = fixture.runSuggest(testing.allocator, select_path, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(cli.ExitCode.ok, result.code);
    var parsed = try parseReport(testing.allocator, result.stdout);
    defer parsed.deinit();
    const warning = (try unappliedWarning(parsed)) orelse return error.TestUnexpectedResult;
    try testing.expect(contains(try warningField(warning, "message"), "0001_a.sql"));
}
