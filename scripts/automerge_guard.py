import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse

MARKER = "<!-- qenome-automerge-guard -->"
PAGE_SIZE = 100
MAX_PAGES = 30
SHA = re.compile(r"^[0-9a-f]{40}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ZIG_VERSION = re.compile(r'(?m)^[ \t]*\.version[ \t]*=[ \t]*"([0-9A-Za-z.+-]{1,40})"[ \t]*,[ \t]*$')
SAFE_VERSION = re.compile(r"^[0-9A-Za-z.+-]{1,40}$")
WORKFLOW_PREFIX = ".github/workflows/"
NPM_PREFIX = "npm/"
PACKAGING_FILES = (
    "scripts/changelog-section.sh",
    "scripts/publish_npm.py",
    "scripts/require_npm_release.py",
    "scripts/smoke_npm.py",
    "scripts/stage_npm.py",
    "scripts/verify_published_npm.py",
)
GATE_FILES = (
    "scripts/automerge_guard.py",
    "scripts/review_gate.py",
)
VERDICT_FILES = ("src/cli/comparison.zig",)
CONTENT_NAMES = ("build.zig.zon", "CHANGELOG.md")


class Unusable(Exception):
    pass


def reject_duplicates(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate key")
        obj[key] = value
    return obj


def clean_path(path):
    if not isinstance(path, str) or not path or len(path) > 500:
        return None
    if path.startswith("/") or path.startswith("\\") or "\\" in path or "\n" in path or "\r" in path or "`" in path:
        return None
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None
    return path


def paths_of(entry):
    found = []
    for key in ("filename", "previous_filename"):
        if key not in entry or entry[key] is None:
            continue
        path = clean_path(entry[key])
        if path is None:
            return None
        if path not in found:
            found.append(path)
    if not found:
        return None
    return found


def is_expected_answer(path):
    parts = path.split("/")
    return len(parts) >= 3 and parts[0] == "testdata" and parts[1] == "accuracy" and parts[-1] == "case.json"


def is_package_json(path):
    return path == "package.json" or path.endswith("/package.json")


def path_reason(path):
    if path.startswith(WORKFLOW_PREFIX):
        return "`" + path + "` changes a workflow, so the pull request is excluded"
    if path == "npm" or path.startswith(NPM_PREFIX):
        return "`" + path + "` changes npm packaging, so the pull request is excluded"
    if path in PACKAGING_FILES:
        return "`" + path + "` changes release or npm packaging, so the pull request is excluded"
    if path in GATE_FILES:
        return "`" + path + "` changes the auto-merge gate, so the pull request is excluded"
    if path in VERDICT_FILES:
        return "`" + path + "` changes the verdict decision, so the pull request is excluded"
    if is_expected_answer(path):
        return "`" + path + "` changes an accuracy expected answer, so the pull request is excluded"
    return None


def zig_version(text):
    if text is None:
        return None
    found = ZIG_VERSION.findall(text)
    if len(found) != 1:
        return None
    return found[0]


def released_part(text):
    if text is None:
        return None
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line == "## [Unreleased]":
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## ["):
            end = index
            break
    return "\n".join(lines[:start] + lines[end:])


def version_headings(text):
    if text is None:
        return None
    found = []
    for line in text.splitlines():
        if line.startswith("## [") and line != "## [Unreleased]":
            found.append(line)
    return found


def package_version(text):
    if text is None:
        return None
    try:
        data = json.loads(text, object_pairs_hook=reject_duplicates)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    version = data.get("version")
    if not isinstance(version, str) or SAFE_VERSION.fullmatch(version) is None:
        return None
    return version


def needs_text(path):
    return path in CONTENT_NAMES or is_package_json(path)


def content_reason(path, texts):
    pair = texts.get(path)
    if not isinstance(pair, dict):
        return "`" + path + "` changed but its text could not be read, so the pull request is excluded"
    base = pair.get("base")
    head = pair.get("head")
    if path == "build.zig.zon":
        return zon_reason(base, head)
    if path == "CHANGELOG.md":
        return changelog_reason(base, head)
    if is_package_json(path):
        return package_reason(path, base, head)
    return None


def zon_reason(base, head):
    if base is None or head is None:
        return "`build.zig.zon` was added or removed, so the pull request is excluded"
    before = zig_version(base)
    after = zig_version(head)
    if before is None or after is None:
        return "`build.zig.zon` `.version` could not be read, so the pull request is excluded"
    if before != after:
        return (
            "`build.zig.zon` `.version` changed from `"
            + before
            + "` to `"
            + after
            + "`, so the pull request is excluded"
        )
    return None


def changelog_reason(base, head):
    if base is None or head is None:
        return "`CHANGELOG.md` was added or removed, so the pull request is excluded"
    before = released_part(base)
    after = released_part(head)
    if before is None or after is None:
        return "`CHANGELOG.md` has no `## [Unreleased]` section, so the pull request is excluded"
    if before == after:
        return None
    before_headings = version_headings(base)
    after_headings = version_headings(head)
    if before_headings != after_headings:
        return "`CHANGELOG.md` changes a version heading, so the pull request is excluded"
    return "`CHANGELOG.md` changes text outside `## [Unreleased]`, so the pull request is excluded"


def package_reason(path, base, head):
    if base is None or head is None:
        return "`" + path + "` was added or removed, so the pull request is excluded"
    before = package_version(base)
    after = package_version(head)
    if before is None or after is None:
        return "`" + path + "` version field could not be read, so the pull request is excluded"
    if before != after:
        return "`" + path + "` `version` changed, so the pull request is excluded"
    return None


def reasons_for(files, texts, capped):
    reasons = []
    if capped:
        reasons.append("the changed-file list did not end within 3000 files, so the pull request is excluded")
    if not isinstance(files, list):
        reasons.append("the changed-file list was not a list, so the pull request is excluded")
        return reasons
    seen = set()
    for entry in files:
        if not isinstance(entry, dict):
            reasons.append("a changed-file entry was not an object, so the pull request is excluded")
            continue
        paths = paths_of(entry)
        if paths is None:
            reasons.append("a changed path is not a normal relative path, so the pull request is excluded")
            continue
        for path in paths:
            if path in seen:
                continue
            seen.add(path)
            reason = path_reason(path)
            if reason is None and needs_text(path):
                reason = content_reason(path, texts)
            if reason:
                reasons.append(reason)
    return reasons


def content_paths(files):
    wanted = []
    if not isinstance(files, list):
        return wanted
    for entry in files:
        if not isinstance(entry, dict):
            continue
        paths = paths_of(entry)
        if paths is None:
            continue
        for path in paths:
            if path_reason(path) or not needs_text(path) or path in wanted:
                continue
            wanted.append(path)
    return wanted


def exclusion_body(reasons):
    lines = [MARKER, "This pull request is excluded from auto-merge.", ""]
    for reason in reasons:
        lines.append("- " + reason)
    lines.extend(
        [
            "",
            "`automerge-guard` fails on purpose. The `automerge` label cannot merge this pull request.",
            "A maintainer who intends to merge it has to bypass this required check.",
            "Removing the label does not make the check pass.",
        ]
    )
    return "\n".join(lines) + "\n"


def fail(message):
    sys.stderr.write("::error::" + message + "\n")


def gh_api(method, endpoint, payload=None):
    argv = ["gh", "api"]
    handle = None
    try:
        if method:
            argv.extend(["--method", method])
        if payload is not None:
            handle = tempfile.NamedTemporaryFile(
                "w", suffix=".json", delete=False, encoding="utf-8", dir=os.environ.get("RUNNER_TEMP") or None
            )
            json.dump(payload, handle)
            handle.close()
            argv.extend(["--input", handle.name])
        argv.append(endpoint)
        done = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as error:
        raise Unusable("cannot run gh: " + error.__class__.__name__) from None
    finally:
        if handle is not None:
            try:
                os.unlink(handle.name)
            except OSError:
                pass
    if done.returncode != 0:
        raise Unusable("gh api failed for " + endpoint.split("?", 1)[0])
    return done.stdout


def gh_json(endpoint):
    text = gh_api("", endpoint, None)
    if text is None:
        raise Unusable("gh api returned nothing for " + endpoint.split("?", 1)[0])
    try:
        return json.loads(text)
    except ValueError:
        raise Unusable("gh api returned invalid JSON for " + endpoint.split("?", 1)[0]) from None


def pull_files(repo, number):
    files = []
    page = 1
    while page <= MAX_PAGES:
        endpoint = "repos/" + repo + "/pulls/" + number + "/files?per_page=" + str(PAGE_SIZE) + "&page=" + str(page)
        data = gh_json(endpoint)
        if not isinstance(data, list):
            raise Unusable("the changed-file list was not a JSON array")
        files.extend(data)
        if len(data) < PAGE_SIZE:
            return files, False
        page += 1
    return files, True


def fetch_text(repo, ref, path):
    quoted = urllib.parse.quote(path)
    endpoint = "repos/" + repo + "/contents/" + quoted + "?ref=" + urllib.parse.quote(ref, safe="")
    argv = ["gh", "api", "-H", "Accept: application/vnd.github.raw", endpoint]
    try:
        done = subprocess.run(argv, capture_output=True, stdin=subprocess.DEVNULL)
    except OSError as error:
        raise Unusable("cannot run gh: " + error.__class__.__name__) from None
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace")
        if "404" in detail or "Not Found" in detail:
            return None
        raise Unusable("cannot read " + path)
    try:
        return done.stdout.decode("utf-8")
    except UnicodeDecodeError:
        raise Unusable("cannot read " + path + " as UTF-8") from None


def load_texts(repo, base, head_ref, paths):
    texts = {}
    for path in paths:
        texts[path] = {"base": fetch_text(repo, base, path), "head": fetch_text(repo, head_ref, path)}
    return texts


def comment_page(repo, number, page):
    endpoint = "repos/" + repo + "/issues/" + number + "/comments?per_page=100&page=" + str(page)
    data = gh_json(endpoint)
    if not isinstance(data, list):
        raise Unusable("the comment list was not a JSON array")
    return data


def marker_comments(repo, number):
    found = []
    page = 1
    while page <= MAX_PAGES:
        data = comment_page(repo, number, page)
        for item in data:
            if not isinstance(item, dict):
                continue
            body = item.get("body")
            comment_id = item.get("id")
            if isinstance(body, str) and MARKER in body and isinstance(comment_id, int):
                found.append({"id": comment_id, "body": body})
        if len(data) < 100:
            return found
        page += 1
    raise Unusable("the comment list did not end")


def sync_comment(repo, number, body):
    existing = marker_comments(repo, number)
    if body is None:
        for comment in existing:
            gh_api("DELETE", "repos/" + repo + "/issues/comments/" + str(comment["id"]))
        return
    if len(existing) == 1 and existing[0]["body"].strip() == body.strip():
        return
    for comment in existing:
        gh_api("DELETE", "repos/" + repo + "/issues/comments/" + str(comment["id"]))
    gh_api("POST", "repos/" + repo + "/issues/" + number + "/comments", {"body": body})


def parse_argv(argv):
    options = {}
    flags = {"--pull-request": "number", "--base": "base"}
    rest = list(argv[1:])
    while rest:
        item = rest.pop(0)
        key = flags.get(item)
        if key is None or not rest:
            raise Unusable("usage: python3 scripts/automerge_guard.py --pull-request N --base SHA")
        options[key] = rest.pop(0)
    if "number" not in options or "base" not in options:
        raise Unusable("usage: python3 scripts/automerge_guard.py --pull-request N --base SHA")
    if not options["number"].isdigit() or options["number"].startswith("0"):
        raise Unusable("the pull request number is not usable")
    if SHA.fullmatch(options["base"]) is None:
        raise Unusable("the base SHA is not a 40-character hex string")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if REPO.fullmatch(repo) is None:
        raise Unusable("GITHUB_REPOSITORY is not owner/name")
    options["repo"] = repo
    return options


def run(argv):
    options = parse_argv(argv)
    files, capped = pull_files(options["repo"], options["number"])
    texts = load_texts(
        options["repo"],
        options["base"],
        "refs/pull/" + options["number"] + "/head",
        content_paths(files),
    )
    reasons = reasons_for(files, texts, capped)
    for reason in reasons:
        fail(reason)
    sync_comment(options["repo"], options["number"], exclusion_body(reasons) if reasons else None)
    if reasons:
        print("automerge-guard: excluded (" + str(len(reasons)) + ")")
        return 1
    print("automerge-guard: not excluded")
    return 0


def main(argv):
    try:
        return run(argv)
    except Unusable as error:
        fail(str(error))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
