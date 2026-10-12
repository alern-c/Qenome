//! Command line contract for Qenome.
//!
//! `run` takes a database path, one read-only SELECT file, one candidate
//! CREATE INDEX file, typed bind values, and an optional time limit. The
//! database is opened read-only and copied as one snapshot (`baseline`) into a
//! private temporary directory; the baseline is then copied byte for byte to
//! `variant`. The candidate index is built on the variant only, and the SELECT
//! runs on both copies. The summary shows, per copy, the row count, the query
//! plan, and the execution counters, then whether the result rows are the
//! same. The temporary directory is removed on every return path.
//!
//! Every outcome is a process exit code:
//!
//! * 0: the SELECT ran on both copies and the result rows match (as a
//!   multiset)
//! * 1: an input was rejected (file, database, snapshot, temporary directory,
//!   SQL, DDL, bind, index build, query plan, step)
//! * 2: the arguments cannot be used
//! * 3: the SELECT ran on both copies and the result rows differ
//! * 4: the SELECT ran on both copies, but the results cannot be compared
//! * 5: a connection or the temporary directory could not be cleaned up after
//!   a run that would have exited 0
//! * 124: the time limit interrupted the index build or a SELECT
//! * 129 / 130 / 143: SIGHUP / SIGINT / SIGTERM interrupted the run

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("db.zig");
const sqlite = @import("sqlite.zig");
const result_rows = @import("result.zig");

/// Upper bound for a SQL input file (1 MiB). A file of exactly this size is
/// still accepted.
pub const max_sql_bytes = 1024 * 1024;

pub const SqlFileError = error{
    /// The file is larger than `max_sql_bytes`.
    SqlFileTooLarge,
    /// The file contains a NUL byte. SQLite takes NUL-terminated strings, so a
    /// NUL cannot be part of a statement.
    SqlFileContainsNul,
};

/// Reads a SQL file and returns it NUL-terminated for the SQLite C API.
///
/// `path` may be absolute or relative to the current directory. The size bound
/// is enforced while reading; the reader reports `error.StreamTooLong` when the
/// limit is reached, so one extra byte is allowed before rejecting.
pub fn readSqlFile(io: Io, allocator: std.mem.Allocator, path: []const u8) (SqlFileError || Io.Dir.ReadFileAllocError)![:0]u8 {
    const data = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_sql_bytes + 1),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.SqlFileTooLarge,
        else => |e| return e,
    };
    errdefer allocator.free(data);
    if (std.mem.indexOfScalar(u8, data, 0) != null) return error.SqlFileContainsNul;
    return data;
}

/// Default value of `--timeout-ms`.
pub const default_timeout_ms: u64 = 30_000;

/// Process exit codes. The numbers are part of the CLI contract.
pub const ExitCode = enum(u8) {
    ok = 0,
    rejected = 1,
    usage = 2,
    /// The result rows of the two copies differ (D-506).
    mismatch = 3,
    /// The result rows of the two copies cannot be compared (D-506).
    incomparable = 4,
    cleanup = 5,
    timeout = 124,
    /// 128 + SIGHUP (1).
    hangup = 129,
    /// 128 + SIGINT (2).
    interrupted = 130,
    /// 128 + SIGTERM (15).
    terminated = 143,
};

/// True on platforms with POSIX signal handling. Windows and WASI stay out of
/// scope for this CLI, as the plan records.
const supports_signals = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

/// Signals that stop the run and still let it clean up (D-004).
const handled_signals = if (supports_signals)
    [_]std.posix.SIG{ .INT, .TERM, .HUP }
else
    [_]std.posix.SIG{};

/// Cancel flag. The signal handler writes it; `run`, `runChecked`, and the
/// SELECT progress handler read it. `run` clears it when the run ends.
var signal_flag: std.atomic.Value(bool) = .init(false);

/// Number of the first signal that set `signal_flag`, or 0. Kept apart from
/// the flag so that `db.StepControl` keeps its plain boolean.
var received_signal: std.atomic.Value(u8) = .init(0);

/// Records the first signal only, then raises the flag, so a reader that sees
/// the flag also sees the number. Both are lock-free atomics.
fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = received_signal.cmpxchgStrong(0, @intCast(@backingInt(sig)), .release, .monotonic);
    signal_flag.store(true, .release);
}

/// Routes SIGINT, SIGTERM and SIGHUP to the flag. `SA.RESTART` keeps the
/// handler itself to atomic stores and lets interrupted syscalls continue.
fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (handled_signals) |sig| std.posix.sigaction(sig, &action, null);
}

fn clearSignals() void {
    signal_flag.store(false, .release);
    received_signal.store(0, .release);
}

fn signalPending() bool {
    return signal_flag.load(.acquire);
}

/// Parsed command line. `binds` is owned by the allocator passed to
/// `parseArgs`.
pub const Args = struct {
    db: ?[:0]const u8 = null,
    select: ?[:0]const u8 = null,
    index_sql: ?[:0]const u8 = null,
    binds: []const db.BindArg = &.{},
    /// Time limit for the index build and for each SELECT run; `0` disables
    /// it.
    timeout_ms: u64 = default_timeout_ms,
    help: bool = false,
};

pub const ParseError = error{
    /// An option that needs a value is the last argument.
    MissingValue,
    /// An argument starts with `-` and is not an option of this CLI.
    UnknownOption,
    /// A positional argument was given.
    UnexpectedArgument,
    /// `--bind` does not follow `<N>:<TYPE>[:<VALUE>]`.
    InvalidBindFormat,
    /// `--timeout-ms` is not a non-negative decimal integer.
    InvalidTimeout,
    OutOfMemory,
};

/// Parses `argv`, including the program name at `argv[0]`, without touching
/// any file or database.
///
/// A repeated option keeps its last value. `--help` and `-h` only set a flag;
/// `run` decides what they do.
pub fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) ParseError!Args {
    var args: Args = .{};
    var binds: std.ArrayList(db.BindArg) = .empty;
    errdefer binds.deinit(allocator);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--db")) {
            args.db = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--select")) {
            args.select = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--index-sql")) {
            args.index_sql = try nextValue(argv, &index);
        } else if (std.mem.eql(u8, arg, "--bind")) {
            const raw = try nextValue(argv, &index);
            try binds.append(allocator, try parseBind(raw));
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const raw = try nextValue(argv, &index);
            args.timeout_ms = std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidTimeout;
        } else if (arg.len != 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            return error.UnexpectedArgument;
        }
    }
    args.binds = try binds.toOwnedSlice(allocator);
    return args;
}

fn nextValue(argv: []const [:0]const u8, index: *usize) ParseError![:0]const u8 {
    index.* += 1;
    if (index.* == argv.len) return error.MissingValue;
    return argv[index.*];
}

/// Parses one `--bind` value: `<N>:<TYPE>[:<VALUE>]`.
///
/// Only the first two colons separate the fields, so a text value may hold
/// colons itself. `null` takes no value; `int`, `real` and `text` need one
/// (an empty text value is allowed and means the empty string).
fn parseBind(raw: [:0]const u8) ParseError!db.BindArg {
    const separator = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidBindFormat;
    const number_text = raw[0..separator];
    if (number_text.len == 0) return error.InvalidBindFormat;
    const number = std.fmt.parseUnsigned(u64, number_text, 10) catch return error.InvalidBindFormat;

    const rest = raw[separator + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':');
    const type_text = if (second) |at| rest[0..at] else rest;
    const value_text: ?[]const u8 = if (second) |at| rest[at + 1 ..] else null;

    const value: db.BindValue = blk: {
        if (std.mem.eql(u8, type_text, "int")) {
            const text = value_text orelse return error.InvalidBindFormat;
            break :blk .{ .int = std.fmt.parseInt(i64, text, 10) catch return error.InvalidBindFormat };
        }
        if (std.mem.eql(u8, type_text, "real")) {
            const text = value_text orelse return error.InvalidBindFormat;
            const parsed = std.fmt.parseFloat(f64, text) catch return error.InvalidBindFormat;
            // SQLite stores NaN as NULL, which would silently lose the
            // declared type, so a NaN is not a usable `real` value.
            if (std.math.isNan(parsed)) return error.InvalidBindFormat;
            break :blk .{ .real = parsed };
        }
        if (std.mem.eql(u8, type_text, "text")) {
            break :blk .{ .text = value_text orelse return error.InvalidBindFormat };
        }
        if (std.mem.eql(u8, type_text, "null")) {
            if (value_text != null) return error.InvalidBindFormat;
            break :blk .null;
        }
        return error.InvalidBindFormat;
    };
    return .{ .number = number, .value = value };
}

/// Writes the CLI contract to `writer`.
pub fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\usage: Qenome --db <PATH> --select <FILE> --index-sql <FILE> [options]
        \\
        \\Checks one read-only SELECT and one candidate CREATE INDEX against a
        \\local SQLite database. The database is opened read-only and copied
        \\as one snapshot into a private directory under $TMPDIR (default
        \\/tmp) as a baseline and a variant; the candidate index is built on
        \\the variant only, and the database itself is never changed. The
        \\SELECT runs on both copies; for each, the row count, the query plan,
        \\and the execution counters are reported, followed by whether the
        \\result rows match. The directory is removed before exit.
        \\Plan labels (kind, covering, automatic) are hints read from SQLite's
        \\wording; the detail text after them is what SQLite reported.
        \\
        \\options:
        \\  --db <PATH>          SQLite database file (required)
        \\  --select <FILE>      file holding one read-only SELECT statement (required)
        \\  --index-sql <FILE>   file holding one candidate CREATE INDEX statement (required)
        \\  --bind <N>:<TYPE>[:<VALUE>]
        \\                       typed value bound to parameter N, repeatable;
        \\                       TYPE is int, real, text or null (null takes no
        \\                       value); every number in 1..parameter count must
        \\                       be given exactly once
        \\  --timeout-ms <MS>    time limit for the index build and for each SELECT
        \\                       run, 0 disables it (default 30000)
        \\  --help, -h           print this message and exit with status 0
        \\
        \\exit status: 0 result rows match, 1 rejected, 2 usage error,
        \\3 result rows differ, 4 results cannot be compared, 5 cleanup
        \\failure, 124 time limit reached, 129 / 130 / 143 interrupted by
        \\SIGHUP / SIGINT / SIGTERM
        \\
    );
}

/// Runs the CLI and returns the process exit code. Rejections and usage errors
/// go to `stderr`; the accepted summary goes to `stdout`. `temp_parent` is the
/// value of `TMPDIR`; null or empty means `/tmp`.
pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    temp_parent: ?[]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) ExitCode {
    // A signal only sets a flag; the checks below and the SELECT progress
    // handler consume it. Clearing it here keeps a later run in the same
    // process from seeing a stale interrupt.
    installSignalHandlers();
    defer clearSignals();

    // Every input below lives until the run ends, so one arena keeps the
    // cleanup path short.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = parseArgs(arena, argv) catch |err| {
        stderr.print("error: {s}\n", .{parseErrorMessage(err)}) catch {};
        return if (err == error.OutOfMemory) .rejected else .usage;
    };

    if (args.help) {
        usage(stdout) catch {};
        return .ok;
    }

    const database_path = args.db orelse return missingArgument(stderr, "--db");
    const select_path = args.select orelse return missingArgument(stderr, "--select");
    const index_path = args.index_sql orelse return missingArgument(stderr, "--index-sql");

    const select_sql = readSqlFile(io, arena, select_path) catch |err| {
        stderr.print("error: cannot read --select file '{s}': {s}\n", .{ select_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };
    const index_sql = readSqlFile(io, arena, index_path) catch |err| {
        stderr.print("error: cannot read --index-sql file '{s}': {s}\n", .{ index_path, fileErrorMessage(err) }) catch {};
        return .rejected;
    };

    // A signal that arrived before the copy skips it.
    if (signalPending()) return reportInterrupted(stderr);

    const parent_path = tempParentPath(temp_parent);
    var work = WorkDir.create(io, arena, parent_path) catch |err| {
        stderr.print("error: cannot create a temporary directory under '{s}': {s}\n", .{ parent_path, @errorName(err) }) catch {};
        return .rejected;
    };

    var cleanup_failed = false;
    const code = blk: {
        // Every connection below is closed before this runs.
        defer work.remove(io, stderr, &cleanup_failed);

        if (prepareCopies(io, database_path, &work, stderr, &cleanup_failed)) |failure| break :blk failure;

        const inputs: Inputs = .{
            .database_path = database_path,
            .baseline_path = work.baseline_path,
            .variant_path = work.variant_path,
            .select_path = select_path,
            .index_path = index_path,
            .select_sql = select_sql,
            .index_sql = index_sql,
            .binds = args.binds,
            .timeout_ms = args.timeout_ms,
        };
        break :blk runChecked(io, arena, allocator, inputs, stdout, stderr, &cleanup_failed);
    };
    return finalExitCode(code, cleanup_failed);
}

/// Parent of the temporary directory: `TMPDIR`, or `/tmp` when it is unset or
/// empty. A relative value is resolved against the current directory.
fn tempParentPath(temp_parent: ?[]const u8) []const u8 {
    const value = temp_parent orelse return "/tmp";
    return if (value.len == 0) "/tmp" else value;
}

/// Prefix of every temporary directory, so that one left behind by `kill -9`
/// is easy to find and remove by hand.
const work_dir_prefix = "qenome-";

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
const WorkDir = struct {
    parent: Io.Dir,
    name: [work_dir_prefix.len + 2 * work_dir_random_bytes]u8,
    /// Absolute path of the directory, for messages.
    path: [:0]const u8,
    baseline_path: [:0]const u8,
    variant_path: [:0]const u8,

    fn create(io: Io, arena: std.mem.Allocator, parent_path: []const u8) !WorkDir {
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

    /// Removes the directory and everything in it. A failure is a cleanup
    /// failure (exit 5 after an otherwise successful run) and names the path
    /// that is left behind.
    fn remove(self: *WorkDir, io: Io, stderr: *Io.Writer, cleanup_failed: *bool) void {
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
fn prepareCopies(
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

/// Everything one checked run needs.
const Inputs = struct {
    /// The database as given, for the summary.
    database_path: [:0]const u8,
    /// The snapshot without the candidate index.
    baseline_path: [:0]const u8,
    /// The copy of the snapshot that gets the candidate index.
    variant_path: [:0]const u8,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
};

/// D-105=案1: after a run that would have exited 0 a cleanup failure is
/// reported with exit code 5. A rejection, usage error, mismatch,
/// incomparable result, timeout, or interruption keeps its own code (D-506).
/// The diagnostic itself is always written where the failure is found.
pub fn finalExitCode(code: ExitCode, cleanup_failed: bool) ExitCode {
    if (cleanup_failed and code == .ok) return .cleanup;
    return code;
}

/// Which copy a SELECT ran on, for messages and the summary.
const Side = enum { baseline, variant };

/// What one SELECT run on one copy reported.
const Measurement = struct {
    rows: u64,
    plan: db.Plan,
    counters: db.Counters,
    columns: c_int,
};

const Verdict = enum { match, mismatch, incomparable };

/// The comparison result of the two runs (D-501, D-503, D-506).
const Outcome = struct {
    verdict: Verdict,
    /// Null when the rows were not compared.
    comparison: ?result_rows.Comparison = null,
    /// Why the results cannot be compared, one line each, with what to try
    /// next (D-513).
    reasons: [max_reasons]Reason = undefined,
    reason_count: usize = 0,

    const max_reasons = 5;

    const Reason = struct {
        text: []const u8,
        /// Null when there is nothing the user can change in the SELECT.
        hint: ?[]const u8,
    };

    fn addReason(self: *Outcome, text: []const u8, hint: ?[]const u8) void {
        if (self.reason_count == max_reasons) return;
        self.reasons[self.reason_count] = .{ .text = text, .hint = hint };
        self.reason_count += 1;
    }

    fn exitCode(self: Outcome) ExitCode {
        return switch (self.verdict) {
            .match => .ok,
            .mismatch => .mismatch,
            .incomparable => .incomparable,
        };
    }
};

/// Opens the baseline and walks the accepted order: check the SELECT, bind,
/// and check the candidate DDL on the baseline; build the index on the
/// variant; read the plan of the SELECT and run it on the baseline, then on
/// the variant; compare the rows. The index is built first so that a failing
/// build (a UNIQUE index over duplicates) shows before a long SELECT runs.
/// `cleanup_failed` is set when a connection cannot be closed. The plans live
/// in `arena`; the result rows live in `allocator`, so that a run that
/// outgrows the budget gives them back at once.
fn runChecked(
    io: Io,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) ExitCode {
    // A signal that arrived before the SELECT started still stops the run.
    if (signalPending()) return reportInterrupted(stderr);

    var baseline: db.Db = .{};
    baseline.openReadOnly(inputs.baseline_path) catch |err| {
        stderr.print("error: cannot open the baseline '{s}' read-only: {s}\n", .{ inputs.baseline_path, openErrorMessage(err) }) catch {};
        return .rejected;
    };
    defer baseline.close() catch {
        cleanup_failed.* = true;
        stderr.print("error: the database connection could not be closed: {s}\n", .{baseline.message()}) catch {};
    };

    const statement = baseline.prepareSelect(inputs.select_sql) catch |err| {
        reportSelectFailure(stderr, err, &baseline, inputs.index_sql);
        return .rejected;
    };
    // Declared after the `baseline.close` defer, so `finalize` always runs
    // first, on every return path (D-105=案1).
    defer _ = sqlite.sqlite3_finalize(statement);

    db.bindAll(statement, inputs.binds) catch |err| {
        stderr.print("error: --bind: {s}\n", .{bindErrorMessage(err)}) catch {};
        return .rejected;
    };

    baseline.checkCreateIndex(inputs.index_sql) catch |err| {
        reportCheckFailure(stderr, "--index-sql", err, &baseline);
        return .rejected;
    };

    if (signalPending()) return reportInterrupted(stderr);

    // The time limit and the signal flag cover the index build and each
    // SELECT execution, each with the full limit (D-509); prepare, bind, and
    // the plan reads stay outside it.
    var control = db.StepControl.init(io, inputs.timeout_ms, &signal_flag);
    var detail: db.SnapshotDetail = .{};
    db.applyCreateIndex(inputs.variant_path, inputs.index_sql, &control, &detail) catch |err| switch (err) {
        error.Timeout => {
            stderr.print("error: --index-sql exceeded the time limit of {d} ms\n", .{inputs.timeout_ms}) catch {};
            return .timeout;
        },
        error.Interrupted => return reportInterrupted(stderr),
        else => {
            const reason = if (detail.len != 0) detail.text() else @errorName(err);
            stderr.print("error: --index-sql: the index could not be created on the variant: {s}\n", .{reason}) catch {};
            return .rejected;
        },
    };

    var budget: result_rows.Budget = .{};
    var baseline_rows = result_rows.RowCollector.init(allocator, &budget);
    defer baseline_rows.deinit();
    var variant_rows = result_rows.RowCollector.init(allocator, &budget);
    defer variant_rows.deinit();

    // A SELECT whose rows are never compared (D-502, D-507) still runs on
    // both copies for its plan and counters, but its rows are not kept.
    const keep_rows = !baseline.clues.alwaysIncomparable();
    var failure: ExitCode = .rejected;
    const before = measure(arena, &baseline, statement, inputs, &control, if (keep_rows) &baseline_rows else null, .baseline, stderr, &failure) orelse return failure;

    if (signalPending()) return reportInterrupted(stderr);

    var variant: db.Db = .{};
    variant.openReadOnly(inputs.variant_path) catch |err| {
        stderr.print("error: cannot open the variant '{s}' read-only: {s}\n", .{ inputs.variant_path, openErrorMessage(err) }) catch {};
        return .rejected;
    };
    defer variant.close() catch {
        cleanup_failed.* = true;
        stderr.print("error: the database connection of the variant could not be closed: {s}\n", .{variant.message()}) catch {};
    };
    // The same SQL and binds were accepted on the baseline, so a failure here
    // comes from the variant itself.
    const variant_statement = variant.prepareSelect(inputs.select_sql) catch |err| {
        reportCheckFailure(stderr, "--select on the variant", err, &variant);
        return .rejected;
    };
    defer _ = sqlite.sqlite3_finalize(variant_statement);
    db.bindAll(variant_statement, inputs.binds) catch |err| {
        stderr.print("error: --bind on the variant: {s}\n", .{bindErrorMessage(err)}) catch {};
        return .rejected;
    };
    // Rows the baseline could not keep cannot be compared, so the variant only
    // runs for its plan and counters then.
    const variant_out: ?*result_rows.RowCollector = if (keep_rows and baseline_rows.failure == null) &variant_rows else null;
    const after = measure(arena, &variant, variant_statement, inputs, &control, variant_out, .variant, stderr, &failure) orelse return failure;

    // A signal that arrives after the last progress check but before the run
    // ends still wins over the summary.
    if (signalPending()) return reportInterrupted(stderr);

    const outcome = decide(arena, before, after, &baseline_rows, &variant_rows, .{
        .clues = db.Clues.merge(baseline.clues, variant.clues),
        .limit_or_offset = db.mentionsLimitOrOffset(inputs.select_sql),
    });

    // The summary is the result of the run, so a failed write is a rejection,
    // whatever the comparison said. It is written only here, after both runs,
    // so a rejection, timeout, or interruption leaves stdout empty.
    writeSummary(stdout, inputs, before, after, outcome) catch {
        stderr.print("error: the summary could not be written\n", .{}) catch {};
        return .rejected;
    };
    return outcome.exitCode();
}

/// Reads the plan of the SELECT on one copy and runs it there, keeping the
/// rows in `rows_out`. Returns null after reporting a failure, with its exit
/// code in `failure`.
fn measure(
    arena: std.mem.Allocator,
    database: *db.Db,
    statement: *sqlite.sqlite3_stmt,
    inputs: Inputs,
    control: *db.StepControl,
    rows_out: ?*result_rows.RowCollector,
    side: Side,
    stderr: *Io.Writer,
    failure: *ExitCode,
) ?Measurement {
    // The plan is read before the run, from a statement of its own (D-302).
    // The same SQL and binds were accepted already, so a failure here is the
    // plan read itself or memory.
    const plan = database.explainPlan(arena, inputs.select_sql, inputs.binds) catch |err| {
        const detail = if (err == error.ExplainFailed and database.errorCode() != sqlite.SQLITE_OK)
            database.message()
        else
            @errorName(err);
        stderr.print("error: --select: the query plan could not be read on the {t}: {s}\n", .{ side, detail }) catch {};
        failure.* = .rejected;
        return null;
    };

    const rows = database.stepAll(statement, control, rows_out) catch |err| {
        failure.* = switch (err) {
            error.Timeout => blk: {
                stderr.print("error: --select exceeded the time limit of {d} ms on the {t}\n", .{ inputs.timeout_ms, side }) catch {};
                break :blk .timeout;
            },
            error.Interrupted => reportInterrupted(stderr),
            error.StepFailed => blk: {
                stderr.print("error: --select failed while running on the {t}: {s}\n", .{ side, database.message() }) catch {};
                break :blk .rejected;
            },
        };
        return null;
    };
    return .{
        .rows = rows,
        .plan = plan,
        .counters = db.statementCounters(statement),
        .columns = sqlite.sqlite3_column_count(statement),
    };
}

const over_budget_reason = std.fmt.comptimePrint(
    "the result rows exceed the {d} MiB kept for the comparison",
    .{result_rows.max_result_bytes / (1024 * 1024)},
);

/// What the SQL says about how its rows may legitimately differ.
const Hints = struct {
    clues: db.Clues,
    /// The SELECT text holds LIMIT or OFFSET (D-504).
    limit_or_offset: bool,
};

/// Turns two finished runs into the result (D-501, D-502, D-504, D-505,
/// D-506, D-507, D-512), in this order:
///
/// 1. A SELECT that changes between runs or reads the schema is never
///    compared.
/// 2. Rows that could not be kept are never reported as a match.
/// 3. Equal rows are a match, whatever the SQL looks like: the match was
///    observed.
/// 4. Differing rows are incomparable when the SQL can read the clock or pick
///    or compute rows by their order, and a mismatch otherwise. The
///    one-sided rows are shown in both cases.
///
/// Every reason comes with a hint on what to try next (D-513), except where
/// the SELECT cannot help. A changed SELECT is another SELECT: the LIMIT hint
/// asks to check its plan again, and the docs say so for every hint. Texts
/// that name a function or a table live in `arena`.
fn decide(
    arena: std.mem.Allocator,
    before: Measurement,
    after: Measurement,
    baseline_rows: *result_rows.RowCollector,
    variant_rows: *result_rows.RowCollector,
    hints: Hints,
) Outcome {
    var outcome: Outcome = .{ .verdict = .incomparable };
    if (hints.clues.nondeterministic_function) |name| outcome.addReason(
        print(arena, "the SELECT calls {s}(), whose result changes between runs", name),
        print(arena, "compare the SELECT without {s}()", name),
    );
    if (hints.clues.schema_table) |name| outcome.addReason(
        print(arena, "the SELECT reads {s}, which describes the database itself", name),
        "SELECTs that read the schema tables are not compared",
    );
    if (outcome.reason_count != 0) return outcome;

    if (baseline_rows.failure orelse variant_rows.failure) |failure| {
        switch (failure) {
            .over_budget => outcome.addReason(over_budget_reason, "narrow the rows with WHERE (not LIMIT) and run again"),
            .out_of_memory => outcome.addReason("out of memory while keeping the result rows", null),
        }
        return outcome;
    }
    if (before.columns != after.columns) {
        outcome.addReason("the column count differs between the copies", null);
        return outcome;
    }

    const comparison = result_rows.compare(baseline_rows, variant_rows);
    outcome.comparison = comparison;
    if (comparison.matched) {
        outcome.verdict = .match;
        return outcome;
    }
    if (hints.clues.time_function) |name| outcome.addReason(
        print(arena, "the rows differ, and the SELECT calls {s}(), which can read the current time ('now' or no argument)", name),
        "if the SELECT reads the current time, bind a fixed time instead and run again",
    );
    if (hints.clues.order_dependent_function) |name| outcome.addReason(
        print(arena, "the rows differ, and the SELECT calls {s}(), whose result can depend on the order rows are read in", name),
        orderHint(arena, name),
    );
    if (hints.limit_or_offset) outcome.addReason(
        "the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other rows when the order changes",
        "to compare, end the ORDER BY next to the LIMIT with a unique NOT NULL column, or drop LIMIT and OFFSET; then check that the plan still uses the candidate index",
    );
    if (hints.clues.view_or_cte) outcome.addReason(
        "the rows differ, and the SELECT reads through a view or a WITH clause, which may pick rows by their order",
        "compare the SELECT inside the view or the WITH clause directly",
    );
    if (outcome.reason_count == 0) outcome.verdict = .mismatch;
    return outcome;
}

/// What to try for an order-dependent function, by its kind (D-513).
fn orderHint(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const sums = [_][]const u8{ "sum", "avg", "total" };
    const windows = [_][]const u8{ "row_number", "ntile", "first_value", "last_value", "nth_value", "lag", "lead" };
    for (sums) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "{s}() adds REAL values in the order they are read, so the results may differ only in the last digits; check the baseline-only-row and variant-only-row lines", name);
    for (windows) |entry| if (std.mem.eql(u8, name, entry))
        return print(arena, "end the ORDER BY in OVER (...) of {s}() with a unique column, so that every row has a fixed place", name);
    return print(arena, "add ORDER BY inside {s}(...), so that the rows are joined in a fixed order", name);
}

/// Formats one reason or hint that names a function or a table. Running out
/// of memory here prints the format itself, with `{s}` in place of the name;
/// the line stays one `key: value` line.
fn print(arena: std.mem.Allocator, comptime format: []const u8, name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, format, .{name}) catch format;
}

/// Writes the summary as `key: value` lines (D-510): the inputs once, then one
/// block per copy that starts with `measured-on`, then the comparison. A plan
/// line keeps its SQLite detail last because the detail contains spaces.
///
/// The baseline block is unchanged from the single-copy summary, so its
/// values are those of the snapshot without the candidate index (D-304); the
/// variant block has the index. Keys repeat between the blocks, so read them
/// in order.
fn writeSummary(
    stdout: *Io.Writer,
    inputs: Inputs,
    before: Measurement,
    after: Measurement,
    outcome: Outcome,
) Io.Writer.Error!void {
    try stdout.print("db: {s}\nselect: {s}\nindex-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: {d}\n", .{
        inputs.database_path, inputs.select_path, inputs.index_path, before.rows,
    });
    try stdout.print("sqlite: {s}\nsqlite-source-id: {s}\n", .{
        sqlite.sqlite3_libversion(), sqlite.sqlite3_sourceid(),
    });
    try writePlanAndCounters(stdout, before);
    try stdout.print("measured-on: variant (candidate index applied)\nrows: {d}\n", .{after.rows});
    try writePlanAndCounters(stdout, after);

    switch (outcome.verdict) {
        .match => try stdout.writeAll("result: match (row multiset)\n"),
        // The cause is not judged: an index should not change the rows, but
        // order-dependent SQL can (D-505).
        .mismatch => try stdout.writeAll("result: mismatch (row multiset; the cause is not determined)\n"),
        .incomparable => try stdout.writeAll("result: incomparable\n"),
    }
    for (outcome.reasons[0..outcome.reason_count]) |reason| {
        try stdout.print("incomparable-reason: {s}\n", .{reason.text});
        if (reason.hint) |hint| try stdout.print("incomparable-hint: {s}\n", .{hint});
    }
    if (outcome.comparison) |comparison| if (!comparison.matched) {
        try stdout.print("baseline-only-rows: {d}\nvariant-only-rows: {d}\n", .{ comparison.baseline_only, comparison.variant_only });
        for (comparison.baselineExamples()) |row| {
            try stdout.writeAll("baseline-only-row: ");
            try result_rows.writeRow(stdout, row);
            try stdout.writeByte('\n');
        }
        for (comparison.variantExamples()) |row| {
            try stdout.writeAll("variant-only-row: ");
            try result_rows.writeRow(stdout, row);
            try stdout.writeByte('\n');
        }
    };
    // The order is only a reference and only for a match (D-503, D-510).
    const order = if (outcome.verdict != .match)
        "not applicable"
    else if (outcome.comparison.?.same_order)
        "same (reference only; not part of the result)"
    else
        "differs (reference only; rows may change order without ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not checked)";
    try stdout.print("row-order: {s}\n", .{order});
}

fn writePlanAndCounters(stdout: *Io.Writer, measurement: Measurement) Io.Writer.Error!void {
    for (measurement.plan.rows) |row| {
        try stdout.print("plan: id={d} parent={d} kind={t} covering={} automatic={} detail={s}\n", .{
            row.id, row.parent, row.label.kind, row.label.covering, row.label.automatic, row.detail,
        });
    }
    try stdout.print("fullscan-steps: {d}\nvm-steps: {d}\nsort-ops: {d}\nautoindex-rows: {d}\n", .{
        measurement.counters.fullscan_steps, measurement.counters.vm_steps, measurement.counters.sort_ops, measurement.counters.autoindex_rows,
    });
}

fn missingArgument(stderr: *Io.Writer, option: []const u8) ExitCode {
    stderr.print("error: {s} is required (see --help)\n", .{option}) catch {};
    return .usage;
}

/// Reports the first signal that arrived. A flag set without a number (a
/// test, or a platform without signals) counts as SIGINT.
fn reportInterrupted(stderr: *Io.Writer) ExitCode {
    const number = received_signal.load(.acquire);
    const code: ExitCode, const name: []const u8 = if (supports_signals and number == @backingInt(std.posix.SIG.TERM))
        .{ .terminated, "SIGTERM" }
    else if (supports_signals and number == @backingInt(std.posix.SIG.HUP))
        .{ .hangup, "SIGHUP" }
    else
        .{ .interrupted, "SIGINT" };
    stderr.print("error: interrupted by {s}\n", .{name}) catch {};
    return code;
}

/// D-508: a SELECT that names the candidate index in `INDEXED BY` cannot be
/// prepared on the baseline, which lacks that index. SQLite reports it as
/// `no such index: <name>` with the name unquoted; when that name is the one
/// the candidate DDL would create, the rejection says so. Every other failure
/// is reported as is.
fn reportSelectFailure(stderr: *Io.Writer, err: db.CheckError, database: *db.Db, index_sql: [:0]const u8) void {
    const prefix = "no such index: ";
    if (err == error.StatementInvalid and database.errorCode() != sqlite.SQLITE_OK) {
        const message = database.message();
        var saved: [512]u8 = undefined;
        if (std.mem.startsWith(u8, message, prefix) and message.len <= saved.len) {
            // The DDL check below replaces the engine message, so keep a copy.
            @memcpy(saved[0..message.len], message);
            const missing = saved[prefix.len..message.len];
            database.checkCreateIndex(index_sql) catch {};
            if (database.candidateIndexName()) |name| {
                if (std.ascii.eqlIgnoreCase(name, missing)) {
                    stderr.print("error: --select: the SELECT (or a view it reads) names the candidate index '{s}' in INDEXED BY, but the baseline does not have that index\n", .{name}) catch {};
                    return;
                }
            }
            stderr.print("error: --select: {s}: {s}\n", .{ checkErrorMessage(err), saved[0..message.len] }) catch {};
            return;
        }
    }
    reportCheckFailure(stderr, "--select", err, database);
}

/// Prints a check failure. The engine message is appended only when SQLite
/// reported an error: some rejections come from our own final checks (an empty
/// file, a `VACUUM`), where the engine message would only say "not an error".
fn reportCheckFailure(stderr: *Io.Writer, option: []const u8, err: db.CheckError, database: *const db.Db) void {
    if (database.errorCode() != sqlite.SQLITE_OK) {
        stderr.print("error: {s}: {s}: {s}\n", .{ option, checkErrorMessage(err), database.message() }) catch {};
    } else {
        stderr.print("error: {s}: {s}\n", .{ option, checkErrorMessage(err) }) catch {};
    }
}

fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingValue => "an option is missing its value (see --help)",
        error.UnknownOption => "unknown option (see --help)",
        error.UnexpectedArgument => "unexpected argument (see --help)",
        error.InvalidBindFormat => "--bind expects <N>:<TYPE>[:<VALUE>] with TYPE int, real, text or null",
        error.InvalidTimeout => "--timeout-ms expects a non-negative integer",
        error.OutOfMemory => "out of memory",
    };
}

fn fileErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SqlFileTooLarge => "the file is larger than 1 MiB",
        error.SqlFileContainsNul => "the file contains a NUL byte",
        else => @errorName(err),
    };
}

fn openErrorMessage(err: db.OpenError) []const u8 {
    return switch (err) {
        error.OpenFailed => "the file is missing, is not a database, or is locked",
        error.NotReadOnlyConnection => "the connection is not read-only",
        error.GuardSetupFailed => "the read-only guards could not be installed",
    };
}

fn checkErrorMessage(err: db.CheckError) []const u8 {
    return switch (err) {
        error.EmptyStatement => "the file holds no statement",
        error.MultipleStatements => "the file must hold exactly one statement",
        error.StatementRejected => "the statement is not allowed here",
        error.StatementInvalid => "the statement is not valid for this database",
        error.StatementNotReadOnly => "the statement is not read-only",
        error.StatementNotCreateIndex => "the statement is not one CREATE INDEX",
    };
}

fn bindErrorMessage(err: db.BindError) []const u8 {
    return switch (err) {
        error.ParameterCountMismatch => "more values were given than the SELECT has parameters",
        error.BindNumberOutOfRange => "a bind number is outside 1..parameter count",
        error.DuplicateBindNumber => "a bind number is given more than once",
        error.MissingBindNumber => "every number in 1..parameter count must be given exactly once",
        error.BindFailed => "SQLite refused a bind value",
    };
}

const testing = std.testing;

test "sql file is read with a trailing sentinel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "select.sql", .data = "SELECT 1;\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "select.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const sql = try readSqlFile(std.testing.io, std.testing.allocator, path);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT 1;\n", sql);
    try std.testing.expectEqual(@as(u8, 0), sql[sql.len]);
}

test "sql file containing a NUL byte is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nul.sql", .data = "SELECT 1\x00SELECT 2" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "nul.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.SqlFileContainsNul,
        readSqlFile(std.testing.io, std.testing.allocator, path),
    );
}

test "sql file at the size limit is accepted and a larger one is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const at_limit = try allocator.alloc(u8, max_sql_bytes);
    defer allocator.free(at_limit);
    @memset(at_limit, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at_limit.sql", .data = at_limit });
    const at_limit_path = try tmp.dir.realPathFileAlloc(std.testing.io, "at_limit.sql", allocator);
    defer allocator.free(at_limit_path);
    const sql = try readSqlFile(std.testing.io, allocator, at_limit_path);
    defer allocator.free(sql);
    try std.testing.expectEqual(@as(usize, max_sql_bytes), sql.len);

    const too_large = try allocator.alloc(u8, max_sql_bytes + 1);
    defer allocator.free(too_large);
    @memset(too_large, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "too_large.sql", .data = too_large });
    const too_large_path = try tmp.dir.realPathFileAlloc(std.testing.io, "too_large.sql", allocator);
    defer allocator.free(too_large_path);
    try std.testing.expectError(
        error.SqlFileTooLarge,
        readSqlFile(std.testing.io, allocator, too_large_path),
    );
}

test "missing sql file reports the read error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing.sql", .data = "SELECT 1" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "missing.sql", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try tmp.dir.deleteFile(std.testing.io, "missing.sql");

    try std.testing.expectError(
        error.FileNotFound,
        readSqlFile(std.testing.io, std.testing.allocator, path),
    );
}

/// A temporary directory that hands out absolute paths for fixture files.
const Fixture = struct {
    tmp: testing.TmpDir,

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    /// Writes `data` and returns the absolute path, owned by the tester.
    fn file(self: *Fixture, sub_path: []const u8, data: []const u8) ![:0]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
        return self.tmp.dir.realPathFileAlloc(testing.io, sub_path, testing.allocator);
    }
};

/// A database, a SELECT file, a candidate DDL file, and an empty parent for
/// the temporary directory of one CLI run.
const CliFixture = struct {
    dir: Fixture,
    db_path: [:0]u8,
    select_path: [:0]u8,
    index_path: [:0]u8,
    /// Passed as `TMPDIR`, so a test can see what a run leaves behind.
    work_parent: [:0]u8,

    fn init(select_sql: []const u8, index_sql: []const u8) !CliFixture {
        return initWithSchema(select_sql, index_sql, fixture_schema);
    }

    fn initWithSchema(select_sql: []const u8, index_sql: []const u8, schema: [:0]const u8) !CliFixture {
        var dir = try Fixture.init();
        errdefer dir.deinit();
        const db_path = try dir.file("fixture.db", "");
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, schema);
        const select_path = try dir.file("select.sql", select_sql);
        errdefer testing.allocator.free(select_path);
        const index_path = try dir.file("index.sql", index_sql);
        errdefer testing.allocator.free(index_path);
        try dir.tmp.dir.createDir(testing.io, "work", .default_dir);
        const work_parent = try dir.tmp.dir.realPathFileAlloc(testing.io, "work", testing.allocator);
        return .{
            .dir = dir,
            .db_path = db_path,
            .select_path = select_path,
            .index_path = index_path,
            .work_parent = work_parent,
        };
    }

    fn deinit(self: *CliFixture) void {
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.select_path);
        testing.allocator.free(self.index_path);
        testing.allocator.free(self.work_parent);
        self.dir.deinit();
    }

    /// Runs the CLI on this fixture with `extra` arguments after the required
    /// ones.
    fn run(self: *CliFixture, extra: []const [:0]const u8, stdout_buffer: []u8, stderr_buffer: []u8) RunResult {
        var argv: [16][:0]const u8 = undefined;
        const required = [_][:0]const u8{ "Qenome", "--db", self.db_path, "--select", self.select_path, "--index-sql", self.index_path };
        @memcpy(argv[0..required.len], &required);
        @memcpy(argv[required.len..][0..extra.len], extra);
        return callRun(testing.allocator, argv[0 .. required.len + extra.len], self.work_parent, stdout_buffer, stderr_buffer);
    }

    /// Fails unless the run removed its temporary directory again.
    fn expectNoLeftovers(self: *CliFixture) !void {
        var parent = try self.dir.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
        defer parent.close(testing.io);
        var it = parent.iterate();
        if (try it.next(testing.io)) |entry| {
            std.debug.print("left behind: {s}\n", .{entry.name});
            return error.TemporaryDirectoryLeft;
        }
    }
};

const fixture_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT);
    \\INSERT INTO t VALUES (1, 'x'), (2, 'y');
    \\CREATE INDEX idx_b ON t(b);
;

const RunResult = struct {
    code: ExitCode,
    stdout: []const u8,
    stderr: []const u8,
};

/// The part of a summary that one copy reported, from its `measured-on` line
/// up to the next block, so that a check cannot match the other copy.
fn summaryBlock(stdout: []const u8, side: Side) []const u8 {
    const variant_at = std.mem.indexOf(u8, stdout, "measured-on: variant") orelse stdout.len;
    if (side == .baseline) {
        const start = std.mem.indexOf(u8, stdout, "measured-on: baseline") orelse return "";
        return stdout[start..variant_at];
    }
    const end = std.mem.indexOf(u8, stdout, "result: ") orelse stdout.len;
    return stdout[variant_at..end];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Calls `run` with the given output buffers and reports what it wrote.
/// `temp_parent` stands in for `TMPDIR`.
fn callRun(
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    temp_parent: ?[]const u8,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) RunResult {
    var stdout = Io.Writer.fixed(stdout_buffer);
    var stderr = Io.Writer.fixed(stderr_buffer);
    const code = run(testing.io, allocator, argv, temp_parent, &stdout, &stderr);
    return .{ .code = code, .stdout = stdout.buffered(), .stderr = stderr.buffered() };
}

test "usage error for missing required arguments" {
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{"Qenome"}, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--db") != null);
}

test "unknown option" {
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const result = callRun(testing.allocator, &.{ "Qenome", "--nope" }, null, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.usage, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown option") != null);
}

test "bind format error" {
    const invalid = [_][:0]const u8{
        "1",
        "x:int:1",
        ":int:1",
        "1:blob:zzz",
        "1:int",
        "1:int:abc",
        "1:real:abc",
        "1:real:nan",
        "1:real:NaN",
        "1:text",
        "1:null:value",
    };
    for (invalid) |raw| {
        var stdout_buffer: [512]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", "--bind", raw }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.usage, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "--bind") != null);
    }
}

test "bind parsing keeps colons and types" {
    const args = try parseArgs(testing.allocator, &.{
        "Qenome",
        "--bind",
        "1:text:a:b:c",
        "--bind",
        "2:null",
        "--bind",
        "3:real:1.5",
        "--timeout-ms",
        "0",
    });
    defer testing.allocator.free(args.binds);

    try testing.expectEqual(@as(usize, 3), args.binds.len);
    try testing.expectEqualStrings("a:b:c", args.binds[0].value.text);
    try testing.expect(args.binds[1].value == .null);
    try testing.expectEqual(@as(f64, 1.5), args.binds[2].value.real);
    try testing.expectEqual(@as(u64, 0), args.timeout_ms);
}

test "timeout defaults to 30000" {
    const args = try parseArgs(testing.allocator, &.{"Qenome"});
    defer testing.allocator.free(args.binds);
    try testing.expectEqual(default_timeout_ms, args.timeout_ms);
}

test "help exits 0" {
    const options = [_][:0]const u8{ "--help", "-h" };
    for (options) |option| {
        var stdout_buffer: [2048]u8 = undefined;
        var stderr_buffer: [512]u8 = undefined;
        const result = callRun(testing.allocator, &.{ "Qenome", option }, null, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, result.code);
        try testing.expectEqualStrings("", result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "usage: Qenome") != null);
    }
}

test "accepted run prints summary on stdout and nothing on stderr (exit 0)" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:int:1",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, fixture.db_path) != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, fixture.index_path) != null);
    try fixture.expectNoLeftovers();
}

test "accepted run prints plan and counters" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE b = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:text:x",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    // Every value after `measured-on` comes from the baseline snapshot, so
    // the line sits between the inputs and `rows` (D-304).
    const expected_head = try std.fmt.allocPrint(
        testing.allocator,
        "index-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: 1\n",
        .{fixture.index_path},
    );
    defer testing.allocator.free(expected_head);
    try testing.expect(std.mem.indexOf(u8, result.stdout, expected_head) != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite: " ++ sqlite.pinned_version ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sqlite-source-id: " ++ sqlite.pinned_source_id ++ "\n") != null);
    // The labels come before the raw detail, which ends the line.
    try testing.expect(std.mem.indexOf(u8, result.stdout, "kind=search covering=false automatic=false detail=SEARCH t USING INDEX idx_b") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "fullscan-steps: 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "vm-steps: ") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sort-ops: 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "autoindex-rows: 0\n") != null);
}

test "rejected run prints error on stderr (exit 1)" {
    var fixture = try CliFixture.init("INSERT INTO t VALUES (3, 'z')", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.startsWith(u8, result.stderr, "error: --select:"));
    try fixture.expectNoLeftovers();
}

test "engine details appear only when SQLite reported an error" {
    var fixture = try CliFixture.init("-- nothing to run\n", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "holds no statement") != null);
    // The empty statement never reached the engine, so its placeholder message
    // must not be printed.
    try testing.expect(std.mem.indexOf(u8, result.stderr, "not an error") == null);
}

test "an invalid statement reports the engine message" {
    var fixture = try CliFixture.init("SELECT nope FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "no such column: nope") != null);
}

test "bind mismatch is a rejection, not a usage error" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "2:int:1",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.startsWith(u8, result.stderr, "error: --bind:"));
}

test "a select whose plan depends on a bound parameter is accepted" {
    // SQLite re-prepares this statement on the first step because the bound
    // LIKE value decides the plan; the authorizer must allow it again.
    var fixture = try CliFixture.init("SELECT b FROM t WHERE b LIKE ?1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--bind",
        "1:text:x%",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 1") != null);
}

test "accepted run applies the index to the variant only" {
    var fixture = try CliFixture.init("SELECT a FROM t WHERE a = ?1", "CREATE INDEX idx_new ON t(a)");
    defer fixture.deinit();
    const before = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const first = fixture.run(&.{ "--bind", "1:int:1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, first.code);
    try testing.expectEqualStrings("", first.stderr);
    const baseline_block = summaryBlock(first.stdout, .baseline);
    const variant_block = summaryBlock(first.stdout, .variant);
    try testing.expect(contains(baseline_block, "rows: 1\n"));
    try testing.expect(contains(baseline_block, "detail=SCAN t\n"));
    try testing.expect(contains(variant_block, "measured-on: variant (candidate index applied)\nrows: 1\n"));
    try testing.expect(contains(variant_block, "detail=SEARCH t USING COVERING INDEX idx_new (a=?)\n"));
    try testing.expect(contains(variant_block, "fullscan-steps: 0\n"));
    try testing.expect(contains(first.stdout, "result: match (row multiset)\nrow-order: same (reference only; not part of the result)\n"));
    try fixture.expectNoLeftovers();

    // The database itself never got the index, so a second run can create
    // it again.
    const after = try Io.Dir.cwd().readFileAlloc(testing.io, fixture.db_path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    var second_stdout: [4096]u8 = undefined;
    var second_stderr: [1024]u8 = undefined;
    const second = fixture.run(&.{ "--bind", "1:int:1" }, &second_stdout, &second_stderr);
    try testing.expectEqual(ExitCode.ok, second.code);
    try testing.expectEqualStrings("", second.stderr);
}

test "an order-only difference is still a match with exit 0" {
    // The rows are stored as 3, 1, 2; the index hands them out as 1, 2, 3.
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > ?1", "CREATE INDEX idx_a ON t(a)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (3, 'z'), (1, 'x'), (2, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{ "--bind", "1:int:0" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.ok, run_result.code);
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "USING COVERING INDEX idx_a"));
    try testing.expect(contains(run_result.stdout, "result: match (row multiset)\nrow-order: differs (reference only;"));
}

test "a bare-column group by that differs exits 3" {
    // `b` is not grouped, so SQLite returns it from one row of the group,
    // picked by the order it reads them in; the index reverses that order
    // (D-505).
    var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.mismatch, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(run_result.stdout, "result: mismatch (row multiset; the cause is not determined)\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
    try testing.expect(contains(run_result.stdout, "baseline-only-row: [1, 'x']\nvariant-only-row: [1, 'y']\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "indexed by the candidate index is rejected with exit 1" {
    const cases = [_]struct { select: []const u8, index: []const u8, expected: []const u8 }{
        .{ .select = "SELECT a FROM t INDEXED BY IDX_NEW WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "names the candidate index 'idx_new' in INDEXED BY" },
        .{ .select = "SELECT a FROM t INDEXED BY \"Idx New\" WHERE a = 1", .index = "CREATE INDEX \"Idx New\" ON t(a)", .expected = "names the candidate index 'Idx New' in INDEXED BY" },
        // Another missing index keeps the engine message.
        .{ .select = "SELECT a FROM t INDEXED BY nope WHERE a = 1", .index = "CREATE INDEX idx_new ON t(a)", .expected = "no such index: nope" },
        // A CTE cannot use any index; SQLite quotes the name then, so it is
        // not mistaken for the candidate.
        .{ .select = "WITH c AS (SELECT a FROM t) SELECT a FROM c INDEXED BY idx_new", .index = "CREATE INDEX idx_new ON t(a)", .expected = "no such index: \"idx_new\"" },
    };
    for (cases) |case| {
        var fixture = try CliFixture.init(case.select, case.index);
        defer fixture.deinit();
        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.rejected, run_result.code);
        try testing.expectEqualStrings("", run_result.stdout);
        try testing.expect(std.mem.startsWith(u8, run_result.stderr, "error: --select: "));
        try testing.expect(contains(run_result.stderr, case.expected));
        try fixture.expectNoLeftovers();
    }
}

test "a unique index over duplicate rows exits 1" {
    var fixture = try CliFixture.init("SELECT a FROM t", "CREATE UNIQUE INDEX idx_b2 ON t(a)");
    defer fixture.deinit();
    // A second row with a = 1 lives in the database before the run.
    const writer = try db.openTestWriter(fixture.db_path, "INSERT INTO t VALUES (1, 'z')");
    _ = sqlite.sqlite3_close(writer);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.rejected, run_result.code);
    try testing.expectEqualStrings("", run_result.stdout);
    try testing.expect(contains(run_result.stderr, "error: --index-sql: the index could not be created on the variant: UNIQUE constraint failed"));
    try fixture.expectNoLeftovers();
}

test "an index build over the time limit exits 124 and leaves no temporary directory" {
    var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a = 1", "CREATE INDEX idx_b ON t(b)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
        \\INSERT INTO t SELECT x, 'v' || x FROM c;
    );
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{ "--timeout-ms", "1" }, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.timeout, run_result.code);
    try testing.expectEqualStrings("", run_result.stdout);
    try testing.expectEqualStrings("error: --index-sql exceeded the time limit of 1 ms\n", run_result.stderr);
    try fixture.expectNoLeftovers();
}

test "a timeout on the variant names the variant and is not a comparison" {
    // Only the variant run is measured here: a SELECT that is slow on the
    // variant alone cannot be built portably, so the step is driven directly.
    var fixture = try CliFixture.init(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c",
        "CREATE INDEX idx_a ON t(a)",
    );
    defer fixture.deinit();
    const sql = try readSqlFile(testing.io, testing.allocator, fixture.select_path);
    defer testing.allocator.free(sql);

    var database: db.Db = .{};
    try database.openReadOnly(fixture.db_path);
    defer database.close() catch unreachable;
    const statement = try database.prepareSelect(sql);
    defer _ = sqlite.sqlite3_finalize(statement);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var control = db.StepControl.init(testing.io, 1, &cancel);
    var budget: result_rows.Budget = .{};
    var rows = result_rows.RowCollector.init(testing.allocator, &budget);
    defer rows.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr = Io.Writer.fixed(&stderr_buffer);
    var failure: ExitCode = .ok;
    const inputs: Inputs = .{
        .database_path = fixture.db_path,
        .baseline_path = fixture.db_path,
        .variant_path = fixture.db_path,
        .select_path = fixture.select_path,
        .index_path = fixture.index_path,
        .select_sql = sql,
        .index_sql = "",
        .binds = &.{},
        .timeout_ms = 1,
    };
    try testing.expectEqual(@as(?Measurement, null), measure(arena_state.allocator(), &database, statement, inputs, &control, &rows, .variant, &stderr, &failure));
    try testing.expectEqual(ExitCode.timeout, failure);
    try testing.expectEqualStrings("error: --select exceeded the time limit of 1 ms on the variant\n", stderr.buffered());
}

test "result rows over the byte budget exit 4" {
    // 70 rows of 1 MiB each do not fit into the 64 MiB budget.
    var fixture = try CliFixture.init(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 70) SELECT zeroblob(1048576) FROM c",
        "CREATE INDEX idx_a ON t(a)",
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(summaryBlock(run_result.stdout, .baseline), "rows: 70\n"));
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "rows: 70\n"));
    try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the result rows exceed the 64 MiB kept for the comparison\nincomparable-hint: narrow the rows with WHERE (not LIMIT) and run again\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "a nondeterministic select exits 4 and still prints both plans" {
    var fixture = try CliFixture.init("SELECT a, random() FROM t WHERE a = 1", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expectEqualStrings("", run_result.stderr);
    try testing.expect(contains(summaryBlock(run_result.stdout, .baseline), "detail=SCAN t\n"));
    try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "detail=SEARCH t USING COVERING INDEX idx_a (a=?)\n"));
    // The rows were never compared, so no one-sided rows are shown.
    try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the SELECT calls random(), whose result changes between runs\nincomparable-hint: compare the SELECT without random()\nrow-order: not applicable\n"));
    try fixture.expectNoLeftovers();
}

test "a schema table select exits 4" {
    var fixture = try CliFixture.init("SELECT count(*) FROM sqlite_master", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expect(contains(run_result.stdout, "incomparable-reason: the SELECT reads sqlite_master, which describes the database itself\nincomparable-hint: SELECTs that read the schema tables are not compared\n"));
}

/// Rows stored with `a` as 3, 1, 2, 3, 1, 2, so an index on `a` hands them out
/// in another order. Summing `r` in the order of an index on `r` puts -1e16
/// and 1e16 at the ends, which changes the last digits of the sum even with
/// SQLite's compensated summation.
const reordered_schema: [:0]const u8 =
    \\CREATE TABLE t(a INTEGER, b TEXT, r REAL);
    \\INSERT INTO t VALUES (3, 'z', 0.1), (1, 'x', 0.2), (2, 'y', 0.3), (3, 'v', 1e16), (1, 'w', -1e16), (2, 'u', 0.7);
;

test "a limit select whose rows differ exits 4 and one that matches exits 0" {
    {
        var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE a > 0 LIMIT 2", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        // The one-sided rows are still shown for a mismatch that the LIMIT
        // explains.
        try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other rows when the order changes\nincomparable-hint: to compare, end the ORDER BY next to the LIMIT with a unique NOT NULL column, or drop LIMIT and OFFSET; then check that the plan still uses the candidate index\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
        try testing.expect(contains(run_result.stdout, "row-order: not applicable\n"));
    }
    {
        var fixture = try CliFixture.initWithSchema("SELECT a, b FROM t ORDER BY a, b LIMIT 2", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
}

test "a cte select whose rows differ exits 4" {
    var fixture = try CliFixture.initWithSchema("WITH c AS (SELECT a, b FROM t) SELECT a, b FROM c GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    try testing.expect(contains(run_result.stdout, "incomparable-reason: the rows differ, and the SELECT reads through a view or a WITH clause, which may pick rows by their order\nincomparable-hint: compare the SELECT inside the view or the WITH clause directly\n"));
}

test "an integer-only sum that matches exits 0 and a real sum that differs exits 4" {
    {
        var fixture = try CliFixture.initWithSchema("SELECT sum(a) FROM t", "CREATE INDEX idx_a ON t(a)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
    {
        var fixture = try CliFixture.initWithSchema("SELECT sum(r) FROM t", "CREATE INDEX idx_r ON t(r)", reordered_schema);
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        try testing.expect(contains(run_result.stdout, "incomparable-reason: the rows differ, and the SELECT calls sum(), whose result can depend on the order rows are read in\nincomparable-hint: sum() adds REAL values in the order they are read, so the results may differ only in the last digits; check the baseline-only-row and variant-only-row lines\nbaseline-only-rows: 1\nvariant-only-rows: 1\n"));
    }
}

test "a date function is compared, and a difference with it exits 4 with a hint" {
    {
        // An expression index on date(...) can be tried: the rows match.
        var fixture = try CliFixture.initWithSchema("SELECT a FROM t WHERE date(b) = ?1", "CREATE INDEX idx_db ON t(date(b))",
            \\CREATE TABLE t(a INTEGER, b TEXT);
            \\INSERT INTO t VALUES (1, '2026-03-15 10:00:00'), (2, '2026-03-16 09:00:00'), (3, '2026-03-15 23:59:59');
        );
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{ "--bind", "1:text:2026-03-15" }, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.ok, run_result.code);
        try testing.expect(contains(summaryBlock(run_result.stdout, .variant), "USING INDEX idx_db"));
        try testing.expect(contains(run_result.stdout, "result: match (row multiset)\n"));
    }
    {
        // The bare column `b` differs; the date function in the SELECT makes
        // that incomparable instead of a mismatch (D-512).
        var fixture = try CliFixture.initWithSchema("SELECT a, b, date('2026-01-01') FROM t GROUP BY a", "CREATE INDEX idx_ab ON t(a, b DESC)",
            \\CREATE TABLE t(a INTEGER, b TEXT);
            \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
        );
        defer fixture.deinit();
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
        try testing.expectEqual(ExitCode.incomparable, run_result.code);
        try testing.expect(contains(run_result.stdout, "result: incomparable\nincomparable-reason: the rows differ, and the SELECT calls date(), which can read the current time ('now' or no argument)\nincomparable-hint: if the SELECT reads the current time, bind a fixed time instead and run again\nbaseline-only-rows: 1\n"));
    }
}

test "several reasons come in pairs with their hints" {
    // The bare column `b` makes the rows differ; the SELECT also has an
    // aggregate, a LIMIT, and a WITH clause, so all three reasons apply.
    var fixture = try CliFixture.initWithSchema("WITH c AS (SELECT a, b FROM t) SELECT a, b, sum(a) FROM c GROUP BY a LIMIT 5", "CREATE INDEX idx_ab ON t(a, b DESC)",
        \\CREATE TABLE t(a INTEGER, b TEXT);
        \\INSERT INTO t VALUES (1, 'x'), (1, 'y');
    );
    defer fixture.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const run_result = fixture.run(&.{}, &stdout_buffer, &stderr_buffer);
    try testing.expectEqual(ExitCode.incomparable, run_result.code);
    // Each reason is followed by its own hint.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, run_result.stdout, "incomparable-reason: "));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, run_result.stdout, "incomparable-hint: "));
    try testing.expect(contains(run_result.stdout, "sum(), whose result can depend on the order rows are read in\nincomparable-hint: sum() adds REAL values"));
    try testing.expect(contains(run_result.stdout, "LIMIT or OFFSET, which can pick other rows when the order changes\nincomparable-hint: to compare"));
    try testing.expect(contains(run_result.stdout, "WITH clause, which may pick rows by their order\nincomparable-hint: compare the SELECT inside"));
}

test "order-dependent hints follow the kind of function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "avg"), "avg() adds REAL values in the order they are read"));
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "lag"), "end the ORDER BY in OVER (...) of lag() with a unique column"));
    try testing.expect(std.mem.startsWith(u8, orderHint(arena, "json_group_array"), "add ORDER BY inside json_group_array(...)"));
}

test "signal handler sets the cancel flag and keeps the first signal" {
    clearSignals();
    defer clearSignals();

    handleSignal(.TERM);
    handleSignal(.INT);
    try testing.expect(signalPending());
    try testing.expectEqual(@as(u8, @intCast(@backingInt(std.posix.SIG.TERM))), received_signal.load(.acquire));

    var buffer: [128]u8 = undefined;
    var stderr = Io.Writer.fixed(&buffer);
    try testing.expectEqual(ExitCode.terminated, reportInterrupted(&stderr));
    try testing.expectEqualStrings("error: interrupted by SIGTERM\n", stderr.buffered());
}

test "cleanup failure maps to exit 5 and keeps every other code" {
    try testing.expectEqual(ExitCode.cleanup, finalExitCode(.ok, true));
    try testing.expectEqual(ExitCode.ok, finalExitCode(.ok, false));
    try testing.expectEqual(ExitCode.rejected, finalExitCode(.rejected, true));
    try testing.expectEqual(ExitCode.usage, finalExitCode(.usage, true));
    try testing.expectEqual(ExitCode.timeout, finalExitCode(.timeout, true));
    try testing.expectEqual(ExitCode.interrupted, finalExitCode(.interrupted, true));
    try testing.expectEqual(ExitCode.terminated, finalExitCode(.terminated, true));
    try testing.expectEqual(ExitCode.hangup, finalExitCode(.hangup, true));
    // A mismatch or an incomparable result is not a success, so it keeps its
    // code (D-506).
    try testing.expectEqual(ExitCode.mismatch, finalExitCode(.mismatch, true));
    try testing.expectEqual(ExitCode.incomparable, finalExitCode(.incomparable, true));
    // The other half of this path is the real close failure in the db test
    // "a failed close keeps the connection for the caller", which sets
    // `cleanup_failed` by returning `error.CloseFailed`.
}

test "timeout exits 124" {
    var fixture = try CliFixture.init(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c",
        "CREATE INDEX idx_a ON t(a)",
    );
    defer fixture.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
        "--timeout-ms",
        "1",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.timeout, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "time limit") != null);
    try fixture.expectNoLeftovers();
}

test "pre-set cancel flag exits 130" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    signal_flag.store(true, .release);
    defer clearSignals();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.interrupted, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "SIGINT") != null);
    try fixture.expectNoLeftovers();
}

test "pre-set SIGTERM and SIGHUP exit 143 and 129" {
    const cases = [_]struct { sig: std.posix.SIG, code: ExitCode, name: []const u8 }{
        .{ .sig = .TERM, .code = .terminated, .name = "SIGTERM" },
        .{ .sig = .HUP, .code = .hangup, .name = "SIGHUP" },
    };
    for (cases) |case| {
        var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
        defer fixture.deinit();

        clearSignals();
        handleSignal(case.sig);
        defer clearSignals();

        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        const result = callRun(testing.allocator, &.{
            "Qenome",
            "--db",
            fixture.db_path,
            "--select",
            fixture.select_path,
            "--index-sql",
            fixture.index_path,
        }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

        try testing.expectEqual(case.code, result.code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, case.name) != null);
        try fixture.expectNoLeftovers();
    }
}

test "a missing temporary directory parent exits 1" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/nope", .{fixture.work_parent});
    defer testing.allocator.free(missing);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, missing, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "temporary directory") != null);
}

test "an unset or empty TMPDIR means /tmp" {
    try testing.expectEqualStrings("/tmp", tempParentPath(null));
    try testing.expectEqualStrings("/tmp", tempParentPath(""));
    try testing.expectEqualStrings("rel/dir", tempParentPath("rel/dir"));
}

test "a missing database exits 1 and leaves no temporary directory" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();
    const missing = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/missing.db", .{fixture.work_parent}, 0);
    defer testing.allocator.free(missing);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        missing,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.rejected, result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "cannot open") != null);
    try fixture.expectNoLeftovers();
}

test "the work directory is private and the variant is a byte copy of the baseline" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_a ON t(a)");
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var work = try WorkDir.create(testing.io, arena_state.allocator(), fixture.work_parent);
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
    try testing.expect(!cleanup_failed);
    try testing.expectEqualStrings("", stderr.buffered());
    try fixture.expectNoLeftovers();
}

test "a run on a wal database counts rows that are still in the wal" {
    // The table exists only as WAL frames, so every row must come through
    // the snapshot.
    var fixture = try CliFixture.init("SELECT a FROM w", "CREATE INDEX idx_w ON w(a)");
    defer fixture.deinit();
    const wal_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/../wal.db", .{fixture.work_parent}, 0);
    defer testing.allocator.free(wal_path);
    const writer = try db.openTestWriter(wal_path,
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA wal_autocheckpoint=0;
        \\CREATE TABLE w(a INTEGER);
        \\INSERT INTO w VALUES (1), (2), (3);
    );
    defer _ = sqlite.sqlite3_close(writer);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const result = callRun(testing.allocator, &.{
        "Qenome",
        "--db",
        wal_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 3\n") != null);
    try fixture.expectNoLeftovers();
}
