const std = @import("std");

pub const pinned_version = "3.51.2";

pub const pinned_version_number: c_int = 3_051_002;

pub const pinned_source_id = "2026-01-09 17:27:48 b270f8339eb13b504d0b2ba154ebca966b7dde08e40c3ed7d559749818cb2075";

pub extern fn sqlite3_libversion() [*:0]const u8;
pub extern fn sqlite3_libversion_number() c_int;
pub extern fn sqlite3_sourceid() [*:0]const u8;

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
pub const sqlite3_backup = opaque {};

pub const AuthorizerCallback = fn (
    ?*anyopaque,
    c_int,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
) callconv(.c) c_int;

pub const ExecCallback = fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;

pub const ProgressCallback = fn (?*anyopaque) callconv(.c) c_int;

pub const SQLITE_OK = 0;
pub const SQLITE_BUSY = 5;
pub const SQLITE_READONLY = 8;
pub const SQLITE_INTERRUPT = 9;
pub const SQLITE_AUTH = 23;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

pub const SQLITE_OPEN_READONLY = 0x0000_0001;
pub const SQLITE_OPEN_READWRITE = 0x0000_0002;
pub const SQLITE_OPEN_CREATE = 0x0000_0004;
pub const SQLITE_OPEN_NOFOLLOW = 0x0100_0000;

pub const SQLITE_DENY = 1;

pub const SQLITE_DBCONFIG_DQS_DML = 1013;
pub const SQLITE_DBCONFIG_DQS_DDL = 1014;
pub const SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006;

pub const SQLITE_LIMIT_VARIABLE_NUMBER = 9;

pub const max_parameter_number: u32 = 32766;

pub const SQLITE_CREATE_INDEX = 1;
pub const SQLITE_INSERT = 18;
pub const SQLITE_PRAGMA = 19;
pub const SQLITE_READ = 20;
pub const SQLITE_SELECT = 21;
pub const SQLITE_REINDEX = 27;
pub const SQLITE_FUNCTION = 31;
pub const SQLITE_RECURSIVE = 33;

pub extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
pub extern fn sqlite3_errcode(db: ?*sqlite3) c_int;
pub extern fn sqlite3_db_readonly(db: ?*sqlite3, zDbName: [*:0]const u8) c_int;
pub extern fn sqlite3_db_config(db: ?*sqlite3, op: c_int, ...) c_int;
pub extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ?*const ExecCallback, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
pub extern fn sqlite3_set_authorizer(db: ?*sqlite3, xAuth: ?*const AuthorizerCallback, pUserData: ?*anyopaque) c_int;
pub extern fn sqlite3_progress_handler(db: ?*sqlite3, n_opcodes: c_int, callback: ?*const ProgressCallback, arg: ?*anyopaque) void;
pub extern fn sqlite3_stmt_readonly(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_stmt_isexplain(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, column: c_int) i64;
pub extern fn sqlite3_column_double(stmt: ?*sqlite3_stmt, column: c_int) f64;
pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, column: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, column: c_int) ?*const anyopaque;

pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

pub extern fn sqlite3_stmt_explain(stmt: ?*sqlite3_stmt, eMode: c_int) c_int;

pub extern fn sqlite3_stmt_status(stmt: ?*sqlite3_stmt, op: c_int, resetFlg: c_int) c_int;

pub extern fn sqlite3_backup_init(pDest: ?*sqlite3, zDestName: [*:0]const u8, pSource: ?*sqlite3, zSourceName: [*:0]const u8) ?*sqlite3_backup;
pub extern fn sqlite3_backup_step(p: ?*sqlite3_backup, nPage: c_int) c_int;
pub extern fn sqlite3_backup_finish(p: ?*sqlite3_backup) c_int;

pub const SQLITE_STMTSTATUS_FULLSCAN_STEP = 1;
pub const SQLITE_STMTSTATUS_SORT = 2;
pub const SQLITE_STMTSTATUS_AUTOINDEX = 3;
pub const SQLITE_STMTSTATUS_VM_STEP = 4;

pub const Destructor = fn (?*anyopaque) callconv(.c) void;
pub const DestructorPtr = ?*align(1) const Destructor;
pub const SQLITE_TRANSIENT: DestructorPtr = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern fn sqlite3_bind_parameter_count(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, index: c_int, value: f64) c_int;
pub extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, index: c_int, text: [*]const u8, bytes: c_int, destructor: DestructorPtr) c_int;
pub extern fn sqlite3_limit(db: ?*sqlite3, id: c_int, new_value: c_int) c_int;

test "vendored sqlite version matches the pinned version" {
    try std.testing.expectEqualStrings(pinned_version, std.mem.span(sqlite3_libversion()));
    try std.testing.expectEqual(pinned_version_number, sqlite3_libversion_number());
    try std.testing.expectEqualStrings(pinned_source_id, std.mem.span(sqlite3_sourceid()));
}
