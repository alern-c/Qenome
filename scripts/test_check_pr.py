import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_pr.py")

FAILURES: list[str] = []

GOOD_TITLE = "ci: check the PR title and body"

GOOD_BODY = """## 1. What was the problem

Who is affected and what goes wrong.

## 2. What was changed

What the diff does.

## 3. What was considered

Two approaches were compared.

## 4. Verification and conclusion

What was run to check each claim.

## 5. Decisions or agreement needed

None.

## 6. Quality checks

- `python3 scripts/check_all.py` passed
"""

OUT_OF_ORDER_BODY = """## 1. What was the problem

Text.

## 3. What was considered

Text.

## 2. What was changed

Text.

## 4. Verification and conclusion

Text.

## 5. Decisions or agreement needed

None.

## 6. Quality checks

Text.
"""

PR_108_TITLE = "docs: add the shared contributor workflow and PR template"

PR_108_FILES = [
    ".github/pull_request_template.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "scripts/check_comments.py",
]

PR_108_BODY = """## 1. What was the problem

Every tool and person that works on Qenome reads `AGENTS.md`, and the checks in
`python3 scripts/check_all.py` already apply to all of them. The process around those checks did not:
test-first, a self-review of the diff, Conventional Commits and the six-section PR body lived only in
the owner's private skills. A contributor using another tool had no shared statement of that
process, and the repository had no PR template.

## 2. What was changed

`AGENTS.md` now has a six-step `## Workflow` list, one line per step, each naming the PR section it
produces. The full rules are in a new `## Workflow` section in `CONTRIBUTING.md`.

| File | Before | After |
| --- | --- | --- |
| `AGENTS.md` | No process after the checks | Six one-line Workflow steps |
| `.github/pull_request_template.md` | None | Six fixed sections |
| `scripts/check_comments.py` | The template would be unclassified | One exclusion line |

The CLI, its output and the README are unchanged.

## 3. What was considered

| View | Keep the process in private skills | Enforce the PR format in CI | A shared Workflow and PR template |
| --- | --- | --- | --- |
| Solves the problem | No | Partly | Yes |
| Change size | None | A new workflow and a parser | Four files |
| Risk and reversibility | The gap stays | A false rejection blocks a PR | Text only |

CI enforcement is the natural next step if malformed bodies keep appearing, but it is out of scope
here.

## 4. Verification and conclusion

- `python3 scripts/check_all.py` passes all 21 stages.
- A read-only review of the exact diff against `origin/main` found no blocker.
- No image is attached: this PR changes no CLI behaviour or output, `npm/` or `skills/`.
- Conclusion: the shared Workflow and template are adopted.

## 5. Decisions or agreement needed

None.

## 6. Quality checks

- ✅ `python3 scripts/check_all.py` passed (21 stages)
- ✅ Read-only review of the exact diff against `origin/main`; no blocker
- CHANGELOG: not needed because this changes contributor docs, not CLI behaviour

<details>
<summary>Technical details</summary>

- `AGENTS.md`: 56 lines, under the 60-line cap in `scripts/check_docs.py`.
- Commands: `python3 scripts/check_all.py` gave `check_all: ok (21 stages)`.

</details>

<!-- CURSOR_SUMMARY -->
---

> [!NOTE]
> **Low Risk**
> Documentation and a single checker exclusion only; no runtime or CI enforcement of PR format.
>
> **Overview**
> Adds `.github/pull_request_template.md` with six fixed sections, and expands `AGENTS.md` and
> `CONTRIBUTING.md`. `scripts/check_comments.py` excludes the template.
<!-- /CURSOR_SUMMARY -->
"""


def load_checker():
    spec = importlib.util.spec_from_file_location("check_pr", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def variant(old, new):
    if old not in GOOD_BODY:
        raise RuntimeError("the sample body has no " + old)
    return GOOD_BODY.replace(old, new)


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def expect_clean(name, found):
    expect(name, found == [], found)


def expect_problem(name, found, mention):
    expect(
        name,
        len(found) == 1 and mention in found[0],
        "want one problem mentioning " + mention + ", got " + str(found),
    )


def main():
    checker = load_checker()
    check = checker.check

    def run(title: str = GOOD_TITLE, body: str | None = GOOD_BODY, files: list[str] | None = None):
        return check(title, body, list(files or []))

    expect_clean("a valid title and body pass", run())
    expect_clean("the PR body of 108 passes with its changed files",
                 run(PR_108_TITLE, PR_108_BODY, PR_108_FILES))

    expect_clean("a scope passes", run(title="feat(cli): add a check"))
    expect_clean("a breaking change marker passes", run(title="fix!: drop the flag"))
    expect_clean("a Revert title passes", run(title='Revert "feat(cli): add a check"'))
    expect_clean("a Revert title with quotes inside passes",
                 run(title='Revert "fix: handle "none""'))
    expect_clean("a Revert of a Revert title passes",
                 run(title='Revert "Revert "feat: x""'))
    expect_clean("a Revert title with the PR number passes",
                 run(title='Revert "feat: add a check" (#42)'))
    expect_problem("a Revert title without quotes fails",
                   run(title="Revert feat: x"), "title:")
    expect_problem("an unknown type fails", run(title="wip: add a check"), "title:")
    expect_problem("a missing space after the colon fails",
                   run(title="feat(cli):add a check"), "title:")
    expect_problem("an empty summary fails", run(title="feat(cli): "), "title:")

    expect_problem("a missing heading fails",
                   run(body=variant("## 6. Quality checks", "## Notes")),
                   '"## 6. Quality checks" is missing')
    expect_problem("a duplicated heading fails",
                   run(body=GOOD_BODY + "\n## 5. Decisions or agreement needed\n\nNone.\n"),
                   "appears 2 times")
    expect_problem("headings out of order fail", run(body=OUT_OF_ORDER_BODY), "is out of order")
    expect_clean("a trailing space after a heading passes",
                 run(body=variant("## 3. What was considered", "## 3. What was considered  ")))
    expect_clean("another ## heading is allowed", run(body=GOOD_BODY + "\n## Notes\n\nExtra.\n"))
    expect_problem("another ## heading ends a section",
                   run(body=variant("What the diff does.", "## Notes\n\nText.")),
                   '"## 2. What was changed" is empty')
    expect_clean("a ### heading stays inside its section",
                 run(body=variant("What the diff does.", "### Sub\n\nText.")))

    expect_problem("a section holding only a details block fails",
                   run(body=variant("What was run to check each claim.",
                                    "<details>\n<summary>Technical details</summary>\n</details>")),
                   '"## 4. Verification and conclusion" is empty')
    expect_problem("a whitespace-only section fails",
                   run(body=variant("What was run to check each claim.", "   ")),
                   '"## 4. Verification and conclusion" is empty')
    expect_clean("a details block with content passes",
                 run(body=variant("What was run to check each claim.",
                                  "<details>\n<summary>Technical details</summary>\n\nText.\n\n</details>")))
    expect_clean("None. in section 5 passes", run(body=variant("None.", "None.")))

    expect_problem("the Closes placeholder fails",
                   run(body=variant("What the diff does.", "What the diff does.\n\nCloses #<n>")),
                   '"Closes #<n>"')
    expect_clean("a real Closes line passes",
                 run(body=variant("What the diff does.", "What the diff does.\n\nCloses #42")))
    expect_clean("the placeholder inside inline code passes",
                 run(body=variant("What the diff does.",
                                  "Delete the `Closes #<n>` line when there is no issue.")))

    expect_clean("a table with a separator row passes",
                 run(body=variant("What the diff does.",
                                  "| File | Before | After |\n| --- | --- | --- |\n| `AGENTS.md` | None | One step |")))
    expect_problem("a table without a separator row fails",
                   run(body=variant("What the diff does.",
                                    "| File | Before |\n| `AGENTS.md` | None |")),
                   "no separator row of --- cells")
    expect_clean("a blockquote line is not a table",
                 run(body=variant("What the diff does.", "> | a |\n> | b |")))
    expect_clean("a | line inside a code block is not a table",
                 run(body=variant("What the diff does.",
                                  "Text.\n\n```\n| a |\n| b |\n```")))
    expect_clean("an indented table passes",
                 run(body=variant("What the diff does.",
                                  "  | File | Before |\n  | --- | --- |\n  | `a` | None |")))
    expect_clean("an aligned separator row passes",
                 run(body=variant("What the diff does.",
                                  "| File | Before |\n| :--- | ---: |\n| `a` | None |")))
    expect_problem("a separator row with too few hyphens fails",
                   run(body=variant("What the diff does.",
                                    "| File | Before |\n| -- | -- |\n| `a` | None |")),
                   "no separator row of --- cells")

    expect_problem("a src change without an image fails", run(files=["src/main.zig"]),
                   "needs an image in the body")
    expect_clean("a src change with an image passes",
                 run(files=["src/main.zig"],
                     body=variant("What was run to check each claim.",
                                  "A run: ![before and after](https://example.com/shot.png)")))
    expect_clean("an img tag passes",
                 run(files=["npm/qenome/package.json"],
                     body=variant("What was run to check each claim.",
                                  '<img src="https://example.com/shot.png" alt="run">')))
    expect_clean("a user-attachments URL passes",
                 run(files=["skills/qenome/SKILL.md"],
                     body=variant("What was run to check each claim.",
                                  "See https://github.com/user-attachments/assets/1234 for the run.")))
    expect_clean("a No image line passes",
                 run(files=["src/main.zig"],
                     body=variant("What was run to check each claim.",
                                  "No image: the output is unchanged.")))
    expect_clean("a bulleted No image line passes",
                 run(files=["src/main.zig"],
                     body=variant("What was run to check each claim.",
                                  "- No image: the output is unchanged.")))
    expect_problem("No image without a reason fails",
                   run(files=["src/main.zig"],
                       body=variant("What was run to check each claim.", "No image:")),
                   "needs an image in the body")
    expect_problem("a No image line outside section 4 fails",
                   run(files=["src/main.zig"],
                       body=variant("What the diff does.", "No image: docs only.")),
                   "needs an image in the body")
    expect_problem("No image is attached does not count",
                   run(files=["src/main.zig"],
                       body=variant("What was run to check each claim.",
                                    "No image is attached: the output is unchanged.")),
                   "needs an image in the body")
    expect_clean("a change outside the image directories needs no image",
                 run(files=["docs/usage.md", "scripts/check_pr.py"]))
    expect_clean("an image outside section 4 passes",
                 run(files=["src/main.zig"],
                     body=variant("Who is affected and what goes wrong.",
                                  "A run: ![before](https://example.com/a.png)")))
    expect_problem("an unfinished markdown image does not count",
                   run(files=["src/main.zig"],
                       body=variant("What was run to check each claim.",
                                    "A run: ![before and after](")),
                   "needs an image in the body")

    expect_clean("a CRLF body passes", run(body=GOOD_BODY.replace("\n", "\r\n")))
    null_body = run(body=None)
    expect(
        "a null body fails on the missing headings",
        len(null_body) == 6 and '"## 1. What was the problem" is missing' in null_body[0],
        null_body,
    )
    expect_clean("an HTML comment is ignored",
                 run(body=GOOD_BODY + "\n<!--\n## 9. Comment\n\nCloses #<n>\n-->\n"))
    expect_clean("a heading inside a code block is not a duplicate",
                 run(body=GOOD_BODY + "\n```\n## 1. What was the problem\n```\n"))
    expect_clean("an unclosed fence runs to the end of the body",
                 run(body=GOOD_BODY + "\n```\n| a |\n| b |\nCloses #<n>\n"))
    expect_clean("a tilde fence hides a heading",
                 run(body=GOOD_BODY + "\n~~~\n## 6. Quality checks\n~~~\n"))
    expect_clean("a shorter closing fence does not close the block",
                 run(body=GOOD_BODY + "\n````\n```\nCloses #<n>\n"))
    expect_problem("a longer closing fence closes the block",
                   run(body=GOOD_BODY + "\n```\n`````\nCloses #<n>\n"),
                   '"Closes #<n>"')
    expect(
        "a multi-line git diagnostic becomes one line",
        checker.one_line("error: could not\nresolve HEAD^1\n") == "error: could not resolve HEAD^1",
        checker.one_line("error: could not\nresolve HEAD^1\n"),
    )

    if FAILURES:
        print("check_pr self-test: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("check_pr self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
