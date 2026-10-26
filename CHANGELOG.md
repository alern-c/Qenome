# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
