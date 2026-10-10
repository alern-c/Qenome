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

test "vendored sqlite version matches the pinned version" {
    try std.testing.expectEqualStrings(pinned_version, std.mem.span(sqlite3_libversion()));
    try std.testing.expectEqual(pinned_version_number, sqlite3_libversion_number());
    try std.testing.expectEqualStrings(pinned_source_id, std.mem.span(sqlite3_sourceid()));
}
