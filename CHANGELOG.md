# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `README.md` and `README.ja.md` show three recordings instead of one: `--suggest` at the top, and a candidate comparison and a `--migration` regression in the `--batch` section. They are recorded from `docs/demo-suggest.tape`, `docs/demo-candidates.tape`, and `docs/demo-migration.tape`, which take their extra inputs from `docs/demo`; `docs/demo.tape` and `docs/demo.gif` are gone.
- `README.md` and `README.ja.md` lead with `npm install -g qenome` for the npm install, so the command is on `PATH` for every project, and keep `npx qenome` for a run without installing; `skills/qenome/SKILL.md` no longer says the npm package is added separately, because `qenome` is published on npm.

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
