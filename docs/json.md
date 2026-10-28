# JSON contract (schema_version 2)

`--format json` is the machine-readable interface. This file is the contract for `schema_version` 2. The JSON Schema files next to it check the same shape: [qenome-report.schema.json](qenome-report.schema.json) for a finished comparison, [qenome-error.schema.json](qenome-error.schema.json) for a failure, and [qenome-batch.schema.json](qenome-batch.schema.json) for a `--batch` report (`batch_schema_version` 1).

`schema_version` is already `2` in this tree. `1` was the time verdict. Do not treat a missing pending field as a version bump. The pending names below are part of version 2 and are reserved until the core change emits them.

Row counts use the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

## Two payloads

| Where | When | What |
| --- | --- | --- |
| stdout | A comparison finished (process exit `0`, `3`, or `4` for an incomparable result, and also when cleanup then makes the process exit `5`) | One comparison object and a trailing newline |
| stderr | `--format json` and the run failed before a comparison object exists | One error object and a trailing newline. stdout is empty |
| stderr | `--format json`, a comparison object was written, and cleanup failed | The error object for the cleanup failure. stdout still holds the comparison. The process exit code is `5` only when the comparison exit would have been `0`; every other comparison exit code is kept |
| stderr | `--format human` or `--format kv` | Text lines that start with `error:`. A second line may start with `hint:` |

`progress:` lines may appear on stderr before the error object when a timing round takes longer than a second. They are not JSON. With `--runs 0` there are no progress lines.

On failure, read the line that starts with `{`. `human` and `kv` do not print the error object.

## Batch report (batch_schema_version 1)

`--batch manifest.json` compares every SELECT in the manifest with every candidate CREATE INDEX. With `--suggest`, the manifest may omit `candidates`, and SQLite's proposed indexes join the comparison. Its stdout object is a separate contract with `batch_schema_version` 1. The comparison objects under `results` keep `schema_version` 2 and the shape above. `--suggest` adds keys to this contract without changing the version.

| Key | Type | Meaning |
| `batch_schema_version` | number | `1` |
| `exit_code` | number | `0`, `1`, `3`, `4`, or `124`. The process can still exit `5` after this object when cleanup fails and the code is `0` |
| `recommended` | string or `null` | The candidate label: a path from the manifest, or `suggested:N` with `--suggest`. `null` when no candidate qualifies |
| `summary` | array | One object per candidate, ordered as described below. 1 to 100 entries |
| `results` | array | One object per compared query and candidate, ordered by candidate (manifest entries first, then suggestions) and then by query (manifest order). An `index_rejected` or `index_timeout` candidate has no entries here |
| `warnings` | array | `{ "code", "message" }` entries. Empty without `--suggest`. See [`--suggest`](#--suggest) for the codes |

### `summary` entries

| Key | Type | Meaning |
| `candidate` | string | The `index_sql` string from the manifest, or `suggested:1`, `suggested:2`, … for a proposed index |
| `source` | string | `manifest` or `suggested` |
| `index_sql_text` | string | The SQL text: for a manifest candidate, the contents of its file; for a suggestion, the statement SQLite reported (ending with `;`) |
| `status` | string | `compared`, `index_rejected`, or `index_timeout` |
| `failure` | object or `null` | `null` for `compared`; otherwise `{ "code", "message" }`. `code` is `index_rejected` or `index_timeout` |
| `improved`, `no_effect`, `needs_check`, `mismatch`, `incomparable` | number or `null` | How many queries ended in each outcome. `improved + no_effect + needs_check + mismatch + incomparable + timeout` equals the query count. `null` when the candidate was not compared |
| `timeout` | number or `null` | Queries whose variant SELECT reached `--timeout-ms` |
| `size_increase` | number or `null` | Variant file size minus baseline file size, in bytes (signed). `null` when the index was not built |

A candidate qualifies for `recommended` when its status is `compared` and `mismatch`, `incomparable`, `needs_check`, and `timeout` are all `0` and `improved` is at least `1`. Qualifying candidates come first in `summary`, in this order: more `improved`, then smaller `size_increase`, then input order. Input order is the manifest order, and suggestions follow the manifest entries. The remaining `compared` candidates follow in input order, and the `index_rejected` / `index_timeout` candidates come last in input order.

### `results` entries

| Key | Type | Meaning |
| `query` | string | The `select` string from the manifest, or the SELECT path argument for a one-SELECT `--suggest` |
| `candidate` | string | The `index_sql` string from the manifest, or `suggested:N` |
| `status` | string | `compared` or `variant_timeout` |
| `comparison` | object or `null` | `null` for `variant_timeout`; otherwise the schema_version 2 comparison object, with `inputs.select` and `inputs.index_sql` set to the same strings. For a one-SELECT `--suggest`, `inputs.select` is the SELECT path argument. The embedded object is minified |

### `--suggest`

`--suggest` asks SQLite's expert (sqlite3expert, built from the vendored SQLite source) for candidate indexes. It opens a second read-only connection to the baseline copy, sets the expert sampling to `0` so the user database is read for its schema only, and passes every checked SELECT to the expert. It then compares the proposed `CREATE INDEX` statements with the existing batch mechanism.

- A suggestion passes the same one-`CREATE INDEX` check as a manifest candidate. A suggestion that fails the check is dropped, and the batch continues.
- Before the expert runs, every `sqlite_schema` row is checked: it must be one statement and start with `CREATE TABLE`, `CREATE INDEX`, `CREATE UNIQUE INDEX`, `CREATE VIEW`, `CREATE TRIGGER`, or `CREATE VIRTUAL TABLE`. A row may not use the `expert` virtual table. A database that fails this check stops the run with exit `1`, empty stdout, and `suggest_schema_rejected`, even when the manifest has candidates.
- While the expert runs, a temporary guard is installed on the connections it opens: `ATTACH` and `DETACH` are denied, only the `index_list` and `index_xinfo` PRAGMAs are allowed, and `SQLITE_LIMIT_ATTACHED` is `0`. After the expert object is created, the expert installs its own authorizer on its analysis copy (`dbv`); the attached-database limit stays in force there. The guard is removed after the expert is destroyed. If the guard cannot be installed, the run stops with `suggest_failed` and the expert is not called.
- At most 20 suggestions are used, and at most 100 candidates in total with the manifest entries. Extra suggestions are dropped in report order, which is not a ranking. Candidates are labelled `suggested:1`, `suggested:2`, … in the order that remains.
- Manifest candidates whose `index_sql` string starts with `suggested:` are rejected as an invalid manifest when `--suggest` is given, so the labels cannot collide.
- A suggestion weighs the same as a manifest candidate: its index failure, timeout, or result mismatch enters `exit_code`.
- `warnings` keeps what the run dropped or could not do:

| `code` | Meaning |
| `suggest_query_skipped` | SQLite could not analyze one SELECT; the other SELECTs continue |
| `suggestion_rejected` | A proposed statement failed the `CREATE INDEX` check and was dropped |
| `suggestions_truncated` | The 20 or 100 limit dropped the tail of the suggestions |
| `no_suggestions` | SQLite proposed nothing; the manifest candidates were still compared |
| `suggest_failed` | The expert could not start or analyze; the manifest candidates were still compared |

- When nothing can be compared (no manifest candidate and no surviving suggestion), the run stops with exit `1`, empty stdout, and error code `no_candidates`.
- With one SELECT file (no `--batch`), the SELECT is one batch query, `--bind` applies to it, and the report is the same batch object. `--suggest` does not take `--runs`, `--format kv`, or an index file.
- Use `--suggest` to find candidates. For a CI gate that must not change when SQLite changes its advice, compare a named index without `--suggest`.

### Exit code and stderr

When the report is written, the exit code is the heaviest of: result mismatch `3`, a candidate index that could not be built `1`, a candidate time limit `124`, an incomparable result `4`, and `0`. Cleanup failure replaces `0` with `5`.

A batch can therefore write a report and still exit `1` or `124`. Read stdout to decide: if stdout is a batch object, the run finished and the failures are in `summary` and `results`. If stdout is empty, the run stopped before the report and stderr holds the schema_version 2 error object. Candidate failures (`index_rejected`, `index_timeout`, `variant_timeout`) are never written as `error:` lines.

Batch error codes:

| `code` | Exit | Next step the hint points at |
| `usage_batch_conflict` | 2 | Put the SELECT, CREATE INDEX, and binds in the manifest; use `--format human` or `json`; do not pass `--runs` |
| `batch_manifest_unreadable` | 1 | Check the manifest path and permissions |
| `batch_manifest_invalid` | 1 | Fix the shape, limits, repeated paths, or binds |
| `batch_sql_unreadable` | 1 | Check the SQL paths in the manifest; they are relative to the manifest |
| `batch_baseline_failed` | 1 | Fix the SELECT or read the SQLite message |
| `batch_baseline_timeout` | 124 | Raise `--timeout-ms` or narrow the SELECT |
| `batch_variant_failed` | 1 | Read the SQLite message; the run stopped before the report |
| `batch_variant_timeout` | 124 | Raise `--timeout-ms` or simplify the CREATE INDEX |
| `batch_index_failed` | 1 | Fix the candidate CREATE INDEX so it applies to this database |
| `batch_workspace_failed` | 1 | Check the temporary directory and its permissions |
| `no_candidates` | 1 | Check that a SELECT has a WHERE or ORDER BY clause, or write a candidate CREATE INDEX |
| `suggest_failed` | 1 | Check that the SELECTs are valid, or drop `--suggest` and name the index |
| `suggest_schema_rejected` | 1 | Use a database whose `sqlite_schema` holds only plain CREATE statements, or compare a named index without `--suggest` |

## Status in this tree

| Name | Status |
| --- | --- |
| `schema_version`, `exit_code`, `verdict`, `verdict_reasons` | Emitted |
| `baseline.counters.rows_read`, `baseline.counters.rows_written`, and the same fields on `variant` | Emitted. This is the per-side row counts |
| `timing` with `rounds`, `ratio`, and per-side `median_ns` / `p25_ns` / `p75_ns` / `min_ns` / `max_ns` | Emitted. The whole `timing` value is JSON `null` when the run is not timed (`--runs 0`, or the rows were not a match) |
| `timing.noise_band` | Emitted; method, pairs, threshold_ns |
| `timing.confidence_interval` | Emitted as object or null; method, level, coverage, lower_ns, upper_ns |
| `warnings` | Emitted. Each element is `{ "code", "message" }` |
| `sqlite.bundled_version`, `sqlite.db_header_version` | Not emitted. Reserved. Until `sqlite` exists, the bundled version is `environment.sqlite_version`. With `--d1`, `d1.sqlite_version` is the local D1 engine version string (`3.53.4`) |

A reader must not require a reserved field. If a reserved field appears, its outer name matches this file. The timing evidence keys below are now defined. Only the SQLite detail fields remain reserved.

## Comparison object

The object is indented with two spaces and ends with a newline. A missing key that this section calls emitted is a contract break. Extra keys are allowed so a core change can add the reserved fields without a parser rejecting the object.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | number | `2` |
| `exit_code` | number | `0`, `3`, or `4` for the comparison. This stays `0` when the process later exits `5` |
| `verdict` | string | `improved`, `no-effect`, `needs-check`, or `not-judged` |
| `verdict_reasons` | array of strings | Why the verdict is `needs-check` or `not-judged`. Empty for `improved` and `no-effect` |
| `result` | string | `match`, `mismatch`, or `incomparable` |
| `row_order` | string | `same`, `differs`, or `not-applicable`. Reference only. `same` or `differs` only when `result` is `match` |
| `result_reasons` | array of `{text, hint}` | Why the rows cannot be compared. `hint` is a string or `null` |
| `row_differences` | object | `baseline_only` and `variant_only` counts. `baseline_only_examples` and `variant_only_examples` are arrays, empty unless `--show-rows` |
| `plan_changed` | boolean | The query plan text differs |
| `baseline`, `variant` | object | `rows` (result row count), `plan` (array of plan steps), `counters` |
| `baseline.counters` / `variant.counters` | object | `rows_read`, `rows_written`, `fullscan_steps`, `vm_steps`, `sort_ops`, `autoindex_rows`. All numbers. `rows_read` and `rows_written` are 32-bit and wrap past 4294967295 |
| `timing` | object or `null` | See the status table. `ratio` is variant median / baseline median, or `null` when the baseline median is `0` |
| `size_bytes` | object | `baseline`, `variant`, and `increase` (variant minus baseline). The whole database file, not the index alone |
| `inputs` | object | `database`, `select`, `index_sql` paths |
| `environment` | object | `qenome_version`, `sqlite_version`, `sqlite_source_id`, `zig_version`, `build_mode`, `os`, `arch`, `work_dir_parent` |
| `d1` | object | Present only with `--d1`: `binding`, `config`, `database_id`, `local_database`, `sqlite_version`, `sqlite_version_note`, `caution` |
| `measurement` | object | `runs_per_copy`, `warmup`, `order`, `scope`, `cache` |
| `binds` | array | `number`, `type`. Text also has `text_bytes`. `value` only with `--show-binds` |
| `warnings` | array | Emitted. `{ "code": string, "message": string }`. Expected codes: `no_analyze_stats` (no ANALYZE statistics), `data_too_small` (too little data to trust the counts) |
| `sqlite` | object | Reserved. `bundled_version` (string), `db_header_version` (string) |

`verdict` values:

| `verdict` | Meaning |
| --- | --- |
| `improved` | The rows match, and the variant reads fewer rows |
| `no-effect` | The rows match, and the variant reads the same number of rows |
| `needs-check` | The rows match, but the variant reads or writes more rows |
| `not-judged` | The rows differ or cannot be compared |

The verdict comes from `rows_read` and `rows_written`. It does not change the exit code. Times do not change the verdict, so `--runs 0` still has a verdict.

String values in the comparison object write a backslash as `\\` and each byte that is not valid UTF-8 as `\xNN`, and the result is then escaped as JSON. Paths, plan details, reasons, and bind text use this rule. The README describes how to reverse it.

## Error object

Emitted on stderr only with `--format json`. One line of minified JSON and a trailing newline.

```json
{
  "schema_version": 2,
  "exit_code": 4,
  "error": {
    "code": "d1_config_not_found",
    "message": "--d1 DB: no wrangler config in the current directory",
    "hint": "Pass --config <PATH>, or run qenome in the wrangler project directory."
  }
}
```

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | number | `2`, the same contract version as the comparison object |
| `exit_code` | number | The process exit code |
| `error.code` | string | Stable code from the table below |
| `error.message` | string | The same detail the text format prints after `error: ` |
| `error.hint` | string | The next step. A `hint:` line from the text format replaces the default hint when one was printed |
| `also` | array | Omitted when there is only one error. Later errors, most often cleanup, use the same `{code, message, hint}` object. The process `exit_code` is still the code in the table of exit statuses, not a second status |

`message` is a JSON string. A byte that is not valid UTF-8 is rewritten as the four ASCII characters `\xNN` before JSON encoding, so `message` does not become an array of bytes. If the object cannot be encoded, stderr falls back to the text `error:` line.

The usage banner (`usage: ...`) is not included in the error object. `progress:` lines stay text and are written as they happen.

## Exit codes

These are the values of `ExitCode` in `src/cli/control.zig`, `--help`, and the README. The numbers match.

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `ok` | The result rows match |
| 1 | `rejected` | An input was rejected (unreadable file, rejected SQL, bind mismatch, index creation failure, out of memory, report write failure) |
| 2 | `usage` | The command line is wrong. Out of memory while parsing is `1`, not `2` |
| 3 | `mismatch` | The result rows differ |
| 4 | `incomparable` | The results cannot be compared, or `--d1` cannot resolve exactly one local database |
| 5 | `cleanup` | Cleanup failed after a match. This replaces `0` only. Every other code is kept |
| 124 | `timeout` | `--timeout-ms` was reached |
| 129 | `hangup` | `SIGHUP` |
| 130 | `interrupted` | `SIGINT` |
| 143 | `terminated` | `SIGTERM` |

Exit `4` covers every `--d1` resolution failure: no config, more than one config, a config that cannot be read, a config whose suffix is not `.toml` / `.jsonc` / `.json`, a config that does not parse, a binding that is missing or duplicated, a binding with neither `database_id` nor `preview_database_id`, a local `.sqlite` file that does not exist yet, and a local file that cannot be opened. An unexpected allocator failure while resolving `--d1` is exit `1`.

The comparison object's `exit_code` is `0`, `3`, or `4`. The process can still exit `5` after that object is written. Trust the process exit code. Read stderr when it is `5`. A batch object can be written with process exit `1` or `124`; stdout is empty when the run stopped before the report. See [Batch report](#batch-report-batch_schema_version-1).

## Error codes

`error.code` is stable. `unclassified` means the message is new and has not been given its own code yet. The hint is still present. Add a specific code in `classifyError` when a new message lands.

| `code` | Exit | Next step the hint points at |
| --- | --- | --- |
| `usage_missing` | 2 | Pass the database or `--d1`, the SELECT file, and the CREATE INDEX file |
| `usage_unknown_option` | 2 | Read `--help` |
| `usage_missing_value` | 2 | Repeat the option with a value |
| `usage_duplicate` | 2 | Pass the option once |
| `usage_too_many_paths` | 2 | At most three paths, or two with `--d1` |
| `usage_empty_path` | 2 | Pass a non-empty path |
| `usage_unexpected_value` | 2 | Drop the value from that flag |
| `usage_format` | 2 | Use `human`, `kv`, or `json` |
| `usage_runs` | 2 | Use an integer from 0 to 1000 |
| `usage_timeout` | 2 | Use a non-negative millisecond count |
| `usage_bind` | 2 | Use `--bind N:TYPE:VALUE` |
| `usage_conflicting_database` | 2 | Pass `--db` or `--d1`, not both |
| `usage_config_requires_d1` | 2 | Add `--d1`, or drop `--config` |
| `usage_suggest_conflict` | 2 | With `--suggest`, give one SELECT file or a manifest; do not pass `--runs`, `--format kv`, or an index file |
| `d1_config_not_found` | 4 | Pass `--config`, or run in the wrangler project |
| `d1_config_ambiguous` | 4 | Pass `--config` naming one file |
| `d1_config_unreadable` | 4 | Fix the path and permissions |
| `d1_config_unsupported` | 4 | Use `.toml`, `.jsonc`, or `.json` |
| `d1_config_invalid` | 4 | Fix the config syntax |
| `d1_binding_not_found` | 4 | Use a top-level `d1_databases` binding name |
| `d1_binding_ambiguous` | 4 | Keep one entry with that name |
| `d1_database_id_missing` | 4 | Set `database_id` or `preview_database_id` |
| `d1_local_file_missing` | 4 | Create the local database with wrangler, then rerun |
| `d1_local_file_unreadable` | 4 | Make the `.sqlite` file readable |
| `select_unreadable` | 1 | `--select` is a path to a file, not SQL text |
| `index_unreadable` | 1 | `--index-sql` is a path to a file, not SQL text |
| `statement_rejected` | 1 | One read-only SELECT and one CREATE INDEX. The files may be swapped |
| `indexed_by_rejected` | 1 | Do not `INDEXED BY` the candidate index |
| `bind_rejected` | 1 | One `--bind` per parameter |
| `index_rejected` | 1 | Make the CREATE INDEX apply to this database |
| `select_failed` | 1 | Fix the SELECT using the SQLite message |
| `plan_unreadable` | 1 | Check the SELECT against this database |
| `database_unreadable` | 1 | The file exists, is SQLite, and is not locked |
| `snapshot_locked` | 1 | Close other connections and rerun |
| `snapshot_failed` | 1 | Check space and permissions, then rerun |
| `workspace_failed` | 1 | The temporary directory must be writable |
| `size_unreadable` | 1 | Rerun |
| `index_timeout` | 124 | Raise `--timeout-ms` or simplify the index |
| `select_timeout` | 124 | Raise `--timeout-ms` or narrow the SELECT |
| `out_of_memory` | 1 | Free memory and rerun |
| `report_failed` | 1 | Rerun. The comparison finished but the report was not written |
| `connection_close_failed` | 1, or unchanged if it happens during cleanup | Rerun |
| `cleanup_failed` | 5 when it replaces `0`, otherwise the earlier code | Remove the named temporary directory |
| `interrupted` | 130 | Rerun |
| `hangup` | 129 | Rerun |
| `terminated` | 143 | Rerun |
| `unclassified` | the process exit code | Read the message. A new message needs a code in `classifyError` |

### Timing evidence and advisory warnings

Each timed round first runs the baseline SELECT twice (A/A), then runs one baseline/variant pair, alternating AB and BA. Both sessions are already warm from the compared run. A/A adds two baseline executions per round. The measured counters in the report still come only from the first compared SELECT; diagnostics and timed executions do not enter them. Warning checks run after timing, on sandbox copies only. No ANALYZE or PRAGMA optimize is run.

`timing.noise_band` reports the empirical 95th percentile of absolute differences between the two baseline A/A durations, using nearest rank `ceil(0.95*n)` and reporting `pairs`. This is a heuristic noise reference, not a confidence bound or a significance threshold with a calibrated false-positive rate. No observed A/A spread does not prove zero underlying variation.

`timing.median_difference_ns` is the median of the per-round differences `variant_i - baseline_i` (negative is faster), not the difference of the two medians and not a ratio. Existing `ratio` remains variant median / baseline median. `confidence_interval` uses sorted paired differences and a symmetric binomial sign interval for their population median. For zero-based endpoints `k` and `n-k-1`, choose the largest k with `P(Binomial(n,0.5) <= k) <= 0.025`; coverage is `1 - 2*P(...)`. `level` is the requested 0.95; `coverage` is the conservative binomial coverage under independent identically distributed continuous differences. This follows the [order-statistic approach described by NIST](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/mediancl.htm), without interpolation. It describes uncertainty in the median difference, not a future single duration. There is no resampling.

The interval is `null` with `unavailable_reason` `too-few-rounds` below six rounds (the widest finite interval has coverage 93.75% at n=5 and 96.875% at n=6), `zero-duration` when any timed duration is zero, or conservatively `no-observed-variation` when all paired differences are equal. These cases give `effect: insufficient-samples`, not a claim of precision at the clock resolution. Otherwise `effect` is `no-difference` if the absolute value of the median paired difference is at most the A/A noise reference or the interval includes zero; it is `faster` or `slower` only when both checks allow that direction. This auxiliary label never changes `verdict` or the exit code. Fixed A/A-before-A/B ordering, cache effects, temporal dependence, load drift, and small samples limit interpretation: nominal 95% coverage is not an exact guarantee for these machine timings or for production D1.

`warnings` is always an array, including with `--runs 0` or incomparable results. Its `{code, message}` entries also appear verbatim in human and kv output. `no_analyze_stats` means the candidate index's table has no non-empty `sqlite_stat1` entry in the baseline snapshot, even if other tables have statistics. This is an absence check, not a freshness/completeness check: a partial-index entry alone counts as present. `data_too_small` means a bounded `SELECT 1 ... LIMIT 1000` on that table returned fewer than 1000 rows. Reaching 1000 only establishes at least 1000 rows; statistics estimates, partial-index cardinality, SELECT result count, and rows read do not decide this warning. The threshold is a heuristic, not proof that larger data is representative. Warnings advise a representative, separately prepared copy; they do not suppress a row verdict or change exit codes. Diagnostic reads respect the existing per-statement timeout/cancellation; failures follow the existing error path.

## Remaining reserved fields

Only `sqlite.bundled_version` and `sqlite.db_header_version` remain reserved and unimplemented. Read `environment.sqlite_version` for the bundled version. The timing and warning additions above keep schema_version 2. New error messages still require a stable code in src/cli/control.zig.
