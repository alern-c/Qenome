//! Process exit codes, interruption state, and the diagnostic that names the
//! signal that stopped a run.
//!
//! The signal handler writes one atomic flag and one atomic number; readers
//! borrow the flag through `cancelFlag` instead of owning it.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

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
pub fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = received_signal.cmpxchgStrong(0, @intCast(@backingInt(sig)), .release, .monotonic);
    signal_flag.store(true, .release);
}

/// Routes SIGINT, SIGTERM and SIGHUP to the flag. `SA.RESTART` keeps the
/// handler itself to atomic stores and lets interrupted syscalls continue.
pub fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (handled_signals) |sig| std.posix.sigaction(sig, &action, null);
}

pub fn clearSignals() void {
    signal_flag.store(false, .release);
    received_signal.store(0, .release);
}

pub fn signalPending() bool {
    return signal_flag.load(.acquire);
}

/// D-105=案1: after a run that would have exited 0 a cleanup failure is
/// reported with exit code 5. A rejection, usage error, mismatch,
/// incomparable result, timeout, or interruption keeps its own code (D-506).
/// The diagnostic itself is always written where the failure is found.
pub fn finalExitCode(code: ExitCode, cleanup_failed: bool) ExitCode {
    if (cleanup_failed and code == .ok) return .cleanup;
    return code;
}

/// Reports the first signal that arrived. A flag set without a number (a
/// test, or a platform without signals) counts as SIGINT.
pub fn reportInterrupted(stderr: *Io.Writer) ExitCode {
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

/// The cancel flag as a borrow, so that a step control can read the same flag
/// the signal handler writes without owning it.
pub fn cancelFlag() *std.atomic.Value(bool) {
    return &signal_flag;
}

/// The number of the first signal that set the flag, or 0. Tests read it to
/// check what the handler kept.
pub fn receivedSignal() u8 {
    return received_signal.load(.acquire);
}

const testing = std.testing;

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

test "the step control borrows the cancel flag the signal handler writes" {
    clearSignals();
    defer clearSignals();

    // A step control borrows this very flag, so a signal that arrives while a
    // statement runs is seen by the statement.
    const borrowed = cancelFlag();
    try testing.expect(!borrowed.load(.monotonic));
    handleSignal(.INT);
    try testing.expect(borrowed.load(.monotonic));
    try testing.expectEqual(@as(u8, @intCast(@backingInt(std.posix.SIG.INT))), receivedSignal());
    // Every borrow is the same flag; the handler cannot be writing another.
    try testing.expect(borrowed == cancelFlag());
}
