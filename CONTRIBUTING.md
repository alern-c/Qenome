# Contributing to Qenome

`README.md` is the user guide. This file holds the build-from-source Quick start, the checks that CI runs, and how to update the golden test output. `AGENTS.md` records the repository rules (language, dependencies, architecture, and comments).

## Build from source

Qenome needs Zig 0.17.0, the `minimum_zig_version` in `build.zig.zon` (CI builds with exactly this version). SQLite is vendored in `vendor/sqlite3` and compiled in, so no system SQLite is needed.

```sh
zig build
./zig-out/bin/qenome --version
```

`zig build` writes the binary to `zig-out/bin/qenome` (`zig-out\bin\qenome.exe` on Windows). For timings that match a release build, build with `zig build -Doptimize=ReleaseFast`.

## Quick start

This walkthrough creates the test database, builds Qenome, and runs seven examples. Run the commands from the repository root, one block at a time, on Linux or macOS. They need Zig 0.17.0 (see [Build from source](#build-from-source)) and the `sqlite3` command-line tool, which loads the SQL files into the new database.

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

The seven examples run `zig-out/bin/qenome`. Each command ends with the result it has to report: `result` and `verdict` from the Summary (or `recommended` for a batch), and the exit status. `python3 scripts/check_all.py` and the quality workflow run these lines as written, so this file and the program stay in step. `--runs 40` keeps the medians steady on a busy machine; the default is `10`.

An index that removes the full scan. The candidate index turns `SCAN events` into `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`, the rows read fall from 200,000 to 101, and both copies return the same 100 rows.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 40  # expect: result=match verdict=improved exit=0
```

An index on data you choose. `--seed-data testdata/seed.json` replaces the `events` rows in the sandbox copy, with the original database unchanged, by 50,000 deterministic rows. The same query then finds row `1234` among them, and the verdict stays `improved`. See [Generating sandbox data](README.md#generating-sandbox-data).

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

A batch compares several queries with several candidate indexes in one run. `testdata/batch.json` pairs the improved and no-effect queries with both candidate indexes. Qenome reports one row per pair and recommends the candidate that helps without a mismatch, so only `cases/improved.index.sql` qualifies. See [Batch comparisons](README.md#batch-comparisons).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --batch testdata/batch.json  # expect: recommended=cases/improved.index.sql exit=0
```

A proposed index, without an index file. `--suggest` asks SQLite which index would help the SELECT, and Qenome compares that proposal with the same batch machinery. The proposal is labelled `suggested:1` and becomes the recommendation when it helps. See [Suggesting candidate indexes](README.md#suggesting-candidate-indexes).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql --bind 1:int:1234 --suggest  # expect: recommended=suggested:1 exit=0
```

The first database build takes about a second, and each timed example a few seconds. `testdata/README.md` records the fixture, the queries, and their expected plan and counters.

## Development checks

```sh
python3 scripts/check_all.py
```

The quality workflow in CI runs the same script. It checks the effective Zig version, runs `zig fmt --check .`, the build, the tests, the Python checks, the architecture and comment checks, the npm staging test, the golden output, and the Quick start above, in order, and stops at the first stage that fails.

`scripts/check_quick_start.py` runs the commands in the [Quick start](#quick-start) as written and compares each result with its `# expect:` marker. An example added to the Quick start needs that marker, so that CI checks it too, and the section keeps a checked example for `improved`, `no-effect`, and `incomparable`. The check also requires `README.md` and `README.ja.md` to link to this file. The Quick start stages run on Linux and macOS; on Windows they print a skip and the other stages still run.

### Golden output

`scripts/check_golden.py` pins the human and JSON output of the main modes against the fixture database:

- one comparison
- `--write`
- `--batch`
- `--suggest`

The comparison is deterministic. Every command runs with `--runs 0`, so no timing is recorded. The script sets `TMPDIR` to a temporary directory and writes it as `<work-dir-parent>`, and it writes the `qenome_version`, `build_mode`, `os`, and `arch` fields as placeholders. The debug-build note is dropped, and trailing spaces at the end of a line are dropped. Rows, plans, sizes, verdicts, and warning text stay exact.

After an intentional output change, regenerate the files and review the diff:

```sh
python3 scripts/check_golden.py --update
git diff -- testdata/golden
```

The files are `testdata/golden/*.human.txt` and `testdata/golden/*.json`. `--d1` is not covered there: it needs a wrangler install and a generated local D1 state. The D1 warning path is covered by `src/cli/d1_tests.zig`.

The codebase carries no comments: explanations live in the README, and the checks are the source of truth for the rules they enforce.

`docs/demo-suggest.gif`, `docs/demo-candidates.gif`, and `docs/demo-migration.gif` are recorded with `vhs docs/demo-suggest.tape`, `vhs docs/demo-candidates.tape`, and `vhs docs/demo-migration.tape` from the repository root, after `zig build -Doptimize=ReleaseFast`. Each tape copies `examples/d1-toml` and `docs/demo` into a temporary directory and silences the terminal echo while it loads the sample, so the recording holds only the Qenome command and its output.
