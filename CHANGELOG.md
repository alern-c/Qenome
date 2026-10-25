# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--version` prints the version from `build.zig.zon` as `qenome <version>` and exits with status 0.

## [0.1.0] - 2026-10-25

### Added

- `qenome` judges whether one candidate `CREATE INDEX` speeds up one read-only `SELECT`. The database is opened read-only and copied, through SQLite's backup API, into a private temporary directory as a baseline snapshot. The variant is a copy of that snapshot, and the index is created only on the variant.
- Result rows are compared as a multiset: each distinct row must occur the same number of times. Row order is reported as a reference and is not part of the match.
- When the rows match and `--runs` is not 0, the `SELECT` is timed again. Rounds alternate baseline-then-variant and variant-then-baseline (ABBA).
- The time verdict is `improved` (less work, a median more than 20% lower, and faster in every round), `no-effect` (the same plan and counters, with medians within 20%), `needs-check` (any other timed result, with the reasons), or `not-judged` (the rows differ, cannot be compared, or `--runs` is 0). The verdict does not change the exit status.
- The comparison exits 0 when the row multisets match, 3 when they differ, and 4 when they cannot be compared.
- `--format human` (the default) prints a summary, a side-by-side comparison, and the query plans. `--format kv` prints one `key: value` per line, including the inputs and the timing conditions.
