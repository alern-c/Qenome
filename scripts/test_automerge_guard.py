import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "automerge_guard.py")
ROOT = os.path.dirname(HERE)
FAILURES: list[str] = []

ZON = """\
.{
    .name = .Qenome,
    .version = "0.3.9",
    .fingerprint = 0x523b0edc3a69374a,
    .minimum_zig_version = "0.17.0",
}
"""

ZON_BUMPED = ZON.replace('"0.3.9"', '"0.4.0"', 1)
ZON_TOOLCHAIN = ZON.replace('"0.17.0"', '"0.18.0"', 1)

CHANGELOG = """\
# Changelog

## [Unreleased]

- A note.

## [0.3.9] - 2026-10-31

- Released.
"""

CHANGELOG_NOTE = CHANGELOG.replace("- A note.", "- A note.\n- Another note.", 1)
CHANGELOG_HEADING = CHANGELOG.replace("## [0.3.9] - 2026-10-31", "## [0.4.0] - 2026-11-01", 1)
CHANGELOG_OLD = CHANGELOG.replace("- Released.", "- Released.\n- Rewritten.", 1)

PACKAGE = '{"name":"example","version":"0.0.0","private":true}\n'
PACKAGE_BUMPED = PACKAGE.replace('"0.0.0"', '"1.2.3"', 1)
PACKAGE_PRIVATE = PACKAGE.replace('"private":true', '"private":false', 1)


def load_guard():
    spec = importlib.util.spec_from_file_location("automerge_guard", GUARD)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + GUARD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(name, condition, detail=None):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def changed(path, previous=None):
    entry = {"filename": path, "status": "modified"}
    if previous is not None:
        entry["previous_filename"] = previous
        entry["status"] = "renamed"
    return entry


def texts_for(**pairs):
    stored = {}
    for path, pair in pairs.items():
        stored[path] = {"base": pair[0], "head": pair[1]}
    return stored


def reasons(guard, files, texts=None, capped=False):
    return guard.reasons_for(files, texts or {}, capped)


def has(reasons, needle):
    return any(needle in reason for reason in reasons)


def main():
    guard = load_guard()
    with open(os.path.join(ROOT, "build.zig.zon"), encoding="utf-8") as handle:
        real_zon = handle.read()
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as handle:
        real_changelog = handle.read()
    expect("the repository version field parses", guard.zig_version(real_zon) is not None, real_zon)
    expect(
        "the changelog has an Unreleased section",
        guard.released_part(real_changelog) is not None,
        "missing",
    )

    expect("a docs change is allowed", reasons(guard, [changed("docs/automerge.md")]) == [], None)
    expect(
        "a workflow change is excluded",
        has(reasons(guard, [changed(".github/workflows/automerge.yml")]), "workflow"),
        None,
    )
    expect(
        "removing a workflow is excluded",
        has(reasons(guard, [{"filename": ".github/workflows/release.yml", "status": "removed"}]), "workflow"),
        None,
    )
    expect("an npm path is excluded", has(reasons(guard, [changed("npm/qenome/package.json")]), "npm packaging"), None)
    expect(
        "a publish script is excluded",
        has(reasons(guard, [changed("scripts/publish_npm.py")]), "release or npm packaging"),
        None,
    )
    expect(
        "the release notes script is excluded",
        has(reasons(guard, [changed("scripts/changelog-section.sh")]), "release or npm packaging"),
        None,
    )
    expect(
        "the guard script is excluded",
        has(reasons(guard, [changed("scripts/automerge_guard.py")]), "auto-merge gate"),
        None,
    )
    expect(
        "the review gate script is excluded",
        has(reasons(guard, [changed("scripts/review_gate.py")]), "auto-merge gate"),
        None,
    )
    expect(
        "a guard test is allowed",
        reasons(guard, [changed("scripts/test_automerge_guard.py")]) == [],
        None,
    )
    expect(
        "the verdict file is excluded",
        has(reasons(guard, [changed("src/cli/comparison.zig")]), "verdict decision"),
        None,
    )
    expect(
        "renaming the verdict file is excluded",
        has(
            reasons(guard, [changed("src/cli/comparison_next.zig", previous="src/cli/comparison.zig")]),
            "verdict decision",
        ),
        None,
    )
    expect(
        "an accuracy answer is excluded",
        has(reasons(guard, [changed("testdata/accuracy/equality-improved/case.json")]), "expected answer"),
        None,
    )
    expect(
        "an accuracy fixture that is not an answer is allowed",
        reasons(guard, [changed("testdata/accuracy/equality-improved/select.sql")]) == [],
        None,
    )
    same_zon = texts_for(**{"build.zig.zon": (ZON, ZON_TOOLCHAIN)})
    expect(
        "a toolchain-only zon edit is allowed",
        reasons(guard, [changed("build.zig.zon")], same_zon) == [],
        reasons(guard, [changed("build.zig.zon")], same_zon),
    )
    bumped_zon = texts_for(**{"build.zig.zon": (ZON, ZON_BUMPED)})
    expect(
        "a zon version bump is excluded",
        has(reasons(guard, [changed("build.zig.zon")], bumped_zon), ".version"),
        None,
    )
    expect(
        "a zon change without text is excluded",
        has(reasons(guard, [changed("build.zig.zon")]), "could not be read"),
        None,
    )
    note = texts_for(**{"CHANGELOG.md": (CHANGELOG, CHANGELOG_NOTE)})
    expect(
        "an Unreleased note is allowed",
        reasons(guard, [changed("CHANGELOG.md")], note) == [],
        reasons(guard, [changed("CHANGELOG.md")], note),
    )
    heading = texts_for(**{"CHANGELOG.md": (CHANGELOG, CHANGELOG_HEADING)})
    expect(
        "a version heading is excluded",
        has(reasons(guard, [changed("CHANGELOG.md")], heading), "version heading"),
        None,
    )
    old = texts_for(**{"CHANGELOG.md": (CHANGELOG, CHANGELOG_OLD)})
    expect(
        "an edit under a released heading is excluded",
        has(reasons(guard, [changed("CHANGELOG.md")], old), "outside"),
        None,
    )
    package = texts_for(**{"tools/package.json": (PACKAGE, PACKAGE_PRIVATE)})
    expect(
        "a package.json edit that keeps the version is allowed",
        reasons(guard, [changed("tools/package.json")], package) == [],
        reasons(guard, [changed("tools/package.json")], package),
    )
    bumped_package = texts_for(**{"tools/package.json": (PACKAGE, PACKAGE_BUMPED)})
    expect(
        "a package.json version bump is excluded",
        has(reasons(guard, [changed("tools/package.json")], bumped_package), "version"),
        None,
    )
    expect(
        "a capped file list is excluded",
        has(reasons(guard, [], capped=True), "3000"),
        None,
    )
    expect(
        "a path that escapes the repository is excluded",
        has(reasons(guard, [changed("../secrets.env")]), "not a normal relative path"),
        None,
    )
    body = guard.exclusion_body(
        ["`src/cli/comparison.zig` changes the verdict decision, so the pull request is excluded"]
    )
    expect("the comment names the exclusion", "verdict decision" in body, body)
    expect("the comment carries the marker", body.startswith(guard.MARKER), body)
    expect("the comment says the label does not clear the check", "Removing the label" in body, body)

    if FAILURES:
        print("automerge_guard self-test: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("automerge_guard self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
