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

It stops at the first failing stage and prints `check_all: failed at "<stage>" with exit code N`. It works from any directory, because it runs at the repository root. The stages are: verify the Zig version, `zig fmt --check .`, build, test, show the Python version, ruff, mypy, the architecture checker's self-test, the architecture check, the comment checker's self-test, the comment check, the npm publish-tree test, the record wrapper test, the Quick start checker's self-test, and the README Quick start. ruff and mypy run through `uv run --locked`, so this check needs uv 0.13.1 or newer. The required version is `required-version` under `[tool.uv]` in `pyproject.toml`. CI pins 0.13.1 in `.github/workflows/quality.yml`, so raise that floor as well when you raise the requirement.

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
