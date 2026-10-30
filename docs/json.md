# JSON contract (schema_version 2)

`--format json` is the machine-readable interface. This file is the contract for `schema_version` 2. The JSON Schema files next to it check the same shape: [qenome-report.schema.json](qenome-report.schema.json) for a finished comparison, [qenome-error.schema.json](qenome-error.schema.json) for a failure, [qenome-batch.schema.json](qenome-batch.schema.json) for a `--batch` report (`batch_schema_version` 1), [qenome-index-audit.schema.json](qenome-index-audit.schema.json) for an `--audit-indexes` report (`audit_schema_version` 1), and [qenome-record.schema.json](qenome-record.schema.json) for a `--record` report (`record_schema_version` 1).

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

`--batch manifest.json` compares every SELECT in the manifest with every candidate CREATE INDEX. With `--suggest`, the manifest may omit `candidates`, and SQLite's proposed indexes join the comparison. With `--migration`, the manifest also omits `candidates`, and one SQL file with index or table changes is applied to the variant before the queries run. Its stdout object is a separate contract with `batch_schema_version` 1. The comparison objects under `results` keep `schema_version` 2 and the shape above. `--suggest` and `--migration` add keys to this contract without changing the version.

| Key | Type | Meaning |
| --- | --- | --- |
| `batch_schema_version` | number | `1` |
| `exit_code` | number | `0`, `1`, `3`, `4`, `6`, or `124`. The process can still exit `5` after this object when cleanup fails and the code is `0` |
| `recommended` | string or `null` | The candidate label: a path from the manifest, the `--migration` path, or `suggested:N` with `--suggest`. `null` when no candidate qualifies |
| `migration` | object | Present only with `--migration`: `path` and `statements`. See [`--migration`](#--migration) |
| `seed_data` | object | Present only with `--seed-data`: `path`, `seed`, `rows`, and `tables`. See [`--seed-data`](#--seed-data) |
| `summary` | array | One object per candidate, ordered as described below. 1 to 100 entries |
| `results` | array | One object per compared query and candidate, ordered by candidate (manifest entries first, then suggestions) and then by query (manifest order). An `index_rejected` or `index_timeout` candidate has no entries here |
| `warnings` | array | `{ "code", "message" }` entries. Holds what `--suggest` dropped or could not do, and, with `--d1`, `unapplied_migrations`. A comparison warning (including `bind_dependent_partial_index`) is in `results[].comparison.warnings`, not here; the `human` report lists each one under `Warnings` as `<query> -> <candidate>: <code>: <message>` |

### `summary` entries

| Key | Type | Meaning |
| --- | --- | --- |
| `candidate` | string | The `index_sql` string from the manifest, `suggested:1`, `suggested:2`, … for a proposed index, or the `--migration` path |
| `source` | string | `manifest`, `suggested`, or `migration` |
| `index_sql_text` | string | The SQL text: for a manifest candidate, the contents of its file; for a suggestion, the statement SQLite reported (ending with `;`); for `--migration`, the contents of the migration file |
| `status` | string | `compared`, `index_rejected`, or `index_timeout` |
| `failure` | object or `null` | `null` for `compared`; otherwise `{ "code", "message" }`. `code` is `index_rejected` or `index_timeout` |
| `improved`, `no_effect`, `needs_check`, `mismatch`, `incomparable` | number or `null` | How many queries ended in each outcome. `improved + no_effect + needs_check + mismatch + incomparable + timeout + not_judged` equals the query count. `null` when the candidate was not compared. In a `--migration` run, `needs_check` counts the queries whose embedded comparison verdict is `regressed` |
| `timeout` | number or `null` | Queries whose variant SELECT reached `--timeout-ms` |
| `not_judged` | number or `null` | Queries that only the variant could run because the migration added the column or table. Each has `verdict` `not-judged` in its embedded comparison. The count does not affect `recommended` or the exit code |
| `size_increase` | number or `null` | Variant minus baseline in bytes (signed). For `manifest` and `suggested` candidates it is the file size. For a `--migration` run it is the bytes in use, `(page_count - freelist_count) * page_size`, so a dropped index reports the freed bytes as a negative number. `null` when the change was not applied |

A candidate qualifies for `recommended` when its status is `compared` and `mismatch`, `incomparable`, `needs_check`, and `timeout` are all `0` and `improved` is at least `1`. `not_judged` is not part of this check. In a `--migration` run, `needs_check` counts the `regressed` queries, so a migration that made a query worse never qualifies. Qualifying candidates come first in `summary`, in this order: more `improved`, then a candidate without a `bind_dependent_partial_index` warning before one with it, then smaller `size_increase`, then input order. Input order is the manifest order, and suggestions follow the manifest entries. A `--migration` run has exactly one candidate, so it is either first in this order or last. The remaining `compared` candidates follow in input order, and the `index_rejected` / `index_timeout` candidates come last in input order.

### `results` entries

| Key | Type | Meaning |
| --- | --- | --- |
| `query` | string | The `select` string from the manifest, or the SELECT path argument for a one-SELECT `--suggest` |
| `candidate` | string | The `index_sql` string from the manifest, or `suggested:N` |
| `status` | string | `compared` or `variant_timeout` |
| `comparison` | object or `null` | `null` for `variant_timeout`; otherwise the schema_version 2 comparison object, with `inputs.select` and `inputs.index_sql` set to the same strings. For a one-SELECT `--suggest`, `inputs.select` is the SELECT path argument. With `--migration`, `inputs.index_sql` is the migration path, and a query whose rows match but whose read or written rows increased has `verdict` `regressed`. A query that only the variant can run has `verdict` `not-judged`, `result` `incomparable`, and `baseline` `null`. The embedded object is minified |

### `--migration`

`--migration <FILE>` applies one migration file to the variant copy before the batch queries run. It needs `--batch`, and the manifest must omit `candidates` or set it to `[]`. It does not take `--select`, `--index-sql`, `--bind`, `--runs`, `--suggest`, or `--format kv`.

- The file is at most 1 MiB and may hold several statements separated by semicolons. It accepts `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` with a column list (not `AS SELECT`), and `ALTER TABLE` with ADD COLUMN, RENAME COLUMN, DROP COLUMN, or RENAME TO. `INSERT`, `UPDATE`, `DELETE`, `DROP TABLE`, `ATTACH`, `PRAGMA`, and every other statement are rejected before the variant is touched, with a statement number and exit `1`; the original database is never changed. The reject code is `migration_statement_rejected`.
- Statements run in file order, so a migration may add a column and index it, rename a column or table, or drop an index and create another with the same name. Each statement gets its own `--timeout-ms`. A statement that fails to apply is recorded as `index_rejected` (or `index_timeout`) in `summary`, and the run still writes the report with exit `1` (or `124`).
- The report names the migration and every statement. Human output adds a `migration:` block; JSON adds the top-level `migration` object with `path` and `statements` (each has `kind`: `create_index`, `drop_index`, `create_table`, or `alter_table`, and `sql`).
- A query that uses a column or table the migration adds cannot be prepared on the baseline. Qenome measures it on the variant only and reports the variant plan and row counts. Its embedded comparison has `verdict` `not-judged`, `result` `incomparable`, `baseline` `null`, `plan_changed` `true`, `exit_code` `0`, and `verdict_reasons` with the baseline reason. `summary.not_judged` counts it. It does not change `recommended` or the batch `exit_code`.
- A query that the migration breaks stops the run before the report. If it refers to a column or table the migration drops or renames, the variant cannot prepare the `SELECT`: stdout is empty, the exit code is `1`, and the error code is `batch_variant_failed`. The message names the query and the migration path. Write the post-migration names in the manifest.
- Adding or dropping a column changes the column count of a `SELECT *` query, so its rows cannot be compared. Its embedded comparison has `verdict` `not-judged`, `result` `incomparable`, `exit_code` `4`, and `result_reasons` with `the column count differs between the copies`; `baseline` is present because the query runs on both copies. `summary.incomparable` counts it and the batch exits `4`. List the columns to compare it.
- The `summary` entry for a migration has `source` `migration`, `candidate` set to the migration path, and the same `improved` / `no_effect` / `needs_check` / `mismatch` / `incomparable` / `timeout` / `not_judged` counts. A query whose rows match but whose read or written rows increased has `verdict` `regressed` in its embedded comparison and is counted under `needs_check`. `recommended` is the migration path only when it qualifies like any other candidate.
- A migration measures `size_increase` and the `size_bytes` of each embedded comparison as the bytes in use, `(page_count - freelist_count) * page_size`, not as the file size. `DROP INDEX` moves its pages to SQLite's freelist without shrinking the file, so the file delta stays `0`; the bytes in use report the freed space as a negative number. The file shrinks only after `VACUUM`. A batch without `--migration` keeps the file size difference.
- When the result rows match but at least one query read or wrote more rows after the migration, that query's `comparison.verdict` is `regressed`, the batch counts it under `needs_check` in `summary`, and the batch `exit_code` is `6`. A heavier result (`3` mismatch, `1` rejected change, `124` timeout, `4` incomparable) takes precedence. `no_effect` alone keeps `0`.
- The batch top-level `warnings` holds no `no_analyze_stats` or `data_too_small` entry with `--migration`: those checks need one candidate table, and a migration can touch several. The comparison `warnings` still carries `bind_dependent_partial_index`, which needs only the variant plan and runs for a variant-only query too. A `--d1` batch adds `unapplied_migrations` to the top-level `warnings` with or without `--migration`, because the check reads the local D1 database and no candidate.

### `--seed-data`

`--seed-data <FILE>` fills the sandbox baseline copy with deterministic dummy rows before the variant is copied, so the original database is never changed. It works with every mode, including `--batch`, `--suggest`, and `--migration`. The file is at most 1 MiB and is one JSON object:

```json
{
  "seed": 7,
  "tables": {
    "events": {
      "rows": 50000,
      "columns": {
        "id": { "kind": "sequence" },
        "status": { "kind": "ratio", "value": "ok", "ratio": 0.5, "otherwise": "failed" },
        "note": { "kind": "fixed", "value": null }
      }
    }
  }
}
```

- `seed` is optional and defaults to `0`. The same spec and seed give the same rows.
- `tables` maps a table name to `rows` and optional `columns`. A column left out takes its SQLite default or rowid; a default must be a literal, and a column with an expression default must be listed in the spec. A listed table with a trigger, or table or column names that differ only by case, is rejected.
- Each column has one `kind`: `fixed` (`value`), `uniform` (`values`), `ratio` (`value`, `ratio`, optional `otherwise`), or `sequence` (optional `from`, `step`).
- The listed tables are emptied first, so their row count is exactly `rows`; unlisted tables are unchanged. Limits are 100 tables, 10,000,000 rows per table, and 20,000,000 rows in total.
- A PRIMARY KEY, UNIQUE, NOT NULL, or CHECK violation stops the run with exit `1`, even when the table declares `ON CONFLICT IGNORE` or `ON CONFLICT REPLACE`. Foreign keys are not checked on the sandbox copy, which is the SQLite default.
- Qenome runs `ANALYZE` on each listed table in the same transaction, so the plan sees statistics for the generated rows.
- The human Summary adds `seed data` and `seed`; `kv` adds `seed-data`, `seed`, `seed-rows`, `seed-tables`, and one `seed-table` per table; `json` adds a top-level `seed_data` object. A batch report has `seed_data` at the top level, and the embedded comparison objects under `results` do not repeat it.

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
| --- | --- |
| `suggest_query_skipped` | SQLite could not analyze one SELECT; the other SELECTs continue |
| `suggestion_rejected` | A proposed statement failed the `CREATE INDEX` check and was dropped |
| `suggestions_truncated` | The 20 or 100 limit dropped the tail of the suggestions |
| `no_suggestions` | SQLite proposed nothing; the manifest candidates were still compared |
| `suggest_failed` | The expert could not start or analyze; the manifest candidates were still compared |

- When nothing can be compared (no manifest candidate and no surviving suggestion), the run stops with exit `1`, empty stdout, and error code `no_candidates`.
- With one SELECT file (no `--batch`), the SELECT is one batch query, `--bind` applies to it, and the report is the same batch object. `--suggest` does not take `--runs`, `--format kv`, or an index file.
- Use `--suggest` to find candidates. For a CI gate that must not change when SQLite changes its advice, compare a named index without `--suggest`.

### Exit code and stderr

When the report is written, the exit code is the heaviest of: result mismatch `3`, a candidate index or migration that could not be built `1`, a candidate time limit `124`, an incomparable result `4`, a `--migration` regression `6`, and `0`. Cleanup failure replaces `0` with `5`.

A batch can therefore write a report and still exit `1`, `6`, or `124`. Read stdout to decide: if stdout is a batch object, the run finished and the failures are in `summary` and `results`. If stdout is empty, the run stopped before the report and stderr holds the schema_version 2 error object. Candidate failures (`index_rejected`, `index_timeout`, `variant_timeout`) are never written as `error:` lines.

The migration statement kind check is not a candidate failure: an unsupported statement (including a data change or `DROP TABLE`), an empty migration, or an unreadable file stops before the report and writes the error object on stderr. A manifest query that the variant cannot prepare after the migration (it uses a column or table the migration dropped or renamed) stops the same way with `batch_variant_failed`. A failure to apply a syntactically valid statement (for example, dropping an index that does not exist) is a candidate failure and stays in the report.

Batch error codes:

| `code` | Exit | Next step the hint points at |
| --- | --- | --- |
| `usage_batch_conflict` | 2 | Put the SELECT, CREATE INDEX, and binds in the manifest; use `--format human` or `json`; do not pass `--runs` |
| `usage_audit_conflict` | 2 | Use `--audit-indexes` with `--batch` and a manifest that has queries; remove `--suggest`, `--migration`, and `--seed-data` |
| `audit_query_failed` | 1 | Fix the SELECT in the manifest, or read the SQLite message |
| `audit_query_timeout` | 124 | Raise `--timeout-ms`, or narrow the SELECT |
| `audit_catalog_unreadable` | 1 | Read the SQLite message and check that the schema can be read |
| `audit_catalog_timeout` | 124 | Raise `--timeout-ms`, or check the schema for a very large catalog |
| `usage_record_conflict` | 2 | Use `--record` with `--out` only, and `--format human` or `json` with `--n-plus-one-threshold`; remove the database, SQL, batch, migration, bind, runs, suggest, and seed options |
| `record_log_unreadable` | 1 | Check that the record log path exists and is readable, then rerun |
| `record_log_invalid` | 1 | Record a session with at least one SELECT, at most 100 distinct statements, and at most 1 MiB. When the 100-statement limit stops the run, the message also names the most repeated shape and how many statements share it |
| `record_output_failed` | 1 | Choose a new `--out` directory and check that it is writable, then rerun |
| `batch_manifest_unreadable` | 1 | Check the manifest path and permissions |
| `batch_manifest_invalid` | 1 | Fix the shape, limits, repeated paths, or binds |
| `batch_sql_unreadable` | 1 | Check the SQL paths in the manifest; they are relative to the manifest |
| `migration_unreadable` | 1 | Check the `--migration` path and permissions |
| `migration_empty` | 1 | Write at least one CREATE INDEX, DROP INDEX, CREATE TABLE, or ALTER TABLE statement |
| `migration_statement_rejected` | 1 | Use only CREATE INDEX, CREATE UNIQUE INDEX, DROP INDEX, CREATE TABLE (not AS SELECT), and ALTER TABLE (ADD / RENAME / DROP COLUMN and RENAME TO) |
| `migration_failed` | 1 | Fix the named statement so it applies to this database |
| `batch_baseline_failed` | 1 | Fix the SELECT or read the SQLite message |
| `batch_baseline_timeout` | 124 | Raise `--timeout-ms` or narrow the SELECT |
| `batch_variant_failed` | 1 | Read the SQLite message; the run stopped before the report. With `--migration`, the query may use a column or table that the migration dropped or renamed |
| `batch_variant_timeout` | 124 | Raise `--timeout-ms` or simplify the CREATE INDEX |
| `batch_index_failed` | 1 | Fix the candidate CREATE INDEX so it applies to this database |
| `batch_workspace_failed` | 1 | Check the temporary directory and its permissions |
| `no_candidates` | 1 | Check that a SELECT has a WHERE or ORDER BY clause, or write a candidate CREATE INDEX |
| `suggest_failed` | 1 | Check that the SELECTs are valid, or drop `--suggest` and name the index |
| `suggest_schema_rejected` | 1 | Use a database whose `sqlite_schema` holds only plain CREATE statements, or compare a named index without `--suggest` |

## Index audit report (audit_schema_version 1)

`--batch FILE --audit-indexes` writes one object with `audit_schema_version` 1 and a trailing newline. It is a separate contract from the batch report: `batch_schema_version` 1 and the comparison object above do not change. [qenome-index-audit.schema.json](qenome-index-audit.schema.json) checks the same shape.

| Key | Type | Meaning |
| --- | --- | --- |
| `audit_schema_version` | number | `1` |
| `exit_code` | number | `0`. The process can still exit `5` after this object when cleanup fails |
| `database` | string | The `--db` path, or the local D1 path that `--d1` resolved |
| `queries` | number | How many manifest queries were planned, 1 to 100 |
| `redundancy_judged` | boolean | `false` when a manifest SELECT uses `INDEXED BY`; every `redundant_by` is then `null` |
| `indexes` | array | One object per index in the main schema, ordered by table and then by name |
| `warnings` | array | Emitted. `{ "code", "message" }` entries, empty without a `--d1` `unapplied_migrations` entry. This contract keeps the comparison `warnings` codes; an audit never runs the comparison checks |

`indexes` entries:

| Key | Type | Meaning |
| --- | --- | --- |
| `name` | string | The index name. `sqlite_autoindex_*` is a UNIQUE or PRIMARY KEY constraint index |
| `table` | string | The table |
| `columns` | array of strings | The key columns in index order. An expression key is `"<expression>"` |
| `unique` | boolean | The index enforces UNIQUE |
| `partial` | boolean | The index has a `WHERE` clause |
| `expression` | boolean | At least one key column is an expression, so the report does not compare this index with others |
| `constraint` | string or `null` | `unique` or `primary_key` for a constraint index; `null` otherwise |
| `used` | boolean or `null` | Whether a manifest plan named the index. `null` for a constraint index, because a WITHOUT ROWID primary key plan says `USING PRIMARY KEY` instead of the index name |
| `redundant_by` | string or `null` | Another index on the same table whose key columns start with this index's columns, with the same collation and ASC/DESC. `INTEGER PRIMARY KEY` means the rowid primary key |

Semantics and limits:

- `used` false means the plans of this manifest did not name the index. It is not a drop instruction: `UPDATE`, `DELETE`, foreign-key maintenance, and queries outside the manifest are not planned. An index used only for `ORDER BY` or `GROUP BY` appears in these plans.
- A partial index is listed as unused when no plan named it, but it is never a redundancy candidate, because its `WHERE` clause and the bound values decide whether it can replace another index.
- An expression index is never a redundancy candidate. A different collation or ASC/DESC order is not treated as covered.
- A redundancy candidate can be replaced by the `redundant_by` index for the lookups this index serves. Two indexes with the same key list report only the later name, so the pair is counted once.
- Findings do not change the exit status: a written report keeps `0`. The process exits `1` when a query cannot be prepared or a catalog read fails, `2` for a usage error, and `124` when `--timeout-ms` reaches a plan or a catalog read.
- `INDEXED BY` in any manifest SELECT suppresses the redundancy list. The query forces an index, and the audit does not try to see which other indexes could replace it.
- `warnings` carries `unapplied_migrations` with `--d1` when the local D1 database has not applied every migration of the wrangler config; the files and the read-only check are the same as in the comparison. The `human` report lists the entry in a `Warnings` section. It does not change the findings or the exit status.

## Record report (record_schema_version 1)

`--record FILE --out DIR --format json` writes one object with `record_schema_version` 1 and a trailing newline. It is a separate contract from the batch report: `schema_version` 2, `batch_schema_version` 1 and `audit_schema_version` 1 do not change. [qenome-record.schema.json](qenome-record.schema.json) checks the same shape. Without `--format json` the same facts are text lines, and the `repeated shapes:` block follows the per-query lines on stdout. [README](../README.md#recording-the-queries-your-app-runs---record) describes the command.

| Key | Type | Meaning |
| `record_schema_version` | number | `1` |
| `exit_code` | number | `0` when the report is written. A finding never changes the exit code |
| `manifest` | string | The `manifest.json` path under `--out` |
| `records` | number | Record lines read, including the skipped ones |
| `queries` | array | One `{ "select", "executions" }` object per manifest entry, in `queries/qNNN.sql` order |
| `skipped` | object | The counters `writes`, `exec`, `other`, `blob`, `unsupported`, `nul`, `large`, `malformed` and `version`; the same numbers as the human `skipped:` line |
| `repeated_shapes` | array | At most 20 shape objects, ordered by `distinct_values`, then `executions`, then first appearance in the log |
| `repeated_shapes_dropped` | number | How many shapes passed the threshold and did not fit in the top 20 |

`repeated_shapes` entries:

| Key | Type | Meaning |
| `kind` | string | `read` for SELECT and VALUES, `write` for INSERT, UPDATE, DELETE and REPLACE |
| `executions` | number | Records with this shape |
| `distinct_values` | number | Distinct combinations of bind values and inlined literals. Records from `op: "batch"` are not counted here |
| `longest_run` | number | Longest stretch of consecutive records with this shape, in log order. A record that the report skips, such as a `PRAGMA` or an `exec`, ends the run |
| `statements` | number | Distinct exact SQL texts with this shape. More than one shows inlined literals |
| `batched` | number | Records with `op: "batch"`. They count in `executions` only; the human block adds `, N batched` for such a shape |
| `example` | string | One exact SQL text of the shape. Never a bind value |
| `previous_shape_example` | string or `null` | The SQL of the shape that most often runs right before a run of this shape, which is usually the query that drives the loop. `null` when no other shape came first |
| `manifest_select` | string or `null` | The `queries/qNNN.sql` entry that holds a statement of this shape. A write shape has `null` |
| `hint` | string | The fixed next step for the kind |

Semantics and limits:

- A shape comes from the tokens of the statement: every `number`, `string`, `blob` and `parameter` token becomes one placeholder, a parenthesised list of only placeholders after `IN` collapses to one list, word case is folded, and identifiers, quoted identifiers, operators and comments stay as tokens. `= ?`, `= ?1`, `= :id`, `= 17` and `= 'a'` share one shape, and so do `IN (?, ?)` and `IN (?, ?, ?)`; a different column, table or operator keeps a different shape. A unary sign on a number is part of the placeholder, so `= -1` matches `= 1`.
- The detection reads every record before the read/write filter, so a loop of `INSERT`, `UPDATE`, `DELETE` or `REPLACE` is reported too.
- A shape is reported when `distinct_values` is at least the threshold: `10` by default, or `--n-plus-one-threshold N` (0 turns the report off, otherwise 2 to 1,000,000). `op: "batch"` records are already one round trip, so they never reach the threshold.
- The report is a hint about round trips and repeated work, not a measurement: it does not change a row count, a timing, the manifest, or the exit code.
- Bind values never appear: only `example` and `previous_shape_example` hold SQL text.

## Status in this tree

| Name | Status |
| --- | --- |
| `schema_version`, `exit_code`, `verdict`, `verdict_reasons` | Emitted |
| `statement` | Emitted as `select` or `write` |
| `baseline.counters.rows_read`, `baseline.counters.rows_written`, and the same fields on `variant` | Emitted. This is the per-side row counts |
| `baseline.changes`, `baseline.total_changes`, `baseline.executions`, and the same fields on `variant` | Emitted only with `--write` |
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
| `exit_code` | number | `0`, `3`, or `4` for the comparison. This stays `0` when the process later exits `5`. A variant-only `--migration` comparison writes `0` |
| `statement` | string | `select` for a SELECT comparison, `write` for an `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` comparison |
| `verdict` | string | `improved`, `no-effect`, `needs-check`, `regressed`, or `not-judged`. `regressed` appears only in a `--migration` batch; the other modes name the same condition `needs-check`. `not-judged` also covers a variant-only `--migration` query whose baseline cannot prepare it, and a `--write` comparison that was not run |
| `verdict_reasons` | array of strings | Why the verdict is `needs-check`, `regressed`, or `not-judged`. Empty for `improved` and `no-effect` |
| `result` | string | `match`, `mismatch`, or `incomparable`. A variant-only `--migration` query is `incomparable` because there is no baseline result to compare. With `--write`, the rows are the `RETURNING` rows (empty without `RETURNING`), and the same `changes` and `total_changes` are also required for a match |
| `row_order` | string | `same`, `differs`, or `not-applicable`. Reference only. `same` or `differs` only when `result` is `match` |
| `result_reasons` | array of `{text, hint}` | Why the rows cannot be compared. `hint` is a string or `null`. Empty for a variant-only `--migration` query; its `verdict_reasons` holds the reason |
| `row_differences` | object | `baseline_only` and `variant_only` counts. `baseline_only_examples` and `variant_only_examples` are arrays, empty unless `--show-rows` |
| `plan_changed` | boolean | The query plan text differs. It is `true` for a variant-only `--migration` query because there is no baseline plan |
| `baseline`, `variant` | object or `null` | `rows` (result row count), `plan` (array of plan steps), `counters`. `baseline` is `null` only for a variant-only `--migration` query; every other comparison has both objects. With `--write`, each object also has `changes`, `total_changes`, and `executions` |
| `baseline.counters` / `variant.counters` | object | `rows_read`, `rows_written`, `fullscan_steps`, `vm_steps`, `sort_ops`, `autoindex_rows`. All numbers. `rows_read` and `rows_written` are 32-bit and wrap past 4294967295 |
| `timing` | object or `null` | See the status table. `ratio` is variant median / baseline median, or `null` when the baseline median is `0` |
| `size_bytes` | object | `baseline`, `variant`, and `increase` (variant minus baseline). The whole database file, not the index alone. In a `--migration` batch it is the bytes in use instead. See [`--migration`](#--migration) |
| `inputs` | object | `database`, `select`, `index_sql` paths. With `--write`, `write` replaces `select` |
| `environment` | object | `qenome_version`, `sqlite_version`, `sqlite_source_id`, `zig_version`, `build_mode`, `os`, `arch`, `work_dir_parent` |
| `d1` | object | Present only with `--d1`: `binding`, `config`, `database_id`, `local_database`, `sqlite_version`, `sqlite_version_note`, `caution` |
| `seed_data` | object | Present only with `--seed-data`: `path`, `seed`, `rows`, and `tables` (each `{table, rows}`) |
| `measurement` | object | `runs_per_copy`, `warmup`, `order`, `scope`, `cache`. With `--write`, `runs_per_copy` is the rolled-back executions per copy and the other values describe the write runs |
| `binds` | array | `number`, `type`. Text also has `text_bytes`. `value` only with `--show-binds` |
| `warnings` | array | Emitted. `{ "code": string, "message": string }`. Expected codes: `no_analyze_stats` (no ANALYZE statistics), `data_too_small` (too little data to trust the counts), `bind_dependent_partial_index` (the variant plan uses a partial index only because the bound values satisfy its WHERE clause), `unapplied_migrations` (the local D1 database has not applied every migration in the wrangler config) |
| `sqlite` | object | Reserved. `bundled_version` (string), `db_header_version` (string) |

`verdict` values:

| `verdict` | Meaning |
| --- | --- |
| `improved` | The rows match, and the variant reads fewer rows |
| `no-effect` | The rows match, and the variant reads the same number of rows |
| `needs-check` | The rows match, but the variant reads or writes more rows |
| `regressed` | The rows match, but the migration made the variant read or write more rows. Only inside a `--migration` batch; the other modes name the same condition `needs-check` |
| `not-judged` | The rows differ or cannot be compared, or a `--migration` query could only run on the variant |

The verdict comes from `rows_read` and `rows_written`. It does not change the exit code. Times do not change the verdict, so `--runs 0` still has a verdict.

## Write comparison (`--write`)

`--write` replaces `--select` and compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE`. The comparison object keeps `schema_version` `2`; the differences are additive:

- `statement` is `write`.
- `inputs.write` holds the write-file path and `inputs.select` is absent. There is no `--batch`, `--migration`, or `--suggest` form of a write comparison.
- `baseline.rows` and `variant.rows` are the number of `RETURNING` rows (0 without `RETURNING`). `row_differences` compares those rows as a multiset.
- `baseline.changes` and `variant.changes` are `sqlite3_changes` for the statement, without trigger or foreign-key changes. `total_changes` is the difference of `sqlite3_total_changes`, which includes trigger and foreign-key changes. Both must match for `result` to be `match`; a difference is `mismatch` and exit `3`.
- `executions` is the number of rolled-back executions per copy. `measurement.runs_per_copy` is the same number. `timing` is always `null`; the `measure-*` values describe the write runs, not a timing loop.
- The plan is read with `EXPLAIN` before the statement runs. A write that calls `random()`, a time function, or a schema table is not executed: `verdict` is `not-judged`, `result` is `incomparable`, and `verdict_reasons` explains that the write was not run. `baseline.counters`, `changes`, `total_changes`, and `executions` are then all `0`.
- `rows_written` is the D1 counter. It includes the table row and each secondary-index insert, trigger insert, and foreign-key cascade, but the bundled patch does not count secondary-index deletes. A `DELETE` can therefore report the same `rows_written` on both copies while its `rows_read` falls.

`--write` keeps the same exit codes as a SELECT comparison: `0` for a match (including `needs-check`), `3` for a mismatch, `4` for an incomparable result, `1` for a rejected write or index, and `124` for a time limit. `regressed` is not used outside a `--migration` batch.

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
| 6 | `regression` | With `--migration`, the result rows matched but a query read or wrote more rows. Only returned by the `--migration` batch path |
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
| `usage_migration_conflict` | 2 | `--migration` needs `--batch`; do not pass `--suggest` or `--index-sql` |
| `usage_write_conflict` | 2 | Use `--write` for one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` with an index file; do not pass `--select`, `--batch`, `--migration`, or `--suggest` |
| `write_unreadable` | 1 | `--write` takes a path to a file that holds one write, not SQL text |
| `write_rejected` | 1 | Use one DML statement that applies to this database, without DDL, `PRAGMA`, `ATTACH`, `VACUUM`, or multiple statements |
| `write_timeout` | 124 | Raise `--timeout-ms` or narrow the write |
| `write_failed` | 1 | Read the SQLite message; the write or one of its constraints failed |
| `write_plan_unreadable` | 1 | Check the write against this database |
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
| `migration_unreadable` | 1 | `--migration` takes a path to a file, not the SQL text |
| `migration_empty` | 1 | Write at least one CREATE INDEX, DROP INDEX, CREATE TABLE, or ALTER TABLE statement |
| `migration_statement_rejected` | 1 | Use only CREATE INDEX, CREATE UNIQUE INDEX, DROP INDEX, CREATE TABLE (not AS SELECT), and ALTER TABLE (ADD / RENAME / DROP COLUMN and RENAME TO) |
| `migration_failed` | 1 | Fix the named statement |
| `seed_data_unreadable` | 1 | Check the `--seed-data` path and permissions |
| `seed_data_invalid` | 1 | Fix the JSON shape, a missing table or column, or a value that does not fit a limit |
| `seed_data_apply_failed` | 1 | Make every value fit the column and its constraints; the original database was not changed |
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

`unapplied_migrations` names the migration files of the wrangler config that the local D1 database does not record as applied. Qenome reads `migrations_dir` (default `migrations`, beside the config file) and `migrations_table` (default `d1_migrations`) from the `d1_databases` entry of `--d1`, lists the `*.sql` files directly in that directory, and compares them with the `name` values of the record table. Only the files that the table does not name are listed, in wrangler's order: the leading number first, then lexical order, with unnumbered files last. The message names at most 10 files and then how many are left, and gives the command `npx wrangler d1 migrations apply <BINDING> --local`, because a comparison against an older schema can hide the effect of the index and report `no-effect` or `improved` for the wrong schema. The entry is omitted when the record table or the directory does not exist, when the local database cannot be read, when the directory holds no `*.sql` file, or when every file is applied. The check is bounded: a record table with more than 10,000 rows, a directory with more than 10,000 entries, a name longer than 4,096 bytes, or a scan that passes its instruction budget counts as unreadable, and the entry is omitted; a `migrations_pattern` and the bindings under `[env.<name>]` are not read. Qenome opens the local database read-only and only reads the `name` column, so the original database does not change, and the warning never changes the verdict, a batch count, or the exit code. In a single comparison the entry is in `warnings`; in a batch, including `--migration` and `--suggest`, it is in the batch top-level `warnings`; in `--batch --audit-indexes` it is in the audit report's `warnings`.

`bind_dependent_partial_index` names a partial index that the variant plan uses only because the bound values satisfy its `WHERE` clause. Qenome reads the variant plan with the bound values and again with every parameter bound to `NULL`. If the partial index appears in the first plan and not the second, the message names it. `NULL` cannot prove a partial index's `WHERE` clause, so the difference means the index is usable because of the values: another value or parameter style can drop it, and an `improved` result then holds only for this run. The check needs only the variant plan, so it runs in every mode, including a variant-only `--migration` query, and its entry is in `warnings` for that comparison. It is best-effort: when the extra plan or the index catalog cannot be read, including a time limit or an interruption, the warning is omitted and the comparison continues. It never changes the verdict, the exit code, or a batch count. In a batch report the entry is in `results[].comparison.warnings`, not in the batch top-level `warnings`, and the batch `human` output lists it under `Warnings` with the query and candidate.

## Remaining reserved fields

Only `sqlite.bundled_version` and `sqlite.db_header_version` remain reserved and unimplemented. Read `environment.sqlite_version` for the bundled version. The timing and warning additions above keep schema_version 2. New error messages still require a stable code in src/cli/control.zig.
