//! The private temporary directory, the snapshot, and the candidate index on
//! the variant. The source database is only read; only the variant this run
//! created is ever written to.

const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const cli_comparison = @import("comparison.zig");
const cli_control = @import("control.zig");
const cli_query = @import("query.zig");
const openErrorMessage = cli_query.openErrorMessage;
const signalPending = cli_control.signalPending;
const reportInterrupted = cli_control.reportInterrupted;
const Side = cli_comparison.Side;
const ExitCode = cli_control.ExitCode;

/// Parent of the temporary directory: `TMPDIR`, or `/tmp` when it is unset or
/// empty. A relative value is resolved against the current directory.
pub fn tempParentPath(temp_parent: ?[]const u8) []const u8 {
    const value = temp_parent orelse return "/tmp";
    return if (value.len == 0) "/tmp" else value;
}

/// Prefix of every temporary directory, so that one left behind by `kill -9`
/// is easy to find and remove by hand.
pub const work_dir_prefix = "qenome-";

/// Random bytes in the directory name; the name holds them as hex.
const work_dir_random_bytes = 12;

/// Attempts before giving up on a free name. A clash needs the same 96 random
/// bits, so a second attempt is already a sign of something else.
const work_dir_attempts = 4;

/// A private directory that holds `baseline.db` and `variant.db`.
///
/// `create` makes the directory with mode 0700 in one `mkdir`, and only a
/// directory this run created is ever removed: a name that already exists is
/// skipped, never reused.
pub const WorkDir = struct {
    parent: Io.Dir,
    name: [work_dir_prefix.len + 2 * work_dir_random_bytes]u8,
    /// Absolute path of the directory, for messages.
    path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,

    pub fn create(io: Io, arena: std.mem.Allocator, parent_path: []const u8) !WorkDir {
        var parent = try Io.Dir.cwd().openDir(io, parent_path, .{});
        errdefer parent.close(io);

        var work: WorkDir = .{
            .parent = parent,
            .name = undefined,
            .path = undefined,
            .baseline_path = undefined,
            .variant_path = undefined,
        };
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            if (attempt == work_dir_attempts) return error.PathAlreadyExists;
            var random_bytes: [work_dir_random_bytes]u8 = undefined;
            io.random(&random_bytes);
            _ = std.fmt.bufPrint(&work.name, work_dir_prefix ++ "{x}", .{&random_bytes}) catch unreachable;
            parent.createDir(io, &work.name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            break;
        }
        // From here on the directory is ours, so a failure removes it.
        errdefer parent.deleteTree(io, &work.name) catch {};

        work.path = try parent.realPathFileAlloc(io, &work.name, arena);
        work.baseline_path = try std.fmt.allocPrintSentinel(arena, "{s}/baseline.db", .{work.path}, 0);
        work.variant_path = try std.fmt.allocPrintSentinel(arena, "{s}/variant.db", .{work.path}, 0);
        return work;
    }

    /// Builds the candidate index on this run's own variant copy. The path
    /// comes from this directory, never from the caller, so an index can only
    /// land in the copy the run made.
    pub fn applyCandidate(
        self: *const WorkDir,
        index_sql: [:0]const u8,
        control: *db.StepControl,
        detail: *db.SnapshotDetail,
    ) db.ApplyError!void {
        return db.applyCreateIndex(self.variant_path, index_sql, control, detail);
    }

    /// Removes the directory and everything in it. A failure is a cleanup
    /// failure (exit 5 after an otherwise successful run) and names the path
    /// that is left behind.
    pub fn remove(self: *WorkDir, io: Io, stderr: *Io.Writer, cleanup_failed: *bool) void {
        defer self.parent.close(io);
        self.parent.deleteTree(io, &self.name) catch |err| {
            cleanup_failed.* = true;
            stderr.print("error: the temporary directory '{s}' could not be removed: {s}\n", .{ self.path, @errorName(err) }) catch {};
        };
    }
};

/// Copies `database_path` into `work` as one snapshot, then copies the closed
/// baseline to the variant. Returns the exit code of a failure, or null when
/// both copies exist.
pub fn prepareCopies(
    io: Io,
    database_path: [:0]const u8,
    work: *const WorkDir,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) ?ExitCode {
    {
        var source: db.Db = .{};
        source.openReadOnly(database_path) catch |err| {
            stderr.print("error: cannot open '{s}' read-only: {s}\n", .{ database_path, openErrorMessage(err) }) catch {};
            return .rejected;
        };
        defer source.close() catch {
            cleanup_failed.* = true;
            stderr.print("error: the database connection could not be closed: {s}\n", .{source.message()}) catch {};
        };

        var detail: db.SnapshotDetail = .{};
        source.copySnapshotTo(work.baseline_path, &detail) catch |err| {
            switch (err) {
                error.SourceBusy => stderr.print("error: cannot copy '{s}': the database is locked by another connection: {s}\n", .{ database_path, detail.text() }) catch {},
                error.SnapshotFailed => stderr.print("error: cannot copy '{s}' into the temporary directory: {s}\n", .{ database_path, detail.text() }) catch {},
            }
            return .rejected;
        };
    }

    // The copy itself cannot be interrupted, so a signal that arrived while
    // it ran is honoured here.
    if (signalPending()) return reportInterrupted(stderr);

    // The baseline is closed and private, so a plain file copy is consistent.
    Io.Dir.cwd().copyFile(work.baseline_path, Io.Dir.cwd(), work.variant_path, io, .{}) catch |err| {
        stderr.print("error: cannot copy the baseline to the variant: {s}\n", .{@errorName(err)}) catch {};
        return .rejected;
    };
    return null;
}

/// The size of a closed-to-writes copy, or null after reporting why it could
/// not be read.
pub fn fileSize(io: Io, path: [:0]const u8, side: Side, stderr: *Io.Writer) ?u64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        stderr.print("error: cannot read the size of the {t} '{s}': {s}\n", .{ side, path, @errorName(err) }) catch {};
        return null;
    };
    return stat.size;
}

const testing = std.testing;

/// The schema of the fixture database these tests copy and index.
const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

/// A temporary directory with one database in it, for the tests that need a
/// real file to copy.
const Fixture = struct {
    tmp: testing.TmpDir,
    db_path: [:0]u8,

    fn init() !Fixture {
        var fixture: Fixture = .{ .tmp = testing.tmpDir(.{}), .db_path = undefined };
        errdefer fixture.tmp.cleanup();
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "fixture.db", .data = "" });
        fixture.db_path = try fixture.tmp.dir.realPathFileAlloc(testing.io, "fixture.db", testing.allocator);
        errdefer testing.allocator.free(fixture.db_path);
        try db.createTestDatabase(fixture.db_path, fixture_schema);
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.db_path);
        self.tmp.cleanup();
    }

    /// An empty directory that can hold the work directory, as `TMPDIR` does.
    fn workParent(self: *Fixture) ![:0]u8 {
        try self.tmp.dir.createDir(testing.io, "work", .default_dir);
        return self.tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator);
    }
};

test "an unset or empty TMPDIR means /tmp" {
    try testing.expectEqualStrings("/tmp", tempParentPath(null));
    try testing.expectEqualStrings("/tmp", tempParentPath(""));
    try testing.expectEqualStrings("rel/dir", tempParentPath("rel/dir"));
}

test "the work directory is private and the variant is a byte copy of the baseline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const work_parent = try fixture.workParent();
    defer testing.allocator.free(work_parent);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var work = try WorkDir.create(testing.io, arena_state.allocator(), work_parent);
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var cleanup_failed = false;
    {
        defer work.remove(testing.io, &stderr, &cleanup_failed);

        try testing.expect(std.mem.startsWith(u8, &work.name, work_dir_prefix));
        const stat = try work.parent.statFile(testing.io, &work.name, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);

        try testing.expectEqual(@as(?ExitCode, null), prepareCopies(testing.io, fixture.db_path, &work, &stderr, &cleanup_failed));
        const baseline = try Io.Dir.cwd().readFileAlloc(testing.io, work.baseline_path, testing.allocator, .unlimited);
        defer testing.allocator.free(baseline);
        const variant = try Io.Dir.cwd().readFileAlloc(testing.io, work.variant_path, testing.allocator, .unlimited);
        defer testing.allocator.free(variant);
        try testing.expect(baseline.len > 0);
        try testing.expectEqualSlices(u8, baseline, variant);
    }
    // Nothing is left behind after `remove`.
    var parent = try fixture.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
    defer parent.close(testing.io);
    var entries = parent.iterate();
    try testing.expect((try entries.next(testing.io)) == null);
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
}

test "applyCandidate writes the index into the variant copy only" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const work_parent = try fixture.workParent();
    defer testing.allocator.free(work_parent);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var work = try WorkDir.create(testing.io, arena_state.allocator(), work_parent);
    var stderr_buffer: [512]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var cleanup_failed = false;
    {
        defer work.remove(testing.io, &stderr, &cleanup_failed);

        try testing.expectEqual(@as(?ExitCode, null), prepareCopies(testing.io, fixture.db_path, &work, &stderr, &cleanup_failed));
        const baseline_before = try Io.Dir.cwd().readFileAlloc(testing.io, work.baseline_path, testing.allocator, .unlimited);
        defer testing.allocator.free(baseline_before);
        const variant_before = try Io.Dir.cwd().readFileAlloc(testing.io, work.variant_path, testing.allocator, .unlimited);
        defer testing.allocator.free(variant_before);
        try testing.expectEqualSlices(u8, baseline_before, variant_before);

        var control = db.StepControl.init(testing.io, 0, cli_control.cancelFlag());
        var detail: db.SnapshotDetail = .{};
        try work.applyCandidate("CREATE INDEX idx_new ON t(a)", &control, &detail);

        // The index is in the variant this directory owns ...
        var failure: ExitCode = .ok;
        const find_index = "SELECT count(*) FROM sqlite_master WHERE name = 'idx_new'";
        var variant_session: cli_query.QuerySession = .{};
        defer variant_session.close(.variant, &stderr, &cleanup_failed);
        defer variant_session.finalize();
        if (!variant_session.open(work.variant_path, find_index, &.{}, .variant, "", &stderr, &failure)) return error.OpenFailed;
        try testing.expectEqual(@as(i64, 1), (try variant_session.firstRowInt64()).?);

        // ... and the baseline keeps its bytes and has no such index.
        var baseline_session: cli_query.QuerySession = .{};
        defer baseline_session.close(.baseline, &stderr, &cleanup_failed);
        defer baseline_session.finalize();
        if (!baseline_session.open(work.baseline_path, find_index, &.{}, .baseline, "", &stderr, &failure)) return error.OpenFailed;
        try testing.expectEqual(@as(i64, 0), (try baseline_session.firstRowInt64()).?);

        const baseline_after = try Io.Dir.cwd().readFileAlloc(testing.io, work.baseline_path, testing.allocator, .unlimited);
        defer testing.allocator.free(baseline_after);
        const variant_after = try Io.Dir.cwd().readFileAlloc(testing.io, work.variant_path, testing.allocator, .unlimited);
        defer testing.allocator.free(variant_after);
        try testing.expectEqualSlices(u8, baseline_before, baseline_after);
        try testing.expect(!std.mem.eql(u8, variant_before, variant_after));
    }
    var parent = try fixture.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
    defer parent.close(testing.io);
    var entries = parent.iterate();
    try testing.expect((try entries.next(testing.io)) == null);
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
}
