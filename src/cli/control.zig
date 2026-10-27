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

const supports_console_ctrl = builtin.os.tag == .windows;

const windows = std.os.windows;

const ctrl_c_event: windows.DWORD = 0;

const ctrl_break_event: windows.DWORD = 1;

const sigint_number: u8 = 2;

const console_ctrl_handler = *const fn (ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleCtrlHandler(handler: ?console_ctrl_handler, add: windows.BOOL) callconv(.winapi) windows.BOOL;

var signal_flag: std.atomic.Value(bool) = .init(false);

var received_signal: std.atomic.Value(u8) = .init(0);

fn recordSignal(number: u8) void {
    _ = received_signal.cmpxchgStrong(0, number, .release, .monotonic);
    signal_flag.store(true, .release);
}

pub fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    recordSignal(@intCast(@backingInt(sig)));
}

fn handleConsoleCtrl(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    if (ctrl_type != ctrl_c_event and ctrl_type != ctrl_break_event) return .FALSE;
    recordSignal(sigint_number);
    return .TRUE;
}

fn installConsoleCtrlHandler() void {
    _ = SetConsoleCtrlHandler(handleConsoleCtrl, .TRUE);
}

pub fn installSignalHandlers() void {
    if (comptime supports_console_ctrl) {
        installConsoleCtrlHandler();
        return;
    }
    if (comptime !supports_signals) return;
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

const error_schema_version: u8 = 2;

const max_error_slots = 4;

const ErrorClass = struct {
    code: []const u8,
    hint: []const u8,
};

pub fn classifyError(message: []const u8) ErrorClass {
    if (std.mem.startsWith(u8, message, "interrupted by SIGTERM")) {
        return .{ .code = "terminated", .hint = "Rerun the command. Temporary copies are removed when the signal is handled." };
    }
    if (std.mem.startsWith(u8, message, "interrupted by SIGHUP")) {
        return .{ .code = "hangup", .hint = "Rerun the command. Temporary copies are removed when the signal is handled." };
    }
    if (std.mem.startsWith(u8, message, "interrupted by SIGINT")) {
        return .{ .code = "interrupted", .hint = "Rerun the command. Temporary copies are removed when the signal is handled." };
    }
    if (std.mem.startsWith(u8, message, "cannot read the batch manifest")) {
        return .{ .code = "batch_manifest_unreadable", .hint = "Check that the manifest path exists and is readable, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "the batch manifest") != null) {
        return .{ .code = "batch_manifest_invalid", .hint = "Fix the manifest: exactly queries and candidates, 1 to 100 entries each, no repeated paths, and valid N:TYPE:VALUE binds." };
    }
    if (std.mem.startsWith(u8, message, "cannot read the batch SQL file")) {
        return .{ .code = "batch_sql_unreadable", .hint = "Check the SQL paths in the manifest; they are relative to the manifest file." };
    }
    if (std.mem.startsWith(u8, message, "--batch ")) {
        return .{ .code = "usage_batch_conflict", .hint = "With --batch, put the SELECT, CREATE INDEX and binds in the manifest. Use --format human or json, and do not pass --runs." };
    }
    if (std.mem.indexOf(u8, message, "the batch baseline SELECT") != null and std.mem.indexOf(u8, message, "exceeded the time limit") != null) {
        return .{ .code = "batch_baseline_timeout", .hint = "Raise --timeout-ms, or narrow the SELECT in the manifest." };
    }
    if (std.mem.indexOf(u8, message, "the batch diagnostics") != null) {
        if (std.mem.indexOf(u8, message, "exceeded the time limit") != null) {
            return .{ .code = "batch_variant_timeout", .hint = "Raise --timeout-ms, or simplify the candidate CREATE INDEX in the manifest." };
        }
        return .{ .code = "batch_variant_failed", .hint = "Read the SQLite message. The run stopped before writing the batch report; rerun after fixing it." };
    }
    if (std.mem.indexOf(u8, message, "the batch variant") != null) {
        return .{ .code = "batch_variant_failed", .hint = "Read the SQLite message. The run stopped before writing the batch report; rerun after fixing it." };
    }
    if (std.mem.indexOf(u8, message, "the batch query") != null or std.mem.indexOf(u8, message, "the batch baseline") != null) {
        return .{ .code = "batch_baseline_failed", .hint = "Fix the SELECT in the manifest or read the SQLite message, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "the batch candidate") != null) {
        if (std.mem.indexOf(u8, message, "the index could not be created") != null or std.mem.indexOf(u8, message, "--index-sql") != null) {
            return .{ .code = "batch_index_failed", .hint = "Fix the candidate CREATE INDEX in the manifest so it applies to this database, then rerun." };
        }
        return .{ .code = "batch_workspace_failed", .hint = "Check the temporary directory and its permissions, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "no wrangler config") != null) {
        return .{ .code = "d1_config_not_found", .hint = "Pass --config <PATH>, or run qenome in the wrangler project directory." };
    }
    if (std.mem.indexOf(u8, message, "more than one wrangler config") != null) {
        return .{ .code = "d1_config_ambiguous", .hint = "Pass --config <PATH> naming one wrangler.toml, wrangler.jsonc, or wrangler.json." };
    }
    if (std.mem.indexOf(u8, message, "cannot read the wrangler config") != null) {
        return .{ .code = "d1_config_unreadable", .hint = "Check that the config path exists and is readable, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "must name a .toml") != null) {
        return .{ .code = "d1_config_unsupported", .hint = "Pass a wrangler.toml, wrangler.jsonc, or wrangler.json file with --config." };
    }
    if (std.mem.indexOf(u8, message, "cannot use the wrangler config") != null) {
        return .{ .code = "d1_config_invalid", .hint = "Fix the config syntax, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "no top-level d1_databases binding") != null) {
        return .{ .code = "d1_binding_not_found", .hint = "Use a binding name from the top-level d1_databases entries in the config." };
    }
    if (std.mem.indexOf(u8, message, "more than one d1_databases binding") != null) {
        return .{ .code = "d1_binding_ambiguous", .hint = "Keep one top-level d1_databases entry with that binding name." };
    }
    if (std.mem.indexOf(u8, message, "no database_id and no preview_database_id") != null) {
        return .{ .code = "d1_database_id_missing", .hint = "Set database_id or preview_database_id on the binding." };
    }
    if (std.mem.indexOf(u8, message, "no local D1 database") != null) {
        return .{ .code = "d1_local_file_missing", .hint = "Create the local database with npx wrangler d1 execute <BINDING> --local --command \"SELECT 1\", or run npx wrangler dev and use the database once." };
    }
    if (std.mem.indexOf(u8, message, "cannot open the local D1 database") != null) {
        return .{ .code = "d1_local_file_unreadable", .hint = "Check that the local .sqlite file is readable, then rerun." };
    }
    if (std.mem.startsWith(u8, message, "missing:")) {
        return .{ .code = "usage_missing", .hint = "Pass the database (a path, --db, or --d1), the SELECT file, and the CREATE INDEX file. See --help." };
    }
    if (std.mem.indexOf(u8, message, "unknown option") != null) {
        return .{ .code = "usage_unknown_option", .hint = "See --help for the option names." };
    }
    if (std.mem.indexOf(u8, message, "needs a value") != null or std.mem.indexOf(u8, message, "missing its value") != null) {
        return .{ .code = "usage_missing_value", .hint = "Repeat the option with a value, for example --db app.db." };
    }
    if (std.mem.indexOf(u8, message, "more than once") != null and std.mem.indexOf(u8, message, "bind number") != null) {
        return .{ .code = "bind_rejected", .hint = "Give each SELECT parameter exactly one --bind N:TYPE:VALUE." };
    }
    if (std.mem.indexOf(u8, message, "more than once") != null) {
        return .{ .code = "usage_duplicate", .hint = "Pass that option once." };
    }
    if (std.mem.indexOf(u8, message, "unexpected argument") != null or std.mem.indexOf(u8, message, "too many paths") != null or std.mem.indexOf(u8, message, "takes two paths") != null) {
        return .{ .code = "usage_too_many_paths", .hint = "Pass at most the database, the SELECT file, and the CREATE INDEX file. With --d1, pass only those two SQL files." };
    }
    if (std.mem.indexOf(u8, message, "a path cannot be empty") != null) {
        return .{ .code = "usage_empty_path", .hint = "Pass a non-empty path." };
    }
    if (std.mem.indexOf(u8, message, "does not take a value") != null or std.mem.indexOf(u8, message, "takes no value") != null) {
        return .{ .code = "usage_unexpected_value", .hint = "Remove the value from that flag." };
    }
    if (std.mem.indexOf(u8, message, "--format expects") != null) {
        return .{ .code = "usage_format", .hint = "Use --format human, --format kv, or --format json." };
    }
    if (std.mem.indexOf(u8, message, "--runs expects") != null) {
        return .{ .code = "usage_runs", .hint = "Use an integer from 0 to 1000." };
    }
    if (std.mem.indexOf(u8, message, "--timeout-ms expects") != null) {
        return .{ .code = "usage_timeout", .hint = "Use a non-negative integer number of milliseconds. 0 disables the limit." };
    }
    if (std.mem.indexOf(u8, message, "--bind expects") != null) {
        return .{ .code = "usage_bind", .hint = "Use --bind <N>:<TYPE>[:<VALUE>], for example --bind 1:int:1234." };
    }
    if (std.mem.indexOf(u8, message, "use either --db") != null) {
        return .{ .code = "usage_conflicting_database", .hint = "Pass --db or --d1, not both." };
    }
    if (std.mem.indexOf(u8, message, "--config is only used with --d1") != null) {
        return .{ .code = "usage_config_requires_d1", .hint = "Add --d1 <BINDING>, or drop --config." };
    }
    if (std.mem.indexOf(u8, message, "out of memory") != null) {
        return .{ .code = "out_of_memory", .hint = "Free memory and rerun the same command." };
    }
    if (std.mem.indexOf(u8, message, "cannot read --select") != null) {
        return .{ .code = "select_unreadable", .hint = "--select takes a path to a file that holds one SELECT, not the SQL text." };
    }
    if (std.mem.indexOf(u8, message, "cannot read --index-sql") != null) {
        return .{ .code = "index_unreadable", .hint = "--index-sql takes a path to a file that holds one CREATE INDEX, not the SQL text." };
    }
    if (std.mem.indexOf(u8, message, "cannot create a temporary directory") != null) {
        return .{ .code = "workspace_failed", .hint = "Check that the temporary directory exists and is writable, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "--index-sql exceeded the time limit") != null) {
        return .{ .code = "index_timeout", .hint = "Raise --timeout-ms, or simplify the CREATE INDEX." };
    }
    if (std.mem.indexOf(u8, message, "--select exceeded the time limit") != null) {
        return .{ .code = "select_timeout", .hint = "Raise --timeout-ms, or narrow the SELECT." };
    }
    if (std.mem.indexOf(u8, message, "the index could not be created") != null) {
        return .{ .code = "index_rejected", .hint = "Fix the CREATE INDEX so it applies to this database, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "INDEXED BY") != null) {
        return .{ .code = "indexed_by_rejected", .hint = "Remove INDEXED BY of the candidate index, or compare a SELECT that does not name it." };
    }
    if (std.mem.indexOf(u8, message, "the query plan could not be read") != null) {
        return .{ .code = "plan_unreadable", .hint = "Check the SELECT against this database, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "--select failed while running") != null) {
        return .{ .code = "select_failed", .hint = "Read the SQLite message in the error and fix the SELECT." };
    }
    if (std.mem.indexOf(u8, message, "the statement is") != null or std.mem.indexOf(u8, message, "the file holds") != null or std.mem.indexOf(u8, message, "the file must hold") != null) {
        return .{ .code = "statement_rejected", .hint = "The SELECT file must be one read-only SELECT and the index file one CREATE INDEX. If the files are swapped, exchange them." };
    }
    if (std.mem.indexOf(u8, message, "cannot open") != null) {
        return .{ .code = "database_unreadable", .hint = "Check that the file exists, is a SQLite database, and is not locked." };
    }
    if (std.mem.indexOf(u8, message, "--bind") != null) {
        return .{ .code = "bind_rejected", .hint = "Give each SELECT parameter exactly one --bind N:TYPE:VALUE." };
    }
    if (std.mem.indexOf(u8, message, "could not be closed") != null) {
        return .{ .code = "connection_close_failed", .hint = "Rerun. If it repeats, SQLite could not close the connection." };
    }
    if (std.mem.indexOf(u8, message, "locked") != null) {
        return .{ .code = "snapshot_locked", .hint = "Close other connections to the database and rerun." };
    }
    if (std.mem.indexOf(u8, message, "cannot copy") != null) {
        return .{ .code = "snapshot_failed", .hint = "Check disk space and permissions on the temporary directory, then rerun." };
    }
    if (std.mem.indexOf(u8, message, "cannot read the size") != null) {
        return .{ .code = "size_unreadable", .hint = "Rerun. If it repeats, the temporary copy could not be stat'ed." };
    }
    if (std.mem.indexOf(u8, message, "could not be removed") != null) {
        return .{ .code = "cleanup_failed", .hint = "Remove the named temporary directory manually. The comparison result was already written when this follows a report." };
    }
    if (std.mem.indexOf(u8, message, "the summary could not be written") != null) {
        return .{ .code = "report_failed", .hint = "Rerun. The comparison finished, but the report could not be written." };
    }
    return .{ .code = "unclassified", .hint = "Read the message, fix the command, and rerun. qenome --help lists the options and exit codes." };
}

const ErrorSlot = struct {
    message: [2048]u8 = undefined,
    message_len: usize = 0,
    hint: [512]u8 = undefined,
    hint_len: usize = 0,
    has_hint: bool = false,

    fn messageText(self: *const ErrorSlot) []const u8 {
        return self.message[0..self.message_len];
    }

    fn hintText(self: *const ErrorSlot) []const u8 {
        return self.hint[0..self.hint_len];
    }
};

const json_stderr_vtable: Io.Writer.VTable = .{
    .drain = jsonStderrDrain,
};

pub const JsonStderr = struct {
    inner: *Io.Writer,
    writer: Io.Writer,
    pending: [8192]u8 = undefined,
    pending_len: usize = 0,
    slots: [max_error_slots]ErrorSlot = .{ .{}, .{}, .{}, .{} },
    count: usize = 0,

    pub fn init(inner: *Io.Writer) JsonStderr {
        return .{
            .inner = inner,
            .writer = .{
                .vtable = &json_stderr_vtable,
                .buffer = &.{},
            },
        };
    }

    pub fn finish(self: *JsonStderr, exit_code: ExitCode) void {
        if (self.pending_len != 0) self.finishLine();
        if (self.count == 0) return;
        var buffer: [16384]u8 = undefined;
        var out = Io.Writer.fixed(&buffer);
        self.writeJson(&out, exit_code) catch {
            self.fallback();
            return;
        };
        self.inner.writeAll(out.buffered()) catch {};
    }

    fn feed(self: *JsonStderr, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n') {
                self.finishLine();
                continue;
            }
            if (self.pending_len < self.pending.len) {
                self.pending[self.pending_len] = byte;
                self.pending_len += 1;
            }
        }
    }

    fn finishLine(self: *JsonStderr) void {
        var line = self.pending[0..self.pending_len];
        self.pending_len = 0;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) return;
        if (std.mem.startsWith(u8, line, "progress:")) {
            self.inner.writeAll(line) catch {};
            self.inner.writeByte('\n') catch {};
            return;
        }
        if (std.mem.startsWith(u8, line, "hint: ")) {
            self.storeHint(line["hint: ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "error: ")) {
            self.storeError(line["error: ".len..]);
        }
    }

    fn storeError(self: *JsonStderr, message: []const u8) void {
        if (self.count >= self.slots.len) return;
        const slot = &self.slots[self.count];
        slot.message_len = copyUtf8(&slot.message, message);
        slot.has_hint = false;
        slot.hint_len = 0;
        self.count += 1;
    }

    fn storeHint(self: *JsonStderr, hint: []const u8) void {
        if (self.count == 0) return;
        const slot = &self.slots[self.count - 1];
        slot.hint_len = copyUtf8(&slot.hint, hint);
        slot.has_hint = slot.hint_len != 0;
    }

    fn writeJson(self: *JsonStderr, out: *Io.Writer, exit_code: ExitCode) !void {
        var json: std.json.Stringify = .{
            .writer = out,
            .options = .{ .whitespace = .minified },
        };
        try json.beginObject();
        try json.objectField("schema_version");
        try json.write(error_schema_version);
        try json.objectField("exit_code");
        try json.write(@as(u8, @intCast(@backingInt(exit_code))));
        try json.objectField("error");
        try writeSlot(&json, &self.slots[0]);
        if (self.count > 1) {
            try json.objectField("also");
            try json.beginArray();
            for (self.slots[1..self.count]) |*slot| try writeSlot(&json, slot);
            try json.endArray();
        }
        try json.endObject();
        try out.writeByte('\n');
    }

    fn fallback(self: *JsonStderr) void {
        for (self.slots[0..self.count]) |*slot| {
            self.inner.print("error: {s}\n", .{slot.messageText()}) catch {};
            if (slot.has_hint) self.inner.print("hint: {s}\n", .{slot.hintText()}) catch {};
        }
    }
};

fn writeSlot(json: *std.json.Stringify, slot: *const ErrorSlot) !void {
    const class = classifyError(slot.messageText());
    try json.beginObject();
    try json.objectField("code");
    try json.write(class.code);
    try json.objectField("message");
    try json.write(slot.messageText());
    try json.objectField("hint");
    if (slot.has_hint) {
        try json.write(slot.hintText());
    } else {
        try json.write(class.hint);
    }
    try json.endObject();
}

fn jsonStderrDrain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const self: *JsonStderr = @alignCast(@fieldParentPtr("writer", w));
    const head = w.buffered();
    if (head.len != 0) {
        self.feed(head);
        w.end = 0;
    }
    if (data.len == 0) return 0;
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        self.feed(slice);
        consumed += slice.len;
    }
    const tail = data[data.len - 1];
    for (0..splat) |_| self.feed(tail);
    return consumed + splat * tail.len;
}

pub fn copyUtf8(dest: []u8, source: []const u8) usize {
    if (std.unicode.utf8ValidateSlice(source)) {
        var length = @min(dest.len, source.len);
        while (length > 0 and !std.unicode.utf8ValidateSlice(source[0..length])) length -= 1;
        @memcpy(dest[0..length], source[0..length]);
        return length;
    }
    const hex = "0123456789abcdef";
    var input: usize = 0;
    var output: usize = 0;
    while (input < source.len and output < dest.len) {
        const width = std.unicode.utf8ByteSequenceLength(source[input]) catch 0;
        if (width != 0 and input + width <= source.len and std.unicode.utf8ValidateSlice(source[input..][0..width])) {
            if (output + width > dest.len) break;
            @memcpy(dest[output..][0..width], source[input..][0..width]);
            output += width;
            input += width;
            continue;
        }
        if (output + 4 > dest.len) break;
        dest[output] = '\\';
        dest[output + 1] = 'x';
        dest[output + 2] = hex[source[input] >> 4];
        dest[output + 3] = hex[source[input] & 0xf];
        output += 4;
        input += 1;
    }
    return output;
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

test "error text maps to a stable code and a next step" {
    const cases = [_]struct { message: []const u8, code: []const u8 }{
        .{ .message = "interrupted by SIGINT", .code = "interrupted" },
        .{ .message = "interrupted by SIGTERM", .code = "terminated" },
        .{ .message = "interrupted by SIGHUP", .code = "hangup" },
        .{ .message = "cannot read the batch manifest 'batch.json': no such file", .code = "batch_manifest_unreadable" },
        .{ .message = "the batch manifest 'batch.json' is not valid: it must be a JSON object", .code = "batch_manifest_invalid" },
        .{ .message = "cannot read the batch SQL file '/tmp/a.sql' for the batch query 'q/a.sql': no such file", .code = "batch_sql_unreadable" },
        .{ .message = "--batch takes only the database path; put the SELECT and CREATE INDEX files in the manifest (see --help)", .code = "usage_batch_conflict" },
        .{ .message = "the batch baseline SELECT for query 'q/a.sql' exceeded the time limit of 1 ms", .code = "batch_baseline_timeout" },
        .{ .message = "the batch baseline SELECT for query 'q/a.sql' failed: disk I/O", .code = "batch_baseline_failed" },
        .{ .message = "the batch query 'q/a.sql': --select: the statement is not allowed here: not authorized", .code = "batch_baseline_failed" },
        .{ .message = "the batch variant for query 'q/a.sql' and candidate 'c/a.sql': the SELECT failed: disk I/O", .code = "batch_variant_failed" },
        .{ .message = "the batch diagnostics for candidate 'c/a.sql' exceeded the time limit of 1 ms", .code = "batch_variant_timeout" },
        .{ .message = "the batch candidate 'c/a.sql': the index could not be created: disk I/O", .code = "batch_index_failed" },
        .{ .message = "the batch candidate 'c/a.sql': --index-sql: the statement is not one CREATE INDEX", .code = "batch_index_failed" },
        .{ .message = "the batch candidate 'c/a.sql': the variant could not be removed: FileBusy", .code = "batch_workspace_failed" },
        .{ .message = "--d1 DB: no wrangler config in the current directory", .code = "d1_config_not_found" },
        .{ .message = "--d1 DB: more than one wrangler config in the current directory", .code = "d1_config_ambiguous" },
        .{ .message = "--d1 DB: cannot read the wrangler config 'wrangler.toml': no such file", .code = "d1_config_unreadable" },
        .{ .message = "--d1 DB: --config 'app.txt' must name a .toml, .jsonc or .json file", .code = "d1_config_unsupported" },
        .{ .message = "--d1 DB: cannot use the wrangler config 'wrangler.toml': line 1", .code = "d1_config_invalid" },
        .{ .message = "--d1 DB: no top-level d1_databases binding named 'DB'", .code = "d1_binding_not_found" },
        .{ .message = "--d1 DB: 'wrangler.toml' has more than one d1_databases binding named 'DB'", .code = "d1_binding_ambiguous" },
        .{ .message = "--d1 DB: the binding in 'wrangler.toml' has no database_id and no preview_database_id", .code = "d1_database_id_missing" },
        .{ .message = "--d1 DB: no local D1 database at 'x.sqlite'", .code = "d1_local_file_missing" },
        .{ .message = "--d1 DB: cannot open the local D1 database 'x.sqlite': permission denied", .code = "d1_local_file_unreadable" },
        .{ .message = "missing: the SELECT file", .code = "usage_missing" },
        .{ .message = "unknown option '--nope' (see --help)", .code = "usage_unknown_option" },
        .{ .message = "--db needs a value (see --help)", .code = "usage_missing_value" },
        .{ .message = "an option is missing its value (see --help)", .code = "usage_missing_value" },
        .{ .message = "--db was given more than once (see --help)", .code = "usage_duplicate" },
        .{ .message = "an option was given more than once (see --help)", .code = "usage_duplicate" },
        .{ .message = "unexpected argument 'extra'", .code = "usage_too_many_paths" },
        .{ .message = "too many paths (see --help)", .code = "usage_too_many_paths" },
        .{ .message = "--d1 takes two paths, the SELECT file and the CREATE INDEX file (see --help)", .code = "usage_too_many_paths" },
        .{ .message = "a path cannot be empty (see --help)", .code = "usage_empty_path" },
        .{ .message = "--help does not take a value (see --help)", .code = "usage_unexpected_value" },
        .{ .message = "an option that takes no value was given one (see --help)", .code = "usage_unexpected_value" },
        .{ .message = "--format expects human, kv or json", .code = "usage_format" },
        .{ .message = "--runs expects an integer from 0 to 1000", .code = "usage_runs" },
        .{ .message = "--timeout-ms expects a non-negative integer", .code = "usage_timeout" },
        .{ .message = "--bind expects <N>:<TYPE>[:<VALUE>]", .code = "usage_bind" },
        .{ .message = "use either --db <PATH> or --d1 <BINDING>, not both (see --help)", .code = "usage_conflicting_database" },
        .{ .message = "--config is only used with --d1 (see --help)", .code = "usage_config_requires_d1" },
        .{ .message = "out of memory", .code = "out_of_memory" },
        .{ .message = "cannot read --select file 'SELECT 1': no such file", .code = "select_unreadable" },
        .{ .message = "cannot read --index-sql file 'CREATE INDEX': no such file", .code = "index_unreadable" },
        .{ .message = "cannot create a temporary directory under '/tmp': permission denied", .code = "workspace_failed" },
        .{ .message = "--index-sql exceeded the time limit of 1 ms", .code = "index_timeout" },
        .{ .message = "--select exceeded the time limit of 1 ms on the baseline", .code = "select_timeout" },
        .{ .message = "--index-sql: the index could not be created on the variant: no such table", .code = "index_rejected" },
        .{ .message = "--select: the statement is not allowed here: not authorized", .code = "statement_rejected" },
        .{ .message = "--select: the SELECT names the candidate index 'idx' in INDEXED BY", .code = "indexed_by_rejected" },
        .{ .message = "--select: the query plan could not be read on the baseline: bad", .code = "plan_unreadable" },
        .{ .message = "--select failed while running on the baseline: disk I/O", .code = "select_failed" },
        .{ .message = "cannot open the baseline 'a.db' read-only: missing", .code = "database_unreadable" },
        .{ .message = "cannot open 'a.db' read-only: missing", .code = "database_unreadable" },
        .{ .message = "--bind: missing parameter 1", .code = "bind_rejected" },
        .{ .message = "--bind: bind number 1 is given more than once; give each parameter once, e.g. --bind 1:int:1234 (parameters in the SELECT: 2; --bind given: 2)", .code = "bind_rejected" },
        .{ .message = "--bind on the variant: bind number 2 is given more than once; give each parameter once, e.g. --bind 2:int:1234 (parameters in the SELECT: 2; --bind given: 3)", .code = "bind_rejected" },
        .{ .message = "--bind: a bind number is given more than once", .code = "bind_rejected" },
        .{ .message = "the database connection could not be closed: busy", .code = "connection_close_failed" },
        .{ .message = "cannot copy 'a.db': the database is locked by another connection: busy", .code = "snapshot_locked" },
        .{ .message = "cannot copy 'a.db' into the temporary directory: io", .code = "snapshot_failed" },
        .{ .message = "cannot read the size of the baseline 'a.db': FileNotFound", .code = "size_unreadable" },
        .{ .message = "the temporary directory '/tmp/q' could not be removed: FileBusy", .code = "cleanup_failed" },
        .{ .message = "the summary could not be written", .code = "report_failed" },
        .{ .message = "something new from the core", .code = "unclassified" },
    };
    for (cases) |case| {
        const found = classifyError(case.message);
        try testing.expectEqualStrings(case.code, found.code);
        try testing.expect(found.hint.len != 0);
    }
}

test "json stderr is one object with a code and a hint" {
    var buffer: [4096]u8 = undefined;
    var inner = Io.Writer.fixed(&buffer);
    var bridge: JsonStderr = .init(&inner);
    bridge.writer.writeAll("error: --d1 DB: no wrangler config in the current directory (expected wrangler.toml)\n") catch {};
    bridge.finish(.incomparable);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, inner.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqual(@as(i64, 2), root.object.get("schema_version").?.integer);
    try testing.expectEqual(@as(i64, 4), root.object.get("exit_code").?.integer);
    const failure = root.object.get("error").?;
    try testing.expectEqualStrings("d1_config_not_found", failure.object.get("code").?.string);
    try testing.expect(std.mem.indexOf(u8, failure.object.get("message").?.string, "no wrangler config") != null);
    try testing.expect(failure.object.get("hint").?.string.len != 0);
    try testing.expect(root.object.get("also") == null);
}

test "json stderr keeps progress, drops the usage banner, and keeps a hint line" {
    var buffer: [4096]u8 = undefined;
    var inner = Io.Writer.fixed(&buffer);
    var bridge: JsonStderr = .init(&inner);
    bridge.writer.writeAll("usage: qenome <DB> <SELECT_FILE> <INDEX_FILE> [options]\n") catch {};
    bridge.writer.writeAll("progress: timed round 1 of 10 done\n") catch {};
    bridge.writer.writeAll("error: --select: the statement is not allowed here: not authorized\n") catch {};
    bridge.writer.writeAll("hint: the SELECT and CREATE INDEX files may be swapped\n") catch {};
    bridge.writer.writeAll("error: the temporary directory '/tmp/qenome' could not be removed: FileBusy\n") catch {};
    bridge.finish(.rejected);

    const text = inner.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "progress: timed round 1 of 10 done\n{"));
    try testing.expect(std.mem.indexOf(u8, text, "usage:") == null);
    const json_at = std.mem.indexOfScalar(u8, text, '{') orelse return error.MissingJson;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text[json_at..], .{});
    defer parsed.deinit();
    const failure = parsed.value.object.get("error").?;
    try testing.expectEqualStrings("statement_rejected", failure.object.get("code").?.string);
    try testing.expect(std.mem.indexOf(u8, failure.object.get("hint").?.string, "swapped") != null);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    const also = parsed.value.object.get("also").?.array;
    try testing.expectEqual(@as(usize, 1), also.items.len);
    try testing.expectEqualStrings("cleanup_failed", also.items[0].object.get("code").?.string);
}
