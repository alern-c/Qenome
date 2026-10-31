# AGENTS.md

Qenome is a Zig CLI that compares the change one candidate `CREATE INDEX` makes to a single local SQLite `SELECT`. `README.md` (Japanese translation: `README.ja.md`) is the source of truth for usage, output and exit codes. This file holds only the facts about this repository that any AI tool needs so that every tool follows the same steps.

## Language

Commit messages, PR titles and bodies, issues, CHANGELOG, code comments and docs are written in English. `README.ja.md` is the only Japanese file; it is a maintained translation and must be updated whenever `README.md` changes. Past history is not rewritten: text that predates this rule keeps its language until that file is next edited (for example the release notes already in `CHANGELOG.md` and `testdata/README.md`).

## Build and test

```sh
zig build
zig build test
```

The Zig version is pinned by `minimum_zig_version` in `build.zig.zon` (currently 0.17.0). The checks do not pass when `zig version` differs.

## Checks before you finish

Before you report a finished task, always run this one command. The quality workflow in CI calls the same script, so the local and CI checks are identical.

```sh
python3 scripts/check_all.py
```

It stops at the first failing stage and prints `check_all: failed at "<stage>" with exit code N`. It works from any directory, because it runs at the repository root. The stages are: verify the Zig version, `zig fmt --check .`, build, the accuracy corpus check, test, show the Python version, ruff, mypy, the architecture checker's self-test, the architecture check, the comment checker's self-test, the comment check, the npm publish-tree test, the record wrapper test, the golden checker's self-test, the golden output check, the accuracy checker's self-test, the Quick start checker's self-test, and the CONTRIBUTING Quick start. ruff and mypy run through `uv run --locked`, so this check needs uv 0.13.1 or newer. The required version is `required-version` under `[tool.uv]` in `pyproject.toml`. CI pins 0.13.1 in `.github/workflows/quality.yml`, so raise that floor as well when you raise the requirement. The accuracy corpus in `testdata/accuracy/` runs with 3 repeats: a change to a verdict, plan reading, counters or warnings must keep `scripts/check_accuracy.py` green, and a new rule needs a case.

## Workflow

1. Problem (PR section 1): before changing anything, write down who is affected, what goes wrong and what happens if it is left alone. Create one branch per issue from an up-to-date `origin/main`, named `<type>/<short-name>` with `<type>` one of `feat`, `fix`, `docs`, `test`, `refactor` or `chore`; leave the issue number out of the name.
2. Approaches (PR section 3): before implementing, list the approaches really considered and compare them on the same points, starting with whether each solves the problem. A purely mechanical change says why there is no comparison.
3. Implement (PR section 2): a behaviour change starts with the failing Zig test or accuracy case (see "Checks before you finish"). For an intended output change, regenerate the golden output with `python3 scripts/check_golden.py --update` and review the diff. Do not mix a behaviour change with a structural change (refactor), and stay within the issue's scope. `README.md` and `README.ja.md` move together (see Language). A change to CLI behaviour, output or the README gets an entry under `[Unreleased]` in `CHANGELOG.md`; a change only to tests or checkers does not.
4. Verify (PR section 4): try the approaches, or say which were not tried and why, and record the result of each and why the chosen one won. For a change to CLI behaviour or output, to the npm launcher (`npm/`) or to the bundled skill (`skills/`, shown as a screenshot of an agent session that uses it; a wording-only change is exempt), capture a PNG or GIF of a real run during this step, before and after when the behaviour changes. A terminal screenshot is enough, and vhs is optional. The image adds to the golden and accuracy checks (see "Checks before you finish"); it does not replace them. No image is needed when the output is unchanged (for example a refactor whose golden and accuracy checks pass), or for a docs-, test-, checker- or build-only change; say why in section 4. Attach images to the PR (drag them into the GitHub form, or `gh pr create --attach` / `gh pr edit --attach`), keep them outside the repository, and do not commit them; the README demos in `docs/*.gif` are recorded only as `CONTRIBUTING.md` describes. The repository is public: images must not show secrets, tokens, personal data or real user data.
5. Check (PR section 6): run `python3 scripts/check_all.py`, then reread `git diff origin/main...HEAD` before committing.
6. Commit and PR: commits follow Conventional Commits, `<type>(<scope>): <summary>` in English, with one logical change per commit; commit only the files the change needs. To update a branch, merge `origin/main` into it; do not rebase or force-push a pushed branch. The PR has a Conventional Commits title, and its body comes from `.github/pull_request_template.md` with the six headings verbatim, because `gh pr create --body` and `--body-file` do not load the template. Put `Closes #<n>` at the end of section 2, and attach the images.

## Dependencies

Code (Zig in `src/`, Python in `scripts/`, JavaScript in `npm/`) uses only each language's standard library. The only external code the program uses is SQLite, vendored in `vendor/sqlite3/`. The only other allowed code is the development tools used by the checks (ruff and mypy, in the `dev` group of `pyproject.toml`). Ask a human for approval before adding any other dependency.

## Architecture

The target dependency order is:

`contract → sqlite → sql → engine → measure → verdict → sandbox → modes → report → cli → main`

A lower layer never imports a higher one. `d1/` and `skill/` are independent components outside the chain: each sits at the rank of the layer it may import, and the layers above that rank may import it. Modes only return report data; only `report/` and `cli/` write to stdout or stderr.

Folders and files that exist now (v0.3.7):

| Layer | Path |
| --- | --- |
| contract | `src/contract/` |
| sqlite | `src/sqlite.zig` |
| sql | `src/sql/` |
| engine | `src/db.zig`, `src/result.zig` |
| cli | `src/cli.zig`, `src/cli/` |
| main | `src/main.zig`, `src/root.zig` |
| d1 (independent) | `src/d1/` |

Planned for v0.3.8: split `src/db.zig` into `src/engine/*`, move measure, verdict and sandbox out of `src/cli/`, move the remaining D1 code into `src/d1/`, and split the report out of `src/cli/report.zig`. Planned for v0.3.9: add `src/modes/`, replace the parsed arguments with a `Command` union, and split `src/cli/tests.zig`.

## Sources of the rules

- Architecture boundaries are the source of truth in `scripts/check_architecture.py`; its self-test is `scripts/test_check_architecture.py`. The script owns `APPROVED_FILES` (the only files allowed under `src/`), the import table for every file, `LAYERS` (which layer each folder or file belongs to), `LINE_LIMITS` (the recorded line count of the largest files) with `MAX_LINES` (the cap for a file the table does not list), `WRITE_ALLOWED` with `WRITE_DEBT` (where stdout and stderr may be written), and the contract values and codes. Add the file or folder to these tables whenever you add one; an unclassified file fails the check.
- The contract values (JSON schema versions, exit codes and warning codes) are defined only in `src/contract/values.zig`. Use an import from there; a second definition, including a second copy of a code string, fails the check. `ExitCode` may stay as an alias of the contract type.
- A file must not grow past its recorded line count. Split the file instead of raising the number; raising it is a deliberate decision for a human.
- Do not add comments to code. Documentation belongs in `README.md` / `README.ja.md`. The rule's source of truth is `scripts/check_comments.py`; its self-test is `scripts/test_check_comments.py`. The language rule above sets the language of the text that exists; it does not allow new comments.
- `check_comments.py` classifies every tracked file as either checked for comments or excluded. When you add a new kind of file, decide whether the check can handle it or list it in `EXCLUDED_FILES`; a file left unclassified fails the check.

## npm

Only `.version` in `build.zig.zon` carries the npm version. Keep `version` at `0.0.0` and `private` at `true` in `npm/*/package.json`. `python3 scripts/stage_npm.py` builds the publish tree in `dist/npm/`. The steps are in `docs/npm.md`.

## CLAUDE.md

`CLAUDE.md` is a relative symlink to this file. Write the content only in `AGENTS.md`.
