# Contributing to Qenome

`README.md` and the pages under `docs/` are the user guide. This file holds the build-from-source Quick start, the checks that CI runs, and how to update the golden test output. `AGENTS.md` records the repository rules and the workflow from branch to PR (language, dependencies, architecture, comments, and the PR body in `.github/pull_request_template.md`).

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

The seven examples run `zig-out/bin/qenome`. Each command ends with the result it has to report: `result` and `verdict` from the Summary (or `recommended` for a batch), and the exit status. `python3 scripts/check_all.py` and the quality workflow run these lines as written, so this file and the program stay in step. Only the first example runs the timing loop, with the default `--runs 10`, which keeps the medians steady on a busy machine. The verdict comes from the rows read and the rows written, not from the times, so the other examples pass `--runs 0`, use a mode that never times (`--batch`, `--suggest`), or return an incomparable result.

An index that removes the full scan. The candidate index turns `SCAN events` into `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`, the rows read fall from 200,000 to 101, and both copies return the same 100 rows.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234  # expect: result=match verdict=improved exit=0
```

An index on data you choose. `--seed-data testdata/seed.json` replaces the `events` rows in the sandbox copy, with the original database unchanged, by 50,000 deterministic rows. The same query then finds row `1234` among them, and the verdict stays `improved`. See [Generating sandbox data](docs/usage.md#generating-sandbox-data).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --seed-data testdata/seed.json --runs 0  # expect: result=match verdict=improved exit=0
```

An index that cannot help. The SELECT wraps the column in `lower()`, so SQLite cannot use the index on `status`, and the plan, the rows read, and the rows written stay the same.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/no-effect.sql testdata/cases/no-effect.index.sql --bind 1:text:ok --runs 0  # expect: result=match verdict=no-effect exit=0
```

An INSERT that a new index makes more expensive. `--write` compares one `INSERT`, `UPDATE`, `DELETE`, or `REPLACE` on both sandbox copies, inside a transaction that is rolled back. The candidate index on `customer_id` is not used by this INSERT, but each inserted row also updates the index: the rows written rise from 1 to 2, while both copies change the same row. The verdict is `needs-check` because the variant writes more, and the exit status stays 0. The original database is not changed.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --write testdata/cases/write.sql --index-sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 0  # expect: result=match verdict=needs-check exit=0
```

A SELECT whose rows cannot be compared. `ORDER BY random()` picks other rows on every run, so Qenome reports the rows as incomparable instead of claiming that they match, and it does not judge the comparison. The exit status 4 is the expected result here, not an error.

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/incomparable.sql testdata/cases/incomparable.index.sql  # expect: result=incomparable verdict=not-judged exit=4
```

A batch compares several queries with several candidate indexes in one run. `testdata/batch.json` pairs the improved and no-effect queries with both candidate indexes. Qenome reports one row per pair and recommends the candidate that helps without a mismatch, so only `cases/improved.index.sql` qualifies. See [Batch comparisons](docs/batch.md#batch-comparisons).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --batch testdata/batch.json  # expect: recommended=cases/improved.index.sql exit=0
```

A proposed index, without an index file. `--suggest` asks SQLite which index would help the SELECT, and Qenome compares that proposal with the same batch machinery. The proposal is labelled `suggested:1` and becomes the recommendation when it helps. See [Suggesting candidate indexes](docs/batch.md#suggesting-candidate-indexes).

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql --bind 1:int:1234 --suggest  # expect: recommended=suggested:1 exit=0
```

The first database build takes about a second, and the whole walkthrough about seven seconds, because only the first example runs the timing loop. `testdata/README.md` records the fixture, the queries, and their expected plan and counters.

## Workflow

The steps follow the work, and each one produces the material for one section of the pull request. The body comes from `.github/pull_request_template.md`.

1. Problem (PR section 1): before changing anything, write down who is affected, what goes wrong and what happens if it is left alone. Create one branch per issue from an up-to-date `origin/main`, named `<type>/<short-name>` with `<type>` one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci` or `chore`; leave the issue number out of the name.
2. Approaches (PR section 3): before implementing, list the approaches really considered and compare them on the same points, starting with whether each solves the problem. A purely mechanical change says why there is no comparison.
3. Implement (PR section 2): a behaviour change starts with the failing Zig test or accuracy case (see [Checks before you finish](AGENTS.md#checks-before-you-finish) in `AGENTS.md`). For an intended output change, regenerate the golden output with `python3 scripts/check_golden.py --update` and review the diff. Do not mix a behaviour change with a structural change (refactor), and stay within the issue's scope. `README.md` and `README.ja.md` move together (see the Language rule in `AGENTS.md`). A change to CLI behaviour, output or the README gets an entry under `[Unreleased]` in `CHANGELOG.md`; a change only to tests or checkers does not.
4. Verify (PR section 4): try the approaches, or say which were not tried and why, and record the result of each and why the chosen one won. For a change to CLI behaviour or output, to the npm launcher (`npm/`) or to the bundled skill (`skills/`, shown as a screenshot of an agent session that uses it; a wording-only change is exempt), capture a PNG or GIF of a real run during this step, before and after when the behaviour changes. A terminal screenshot is enough, and vhs is optional. The image adds to the golden and accuracy checks (see [Checks before you finish](AGENTS.md#checks-before-you-finish)); it does not replace them. No image is needed when the output is unchanged (for example a refactor whose golden and accuracy checks pass), or for a docs-, test-, checker- or build-only change; say why in section 4 on a line that starts with `No image:` and the reason, as in `No image: the golden output is unchanged`. Attach images to the PR (drag them into the GitHub form, or `gh pr create --attach` / `gh pr edit --attach`), keep them outside the repository, and do not commit them; the README demos in `docs/*.gif` are recorded only as [Golden output](#golden-output) describes. The repository is public: images must not show secrets, tokens, personal data or real user data.
5. Check (PR section 6): run `python3 scripts/check_all.py`, then reread `git diff origin/main...HEAD` before committing.
6. Commit and PR: commits follow Conventional Commits, `<type>(<scope>): <summary>` in English, with one logical change per commit; commit only the files the change needs. To update a branch, merge `origin/main` into it; do not rebase or force-push a pushed branch. The PR has a Conventional Commits title, and its body comes from `.github/pull_request_template.md` with the six headings verbatim, because `gh pr create --body` and `--body-file` do not load the template. Put `Closes #<n>` at the end of section 2, and attach the images. The `pr-format` check in CI reads the title and body on every pull request that is opened, edited or pushed to, and prints one line per problem. It rejects a title that is not Conventional Commits with one of the types above (a `Revert "…"` title passes), one of the six headings missing, repeated or out of order, an empty section (section 5 says `None.` when there is nothing to decide), the `Closes #<n>` placeholder left in place, a table whose second line is not a row of `---` cells, and a change under `src/`, `npm/` or `skills/` with no image and no `No image:` line in section 4.

## Development checks

```sh
python3 scripts/check_all.py
```

The quality workflow in CI runs the same script. It stops at the first stage that fails.

### Release

`.github/workflows/release.yml` calls that quality workflow before any other job. A tag push (`v*`) or a manual run builds the assets and runs the smoke test only after the call succeeds, and a tag creates the GitHub release only after those jobs succeed too. A failing call skips the build, the smoke test, and the release. The workflow fails before any asset is uploaded and before a GitHub release is created. The call runs both quality jobs on that commit: `verify` (`python3 scripts/check_all.py`, which includes the accuracy and golden checks) and `skill-examples`. GitHub uses the workflow file in the tagged commit, so the gate applies to tags of commits that contain it.

The stages are:

1. verify the effective Zig version
2. `zig fmt --check .`
3. build
4. the accuracy corpus check
5. test
6. show the Python version
7. ruff
8. `ruff format --check .`
9. mypy
10. the architecture checker's self-test
11. the architecture check
12. the comment checker's self-test
13. the comment check
14. the docs checker's self-test
15. the docs check
16. the PR format checker's self-test
17. the npm publish-tree test
18. the record wrapper test
19. the golden checker's self-test
20. the golden output check
21. the accuracy checker's self-test
22. the Quick start checker's self-test
23. the CONTRIBUTING Quick start

ruff, `ruff format` and mypy run through `uv run --locked`, so the checks need uv 0.13.1 or newer.

`scripts/check_docs.py` keeps the documentation in shape. It holds the list of pages cut from the README, checks that each has its `docs/ja/` pair with the same sequence of heading levels, caps the README and `AGENTS.md` line counts, and checks every relative link, anchor and image in `README.md`, `README.ja.md`, `AGENTS.md`, this file, `skills/qenome/SKILL.md` and the pages under `docs/`. Add a page to its list when you add one; a new `docs/*.md` that is neither a paired page nor a listed developer page fails the check.

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

The codebase carries no comments: explanations live in the README and the pages under `docs/`, and the checks are the source of truth for the rules they enforce.

`docs/demo-suggest.gif`, `docs/demo-candidates.gif`, and `docs/demo-migration.gif` are recorded with `vhs docs/demo-suggest.tape`, `vhs docs/demo-candidates.tape`, and `vhs docs/demo-migration.tape` from the repository root, after `zig build -Doptimize=ReleaseFast`. Each tape copies `examples/d1-toml` and `docs/demo` into a temporary directory and silences the terminal echo while it loads the sample, so the recording holds only the Qenome command and its output.
