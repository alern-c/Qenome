# My D1 bill spiked: find and fix the missing index

A jump in rows read is often one statement scanning a table. This page finds that statement on a local copy, asks SQLite for one index, and gates the migration so it cannot regress another query. Qenome does not read a Cloudflare bill, and a green run here does not lower one. `rows read x runs` is a relative indicator, not a bill. [Accuracy and production D1](accuracy.md) explains how these numbers can differ from production D1.

The commands below were run from the repository root with the built `qenome` on the fixture in `testdata/accuracy/rank-full-scan-above-indexed` (200 rows in `events`, an index on `customer_id`, none on `note`). The database, the log, and the manifest live under `testdata/generated/bill-spiked/`, which is not committed. The manifest holds bind values. Do not commit it.

The same `--batch`, `--rank`, `--suggest`, and `--migration` flags accept `--d1 <BINDING>` in place of a database path. That form is documented in [Check a local D1](local-d1.md). The run below uses a database file.

## Spot the jump

D1's own rows-read metric is a billing input. These Cloudflare pages are the source for where to look. This guide adds no dashboard steps beyond what those pages describe.

- Per database, [Metrics and analytics](https://developers.cloudflare.com/d1/observability/metrics-analytics/) says: in the Cloudflare dashboard, open the D1 page, select the database, then the Metrics tab. `rowsRead` is the count of rows scanned. The time window defaults to the last 24 hours.
- For the account, [Billing](https://developers.cloudflare.com/d1/observability/billing/) says: open Billing, then Billable Usage. That history is kept for at most 30 days.
- [Pricing](https://developers.cloudflare.com/d1/platform/pricing/) defines rows read as rows a query scans. [Find slow and expensive queries](https://developers.cloudflare.com/d1/observability/find-expensive-queries/) is the longer walkthrough on that site.

The metrics page also documents `wrangler d1 insights`. It is experimental, it reads remote D1, and an API token needs the Account Analytics Read permission. It was not run on this fixture. The invocation this repository already documents, which matches that page, is:

```sh
npx wrangler d1 insights <database> --sort-by=reads --sort-type=avg --time-period=7d --json
```

`<database>` is the database name, binding, or id. Omit it to list queries across the account; each row then includes `databaseId`. Do not paste an account id or a database id into a guide or a commit. The command groups by query text and does not return bind values. `avgRowsRead` is an average over the period, not Qenome's `rows_read` for one value. See [How to check against production yourself](accuracy.md#how-to-check-against-production-yourself).

## Record the queries

Insights names the SQL text. Qenome also needs the bind values, in a manifest. `qenome/d1` records both from a local D1. The Worker steps are in [Recording the queries your app runs (--record)](batch.md#recording-the-queries-your-app-runs---record). Use the wrapper only for local development and tests, and do not ship it to production.

The run below calls the same `wrapD1` on a stand-in database, so the later commands have a manifest. It runs the unindexed statement 40 times and the indexed statement once. `umask 077` keeps the log readable only by you.

```sh
rm -rf testdata/generated/bill-spiked
mkdir -p testdata/generated/bill-spiked
sqlite3 testdata/generated/bill-spiked/app.db < testdata/accuracy/rank-full-scan-above-indexed/schema.sql
(umask 077; node --input-type=module <<'EOF' > testdata/generated/bill-spiked/record.log
import { wrapD1 } from "./npm/qenome/lib/d1.mjs";
const db = wrapD1({
  prepare(sql) {
    const statement = {
      bind() { return statement; },
      async all() { return { results: [] }; },
    };
    return statement;
  },
});
const scan = "SELECT note FROM events WHERE note = 'missing'";
const lookup = "SELECT note FROM events WHERE customer_id = ?";
for (let i = 0; i < 40; i++) await db.prepare(scan).all();
await db.prepare(lookup).bind(1).all();
EOF
)
qenome --record testdata/generated/bill-spiked/record.log --out testdata/generated/bill-spiked/manifest
```

That run exited 0 and printed:

```text
record: 41 record lines
manifest: testdata/generated/bill-spiked/manifest/manifest.json
queries: 2 distinct read-only statements (41 executions)
  queries/q001.sql  40 executions
  queries/q002.sql  1 execution
repeated shapes: none
skipped: none
warning: the manifest holds bind values; keep it local and do not commit it
```

`executions` is how many times that statement ran. Comparison modes ignore it. `--rank` multiplies rows read by it. The published import is `qenome/d1`; the script above loads the copy in this repository.

## Rank the manifest

```sh
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --rank
```

Exit status 7: the report was written, and at least one query is a likely full scan. Exit 0 would mean none were. The `work-dir-parent` line is the sandbox parent on the machine that ran the command and is omitted here. The rest is what this run printed:

```text
baseline rank: 2 queries
database: testdata/generated/bill-spiked/app.db
sqlite: 3.53.4
likely full scans: 1
note: rows read x runs is a relative indicator, not a bill

#1  queries/q001.sql
  flag: likely full scan
  rows read: 200
  rows returned: 0
  rows read / rows returned: n/a
  fullscan steps: 199
  scan: SCAN events
  runs: 40
  rows read x runs (not a bill): 8000

#2  queries/q002.sql
  rows read: 2
  rows returned: 1
  rows read / rows returned: 2
  fullscan steps: 0
  scan: none
  runs: 1
  rows read x runs (not a bill): 2

next: qenome <DB> queries/q001.sql --suggest
```

`8000` is 200 rows read times 40 runs. It orders the list. It is not a charge. The `next` path is relative to the manifest file. See [Ranking queries on the baseline (--rank)](batch.md#ranking-queries-on-the-baseline---rank).

## Suggest an index

```sh
qenome testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/manifest/queries/q001.sql --suggest
```

Exit status 0. This run printed `CREATE INDEX events_idx_000160d6 ON events(note);`, `Recommendation: suggested:1`, and `improved` with `200 -> 0`. Under `Warnings` it printed:

```text
  suggested:1: data_too_small: The candidate index table has fewer than 1000 rows. This heuristic does not establish representative performance; test with more representative data.
```

`events` has 200 rows. The warning does not change the verdict or the exit status. Copy the `CREATE INDEX` line from your own `Suggested by SQLite` section into a migration file. For a CI gate, compare that file without `--suggest`, so a later change in SQLite's advice cannot change the build. See [Suggesting candidate indexes](batch.md#suggesting-candidate-indexes).

On this branch, any fewer rows read is `improved`. [PR #142](https://github.com/alern-c/Qenome/pull/142) is not merged and is not in this branch. It would require at least 1% fewer rows, and a smaller drop would be `no-effect`. `200 -> 0` is above that bar.

`queries/q002.sql` already uses `idx_events_customer`. This run of `--suggest` with `--bind 1:int:1` exited 1 and wrote nothing to stdout. stderr was:

```text
error: no candidate index to compare: SQLite suggested no index for these queries
hint: Check that the SELECT has a WHERE or ORDER BY clause, or write a candidate CREATE INDEX file and compare it without --suggest.
```

That error is `no_candidates`. [PR #143](https://github.com/alern-c/Qenome/pull/143) is not merged and is not in this branch. When the current plan already needs no index, it would exit 0 and start the report with `no index needed`. It would also accept `--sql` and a SELECT path of `-` for stdin. This page uses a SQL file, which this branch accepts.

## Gate the migration

Save the suggested statement. This run wrote `testdata/generated/bill-spiked/0002_note.sql` and compared it:

```sh
printf '%s\n' "CREATE INDEX events_idx_000160d6 ON events(note);" > testdata/generated/bill-spiked/0002_note.sql
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --migration testdata/generated/bill-spiked/0002_note.sql
```

Exit status 0. `queries/q001.sql` was `improved` (`200 -> 0`). `queries/q002.sql` was `no-effect` (`2 -> 2`). `Recommendation:` named the migration file. The original database was not changed.

A migration that makes any listed query read more rows is `regressed`, and the batch exits 6. Dropping the index the second query uses does that:

```sh
printf '%s\n' "DROP INDEX idx_events_customer;" > testdata/generated/bill-spiked/drop_customer.sql
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --migration testdata/generated/bill-spiked/drop_customer.sql
```

Exit status 6. `queries/q002.sql` was `regressed` (`2 -> 200`). `queries/q001.sql` was `no-effect` (`200 -> 200`). `Recommendation:` was `none`. Point CI at the migration you intend to merge, and fail the job on exit 6. The rules are in [Batch comparisons](batch.md#batch-comparisons).

`--rank` does not take `--migration`. To rank the schema after the index, this run copied the database, applied `0002_note.sql` to the copy, and ranked the copy:

```sh
cp testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/indexed.db
sqlite3 testdata/generated/bill-spiked/indexed.db < testdata/generated/bill-spiked/0002_note.sql
qenome testdata/generated/bill-spiked/indexed.db --batch testdata/generated/bill-spiked/manifest/manifest.json --rank
```

Exit status 0. `likely full scans: 0`. `queries/q001.sql` read 0 rows.

## Check again after deploy

After the migration is on the remote database, read the same metrics again. [How to check against production yourself](accuracy.md#how-to-check-against-production-yourself) says to run `d1 insights` for the same period length and compare `avgRowsRead`. Traffic changes between the two periods, so a lower average is a check. It is not proof that the index caused the change, and it is not proof that the bill went down.

## When the local table is too small

Two hundred rows still show `flag: likely full scan`, and the comparison can say `improved`, while the absolute count stays small. That hides what the same scan costs on a larger table. `data_too_small` means the candidate's table has fewer than 1,000 rows. On this branch the warning text does not name a follow-up command, and it does not change the verdict. [PR #145](https://github.com/alern-c/Qenome/pull/145) is not merged and is not in this branch. It would keep the verdict and add a suggested `--seed-data` and `--scale` command to the report.

`--scale` already works here. It does not combine with `--suggest`, `--batch`, or `--rank`, so the index has to be a file first. The seed replaces `events` in the sandbox copy only. Every seeded `note` is `n`, and the query looks for `missing`, so the scan still reads every row and the index reads none.

```sh
cat > testdata/generated/bill-spiked/seed.json <<'EOF'
{
  "seed": 7,
  "tables": {
    "events": {
      "rows": 100,
      "columns": {
        "id": { "kind": "sequence" },
        "customer_id": { "kind": "sequence" },
        "note": { "kind": "fixed", "value": "n" }
      }
    }
  }
}
EOF
qenome testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/manifest/queries/q001.sql testdata/generated/bill-spiked/0002_note.sql --seed-data testdata/generated/bill-spiked/seed.json --scale 100,10000 --runs 0
```

Exit status 0. The `work-dir-parent` line is omitted, as above. This run printed:

```text
scale: 100, 10,000 rows in 2 steps
database: testdata/generated/bill-spiked/app.db
select: testdata/generated/bill-spiked/manifest/queries/q001.sql
index: testdata/generated/bill-spiked/0002_note.sql
seed-data: testdata/generated/bill-spiked/seed.json
sqlite: 3.53.4

Steps
          rows baseline read variant read   ratio  verdict     result       plan    median
           100           100            0 0.0000x  improved    match        changed -
        10,000        10,000            0 0.0000x  improved    match        changed -

Warnings
  warning at 100 rows: data_too_small: The candidate index table has fewer than
    1000 rows. This heuristic does not establish representative performance;
    test with more representative data.

note: these rows come from generated data measured on this machine; they are not
production D1 billing.
```

At 100 rows the baseline reads 100 and `data_too_small` is present. At 10,000 rows the baseline reads 10,000 and that warning is gone. The verdict stays `improved`. The closing note is the report's own line: the rows are generated data measured on this machine, and they are not production D1 billing. See [Generating sandbox data](usage.md#generating-sandbox-data) and [Measuring at several sizes (--scale)](usage.md#measuring-at-several-sizes---scale).
