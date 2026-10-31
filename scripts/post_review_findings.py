import json
import os
import re
import subprocess
import sys
import tempfile

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
SEVERITY = re.compile(r"^[A-Za-z][A-Za-z0-9 -]{0,19}$")
MAX_COMMENTS = 20
MAX_COMMENT_BODY = 2000
MAX_REVIEW_BODY = 6000
MAX_FINDINGS_BYTES = 256 * 1024
BULLET_BODY = 300
PAGE_SIZE = 100
MAX_PAGES = 30
OUTSIDE_PREFIX = "Findings that are not on a line of this pull request's diff:"


class Unusable(Exception):
    pass


def one_line(text, limit=300):
    return " ".join(str(text).split())[:limit]


def warn(message):
    sys.stderr.write("::warning::" + one_line(message) + "\n")


def load_findings(path):
    if not path or not os.path.isfile(path):
        return [], 0
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAX_FINDINGS_BYTES + 1)
    except OSError as error:
        raise Unusable("cannot read the findings file: " + str(error)) from None
    if len(raw) > MAX_FINDINGS_BYTES:
        raise Unusable("the findings file is larger than " + str(MAX_FINDINGS_BYTES) + " bytes")
    try:
        data = json.loads(unfence(raw.decode("utf-8", "replace")))
    except ValueError:
        raise Unusable("the findings file is not valid JSON") from None
    return clean_findings(data)


def unfence(text):
    text = text.strip()
    if not text.startswith("```"):
        return text
    lines = text.split("\n")
    lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    return "\n".join(lines).strip()


def clean_findings(data):
    if not isinstance(data, list):
        raise Unusable("the findings file does not hold a JSON array")
    findings = []
    skipped = 0
    for item in data:
        finding = clean_finding(item)
        if finding is None:
            skipped += 1
            continue
        findings.append(finding)
    return findings, skipped


def clean_finding(item):
    if not isinstance(item, dict):
        return None
    path = item.get("path")
    line = item.get("line")
    body = item.get("body")
    severity = item.get("severity")
    if not isinstance(path, str) or not isinstance(body, str):
        return None
    if isinstance(line, str) and line.strip().isdigit():
        line = int(line.strip())
    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        return None
    path = clean_path(path)
    body = body.strip()
    if not path or not body:
        return None
    if not isinstance(severity, str) or SEVERITY.match(severity.strip()) is None:
        severity = ""
    return {"path": path, "line": line, "severity": severity.strip(), "body": body[:MAX_COMMENT_BODY]}


def clean_path(path):
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    if not path or path.startswith("/") or "\\" in path or ":" in path:
        return None
    for part in path.split("/"):
        if part in ("", ".", ".."):
            return None
    return path


def hunk_lines(patch):
    covered = set()
    number = None
    for raw in patch.split("\n"):
        header = HUNK.match(raw)
        if header is not None:
            number = int(header.group(1))
            continue
        if number is None:
            continue
        if raw.startswith("+") or raw.startswith(" "):
            covered.add(number)
            number += 1
        elif raw.startswith("-"):
            continue
        elif raw.startswith("\\"):
            continue
        else:
            number = None
    return covered


def diff_lines(files):
    allowed = {}
    for entry in files:
        if not isinstance(entry, dict):
            continue
        path = entry.get("filename")
        patch = entry.get("patch")
        if not isinstance(path, str) or not isinstance(patch, str):
            continue
        if entry.get("status") == "removed":
            continue
        allowed[path] = hunk_lines(patch)
    return allowed


def split_findings(findings, allowed):
    inline = []
    outside = []
    for finding in findings:
        lines = allowed.get(finding["path"])
        if lines is not None and finding["line"] in lines:
            inline.append(finding)
        else:
            outside.append(finding)
    return inline, outside


def severity_prefix(finding):
    if not finding["severity"]:
        return ""
    return "**" + finding["severity"][:1].upper() + finding["severity"][1:] + "**: "


def inline_comment(finding):
    return {
        "path": finding["path"],
        "line": finding["line"],
        "side": "RIGHT",
        "body": severity_prefix(finding) + finding["body"],
    }


def review_body(findings, skipped):
    bullets = []
    used = len(OUTSIDE_PREFIX)
    left_out = 0
    for finding in findings:
        bullet = "- `" + finding["path"] + ":" + str(finding["line"]) + "` "
        bullet += severity_prefix(finding) + one_line(finding["body"], BULLET_BODY)
        if used + len(bullet) > MAX_REVIEW_BODY - 300:
            left_out += 1
            continue
        bullets.append(bullet)
        used += len(bullet) + 1
    parts = []
    if bullets:
        parts.append(OUTSIDE_PREFIX)
        parts.extend(bullets)
    notes = []
    if left_out:
        notes.append("(" + str(left_out) + " more finding(s) were left out of this review.)")
    if skipped:
        notes.append("(" + str(skipped) + " finding(s) without a path, a line and a body were skipped.)")
    if notes:
        if parts:
            parts.append("")
        parts.extend(notes)
    return "\n".join(parts)


def review_payload(commit, comments, body):
    return {
        "commit_id": commit,
        "event": "COMMENT",
        "body": body,
        "comments": comments,
    }


def plan(findings, skipped, files, commit):
    inline, outside = split_findings(findings, diff_lines(files))
    kept = inline[:MAX_COMMENTS]
    comments = [inline_comment(finding) for finding in kept]
    body = review_body(outside + inline[MAX_COMMENTS:], skipped)
    return review_payload(commit, comments, body)


def gh_api(endpoint, payload=None):
    argv = ["gh", "api"]
    handle = None
    try:
        if payload is not None:
            handle = tempfile.NamedTemporaryFile(
                "w", suffix=".json", delete=False, encoding="utf-8", dir=os.environ.get("RUNNER_TEMP") or None
            )
            json.dump(payload, handle)
            handle.close()
            argv.extend(["--method", "POST", "--input", handle.name])
        argv.append(endpoint)
        done = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    finally:
        if handle is not None:
            try:
                os.unlink(handle.name)
            except OSError as error:
                sys.stderr.write("post_review_findings: cannot remove " + handle.name + ": " + str(error) + "\n")
    if done.returncode != 0:
        raise Unusable("gh api " + endpoint + " failed: " + (done.stderr or done.stdout))
    return done.stdout


def pull_request_files(repo, number):
    files = []
    page = 1
    while page <= MAX_PAGES:
        endpoint = "repos/" + repo + "/pulls/" + str(number) + "/files?per_page=" + str(PAGE_SIZE)
        endpoint += "&page=" + str(page)
        try:
            data = json.loads(gh_api(endpoint))
        except ValueError:
            raise Unusable("gh api " + endpoint + " did not return JSON") from None
        if not isinstance(data, list):
            raise Unusable("gh api " + endpoint + " did not return a list")
        files.extend(data)
        if len(data) < PAGE_SIZE:
            break
        page += 1
    return files


def post_review(repo, number, payload):
    endpoint = "repos/" + repo + "/pulls/" + str(number) + "/reviews"
    gh_api(endpoint, payload)
    print("post_review_findings: posted " + str(len(payload["comments"])) + " inline comment(s) on PR " + str(number))


def parse_argv(argv):
    options = {"path": None, "pull_request": None, "commit": None, "repo": os.environ.get("GITHUB_REPOSITORY", "")}
    dry_run = False
    rest = list(argv[1:])
    while rest:
        item = rest.pop(0)
        if item == "--pull-request" and rest:
            options["pull_request"] = rest.pop(0)
        elif item == "--commit" and rest:
            options["commit"] = rest.pop(0)
        elif item == "--repo" and rest:
            options["repo"] = rest.pop(0)
        elif item == "--dry-run":
            dry_run = True
        elif item.startswith("--"):
            raise Unusable("unknown option " + item)
        elif options["path"] is None:
            options["path"] = item
        else:
            raise Unusable("unexpected argument " + item)
    return options, dry_run


def run(argv):
    options, dry_run = parse_argv(argv)
    path = options["path"]
    findings, skipped = load_findings(path)
    if not findings and not skipped:
        print("post_review_findings: no findings at " + str(path) + "; nothing to post")
        return 0
    if not options["pull_request"] or not options["commit"]:
        raise Unusable("--pull-request and --commit are required")
    if not options["repo"]:
        raise Unusable("GITHUB_REPOSITORY is not set and --repo is missing")
    payload = plan(findings, skipped, pull_request_files(options["repo"], options["pull_request"]), options["commit"])
    if dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0
    if not payload["comments"] and not payload["body"]:
        print("post_review_findings: no finding is on a line of the diff; nothing to post")
        return 0
    post_review(options["repo"], options["pull_request"], payload)
    return 0


def main(argv):
    try:
        return run(argv)
    except Unusable as error:
        warn("post_review_findings: " + str(error))
        return 0
    except Exception as error:
        warn("post_review_findings: " + type(error).__name__ + ": " + str(error))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
