---
name: qenome
description: >
  Decide whether a CREATE INDEX helps a local Cloudflare D1 or SQLite query
  before merging. Compares one read-only SELECT, or one write, before and after
  a candidate index on sandbox copies, and reports the rows read and written,
  the verdict, the exit code, and a JSON report (schema_version 2). Use when a
  D1 or SQLite query is slow, when its plan reads many rows, when the user asks
  whether an index helps or which index is missing, or when a migration that
  adds, drops, or replaces an index or a column must be checked before merge.
  Needs a wrangler d1_databases binding or a SQLite file. Does not apply the
  index to the original database.
---

# Qenome

Qenome compares one read-only `SELECT` with one candidate `CREATE INDEX` on sandbox copies. With `--write`, it compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` instead, inside a transaction that is rolled back. With `--batch`, it compares every SELECT in a manifest with every candidate in one run. With `--batch ... --audit-indexes`, it reports the indexes that the manifest queries did not use and the indexes whose leading columns another index or the primary key covers. With `--suggest`, SQLite's expert proposes the candidate indexes, so a SELECT file is enough. With `--migration`, it applies a SQL file of index or table changes to the variant before comparing every query in a manifest. The verdict uses the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

The contract is [docs/json.md](../../docs/json.md). This skill expects `schema_version` 2. Before telling a user what a result means for production, read [docs/accuracy.md](../../docs/accuracy.md): how rows are counted, what each verdict means, and what can differ from production D1.

## Install this skill

`qenome skill install` copies this file into an AI agent's skills directory: Claude Code `~/.claude/skills/qenome/`, or the cross-agent `~/.agents/skills/qenome/` that Codex, Cursor, and Gemini CLI read. `--project` writes under the current directory, `qenome skill status` shows whether the installed copy is up to date, and `qenome skill uninstall` removes it. `qenome skill print` writes the file to stdout. The links below point at the repository; when you read an installed copy, use https://github.com/alern-c/Qenome for them.

## When to run

Run Qenome before keeping a `CREATE INDEX` on a local D1 or a SQLite file. Run it when the user asks whether an index helps, whether a query got faster, whether a write gets more expensive, or whether a schema change is safe to merge.

Do not run it to change production, to apply SQL, or to estimate a bill. One comparison is one SELECT file and one CREATE INDEX file; `--batch` takes a manifest of them. `--suggest` lets SQLite propose the candidate from the SELECT file alone.

## Install and invoke

On a D1 project:

```sh
npx qenome --version
```

The package is published on npm as `qenome`, so `npx qenome` downloads it. If the command does not resolve, build this repository with `zig build` and call `zig-out/bin/qenome`. The commands below use `npx qenome`. A checkout that has already been built can substitute that binary. The CI job does that substitution.

## Run on a D1 project

1. Work in the wrangler project, or pass `--config path/to/wrangler.toml` (`.json` and `.jsonc` work too).
2. The binding is the top-level `d1_databases` name, for example `DB`.
3. If the local database does not exist yet, create it once:

```sh
npx wrangler d1 execute DB --local --command "SELECT 1"
```

4. Put the query in `select.sql` (one read-only `SELECT`). A candidate `CREATE INDEX` in `index.sql` is optional: `--suggest` asks SQLite for one instead.
5. Take the verdict without a timing loop:

```sh
npx qenome --d1 DB select.sql index.sql --runs 0 --format json
```

6. Add `--bind 1:int:1234` once per parameter. `TYPE` is `int`, `real`, `text`, or `null`. Text may contain `:`.
7. Use `--runs 40` only when the user wants a timing reference. The verdict does not change with the times. `--runs 0` is the default choice for an agent.

`--config` and `--d1` together:

```sh
npx qenome --d1 DB select.sql index.sql --config packages/api/wrangler.toml --runs 0 --format json
```

A SQLite file uses a path instead of `--d1`:

```sh
npx qenome app.db select.sql index.sql --runs 0 --format json
```

## Compare a write (`--write`)

Use `--write` when the user wants to know what a new index costs an `INSERT`, `UPDATE`, `DELETE`, or `REPLACE`, or whether `DELETE ... WHERE` can use the index. `--write` replaces `--select`:

```sh
npx qenome app.db --write update.sql --index-sql index.sql --bind 1:int:1234 --runs 0 --format json
npx qenome --d1 DB --write delete.sql --index-sql index.sql --runs 0 --format json
```

- The file holds one DML statement. A leading `WITH` and a trailing `RETURNING` are allowed. `CREATE`, `DROP`, `ALTER`, `PRAGMA`, `ATTACH`, `VACUUM`, and multiple statements are rejected with exit `1`.
- Each copy runs the statement in a transaction and rolls it back. The original database is never opened for writing. Triggers and foreign keys are active in the sandbox, so their writes are counted and rolled back.
- Both copies must report the same `RETURNING` rows, `changes`, and `total_changes`; a difference is `mismatch` and exit `3`.
- `--runs` is the number of rolled-back executions per copy (at least one), not a timing loop. `--runs 0` still runs once. A later run that reports different counts makes the comparison `incomparable` (exit `4`).
- A write that calls `random()`, a time function, or reads `sqlite_schema` / `sqlite_master` / `sqlite_stat*` is not run: it is `incomparable` (exit `4`) and `verdict_reasons` says the write was not run.
- `--write` works with `--d1`, `--seed-data`, `--bind`, `--timeout-ms`, and every output format. It does not combine with `--batch`, `--migration`, or `--suggest`.
- `rows_written` includes the table row and secondary-index inserts, trigger inserts, and foreign-key cascades. The bundled D1 patch does not count secondary-index deletes, so a `DELETE` can read fewer rows without a higher write count. Say this when reporting a delete result; do not claim that index maintenance is free.

## Fill sandbox data (--seed-data)

Use `--seed-data spec.json` when the local database is empty or too small to show an index effect. It replaces the listed tables in the sandbox copy before the comparison; the original database is never changed. It works with every mode.

```json
{ "seed": 7,
  "tables": { "events": { "rows": 50000, "columns": {
    "id": { "kind": "sequence" },
    "status": { "kind": "ratio", "value": "ok", "ratio": 0.5, "otherwise": "failed" } } } } }
```

- `seed` is optional (default `0`). The same spec and seed give the same rows.
- `kind` is `fixed` (`value`), `uniform` (`values`), `ratio` (`value`, `ratio`, optional `otherwise`), or `sequence` (optional `from`, `step`).
- The listed tables are emptied first; unlisted tables are unchanged. A table with a trigger is rejected, as are names that differ only by case. A PRIMARY KEY, UNIQUE, NOT NULL, or CHECK violation stops with exit `1`, even with `ON CONFLICT IGNORE` or `REPLACE`.
- A column left out takes its SQLite default or rowid; a default must be a literal, so list a column with an expression default in the spec.
- Qenome runs `ANALYZE` on the listed tables, so the plan sees statistics for the generated rows.
- The report adds a top-level `seed_data` object (`path`, `seed`, `rows`, `tables`). In a batch report it is at the top level, not inside each comparison.

```sh
npx qenome app.db select.sql index.sql --seed-data seed.json --runs 0 --format json
npx qenome --d1 DB --batch batch.json --seed-data seed.json --format json
```

## Find candidates (--suggest)

Use `--suggest` when the user has a SELECT but no candidate index. SQLite's expert proposes indexes, and Qenome compares them with the same batch machinery. `--suggest` does not take `--runs`, `--format kv`, or an index file.

```sh
npx qenome app.db select.sql --suggest --format json
npx qenome --d1 DB select.sql --bind 1:int:1 --suggest --format json
npx qenome app.db --batch batch.json --suggest --format json
```

The output is the batch report (see below). Proposals are labelled `suggested:1`, `suggested:2`, …; at most 20 are compared, and at most 100 with the manifest candidates. When no candidate is left, the run stops with exit `1` and `no_candidates`. Qenome checks the database schema before the expert runs and rejects a database whose `sqlite_schema` holds anything other than one plain CREATE statement (`suggest_schema_rejected`, exit `1`), even with manifest candidates. Do not retry with `--suggest` on that database; compare a named index instead. Do not use `--suggest` in a CI gate; compare a named index there.

## Compare many candidates (--batch)

Use `--batch` when the user has several candidate indexes or several queries. The manifest is one JSON object:

```json
{ "queries": [ { "select": "select.sql", "binds": ["1:int:1"] } ],
  "candidates": [ { "index_sql": "index.sql" }, { "index_sql": "index2.sql" } ] }
```

- Paths are relative to the manifest, not the current directory. The human report shortens an absolute path to the shortest trailing part that no other path in the same list shares, so candidates in different directories stay apart; the JSON report keeps the path as written.
- `queries` and `candidates` take 1 to 100 entries each. A path cannot repeat inside one list.
- `binds` uses the same `N:TYPE:VALUE` syntax as `--bind`.
- `--batch` does not take `--select`, `--index-sql`, `--bind`, `--runs`, or `--format kv`.
- A candidate that fails is recorded and the batch continues. A failure that affects the whole run stops with empty stdout.

```sh
npx qenome app.db --batch batch.json --format json
npx qenome --d1 DB --batch batch.json --format json
```

## Audit the indexes a manifest uses (--audit-indexes)

Use this when the user wants to find indexes that no query uses, or duplicate indexes, from a manifest.

```sh
npx qenome app.db --batch manifest.json --audit-indexes --format json
npx qenome --d1 DB --batch manifest.json --audit-indexes --format json
```

- The manifest needs only `queries`; `candidates` are ignored, so a manifest from `--record` works as it is. `--suggest`, `--migration`, and `--seed-data` are not accepted with it.
- The JSON has `audit_schema_version` `1`, `database`, `queries`, `redundancy_judged`, and one `indexes` entry per index: `name`, `table`, `columns`, `unique`, `partial`, `expression`, `constraint`, `used`, `redundant_by`.
- `used` false means the plans of this manifest did not name the index. Do not tell the user to drop it: `UPDATE`, `DELETE`, foreign-key maintenance, and queries outside the manifest are not planned. Say "unused in this manifest".
- `constraint` `unique` or `primary_key` indexes are kept for the constraint, not removal candidates.
- `redundant_by` names another index on the same table whose leading columns match this index's columns with the same collation and ASC/DESC. A partial or expression index is never in this list.
- `redundancy_judged` false means a manifest SELECT uses `INDEXED BY`; do not report redundancy then.
- Exit `0` means the report was written, including when the lists are not empty. Do not treat findings as a failure. Exit `1`, `2`, or `124` means the input, the command, or the time limit failed.
- Do not apply a `DROP INDEX`. Report the candidates and let the user decide.

## Record the queries the app runs (--record)

Use this when the user wants a manifest from the queries the app actually runs, or when a hand-written manifest may miss ORM-built queries.

1. Add `qenome` as a development dependency, and wrap the D1 binding in the test or development entry with `const db = wrapD1(env.DB);` from `qenome/d1`. This one line is the only change to the app.
1. Run the app and keep its output in a new private file:

```sh
(umask 077; npx wrangler dev --local 2>&1 | tee qenome-record.log)
```

1. Build the manifest:

```sh
npx qenome --record qenome-record.log --out qenome-manifest
```

1. Compare it with `--suggest` or `--migration`, because the manifest holds only `queries`:

```sh
npx qenome --d1 DB --batch qenome-manifest/manifest.json --suggest --format json
```

- The same SQL in the log becomes one query. SQL that differs only in whitespace outside strings and comments counts as the same. The first execution supplies the bind values, and human output shows the execution count.
- `INSERT`, `UPDATE`, `DELETE`, `REPLACE`, `exec`, and statements that bind a BLOB, a boolean, or text with a NUL are skipped and counted in the `skipped:` line.
- The manifest holds bind values. Keep it local, do not commit it, and delete the record log after the manifest exists.
- After writing a data-access loop, run `npx qenome --record qenome-record.log --out qenome-manifest --format json` and read `repeated_shapes`: each entry is a statement that ran many times with different values (a possible N+1), with `manifest_select` and a `hint`. It is a hint, not a measurement, and it never changes the exit code. `--n-plus-one-threshold N` changes the default of 10 different values; `0` turns the report off.
- `--record` needs no database, takes `--format human` (default) or `--format json`, and cannot be combined with the comparison options.
- Do not put the wrapper in production code: it writes the SQL and the bind values to the output. SQL inside `withSession` and Durable Objects is not recorded.

## Compare a migration (--migration)

Use `--migration` when the change is a SQL file, especially when it drops or replaces an index or adds, renames, or drops a column or table.

```sh
npx qenome app.db --batch queries.json --migration 0002_replace_index.sql --format json
npx qenome --d1 DB --batch queries.json --migration 0002_replace_index.sql --format json
```

- It needs `--batch`, and the manifest must omit `candidates` (or use `[]`). Put only the queries in the manifest.
- `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (a column list, not `AS SELECT`), and `ALTER TABLE` (ADD / RENAME / DROP COLUMN and RENAME TO) are accepted, in any order and separated by semicolons. Any other statement is rejected with exit `1` and the statement number before the variant is touched. Do not put `INSERT`, `UPDATE`, `DELETE`, `DROP TABLE`, `ATTACH`, or `PRAGMA` in the file.
- The original database is never changed. Qenome applies the statements to the variant copy only.
- A query that uses a column or table the migration adds cannot run on the baseline. Qenome measures it on the variant only: its embedded comparison has `verdict` `not-judged`, `result` `incomparable`, `baseline` `null`, the variant plan and row counts, and the baseline reason in `verdict_reasons`. Its `summary.not_judged` count and the batch exit code are separate: this query does not change the exit code. Do not call it a failure; report the variant plan, the row counts, and the reason. In the human report its `Results` `result` column says `variant-only` with verdict `not-judged`, so it matches the `not-judged` summary count; the embedded JSON comparison keeps `result` `incomparable`.
- A query that the migration breaks stops the run. If it names a column or table the migration drops or renames, the variant cannot prepare it: exit `1`, empty stdout, error code `batch_variant_failed`, and the message names the query and the migration. Fix the manifest to use the post-migration names; do not revert the migration. A CI gate stops here.
- A `SELECT *` query cannot be compared after a migration that adds or drops a column, because the result has a different column count. Its comparison has `verdict` `not-judged`, `result` `incomparable`, `exit_code` `4`, and `result_reasons` with the column count, and `baseline` is present. The batch exits `4`. Write the columns explicitly in the manifest when the user wants the comparison.
- The report is the batch object plus a top-level `migration` object with `path` and `statements` (`kind` is `create_index`, `drop_index`, `create_table`, or `alter_table`, and `sql`). Human output has a `migration:` block and a `not-judged` summary column instead.
- `size_increase` counts the bytes in use, not the file size, so a `DROP INDEX` reports the freed bytes as a negative number. The file itself shrinks only after `VACUUM`.
- Exit `6` means the result rows matched, but at least one query read or wrote more rows after the migration. That query's verdict is `regressed` (the human `Results` column and `results[].comparison.verdict`); the JSON `summary` key stays `needs_check` and counts those queries. Do not keep the migration for a CI gate. Exit `3` (rows differ) and `4` (cannot compare) also stop the gate.

## Read the JSON

State `schema_version` before you interpret fields.

- If stdout is a JSON object with `record_schema_version` `1`, it is a `--record` report. Read `records`, `queries`, `skipped`, `warnings`, `repeated_shapes`, and `repeated_shapes_dropped`. Repeat the `warnings` codes `record_log_permissions` (the log is readable by other users) and `record_manifest_binds`. It is not a comparison and has no `verdict`; the exit code is `0` when the object is written. On a no-SELECT failure, the error `message` carries the `skipped:` breakdown.
- If stdout is a JSON object with `audit_schema_version` `1`, it is an index audit report. Read `redundancy_judged` first, then each `indexes` entry (`used`, `constraint`, `redundant_by`, `partial`, `expression`). It is not a comparison and has no `verdict`. Exit `0` can have unused and redundant entries; report them as candidates only.
- If stdout is a JSON object with `batch_schema_version`, it is a batch report. Read `batch_schema_version` first; it must be `1`. Read `recommended` (`null` when no candidate qualifies; with `--suggest` it can be `suggested:N`; with `--migration` it is the migration path or `null`), the `summary` entries (`candidate`, `source`, `index_sql_text`, `not_judged`; `source` can be `manifest`, `suggested`, or `migration`), the `results`, the optional top-level `migration` object (`path`, `statements`), and the top-level `warnings` (the `--suggest` entries, plus `unapplied_migrations` with `--d1`). Repeat every batch warning `code` and `message`, like the comparison warnings. Read each `results[].comparison.warnings` too: comparison warnings, including `bind_dependent_partial_index`, are there and not in the batch top-level `warnings`. A `human` batch report lists each comparison warning under `Warnings` as `<query> -> <candidate>: <code>: <message>`. The `comparison` object under each result has `schema_version` 2 and the shape below.
- A top-level `seed_data` object appears in a comparison or batch object when `--seed-data` was used. Read `path`, `seed`, `rows`, and `tables`. It is an input fact and does not change the verdict.
- If stdout is a JSON object, it is the comparison. Read `schema_version` first. If it is missing or not `2`, stop and say the output does not match this skill or `docs/json.md`. Do not guess renamed fields.
- If stdout is empty, stderr is the error object (skip any `progress:` lines). It also has `schema_version` 2, plus `exit_code` and `error` with `code`, `message`, and `hint`. Do what `hint` says. Do not treat the failure as a verdict.
- `exit_code` inside a comparison object is `0`, `3`, or `4`. The process can still exit `5` after writing that object. Trust the process exit code.

Emitted fields an agent should read:

| Field | Use |
| --- | --- |
| `verdict` | `improved`, `no-effect`, `needs-check`, `regressed` (a `--migration` result only), or `not-judged` (the rows differ or cannot be compared, or a `--migration` query could only run on the variant) |
| `statement` | `select` or `write` |
| `result` | `match`, `mismatch`, or `incomparable` |
| `verdict_reasons` | Why it is `needs-check`, `regressed`, or `not-judged` |
| `result_reasons` | Why the rows cannot be compared. Each item has `text` and `hint` |
| `baseline` | The current schema's measurement. It is `null` for a variant-only `--migration` query; use `variant` for that query's plan and row counts |
| `inputs.write` | With `--write`, the write-file path; `inputs.select` is absent |
| `baseline.counters.rows_read` | Rows the current schema read |
| `variant.counters.rows_read` | Rows the candidate index read |
| `baseline.counters.rows_written` and `variant.counters.rows_written` | Writes during the SELECT. An increase is `needs-check` (`regressed` in a `--migration` result) when the rows match. With `--write`, this is the write cost of the statement |
| `baseline.changes` / `variant.changes` | With `--write`: rows the statement itself changed, without triggers or foreign keys |
| `baseline.total_changes` / `variant.total_changes` | With `--write`: changes including triggers and foreign keys. Both `changes` and `total_changes` must match for `result` `match` |
| `baseline.executions` / `variant.executions` | With `--write`: rolled-back executions per copy |
| `plan_changed` | Whether the plan text changed |
| `timing` | `null` with `--runs 0`. When present, it is a reference. It does not pick the verdict |
| `environment.sqlite_version` | Bundled SQLite until `sqlite.bundled_version` exists |

Timing now includes measured A/A `noise_band`, nullable `confidence_interval`, paired `median_difference_ns`, `effect`, and `unavailable_reason`. An unavailable interval or no-difference is not a row verdict. Warnings are always an array; repeat their codes/messages. See README for assumptions, sample limits, and heuristic thresholds.

Warning codes in the comparison `warnings`: `no_analyze_stats` (no statistics on the candidate table), `data_too_small` (too little data to trust the counts), `bind_dependent_partial_index`, and `unapplied_migrations`. `unapplied_migrations` means the local D1 database has not applied every migration that the wrangler config names; the message lists the files and the command `npx wrangler d1 migrations apply <BINDING> --local`. Tell the user to apply them and run Qenome again, because this run tested an older schema; do not treat its verdict as final. In a batch the entry is in the top-level `warnings`, and with `--audit-indexes` in the audit `warnings`; it never changes the verdict or the exit code. `bind_dependent_partial_index` names a partial index that the variant plan uses only because the bound values satisfy its `WHERE` clause; SQLite no longer uses it when the values or the parameter style change, so an `improved` result holds only for these bound values. Tell the user that, and test the values they deploy with. The check is best-effort and never changes the verdict or the exit code. In a batch, a candidate with this warning comes after a candidate with the same `improved` count that has no warning, so `recommended` can name the candidate without it; the JSON `summary` order follows the same rule.

Still reserved; do not require or invent:

- `sqlite.bundled_version`
- `sqlite.db_header_version`

If `warnings` is absent, say the ANALYZE-stats check, the small-data check, and the bind-dependent partial index check are not in this binary yet. If `warnings` is present, repeat every `code` and `message` to the user. Warnings do not change the exit code. Do not keep a `needs-check` index or an exit `3` result because a warning might explain it. A `bind_dependent_partial_index` warning does not disqualify an `improved` index for the values that were tested; it says the plan is not value-independent.

`rows_read` and `rows_written` live under `counters` on each side. If a future build moves them, `schema_version` stays `2` and this skill's fixture marker must be updated. See the reconciliation list in `docs/json.md`.

## What to do with the result

Tell the user the process exit code, `schema_version`, `result`, `verdict`, and the two `rows_read` numbers. Then act:

| Process exit | Action |
| --- | --- |
| 0 and `verdict` `improved` | The candidate read fewer rows and the result rows match. It is a candidate to keep on this local copy. It is not a production measurement. With `bind_dependent_partial_index`, the improvement holds only for the bound values; say so and test other values. In a batch, an equal-improving candidate without the warning is recommended instead |
| 0 and `verdict` `no-effect` | Do not add the index for this query. The variant did not read fewer rows |
| 0 and `verdict` `needs-check` | Do not merge the index. Quote `verdict_reasons`. With `--write`, the reason is usually that the variant writes more rows |
| 3 | Do not merge. The result rows differ. Offer `--show-rows` only if the user wants the example values in the log |
| 4 and stdout is a comparison | Do not call it a match. Quote `result_reasons` and their hints. `verdict` is `not-judged`. With `--migration`, a `SELECT *` after a column was added or dropped lands here; list the columns and rerun. With `--write`, a write that reads the schema, calls `random()`, or reads the current time lands here; the write was not run |
| 4 and stdout is empty | The local D1 was not found. Follow `error.hint`. Do not edit the index to fix a missing database |
| 5 | The comparison matched and cleanup failed. stdout holds the report (`exit_code` 0). Tell the user to remove the directory named in the stderr error. Do not loop |
| 6 | `--migration` matched the rows but made a query read or write more rows. Do not keep the migration. Quote the `regressed` verdicts, the `needs_check` summary count, and the comparison reasons |
| 0 with `not-judged` | The query could only run on the variant. Report the variant plan, the row counts, and the `verdict_reasons`; do not treat it as a failure and do not change the exit code. Quote `summary.not_judged` |
| 1 | The input was rejected. Follow `error.hint` or the `error:` line. With `--migration`, `batch_variant_failed` may mean a manifest query uses a column or table the migration dropped or renamed: read the SQLite message and, if it does, fix the manifest rather than the migration |
| 2 | The command line is wrong. Follow the hint. Fix the invocation and rerun once |
| 124 | The time limit fired. Raise `--timeout-ms` or narrow the SELECT. Do not treat it as a slow index |
| 129, 130, 143 | The run was interrupted. Rerun once if the user still wants a verdict |

With `--batch`, exit `1`, `6`, or `124` can still have a report on stdout. If stdout is the batch object, the run finished: read `recommended`, the `summary` statuses, and the `failure` messages. If stdout is empty, the run stopped before the report and stderr holds the error object. Do not tell the user that a rejected candidate lost the other results; they are in `results`.

Do not apply `index.sql` to the user's database. Qenome already tried it on a copy.

## What not to claim

Say "same counting as local D1 (workerd patch)". The numbers have not yet been checked against production D1. Describe that local measurement only.

## Examples checked in CI

`scripts/check_skill_examples.py` runs every `sh` line tagged `# qenome-ci: run`. It builds `testdata/skill/app.db` from `testdata/skill/schema.sql` first. Lines tagged `# qenome-ci: pending` are skipped and printed as TODO. A pending line must contain `TODO`.

Create the fixture yourself with the same SQL if you run the file commands outside CI. `testdata/skill/app.db` is gitignored.

```sh
npx qenome testdata/skill/app.db testdata/skill/select.sql testdata/skill/index.sql --bind 1:int:1 --runs 0 --format json  # qenome-ci: run exit=0 stdout=report verdict=improved result=match fields=schema_version,exit_code,verdict,result,baseline.counters.rows_read,baseline.counters.rows_written,variant.counters.rows_read,variant.counters.rows_written,timing
```

```sh
npx qenome --d1 MISSING testdata/skill/select.sql testdata/skill/index.sql --format json  # qenome-ci: run exit=4 stdout=empty error=d1_config_not_found
```

```sh
npx qenome --d1 DB select.sql index.sql --runs 0 --format json  # qenome-ci: pending TODO(d1-fixture): needs the project's local D1. The testdata/skill command above checks the same comparison fields.
```

```sh
npx qenome testdata/skill/app.db testdata/skill/select.sql testdata/skill/index.sql --bind 1:int:1 --runs 6 --format json  # qenome-ci: run exit=0 stdout=report verdict=improved result=match fields=schema_version,exit_code,verdict,warnings,timing.noise_band,timing.confidence_interval,timing.median_difference_ns,timing.effect,timing.unavailable_reason
```

```sh
npx qenome testdata/skill/app.db --batch testdata/skill/batch.json --format json  # qenome-ci: run exit=0 stdout=report fields=batch_schema_version,recommended,summary
```

```sh
npx qenome testdata/skill/app.db testdata/skill/select.sql --bind 1:int:1 --suggest --format json  # qenome-ci: run exit=0 stdout=report fields=batch_schema_version,recommended,summary,warnings
```
