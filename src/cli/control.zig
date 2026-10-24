const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const ExitCode = enum(u8) {
    ok = 0,
    rejected = 1,
    usage = 2,
    mismatch = 3,
    incomparable = 4,
    cleanup = 5,
    timeout = 124,
    hangup = 129,
    interrupted = 130,
    terminated = 143,
};

const supports_signals = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

const handled_signals = if (supports_signals)
    [_]std.posix.SIG{ .INT, .TERM, .HUP }
else
    [_]std.posix.SIG{};

var signal_flag: std.atomic.Value(bool) = .init(false);

var received_signal: std.atomic.Value(u8) = .init(0);

pub fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = received_signal.cmpxchgStrong(0, @intCast(@backingInt(sig)), .release, .monotonic);
    signal_flag.store(true, .release);
}

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

pub fn finalExitCode(code: ExitCode, cleanup_failed: bool) ExitCode {
    if (cleanup_failed and code == .ok) return .cleanup;
    return code;
}

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

pub fn cancelFlag() *std.atomic.Value(bool) {
    return &signal_flag;
}

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
    try testing.expectEqual(ExitCode.mismatch, finalExitCode(.mismatch, true));
    try testing.expectEqual(ExitCode.incomparable, finalExitCode(.incomparable, true));
}

test "the step control borrows the cancel flag the signal handler writes" {
    clearSignals();
    defer clearSignals();

    const borrowed = cancelFlag();
    try testing.expect(!borrowed.load(.monotonic));
    handleSignal(.INT);
    try testing.expect(borrowed.load(.monotonic));
    try testing.expectEqual(@as(u8, @intCast(@backingInt(std.posix.SIG.INT))), receivedSignal());
    try testing.expect(borrowed == cancelFlag());
}
