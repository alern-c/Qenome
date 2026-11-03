const std = @import("std");

pub const schema_version: u8 = 2;

pub const batch_schema_version: u8 = 1;

pub const audit_schema_version: u8 = 1;

pub const record_schema_version: u8 = 1;

pub const scale_schema_version: u8 = 1;

pub const rank_schema_version: u8 = 1;

pub const ExitCode = enum(u8) {
    ok = 0,
    rejected = 1,
    usage = 2,
    mismatch = 3,
    incomparable = 4,
    cleanup = 5,
    regression = 6,
    likely_full_scan = 7,
    timeout = 124,
    hangup = 129,
    interrupted = 130,
    terminated = 143,
};

pub const code = struct {
    pub const no_analyze_stats = "no_analyze_stats";
    pub const data_too_small = "data_too_small";
    pub const bind_dependent_partial_index = "bind_dependent_partial_index";
    pub const unapplied_migrations = "unapplied_migrations";
    pub const suggest_query_skipped = "suggest_query_skipped";
    pub const suggestions_truncated = "suggestions_truncated";
    pub const suggestion_rejected = "suggestion_rejected";
    pub const suggest_failed = "suggest_failed";
    pub const no_suggestions = "no_suggestions";
    pub const record_log_permissions = "record_log_permissions";
    pub const record_manifest_binds = "record_manifest_binds";
    pub const usage_scale = "usage_scale";
    pub const improvement_vanishes_at_scale = "improvement_vanishes_at_scale";
    pub const regresses_at_scale = "regresses_at_scale";
    pub const improves_only_at_scale = "improves_only_at_scale";
    pub const only_faster_at_small_sizes = "only_faster_at_small_sizes";
    pub const plan_changes_with_scale = "plan_changes_with_scale";
    pub const gain_grows_with_scale = "gain_grows_with_scale";
    pub const gain_shrinks_with_scale = "gain_shrinks_with_scale";
    pub const batch_write_failed = "batch_write_failed";
    pub const batch_write_timeout = "batch_write_timeout";
    pub const no_index_needed = "no_index_needed";
    pub const sqlite_toobig = "sqlite_toobig";
    pub const function_on_column = "function_on_column";
    pub const leading_wildcard_like = "leading_wildcard_like";
    pub const or_across_columns = "or_across_columns";
    pub const large_offset = "large_offset";
    pub const order_by_random = "order_by_random";
    pub const select_star = "select_star";
    pub const usage_sql_warning = "usage_sql_warning";
};

pub const sql_warning_severity = struct {
    pub const warning = "warning";
    pub const info = "info";
};

pub const sql_warning_codes = [_][]const u8{
    code.function_on_column,
    code.leading_wildcard_like,
    code.or_across_columns,
    code.large_offset,
    code.order_by_random,
    code.select_star,
};

pub const sql_warning_messages = struct {
    pub const function_on_column = "A function or arithmetic on a column in a comparison stops SQLite from using an index on that column. Compare the plain column, or add an expression index for this expression.";
    pub const leading_wildcard_like = "A LIKE or GLOB pattern that starts with a wildcard cannot use an index. Put a fixed prefix first, or compare the column another way.";
    pub const or_across_columns = "The OR compares different columns, so one index cannot serve every branch. Split it into separate queries, or add an index for each column.";
    pub const large_offset = "A large OFFSET reads and discards every skipped row. Page with WHERE id > ? ORDER BY id LIMIT ? instead.";
    pub const order_by_random = "ORDER BY random() reads and sorts the whole result. Order by a column instead, or pick the random rows another way.";
    pub const select_star = "SELECT * reads every column, so a covering index cannot serve the query. List the columns you use.";
};

pub const warning_codes = [_][]const u8{ code.no_analyze_stats, code.data_too_small };

pub const warning_messages = [_][]const u8{
    "The candidate index table has no non-empty sqlite_stat1 entry. Test an ANALYZE'd copy with representative data; this check does not run ANALYZE.",
    "The candidate index table has fewer than 1000 rows. This heuristic does not establish representative performance; test with more representative data.",
};

pub const data_too_small_message = "The table \"{s}\" has {d} rows, fewer than 1000 rows, so this result is not meaningful yet. {s}Write a seed spec that lists {s} and rerun: {s}";

pub const data_too_small_scale_message = "The table \"{s}\" has {d} rows, fewer than 1000 rows, so this step is below the size where the result is meaningful. {s}Read the comparison at a larger step.";

pub const data_too_small_full_scan = "A full scan reads every row, so a small count does not mean a missing index is harmless. ";

pub const data_too_small_suggested = "Save the suggested index as index.sql first; --scale does not run with --suggest. ";

pub const bind_dependent_partial_index_message = "The variant plan uses the partial index \"{s}\" only because the bound values satisfy its WHERE clause. A different bound value changes the plan, so test with the values you deploy.";

pub const unapplied_migrations_message = "wrangler has not applied these migrations to the local D1 database for {s}: {s}. Run `npx wrangler d1 migrations apply {s} --local` and compare again; the schema under test is older than the migrations describe.";

pub const min_read_gain_percent: u32 = 1;

pub const below_min_read_gain_reason = std.fmt.comptimePrint(
    "the rows match, and the variant reads fewer rows, but the reduction is below {d}% of the baseline rows read",
    .{min_read_gain_percent},
);

pub const record_log_permissions_message = "the record log '{s}' is readable by other users; create a new log with umask 077 and delete it after this run";

pub const record_manifest_binds_message = "the manifest holds bind values; keep it local and do not commit it";

test "the warning codes pair with one message each" {
    try std.testing.expectEqual(warning_codes.len, warning_messages.len);
}

test "the exit codes keep the documented values" {
    try std.testing.expectEqual(@as(u8, 0), @backingInt(ExitCode.ok));
    try std.testing.expectEqual(@as(u8, 6), @backingInt(ExitCode.regression));
    try std.testing.expectEqual(@as(u8, 7), @backingInt(ExitCode.likely_full_scan));
    try std.testing.expectEqual(@as(u8, 124), @backingInt(ExitCode.timeout));
    try std.testing.expectEqual(@as(u8, 143), @backingInt(ExitCode.terminated));
}
