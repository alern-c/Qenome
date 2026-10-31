# Accuracy and production D1

Qenome compares a sandbox copy of a local database. It never changes the original database, and it does not read production D1 metrics. This page says how far to trust a result: how the row counters are built, what each verdict means, what can differ from production D1, and how to check a result against production yourself.

The numbers use the same counting as local D1 (workerd patch), but they come from your local data and statistics. They have not yet been checked against production D1. Use them to compare a query before and after an index on the same copy, not as a production measurement. The full JSON contract is in [docs/json.md](json.md).

## How rows are counted

Qenome builds the bundled SQLite (3.53.4 in this tree) with Cloudflare's row-count patch from `workerd`; [NOTICE](../NOTICE) names the patch and [vendor/sqlite3/PROVENANCE.txt](../vendor/sqlite3/PROVENANCE.txt) records its hashes and how to apply it again. The patch adds two prepared-statement counters, `LIBSQL_STMTSTATUS_ROWS_READ` (1025) and `LIBSQL_STMTSTATUS_ROWS_WRITTEN` (1026), and Qenome reports them as `rows_read` and `rows_written`. Local D1 runs the same patch, so the report uses the same counting as local D1 (workerd patch).

The patch increments the read counter in `OP_Count`, `OP_Seek*`, `OP_NotExists`, `OP_SeekRowid`, `OP_Last`, `OP_Rewind`, `OP_Next`, and `OP_VNext`. It increments the write counter in `OP_Insert`, `OP_IdxInsert`, `OP_Delete`, `OP_Clear`, and `OP_VUpdate`, skipping ephemeral cursors. In practice:

- **Rows read** counts the rows and index entries a scan steps over. The positioning operations (`OP_Seek*`, `OP_NotExists`, `OP_SeekRowid`, `OP_Last`, `OP_Rewind`) add one for the attempt, which can be counted even when the lookup finds no row; `OP_Count` adds the row count it returns.
- **Rows written** counts the table rows and secondary-index entries the statement inserts, plus the rows that triggers and foreign-key actions insert or delete. A deleted table row is counted; the removal of its secondary-index entry is not.
- Both sides are measured from the first run of the statement on each copy. The comparison adds no run to collect them, so `--runs 0` still reports both counts.

For a simple `INSERT` into a table with one secondary index and no triggers or foreign-key actions, one table row and one index entry are written, so the copy with the index reports 2 rows written. A `DELETE` of one such row reports 1 row written: the table row is counted and the index entry is not. A `DELETE ... WHERE` can therefore read fewer rows with the same rows written. An `UPDATE` that removes an old index entry reports less than the full index-maintenance cost.

Both counters are 32-bit. Each wraps past 4,294,967,295 of its own count, so a statement that goes past that in one run reports a wrapped number. The verdict compares the numbers as they were read.

## What the verdicts mean

The result rows are compared as a multiset: each distinct row must appear the same number of times on both copies. Row order is a reference and is not part of the match. With `--write`, the `RETURNING` rows (empty without `RETURNING`), `sqlite3_changes`, and `sqlite3_total_changes` must also match.

| Verdict | Meaning |
| --- | --- |
| `improved` | The rows match, the variant reads fewer rows, and the variant writes no more rows. |
| `no-effect` | The rows match, both copies read the same number of rows, and the variant writes no more rows. |
| `needs-check` | The rows match, but the variant reads or writes more rows. |
| `regressed` | The rows match, but the migration made the variant read or write more rows. Only in a `--migration` batch; the batch exits `6` unless a mismatch, a rejected change, a timeout, or an incomparable result takes precedence. |
| `not-judged` | The rows differ or cannot be compared, or a `--migration` query could only run on the variant. Also used for a `--write` that was not run. |

`rows_read` and `rows_written` decide the verdict. The times are a reference only and never change the verdict or the exit status, so `--runs 0` keeps the verdict and skips the timing loop.

The `result` field says whether the rows could be compared:

| Result | Meaning |
| --- | --- |
| `match` | The rows are the same on both copies. With `--write`, the same `RETURNING` rows, `changes`, and `total_changes` are also required. |
| `mismatch` | The rows differ, or a `--write` made a different change; the exit status is `3`. |
| `incomparable` | The rows cannot be compared. A comparison with both sides exits `4`; a variant-only `--migration` query is `not-judged`, writes exit `0` in its comparison, and does not change the batch exit status. |

Warnings advise; they never change the verdict, a row count, or the exit status. The codes are defined in [src/contract/values.zig](../src/contract/values.zig):

| Code | Meaning | What to do |
| --- | --- | --- |
| `no_analyze_stats` | The candidate index's table has no non-empty `sqlite_stat1` entry in the baseline copy. | Test an `ANALYZE`'d copy with representative data. Qenome does not run `ANALYZE`; `--seed-data` runs it on the tables in the spec. |
| `data_too_small` | The candidate index's table has fewer than 1,000 rows. | Test with more representative data. The warning is a heuristic, not proof that the data is representative. |
| `bind_dependent_partial_index` | The variant plan uses a partial index only because the bound values satisfy its `WHERE` clause. | Test the values you deploy. The improvement holds only for this run; another bound value or parameter style can drop the index. |
| `unapplied_migrations` | The local D1 database has not applied these migrations from the wrangler config. | Run `npx wrangler d1 migrations apply <BINDING> --local` and compare again; the schema under test is older than the migrations describe. |

A `--migration` batch does not emit `no_analyze_stats` or `data_too_small`, because a migration can touch several tables.

## What can differ from production D1

The result is a measurement of a local copy. A production result can differ for any of these reasons.

- **Data size and distribution.** A local database, or the rows from `--seed-data`, is not production data. A different number of rows, or different duplicate and NULL counts, changes the row counts and can change the plan.
- **Statistics.** The planner uses `ANALYZE` data in `sqlite_stat1`. The local copy may have no statistics (`no_analyze_stats`) or statistics from other data, while production may have other statistics or none. Qenome does not run `ANALYZE` except on the tables listed by `--seed-data`.
- **SQLite version and build.** The report records the bundled version in `environment.sqlite_version` and, with `--d1`, the local D1 engine version in `d1.sqlite_version`; both are SQLite 3.53.4 in this tree. The bundled build and the local D1 build use different compile options, and production D1 runs its own build. A different version or build can plan and time the query differently.
- **The query planner.** On other data or statistics, SQLite can choose another index, another join order, or a full scan. The local plan is not a promise for production.
- **Real traffic.** Qenome runs the query with the bind values you pass. Production runs it with other values, at its own frequency, with its own caching and concurrent writes. `avgRowsRead` from `d1 insights` is an average over the values that ran in the period, not the count for one value.
- **Writes.** The write counter does not count secondary-index deletes (see [How rows are counted](#how-rows-are-counted)), so a `DELETE` or an `UPDATE` that removes an old index entry reports less than the full index-maintenance cost.
- **Schema.** The local D1 database can be older than the migrations in the wrangler config. The `unapplied_migrations` warning lists the migration files that have not been applied; a result on that schema can hide the effect of the index.
- **Billing.** D1 bills on its own counters. Qenome reads `sqlite3_stmt_status` on a local copy and does not read the production counters, so the report cannot tell you what D1 will charge.

## How to check against production yourself

The wrangler commands use the database name or binding in place of `<database>`. `wrangler d1 insights` is marked experimental in wrangler and acts on remote D1 databases. It needs the **Account Analytics: Read** permission on the account; with an API token, add that permission to the token.

1. List the top queries by average rows read:

   ```sh
   npx wrangler d1 insights <database> --sort-by=reads --sort-type=avg --time-period=7d --json
   ```

   `--time-period` accepts days, hours, or minutes (`7d`, `24h`, `60m`), and the maximum is 31 days. The `--limit` default is 5; raise it if the query you want is not in the list. `d1 insights` groups by query text and does not record bind values.

2. Pick the query and note `avgRowsRead`, `avgRowsWritten`, and `numberOfTimesRun`. The averages cover every bind value and every execution of that query text in the period.

3. Run Qenome on the same query with typical bind values against a local copy that is close to production: the local D1 database, `--seed-data` with similar row counts, or a copy of an export you are allowed to use. Use `--d1 <BINDING>` for a local D1 database and a database path instead for an export. Compare the baseline `rows_read` with `avgRowsRead`:

   ```sh
   npx qenome --d1 <BINDING> select.sql index.sql --bind 1:int:1234 --runs 0 --format json
   ```

   The JSON report holds the count at `baseline.counters.rows_read`; the human report prints it on the left of the `rows read` line. A difference is expected when the data, statistics, version, or bind values differ; see [What can differ from production D1](#what-can-differ-from-production-d1). The comparison is useful when the two values are close.

4. Optionally, run the query once in production with typical values and read `rows_read` from the result's `meta`:

   ```sh
   npx wrangler d1 execute <database> --remote --json --command "SELECT ..."
   ```

   This runs against production and counts as usage. `--command` has no bind option, so write the values into the SQL. It is one execution with one set of values, not an average.

5. After the index is deployed, run `d1 insights` again for the same period length and compare `avgRowsRead`. Traffic changes between the two periods, so a lower average is a check, not proof that the index caused it. Keep the period length and the query text the same.

The local `rows_read` and the production `avgRowsRead` are two different measurements. They can agree, but they are not the same measurement.

## Showing a regression

`--migration` checks a schema change, including one that drops an index the query uses. The accuracy corpus keeps a known-answer case at [testdata/accuracy/migration-regressed/](../testdata/accuracy/migration-regressed/):

- `select.sql`: `SELECT id, note FROM events WHERE customer_id = ?;`
- `migration.sql`: `DROP INDEX idx_customer;`

Before the migration the plan is `SEARCH events USING INDEX idx_customer (customer_id=?)`; after it the plan is `SCAN events`. The result rows still match, but the variant reads more rows. The verdict is `regressed` and the batch exits `6`. The JSON keeps the verdict in `results[].comparison.verdict`, counts the query under `summary.needs_check`, and sets `recommended` to `null`. The `human` report shows `regressed` in the `Results` table.

No new code is needed for this case; the corpus already checks it.
