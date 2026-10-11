//! Command line contract for Qenome.
//!
//! `run` takes a database path, one read-only SELECT file, one candidate
//! CREATE INDEX file, typed bind values, and an optional time limit. The
//! database is opened read-only and copied as one snapshot (`baseline`) into a
//! private temporary directory; the baseline is then copied byte for byte to
//! `variant`. The candidate DDL is only validated, and the SELECT is executed
//! on the baseline to count its rows. The summary also shows the SQLite
//! release, the query plan, and the execution counters of the SELECT. The
//! temporary directory is removed on every return path.
//!
//! Every outcome is a process exit code:
//!
//! * 0: the SELECT was accepted and executed
//! * 1: an input was rejected (file, database, snapshot, temporary directory,
//!   SQL, DDL, bind, query plan, step)
//! * 2: the arguments cannot be used
//! * 5: a connection or the temporary directory could not be cleaned up after
//!   an otherwise successful run
//! * 124: the time limit interrupted the SELECT
//! * 129 / 130 / 143: SIGHUP / SIGINT / SIGTERM interrupted the run

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const db = @import("db.zig");
const sqlite = @import("sqlite.zig");

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
    /// Time limit for the SELECT execution; `0` disables it.
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
        \\local SQLite database, then runs the SELECT and reports its row count,
        \\the SQLite release, the query plan, and the execution counters.
        \\The database is opened read-only and copied as one snapshot into a
        \\private directory under $TMPDIR (default /tmp); the SELECT runs on
        \\that copy, and the directory is removed before exit. The candidate
        \\DDL is not applied.
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
        \\  --timeout-ms <MS>    statement time limit, 0 disables it (default 30000)
        \\  --help, -h           print this message and exit with status 0
        \\
        \\exit status: 0 accepted, 1 rejected, 2 usage error, 5 cleanup failure,
        \\124 time limit reached, 129 / 130 / 143 interrupted by SIGHUP /
        \\SIGINT / SIGTERM
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
            .measured_path = work.baseline_path,
            .select_path = select_path,
            .index_path = index_path,
            .select_sql = select_sql,
            .index_sql = index_sql,
            .binds = args.binds,
            .timeout_ms = args.timeout_ms,
        };
        break :blk runChecked(io, arena, inputs, stdout, stderr, &cleanup_failed);
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
    /// The snapshot that the checks and the run use.
    measured_path: [:0]const u8,
    select_path: [:0]const u8,
    index_path: [:0]const u8,
    select_sql: [:0]const u8,
    index_sql: [:0]const u8,
    binds: []const db.BindArg,
    timeout_ms: u64,
};

/// D-105=案1: after an otherwise successful run a cleanup failure is reported
/// with exit code 5. A rejection, usage error, timeout, or interruption keeps
/// its own code. The diagnostic itself is always written where the failure is
/// found.
pub fn finalExitCode(code: ExitCode, cleanup_failed: bool) ExitCode {
    if (cleanup_failed and code == .ok) return .cleanup;
    return code;
}

/// Opens the baseline and walks the accepted order: check the SELECT, bind,
/// check the candidate DDL, read the query plan, then run the SELECT.
/// `cleanup_failed` is set when the connection cannot be closed. The plan
/// lives in `arena`.
fn runChecked(
    io: Io,
    arena: std.mem.Allocator,
    inputs: Inputs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cleanup_failed: *bool,
) ExitCode {
    // A signal that arrived before the SELECT started still stops the run.
    if (signalPending()) return reportInterrupted(stderr);

    var database: db.Db = .{};
    database.openReadOnly(inputs.measured_path) catch |err| {
        stderr.print("error: cannot open the baseline '{s}' read-only: {s}\n", .{ inputs.measured_path, openErrorMessage(err) }) catch {};
        return .rejected;
    };
    defer database.close() catch {
        cleanup_failed.* = true;
        stderr.print("error: the database connection could not be closed: {s}\n", .{database.message()}) catch {};
    };

    const statement = database.prepareSelect(inputs.select_sql) catch |err| {
        reportCheckFailure(stderr, "--select", err, &database);
        return .rejected;
    };
    // Declared after the `database.close` defer, so `finalize` always runs
    // first, on every return path (D-105=案1).
    defer _ = sqlite.sqlite3_finalize(statement);

    db.bindAll(statement, inputs.binds) catch |err| {
        stderr.print("error: --bind: {s}\n", .{bindErrorMessage(err)}) catch {};
        return .rejected;
    };

    database.checkCreateIndex(inputs.index_sql) catch |err| {
        reportCheckFailure(stderr, "--index-sql", err, &database);
        return .rejected;
    };

    // The plan is read before the run, from a statement of its own (D-302).
    // The same SQL and binds were accepted above, so a failure here is the
    // plan read itself or memory. Like prepare and bind, it is outside the
    // time limit.
    const plan = database.explainPlan(arena, inputs.select_sql, inputs.binds) catch |err| {
        const detail = if (err == error.ExplainFailed and database.errorCode() != sqlite.SQLITE_OK)
            database.message()
        else
            @errorName(err);
        stderr.print("error: --select: the query plan could not be read: {s}\n", .{detail}) catch {};
        return .rejected;
    };

    // The time limit and the signal flag cover the SELECT execution only, so
    // the control is built here and the deadline starts inside `stepAll`.
    var control = db.StepControl.init(io, inputs.timeout_ms, &signal_flag);
    const rows = database.stepAll(statement, &control) catch |err| switch (err) {
        error.Timeout => {
            stderr.print("error: --select exceeded the time limit of {d} ms\n", .{inputs.timeout_ms}) catch {};
            return .timeout;
        },
        error.Interrupted => return reportInterrupted(stderr),
        error.StepFailed => {
            stderr.print("error: --select failed while running: {s}\n", .{database.message()}) catch {};
            return .rejected;
        },
    };

    // A signal that arrives after the last progress check but before the run
    // ends still wins over the summary.
    if (signalPending()) return reportInterrupted(stderr);

    // The summary is the result of the run, so a failed write is a rejection.
    // It is written only here, after a finished run, so a rejection, timeout,
    // or interruption leaves stdout empty.
    writeSummary(stdout, inputs, rows, plan, db.statementCounters(statement)) catch {
        stderr.print("error: the summary could not be written\n", .{}) catch {};
        return .rejected;
    };
    return .ok;
}

/// Writes the accepted summary as `key: value` lines. A plan line keeps its
/// SQLite detail last because the detail contains spaces.
///
/// `measured-on` comes right before `rows` because every value after it was
/// measured on the baseline snapshot of `db`: the candidate index is only
/// checked, so a `SCAN` or a full scan count below is not the effect of that
/// index (D-304).
fn writeSummary(
    stdout: *Io.Writer,
    inputs: Inputs,
    rows: u64,
    plan: db.Plan,
    counters: db.Counters,
) Io.Writer.Error!void {
    try stdout.print("db: {s}\nselect: {s}\nindex-sql: {s}\nmeasured-on: baseline (candidate index not applied)\nrows: {d}\n", .{
        inputs.database_path, inputs.select_path, inputs.index_path, rows,
    });
    try stdout.print("sqlite: {s}\nsqlite-source-id: {s}\n", .{
        sqlite.sqlite3_libversion(), sqlite.sqlite3_sourceid(),
    });
    for (plan.rows) |row| {
        try stdout.print("plan: id={d} parent={d} kind={t} covering={} automatic={} detail={s}\n", .{
            row.id, row.parent, row.label.kind, row.label.covering, row.label.automatic, row.detail,
        });
    }
    try stdout.print("fullscan-steps: {d}\nvm-steps: {d}\nsort-ops: {d}\nautoindex-rows: {d}\n", .{
        counters.fullscan_steps, counters.vm_steps, counters.sort_ops, counters.autoindex_rows,
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
        var dir = try Fixture.init();
        errdefer dir.deinit();
        const db_path = try dir.file("fixture.db", "");
        errdefer testing.allocator.free(db_path);
        try db.createTestDatabase(db_path, fixture_schema);
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

    var stdout_buffer: [2048]u8 = undefined;
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
        "1:text:x%",
    }, fixture.work_parent, &stdout_buffer, &stderr_buffer);

    try testing.expectEqual(ExitCode.ok, result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "rows: 1") != null);
}

test "the candidate ddl is validated but not applied" {
    var fixture = try CliFixture.init("SELECT count(*) FROM t", "CREATE INDEX idx_new ON t(a)");
    defer fixture.deinit();

    const argv = [_][:0]const u8{
        "Qenome",
        "--db",
        fixture.db_path,
        "--select",
        fixture.select_path,
        "--index-sql",
        fixture.index_path,
    };
    var first_stdout: [1024]u8 = undefined;
    var first_stderr: [1024]u8 = undefined;
    const first = callRun(testing.allocator, &argv, fixture.work_parent, &first_stdout, &first_stderr);
    try testing.expectEqual(ExitCode.ok, first.code);

    // A second run still succeeds: the index was never created, so
    // "CREATE INDEX idx_new" is not rejected as an existing name.
    var second_stdout: [1024]u8 = undefined;
    var second_stderr: [1024]u8 = undefined;
    const second = callRun(testing.allocator, &argv, fixture.work_parent, &second_stdout, &second_stderr);
    try testing.expectEqual(ExitCode.ok, second.code);
    try testing.expectEqualStrings("", second.stderr);
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

test "cleanup failure maps to exit 5 and does not override an earlier failure" {
    try testing.expectEqual(ExitCode.cleanup, finalExitCode(.ok, true));
    try testing.expectEqual(ExitCode.ok, finalExitCode(.ok, false));
    try testing.expectEqual(ExitCode.rejected, finalExitCode(.rejected, true));
    try testing.expectEqual(ExitCode.usage, finalExitCode(.usage, true));
    try testing.expectEqual(ExitCode.timeout, finalExitCode(.timeout, true));
    try testing.expectEqual(ExitCode.interrupted, finalExitCode(.interrupted, true));
    try testing.expectEqual(ExitCode.terminated, finalExitCode(.terminated, true));
    try testing.expectEqual(ExitCode.hangup, finalExitCode(.hangup, true));
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

    var stdout_buffer: [2048]u8 = undefined;
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
