# JSON contract (schema_version 2)

`--format json` is the machine-readable interface. This file is the contract for `schema_version` 2. The JSON Schema files next to it check the same shape: [qenome-report.schema.json](qenome-report.schema.json) for a finished comparison, and [qenome-error.schema.json](qenome-error.schema.json) for a failure.

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

## Status in this tree

| Name | Status |
| --- | --- |
| `schema_version`, `exit_code`, `verdict`, `verdict_reasons` | Emitted |
| `baseline.counters.rows_read`, `baseline.counters.rows_written`, and the same fields on `variant` | Emitted. This is the per-side row counts |
| `timing` with `rounds`, `ratio`, and per-side `median_ns` / `p25_ns` / `p75_ns` / `min_ns` / `max_ns` | Emitted. The whole `timing` value is JSON `null` when the run is not timed (`--runs 0`, or the rows were not a match) |
| `timing.noise_band` | Not emitted. Reserved |
| `timing.confidence_interval` | Not emitted. Reserved |
| `warnings` | Not emitted. Reserved. Each element will be `{ "code", "message" }` |
| `sqlite.bundled_version`, `sqlite.db_header_version` | Not emitted. Reserved. Until `sqlite` exists, the bundled version is `environment.sqlite_version`. With `--d1`, `d1.sqlite_version` is the local D1 engine version string (`3.53.4`) |

A reader must not require a reserved field. If a reserved field appears, its outer name matches this file. Inner keys of `noise_band` and `confidence_interval` are not frozen; reconcile them with the core change before a reader depends on a key inside them.

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
| `warnings` | array | Reserved. `{ "code": string, "message": string }`. Expected codes: `no_analyze_stats` (no ANALYZE statistics), `data_too_small` (too little data to trust the counts) |
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

The comparison object's `exit_code` is `0`, `3`, or `4`. The process can still exit `5` after that object is written. Trust the process exit code. Read stderr when it is `5`.

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

## Reconciliation after the core change

This tree already emits `schema_version` 2, top-level `verdict`, and per-side `rows_read` / `rows_written` under `baseline.counters` and `variant.counters`. The following is not implemented. When it lands, update this file, the two schema files, and the `# qenome-ci: pending` lines in [skills/qenome/SKILL.md](../skills/qenome/SKILL.md). Do not bump `schema_version` for these fields.

1. `timing.noise_band`. Outer name is fixed. Inner keys are not. The verdict must keep using row counts, not this object.
2. `timing.confidence_interval`. Same rule.
3. `warnings`: an array of `{ "code", "message" }`. Use `no_analyze_stats` and `data_too_small` for the two planned warnings. Warnings do not change the exit code.
4. `sqlite.bundled_version` and `sqlite.db_header_version`. `bundled_version` should match today's `environment.sqlite_version`. There is no database-header version field yet.
5. If `rows_read` or `rows_written` move out of `counters`, change the skill example marker that requires `baseline.counters.rows_read` and `variant.counters.rows_written`.
6. New stderr sentences need a row in `classifyError` (`src/cli/control.zig`) or they are reported as `unclassified`.
