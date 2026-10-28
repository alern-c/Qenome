---
name: qenome
description: >
  Decide whether a CREATE INDEX helps a local Cloudflare D1 or SQLite SELECT
  before merging. Use when the user has a wrangler d1_databases binding, asks
  if an index helps, or wants a qenome verdict, exit code, JSON report, or
  warning. Reads schema_version 2. Does not apply the index to the original
  database.
---

# Qenome

Qenome compares one read-only `SELECT` with one candidate `CREATE INDEX` on sandbox copies. With `--batch`, it compares every SELECT in a manifest with every candidate in one run. With `--suggest`, SQLite's expert proposes the candidate indexes, so a SELECT file is enough. With `--migration`, it applies a SQL file of index changes to the variant before comparing every query in a manifest. The verdict uses the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

The contract is [docs/json.md](../../docs/json.md). This skill expects `schema_version` 2.

## When to run

Run Qenome before keeping a `CREATE INDEX` on a local D1 or a SQLite file. Run it when the user asks whether an index helps, whether a query got faster, or whether a schema change is safe to merge.

Do not run it to change production, to apply SQL, or to estimate a bill. One comparison is one SELECT file and one CREATE INDEX file; `--batch` takes a manifest of them. `--suggest` lets SQLite propose the candidate from the SELECT file alone.

## Install and invoke

On a D1 project:

```sh
npx qenome --version
```

The npm package is added separately. If `npx qenome` does not resolve, build this repository with `zig build` and call `zig-out/bin/qenome`. The commands below use `npx qenome`. A checkout that has already been built can substitute that binary. The CI job does that substitution.

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

- Paths are relative to the manifest, not the current directory.
- `queries` and `candidates` take 1 to 100 entries each. A path cannot repeat inside one list.
- `binds` uses the same `N:TYPE:VALUE` syntax as `--bind`.
- `--batch` does not take `--select`, `--index-sql`, `--bind`, `--runs`, or `--format kv`.
- A candidate that fails is recorded and the batch continues. A failure that affects the whole run stops with empty stdout.

```sh
npx qenome app.db --batch batch.json --format json
npx qenome --d1 DB --batch batch.json --format json
```

## Compare a migration (--migration)

Use `--migration` when the change is a SQL file, especially when it drops an index or replaces one index with another.

```sh
npx qenome app.db --batch queries.json --migration 0002_replace_index.sql --format json
npx qenome --d1 DB --batch queries.json --migration 0002_replace_index.sql --format json
```

- It needs `--batch`, and the manifest must omit `candidates` (or use `[]`). Put only the queries in the manifest.
- Only `CREATE INDEX`, `CREATE UNIQUE INDEX`, and `DROP INDEX` are accepted, in any order and separated by semicolons. Any other statement is rejected with exit `1` before the variant is touched. Do not put `INSERT`, `UPDATE`, `DELETE`, `ALTER TABLE`, or `CREATE TABLE` in the file.
- The original database is never changed. Qenome applies the statements to the variant copy only.
- The report is the batch object plus a top-level `migration` object with `path` and `statements` (`kind` and `sql`). Human output has a `migration:` block instead.
- Exit `6` means the result rows matched, but at least one query read or wrote more rows after the migration. Do not keep the migration for a CI gate. Exit `3` (rows differ) and `4` (cannot compare) also stop the gate.

## Read the JSON

State `schema_version` before you interpret fields.

- If stdout is a JSON object with `batch_schema_version`, it is a batch report. Read `batch_schema_version` first; it must be `1`. Read `recommended` (`null` when no candidate qualifies; with `--suggest` it can be `suggested:N`; with `--migration` it is the migration path or `null`), the `summary` entries (`candidate`, `source`, `index_sql_text`; `source` can be `manifest`, `suggested`, or `migration`), the `results`, the optional top-level `migration` object (`path`, `statements`), and the top-level `warnings` (empty without `--suggest` and with `--migration`). Repeat every batch warning `code` and `message`, like the comparison warnings. The `comparison` object under each result has `schema_version` 2 and the shape below.
- If stdout is a JSON object, it is the comparison. Read `schema_version` first. If it is missing or not `2`, stop and say the output does not match this skill or `docs/json.md`. Do not guess renamed fields.
- If stdout is empty, stderr is the error object (skip any `progress:` lines). It also has `schema_version` 2, plus `exit_code` and `error` with `code`, `message`, and `hint`. Do what `hint` says. Do not treat the failure as a verdict.
- `exit_code` inside a comparison object is `0`, `3`, or `4`. The process can still exit `5` after writing that object. Trust the process exit code.

Emitted fields an agent should read:

| Field | Use |
| --- | --- |
| `verdict` | `improved`, `no-effect`, `needs-check`, or `not-judged` |
| `result` | `match`, `mismatch`, or `incomparable` |
| `verdict_reasons` | Why it is `needs-check` or `not-judged` |
| `result_reasons` | Why the rows cannot be compared. Each item has `text` and `hint` |
| `baseline.counters.rows_read` | Rows the current schema read |
| `variant.counters.rows_read` | Rows the candidate index read |
| `baseline.counters.rows_written` and `variant.counters.rows_written` | Writes during the SELECT. An increase is `needs-check` when the rows match |
| `plan_changed` | Whether the plan text changed |
| `timing` | `null` with `--runs 0`. When present, it is a reference. It does not pick the verdict |
| `environment.sqlite_version` | Bundled SQLite until `sqlite.bundled_version` exists |

Timing now includes measured A/A `noise_band`, nullable `confidence_interval`, paired `median_difference_ns`, `effect`, and `unavailable_reason`. An unavailable interval or no-difference is not a row verdict. Warnings are always an array; repeat their codes/messages. See README for assumptions, sample limits, and heuristic thresholds.

Still reserved; do not require or invent:

- `sqlite.bundled_version`
- `sqlite.db_header_version`

If `warnings` is absent, say the ANALYZE-stats check and the small-data check are not in this binary yet. If `warnings` is present, repeat every `code` and `message` to the user. Warnings do not change the exit code. Do not keep a `needs-check` index or an exit `3` result because a warning might explain it.

`rows_read` and `rows_written` live under `counters` on each side. If a future build moves them, `schema_version` stays `2` and this skill's fixture marker must be updated. See the reconciliation list in `docs/json.md`.

## What to do with the result

Tell the user the process exit code, `schema_version`, `result`, `verdict`, and the two `rows_read` numbers. Then act:

| Process exit | Action |
| --- | --- |
| 0 and `verdict` `improved` | The candidate read fewer rows and the result rows match. It is a candidate to keep on this local copy. It is not a production measurement |
| 0 and `verdict` `no-effect` | Do not add the index for this query. The variant did not read fewer rows |
| 0 and `verdict` `needs-check` | Do not merge the index. Quote `verdict_reasons` |
| 3 | Do not merge. The result rows differ. Offer `--show-rows` only if the user wants the example values in the log |
| 4 and stdout is a comparison | Do not call it a match. Quote `result_reasons` and their hints. `verdict` is `not-judged` |
| 4 and stdout is empty | The local D1 was not found. Follow `error.hint`. Do not edit the index to fix a missing database |
| 5 | The comparison matched and cleanup failed. stdout holds the report (`exit_code` 0). Tell the user to remove the directory named in the stderr error. Do not loop |
| 6 | `--migration` matched the rows but made a query read or write more rows. Do not keep the migration. Quote the `needs_check` summary and the comparison reasons |
| 1 | The input was rejected. Follow `error.hint` or the `error:` line |
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
