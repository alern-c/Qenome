import json
import os
import subprocess
import sys

import stage_npm


def local_problem(ref, sha, version):
    if ref != "refs/heads/main":
        return "ref is " + (ref or "<missing>") + ", want refs/heads/main"
    if not sha:
        return "commit sha is missing"
    if stage_npm.SEMVER.match(version) is None or version == stage_npm.PLACEHOLDER_VERSION:
        return "version is not a release version"
    return None


def remote_problem(sha, version, tag_sha, release_tag):
    tag = "v" + version
    if tag_sha.lower() != sha.lower():
        return "tag " + tag + " points at " + (tag_sha or "<missing>") + ", not this commit"
    if release_tag != tag:
        return "GitHub release " + tag + " is missing"
    return None


def gh_api(path):
    done = subprocess.run(
        ["gh", "api", path],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip()
        raise ValueError(detail or "gh api failed for " + path)
    try:
        payload = json.loads(done.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("gh api returned invalid JSON for " + path) from error
    if not isinstance(payload, dict):
        raise ValueError("gh api returned a non-object for " + path)
    return payload


def main(argv):
    if len(argv) != 1:
        sys.stderr.write("usage: python3 scripts/require_npm_release.py\n")
        return 2
    root = stage_npm.repo_root()
    try:
        version = stage_npm.read_version(os.path.join(root, "build.zig.zon"))
    except ValueError as error:
        sys.stderr.write("require_npm_release: " + str(error) + "\n")
        return 1
    ref = os.environ.get("GITHUB_REF", "")
    sha = os.environ.get("GITHUB_SHA", "")
    found = local_problem(ref, sha, version)
    if found is not None:
        sys.stderr.write("require_npm_release: " + found + "\n")
        return 1
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if repo.count("/") != 1 or repo.startswith("/") or repo.endswith("/"):
        sys.stderr.write("require_npm_release: GITHUB_REPOSITORY is missing\n")
        return 1
    tag = "v" + version
    try:
        commit = gh_api("repos/" + repo + "/commits/" + tag)
        release = gh_api("repos/" + repo + "/releases/tags/" + tag)
    except ValueError as error:
        sys.stderr.write("require_npm_release: " + str(error) + "\n")
        return 1
    found = remote_problem(sha, version, str(commit.get("sha", "")), str(release.get("tag_name", "")))
    if found is not None:
        sys.stderr.write("require_npm_release: " + found + "\n")
        return 1
    print("require_npm_release: " + tag + " is " + sha, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
