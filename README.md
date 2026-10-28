<div align="center">

<img src="docs/logo.svg" width="96" height="96" alt="Qenome logo: a two-twist DNA double helix, with one amber base pair marking a single change">

# Qenome

**Check whether a candidate index helps a query before you merge it.**

[![npm version](https://img.shields.io/npm/v/qenome?style=flat-square)](https://www.npmjs.com/package/qenome)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](LICENSE)
[![Quality workflow](https://github.com/alern-c/Qenome/actions/workflows/quality.yml/badge.svg)](https://github.com/alern-c/Qenome/actions/workflows/quality.yml)

English | [日本語](README.ja.md)

<img src="docs/demo-suggest.gif" width="1200" alt="The D1 sample project: qenome --d1 DEMO_DB select.sql --suggest proposes one index, matches the result rows, reads 200000 -> 101 rows, and recommends suggested:1">

</div>

<p align="center"><sub>The recording comes from <a href="#try-the-sample-project"><code>examples/d1-toml</code></a>; the sample runs on your machine with two commands.</sub></p>

Give it one read-only `SELECT` and one `CREATE INDEX`. With `--write`, give it one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` instead. It copies a local SQLite file, or a local Cloudflare D1 database (`--d1 <BINDING>`, `--config`), into sandbox snapshots and compares them. The original database is never modified.

## Features

- **Your database stays untouched.** Qenome opens the original read-only and compares sandbox copies, so a candidate index that does not help can be dropped before the merge.
- **The verdict comes from the rows read, not the time.** Rows read and rows written use the same counting as local D1 (workerd patch); `--runs 0` keeps the verdict and skips the timing.
- **The result rows are checked too.** Both copies must return the same rows as a multiset; a mismatch or an incomparable result is reported instead of a pass.
- **See what an index costs a write.** `--write` runs one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` in a rolled-back transaction on each copy and reports the rows written on both sides, including secondary-index inserts, triggers, and foreign-key cascades. See [Comparing a write](#comparing-a-write).
- **A local D1 binding is enough.** `--d1 <BINDING>` finds the local database from a wrangler config, and `--config` names the config.
- **Compare many queries in one run.** `--batch <FILE>` pairs every SELECT in a JSON manifest with every candidate `CREATE INDEX` and reports each pair; see [Batch comparisons](#batch-comparisons).
- **Find the indexes a manifest does not use.** `--batch manifest.json --audit-indexes` lists the indexes that no query plan named, the indexes whose leading columns another index or the primary key covers, and the UNIQUE and PRIMARY KEY indexes that stay for their constraint; see [Index audit (--audit-indexes)](#index-audit---audit-indexes).
- **Build a manifest from the queries your app runs.** `qenome/d1` records the SELECTs and bind values that run against a local D1, and `--record` turns the log into a manifest you can compare; see [Recording the queries your app runs (--record)](#recording-the-queries-your-app-runs---record).
- **Find a candidate from the query.** `--suggest` lets SQLite's expert propose candidate indexes and compares them, so a SELECT file is enough; see [Suggesting candidate indexes](#suggesting-candidate-indexes).
- **JSON for AI agents and CI.** `--format json` gives the report with `schema_version` 2, and the exit status separates a match, a mismatch, and an incomparable result.
- **The evidence stays next to the verdict.** The query plan, the median times, the size increase of the whole database, and advisory warnings are in the report.

> The row numbers have not yet been checked against production D1. Qenome measures the local database only.

## Contents

- [Features](#features)
- [Installation](#installation)
- [Check a local D1](#check-a-local-d1)
- [Use with AI agents](#use-with-ai-agents)
- [Why not ...](#why-not-)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Generating sandbox data (--seed-data)](#generating-sandbox-data)
- [Batch comparisons](#batch-comparisons)
- [Index audit (--audit-indexes)](#index-audit---audit-indexes)
- [Recording the queries your app runs (--record)](#recording-the-queries-your-app-runs---record)
- [Output formats](#output-formats)
- [Rules](#rules)
- [Development checks](#development-checks)
- [License](#license)

From this README, a D1 developer or their AI agent can get that verdict on a local D1 in a few minutes. See [Check a local D1](#check-a-local-d1) and [Use with AI agents](#use-with-ai-agents).

## Installation

### npm

On Linux and macOS, for x64 and arm64, install the command once:

```sh
npm install -g qenome
qenome --version
```

The global install puts `qenome` on your `PATH`, so the examples below run as written. Update it with `npm install -g qenome@latest`.

To try Qenome without installing it, run it through `npx`, which fetches the package and adds no global command:

```sh
npx qenome --version
```

Install it once if you run Qenome often; use `npx qenome` for a one-off check on a D1 project. When the binary is not on your `PATH`, replace `qenome` with `npx qenome` in the examples.

The package is a small launcher plus one optional binary for the machine you are on (`@qenome-cli/linux-x64`, `@qenome-cli/linux-arm64`, `@qenome-cli/darwin-x64`, or `@qenome-cli/darwin-arm64`). The version is `.version` in `build.zig.zon`, and [docs/npm.md](docs/npm.md) covers how the packages are built and published. Windows is not an npm target: use the prebuilt binaries below.

### Prebuilt binaries (GitHub Releases)

Download an asset from the [Releases](https://github.com/alern-c/Qenome/releases) page, together with the `SHA256SUMS` file from the same release.

Prebuilt binaries are provided for Linux, macOS, and Windows. Release assets are uncompressed binaries named `qenome-<version>-<arch>-<os>` (`qenome-<version>-<arch>-<os>.exe` on Windows). For example:

- `qenome-0.3.5-x86_64-linux`
- `qenome-0.3.5-aarch64-macos`
- `qenome-0.3.5-x86_64-windows.exe`

The release page lists the assets that were built; pick the one whose `<arch>` and `<os>` match your machine. `SHA256SUMS` uses the `sha256sum` format: a SHA-256 hash, two spaces, and the file name.

Verify the download before running it. Replace `0.3.5` and the file name in these examples with the version and asset you downloaded.

<details>
<summary>Show the checksum commands for Linux, macOS, and Windows</summary>

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.3.5-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows (PowerShell):

```powershell
Select-String 'qenome-0.3.5-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.3.5-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` must print the same SHA-256 hash as the line from `SHA256SUMS` (uppercase letters are fine).

</details>

Then give the binary execute permission (Linux and macOS) and run it:

```sh
chmod +x qenome-0.3.5-aarch64-macos
mv qenome-0.3.5-aarch64-macos qenome
./qenome --version
```

On Windows, run the `.exe` directly.

If macOS refuses to run the binary because it is not notarized, allow it in System Settings → Privacy & Security.

### From source

Qenome needs Zig 0.17.0, the `minimum_zig_version` in `build.zig.zon` (CI builds with exactly this version). SQLite is vendored in `vendor/sqlite3` and compiled in, so no system SQLite is needed.

```sh
zig build
./zig-out/bin/qenome --version
```

`zig build` writes the binary to `zig-out/bin/qenome` (`zig-out\bin\qenome.exe` on Windows). For timings that match a release build, build with `zig build -Doptimize=ReleaseFast`.

## Check a local D1

Use this when the database is a local Cloudflare D1 and you want a verdict before merging an index. You need Node.js for `npx`, a wrangler project, and two SQL files: one `SELECT`, one `CREATE INDEX`.

If the local database does not exist yet, create it once. `DB` is the `d1_databases` binding name:

```sh
npx wrangler d1 execute DB --local --command "SELECT 1"
```

From that project directory:

```sh
npx qenome --d1 DB select.sql index.sql --runs 0 --format json
```

`--runs 0` skips the timing and still returns the verdict. Exit status `0` means the result rows match. Read `verdict` in the JSON: `improved` means the variant read fewer rows, `no-effect` means it did not, and `needs-check` means it read or wrote more. The numbers use the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

`--config <PATH>` names a wrangler file outside the current directory. The lookup rules are in [D1 local databases](#d1-local-databases). The JSON fields are in [docs/json.md](docs/json.md).

A worked sample with a `wrangler.toml` is in [Try the sample project](#try-the-sample-project).

## Use with AI agents

An agent that changes a D1 schema should run Qenome before it keeps a `CREATE INDEX`. The instructions are [skills/qenome/SKILL.md](skills/qenome/SKILL.md): when to run, how to pass `--d1` and `--config`, how to read `schema_version` 2, and what to do with exit codes and warnings.

Point the agent at that file. `--format json` is the machine-readable report, specified in [docs/json.md](docs/json.md).

## Why not ...

**EXPLAIN QUERY PLAN.** The plan says whether SQLite expects to touch an index. It does not run the `SELECT` on a copy of the data, so it cannot show that the result rows changed, how many rows were read or written, or how much the database file grew. Qenome runs the statement on both sandbox copies and counts with the same counting as local D1 (workerd patch).

**`wrangler d1 execute --local`.** A local wrangler command can print one duration for the whole call. That duration moves from run to run, and wrangler does not build your candidate index on a copy and compare it with the current schema. Qenome leaves the original database unchanged and judges the index from the row counts. The times are a reference next to that verdict.

**Production D1 metrics.** The numbers have not yet been checked against production D1. Qenome measures the local database only.

**Applying the index and watching the app.** That writes the index into the database you ship. Qenome tries it on a sandbox copy, so a candidate that does not help can be dropped before the merge.

## Quick start

This walkthrough creates the test database, builds Qenome, and runs seven examples. Run the commands from the repository root, one block at a time, on Linux or macOS. They need Zig 0.17.0 (see [From source](#from-source)) and the `sqlite3` command-line tool, which loads the SQL files into the new database.

Create the test database from `testdata/schema.sql` and `testdata/seed.sql`. `verify.sql` prints one `ok` line for each of its 17 checks, and fails the load when a value is not the expected one.

```sh
mkdir -p testdata/generated
rm -f testdata/generated/qenome-fixture.db
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/schema.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/seed.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/verify.sql"
```

Build Qenome:

```sh
zig build
```

The seven examples run `zig-out/bin/qenome`. Each command ends with the result it has to report: `result` and `verdict` from the Summary (or `recommended` for a batch), and the exit status. `python3 scripts/check_all.py` and the quality workflow run these lines as written, so the README and the program stay in step. `--runs 40` keeps the medians steady on a busy machine; the default is `10`.

An index that removes the full scan. The candidate index turns `SCAN events` into `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`, the rows read fall from 200,000 to 101, and both copies return the same 100 rows.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 40  # expect: result=match verdict=improved exit=0
```

An index on data you choose. `--seed-data testdata/seed.json` replaces the `events` rows in the sandbox copy, with the original database unchanged, by 50,000 deterministic rows. The same query then finds row `1234` among them, and the verdict stays `improved`. See [Generating sandbox data](#generating-sandbox-data).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --seed-data testdata/seed.json --runs 0  # expect: result=match verdict=improved exit=0
```

An index that cannot help. The SELECT wraps the column in `lower()`, so SQLite cannot use the index on `status`, and the plan, the rows read, and the rows written stay the same.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/no-effect.sql testdata/cases/no-effect.index.sql --bind 1:text:ok --runs 40  # expect: result=match verdict=no-effect exit=0
```

An INSERT that a new index makes more expensive. `--write` compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` on both sandbox copies, inside a transaction that is rolled back. The candidate index on `customer_id` is not used by this INSERT, but each inserted row also updates the index: the rows written rise from 1 to 2, while both copies change the same row. The verdict is `needs-check` because the variant writes more, and the exit status stays 0. The original database is not changed.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --write testdata/cases/write.sql --index-sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 0  # expect: result=match verdict=needs-check exit=0
```

A SELECT whose rows cannot be compared. `ORDER BY random()` picks other rows on every run, so Qenome reports the rows as incomparable instead of claiming that they match, and it does not judge the comparison. The exit status 4 is the expected result here, not an error.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/incomparable.sql testdata/cases/incomparable.index.sql  # expect: result=incomparable verdict=not-judged exit=4
```

A batch compares several queries with several candidate indexes in one run. `testdata/batch.json` pairs the improved and no-effect queries with both candidate indexes. Qenome reports one row per pair and recommends the candidate that helps without a mismatch, so only `cases/improved.index.sql` qualifies. See [Batch comparisons](#batch-comparisons).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --batch testdata/batch.json  # expect: recommended=cases/improved.index.sql exit=0
```

A proposed index, without an index file. `--suggest` asks SQLite which index would help the SELECT, and Qenome compares that proposal with the same batch machinery. The proposal is labelled `suggested:1` and becomes the recommendation when it helps. See [Suggesting candidate indexes](#suggesting-candidate-indexes).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql --bind 1:int:1234 --suggest  # expect: recommended=suggested:1 exit=0
```

The first database build takes about a second, and each timed example a few seconds. `testdata/README.md` records the fixture, the queries, and their expected plan and counters.

## Usage

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
qenome app.db select.sql index.sql --seed-data seed.json
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

`select.sql` holds one read-only `SELECT`; `index.sql` holds one candidate `CREATE INDEX`. Qenome rejects multiple statements and any other statement. A `--migration` file is the one exception: it may hold several `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE`, and `ALTER TABLE` statements; see [Batch comparisons](#batch-comparisons).

`--write` takes the place of `--select` and holds one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` (a leading `WITH` and a trailing `RETURNING` are allowed). It does not take `--batch`, `--migration`, or `--suggest`. The statement runs in a transaction on each copy and is rolled back, so the original database is never changed and every `--runs` round starts from the same rows.

- `--db <PATH>`: the SQLite database to read (required, once; not with `--d1`)
- `--d1 <BINDING>`: the local D1 database of this `d1_databases` binding in a wrangler config, instead of `--db`. See [D1 local databases](#d1-local-databases)
- `--config <PATH>`: the wrangler config for `--d1` (default: `wrangler.toml`, `wrangler.jsonc`, or `wrangler.json` in the current directory)
- `--select <FILE>`: a file holding the one `SELECT` to compare (required, once; not with `--write`)
- `--write <FILE>`: a file holding one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` to compare instead of a `SELECT`; it runs in a transaction on each sandbox copy and is rolled back. See [Comparing a write](#comparing-a-write). It cannot be combined with `--select`, `--batch`, `--migration`, or `--suggest`
- `--index-sql <FILE>`: a file holding the one candidate `CREATE INDEX` (required, once)
- `--batch <FILE>`: compare every SELECT in a JSON manifest with every candidate `CREATE INDEX` in one run; see [Batch comparisons](#batch-comparisons). It cannot be combined with `--select`, `--index-sql`, `--bind`, positional SELECT or INDEX paths, `--runs`, or `--format kv`
- `--audit-indexes`: with `--batch`, report the indexes that no manifest query plan used and the indexes whose leading columns another index or the primary key covers, and keep the UNIQUE and PRIMARY KEY indexes in a separate list; the manifest needs only `queries`, and `candidates` are ignored. It needs `--batch` and cannot be combined with `--suggest`, `--migration`, or `--seed-data`. See [Index audit (--audit-indexes)](#index-audit---audit-indexes)
- `--record <FILE>`: read the records that `qenome/d1` wrote and write a manifest without candidates to `--out`; no database is needed. The manifest holds bind values, so keep it local and do not commit it. Use it with `--out`; it cannot be combined with `--db`, `--d1`, `--select`, `--write`, `--index-sql`, `--batch`, `--migration`, `--seed-data`, `--bind`, `--runs`, `--suggest`, or `--format kv` / `json`. See [Recording the queries your app runs (--record)](#recording-the-queries-your-app-runs---record)
- `--out <DIR>`: the new directory for `--record`. It must not exist. The directory is created with mode `0700` and its files with `0600`
- `--migration <FILE>`: apply this SQL file to the variant only before the `--batch` queries run. It needs `--batch` and a manifest without `candidates`; it cannot be combined with `--select`, `--index-sql`, `--bind`, `--runs`, `--suggest`, or `--format kv`. `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (a column list, not `AS SELECT`), and `ALTER TABLE` (ADD / RENAME / DROP COLUMN and RENAME TO) are accepted; data changes, `DROP TABLE`, `ATTACH`, `PRAGMA`, and other statements are rejected with the statement number. A query that uses a column or table the migration drops or renames cannot run on the variant, so the whole run stops with exit `1`; a `SELECT *` cannot be compared after a column is added or dropped, so list the columns you need. See [Batch comparisons](#batch-comparisons)
- `--seed-data <FILE>`: replace the tables listed in this JSON spec with deterministic dummy rows in the sandbox copy before comparing; the original database is not changed. It works with every mode, including `--batch`, `--suggest`, and `--migration`. See [Generating sandbox data](#generating-sandbox-data)
- `--suggest`: ask SQLite's expert for candidate indexes instead of naming one, and compare the proposals. With `--batch`, the manifest may omit `candidates`. It cannot be combined with `--runs`, `--format kv`, or an index file (`--index-sql` or a third positional path). See [Suggesting candidate indexes](#suggesting-candidate-indexes)
- `--bind <N>:<TYPE>[:<VALUE>]`: a typed value bound to parameter `N`; repeatable. `N` is SQLite's parameter number: named parameters share the number of their first appearance, and `?NNN` uses `NNN`. `TYPE` is `int`, `real`, `text`, or `null` (null takes no value). Every number in `1..parameter count` must be given exactly once, and a `SELECT` without parameters takes no `--bind`. The value is the rest of the argument, so text may contain `:`.
- `--runs <N>`: timed rounds after the results match; each round adds two baseline A/A executions and times the `SELECT` once per copy. The default is `10`; `0` skips the timing but keeps the row counts and the verdict; the maximum is `1000`. A timing that takes longer than a second reports its progress on stderr. With `--write`, `N` is the number of rolled-back executions per copy (at least one), no timing runs, and every execution must report the same counts.
- `--timeout-ms <MS>`: time limit for building the index, for each `SELECT` run, and for each `--write` execution; the default is `30000`; `0` disables the limit. The comparison and timing can take the database copy plus `(3 + 4 × runs)` time limits, with additional bounded diagnostic statements (the ANALYZE and size checks, and when the SELECT has parameters the bind-dependent partial index check) each using the same timeout.
- `--format <human|kv|json>`: output format (default `human`). See [Output formats](#output-formats).
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

### Comparing a write

`--write write.sql --index-sql index.sql` compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` before and after the candidate index. A leading `WITH` and a trailing `RETURNING` are allowed; `CREATE`, `DROP`, `ALTER`, `PRAGMA`, `ATTACH`, `VACUUM`, and multiple statements are rejected. The statement is prepared with the same authorizer as the SELECT mode, so only writes to the main schema and reads, functions, and common table expressions are allowed.

The original database is opened read-only and copied as usual. On each copy, Qenome starts a transaction, runs the statement, reads the counters, changes, and `RETURNING` rows, and rolls the transaction back. The next `--runs` round starts from the same rows. The write connections are on the sandbox copies only and enable SQLite's foreign keys (`PRAGMA foreign_keys=ON`), so a `ON DELETE CASCADE` or `SET NULL` action is counted and rolled back with the statement. Triggers are active and their writes are counted too. A rollback failure stops the comparison; Qenome never tries to repair the sandbox.

Both copies must make the same change. Qenome compares three facts: the multiset of `RETURNING` rows (empty without `RETURNING`), `sqlite3_changes` (the rows the statement itself changed), and the difference of `sqlite3_total_changes` (which also counts trigger and foreign-key changes). A difference is a result mismatch (exit status `3`) and is not judged from the row counts.

`--runs` has a different meaning in this mode: it is the number of rolled-back executions per copy, at least one. The first execution supplies the reported counts. If a later execution reports different counters or changes, the write is not repeatable from the same rows, so the comparison is `incomparable` (exit status `4`) with the reason. `--runs 0` still runs once. There is no timing loop, so `timing` is `null` and the `time` line says it is not timed.

The statement is not run when it calls a function whose result changes between runs (`random()`, `randomblob()`, `changes()`, `last_insert_rowid()`, `total_changes()`), reads the current time (`date()`, `datetime()`, `julianday()`, `strftime()`, and the other time functions), or reads a schema table (`sqlite_schema`, `sqlite_master`, or a `sqlite_stat*` table). The last case includes a trigger that reads the schema. Those comparisons are `incomparable` (exit status `4`) and say that the write was not run. A `RETURNING` clause is compared as rows, so it can be used to check which rows the write touched.

Rows written use the same local D1 (workerd patch) counting as the SELECT mode. The counter includes the table row and each secondary-index insert, trigger insert, and foreign-key cascade. The bundled patch does not count secondary-index deletes: a `DELETE` or an `UPDATE` that removes an old index entry reports the table change but not the index removal. A `DELETE ... WHERE` can therefore show fewer rows read with the same rows written. Treat the write count as the part the patch measures, not as the full cost of index maintenance.

`--write` works with `--d1`, `--seed-data`, `--bind`, `--timeout-ms`, `--show-binds`, `--show-rows`, and every output format. It does not work with `--batch`, `--migration`, or `--suggest`; those modes keep their SELECT-only input and reject `--write` with a usage error.

### Generating sandbox data

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

### D1 local databases

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

#### Try the sample project

`examples/d1-toml` and `examples/d1-jsonc` hold the same database and queries, once with `wrangler.toml` and once with `wrangler.jsonc`. Each is a wrangler project on its own: the config has one binding, `DEMO_DB`, and the `database_id` is a placeholder that is never deployed. Node.js is needed because wrangler runs through `npx`. Nothing is installed into the repository, and `.wrangler/` is not tracked by Git.

Run these commands in `examples/d1-toml`. The same commands work in `examples/d1-jsonc`.

```sh
npx wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql
qenome --d1 DEMO_DB select.sql index.sql --runs 40
```

The first command writes the local database into `.wrangler/` and loads 200,000 rows. The second compares `select.sql` with the candidate index in `index.sql`: `result rows` is `match`, `verdict` is `improved`, the plan changes from `SCAN events` to `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`, and the D1 block reports the SQLite versions and the caution. The exit status is 0.

`schema.sql` recreates `events`, so it can be run again at any time. Nothing is deployed. The commands use `qenome` from `PATH`; right after [From source](#from-source) it is `./zig-out/bin/qenome`. `4.152.0` is the wrangler version the sample was checked with.

### Batch comparisons

`--batch manifest.json` compares every SELECT in a manifest with every candidate `CREATE INDEX`. The manifest is a JSON object with two lists:

```json
{
  "queries": [
    { "select": "queries/orders.sql", "binds": ["1:int:1234"] },
    { "select": "queries/recent.sql" }
  ],
  "candidates": [
    { "index_sql": "candidates/a.sql" },
    { "index_sql": "candidates/b.sql" }
  ]
}
```

- `queries` holds 1 to 100 entries. `candidates` holds 1 to 100 entries, or may be omitted (or `[]`) when `--suggest` adds the proposals or `--migration` supplies the variant change.
- The same path cannot appear twice in `queries`, and it cannot appear twice in `candidates`.
- With `--migration`, `candidates` must be omitted or `[]`, and the manifest holds only `queries`.
- `select` and `index_sql` are paths to files. They are resolved from the manifest's directory, not from the current directory. Each file holds one read-only SELECT or one `CREATE INDEX`, and is at most 1 MiB.
- `binds` is optional and uses the same `N:TYPE:VALUE` syntax as `--bind`. Every path and bind must be a JSON string without a NUL byte.
- The `select` and `index_sql` strings are copied to the JSON report exactly as written. The `human` report shortens an absolute path to the shortest trailing part that no other path in the same list shares, so candidates in different directories stay apart (`a/x.sql` and `b/x.sql`), and shows a relative path and a `suggested:N` label as written. The full path stays in the JSON report, and with `--migration` in the `migration:` line.

Qenome copies the database once, checks every SELECT and every candidate before it runs anything, then visits the candidates in manifest order. For each candidate it copies the baseline again, builds the index on that copy only, and runs every query on both copies. The baseline SELECT is run again for each candidate.

With `--migration <FILE>`, the variant change is the whole migration file instead of a candidate index. The file is at most 1 MiB. Qenome checks the file before it touches the variant: it allows `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (a column list, not `AS SELECT`), and `ALTER TABLE` with ADD COLUMN, RENAME COLUMN, DROP COLUMN, or RENAME TO, separated by semicolons. `INSERT`, `UPDATE`, `DELETE`, `DROP TABLE`, `ATTACH`, `PRAGMA`, and every other statement are rejected with the statement number and status `1`; the variant and the original database are not touched. It then applies the statements in file order to the variant only, so a migration may add a column and index it, rename a column or table, or drop an index and create another with the same name. Each statement gets its own `--timeout-ms`. The original database is never changed. The report adds a `migration:` block (human) or a top-level `migration` object (JSON) with the path and every applied statement. A query that uses a column or table the migration adds cannot run on the baseline: Qenome measures it on the variant only and reports its plan and row counts with verdict `not-judged`, with the baseline reason in `verdict_reasons`. That query does not change the exit status. Human output adds a `not-judged` summary column and a `Not judged` list; JSON counts it under `summary.not_judged` and writes the comparison with `baseline: null`. A query that the migration breaks stops the run: if the manifest refers to a column or table that the migration drops or renames, the variant cannot prepare that `SELECT`, so nothing is written to stdout and the batch exits `1`, with an `error:` line that names the query and the migration file (JSON: `batch_variant_failed`). A CI step fails there. Write the post-migration names in the manifest. Adding or dropping a column also changes the column count of a `SELECT *`, so that query is `incomparable` and the batch exits `4`; list the columns you need to compare it. When the result rows match but a query reads or writes more rows after the migration, that query's verdict is `regressed`: the human `Results` column says `regressed`, and JSON has `"verdict": "regressed"` under `results[].comparison`. The `summary` count keeps the key `needs_check` and counts those queries, and the batch exits with status `6`; a result mismatch (`3`), a rejected change (`1`), a time limit (`124`), or an incomparable result (`4`) takes precedence. `no-effect` alone keeps `0`. The other modes keep the name `needs-check` for the same condition. The `no_analyze_stats` and `data_too_small` warnings are not emitted for a migration, because it can touch several tables. The `bind_dependent_partial_index` warning is still emitted, because it needs only the variant plan.

With `--migration`, the `size increase` is the change in the bytes that pages in use hold, `(page_count - freelist_count) * page_size`, not the change of the file size. `DROP INDEX` moves its pages to SQLite's freelist without shrinking the file, so the file delta stays `0 B`; the bytes in use report the freed space as a negative value (for example `-2.06 MiB`). The file itself shrinks only after `VACUUM`. Runs without `--migration` keep reporting the file size difference.

<details>
<summary>Batch statuses, failures, and exit status</summary>

A candidate that cannot be built is recorded and the batch continues:

| Status | Meaning | Exit contribution |
| --- | --- | --- |
| `index_rejected` | SQLite rejected the `CREATE INDEX` (for example a UNIQUE constraint on duplicate rows) | `1` |
| `index_timeout` | the index build reached `--timeout-ms` | `124` |
| `variant_timeout` | a variant SELECT reached `--timeout-ms`; that query is not judged, the others stay | `124` |

A failure that affects the whole run stops it before any report is written and leaves stdout empty: a baseline SELECT that fails or times out, a variant SELECT that cannot run after the migration (it uses a column or table the migration dropped or renamed), a signal, a variant or baseline connection that fails, the temporary copies that cannot be created or removed, and storage errors such as a full disk. Candidate failures are not written as `error:` lines.

When the report is written, the exit status is the heaviest of a result mismatch (`3`), a rejected index or migration (`1`), a candidate time limit (`124`), an incomparable result (`4`), a `--migration` regression (`6`), and `0`. Cleanup failure replaces `0` with `5`. A batch can therefore write a report and still exit `1`, `6`, or `124`; read stdout to tell the cases apart.

The `human` output has a table of candidates, a `Recommendation:`, and a table of query and candidate verdicts. The recommendation is the candidate with the most improved queries among those with no mismatch, no incomparable result, no `needs-check` (`needs_check` counts the `regressed` queries in a `--migration` run), no timeout, and at least one improvement. A query measured on the variant only is `not-judged` and does not disqualify the migration by itself; in the `Results` table its `result` column says `variant-only` and its `verdict` column `not-judged`, while the embedded JSON comparison keeps `result` `incomparable` with `baseline` `null`. Ties go to the candidate without a `bind_dependent_partial_index` warning, then to the smaller size increase, then to manifest order. A warning never changes a verdict, a batch count, or the exit status. The `human` output lists each comparison warning after the results table in a `Warnings` section, as `<query> -> <candidate>: <code>: <message>`; the paths and the index name are escaped like the other warnings, and the paths use the short form described above. With `--format json` the output is the `batch_schema_version` 1 object described in [docs/json.md](docs/json.md).

Each index build, each SELECT run, and each diagnostic statement has its own `--timeout-ms` limit. A batch can take one database copy, one baseline SELECT run per query before the candidate loop, and then, for every candidate, one index build and two SELECT runs per query plus the diagnostic statements: up to three for the ANALYZE and size warnings, and, for a query with parameters, the bind-dependent partial index check (one plan, one catalog read, and up to two statements per used index: a table-name lookup and a `PRAGMA index_list`), each with its own time limit. `--show-binds` and `--show-rows` apply to every comparison object.

</details>

Two recordings show the report. The first compares one SELECT with two candidates: the composite index with the columns in the wrong order reads the same rows (`200000 -> 200000`, `no-effect`), and `index.sql` reads `101` rows and becomes the `Recommendation`.

<img src="docs/demo-candidates.gif" width="1200" alt="qenome --d1 DEMO_DB --batch candidates.json compares select.sql with a composite index and with index.sql: the composite index is no-effect at 200000 -> 200000 rows read, index.sql is improved at 200000 -> 101, and the Recommendation is index.sql">

The second applies `0002_reindex.sql`, which drops `ix_events_customer_id` and creates the composite index in its place: `select.sql` is `regressed` (`101 -> 200000`), `failed.sql` is `improved` (`101 -> 35`), and the run exits with status `6`.

<img src="docs/demo-migration.gif" width="1200" alt="qenome --d1 DEMO_DB --batch queries.json --migration 0002_reindex.sql applies the migration to the variant copy: select.sql is regressed at 101 -> 200000 rows read, failed.sql is improved at 101 -> 35, and the shell reports exit=6">

Both recordings take their extra inputs from `docs/demo`, together with the `examples/d1-toml` sample.

### Index audit (--audit-indexes)

`qenome app.db --batch manifest.json --audit-indexes` reports the existing indexes that the manifest queries did not use, and the ones whose key columns another index or the primary key already covers. It reads the plan of every manifest query on one read-only copy; it does not build a variant and does not change the database. The manifest needs only `queries`, so a manifest from `--record` works as it is; `candidates` are ignored.

Qenome prints three lists:

| List | What it holds |
| --- | --- |
| `Unused in this manifest` | Indexes that no plan named. A partial index is marked, because another bound value can use it |
| `Redundant candidates` | Plain indexes whose key columns are a prefix of another index or of the primary key, with the same collation and sort order. `covered by` names that index; `INTEGER PRIMARY KEY` means the rowid primary key |
| `Kept for constraints` | UNIQUE and PRIMARY KEY indexes. They are not removal candidates |

An index can appear in both the unused and the redundant lists. The key columns come from `PRAGMA index_list` and `PRAGMA index_xinfo`. A partial index is never judged redundant, an expression index is not compared, and a different collation or ASC/DESC order is not treated as covered. A plain index is named in `Redundant candidates` only when another index or the primary key on the same table can serve the same lookups. When a manifest SELECT uses `INDEXED BY`, Qenome does not judge the redundancy list at all, so it cannot point at an index that the query forces.

The report is a statement about this manifest, not a recommendation to drop an index. The plans cover the SELECTs in the manifest only, so an index used by `UPDATE`, `DELETE`, foreign-key maintenance, or a query outside the manifest is not visible here. An index used only for `ORDER BY` or `GROUP BY` does appear in these plans. An index that SQLite did not pick can still be one it could use.

The run exits `0` when the report is written, even when the lists are not empty. Read stdout, not the exit status, to find indexes. `--audit-indexes` needs `--batch` and does not take `--suggest`, `--migration`, or `--seed-data`; it takes `--d1`, `--timeout-ms` (for each plan and each catalog read), and `--format human` (default) or `--format json`. With JSON the output is the `audit_schema_version` 1 object described in [docs/json.md](docs/json.md).

### Recording the queries your app runs (--record)

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

1. Compare the manifest, or audit the indexes it uses. It holds only `queries`, so pair it with `--suggest`, `--migration`, or `--audit-indexes`.

```sh
npx qenome --d1 DB --batch qenome-manifest/manifest.json --suggest
```

Add `candidates` to `manifest.json` when you have your own.

How `--record` works:

- The same SQL becomes one entry. SQL that differs only in whitespace outside strings and comments counts as the same, and the first execution supplies the bind values. stdout shows how many times each statement ran.
- `INSERT`, `UPDATE`, `DELETE`, and `REPLACE` are not put in the manifest; only their count is reported. `exec` and statements that bind a BLOB, a boolean, or text with a NUL are skipped too, because `--bind` cannot express those values. The `skipped:` line names each reason and count.
- More than 100 distinct SELECTs, a manifest over 1 MiB, a SQL statement over 1 MiB, or a log over 16 MiB stops the run before `--out` is created.
- `--record` needs no database and cannot be combined with `--db`, `--d1`, `--batch`, `--migration`, `--suggest`, `--seed-data`, `--bind`, `--runs`, or the other comparison options. Only `--format human` is accepted.

Recording is for local development and tests only. The wrapper writes the SQL and the bind values to its output, so do not ship it to production. SQL inside `withSession` and Durable Objects is not recorded.

### Suggesting candidate indexes

`--suggest` has SQLite's expert (sqlite3expert, built from the vendored SQLite source) propose candidate indexes, then compares them with the same batch machinery. You do not need an index file.

```sh
qenome app.db select.sql --suggest
qenome --d1 DB select.sql --suggest --bind 1:int:1234
qenome app.db --batch batch.json --suggest
```

With one SELECT file, the SELECT becomes one batch query and `--bind` applies to it. With `--batch`, the proposals join the manifest candidates, which may be omitted or empty. `--suggest` does not take `--runs`, `--format kv`, or an index file.

Qenome opens a second read-only connection to the baseline copy and sets the expert sampling to `0`, so the expert reads the schema only. Every checked SELECT is passed to it. Before the expert starts, every `sqlite_schema` row is checked: each must be one statement and start with `CREATE TABLE`, `CREATE INDEX`, `CREATE UNIQUE INDEX`, `CREATE VIEW`, `CREATE TRIGGER`, or `CREATE VIRTUAL TABLE`, and none may use the `expert` virtual table. A database that fails this check is rejected with `suggest_schema_rejected` (exit `1`, empty stdout), even when the manifest has candidates. While the expert runs, a temporary guard is installed on the connections it opens: `ATTACH` and `DETACH` are denied, only the `index_list` and `index_xinfo` PRAGMAs are allowed, and the attached-database limit is `0`. After the expert object is created, the expert installs its own authorizer on its analysis copy; the attached-database limit stays in force there. Qenome removes the guard after the expert is destroyed. If the guard cannot be installed, Qenome stops before calling the expert. Together they keep a crafted schema from creating or changing another database file. The `CREATE INDEX` statements in its report are split with SQLite's own statement parser, so a `;` inside a quoted name does not split one. Each proposal passes the same check as a manifest candidate and is dropped with a `suggestion_rejected` warning when it fails. Labels are `suggested:1`, `suggested:2`, …; at most 20 proposals are compared, and at most 100 candidates with the manifest entries.

The output is the batch report. Each `summary` entry adds `source` (`manifest` or `suggested`) and `index_sql_text`, and the top-level `warnings` array lists what was dropped or could not be done. Each `results[].comparison` keeps the comparison `warnings`, including `bind_dependent_partial_index`; the batch top-level `warnings` stays for `--suggest`. The `human` report lists each comparison warning with its query and candidate.

| Warning `code` | Meaning |
| --- | --- |
| `suggest_query_skipped` | SQLite could not analyze one SELECT; the other SELECTs continue |
| `suggestion_rejected` | A proposal failed the `CREATE INDEX` check |
| `suggestions_truncated` | The 20 or 100 limit dropped the tail of the proposals |
| `no_suggestions` | SQLite proposed nothing; the manifest candidates were compared |
| `suggest_failed` | The expert could not start or analyze; the manifest candidates were compared |

When nothing can be compared, the run stops with exit `1`, empty stdout, and error code `no_candidates`. A proposal weighs the same as a manifest candidate in the exit status and in the recommendation. The proposals are a starting point, not a verdict: the result rows, the rows read, and the exit status still come from the real comparison.

Use `--suggest` to find candidates. For a CI gate, compare a named index without `--suggest`, so that a change in SQLite's advice cannot change the build. The batch report keeps `batch_schema_version` `1`; `source`, `index_sql_text`, and `warnings` are additions.

## Output formats

### human (default)

`--format human` prints what a decision needs:

- a Summary: whether the result rows match, how many rows each copy read and wrote, the verdict with its reasons, whether the plan changed, with `--seed-data` the `seed data` and `seed` lines, the median times with the direction from the paired rounds (or the median ratio when the rounds cannot judge it), the size of the change when the medians agree (`230x faster`), and the size increase, and a note when the build is a debug build. With `--write`, the Summary adds the `write` file, `returning rows`, `rows changed`, `total changed`, and `write runs`, and the side-by-side table adds `rows changed` and `total changed`;
- a side-by-side table of baseline and variant: rows read, rows written, result rows, full-scan steps, VM steps, sort operations and autoindex rows when they are not zero, the p25 and p75 times when timed, and the database file bytes;
- the query plan for both copies, with `kind`, `covering`, and `automatic` as hints read from SQLite's wording;
- a `Warnings` section with `warning: <code>: <message>` lines when an advisory warning applies;
- with `--suggest`, a `Suggested by SQLite:` section that lists each proposal as `suggested:N: CREATE INDEX ...` with its SQL text, and `warning: <code>: <message>` lines after the tables for what was dropped or could not be done;
- with `--d1`, a D1 block: the binding, the config, the database id, the local file, the SQLite version difference, and the caution about production D1.

When the rows differ, cannot be compared, or come in another order, the human output adds an explanation and the one-sided counts. Example rows appear only with `--show-rows`; when they are hidden, the human output says to rerun with that flag. `--show-binds` adds the bind values.

Input paths other than `--seed-data`, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions appear only in `kv` and `json`. The timing evidence (`effect`, `median_difference_ns`, `noise_band`, `confidence_interval`) also appears only in `kv` and `json`. With `--d1`, `human` also shows the D1 block described above.

### kv

`--format kv` prints every fact as one `key: value` line, for scripts and logs. It includes the inputs, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions, which the human output leaves out. With `--d1` it adds `d1-binding`, `d1-config`, `d1-database-id`, `d1-local-database`, `d1-sqlite-version`, `d1-sqlite-version-note`, and `d1-caution`. With `--seed-data` it adds `seed-data`, `seed`, `seed-rows`, `seed-tables`, and one `seed-table` line per table. With `--write` it prints `write` instead of `select`, adds `result-kind`, `write-changes-baseline`, `write-changes-variant`, `write-total-changes-baseline`, `write-total-changes-variant`, and `write-runs`, and describes the write measurement in the `measure-*` lines. `baseline-only-row` and `variant-only-row` appear only with `--show-rows`.

### json

`--format json` prints one JSON object with a trailing newline after a comparison finishes. With `--batch` it prints the separate `batch_schema_version` 1 object described above (see [Batch comparisons](#batch-comparisons) and [docs/json.md](docs/json.md)). With `--seed-data`, both objects add a top-level `seed_data` object. The fields, including names reserved for the next core change, are specified in [docs/json.md](docs/json.md). When an input is rejected, the time limit is reached, or the run is interrupted, stdout stays empty. With `--format json`, stderr is then one JSON object (`schema_version`, `exit_code`, and `error` with `code`, `message`, and `hint`). `human` and `kv` keep the text `error:` line.

The verdict is in the top-level `verdict` field:

| `verdict` | Meaning |
| --- | --- |
| `improved` | The rows match, and the variant reads fewer rows |
| `no-effect` | The rows match, and the variant reads the same number of rows |
| `needs-check` | The rows match, but the variant reads or writes more rows; `verdict_reasons` holds the reasons |
| `not-judged` | The rows differ or cannot be compared; `verdict_reasons` holds the reasons |

A `--migration` batch names the `needs-check` case `regressed`, because the migration is a change that is already written. The standalone, `--batch`, and `--suggest` verdicts keep `needs-check`; the batch `summary` count likewise keeps the key `needs_check`. A query that only the variant can run is `not-judged` and keeps the exit code unchanged. See [Batch comparisons](#batch-comparisons).

The verdict uses the rows read and the rows written, with the same counting as local D1 (workerd patch). The times are a reference only, so `--runs 0` keeps the verdict. The numbers have not yet been checked against production D1. In `--write`, `result` compares the `RETURNING` rows (empty without `RETURNING`), and the two copies must also report the same `changes` and `total_changes`; a difference is `mismatch` and exit `3`, and the row counts are not judged.

Print only the verdict:

```sh
qenome app.db select.sql index.sql --format json | jq -r .verdict
```

In CI, keep the index only when the results match and the verdict is `improved`:

```sh
if qenome app.db select.sql index.sql --format json | jq -e '.result == "match" and .verdict == "improved"' > /dev/null; then
  echo "keep the index"
fi
```

<details>
<summary>Main keys and string escaping</summary>

Main keys:

| Key | Contents |
| --- | --- |
| `schema_version` | Version of the output format (currently `2`; `1` was the time verdict) |
| `statement` | `select` or `write` |
| `exit_code` | Exit status for the comparison (`0`, `3`, or `4`). If cleanup fails after a match, the JSON is written first and the process exits with `5` instead of `0` |
| `verdict` / `verdict_reasons` | Verdict from the rows read and its reasons (`improved` / `no-effect` / `needs-check` / `not-judged`) |
| `result` | Result row comparison (`match` / `mismatch` / `incomparable`) |
| `row_order` | Row order (`same` / `differs` / `not-applicable`). Reference only and not part of the match; `same` or `differs` only when `result` is `match` |
| `result_reasons` | Why the rows cannot be compared. Each element has `text` and `hint` (`null` when there is none) |
| `row_differences` | `baseline_only` and `variant_only` counts. `baseline_only_examples` and `variant_only_examples` are arrays; they stay empty by default, and `--show-rows` fills them with up to 5 example rows |
| `plan_changed` | Whether the query plan differs between baseline and variant |
| `baseline` / `variant` | `rows`; `plan` (`id`, `parent`, `kind`, `covering`, `automatic`, `detail`); `counters` (`rows_read`, `rows_written`, `fullscan_steps`, `vm_steps`, `sort_ops`, `autoindex_rows`). With `--write`, also `changes`, `total_changes`, and `executions` |
| `timing` | `rounds`, `variant_faster_rounds`, `ratio`, and `baseline` / `variant` with `median_ns`, `p25_ns`, `p75_ns`, `min_ns`, `max_ns`. `null` when not timed; `ratio` is `null` when the baseline median is `0`. `noise_band`, `confidence_interval`, `median_difference_ns`, `effect`, and `unavailable_reason` describe the timing evidence below |
| `size_bytes` | `baseline`, `variant`, and `increase` (the whole database file, not the index alone; with `--migration`, the bytes in use instead, see [Batch comparisons](#batch-comparisons)) |
| `inputs` | `database`, `select`, and `index_sql` paths. With `--write`, `write` replaces `select` |
| `d1` | Present only with `--d1`: `binding`, `config`, `database_id`, `local_database`, `sqlite_version` (D1's 3.53.4), `sqlite_version_note`, and `caution` |
| `environment` | `qenome_version` (the same version as `--version`, from `build.zig.zon`), `sqlite_version`, `sqlite_source_id`, `zig_version`, `build_mode`, `os`, `arch`, `work_dir_parent` |
| `measurement` | Timing conditions: `runs_per_copy` (timed rounds per copy; `0` when not timed), `warmup`, `order`, `scope`, `cache`. With `--write`, `runs_per_copy` is the number of rolled-back executions per copy |
| `binds` | `number` and `type`; text also has `text_bytes`. `value` appears only with `--show-binds` |
| `warnings` | An array of `{code, message}` (`no_analyze_stats`, `data_too_small`, `bind_dependent_partial_index`); advisory, never changes verdict or exit |
| `sqlite` | Reserved, not emitted yet. `bundled_version` and `db_header_version`. Until then, the bundled version is `environment.sqlite_version` |

- String values write a backslash as `\\` and each byte that is not valid UTF-8 as `\xNN` (byte 0xFF becomes `\xff`), and the result is then escaped as JSON. A literal four-character `\xff` therefore becomes `\\xff` and is a different string from the byte 0xFF. To recover the original bytes, read `\\` as one backslash and `\xNN` as that byte, and leave everything else as it is. Paths, plan details, reasons, and bind text use this rule. Text values in the example rows use it too, surrounded by single quotes (for example `'\xff'`, which appears as `'\\xff'` in the JSON text); BLOBs are written as `x'00ff'`. Example values longer than 200 bytes are cut and followed by `...(N bytes)`.
- `binds` keeps the same secrecy as kv. Without `--show-binds`, only the number, the type, and the text length appear. A non-finite real value (`inf` or `-inf`) is written as a string, because JSON numbers cannot represent it.
- `row_differences` always has both counts. The example array keys are always present but empty unless `--show-rows` is set; human and kv use the same flag and print only the counts by default.
- `row_order` is a reference, not part of the result match.

</details>

### Exit status

| Code | Meaning |
| --- | --- |
| 0 | The result rows match |
| 1 | An input was rejected (unreadable file, invalid or rejected SQL, bind mismatch, index creation failure, rejected `--write` statement) |
| 2 | A usage error |
| 3 | The result rows differ, or a `--write` made a different change (`changes` or `total_changes`) |
| 4 | The results cannot be compared, a `--write` was not run because it reads the schema, the current time, or a nondeterministic function, or `--d1` cannot locate exactly one local database (no config, more than one config, an unreadable or invalid config, an unknown or duplicate binding, a missing database id, a local file that does not exist yet, or a local file that cannot be opened) |
| 5 | Cleanup failed after the comparison (this replaces 0; every other code is kept) |
| 6 | With `--migration`, the result rows matched but a query read or wrote more rows. Only the `--migration` batch path returns it |
| 124 | A time limit was reached (`--timeout-ms`) |
| 129 / 130 / 143 | Interrupted by `SIGHUP` / `SIGINT` / `SIGTERM` (POSIX) |

`--format json` reports the comparison result in `exit_code` as `0`, `3`, or `4`. The process can still exit with `5` after writing the JSON.

A `--batch` report can be written with exit `1`, `6`, or `124`. If stdout is the batch object, the run finished and the failures are in the report. If stdout is empty, the run stopped and stderr holds the error object.

### Timing evidence and advisory warnings

<details>
<summary>Timing evidence and advisory warnings in detail</summary>

Each timed round first runs the baseline SELECT twice (A/A), then runs one baseline/variant pair, alternating AB and BA. Both sessions are already warm from the compared run. A/A adds two baseline executions per round. The measured counters in the report still come only from the first compared SELECT; diagnostics and timed executions do not enter them. Warning checks run after timing, on sandbox copies only. No ANALYZE or PRAGMA optimize is run.

`timing.noise_band` reports the empirical 95th percentile of absolute differences between the two baseline A/A durations, using nearest rank `ceil(0.95*n)` and reporting `pairs`. This is a heuristic noise reference, not a confidence bound or a significance threshold with a calibrated false-positive rate. No observed A/A spread does not prove zero underlying variation.

`timing.median_difference_ns` is the median of the per-round differences `variant_i - baseline_i` (negative is faster), not the difference of the two medians and not a ratio. Existing `ratio` remains variant median / baseline median. `confidence_interval` uses sorted paired differences and a symmetric binomial sign interval for their population median. For zero-based endpoints `k` and `n-k-1`, choose the largest k with `P(Binomial(n,0.5) <= k) <= 0.025`; coverage is `1 - 2*P(...)`. `level` is the requested 0.95; `coverage` is the conservative binomial coverage under independent identically distributed continuous differences. This follows the [order-statistic approach described by NIST](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/mediancl.htm), without interpolation. It describes uncertainty in the median difference, not a future single duration. There is no resampling.

The interval is `null` with `unavailable_reason` `too-few-rounds` below six rounds (the widest finite interval has coverage 93.75% at n=5 and 96.875% at n=6), `zero-duration` when any timed duration is zero, or conservatively `no-observed-variation` when all paired differences are equal. These cases give `effect: insufficient-samples`, not a claim of precision at the clock resolution. Otherwise `effect` is `no-difference` if the absolute value of the median paired difference is at most the A/A noise reference or the interval includes zero; it is `faster` or `slower` only when both checks allow that direction. This auxiliary label never changes `verdict` or the exit code. Fixed A/A-before-A/B ordering, cache effects, temporal dependence, load drift, and small samples limit interpretation: nominal 95% coverage is not an exact guarantee for these machine timings or for production D1. The human output shows the median times and the direction from the paired rounds; it adds the size of the change only when the medians point the same way. When the paired rounds cannot judge the direction, it shows the median ratio without a direction and says that the direction is not determined. The evidence fields above stay in `kv` and `json`.

`warnings` is always an array, including with `--runs 0` or incomparable results. Its `{code, message}` entries also appear verbatim in human and kv output. `no_analyze_stats` means the candidate index's table has no non-empty `sqlite_stat1` entry in the baseline snapshot, even if other tables have statistics. This is an absence check, not a freshness/completeness check: a partial-index entry alone counts as present. `data_too_small` means a bounded `SELECT 1 ... LIMIT 1000` on that table returned fewer than 1000 rows. Reaching 1000 only establishes at least 1000 rows; statistics estimates, partial-index cardinality, SELECT result count, and rows read do not decide this warning. The threshold is a heuristic, not proof that larger data is representative. Warnings advise a representative, separately prepared copy; they do not suppress a row verdict or change exit codes. Diagnostic reads respect the existing per-statement timeout/cancellation; failures follow the existing error path.

`bind_dependent_partial_index` names a partial index that the variant plan uses only because the bound values satisfy its `WHERE` clause. Qenome reads the variant plan with the bound values and again with every parameter bound to `NULL`. If the partial index appears in the first plan and not the second, the message names it. `NULL` cannot prove a partial index's `WHERE` clause, so the difference means the index is usable because of the values: another value or parameter style can drop it, and an `improved` result then holds only for this run. The check needs only the variant plan, so it runs in every mode, including a variant-only `--migration` query. It is best-effort: when the extra plan or the index catalog cannot be read, including a time limit or an interruption, the warning is omitted and the comparison continues. It never changes the verdict, the exit code, or a batch count. In a batch report the entry is in `results[].comparison.warnings`, and the batch `human` output lists it under `Warnings` with the query and candidate.

</details>

## Rules

- Do not change the original database (open it read-only). `--write` runs only on the sandbox copies, inside a transaction that is rolled back.
- Never report a result that cannot be compared as a match or a success.
- Judge from the rows read, not from the time: a SELECT that reads no fewer rows is not an improvement. A write that writes more rows is `needs-check` even when it reads fewer rows.
- The size is the increase of the whole database file, not the size of the index alone. A `--migration` run measures the bytes in use instead, so a dropped index reports the freed bytes as a negative value.
- Reject multiple statements, writes outside `--write`, and dangerous DDL. A `--migration` file may hold several index and table changes, but only `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (not `AS SELECT`), and `ALTER TABLE` (ADD / RENAME / DROP COLUMN and RENAME TO). Data changes, `DROP TABLE`, `ATTACH`, `PRAGMA`, and other statements are rejected.
- Clean up connections and temporary files on success, failure, and interruption.
- Do not guess a D1 database file: stop when the binding does not resolve to exactly one file.

## Development checks

```sh
python3 scripts/check_all.py
```

The quality workflow in CI runs the same script. It checks the effective Zig version, runs `zig fmt --check .`, the build, the tests, and the architecture and comment checks in order, and stops at the first stage that fails. The last two stages check the [Quick start](#quick-start): `scripts/check_quick_start.py` runs the commands in this README as written and compares each result with its `# expect:` marker, and `README.ja.md` must hold the same commands. An example added to the Quick start needs that marker, so that CI checks it too, and the section keeps a checked example for `improved`, `no-effect`, and `incomparable`. Both Quick start stages run on Linux and macOS; on Windows they print a skip and the other stages still run.

The codebase carries no comments: explanations live in the README, and the checks are the source of truth for the rules they enforce.

`docs/demo-suggest.gif`, `docs/demo-candidates.gif`, and `docs/demo-migration.gif` are recorded with `vhs docs/demo-suggest.tape`, `vhs docs/demo-candidates.tape`, and `vhs docs/demo-migration.tape` from the repository root, after `zig build -Doptimize=ReleaseFast`. Each tape copies `examples/d1-toml` and `docs/demo` into a temporary directory and silences the terminal echo while it loads the sample, so the recording holds only the Qenome command and its output.

## License

Qenome is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.

The bundled SQLite amalgamation stays in the public domain, and the row-count patch in `vendor/sqlite3/patches` keeps its own notices. See [NOTICE](NOTICE) for both.
