//! Hand-written declarations for the vendored SQLite C library.
//!
//! The amalgamation under `vendor/sqlite3` is pinned to a single release. See
//! `vendor/sqlite3/PROVENANCE.txt` for the source, the official hashes, and the
//! compile flags used in `build.zig`. Only the declarations that the code needs
//! are kept here; each one is checked against `zig translate-c` output when it
//! is added.

const std = @import("std");

/// `SQLITE_VERSION` of the vendored release.
pub const pinned_version = "3.51.2";

/// `SQLITE_VERSION_NUMBER` of `pinned_version` (3 * 1_000_000 + 51 * 1_000 + 2).
pub const pinned_version_number: c_int = 3_051_002;

/// `SQLITE_SOURCE_ID` of the vendored amalgamation. sqlite.org publishes this
/// value for the release, so it ties the vendored file to that release.
pub const pinned_source_id = "2026-01-09 17:27:48 b270f8339eb13b504d0b2ba154ebca966b7dde08e40c3ed7d559749818cb2075";

// Version helpers (`sqlite3.h`).
pub extern fn sqlite3_libversion() [*:0]const u8;
pub extern fn sqlite3_libversion_number() c_int;
pub extern fn sqlite3_sourceid() [*:0]const u8;

// Opaque handles (`sqlite3.h`).
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

/// Callback type of `sqlite3_set_authorizer`. Every `const char *` argument
/// may be NULL.
pub const AuthorizerCallback = fn (
    ?*anyopaque,
    c_int,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
) callconv(.c) c_int;

/// Callback type of `sqlite3_exec`; only the NULL callback is used here.
pub const ExecCallback = fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;

// Result codes (`sqlite3.h`).
pub const SQLITE_OK = 0;
pub const SQLITE_READONLY = 8;
pub const SQLITE_AUTH = 23;
pub const SQLITE_ROW = 100;

// Flags for `sqlite3_open_v2` (`sqlite3.h`).
pub const SQLITE_OPEN_READONLY = 0x0000_0001;
pub const SQLITE_OPEN_READWRITE = 0x0000_0002;
pub const SQLITE_OPEN_CREATE = 0x0000_0004;

// Authorizer verdicts (`sqlite3.h`).
pub const SQLITE_DENY = 1;

// Configuration verbs for `sqlite3_db_config` (`sqlite3.h`).
pub const SQLITE_DBCONFIG_DQS_DML = 1013;
pub const SQLITE_DBCONFIG_DQS_DDL = 1014;

// Authorizer action codes (`sqlite3.h`). The numeric values are part of the
// public ABI, so they must not be changed.
pub const SQLITE_CREATE_INDEX = 1;
pub const SQLITE_INSERT = 18;
pub const SQLITE_PRAGMA = 19;
pub const SQLITE_READ = 20;
pub const SQLITE_SELECT = 21;
pub const SQLITE_REINDEX = 27;
pub const SQLITE_FUNCTION = 31;
pub const SQLITE_RECURSIVE = 33;

// Connection and statement API (`sqlite3.h`). `sqlite3_prepare_v2` is called
// with `nByte = -1`, so `zSql` and the returned `pzTail` point into the same
// NUL-terminated buffer.
pub extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
pub extern fn sqlite3_db_readonly(db: ?*sqlite3, zDbName: [*:0]const u8) c_int;
/// Variadic; the arguments depend on `op`. The `SQLITE_DBCONFIG_DQS_*` verbs
/// take `(c_int, ?*c_int)`.
pub extern fn sqlite3_db_config(db: ?*sqlite3, op: c_int, ...) c_int;
pub extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ?*const ExecCallback, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
pub extern fn sqlite3_set_authorizer(db: ?*sqlite3, xAuth: ?*const AuthorizerCallback, pUserData: ?*anyopaque) c_int;
pub extern fn sqlite3_stmt_readonly(stmt: ?*sqlite3_stmt) c_int;
/// 0 = a normal statement, 1 = `EXPLAIN`, 2 = `EXPLAIN QUERY PLAN`.
pub extern fn sqlite3_stmt_isexplain(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, column: c_int) i64;

test "vendored sqlite version matches the pinned version" {
    try std.testing.expectEqualStrings(pinned_version, std.mem.span(sqlite3_libversion()));
    try std.testing.expectEqual(pinned_version_number, sqlite3_libversion_number());
    try std.testing.expectEqualStrings(pinned_source_id, std.mem.span(sqlite3_sourceid()));
}
