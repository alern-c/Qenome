# AGENTS.md

Qenome is a Zig CLI that compares the change one candidate `CREATE INDEX` makes to a single local SQLite `SELECT`. `README.md` and the pages under `docs/` are the source of truth for usage, output and exit codes. This file holds the rules that every AI tool follows, one line each, and links to the page that explains each one.

## Language

Commit messages, PR titles and bodies, issues, CHANGELOG and code comments are written in English, and so are the docs. The maintained translations are `README.ja.md` and the pages under `docs/ja/`, one for every page cut from the README; update the translation in the same change as the English page. `docs/npm.md` and `testdata/README.md` are older Japanese text that predates this rule. Past history is not rewritten: text that predates the rule keeps its language until that file is next edited (for example the release notes already in `CHANGELOG.md`).

## Build and test

- Build with `zig build` and test with `zig build test`.
- The Zig version is pinned by `minimum_zig_version` in `build.zig.zon` (currently 0.17.0); the checks fail when `zig version` differs.

## Checks before you finish

- Run `python3 scripts/check_all.py` before you report a finished task. CI runs the same script.
- ruff and mypy run through `uv run --locked`, so the checks need uv 0.13.1 or newer (`required-version` under `[tool.uv]` in `pyproject.toml`). CI pins 0.13.1 in `.github/workflows/quality.yml`, so raise that floor as well when you raise the requirement.
- The stages, and what each one covers, are listed once in [the development checks](CONTRIBUTING.md#development-checks).
- A change to a verdict, plan reading, counters or warnings must keep `python3 scripts/check_accuracy.py` green, and a new rule needs a case in `testdata/accuracy/`.
- A file must not grow past the line count its check records. Split the file instead of raising the number; raising it is a deliberate decision for a human.

## Workflow

1. Problem (PR section 1): who is affected, what goes wrong, what happens if it is left alone, and one branch per issue from an up-to-date `origin/main`, named `<type>/<short-name>` (feat, fix, docs, test, refactor or chore; no issue number).
2. Approaches (PR section 3): the approaches really considered, compared on the same points, starting with whether each solves the problem; a purely mechanical change says why there is no comparison.
3. Implement (PR section 2): a failing Zig test or accuracy case first for a behaviour change, golden regeneration for an intended output change, no mixed behaviour and structural change, stay in scope, and the README/CHANGELOG rules.
4. Verify (PR section 4): try the approaches or say why not, record each result and why the chosen one won; a change to CLI behaviour or output, `npm/` or `skills/` attaches a PNG/GIF of a real run and does not commit it.
5. Check (PR section 6): run `python3 scripts/check_all.py`, then reread `git diff origin/main...HEAD`.
6. Commit and PR: Conventional Commits `<type>(<scope>): <summary>` in English, one logical change per commit, commit only the files the change needs; merge `origin/main` to update, no rebase or force-push; PR title in Conventional Commits, body from the template with the six headings verbatim, `Closes #<n>` at the end of section 2.

The details, including every evidence rule, are in [the workflow](CONTRIBUTING.md#workflow).

## Dependencies

- Code (Zig in `src/`, Python in `scripts/`, JavaScript in `npm/`) uses only each language's standard library. The only external code the program uses is SQLite, vendored in `vendor/sqlite3/`. The only other allowed code is the development tools used by the checks (ruff and mypy, in the `dev` group of `pyproject.toml`).
- Ask a human for approval before adding any other dependency.

## Architecture

- The dependency order, the folder table and the plans are in [docs/architecture.md](docs/architecture.md). The source of truth is `scripts/check_architecture.py`; add every new file or folder to its tables.
- The contract values are defined only in `src/contract/values.zig`; a second definition, including a second copy of a code string, fails the check.

## Documentation

- The README is an index: an introduction, the first example, and links to `docs/`. Put details on a `docs/` page, with its `docs/ja/` pair.
- Do not add comments to code. The source of truth is `scripts/check_comments.py`; when you add a new kind of file, check it or list it in `EXCLUDED_FILES`.
- When you add a page, register its English and Japanese pair in `scripts/check_docs.py`. That check owns the page list, the README line caps, the link, anchor and image checks, and the heading-pair check.

## npm

- Only `.version` in `build.zig.zon` carries the npm version. Keep `version` at `0.0.0` and `private` at `true` in `npm/*/package.json`.
- The publish steps are in [docs/npm.md](docs/npm.md).

## CLAUDE.md

`CLAUDE.md` is a relative symlink to this file. Write the content only in `AGENTS.md`.
