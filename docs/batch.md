# Comparing many queries and candidates

## Batch comparisons

`--batch manifest.json` compares every SELECT in a manifest with every candidate `CREATE INDEX`. The manifest is a JSON object with the lists it needs:

```json
{
  "queries": [
    { "select": "queries/orders.sql", "binds": ["1:int:1234"] },
    { "select": "queries/recent.sql" }
  ],
  "writes": [
    { "write": "writes/mark.sql", "binds": ["1:int:1234"] }
  ],
  "candidates": [
    { "index_sql": "candidates/a.sql" },
    { "index_sql": "candidates/b.sql" }
  ]
}
```

- `queries` holds 1 to 100 entries. `candidates` holds 1 to 100 entries, or may be omitted (or `[]`) when `--suggest` adds the proposals or `--migration` supplies the variant change.
- `writes` holds 1 to 100 entries and is only accepted with `--migration`. Without `--migration` the manifest is rejected before anything runs, with exit status `1` and `batch_manifest_invalid`, unless the run is `--rank`, which ignores `writes`. Each entry names one file that holds one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE`; a leading `WITH` and a trailing `RETURNING` are allowed, and the same checks and time limit apply as for `--write`.
- The same path cannot appear twice in `queries`, in `writes`, or in `candidates`.
- With `--migration`, `candidates` must be omitted or `[]`, and the manifest holds `queries` and optional `writes`.
- `select`, `write`, and `index_sql` are paths to files. They are resolved from the manifest's directory, not from the current directory. Each file holds one read-only SELECT, one write statement, or one `CREATE INDEX`, and is at most 1 MiB.
- `binds` is optional and uses the same `N:TYPE:VALUE` syntax as `--bind`. Every query and write entry carries its own binds. Every path and bind must be a JSON string without a NUL byte.
- `executions` is optional on a query. It is a whole number of at least 1. `--record` writes how many times that statement ran. Comparison modes ignore it. `--rank` multiplies rows read by it.
- The `select`, `write`, and `index_sql` strings are copied to the JSON report exactly as written. The `human` report shortens an absolute path to the shortest trailing part that no other path in the same list shares, so candidates in different directories stay apart (`a/x.sql` and `b/x.sql`), and shows a relative path and a `suggested:N` label as written. The full path stays in the JSON report, and with `--migration` in the `migration:` line.

Qenome copies the database once, checks every SELECT, every write statement, and every candidate before it runs anything, then visits the candidates in manifest order. For each candidate it copies the baseline again, builds the index on that copy only, and runs every query on both copies. The baseline SELECT is run again for each candidate. With `--migration`, every write statement of the manifest runs after the queries of the candidate, on the same two copies.

With `--migration <FILE>`, the variant change is the whole migration file instead of a candidate index. The file is at most 1 MiB. Qenome checks the file before it touches the variant: it allows `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (a column list, not `AS SELECT`), and `ALTER TABLE` with ADD COLUMN, RENAME COLUMN, DROP COLUMN, or RENAME TO, separated by semicolons. `INSERT`, `UPDATE`, `DELETE`, `DROP TABLE`, `ATTACH`, `PRAGMA`, and every other statement are rejected with the statement number and status `1`; the variant and the original database are not touched. It then applies the statements in file order to the variant only, so a migration may add a column and index it, rename a column or table, or drop an index and create another with the same name. Each statement gets its own `--timeout-ms`. The original database is never changed. The report adds a `migration:` block (human) or a top-level `migration` object (JSON) with the path and every applied statement. A query that uses a column or table the migration adds cannot run on the baseline: Qenome measures it on the variant only and reports its plan and row counts with verdict `not-judged`, with the baseline reason in `verdict_reasons`. That query does not change the exit status. Human output adds a `not-judged` summary column and a `Not judged` list; JSON counts it under `summary.not_judged` and writes the comparison with `baseline: null`. A query that the migration breaks stops the run: if the manifest refers to a column or table that the migration drops or renames, the variant cannot prepare that `SELECT`, so nothing is written to stdout and the batch exits `1`, with an `error:` line that names the query and the migration file (JSON: `batch_variant_failed`). A CI step fails there. Write the post-migration names in the manifest. Adding or dropping a column also changes the column count of a `SELECT *`, so that query is `incomparable` and the batch exits `4`; list the columns you need to compare it. When the result rows match but a query reads or writes more rows after the migration, that query's verdict is `regressed`: the human `Results` column says `regressed`, and JSON has `"verdict": "regressed"` under `results[].comparison`. The `summary` count keeps the key `needs_check` and counts those queries, and the batch exits with status `6`; a result mismatch (`3`), a rejected change (`1`), a time limit (`124`), or an incomparable result (`4`) takes precedence. `no-effect` alone keeps `0`. The other modes keep the name `needs-check` for the same condition. The `no_analyze_stats` and `data_too_small` warnings are not emitted for a migration, because it can touch several tables. The `bind_dependent_partial_index` warning is still emitted, because it needs only the variant plan.

`writes` compares write statements in a `--migration` run. After the queries of the candidate, Qenome runs every write statement on the baseline and on the variant, each inside a transaction that it rolls back, so the next statement starts from the same rows and neither the original database nor the sandbox copy keeps a change. Each statement is planned with `EXPLAIN` before it runs, and `--timeout-ms` applies to the plan, the baseline run, and the variant run separately. The report gives `rows read` and `rows written` for both copies. `rows read` decides the verdict, as for a query: more rows read is `regressed` (the batch exits `6`), the same count or a reduction below 1% of the baseline rows read is `no-effect`, and a reduction of at least 1% is `improved`. `rows written` is reported and does not change the verdict, because an index that the migration adds makes every `INSERT` and `UPDATE` write at least one more entry; read the two numbers for the trade-off. The rows must match as for `--write`: the `RETURNING` rows, `changes`, and the difference of `total_changes` must be the same on both copies, and a difference is a `mismatch` with exit `3`. A write that reads the schema, the current time, or a nondeterministic function is not run: its verdict is `not-judged`, its `result` is `incomparable`, and it contributes exit `4`. The bundled D1 counting patch does not count secondary-index deletes, so a migration that drops an index does not lower `rows written`; only the rows read show the change (see [accuracy](accuracy.md)). A write that uses a column or table the migration adds cannot run on the baseline: Qenome runs it on the variant only, reports it as `not-judged` with the baseline reason and the variant counts, and it does not change the exit status, like a query. A write that the variant cannot prepare after the migration, or that fails while it runs (for example a UNIQUE constraint the migration adds), stops the run before the report: stdout is empty, the exit code is `1`, and the error code is `batch_write_failed`; a plan read that reaches `--timeout-ms` stops the same way with `batch_write_timeout` and exit `124`. A write that reaches `--timeout-ms` on the variant is recorded as `timeout` with no comparison, and the batch continues with exit `124`. A migration is recommended only when the queries qualify and no write has a `mismatch`, an `incomparable` result, a timeout, or `regressed`; a `not-judged` write does not disqualify it. The human report adds a `Writes` section with a line per statement and a note about the counting limit, and its `Summary` table keeps counting queries only. JSON adds a top-level `writes` array when the manifest has writes. When a write fails, the `error:` line repeats the SQLite message, which can hold text from the database row or from a bind value (a trigger's `RAISE()` message, for example); stderr is therefore as sensitive as the manifest, and CI logs that keep it need the same care.

With `--migration`, the `size increase` is the change in the bytes that pages in use hold, `(page_count - freelist_count) * page_size`, not the change of the file size. `DROP INDEX` moves its pages to SQLite's freelist without shrinking the file, so the file delta stays `0 B`; the bytes in use report the freed space as a negative value (for example `-2.06 MiB`). The file itself shrinks only after `VACUUM`. Runs without `--migration` keep reporting the file size difference.

<details>
<summary>Batch statuses, failures, and exit status</summary>

A candidate that cannot be built is recorded and the batch continues:

| Status | Meaning | Exit contribution |
| --- | --- | --- |
| `index_rejected` | SQLite rejected the `CREATE INDEX` (for example a UNIQUE constraint on duplicate rows) | `1` |
| `index_timeout` | the index build reached `--timeout-ms` | `124` |
| `variant_timeout` | a variant SELECT reached `--timeout-ms`; that query is not judged, the others stay | `124` |

A failure that affects the whole run stops it before any report is written and leaves stdout empty: a baseline SELECT that fails or times out, a variant SELECT that cannot run after the migration (it uses a column or table the migration dropped or renamed), a write statement that the variant cannot prepare or run, a baseline write run or plan read that fails or times out, a signal, a variant or baseline connection that fails, the temporary copies that cannot be created or removed, and storage errors such as a full disk. Candidate failures are not written as `error:` lines; a write statement that reaches its limit on the variant is recorded as `timeout` in the `Writes` section and inside `writes`, and the run continues.

When the report is written, the exit status is the heaviest of a result mismatch (`3`), a rejected index or migration (`1`), a candidate time limit (`124`), an incomparable result (`4`), a `--migration` regression (`6`) of a query or a write, and `0`. Cleanup failure replaces `0` with `5`. A batch can therefore write a report and still exit `1`, `6`, or `124`; read stdout to tell the cases apart.

The `human` output has a table of candidates, a `Recommendation:`, a table of query and candidate verdicts, and, with `--migration` and `writes`, a `Writes` section. The recommendation is the candidate with the most improved queries among those with no mismatch, no incomparable result, no `needs-check` (`needs_check` counts the `regressed` queries in a `--migration` run), no timeout, and at least one improvement. A write with a `mismatch`, an `incomparable` result, a timeout, or `regressed` also keeps the migration out of `Recommendation:`; a write measured on the variant only is `not-judged` and does not. A query measured on the variant only is `not-judged` and does not disqualify the migration by itself; in the `Results` table its `result` column says `variant-only` and its `verdict` column `not-judged`, while the embedded JSON comparison keeps `result` `incomparable` with `baseline` `null`. Ties go to the candidate without a `bind_dependent_partial_index` warning, then to the smaller size increase, then to manifest order. A warning never changes a verdict, a batch count, or the exit status. The `human` output lists the candidate warnings after the results table in a `Warnings` section, as `<candidate>: <code>: <message>` for `no_analyze_stats` and `data_too_small`, and each comparison warning as `<query> -> <candidate>: <code>: <message>` for `bind_dependent_partial_index`; the paths and the index name are escaped like the other warnings, and the paths use the short form described above. The batch top-level `warnings` (the `--suggest` entries and `unapplied_migrations`) are printed after that as `warning: <code>: <message>`. With `--format json` the output is the `batch_schema_version` 1 object described in [docs/json.md](json.md).

Each index build, each SELECT run, and each diagnostic statement has its own `--timeout-ms` limit. A batch can take one database copy, one baseline SELECT run per query before the candidate loop, and then, for every candidate, one index build and two SELECT runs per query plus the diagnostic statements: up to three for the ANALYZE and size warnings, and, for a query with parameters, the bind-dependent partial index check (one plan, one catalog read, and up to two statements per used index: a table-name lookup and a `PRAGMA index_list`), each with its own time limit. `--show-binds` and `--show-rows` apply to every comparison object.

</details>

Two recordings show the report. The first compares one SELECT with two candidates: the composite index with the columns in the wrong order reads the same rows (`200000 -> 200000`, `no-effect`), and `index.sql` reads `101` rows and becomes the `Recommendation`.

<img src="demo-candidates.gif" width="1200" alt="qenome --d1 DEMO_DB --batch candidates.json compares select.sql with a composite index and with index.sql: the composite index is no-effect at 200000 -> 200000 rows read, index.sql is improved at 200000 -> 101, and the Recommendation is index.sql">

The second applies `0002_reindex.sql`, which drops `ix_events_customer_id` and creates the composite index in its place: `select.sql` is `regressed` (`101 -> 200000`), `failed.sql` is `improved` (`101 -> 35`), and the run exits with status `6`.

<img src="demo-migration.gif" width="1200" alt="qenome --d1 DEMO_DB --batch queries.json --migration 0002_reindex.sql applies the migration to the variant copy: select.sql is regressed at 101 -> 200000 rows read, failed.sql is improved at 101 -> 35, and the shell reports exit=6">

Both recordings take their extra inputs from `docs/demo`, together with the `examples/d1-toml` sample.

## Index audit (--audit-indexes)

`qenome app.db --batch manifest.json --audit-indexes` reports the existing indexes that the manifest queries did not use, and the ones whose key columns another index or the primary key already covers. It reads the plan of every manifest query on one read-only copy; it does not build a variant and does not change the database. The manifest needs only `queries`, so a manifest from `--record` works as it is; `candidates` are ignored.

Qenome prints three lists:

| List | What it holds |
| --- | --- |
| `Unused in this manifest` | Indexes that no plan named. A partial index is marked, because another bound value can use it |
| `Redundant candidates` | Plain indexes whose key columns are a prefix of another index or of the primary key, with the same collation and sort order. `covered by` names that index; `INTEGER PRIMARY KEY` means the rowid primary key |
| `Kept for constraints` | UNIQUE and PRIMARY KEY indexes. They are not removal candidates |

An index can appear in both the unused and the redundant lists. The key columns come from `PRAGMA index_list` and `PRAGMA index_xinfo`. A partial index is never judged redundant, an expression index is not compared, and a different collation or ASC/DESC order is not treated as covered. A plain index is named in `Redundant candidates` only when another index or the primary key on the same table can serve the same lookups. When a manifest SELECT uses `INDEXED BY`, Qenome does not judge the redundancy list at all, so it cannot point at an index that the query forces.

The report is a statement about this manifest, not a recommendation to drop an index. The plans cover the SELECTs in the manifest only, so an index used by `UPDATE`, `DELETE`, foreign-key maintenance, or a query outside the manifest is not visible here. An index used only for `ORDER BY` or `GROUP BY` does appear in these plans. An index that SQLite did not pick can still be one it could use.

The run exits `0` when the report is written, even when the lists are not empty. With `--d1` the JSON report adds a `warnings` array, and the human report a `Warnings` section, for `unapplied_migrations`; it does not change the findings or the exit status. Read stdout, not the exit status, to find indexes. `--audit-indexes` needs `--batch` and does not take `--suggest`, `--migration`, or `--seed-data`; it takes `--d1`, `--timeout-ms` (for each plan and each catalog read), and `--format human` (default) or `--format json`. With JSON the output is the `audit_schema_version` 1 object described in [docs/json.md](json.md).

## Recording the queries your app runs (--record)

A hand-written manifest misses the queries an ORM builds, and nothing tells you what is missing. `qenome/d1` records the SELECTs and bind values that the app actually runs against a local D1, and `--record` turns that log into a manifest. Use it only during local development and tests.

1. Add `qenome` as a development dependency.

```sh
npm install -D qenome
```

1. In the test or development Worker entry, wrap the D1 binding with `wrapD1`. This one line is the only change to the app.

```js
import { wrapD1 } from "qenome/d1";

export default {
  async fetch(request, env) {
    const db = wrapD1(env.DB);
    const { results } = await db
      .prepare("SELECT id FROM events WHERE customer_id = ?")
      .bind(1234)
      .all();
    return Response.json(results);
  },
};
```

1. Run the app and keep its output in a new file. `umask 077` keeps the recorded SQL and bind values readable only by you.

```sh
(umask 077; npx wrangler dev --local 2>&1 | tee qenome-record.log)
```

The same works for tests; make the test runner print `console.log` output.

```sh
(umask 077; npx vitest run 2>&1 | tee qenome-record.log)
```

1. Build the manifest. `--out` must name a new directory.

```sh
npx qenome --record qenome-record.log --out qenome-manifest
```

`--out` gets `manifest.json` and SQL files such as `queries/q001.sql`. The directory is created with mode `0700` and the files with `0600`, and stdout never holds a bind value. The manifest does hold the values, so do not commit it, and delete the record log once the manifest exists.

1. Rank the manifest when you do not yet know which query reads the most, or compare it, or audit the indexes it uses. It holds only `queries`. `--record` also writes `executions` on each query, the number of times that statement ran.

```sh
npx qenome --d1 DB --batch qenome-manifest/manifest.json --rank
npx qenome --d1 DB --batch qenome-manifest/manifest.json --suggest
```

Add `candidates` to `manifest.json` when you have your own.

How `--record` works:

- The same SQL becomes one entry. SQL that differs only in whitespace outside strings and comments counts as the same, and the first execution supplies the bind values. stdout shows how many times each statement ran.
- `INSERT`, `UPDATE`, `DELETE`, and `REPLACE` are not put in the manifest; only their count is reported. `exec` and statements that bind a BLOB, a boolean, or text with a NUL are skipped too, because `--bind` cannot express those values. The `skipped:` line names each reason and count.
- More than 100 distinct SELECTs, a manifest over 1 MiB, a SQL statement over 1 MiB, or a log over 16 MiB stops the run before `--out` is created.
- `--record` needs no database and cannot be combined with `--db`, `--d1`, `--batch`, `--migration`, `--suggest`, `--seed-data`, `--bind`, `--runs`, or the other comparison options. It takes `--format human` (the default) or `--format json`, and `--n-plus-one-threshold N`.

`--record` also points at the queries that the app ran many times with the same shape and only different values, which is the N+1 pattern:

```text
repeated shapes:
  queries/q002.sql  shape: 50 executions, 50 different values, longest run 50 (possible N+1; fetch the rows in one query with IN (...) or a JOIN, or send the statements with db.batch())
```

A shape ignores the values, not the statement: `WHERE post_id = ?`, `= ?1`, `= :id`, `= 17` and `= 'a'` are one shape, `IN (?, ?)` and `IN (?, ?, ?)` are one shape, and a different column, table, or operator is another shape. A shape is reported when at least 10 different values ran with it; `--n-plus-one-threshold N` changes that (2 to 1,000,000) and `0` turns the report off. At most 20 shapes are reported, ordered by different values, then executions, and the block says how many it dropped. A loop of `INSERT` or `UPDATE` is reported too, with a write hint, and records from `db.batch()` do not count toward the threshold, because they are already one round trip; when a reported shape also ran in a batch, the line says how many (`20 batched`). `repeated shapes: none` means that nothing passed the threshold. With `--format json` the same facts are one object with `record_schema_version` 1, and its `repeated_shapes` array holds the values above plus `batched`, `previous_shape_example`, `manifest_select` (the `queries/qNNN.sql` entry of the shape), and `hint`; [docs/json.md](json.md) describes every key. Neither form prints a bind value.

The report is a hint about round trips and repeated work, not a measurement: it does not change a row count, a timing, the manifest, or the exit status.

Recording is for local development and tests only. The wrapper writes the SQL and the bind values to its output, so do not ship it to production. SQL inside `withSession` and Durable Objects is not recorded.

## Ranking queries on the baseline (--rank)

`qenome app.db --batch manifest.json --rank` measures every SELECT in the manifest on the baseline copy only and prints them in rank order. Use it when a missing index may be reading far more rows than the query returns, and you do not yet have a candidate `CREATE INDEX`. A manifest from `--record` works as it is. A hand-written manifest needs only `queries`. `candidates` and `writes` are ignored, so an existing comparison manifest can be ranked without editing it.

```sh
qenome app.db --batch manifest.json --rank
qenome --d1 DB --batch qenome-manifest/manifest.json --rank --format json
```

Each query runs once. The report gives rows read, rows returned, the rows-read / rows-returned ratio (`n/a` when the query returns no rows), full-scan steps, and the plan steps that are a table `SCAN` (a `SCAN` that does not say `USING`). A `SCAN` of a co-routine (a name that the plan's own `CO-ROUTINE` line declares, so a materialized subquery or a CTE), of a constant row set, or of a `VALUES` clause is not a table `SCAN`. A query is a likely full scan when the full-scan counter is above zero or one of those table `SCAN` steps is present. The human report marks it with `flag: likely full scan`.

The order is the weight, highest first: `rows read` multiplied by `executions` when the query has that count, otherwise `rows read` alone. A likely full scan, then a higher ratio, then manifest order, break ties. `rows read x runs` is a relative indicator, not a bill. The report says that in the `note` line and on each weighted row. Nothing in the report is a charge.

The last line names the top query for the next step: `qenome <DB> <that SELECT> --suggest`. The path is the `select` string from the manifest, relative to the manifest file.

Exit status `0` means the report was written and no query is a likely full scan. Exit status `7` means the report was written and at least one query is. A rejected SELECT, a bad manifest, or a usage error still exits `1` or `2` with empty stdout. A time limit exits `124`. Cleanup failure replaces `0` with `5` and leaves `7` as it is. `--rank` needs `--batch`. It takes `--d1`, `--seed-data`, `--timeout-ms`, and `--format human` or `json`. It does not take `--suggest`, `--migration`, `--audit-indexes`, `--runs`, or `--format kv`.

`--format json` writes one object with `schema_version` 2 and `rank_schema_version` 1. The comparison object is unchanged. [docs/json.md](json.md#baseline-rank-rank_schema_version-1) lists the keys.

## Suggesting candidate indexes

`--suggest` has SQLite's expert (sqlite3expert, built from the vendored SQLite source) propose candidate indexes, then compares them with the same batch machinery. You do not need an index file.

```sh
qenome app.db select.sql --suggest
qenome --d1 DB select.sql --suggest --bind 1:int:1234
qenome app.db --batch batch.json --suggest
```

With one SELECT file, the SELECT becomes one batch query and `--bind` applies to it. With `--batch`, the proposals join the manifest candidates, which may be omitted or empty. `--suggest` does not take `--runs`, `--format kv`, or an index file.

Qenome opens a second read-only connection to the baseline copy and sets the expert sampling to `0`, so the expert reads the schema only. Every checked SELECT is passed to it. Before the expert starts, every `sqlite_schema` row is checked: each must be one statement and start with `CREATE TABLE`, `CREATE INDEX`, `CREATE UNIQUE INDEX`, `CREATE VIEW`, `CREATE TRIGGER`, or `CREATE VIRTUAL TABLE`, and none may use the `expert` virtual table. A database that fails this check is rejected with `suggest_schema_rejected` (exit `1`, empty stdout), even when the manifest has candidates. While the expert runs, a temporary guard is installed on the connections it opens: `ATTACH` and `DETACH` are denied, only the `index_list` and `index_xinfo` PRAGMAs are allowed, and the attached-database limit is `0`. After the expert object is created, the expert installs its own authorizer on its analysis copy; the attached-database limit stays in force there. Qenome removes the guard after the expert is destroyed. If the guard cannot be installed, Qenome stops before calling the expert. Together they keep a crafted schema from creating or changing another database file. The `CREATE INDEX` statements in its report are split with SQLite's own statement parser, so a `;` inside a quoted name does not split one. Each proposal passes the same check as a manifest candidate and is dropped with a `suggestion_rejected` warning when it fails. Labels are `suggested:1`, `suggested:2`, …; at most 20 proposals are compared, and at most 100 candidates with the manifest entries.

The output is the batch report. Each `summary` entry adds `source` (`manifest` or `suggested`) and `index_sql_text`, and the top-level `warnings` array lists what was dropped or could not be done. Each `results[].comparison` keeps the comparison `warnings`, including `bind_dependent_partial_index`; the batch top-level `warnings` stays for `--suggest`. The `human` report lists each candidate warning with its candidate and each comparison warning with its query and candidate.

| Warning `code` | Meaning |
| --- | --- |
| `suggest_query_skipped` | SQLite could not analyze one SELECT; the other SELECTs continue |
| `suggestion_rejected` | A proposal failed the `CREATE INDEX` check |
| `suggestions_truncated` | The 20 or 100 limit dropped the tail of the proposals |
| `no_suggestions` | SQLite proposed nothing, and the manifest candidates were still compared. This is a warning, not a failure |
| `suggest_failed` | The expert could not start or analyze. With manifest candidates, those were still compared. With none, the run stops |

When the expert runs and proposes nothing because the current plan already needs no index, the run exits `0`. Human output starts with `no index needed` and lists each query's plan and rows read. JSON is a `schema_version` 2 object with `index_needed` false, `result` `no_index_needed`, `verdict` `no-effect`, `baseline` set to the current plan and counters, and `variant` null. `queries` lists every measured query. These fields are additions; `schema_version` stays 2.

When a suggestion cannot be produced, the run still exits `1` with empty stdout. A query that cannot be prepared is `batch_baseline_failed`. A query the expert cannot analyze, with no manifest candidate left, is `suggest_failed`. Every proposal that fails the `CREATE INDEX` check is `no_candidates`. `no_suggestions` is only the warning used when manifest candidates remain.

Qualifying candidates are ordered by fewer rows read, then by removing a sort (`USE TEMP B-TREE` on the baseline plan and not on the variant), then by a smaller index, then by input order. A bind-dependent partial index warning is still reported and does not change this order.

A proposal weighs the same as a manifest candidate in the exit status and in the recommendation. The proposals are a starting point, not a verdict: the result rows, the rows read, and the exit status still come from the real comparison.

Use `--suggest` to find candidates. For a CI gate, compare a named index without `--suggest`, so that a change in SQLite's advice cannot change the build. The batch report keeps `batch_schema_version` `1`; `source`, `index_sql_text`, and `warnings` are additions.
