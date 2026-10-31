# Output formats

## human (default)

`--format human` prints what a decision needs:

- a Summary: whether the result rows match, how many rows each copy read and wrote, the verdict with its reasons, whether the plan changed, with `--seed-data` the `seed data` and `seed` lines, the median times with the direction from the paired rounds (or the median ratio when the rounds cannot judge it), the `time noise` line, shown only when timed (the empirical p95 of the absolute differences between the two baseline A/A runs and the number of pairs; reference only, and it never changes the verdict or the exit code; see [`timing.noise_band`](#timing-evidence-and-advisory-warnings)), the size of the change when the medians agree (`230x faster`), and the size increase, and a note when the build is a debug build. With `--write`, the Summary adds the `write` file, `returning rows`, `rows changed`, `total changed`, and `write runs`, and the side-by-side table adds `rows changed` and `total changed`;
- a side-by-side table of baseline and variant: rows read, rows written, result rows, full-scan steps, VM steps, sort operations and autoindex rows when they are not zero, the p25 and p75 times when timed, and the database file bytes;
- the query plan for both copies, with `kind`, `covering`, and `automatic` as hints read from SQLite's wording;
- a `Warnings` section with `warning: <code>: <message>` lines when an advisory warning applies;
- with `--suggest`, a `Suggested by SQLite:` section that lists each proposal as `suggested:N: CREATE INDEX ...` with its SQL text, and `warning: <code>: <message>` lines after the tables for what was dropped or could not be done;
- with `--d1`, a D1 block: the binding, the config, the database id, the local file, the SQLite version difference, and the caution about production D1.

When the rows differ, cannot be compared, or come in another order, the human output adds an explanation and the one-sided counts. Example rows appear only with `--show-rows`; when they are hidden, the human output says to rerun with that flag. `--show-binds` adds the bind values.

Input paths other than `--seed-data`, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions appear only in `kv` and `json`. The timing evidence fields (`effect`, `median_difference_ns`, `confidence_interval`) appear only in `kv` and `json`; the human Summary shows the median times, the direction, and the A/A noise band. With `--d1`, `human` also shows the D1 block described above.

## kv

`--format kv` prints every fact as one `key: value` line, for scripts and logs. It includes the inputs, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions, which the human output leaves out. With `--d1` it adds `d1-binding`, `d1-config`, `d1-database-id`, `d1-local-database`, `d1-sqlite-version`, `d1-sqlite-version-note`, and `d1-caution`. With `--seed-data` it adds `seed-data`, `seed`, `seed-rows`, `seed-tables`, and one `seed-table` line per table. With `--write` it prints `write` instead of `select`, adds `result-kind`, `write-changes-baseline`, `write-changes-variant`, `write-total-changes-baseline`, `write-total-changes-variant`, and `write-runs`, and describes the write measurement in the `measure-*` lines. `baseline-only-row` and `variant-only-row` appear only with `--show-rows`.

## json

`--format json` prints one JSON object with a trailing newline after a comparison finishes. With `--batch` it prints the separate `batch_schema_version` 1 object described above (see [Batch comparisons](batch.md#batch-comparisons) and [docs/json.md](json.md)). With `--batch --rank` it prints one object that carries `schema_version` 2 and `rank_schema_version` 1: rows read, rows returned, the ratio, full-scan steps, and `rows read x runs` labelled as a relative indicator, not a bill (see [Ranking queries on the baseline (--rank)](batch.md#ranking-queries-on-the-baseline---rank)). With `--scale` it prints the separate `scale_schema_version` 1 object with one comparison per size (see [Measuring at several sizes](usage.md#measuring-at-several-sizes---scale)). With `--seed-data`, both objects add a top-level `seed_data` object. The fields, including names reserved for the next core change, are specified in [docs/json.md](json.md). When an input is rejected, the time limit is reached, or the run is interrupted, stdout stays empty. With `--format json`, stderr is then one JSON object (`schema_version`, `exit_code`, and `error` with `code`, `message`, and `hint`). `human` and `kv` keep the text `error:` line.

The verdict is in the top-level `verdict` field:

| `verdict` | Meaning |
| --- | --- |
| `improved` | The rows match, and the variant reads fewer rows |
| `no-effect` | The rows match, and the variant reads the same number of rows |
| `needs-check` | The rows match, but the variant reads or writes more rows; `verdict_reasons` holds the reasons |
| `not-judged` | The rows differ or cannot be compared; `verdict_reasons` holds the reasons |

A `--migration` batch names the `needs-check` case `regressed`, because the migration is a change that is already written. A write statement that the manifest lists under `writes` follows the same name, and only its rows read decide it: more rows written is reported and leaves the verdict at `no-effect`. The standalone, `--batch`, and `--suggest` verdicts keep `needs-check`; the batch `summary` count likewise keeps the key `needs_check` and counts queries only. A query that only the variant can run is `not-judged` and keeps the exit code unchanged. See [Batch comparisons](batch.md#batch-comparisons).

The verdict uses the rows read and the rows written, with the same counting as local D1 (workerd patch). The times are a reference only, so `--runs 0` keeps the verdict. The numbers have not yet been checked against production D1. In `--write`, `result` compares the `RETURNING` rows (empty without `RETURNING`), and the two copies must also report the same `changes` and `total_changes`; a difference is `mismatch` and exit `3`, and the row counts are not judged.

Print only the verdict:

```sh
qenome app.db select.sql index.sql --format json | jq -r .verdict
```

In CI, keep the index only when the results match and the verdict is `improved`:

```sh
if qenome app.db select.sql index.sql --format json | jq -e '.result == "match" and .verdict == "improved"' > /dev/null; then
  echo "keep the index"
fi
```

<details>
<summary>Main keys and string escaping</summary>

Main keys:

| Key | Contents |
| --- | --- |
| `schema_version` | Version of the output format (currently `2`; `1` was the time verdict) |
| `statement` | `select` or `write` |
| `exit_code` | Exit status for the comparison (`0`, `3`, or `4`). If cleanup fails after a match, the JSON is written first and the process exits with `5` instead of `0` |
| `verdict` / `verdict_reasons` | Verdict from the rows read and its reasons (`improved` / `no-effect` / `needs-check` / `not-judged`) |
| `result` | Result row comparison (`match` / `mismatch` / `incomparable`) |
| `row_order` | Row order (`same` / `differs` / `not-applicable`). Reference only and not part of the match; `same` or `differs` only when `result` is `match` |
| `result_reasons` | Why the rows cannot be compared. Each element has `text` and `hint` (`null` when there is none) |
| `row_differences` | `baseline_only` and `variant_only` counts. `baseline_only_examples` and `variant_only_examples` are arrays; they stay empty by default, and `--show-rows` fills them with up to 5 example rows |
| `plan_changed` | Whether the query plan differs between baseline and variant |
| `baseline` / `variant` | `rows`; `plan` (`id`, `parent`, `kind`, `covering`, `automatic`, `detail`); `counters` (`rows_read`, `rows_written`, `fullscan_steps`, `vm_steps`, `sort_ops`, `autoindex_rows`). With `--write`, also `changes`, `total_changes`, and `executions` |
| `timing` | `rounds`, `variant_faster_rounds`, `ratio`, and `baseline` / `variant` with `median_ns`, `p25_ns`, `p75_ns`, `min_ns`, `max_ns`. `null` when not timed; `ratio` is `null` when the baseline median is `0`. `noise_band`, `confidence_interval`, `median_difference_ns`, `effect`, and `unavailable_reason` describe the timing evidence below |
| `size_bytes` | `baseline`, `variant`, and `increase` (the whole database file, not the index alone; with `--migration`, the bytes in use instead, see [Batch comparisons](batch.md#batch-comparisons)) |
| `inputs` | `database`, `select`, and `index_sql` paths. With `--write`, `write` replaces `select` |
| `d1` | Present only with `--d1`: `binding`, `config`, `database_id`, `local_database`, `sqlite_version` (D1's 3.53.4), `sqlite_version_note`, and `caution` |
| `environment` | `qenome_version` (the same version as `--version`, from `build.zig.zon`), `sqlite_version`, `sqlite_source_id`, `zig_version`, `build_mode`, `os`, `arch`, `work_dir_parent` |
| `measurement` | Timing conditions: `runs_per_copy` (timed rounds per copy; `0` when not timed), `warmup`, `order`, `scope`, `cache`. With `--write`, `runs_per_copy` is the number of rolled-back executions per copy |
| `binds` | `number` and `type`; text also has `text_bytes`. `value` appears only with `--show-binds` |
| `warnings` | An array of `{code, message}` (`no_analyze_stats`, `data_too_small`, `bind_dependent_partial_index`, `unapplied_migrations`); advisory, never changes verdict or exit |
| `sqlite` | Reserved, not emitted yet. `bundled_version` and `db_header_version`. Until then, the bundled version is `environment.sqlite_version` |

- String values write a backslash as `\\` and each byte that is not valid UTF-8 as `\xNN` (byte 0xFF becomes `\xff`), and the result is then escaped as JSON. A literal four-character `\xff` therefore becomes `\\xff` and is a different string from the byte 0xFF. To recover the original bytes, read `\\` as one backslash and `\xNN` as that byte, and leave everything else as it is. Paths, plan details, reasons, and bind text use this rule. Text values in the example rows use it too, surrounded by single quotes (for example `'\xff'`, which appears as `'\\xff'` in the JSON text); BLOBs are written as `x'00ff'`. Example values longer than 200 bytes are cut and followed by `...(N bytes)`.
- `binds` keeps the same secrecy as kv. Without `--show-binds`, only the number, the type, and the text length appear. A non-finite real value (`inf` or `-inf`) is written as a string, because JSON numbers cannot represent it.
- `row_differences` always has both counts. The example array keys are always present but empty unless `--show-rows` is set; human and kv use the same flag and print only the counts by default.
- `row_order` is a reference, not part of the result match.

</details>

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | The result rows match |
| 1 | An input was rejected (unreadable file, invalid or rejected SQL, bind mismatch, index creation failure, rejected `--write` statement) |
| 2 | A usage error |
| 3 | The result rows differ, or a `--write` made a different change (`changes` or `total_changes`) |
| 4 | The results cannot be compared, a `--write` was not run because it reads the schema, the current time, or a nondeterministic function, or `--d1` cannot locate exactly one local database (no config, more than one config, an unreadable or invalid config, an unknown or duplicate binding, a missing database id, a local file that does not exist yet, or a local file that cannot be opened) |
| 5 | Cleanup failed after the comparison (this replaces 0; every other code is kept) |
| 6 | With `--migration`, the result rows matched but a query read or wrote more rows, or a write statement read more rows. Only the `--migration` batch path returns it |
| 7 | With `--rank`, the report was written and at least one query is a likely full scan. A report with none exits `0`. Cleanup failure replaces `0` only, so `7` is kept |
| 124 | A time limit was reached (`--timeout-ms`) |
| 129 / 130 / 143 | Interrupted by `SIGHUP` / `SIGINT` / `SIGTERM` (POSIX) |

For how the counters are built and what each verdict means for production D1, see [Accuracy and production D1](accuracy.md).

`--format json` reports the comparison result in `exit_code` as `0`, `3`, or `4`. The process can still exit with `5` after writing the JSON.

A `--batch` report can be written with exit `1`, `6`, or `124`. If stdout is the batch object, the run finished and the failures are in the report. If stdout is empty, the run stopped and stderr holds the error object.

## Timing evidence and advisory warnings

<details>
<summary>Timing evidence and advisory warnings in detail</summary>

Each timed round first runs the baseline SELECT twice (A/A), then runs one baseline/variant pair, alternating AB and BA. Both sessions are already warm from the compared run. A/A adds two baseline executions per round. The measured counters in the report still come only from the first compared SELECT; diagnostics and timed executions do not enter them. Warning checks run after timing, on sandbox copies only. No ANALYZE or PRAGMA optimize is run.

`timing.noise_band` reports the empirical 95th percentile of absolute differences between the two baseline A/A durations, using nearest rank `ceil(0.95*n)` and reporting `pairs`. This is a heuristic noise reference, not a confidence bound or a significance threshold with a calibrated false-positive rate. No observed A/A spread does not prove zero underlying variation.

`timing.median_difference_ns` is the median of the per-round differences `variant_i - baseline_i` (negative is faster), not the difference of the two medians and not a ratio. Existing `ratio` remains variant median / baseline median. `confidence_interval` uses sorted paired differences and a symmetric binomial sign interval for their population median. For zero-based endpoints `k` and `n-k-1`, choose the largest k with `P(Binomial(n,0.5) <= k) <= 0.025`; coverage is `1 - 2*P(...)`. `level` is the requested 0.95; `coverage` is the conservative binomial coverage under independent identically distributed continuous differences. This follows the [order-statistic approach described by NIST](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/mediancl.htm), without interpolation. It describes uncertainty in the median difference, not a future single duration. There is no resampling.

The interval is `null` with `unavailable_reason` `too-few-rounds` below six rounds (the widest finite interval has coverage 93.75% at n=5 and 96.875% at n=6), `zero-duration` when any timed duration is zero, or conservatively `no-observed-variation` when all paired differences are equal. These cases give `effect: insufficient-samples`, not a claim of precision at the clock resolution. Otherwise `effect` is `no-difference` if the absolute value of the median paired difference is at most the A/A noise reference or the interval includes zero; it is `faster` or `slower` only when both checks allow that direction. This auxiliary label never changes `verdict` or the exit code. Fixed A/A-before-A/B ordering, cache effects, temporal dependence, load drift, and small samples limit interpretation: nominal 95% coverage is not an exact guarantee for these machine timings or for production D1. The human output shows the median times and the direction from the paired rounds; it adds the size of the change only when the medians point the same way. When the paired rounds cannot judge the direction, it shows the median ratio without a direction and says that the direction is not determined. The evidence fields above stay in `kv` and `json`.

`warnings` is always an array, including with `--runs 0` or incomparable results. Its `{code, message}` entries also appear verbatim in human and kv output. A batch or `--suggest` human report lists `no_analyze_stats` and `data_too_small` once per candidate in its `Warnings` section, and `bind_dependent_partial_index` with the query and candidate that produced it. `no_analyze_stats` means the candidate index's table has no non-empty `sqlite_stat1` entry in the baseline snapshot, even if other tables have statistics. This is an absence check, not a freshness/completeness check: a partial-index entry alone counts as present. `data_too_small` means a bounded `SELECT 1 ... LIMIT 1000` on that table returned fewer than 1000 rows. Reaching 1000 only establishes at least 1000 rows; statistics estimates, partial-index cardinality, SELECT result count, and rows read do not decide this warning. The threshold is a heuristic, not proof that larger data is representative. Warnings advise a representative, separately prepared copy; they do not suppress a row verdict or change exit codes. Diagnostic reads respect the existing per-statement timeout/cancellation; failures follow the existing error path.

`bind_dependent_partial_index` names a partial index that the variant plan uses only because the bound values satisfy its `WHERE` clause. Qenome reads the variant plan with the bound values and again with every parameter bound to `NULL`. If the partial index appears in the first plan and not the second, the message names it. `NULL` cannot prove a partial index's `WHERE` clause, so the difference means the index is usable because of the values: another value or parameter style can drop it, and an `improved` result then holds only for this run. The check needs only the variant plan, so it runs in every mode, including a variant-only `--migration` query. It is best-effort: when the extra plan or the index catalog cannot be read, including a time limit or an interruption, the warning is omitted and the comparison continues. It never changes the verdict, the exit code, or a batch count. In a batch report the entry is in `results[].comparison.warnings`, and the batch `human` output lists it under `Warnings` with the query and candidate.

</details>
