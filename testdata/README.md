# Test data (step 1: dummy database and expected-value table)

A dummy database for judging an index, and the expected values that decision is checked against. Compare a result with this table to decide whether it improved.

No real data, secrets, or real personal information (only synthetic data determined by `id`).

## Files

| Path | Role |
|---|---|
| `schema.sql` | The `events` table (no indexes are created) |
| `seed.sql` | A deterministic load of 200,000 rows (does not use `random()`) |
| `verify.sql` | Invariant checks (for the `sqlite3` CLI only) |
| `seed.json` | A 50,000-row dummy-data spec for `--seed-data` (used by the Quick start in CONTRIBUTING.md; the fixture database is not changed) |
| `cases/improved.sql` / `cases/improved.index.sql` | The SELECT and candidate DDL for an example that improves |
| `cases/write.sql` | The INSERT for a `--write` example (uses `cases/improved.index.sql` as the candidate) |
| `cases/no-effect.sql` / `cases/no-effect.index.sql` | The SELECT and candidate DDL for an example with no effect |
| `cases/incomparable.sql` / `cases/incomparable.index.sql` | The SELECT and candidate DDL for an example whose results cannot be compared |
| `generated/` | Where the generated database is placed (gitignored; not tracked) |

## Regenerating the database

Run `schema.sql`, then `seed.sql`, then `verify.sql`. Loading the seed takes about 0.08 seconds, and the load plus the checks stays under one second (2026-10-10, macOS, SQLite 3.51.2). Checked with macOS `sh` / `zsh`. Windows has not been checked.

```sh
mkdir -p testdata/generated
rm -f testdata/generated/qenome-fixture.db
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/schema.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/seed.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/verify.sql"
```

- The leading `mkdir` is required. Without the directory, `sqlite3` exits 1 with `unable to open database file` and creates no database.
- `verify.sql` prints 17 checks. All `ok` means exit 0. One `FAIL` makes the last `INSERT` violate a `CHECK` constraint and exit 1 (measured: `Runtime error near line 32: CHECK constraint failed: ok = 1 (19)`).
- If a step fails, delete the partly written database and start again (do not keep a half-built database). Deleting it and running the steps again has been checked.
- If a check prints `FAIL`, do not rewrite the expected values. Find the cause first (do not treat a result that does not match the record as a success).
- This procedure was run twice, and the check output matched exactly (2026-10-10).

Checks in `verify.sql`: the row count; the minimum, maximum, and uniqueness of `id`; the non-NULL count, NULL count, distinct count, minimum, maximum, and zero out-of-range values of `customer_id`; the three `status` counts and zero unknown values; the NULL and non-NULL counts of `note`; and zero user-defined indexes.

`seed.json` is the `--seed-data` example in the Quick start in CONTRIBUTING.md. It replaces `events` in the sandbox copy with 50,000 rows whose `id` and `customer_id` are the sequence 1..50,000, whose `status` is `ok` 50% / `failed` 50%, and whose `note` is NULL. The fixture database is not changed.

## Reference version

The expected values were derived on the following version. Use the same version when you build `testdata/generated`.

```text
sqlite3 3.51.2 2026-01-09 17:27:48 b270f8339eb13b504d0b2ba154ebca966b7dde08e40c3ed7d559749818cbalt1 (64-bit)
```

The plan text and the full-scan row counts were checked to be the same on 3.51.0 and 3.53.4. **When the version changes, derive the expected values again.**

## Data conditions (the values `verify.sql` checks)

| Condition | Value |
|---|---|
| Row count | 200,000 |
| `id` | The sequence 1..200,000 (no duplicates) |
| `customer_id` | Cycles through 1..2,000. The 200 rows where `id%997 = 0` are NULL |
| `status` | `ok` 66,666 / `warn` 66,667 / `failed` 66,667 (decided by `id%3`) |
| `note` | `'note-'||id`. The 40,000 rows where `id%5 = 0` are NULL |
| User-defined indexes | 0 |
| Database size (reference) | 1,242 pages, 5,087,232 bytes (about 4.85MiB, `page_size` 4096) |

The database size can change with the version, so it is not part of the checks and is recorded only as a reference. Byte-for-byte identity of the file is not guaranteed either (the judgement uses the invariants in `verify.sql`).

## Three queries and their candidate DDL

| | Example that improves | Example with no effect |
|---|---|---|
| SELECT | `SELECT id, status, note FROM events WHERE customer_id = ?;` | `SELECT note FROM events WHERE lower(status) = ?;` |
| Representative bind | Type INTEGER, value `1234` | Type TEXT, value `'ok'` |
| Candidate DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` | `CREATE INDEX ix_events_status ON events(status);` |
| Why the index does not apply | — | The filtered column is wrapped in `lower()`, so the index on `status` cannot be used |

### Example that cannot be compared

| Item | Value |
|---|---|
| SELECT | `SELECT id, note FROM events ORDER BY random() LIMIT 10;` |
| Representative bind | None |
| Candidate DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` |
| Why it cannot be compared | `random()` picks different rows on every run (`alwaysIncomparable` in `src/db.zig`) |
| Result | `result: incomparable`, exit status 4, `verdict: not-judged`. The SELECT is not measured |

The Quick start in CONTRIBUTING.md uses this pair. The candidate DDL is not what the comparison judges, so it is the same DDL as the example that improves.

### Write example

| Item | Value |
| --- | --- |
| File | `cases/write.sql` |
| SQL | `INSERT INTO events(customer_id, status, note) VALUES (?, 'ok', 'new');` |
| Representative bind | Type INTEGER, value `1234` |
| Candidate DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` (the same as the example that improves) |
| Expected rows written | baseline 1 (one table row), variant 2 (one table row + one insert into the candidate index) |
| Expected rows changed | 1 on both sides |
| Result | `result: match`, `verdict: needs-check`, exit status 0 |
| Expected rows read | 0 on both sides (`INSERT ... VALUES` reads no rows) |

`--write` runs the statement on each sandbox copy and rolls the transaction back, so the original database does not change. Rows written use the workerd row-count patch. They include the table row, each secondary-index insert, trigger inserts, and foreign-key CASCADE actions. They do not include secondary-index deletes, so a `DELETE` may not increase the rows written. An integration test in `src/cli/tests.zig` checks that an index can lower the rows read by `DELETE ... WHERE`.

## Expected-value table

Values from a run with the representative bind. The index is the difference between `baseline` (no index) and `variant` (only the candidate DDL applied).

### Example that improves

| Item | No index (baseline) | With the index (variant) |
|---|---|---|
| Plan | `SCAN events` | `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` |
| Full-scan rows | 199,999 | 0 |
| VM steps | 600,407 | 710 |
| Row count | 100 | 100 |
| `count(customer_id)` / `count(note)` | 100 / 100 | 100 / 100 |
| `sum(id)` / `sum(customer_id)` | 10,023,300 / 123,400 | Same as baseline |
| `sum(length(note))` | 1,045 | 1,045 |
| `min(id)` / `max(id)` | 1,233 / 199,233 | Same as baseline |
| Result comparison (step 5) | — | Match (`result: match (row multiset)`, exit status 0, `row-order: same`) |

### Example with no effect

| Item | No index (baseline) | With the index (variant) |
|---|---|---|
| Plan | `SCAN events` | `SCAN events` (identical) |
| Full-scan rows | 199,999 | 199,999 |
| VM steps | 933,339 | 933,339 |
| Row count | 66,666 | 66,666 |
| `count(note)` | 53,333 | 53,333 |
| `sum(length(note))` | 557,032 | 557,032 |
| `min(note)` / `max(note)` | `note-100002` / `note-99999` | Same as baseline |
| Result comparison (step 5) | — | Match (`result: match (row multiset)`, exit status 0, `row-order: same`) |

### Decision conditions

The decision is the following relations, not the absolute numbers.

- Example that improves: the results match, and the rows read (`rows-read`) are lower than with no index. The plan also changes to `SEARCH`.
- Example with no effect: the results match, and the rows read and the rows written match the no-index side. The plan, the full-scan rows, and the VM steps also match.
- Time (no numeric answer is fixed. It is not used for the decision, and is reported as a reference in `time-baseline-ns` / `time-variant-ns`): for the example that improves, the median with the index is smaller and the order does not reverse across repeats. For the example with no effect, the difference of the two medians stays inside the measurement noise (for example, within ±20% of the no-index median).
- When the rows read do not fall: do not call it an improvement, even if the time is shorter.

VM steps can change by a few steps with the way the statement is written (the indexed side of the example that improves: representative bind 710 / literal 708). The table above uses the representative bind. That difference does not affect the relations.

## Commands that derive the values

How to derive the expected values again. Use the reference version of `sqlite3`.

```sh
d=$(mktemp -d)
cp testdata/generated/qenome-fixture.db "$d/baseline.db"
cp testdata/generated/qenome-fixture.db "$d/improved.db"
cp testdata/generated/qenome-fixture.db "$d/no-effect.db"
sqlite3 "$d/improved.db" ".read testdata/cases/improved.index.sql"    # add the index on the variant side only
sqlite3 "$d/no-effect.db" ".read testdata/cases/no-effect.index.sql"
```

The plan and the counters (the example that improves; `1234` is the representative bind):

```sh
sqlite3 "$d/baseline.db" <<'SQL'
.parameter set ?1 1234
.stats stmt
EXPLAIN QUERY PLAN SELECT id, status, note FROM events WHERE customer_id = ?;
SELECT id, status, note FROM events WHERE customer_id = ?;
SQL
```

- Read the `SCAN` / `SEARCH` line from the `EXPLAIN QUERY PLAN` output.
- Read the **last** `Fullscan Steps` and `Virtual Machine Steps` from `.stats stmt`. Result rows are mixed into the output (the example with no effect prints 66,666 rows).
- For the side with the index, read `$d/improved.db` or `$d/no-effect.db` instead.
- For the example with no effect, use `.parameter set ?1 ok` and replace the statement with `SELECT note FROM events WHERE lower(status) = ?;`.

Summary of the result (the example that improves):

```sh
sqlite3 "$d/baseline.db" "SELECT count(*), count(customer_id), count(note), sum(id), sum(customer_id), sum(length(note)), min(id), max(id) FROM events WHERE customer_id = 1234;"
```

Summary of the result (the example with no effect):

```sh
sqlite3 "$d/baseline.db" "SELECT count(*), count(note), sum(length(note)), min(note), max(note) FROM events WHERE lower(status) = 'ok';"
```

The summaries only check the expected values. They do not replace the step-5 match (a multiset comparison of rows that keeps value types, NULLs, and duplicate counts). Two results can share a summary and still differ.

## Traps

- **Covering index**: drop `note` from the SELECT in the example with no effect (`SELECT status FROM events WHERE lower(status) = ?;`) and the plan with the index becomes `SCAN events USING COVERING INDEX ix_events_status`. The plan changed without an improvement, so derive the expected values again when you change the SELECT.
- **Do not run `ANALYZE`**: statistics make the plan depend on the statistics, so the fixture does not run `ANALYZE`.
- **Reading the counters**: result rows are mixed into the `.stats stmt` output. Take the last `Fullscan Steps` / `Virtual Machine Steps`.
- **Version dependence**: the expected values were derived on the reference version. Derive them again when the version changes.
- **Byte-for-byte identity is not guaranteed**: the judgement does not use identical file bytes. It uses the invariants in `verify.sql`.
- **`LIMIT` alone does not make a result incomparable**: a SELECT with `LIMIT` / `OFFSET` stays a `match` and keeps being compared and measured when the rows match (`LIMIT` / `OFFSET` appears only as the reason when the rows differ). What makes a result incomparable is a non-deterministic function such as `random()`, or a SELECT that reads a schema table (`alwaysIncomparable` in `src/db.zig`).

## Accuracy corpus (`testdata/accuracy/`)

`testdata/accuracy/` holds known-answer cases for the verdict. `scripts/check_accuracy.py` builds a fresh database for each case in a temporary directory, runs `zig-out/bin/qenome --format json`, and compares the JSON with the answer in `case.json`. It runs each case several times (`--repeat N`, default 3) and fails when the exit status, the report `exit_code`, `result`, `verdict`, `plan_changed`, a plan step detail, or a counter differs between the runs. Every comparison in a batch report is checked, and a batch report also has its `recommended` and summary counts compared. Timing is not compared unless a case opts in with `"timing": "stable"`, and a case asserts the timing labels with `effect`: that expectation fails only when more than half of the runs return a label outside the allowed list, and the smaller count of runs outside it is printed on one line that starts `note`, with the case name, the run numbers and the labels, because the label is statistical. A case without `effect` keeps the stricter check: every run must hold a valid label, and the runs must not flip between `faster` and `slower`.

One directory per case, `testdata/accuracy/<case>/`:

| Path | Role |
| --- | --- |
| `schema.sql` | Tables and existing indexes; the harness applies it to a new database |
| `data.sql` | Optional deterministic rows and `ANALYZE`; the harness applies it with Python's `sqlite3` module |
| `seed.json` | Optional `--seed-data` spec instead of `data.sql`; the harness passes it to qenome |
| `select.sql` or `write.sql` | The statement to compare |
| `index.sql` | The candidate index for one comparison or `--write` |
| `batch.json` | A `--batch` manifest; a batch case has no `index.sql` |
| `migration.sql` | A migration applied on the variant with `--batch`; a manifest here must omit `candidates` |
| `w.sql` | A write statement that a `--batch` manifest lists under `writes`; the harness never treats it as the `--write` marker |
| `case.json` | `description`, `args` and `expect`; `known_wrong` and `timing` are optional |

No database file is committed. The harness infers the mode from the files: a `batch.json` means `--batch` (with `--migration` when `migration.sql` exists), a `write.sql` means `--write`, `--suggest` in `args` means one SELECT without `index.sql`, and anything else is one SELECT with `index.sql`. `args` holds only extra qenome options such as `--bind`; the harness adds `--format json` and `--runs 0` (the last one is skipped for a batch, `--suggest`, or a case with `--runs`). A case with `--runs` needs `"timing": "stable"`, and a timing case needs at least 6 rounds.

`expect` keys (an unknown key is an error):

- `exit` (the process status) and `exit_code` (the same field in the JSON report).
- `result` (`match`, `mismatch`, `incomparable`), `verdict`, and `plan_changed`.
- `baseline_plan` / `variant_plan`: `contains` and `excludes` substrings of a plan step `detail`.
- `rows_read` / `rows_written`: `decrease`, `same`, or `increase`, or an object with `direction` and an optional `max_ratio` (the upper bound of variant / baseline).
- `effect`: the timing `effect` of the runs, as one value or an array of allowed values from `faster`, `slower`, `no-difference`, and `insufficient-samples`; it needs `"timing": "stable"`. This check fails only when more than half of the runs return a value outside the list (with `--repeat 3`, two or more); for a smaller count of runs outside it, the check passes and one `note` line names the case, the runs and their labels. Every other key fails on a single run.
- `warnings`: warning `code`s that must be in `contains` or `excludes`.
- `human`: `contains` / `excludes` substrings of the `--format human` report. The harness runs that report once, after the JSON runs, so a case can require that the human report shows a warning next to the verdict.
- `batch`: `recommended` and `counts` for `summary[0]` (`improved`, `no_effect`, `needs_check`, `mismatch`, `incomparable`, `timeout`, `not_judged`).
- `writes`: one comparison check per entry of the report's top-level `writes` array, in order, with the same keys as the top-level comparison check (`result`, `verdict`, `plan_changed`, the two plans, the two counters, and `warnings`). It fails when the report holds a different number of write comparisons.
- `suggest`: `recommended` (true or false) and `leads_with` (the leading columns of the recommended index).
- `rank`: for a case whose `args` contain `--rank`. `likely_full_scans` is the count in the report, `first` is `queries[0].select` after ranking, and `note` is a substring of the report `note` (the line that says the weighted rows are not a bill).
- `error`: the `code` of the error object on stderr, for a run that stops before the report.

For one comparison the report itself is the comparison object; for `--batch`, `--migration`, and `--suggest` it is `results[0].comparison`, so a case that checks the comparison holds exactly one query result. A `--migration` case that lists write statements checks them with `writes`, and its comparison check still reads `results[0].comparison`. Run the corpus with `python3 scripts/check_accuracy.py [--case NAME] [--repeat N] [--binary PATH]`.

After the per-case lines the run prints one summary line: the number of cases per expected `verdict` and per expected `result` (`unstated` counts the cases that expect neither), then one line for every case that expects a verdict other than `improved` and got `improved`. Such a case fails the run, including a `known_wrong` case, whose marker records the wrong answer but must not hide it: those cases are listed on their own line with their issue link.

### Case groups

The cases fall into three groups, and each directory is named after the trap it tests.

| Group | What the case protects | Added later |
| --- | --- | --- |
| not improved | the rows match and the variant does not read at least 1% fewer rows, so the answer is `no-effect`: an index SQLite does not use, a plan whose text changed without changing the rows read, an unused index that the timing must not call `faster` in most runs, and a one-row saving out of 50,000 | `unused-column-index`, `nocase-index-binary-comparison`, `covering-index-same-rows`, `timing-same-plan`, `one-row-gain-of-50000` |
| needs review | the rows match but the change costs something: the verdict is `needs-check` when the variant reads or writes more rows, and the warnings must reach the human report next to the verdict | `stale-stats-reads-more`, `insert-index-writes`, `update-indexed-column-writes-more`, the same query and index that answer `improved` for one bind and `no-effect` for another (`bind-range-one-row`, `bind-range-every-row`), and the human checks in `small-data` and `no-analyze-stats` |
| results differ | the rows must stay the same where the candidate can only change the plan, and a case where they can differ expects exit `3` or `4` with `verdict` `not-judged`, never `improved` | `nocase-index-match`, `partial-index-range-match`, `order-by-ties-limit` |

To add a case, create the directory with the files above, put the explanation in `description` (the SQL files must not hold comments), and run `python3 scripts/check_accuracy.py --case <case>`. Decide the expected answer from SQLite's documented behaviour and from the baseline and variant plans, not from what the binary prints today. When the binary is wrong, keep the right expectation and mark the case `"known_wrong": "<issue link>"` with a new issue: the harness reports it as `known-wrong` instead of `ok`, and fails once the case starts passing so that the marker gets removed. A change to the verdict rule belongs in its own issue, not in a corpus case. When the expectation deliberately records today's answer while a human decides (as in `one-row-gain-of-50000`), name that issue in `description`. The 1% read-reduction rule has three known answers: `one-row-gain-of-50000` is `no-effect`, `one-percent-gain-of-50000` is the smallest `improved`, and `clear-gain-equality` is a clear `improved`. The corpus depends only on the JSON contracts in `docs/json.md` (comparison `schema_version` 2, `batch_schema_version` 1, and a `--rank` report that carries `schema_version` 2 plus `rank_schema_version` 1); a new SQLite version can change a plan text or a counter, so recheck the expected values then.

`rows_read` counts the rows a b-tree cursor visits: a full scan visits every row, and an index search visits its matching entries plus one, so one search cannot read more rows than a full scan. Sorter reads count too, so an index that removes an `ORDER BY` sort also lowers the counter. A `needs-check` from one SELECT therefore needs a baseline that already reads fewer rows than the table: `stale-stats-reads-more` writes a `sqlite_stat1` row that makes the planner prefer the candidate index over a better existing one. A write reaches `needs-check` through `rows_written` instead (`insert-index-writes`, `update-indexed-column-writes-more`). A bind decides the direction of one search: `bind-range-one-row` matches one row and reads one, while the same query and index in `bind-range-every-row` matches every row and reads every entry, so the first is `improved` and the second is `no-effect`.

A `mismatch` needs a query whose rows SQL itself leaves open: `group-by-bare-column` uses a bare column beside `GROUP BY`, where the index changes the row SQLite picks. A `LIMIT` query whose rows differ is `incomparable` (exit `4`) instead, because the plan can pick other rows: `order-by-ties-limit` orders by a non-unique column and cuts through tied rows, so the two copies return different rows. A collation does not change the rows on the same data (`nocase-index-match` shows the NOCASE index search returning the same rows); it only decides whether the index can be used, because a NOCASE index does not serve the default BINARY comparison (`nocase-index-binary-comparison`).
