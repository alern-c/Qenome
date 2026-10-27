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

Qenome compares one read-only `SELECT` with one candidate `CREATE INDEX` on sandbox copies. The verdict uses the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

The contract is [docs/json.md](../../docs/json.md). This skill expects `schema_version` 2.

## When to run

Run Qenome before keeping a `CREATE INDEX` on a local D1 or a SQLite file. Run it when the user asks whether an index helps, whether a query got faster, or whether a schema change is safe to merge.

Do not run it to change production, to apply SQL, or to estimate a bill. One comparison is one SELECT file and one CREATE INDEX file.

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

4. Put the query in `select.sql` (one read-only `SELECT`) and the candidate in `index.sql` (one `CREATE INDEX`).
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

## Read the JSON

State `schema_version` before you interpret fields.

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
| 1 | The input was rejected. Follow `error.hint` or the `error:` line |
| 2 | The command line is wrong. Follow the hint. Fix the invocation and rerun once |
| 124 | The time limit fired. Raise `--timeout-ms` or narrow the SELECT. Do not treat it as a slow index |
| 129, 130, 143 | The run was interrupted. Rerun once if the user still wants a verdict |

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
