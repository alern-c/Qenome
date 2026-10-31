import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
POSTER = os.path.join(HERE, "post_review_findings.py")

FAILURES: list[str] = []

FIRST_PATCH = "\n".join(
    [
        "@@ -1,4 +1,6 @@",
        " import os",
        "+import re",
        " import sys",
        " ",
        "-x = 1",
        "+x = 2",
        "+y = 3",
    ]
)

SECOND_PATCH = "\n".join(
    [
        "@@ -20,4 +22,5 @@ def main():",
        " a",
        "-old",
        "\\ No newline at end of file",
        "+new",
        " c",
    ]
)

FILES = [
    {"filename": "scripts/post_review_findings.py", "status": "modified", "patch": FIRST_PATCH},
    {"filename": "docs/removed.md", "status": "removed", "patch": SECOND_PATCH},
    {"filename": "npm/logo.png", "status": "modified"},
]


def load_poster():
    spec = importlib.util.spec_from_file_location("post_review_findings", POSTER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + POSTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(name, condition, detail=None):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def finding(path="scripts/post_review_findings.py", line=3, severity="major", body="A problem."):
    return {"path": path, "line": line, "severity": severity, "body": body}


def main():
    poster = load_poster()

    expect(
        "a hunk tells the lines of the head that a comment may use",
        poster.hunk_lines(FIRST_PATCH) == {1, 2, 3, 4, 5, 6},
        poster.hunk_lines(FIRST_PATCH),
    )
    expect(
        "a removed line takes no number and a no-newline marker keeps counting",
        poster.hunk_lines(SECOND_PATCH) == {22, 23, 24},
        poster.hunk_lines(SECOND_PATCH),
    )
    expect(
        "a no-newline marker after an added line adds no line",
        poster.hunk_lines("@@ -1,1 +1,2 @@\n a\n+b\n\\ No newline at end of file") == {1, 2},
        poster.hunk_lines("@@ -1,1 +1,2 @@\n a\n+b\n\\ No newline at end of file"),
    )
    expect("an empty patch covers nothing", poster.hunk_lines("") == set(), poster.hunk_lines(""))
    expect(
        "the hunk of a patch rises from its start",
        poster.hunk_lines("@@ -1 +7 @@\n+a\n+b") == {7, 8},
        poster.hunk_lines("@@ -1 +7 @@\n+a\n+b"),
    )
    expect(
        "a line that is neither context nor a change ends the hunk",
        poster.hunk_lines("@@ -1,2 +1,2 @@\n+a\nbogus\n+b") == {1},
        poster.hunk_lines("@@ -1,2 +1,2 @@\n+a\nbogus\n+b"),
    )

    allowed = poster.diff_lines(FILES)
    expect("only a file with a patch is in the diff", sorted(allowed) == ["scripts/post_review_findings.py"], allowed)
    expect("a removed file is not in the diff", "docs/removed.md" not in allowed, allowed)
    kept = allowed["scripts/post_review_findings.py"]
    expect("a file with a patch keeps the lines of its hunks", kept == {1, 2, 3, 4, 5, 6}, kept)

    good = finding()
    findings, skipped = poster.clean_findings([good])
    expect("a well-formed finding passes", findings == [good] and skipped == 0, (findings, skipped))

    bad = [
        "text",
        {"path": "a.py", "line": True, "body": "b"},
        {"path": "a.py", "line": 0, "body": "b"},
        {"path": "/etc/passwd", "line": 1, "body": "b"},
        {"path": "../secret.py", "line": 1, "body": "b"},
        {"path": "a//b.py", "line": 1, "body": "b"},
        {"path": "a\\b.py", "line": 1, "body": "b"},
        {"path": "a.py", "line": 1, "body": "   "},
        {"path": "", "line": 1, "body": "b"},
        {"path": "a.py", "line": 1, "severity": "b", "body": 7},
    ]
    findings, skipped = poster.clean_findings([good] + bad)
    expect("a finding without a usable path, line and body is skipped", findings == [good] and skipped == 10, skipped)

    findings, _ = poster.clean_findings([{"path": "./a.py", "line": 1, "severity": "  BLOCKER ", "body": "  text  "}])
    expect(
        "the path, the severity and the body are cleaned",
        findings == [{"path": "a.py", "line": 1, "severity": "BLOCKER", "body": "text"}],
        findings,
    )
    findings, _ = poster.clean_findings([{"path": "a.py", "line": 1, "severity": "see the note", "body": "t"}])
    expect("an unusable severity is dropped", findings[0]["severity"] == "see the note", findings)
    findings, _ = poster.clean_findings([{"path": "a.py", "line": 1, "severity": "#1 urgent", "body": "t"}])
    expect("a severity with a markdown character is dropped", findings[0]["severity"] == "", findings)

    findings, _ = poster.clean_findings([{"path": "a.py", "line": "12", "body": "t"}])
    expect("a line written as a number string passes", findings[0]["line"] == 12, findings)
    expect(
        "a fenced JSON body loses the fence",
        poster.unfence("```json\n[1]\n```") == "[1]",
        poster.unfence("```json\n[1]\n```"),
    )
    expect("a plain JSON body keeps its text", poster.unfence(" [1] ") == "[1]", poster.unfence(" [1] "))

    findings, _ = poster.clean_findings([{"path": "a.py", "line": 1, "body": "x" * 5000}])
    expect("a long body is cut", len(findings[0]["body"]) == poster.MAX_COMMENT_BODY, len(findings[0]["body"]))

    inline, outside = poster.split_findings([finding(line=3), finding(line=9), finding(path="docs/usage.md")], allowed)
    expect("a finding on a line of the diff stays inline", inline == [finding(line=3)], inline)
    expect("a line outside the diff and another path move out", len(outside) == 2, outside)

    payload = poster.plan([finding(line=3), finding(line=40)], 2, FILES, "abc123")
    expect("the review names the commit and asks for comments", payload["commit_id"] == "abc123", payload)
    expect("the review is a comment review", payload["event"] == "COMMENT", payload["event"])
    expect("the review holds the inline finding", len(payload["comments"]) == 1, payload["comments"])
    expect(
        "the inline comment sits on the right of the line",
        payload["comments"][0]
        == {
            "path": "scripts/post_review_findings.py",
            "line": 3,
            "side": "RIGHT",
            "body": "**Major**: A problem.",
        },
        payload["comments"],
    )
    expect(
        "the body carries the finding that is not on the diff",
        payload["body"].startswith(poster.OUTSIDE_PREFIX)
        and "`scripts/post_review_findings.py:40` **Major**: A problem." in payload["body"]
        and "2 finding(s) without a path, a line and a body were skipped." in payload["body"],
        payload["body"],
    )

    many = [finding(line=3) for _ in range(poster.MAX_COMMENTS + 3)]
    payload = poster.plan(many, 0, FILES, "abc123")
    comments = payload["comments"]
    expect("the number of inline comments is capped", len(comments) == poster.MAX_COMMENTS, len(comments))
    bullets = payload["body"].count("\n- `")
    expect("the findings over the cap move into the body", bullets == 3, payload["body"])
    expect("the body starts with the finding that is not on a line", payload["body"].startswith(poster.OUTSIDE_PREFIX))

    payload = poster.plan([], 0, FILES, "abc123")
    expect("no finding makes no review", payload["comments"] == [] and payload["body"] == "", payload)

    verbose = [finding(line=40, body=name) for name in ["x" * 290 for _ in range(200)]]
    body = poster.review_body(verbose, 0)
    expect("the review body stays inside its cap", len(body) <= poster.MAX_REVIEW_BODY, len(body))
    expect("a finding that does not fit is counted", "more finding(s) were left out" in body, body[-200:])

    posted = []
    setattr(poster, "pull_request_files", lambda repo, number: FILES)
    setattr(poster, "post_review", lambda repo, number, payload: posted.append((repo, number, payload)))
    path = os.path.join(HERE, "post_review_findings.py")
    missing = poster.run(["post", path + ".missing", "--repo", "o/r"])
    expect("a missing findings file posts nothing", missing == 0, posted)
    expect("a missing findings file reaches no review", posted == [], posted)

    workdir = tempfile.mkdtemp(prefix="post-review-findings-")
    findings_path = os.path.join(workdir, "findings.json")
    try:
        with open(findings_path, "w", encoding="utf-8") as handle:
            json.dump([finding(line=3), finding(line=40)], handle)
        expect(
            "the run posts one review",
            poster.run(["post", findings_path, "--repo", "o/r", "--pull-request", "7", "--commit", "abc"]) == 0,
        )
        expect("the review goes to the pull request", [item[1] for item in posted] == ["7"], posted)
        expect("the review is a comment review", posted[0][2]["event"] == "COMMENT", posted[0][2])
        expect("the review has the one inline comment", len(posted[0][2]["comments"]) == 1, posted[0][2]["comments"])
        posted.clear()
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            code = poster.run(
                ["post", findings_path, "--repo", "o/r", "--pull-request", "7", "--commit", "abc", "--dry-run"]
            )
        expect("a dry run posts nothing", code == 0, printed.getvalue())
        printed_text = printed.getvalue()
        expect("a dry run prints the review it would post", '"event": "COMMENT"' in printed_text, printed_text)
        expect("a dry run reaches no review", posted == [], posted)
        with open(findings_path, "w", encoding="utf-8") as handle:
            handle.write("not json")
        expect("a file that is not JSON is not a failure", poster.main(["post", findings_path, "--repo", "o/r"]) == 0)
        with open(findings_path, "w", encoding="utf-8") as handle:
            handle.write('{"path": "a.py"}')
        expect(
            "an object instead of a list is not a failure", poster.main(["post", findings_path, "--repo", "o/r"]) == 0
        )
        with open(findings_path, "w", encoding="utf-8") as handle:
            handle.write("[]")
        expect("an empty list posts nothing", poster.run(["post", findings_path, "--repo", "o/r"]) == 0)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    options, dry_run = poster.parse_argv(["post", "a.json", "--pull-request", "7", "--commit", "abc"])
    expect(
        "the arguments are read",
        options == {"path": "a.json", "pull_request": "7", "commit": "abc", "repo": options["repo"]} and not dry_run,
        options,
    )
    try:
        poster.parse_argv(["post", "--unknown"])
        raise AssertionError("an unknown option passed")
    except poster.Unusable as error:
        expect("an unknown option is refused", "unknown option" in str(error), error)

    if FAILURES:
        print("post_review_findings self-test: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("post_review_findings self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
