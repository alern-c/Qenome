# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.8] - 2026-10-31

### Added

- `--record` also reports the statement shapes that ran many times with only different values, which is a possible N+1: a `repeated shapes:` block after the per-query lines gives each shape's executions, different values and longest run, or `repeated shapes: none` when nothing passed the threshold. A shape ignores the values and not the statement, so `= ?`, `= ?1`, `= :id`, `= 17` and `= 'a'` are one shape and `IN (?, ?)` and `IN (?, ?, ?)` are one shape; a write loop is reported with a write hint, and a record from `db.batch()` never reaches the threshold because it is already one round trip. A shape is reported when at least 10 different values ran with it, `--n-plus-one-threshold N` changes that (`0` turns the report off, otherwise 2 to 1,000,000), at most 20 shapes are listed with a count of those dropped, and neither form prints a bind value. `--record` now takes `--format json`, which writes the same facts as one object with `record_schema_version` 1 in a new schema, and the error for more than 100 distinct statements also names the most repeated shape.
- `testdata/accuracy/` holds the known-answer accuracy corpus: 46 cases covering the single comparison, `--write`, `--suggest`, `--batch` and `--migration`, each with its fixtures in the case directory and the answer it must produce. `scripts/check_accuracy.py` builds a fresh database for every case, runs the built binary, repeats each case three times in `python3 scripts/check_all.py`, and fails when the exit status, the result, the verdict, a plan step or a counter differs between the runs. The corpus covers the answers that are not `improved` as well: an index the query never uses, a covering index that changes only the plan text, a `sqlite_stat1` row that makes the planner read 10,000 rows instead of 11, one index entry written per inserted or updated row, a one-row gain out of 50,000 rows recorded as today's answer, and one query and index that answers `improved` for a bind that matches one row and `no-effect` for a bind that matches every row. A case can check the timing label with `effect` and the human report with `human`, and `testdata/README.md` documents the layout, the keys and the marker for a case that records a known-wrong answer.
- `--scale ROWS,ROWS[,ROWS]` with `--seed-data` runs the same comparison at 2 or 3 data sizes in one run and shows the rows read on both copies, the ratio, the rows written with `--write`, the verdict, the result and whether the plan changed side by side, one row per step, in the human output and as a new `scale_schema_version` 1 object in JSON. Each step seeds a fresh sandbox copy at that size, the steps must be strictly increasing, and a bad size or a conflicting mode is `usage_scale` with exit status `2` before a copy is made. `--scale` works with `--d1`, `--write`, `--bind`, `--runs`, `--timeout-ms`, `--show-binds`, and `--show-rows`, and does not take `--batch`, `--suggest`, `--migration`, `--audit-indexes`, `--record`, or `--format kv`.

### Changed

- The output page (`docs/output.md` and `docs/ja/output.md`) names the `time noise` line of the human Summary: the empirical A/A p95 and the number of pairs, shown only when timed, for reference only, and never changing the verdict or the exit code.
- `README.md` and `README.ja.md` are an index of paired pages under `docs/` and `docs/ja/`: the installation, D1, agent, usage, batch, output and rules details moved to those pages with their text unchanged, and the README keeps the introduction, the first example, the features and the contents list. `AGENTS.md` is an index of one-line rules, with the check stages in `CONTRIBUTING.md` and the architecture table in `docs/architecture.md`, and link targets elsewhere in the repository follow the moved pages. `scripts/check_docs.py` keeps that shape: it holds the page list, caps the line counts of the README and `AGENTS.md`, compares the heading levels of each page pair, and checks relative links, anchors and images, and `python3 scripts/check_all.py` runs it with its self-test.
- `README.md` and `README.ja.md` have a short install section: the npm install for Linux and macOS, `npx qenome` without installing, and the Windows prebuilt binaries, with the installation page kept as the detail link.
- `docs/accuracy.md` and `docs/ja/accuracy.md` explain how the rows read and written are counted, what each verdict and warning means, what can differ from production D1, and how to check a result against production yourself; the READMEs, the output page and the bundled skill link to them. The page keeps to the same counting as local D1 (workerd patch) and says that the numbers have not been checked against production D1.

### Fixed

- `--record --format json` writes the warnings that the human report shows: the record object now has a `warnings` array with `record_manifest_binds` for the manifest's bind values and, when the log is readable by other users, `record_log_permissions` with the log path. On the no-SELECT error path the JSON error message carries the same `skipped:` breakdown that the human report writes on the next line, so a JSON reader no longer loses the counts. `record_schema_version` stays `1`, and the human output is unchanged.
- An invalid `--n-plus-one-threshold` value is reported as `usage_n_plus_one_threshold` with a hint that gives the valid range (0, or 2 to 1,000,000) instead of `usage_record_conflict`; using the flag without `--record` still reports `usage_record_conflict`.

## [0.3.7] - 2026-10-31

### Added

- `--d1` warns `unapplied_migrations` when the local D1 database has not applied every migration of the wrangler config. Qenome reads `migrations_dir` (default `migrations`, beside the config file) and `migrations_table` (default `d1_migrations`) from the `d1_databases` entry, lists the `.sql` files directly in that directory, and compares them with the `name` values of the record table; the files the table does not name are listed in wrangler's order (a leading number, then lexical order, unnumbered last), and the message gives `npx wrangler d1 migrations apply <BINDING> --local`. A comparison against an older schema can hide the effect of the index and report `no-effect` or `improved` for the wrong schema, so the warning appears in every `--d1` mode, including `--write`, `--batch`, `--suggest`, and `--batch --audit-indexes`; the comparison and the audit report put it in `warnings`, and a batch in its top-level `warnings`. It never changes the verdict, a batch count, or the exit status. It is omitted when the record table or the migrations directory does not exist, when the directory holds no `.sql` file, when the local database cannot be read, when the table or the directory is too large for the bounded read (more than 10,000 rows or entries, a name over 4,096 bytes, or an exhausted instruction budget), and when every file is applied; a `migrations_pattern` and the bindings under `[env.<name>]` are not read. Qenome opens the local database read-only and reads only the names, so the original database is not changed. The message names at most 10 files and then how many are left. The JSON contract keeps `schema_version` 2, `batch_schema_version` 1, and `audit_schema_version` 1; the audit report gains the `warnings` key.
- `qenome skill print | install | uninstall | status` shows and installs the bundled Agent Skill. `install` copies `skills/qenome/SKILL.md` into each detected agent's skills directory (Claude Code `~/.claude/skills/qenome/` and the cross-agent location that Codex, Cursor, and Gemini CLI read, `~/.agents/skills/qenome/`), takes `--project` for the current directory, `--target claude|agents|all`, `--dry-run`, and `--yes`, and shows a unified diff before overwriting a modified copy. `status` reports `not installed`, `up to date`, or a copy that differs from the binary's copy, and `uninstall` removes only a regular copy that still matches the binary and keeps a modified copy or a copy reached through a symbolic link. The skill is embedded in the binary, so `print` writes the same bytes as the repository file, the npm launcher package ships `skills/`, and `--help` points AI agents to `qenome skill print` / `qenome skill install`.
- Eight golden files in `testdata/golden/` pin the human and JSON output of the single comparison, `--write`, `--batch`, and `--suggest`. `scripts/check_golden.py` compares the binary's output with them, `python3 scripts/check_golden.py --update` regenerates them, and `python3 scripts/check_all.py` runs the checker and its self-test on every commit.

### Changed

- `README.md` and `README.ja.md` open with the problem, one `npx qenome --d1 DEMO_DB select.sql --suggest` command, and the sample result (200,000 to 101 rows read). The build-from-source Quick start, the development checks, and the golden update move to `CONTRIBUTING.md`; both READMEs link to it.
- The npm launcher and the four platform packages carry search keywords.

### Fixed

- A SELECT that writes a numbered parameter directly before `LIMIT`, such as `?1LIMIT 2`, now counts as having LIMIT or OFFSET. SQLite ends the parameter at the digits and reads the characters after them as `LIMIT`, so it applies the limit, while Qenome read `1LIMIT` as one word and found no LIMIT or OFFSET: when the rows differed, the reason "the rows differ, and the SELECT has LIMIT or OFFSET, which can pick other rows when the order changes" was missing, and the run reported `MISMATCH` with exit `3` (the `mismatch` column and exit `3` in `--batch`) instead of `INCOMPARABLE` with exit `4` and that reason in the Result rows section. `:1limit`, `@1limit`, and `$1limit` stay one parameter each and are still not read as a LIMIT, because SQLite reads them that way; strings, comments, and quoted identifiers are skipped as before.
- The `Warnings` section of the `--batch` and `--suggest` human reports lists `no_analyze_stats` and `data_too_small` once per candidate, instead of keeping them in the machine-readable output only, and a timed single comparison adds a `time noise` line with the A/A p95 to its Summary; the bind-dependent partial index warning keeps its query and candidate form, and JSON, `kv`, the verdicts, and the exit status are unchanged.

## [0.3.6] - 2026-10-29

### Added

- `--write <FILE>` compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` with the candidate index in place of the `SELECT`. A leading `WITH` and a trailing `RETURNING` are allowed, and `CREATE`, `DROP`, `ALTER`, `PRAGMA`, `ATTACH`, `VACUUM`, and multiple statements are rejected with exit `1`. The statement runs inside a transaction on each sandbox copy and is rolled back, so the original database is never changed and every round starts from the same rows; `--runs` is the number of rolled-back executions per copy (at least one) and there is no timing. Both copies must make the same change: the multiset of `RETURNING` rows, `changes`, and the difference of `total_changes` (which also counts trigger and foreign-key changes) are compared, and a difference is a mismatch with exit `3` that is not judged from the row counts. A write that reads the schema, the current time, or a nondeterministic function is not run and is `incomparable` with exit `4`. The rows written include the table row and each secondary-index insert, trigger insert, and foreign-key cascade, but the bundled D1 counting patch does not count secondary-index deletes, so a `DELETE ... WHERE` can show fewer rows read with the same rows written. `--write` works with `--d1`, `--seed-data`, `--bind`, `--timeout-ms`, `--show-binds`, `--show-rows`, and every format, and is rejected with a usage error together with `--batch`, `--migration`, or `--suggest`.
- `qenome/d1` records the SELECTs and bind values that an app runs against a local D1, and `qenome --record <FILE> --out <DIR>` turns that log into a batch manifest with no candidates. `wrapD1(env.DB)` proxies `prepare`, `bind`, `all`, `run`, `first`, `raw`, `batch`, and `exec` without changing the return value, `this`, or the exception, and writes a record only after a successful call, so a recording failure does not break the query; it prints a one-time notice that it is for local development and tests only. `--record` keeps the binds of the first execution and prints how many times each statement ran, so SQL that differs only in whitespace outside strings and comments becomes one entry, while `INSERT`, `UPDATE`, `DELETE`, `REPLACE`, `exec`, and a statement that binds a BLOB, a boolean, or text with a NUL are counted and skipped. It writes `manifest.json` and `queries/qNNN.sql` into a new directory with mode `0700` and files with `0600`, refuses an existing `--out`, and needs no database; a log over 16 MiB, a SQL statement over 1 MiB, a manifest over 1 MiB, or more than 100 distinct SELECTs stops the run before the directory is created. The manifest holds the bind values, so keep it local and do not commit it, do not ship the wrapper to production, and delete the log once the manifest exists; the SQL inside `withSession` and Durable Objects is not recorded, and only `--format human` is accepted.
- `--batch <manifest> --audit-indexes` reports the existing indexes that the manifest SELECTs did not use, the plain indexes whose key columns another index or the primary key already covers, and the UNIQUE and PRIMARY KEY indexes that stay for their constraint. It reads `PRAGMA index_list`, `index_xinfo`, and `table_info`, takes `EXPLAIN QUERY PLAN` of every manifest query on one read-only copy, and builds no variant, so the database is not changed; the manifest needs only `queries`, so a manifest from `--record` works as it is, and `candidates` are ignored. A partial index is never judged redundant, an expression index is not compared, a different collation or ASC/DESC order is not treated as covered, and a manifest that uses `INDEXED BY` gets no redundancy list at all. The report is a statement about this manifest and not a recommendation to drop an index: an index used by `UPDATE`, `DELETE`, foreign-key maintenance, or a query outside the manifest is not visible. The run exits `0` when the report is written, even when the lists are not empty. `--audit-indexes` needs `--batch`, takes `--d1`, `--timeout-ms` (for each plan and each catalog read), and `--format human` or `json`, and is rejected with `--suggest`, `--migration`, or `--seed-data`; the JSON output is the `audit_schema_version` 1 object.

### Changed

- `README.md` and `README.ja.md` show three recordings instead of one: `--suggest` at the top, and a candidate comparison and a `--migration` regression in the `--batch` section. They are recorded from `docs/demo-suggest.tape`, `docs/demo-candidates.tape`, and `docs/demo-migration.tape`, which take their extra inputs from `docs/demo`; `docs/demo.tape` and `docs/demo.gif` are gone.

### Fixed

- The batch `human` output lists each bind-dependent partial index warning after the results table in a `Warnings` section, as `<query> -> <candidate>: <code>: <message>`, with the paths and the index name escaped like the other warnings, instead of keeping the warning in the machine-readable output only. When candidates have the same number of improved queries, the recommendation and the JSON `summary` order prefer a candidate without that warning, then the smaller size increase, then manifest order, so a bind-dependent partial index no longer wins on size alone; a different improvement count still decides first, and a batch without warnings keeps its output, order, recommendation, and exit status.
- A batch `human` report shortens an absolute candidate or query path to the shortest suffix that keeps it distinct from the other paths in the same list, so two candidates named `x.sql` in different directories read `a/x.sql` and `b/x.sql` instead of the full paths; relative paths, the `migration:` line, and the machine-readable output keep the full path. A query that a `--migration` run measured on the variant only now shows `variant-only` in the `result` column of the `Results` table instead of `incomparable`, so the rows agree with the `not-judged` count in the Summary; its `verdict` stays `not-judged`, a comparison that really cannot be compared stays `incomparable`, and the embedded JSON keeps `result` `incomparable` with `baseline` `null`.

## [0.3.5] - 2026-10-28

### Added

- `--migration <FILE>` also accepts `CREATE TABLE` and `ALTER TABLE` next to the index changes, so one file can add a column and index it, rename or drop a column, or rename a table. `CREATE TABLE` takes a column list and not `AS SELECT`, and `ALTER TABLE` takes ADD COLUMN, RENAME COLUMN, DROP COLUMN, or RENAME TO; data changes, `DROP TABLE`, `ATTACH`, `PRAGMA`, and every other statement are still rejected with the statement number and exit `1`. The statements run in file order on the variant only, and the original database is never changed.
- A query that uses a column or table that the migration adds cannot run on the baseline, so Qenome measures it on the variant only and reports its plan and rows read with verdict `not-judged`; the human Summary adds a `not-judged` column and a `Not judged` list, and JSON writes the comparison with `baseline: null` and counts it under `summary.not_judged`. It does not change the batch exit status. A query that the migration breaks stops the run: a column or table that the migration drops or renames cannot be prepared on the variant, so the batch exits `1` before the report, with an `error:` line that names the query and the migration file (JSON: `batch_variant_failed`). Adding or dropping a column also changes the column count of a `SELECT *`, so that query is `incomparable` and the batch exits `4`.
- The comparison warns `bind_dependent_partial_index` when the variant plan uses a partial index only because the bound values satisfy its `WHERE` clause. Qenome reads the variant plan with the bound values and again with every parameter bound to `NULL`, and names the partial index that appears in the first plan and not the second, because another value or parameter style can drop it, so an `improved` result holds only for that run. The warning sits with the other warnings in human and `kv`, in the JSON `warnings` array, and in a batch in `results[].comparison.warnings`, while the batch top-level `warnings` keeps the `--suggest` entries. The check is best-effort and never changes the verdict, a batch count, or the exit status.

### Changed

- `README.md` and `README.ja.md` lead with `npm install -g qenome` for the npm install, so the command is on `PATH` for every project, and keep `npx qenome` for a run without installing; `skills/qenome/SKILL.md` no longer says the npm package is added separately, because `qenome` is published on npm.

### Fixed

- Nine tables in `README.md`, `README.ja.md`, and `docs/json.md` had no separator row under the header, so GitHub showed them as one line of pipe-separated text. Each now has the row and renders as a table, with the same words, columns, and rows.

## [0.3.4] - 2026-10-28

### Added

- `--migration <FILE>` applies a file of index changes to the variant copy before the `--batch` queries run, so one run compares the queries before and after a migration. It needs `--batch` with a manifest that has no candidates and does not take `--select`, `--index-sql`, `--bind`, `--runs`, `--suggest`, or `--format kv`. The file is at most 1 MiB and may hold `CREATE INDEX`, `CREATE UNIQUE INDEX`, and `DROP INDEX` statements, which run in file order on the variant only; the original database is never changed. The report adds a `migration:` block (human) or a top-level `migration` object (JSON) with the path and every applied statement.
- `--seed-data <FILE>` replaces the tables listed in a JSON spec with deterministic dummy rows in the sandbox copy before the comparison, so an empty or small database can still show what an index would read. Each column takes a `fixed`, `uniform`, `ratio`, or `sequence` distribution, and the same spec and `seed` give the same rows on every run. The original database stays unchanged, and the option works with every mode, including `--batch`, `--suggest`, and `--migration`. The run rejects listed tables with triggers and limits the spec to 100 tables, 10,000,000 rows per table, and 20,000,000 rows in total. The human Summary adds `seed data` and `seed` lines, `kv` adds the seed values, and `json` adds a `seed_data` object.

### Changed

- A batch measures each query's baseline once and reuses the rows for every candidate (up to 64 MiB), so it no longer repeats the baseline SELECT and prepare for every candidate. It still copies the database and runs the index build and the queries for each candidate, and a query that does not fit is measured per candidate as before; the report is unchanged.
- With `--migration`, the size increase is the change in the bytes in use, `(page_count - freelist_count) * page_size`, not the change of the file size. A `DROP INDEX` moves its pages to SQLite's freelist without shrinking the file, so it reports the freed space as a negative value; runs without `--migration` keep the file size difference.
- In a `--migration` batch, a query whose result rows match but that reads or writes more rows is `regressed` in the human Results column and in `results[].comparison.verdict`. The batch counts it under `needs_check`, recommends no such migration, and exits with status `6`; the other modes keep the name `needs-check`.
- The four npm binary packages moved from the `@qenome` scope to `@qenome-cli/<platform>-<arch>`, because the npm org `qenome` could not be created. Nothing has been published to npm yet, so the launcher stays `qenome` and the command stays `npx qenome`.

### Fixed

- The human Summary reports the direction from the paired rounds, and the size of the change only when the medians agree, instead of a ratio that can point the other way. The timing evidence (`effect`, median difference, noise band, and confidence interval) stays in `kv` and `json`, and advisory warnings move to their own `Warnings` section.

## [0.3.3] - 2026-10-28

### Added

- Timing includes measured baseline A/A noise, a nominal 95% paired median-difference sign interval with conservative binomial coverage, and explicit unavailable reasons. Timing evidence never changes the row verdict.
- Advisory target-table warnings report missing ANALYZE statistics and fewer than 1000 rows in human, kv, and JSON, without changing verdicts or exit codes.

- The output reports the rows each copy read and wrote: `rows read` and `rows written` in the human summary and table, `rows-read` and `rows-written` in `kv`, and `counters.rows_read` and `counters.rows_written` in `json`. They use the counts of a local D1: the vendored SQLite is built with Cloudflare's row-count patch from `workerd`, which is kept unmodified in `vendor/sqlite3/patches` together with the script that applies it. `NOTICE` records where the patch and SQLite come from and which licenses they keep.
- Regression tests fix the counts: a full scan of 100,000 rows becomes 201 reads through the candidate index, an `INSERT` of 1,000 rows counts 1,000 writes and 2,000 with one secondary index, and a comparison leaves the source database and its `-wal` file byte for byte unchanged.
- `docs/logo.svg` is the project logo: a two-twist DNA double helix, with one amber base pair marking a single change, hand-written with no external font or image. It is excluded from the comment check as an image asset.
- `--batch <FILE>` compares every SELECT in a JSON manifest with every candidate `CREATE INDEX` in one run. The manifest holds 1 to 100 queries, each with an optional `binds` list, and 1 to 100 candidates, or none when `--suggest` adds them; their paths resolve from the manifest's directory, not from the current directory. Qenome copies the database once, checks every SELECT and every candidate before it runs anything, then visits the candidates in manifest order and prints one row per pair, a `Recommendation:` line, and the candidate and query verdicts. With `--format json` the report is the separate `batch_schema_version` 1 object specified in `docs/json.md`. `--batch` cannot be combined with `--select`, `--index-sql`, `--bind`, positional SELECT or INDEX paths, `--runs`, or `--format kv`.
- The recommendation is the candidate with the most improved queries among those with no mismatch, no incomparable result, no `needs-check`, no timeout, and at least one improvement; ties go to the smaller size increase, then to manifest order. A candidate that cannot be built (`index_rejected`) or a variant SELECT that reaches `--timeout-ms` is recorded and the batch continues, so a report can be written with exit `1` or `124`. The exit status is the heaviest of a result mismatch (`3`), a rejected index (`1`), a candidate time limit (`124`), an incomparable result (`4`), and `0`.
- `--suggest` has SQLite's expert (sqlite3expert, built from the vendored SQLite source) propose candidate indexes instead of naming one, and compares the proposals with the same batch machinery, so a SELECT file is enough. With one SELECT file the SELECT becomes one batch query and `--bind` applies to it; with `--batch` the proposals join the manifest candidates. Proposals are labelled `suggested:1`, `suggested:2`, …; at most 20 are compared, and at most 100 with the manifest entries. `--suggest` does not take `--runs`, `--format kv`, or an index file.
- Before the expert runs, every `sqlite_schema` row is checked: each must be one statement that starts with `CREATE TABLE`, `CREATE INDEX`, `CREATE UNIQUE INDEX`, `CREATE VIEW`, `CREATE TRIGGER`, or `CREATE VIRTUAL TABLE`, and none may use the `expert` virtual table. A database that fails this check is rejected with `suggest_schema_rejected` and exit `1`, even when the manifest has candidates. While the expert runs, `ATTACH` and `DETACH` are denied, only the `index_list` and `index_xinfo` PRAGMAs are allowed, and the attached-database limit is `0`, so a crafted schema cannot create or change another database file. A proposal that fails the `CREATE INDEX` check is dropped with a `suggestion_rejected` warning, and the report lists `suggest_query_skipped`, `suggestion_rejected`, `suggestions_truncated`, `no_suggestions`, and `suggest_failed` in a top-level `warnings` array; a run with nothing to compare stops with `no_candidates` and exit `1`. The human output escapes control characters in the proposal SQL text, the warnings, and the schema error. The batch report keeps `batch_schema_version` `1`, and `source` and `index_sql_text` are additions.
- The npm package `qenome` runs the release binary for Linux and macOS, x64 and arm64: it is a small launcher plus one optional binary for the machine you are on (`@qenome/linux-x64`, `@qenome/linux-arm64`, `@qenome/darwin-x64`, or `@qenome/darwin-arm64`), so `npx qenome` and `npm install --global qenome` install only that binary. The version is `.version` in `build.zig.zon`; `npm/*/package.json` keeps `version` `0.0.0` and `private` `true`, and `scripts/stage_npm.py` writes the version into the published tree. Windows stays on the prebuilt binaries.
- `docs/json.md` is the specification of the JSON output: the comparison object with `schema_version` 2, the `--batch` report with `batch_schema_version` 1, and the error object, with the matching JSON Schemas in `docs/qenome-report.schema.json`, `docs/qenome-batch.schema.json`, and `docs/qenome-error.schema.json`.
- `skills/qenome/SKILL.md` gives an AI agent the instructions to run Qenome before it keeps a `CREATE INDEX`: when to run, how to pass `--d1` and `--config`, how to read a `schema_version` 2 comparison and a batch report, and what to do with exit codes and warnings. `scripts/check_skill_examples.py` runs the commands it marks with `# qenome-ci:` in the quality workflow.
- The Quick start adds an example for `--batch` with `testdata/batch.json` and one for `--suggest`, so it now runs five examples. Each command ends with the result it has to report, and `scripts/check_quick_start.py` checks a `recommended=` marker as well as `result=`, `verdict=`, and `exit=`.

### Changed

- The verdict now follows the rows read instead of the time: `improved` when the rows match and the variant reads fewer rows, `no-effect` when it reads the same number, `needs-check` when it reads or writes more (with the reasons), and `not-judged` when the rows differ or cannot be compared. The times stay in the output as a reference and no longer change the verdict, so `--runs 0` keeps the verdict and only skips the timing.
- `--format json` reports `schema_version` 2: `verdict` means the rows read now, and `counters` has `rows_read` and `rows_written`. The human summary prints `verdict` where it printed `time verdict`, and `kv` prints `verdict` and `verdict-reason` instead of `time-verdict` and `time-verdict-reason`.
- The bundled SQLite amalgamation is now 3.53.4, the same version D1's local engine runs, so `--db` and `--d1` compare on the same SQLite version. The README, the usage message, and `vendor/sqlite3/PROVENANCE.txt` name the new version.
- `README.md` and `README.ja.md` open with a centered header (logo, tagline, npm, license, and CI badges, language switch, and demo GIF), followed by a short feature list and a contents list. The checksum commands, the JSON main keys and string escaping, and the timing evidence fold into `<details>` without changing their text. Existing headings and the Quick start commands are unchanged.

### Fixed

- `--format json` reports a `--bind` number given more than once as `bind_rejected` instead of `usage_duplicate`, so the error code names the input that has to change; the exit status stays `1`.

## [0.3.2] - 2026-10-26

### Added

- `--d1 <BINDING>` compares the local database of a D1 binding from `wrangler.toml`, `wrangler.jsonc`, or `wrangler.json` instead of a `--db` path. It finds `<config directory>/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/<id>.sqlite` from `preview_database_id` or `database_id`, the file that local wrangler commands write. `--config <PATH>` names the config; otherwise it is searched in the current directory. The rule was checked against local databases written by wrangler 3.114.17 and 4.152.0.
- `--d1` stops with status 4 before comparing when it cannot choose exactly one database: no config, more than one config, an unknown or duplicated binding, a binding without an id, or a local file that does not exist yet. Nothing is written to stdout, and the reason is on stderr.
- Every `--d1` comparison reports that the bundled SQLite is 3.51.2 while D1's local engine is 3.53.4, and that the times come from the local copy rather than production D1. `--format json` adds a `d1` object; `schema_version` stays 1. `--db` output is unchanged.
- `README.md` and `README.ja.md` have a Quick start that creates the test database, builds Qenome, and runs three examples: an index that removes the full scan (`improved`), an index the SELECT cannot use (`no-effect`), and a SELECT whose rows cannot be compared (`incomparable`, exit status 4). Each command ends with the result it has to report.
- `scripts/check_quick_start.py` runs the Quick start commands from `README.md` as written, compares each result with its `# expect:` marker, and checks that `README.ja.md` holds the same commands. `python3 scripts/check_all.py` and the quality workflow run it on every commit, so the README and the program cannot drift apart. The stages print a skip on Windows, where the Quick start commands do not run.
- The fixture has a third case, `testdata/cases/incomparable.sql` and its candidate index, for a SELECT whose rows cannot be compared.
- `examples/d1-toml` and `examples/d1-jsonc` are sample wrangler projects for `--d1`: the same database and queries, once with `wrangler.toml` and once with `wrangler.jsonc`. Each has one `DEMO_DB` binding, a `schema.sql` that loads 200,000 rows, and the `select.sql` and `index.sql` of the `improved` case. They need only `npx wrangler@4.152.0`, and `.wrangler/` is not tracked by Git.
- `docs/demo.gif` records `qenome --d1 DEMO_DB select.sql index.sql --runs 40` in the sample project, with the matching `docs/demo.tape` for re-recording it. `README.md` and `README.ja.md` show it near the top.
- The D1 section of `README.md` and `README.ja.md` gives the commands that load a sample project and the verdict they report.

### Changed

- `scripts/check_comments.py` checks `.toml` and `.jsonc` files for `#`, `//`, and `/*` markers, and `.tape` files for comment lines, so the samples and the recording script follow the no-comment rule too. `docs/demo.gif` is excluded.

- Release notes now come from the matching CHANGELOG section.

## [0.3.1] - 2026-10-26

### Changed

- Release binaries no longer carry debug information. The Linux binaries shrink from about 11 MB to about 2 MB, and a panic stack trace shows addresses instead of function names and lines.

## [0.3.0] - 2026-10-26

### Added

- The project is licensed under the Apache License 2.0. The license text is the unmodified official text and is in `LICENSE`.
- Windows (x86_64) builds are supported.

### Changed

- `README.md` is now in English; the Japanese version is in `README.ja.md`.

## [0.2.0] - 2026-10-25

### Added

- `--version` prints the version from `build.zig.zon` as `qenome <version>` and exits with status 0.
- `--format json` prints one JSON object with a trailing newline after a comparison that finishes: the time verdict and its reasons, the result comparison with its reasons, counts and example rows (the examples only with `--show-rows`), both plans and counters, the times and sizes, the inputs, versions and timing conditions, and the binds (their values only with `--show-binds`).
- `--format json` includes `environment.qenome_version`, the same version `--version` prints from `build.zig.zon`. `schema_version` stays 1.

### Changed

- Mismatched result rows are counts unless `--show-rows` is set, in every format. Human omits the example rows and says to rerun with `--show-rows`. kv omits `baseline-only-row` and `variant-only-row`. json leaves `baseline_only_examples` and `variant_only_examples` empty. The counts stay, and `schema_version` stays 1. The hint for `sum()`, `avg()` and `total()` says to rerun with `--show-rows` instead of pointing at those lines.

### Fixed

- `--format json` writes a backslash as `\\` and an invalid UTF-8 byte as `\xNN` in string values, so the four characters `\xff` and the byte 0xFF stay distinct. Paths, plan detail, reasons, and bind text use this encoding. `schema_version` stays 1, because JSON output has not been in a release.

## [0.1.0] - 2026-10-25

### Added

- `qenome` judges whether one candidate `CREATE INDEX` speeds up one read-only `SELECT`. The database is opened read-only and copied, through SQLite's backup API, into a private temporary directory as a baseline snapshot. The variant is a copy of that snapshot, and the index is created only on the variant.
- Result rows are compared as a multiset: each distinct row must occur the same number of times. Row order is reported as a reference and is not part of the match.
- When the rows match and `--runs` is not 0, the `SELECT` is timed again. Rounds alternate baseline-then-variant and variant-then-baseline (ABBA).
- The time verdict is `improved` (less work, a median more than 20% lower, and faster in every round), `no-effect` (the same plan and counters, with medians within 20%), `needs-check` (any other timed result, with the reasons), or `not-judged` (the rows differ, cannot be compared, or `--runs` is 0). The verdict does not change the exit status.
- The comparison exits 0 when the row multisets match, 3 when they differ, and 4 when they cannot be compared.
- `--format human` (the default) prints a summary, a side-by-side comparison, and the query plans. `--format kv` prints one `key: value` per line, including the inputs and the timing conditions.
