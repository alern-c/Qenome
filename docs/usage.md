# Usage

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
qenome app.db select.sql index.sql --seed-data seed.json
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000
qenome app.db --write update.sql --index-sql index.sql
qenome --d1 DB select.sql index.sql
qenome app.db --batch batch.json
qenome app.db --batch batch.json --audit-indexes
qenome app.db --batch batch.json --migration 0002_replace_index.sql
qenome app.db select.sql --suggest
qenome app.db --batch batch.json --suggest
qenome --record qenome-record.log --out qenome-manifest
```

The three paths fill the roles in this order: database, SELECT (or write) file, CREATE INDEX file. Each role can also be given with `--db`, `--select`/`--write`, or `--index-sql`, and the two forms can be mixed; a positional path fills the first role that is still empty. With `--d1`, the two positional paths fill the SELECT and CREATE INDEX roles. With `--write`, a positional path fills the write file instead of the SELECT file. After `--`, every argument is treated as a path, including paths that start with `-`.

`select.sql` holds one read-only `SELECT`; `index.sql` holds one candidate `CREATE INDEX`. Qenome rejects multiple statements and any other statement. A `--migration` file is the one exception: it may hold several `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE`, and `ALTER TABLE` statements; see [Batch comparisons](batch.md#batch-comparisons).

`--write` takes the place of `--select` and holds one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` (a leading `WITH` and a trailing `RETURNING` are allowed). It does not take `--batch`, `--migration`, or `--suggest`. The statement runs in a transaction on each copy and is rolled back, so the original database is never changed and every `--runs` round starts from the same rows.

- `--db <PATH>`: the SQLite database to read (required, once; not with `--d1`)
- `--d1 <BINDING>`: the local D1 database of this `d1_databases` binding in a wrangler config, instead of `--db`. See [D1 local databases](#d1-local-databases)
- `--config <PATH>`: the wrangler config for `--d1` (default: `wrangler.toml`, `wrangler.jsonc`, or `wrangler.json` in the current directory)
- `--select <FILE>`: a file holding the one `SELECT` to compare (required, once; not with `--write`)
- `--write <FILE>`: a file holding one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` to compare instead of a `SELECT`; it runs in a transaction on each sandbox copy and is rolled back. See [Comparing a write](#comparing-a-write). It cannot be combined with `--select`, `--batch`, `--migration`, or `--suggest`
- `--index-sql <FILE>`: a file holding the one candidate `CREATE INDEX` (required, once)
- `--batch <FILE>`: compare every SELECT in a JSON manifest with every candidate `CREATE INDEX` in one run; see [Batch comparisons](batch.md#batch-comparisons). It cannot be combined with `--select`, `--index-sql`, `--bind`, positional SELECT or INDEX paths, `--runs`, or `--format kv`
- `--audit-indexes`: with `--batch`, report the indexes that no manifest query plan used and the indexes whose leading columns another index or the primary key covers, and keep the UNIQUE and PRIMARY KEY indexes in a separate list; the manifest needs only `queries`, and `candidates` are ignored. It needs `--batch` and cannot be combined with `--suggest`, `--migration`, or `--seed-data`. See [Index audit (--audit-indexes)](batch.md#index-audit---audit-indexes)
- `--record <FILE>`: read the records that `qenome/d1` wrote and write a manifest without candidates to `--out`; no database is needed. The manifest holds bind values, so keep it local and do not commit it. Use it with `--out`; it cannot be combined with `--db`, `--d1`, `--select`, `--write`, `--index-sql`, `--batch`, `--migration`, `--seed-data`, `--bind`, `--runs`, `--suggest`, or `--format kv`. It takes `--format human` (default) or `--format json` and `--n-plus-one-threshold N`. See [Recording the queries your app runs (--record)](batch.md#recording-the-queries-your-app-runs---record)
- `--out <DIR>`: the new directory for `--record`. It must not exist. The directory is created with mode `0700` and its files with `0600`
- `--migration <FILE>`: apply this SQL file to the variant only before the `--batch` queries run. It needs `--batch` and a manifest without `candidates`; it cannot be combined with `--select`, `--index-sql`, `--bind`, `--runs`, `--suggest`, or `--format kv`. `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (a column list, not `AS SELECT`), and `ALTER TABLE` (ADD / RENAME / DROP COLUMN and RENAME TO) are accepted; data changes, `DROP TABLE`, `ATTACH`, `PRAGMA`, and other statements are rejected with the statement number. A query that uses a column or table the migration drops or renames cannot run on the variant, so the whole run stops with exit `1`; a `SELECT *` cannot be compared after a column is added or dropped, so list the columns you need. See [Batch comparisons](batch.md#batch-comparisons)
- `--seed-data <FILE>`: replace the tables listed in this JSON spec with deterministic dummy rows in the sandbox copy before comparing; the original database is not changed. It works with every mode, including `--batch`, `--suggest`, and `--migration`. See [Generating sandbox data](#generating-sandbox-data)
- `--scale <ROWS,ROWS[,ROWS]>`: with `--seed-data`, compare at 2 or 3 strictly increasing row counts in one run and show the results side by side; each step seeds a fresh sandbox copy at that size. The largest table in the spec gets the step size, and the other tables scale with it. It cannot be combined with `--batch`, `--suggest`, `--migration`, `--audit-indexes`, `--record`, or `--format kv`. See [Measuring at several sizes](#measuring-at-several-sizes---scale)
- `--suggest`: ask SQLite's expert for candidate indexes instead of naming one, and compare the proposals. With `--batch`, the manifest may omit `candidates`. It cannot be combined with `--runs`, `--format kv`, or an index file (`--index-sql` or a third positional path). See [Suggesting candidate indexes](batch.md#suggesting-candidate-indexes)
- `--bind <N>:<TYPE>[:<VALUE>]`: a typed value bound to parameter `N`; repeatable. `N` is SQLite's parameter number: named parameters share the number of their first appearance, and `?NNN` uses `NNN`. `TYPE` is `int`, `real`, `text`, or `null` (null takes no value). Every number in `1..parameter count` must be given exactly once, and a `SELECT` without parameters takes no `--bind`. The value is the rest of the argument, so text may contain `:`.
- `--runs <N>`: timed rounds after the results match; each round adds two baseline A/A executions and times the `SELECT` once per copy. The default is `10`; `0` skips the timing but keeps the row counts and the verdict; the maximum is `1000`. A timing that takes longer than a second reports its progress on stderr. With `--write`, `N` is the number of rolled-back executions per copy (at least one), no timing runs, and every execution must report the same counts.
- `--timeout-ms <MS>`: time limit for building the index, for each `SELECT` run, and for each `--write` execution; the default is `30000`; `0` disables the limit. The comparison and timing can take the database copy plus `(3 + 4 × runs)` time limits, with additional bounded diagnostic statements (the ANALYZE and size checks, and when the SELECT has parameters the bind-dependent partial index check) each using the same timeout.
- `--format <human|kv|json>`: output format (default `human`). See [Output formats](output.md#output-formats).
- `--show-binds`: print the bind values. Without it, `human` leaves the binds out, and `kv` and `json` print only their numbers, types, and text lengths, so the values stay out of logs.
- `--show-rows`: print the example rows that only one copy returned. Without it, every format prints only the counts, so row values stay out of logs; `human` says to rerun with this flag.
- `--help`, `-h`: print the usage and exit with status 0.
- `--version`: print the version from `build.zig.zon` as `qenome <version>` and exit with status 0.

Options that take a value can also be written as `--db=app.db`.

Qenome opens the database read-only and copies it, through SQLite's backup API, into a private directory under `$TMPDIR` (default `/tmp`) on Linux and macOS, or under the first of `%TMP%`, `%TEMP%`, and `%USERPROFILE%` that is set on Windows. The copy is the baseline; a second copy becomes the variant, and the candidate index is built only on the variant. With `--seed-data`, Qenome fills the baseline with the spec's rows before it makes the variant, so both copies hold the same dummy data. The `SELECT` runs on both copies, and the result rows are compared as a multiset: each distinct row must appear the same number of times. Row order is reported as a reference and is not part of the match.

The rows read and the rows written come from that first run on each copy, so they cost no extra work and stay available with `--runs 0`. When the rows match and `--runs` is not `0`, the `SELECT` is timed again as a reference. Each copy gets one warm-up run whose rows were compared and that is not timed. The timed rounds alternate baseline-variant and variant-baseline (ABBA). A round times `sqlite3_step` from the reset statement to `SQLITE_DONE`, including the interrupt checks; it does not read columns and does not time prepare, bind, or the plan read. The cache is warm, since each copy reuses its connection and page cache after its file was just written. The private directory is removed before exit, whatever the result. In `--write`, each run is a real measured run inside its own transaction and rollback, and there are no timed rounds.

On Linux and macOS the directory is created so that only its owner can access it (`0700`). Windows has no equivalent setting, so the directory inherits the access control of the temporary folder, and its protection depends on that folder being private to the user. Qenome removes the directory when it receives Ctrl+C or Ctrl+Break on Windows, and SIGINT, SIGTERM, or SIGHUP on Linux and macOS. A forced termination, such as closing the console window or killing the process, can leave the copies behind.

The verdict comes from the rows read, and it never changes the exit status.

Rows read and rows written use the same counting as local D1 (workerd patch): Qenome builds the bundled SQLite with Cloudflare's row-count patch from `workerd`. The numbers have not yet been checked against production D1. Both counters are 32-bit: each wraps past 4,294,967,295 of its own count, so a SELECT that goes past that in one run reports a wrapped number, and the verdict compares the numbers as they were read. `NOTICE` records where the patch comes from, and `vendor/sqlite3/PROVENANCE.txt` records how to apply it again.

## Comparing a write

`--write write.sql --index-sql index.sql` compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` before and after the candidate index. A leading `WITH` and a trailing `RETURNING` are allowed; `CREATE`, `DROP`, `ALTER`, `PRAGMA`, `ATTACH`, `VACUUM`, and multiple statements are rejected. The statement is prepared with the same authorizer as the SELECT mode, so only writes to the main schema and reads, functions, and common table expressions are allowed.

The original database is opened read-only and copied as usual. On each copy, Qenome starts a transaction, runs the statement, reads the counters, changes, and `RETURNING` rows, and rolls the transaction back. The next `--runs` round starts from the same rows. The write connections are on the sandbox copies only and enable SQLite's foreign keys (`PRAGMA foreign_keys=ON`), so a `ON DELETE CASCADE` or `SET NULL` action is counted and rolled back with the statement. Triggers are active and their writes are counted too. A rollback failure stops the comparison; Qenome never tries to repair the sandbox.

Both copies must make the same change. Qenome compares three facts: the multiset of `RETURNING` rows (empty without `RETURNING`), `sqlite3_changes` (the rows the statement itself changed), and the difference of `sqlite3_total_changes` (which also counts trigger and foreign-key changes). A difference is a result mismatch (exit status `3`) and is not judged from the row counts.

`--runs` has a different meaning in this mode: it is the number of rolled-back executions per copy, at least one. The first execution supplies the reported counts. If a later execution reports different counters or changes, the write is not repeatable from the same rows, so the comparison is `incomparable` (exit status `4`) with the reason. `--runs 0` still runs once. There is no timing loop, so `timing` is `null` and the `time` line says it is not timed.

The statement is not run when it calls a function whose result changes between runs (`random()`, `randomblob()`, `changes()`, `last_insert_rowid()`, `total_changes()`), reads the current time (`date()`, `datetime()`, `julianday()`, `strftime()`, and the other time functions), or reads a schema table (`sqlite_schema`, `sqlite_master`, or a `sqlite_stat*` table). The last case includes a trigger that reads the schema. Those comparisons are `incomparable` (exit status `4`) and say that the write was not run. A `RETURNING` clause is compared as rows, so it can be used to check which rows the write touched.

Rows written use the same local D1 (workerd patch) counting as the SELECT mode. The counter includes the table row and each secondary-index insert, trigger insert, and foreign-key cascade. The bundled patch does not count secondary-index deletes: a `DELETE` or an `UPDATE` that removes an old index entry reports the table change but not the index removal. A `DELETE ... WHERE` can therefore show fewer rows read with the same rows written. Treat the write count as the part the patch measures, not as the full cost of index maintenance.

`--write` works with `--d1`, `--seed-data`, `--bind`, `--timeout-ms`, `--show-binds`, `--show-rows`, and every output format. It does not work with `--batch`, `--migration`, or `--suggest`; those modes keep their SELECT-only input and reject `--write` with a usage error.

## Generating sandbox data

`--seed-data spec.json` fills the sandbox copy with deterministic dummy rows before the comparison, so an empty or small local database can still show what an index would read. The original database is opened read-only and is never changed. The rows go into the baseline copy, and that copy becomes the variant too.

The spec is one JSON object. `tables` maps a table name to its `rows` and optional `columns`. A column that you leave out takes its SQLite default or the rowid; a default must be a literal value, and a column with an expression default must be listed in the spec so the generated rows are reproducible. `seed` is optional and defaults to `0`.

```json
{
  "seed": 7,
  "tables": {
    "events": {
      "rows": 50000,
      "columns": {
        "id": { "kind": "sequence" },
        "customer_id": { "kind": "sequence" },
        "status": { "kind": "ratio", "value": "ok", "ratio": 0.5, "otherwise": "failed" },
        "note": { "kind": "fixed", "value": null }
      }
    }
  }
}
```

Each column has one `kind`:

| `kind` | Keys | Meaning |
| --- | --- | --- |
| `fixed` | `value` | the same value on every row |
| `uniform` | `values` | one of the values, with the same chance each |
| `ratio` | `value`, `ratio`, optional `otherwise` | `value` on the given fraction of rows (`0` to `1`), and `otherwise` (default `null`) on the rest |
| `sequence` | optional `from` (default `1`), optional `step` (default `1`) | an integer that increases by `step` on each row |

A JSON string becomes TEXT, an integer INTEGER, a number with a fraction REAL, `true` / `false` 1 / 0, and `null` NULL. The tables in the spec are emptied first, so their row count is exactly `rows`; tables you do not list are left as they are. Qenome rejects a listed table with a trigger, because the trigger could change another table or produce values that the seed does not control, and it rejects table or column names that differ only by case. The spec is limited to 100 tables, 10,000,000 rows per table, and 20,000,000 rows in total. `--seed-data` works with every mode, including `--batch`, `--suggest`, and `--migration`.

The same spec and `seed` give the same rows on every run, so a reported comparison can be repeated. Values are inserted in one transaction, and Qenome then runs `ANALYZE` on each listed table in that transaction, so the planner sees statistics for the generated rows and `no_analyze_stats` does not apply to them. A constraint violation such as a PRIMARY KEY, UNIQUE, NOT NULL, or CHECK violation stops the run with exit status `1` and the SQLite message, even when the table declares `ON CONFLICT IGNORE` or `ON CONFLICT REPLACE`. Foreign keys are not checked on the sandbox copy, which is the SQLite default, so the tables may be listed in any order. Seeding is not limited by `--timeout-ms`; Ctrl+C stops it and removes the copy. The dummy rows live only in the private copy, which is removed before exit.

The human Summary adds `seed data` and `seed` lines; `kv` adds `seed-data`, `seed`, `seed-rows`, `seed-tables`, and one `seed-table` line per table; `json` adds a top-level `seed_data` object with `path`, `seed`, `rows`, and `tables`.

## Measuring at several sizes (--scale)

When the candidate table has fewer than 1,000 rows, the human Summary says so on the `data` line and the `next` line is the command to run next. A full scan of that table reads every row, so a small `rows_read` does not mean a missing index is harmless. Write a seed spec that lists the table, then rerun:

```sh
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000 --runs 0
```

The paths are the ones from this run. `--suggest` and `--batch` print the same note under `Recommendation:`; save a suggested index as `index.sql` and rerun that one comparison, because `--scale` does not combine with those modes. The JSON warning adds `table`, `rows`, `full_scan`, and `next_command` and keeps `schema_version` `2`. See [Accuracy and production D1](accuracy.md#what-the-verdicts-mean).

`--scale 1000,10000` runs the same comparison at 2 or 3 row counts and shows the results side by side, so you can see whether an improvement still holds when the table is larger. It needs `--seed-data`, because the seed spec is the only input that describes the distribution of the data separately from its size. Each step sets the row count of the largest table in the spec to that size and scales the other listed tables by the same factor (rounded, at least 1 row), so the ratio between the tables stays the same; a listed table with `rows: 0` gets at least 1 row. When every listed table has `rows: 0`, there is no ratio to keep, so every table takes the step size. Tables that the spec does not list keep their rows, as with `--seed-data`.

```sh
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000 --runs 0
```

```text
scale: 1,000, 10,000 rows in 2 steps
database: app.db
select: select.sql
index: index.sql
seed-data: seed.json
sqlite: 3.53.4
work-dir-parent: <work-dir-parent>

Steps
          rows baseline read variant read   ratio  verdict     result       plan    median
         1,000         1,000            0 0.0000x  improved    match        changed -
        10,000        10,000            2 0.0002x  improved    match        changed -

note: these rows come from generated data measured on this machine; they are not
production D1 billing.
```

Each step copies the original database into a new sandbox, seeds that copy, builds the candidate index on the variant, runs the existing comparison, and removes the copies before the next step. The table has one row per step: the rows, the rows read on both copies, the variant / baseline ratio, the rows written with `--write`, the verdict, the result, whether the plan changed, and the median times when `--runs` is not `0`. With `--show-binds`, the header also lists the bind values; with `--show-rows`, a step whose result is not `match` lists the example rows that only one copy returned. A warning is printed only where it differs between the steps, such as `data_too_small` at the smallest one. When the verdict changes between steps, one line says so, for example `The verdict changes between 1,000 and 10,000 rows.`; it does not classify the growth. The last line says that the rows are generated data measured on this machine and not production D1 billing.

The steps are 2 or 3 strictly increasing integers, each at most 10,000,000; the scaled spec must stay within 10,000,000 rows per table and 20,000,000 rows in total. Otherwise the run is a usage error (`usage_scale`, exit status `2`) before any copy is made. `--scale` works with `--d1`, `--write`, `--bind`, `--runs`, `--timeout-ms`, `--show-binds`, `--show-rows`, and `--format human` or `json`. It does not take `--batch`, `--suggest`, `--migration`, `--audit-indexes`, `--record`, or `--format kv`.

The exit status is the heaviest of the steps, in the same order as a single comparison: `3`, then `4`, then `124`, then `1`, otherwise `0`. A step that cannot run stops the run before the report is written.

With `--format json` the output is a separate object with `scale_schema_version` `1`: the `inputs`, the `environment`, one `steps` entry per size (its `tables` and the full `schema_version` 2 comparison), and the run-wide `warnings`. See [the JSON contract](json.md#scale-report-scale_schema_version-1).

## D1 local databases

`--d1 <BINDING>` compares the local copy of a Cloudflare D1 database instead of a file named with `--db`. Qenome reads the top-level `d1_databases` entries of a wrangler config and uses the binding name to find that copy:

- the config is `wrangler.toml`, `wrangler.jsonc`, or `wrangler.json` in the current directory; `--config <PATH>` names one file instead. JSONC comments (`//` and `/* */`) and trailing commas are accepted.
- the database id is `preview_database_id` when it is set, and `database_id` otherwise; this is the same choice wrangler makes for local development.
- the file is `<config directory>/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/<id>.sqlite`, where `<id>` is the identifier miniflare derives from the database id. The rule was checked against local databases written by `wrangler` 3.114.17 and 4.152.0.

```sh
qenome --d1 DB select.sql index.sql
qenome --d1 DB select.sql index.sql --config packages/api/wrangler.toml
```

Qenome stops with status 4, prints the reason on stderr, and writes nothing to stdout when it cannot pick exactly one database:

- there is no config file in the current directory (pass `--config`, or run Qenome in the wrangler project);
- there is more than one config file, so the config itself is ambiguous;
- the binding name appears in no top-level `d1_databases` entry, or it appears more than once;
- the binding has neither `database_id` nor `preview_database_id`;
- the local `.sqlite` file does not exist yet. Run a local wrangler command in the project first, such as `npx wrangler d1 execute DB --local --command "SELECT 1"`, or `npx wrangler dev` and use the database once.

Every `--d1` comparison prints two facts in all formats:

- the bundled SQLite used for the comparison is 3.53.4, the same version D1's local engine runs, but the two builds use different compile options, so plans and times can differ. D1 rejects `select sqlite_version()`, so 3.53.4 comes from the version string in wrangler's local engine;
- the times are measured on the local copy, not on production D1, and do not promise the speed of a deployed database.

Sections for other environments (`[env.<name>]`) and custom persist paths (`--persist-to`) are not read.

Qenome also checks the migrations of the binding. It reads `migrations_dir` (default `migrations`, beside the config file) and `migrations_table` (default `d1_migrations`) from the `d1_databases` entry, lists the `.sql` files directly in that directory, and compares them with the names in the record table. When a file is not applied, every `--d1` mode warns `unapplied_migrations`, names the files in wrangler's order (a leading number, then lexical order), and says to run `npx wrangler d1 migrations apply DB --local`, because a comparison against an older schema can hide what the index does. The message names at most 10 files and then how many are left. The warning never changes the verdict, a count, or the exit status. It is omitted when the record table or the directory does not exist, when the local database cannot be read, and when the table or the directory is too large to read within the check's bounds. Qenome opens the local database read-only and reads only the names, so the original database does not change; `migrations_pattern` and the bindings under `[env.<name>]` are not read.

### Try the sample project

`examples/d1-toml` and `examples/d1-jsonc` hold the same database and queries, once with `wrangler.toml` and once with `wrangler.jsonc`. Each is a wrangler project on its own: the config has one binding, `DEMO_DB`, and the `database_id` is a placeholder that is never deployed. Node.js is needed because wrangler runs through `npx`. Nothing is installed into the repository, and `.wrangler/` is not tracked by Git.

Run these commands in `examples/d1-toml`. The same commands work in `examples/d1-jsonc`.

```sh
npx wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql
qenome --d1 DEMO_DB select.sql index.sql --runs 40
```

The first command writes the local database into `.wrangler/` and loads 200,000 rows. The second compares `select.sql` with the candidate index in `index.sql`: `result rows` is `match`, `verdict` is `improved`, the plan changes from `SCAN events` to `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`, and the D1 block reports the SQLite versions and the caution. The exit status is 0.

`schema.sql` recreates `events`, so it can be run again at any time. Nothing is deployed. The commands use `qenome` from `PATH`; right after [Build from source](../CONTRIBUTING.md#build-from-source) it is `./zig-out/bin/qenome`. `4.152.0` is the wrangler version the sample was checked with.
