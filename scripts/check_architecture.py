#!/usr/bin/env python3
"""Check the source boundaries of the CLI split (read-only).

The rules here are the machine-readable half of `docs/architecture.md`; that
document describes the same rules for people, including what this check cannot
see. The check never writes anything.

Every file it knows about is a file of the CLI split, and every `@import` in
them must be one of the forms below and point at an approved file:

  const name = @import("path");
  pub const name = @import("path");
  _ = @import("path");            # only as the test entry of src/cli.zig

Anything that contains the word `@import` but is not one of the forms below
is a failure, because the check cannot tell code from comments and strings
without a full Zig parser. That keeps the check from silently skipping a
variant such as `@import ("path")` or an `@import` whose argument starts on the
next line. A comment that mentions `@import` therefore fails the check on
purpose; keep such text out of the sources, or rewrite the check and its tests
together.

Exit codes: 0 clean, 1 at least one violation, 2 the arguments cannot be used.
Usage: python3 scripts/check_architecture.py [--root DIR]
"""

import os
import re
import sys

# The files of the CLI split. A missing file fails; a file under src/cli/ that
# is not in this list fails too.
APPROVED_FILES = [
    "src/cli.zig",
    "src/cli/args.zig",
    "src/cli/control.zig",
    "src/cli/comparison.zig",
    "src/cli/query.zig",
    "src/cli/workspace.zig",
    "src/cli/timing.zig",
    "src/cli/report.zig",
    "src/cli/tests.zig",
]

# The files that are part of a normal build. tests.zig is only reachable from
# src/cli.zig's test entry, so it is not a node of the production graph.
PRODUCTION_FILES = [path for path in APPROVED_FILES if path != "src/cli/tests.zig"]

# Project files each production file may import. `std` and `builtin` are
# allowed everywhere and are not listed.
PRODUCTION_IMPORTS = {
    "src/cli.zig": [
        "src/db.zig",
        "src/result.zig",
        "src/cli/args.zig",
        "src/cli/control.zig",
        "src/cli/comparison.zig",
        "src/cli/query.zig",
        "src/cli/workspace.zig",
        "src/cli/timing.zig",
        "src/cli/report.zig",
    ],
    "src/cli/args.zig": ["src/db.zig"],
    "src/cli/control.zig": [],
    "src/cli/comparison.zig": ["src/db.zig", "src/result.zig"],
    "src/cli/query.zig": [
        "src/db.zig",
        "src/sqlite.zig",
        "src/result.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
    ],
    "src/cli/workspace.zig": [
        "src/db.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/query.zig",
    ],
    "src/cli/timing.zig": [
        "src/db.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/query.zig",
    ],
    "src/cli/report.zig": [
        "src/result.zig",
        "src/cli/args.zig",
        "src/cli/comparison.zig",
        "src/cli/timing.zig",
    ],
}

# The one file that may import the test file. Its imports are the test table:
# the whole CLI and the layers the tests drive directly.
TEST_ENTRY_IMPORTER = "src/cli.zig"
TEST_ENTRY_TARGET = "src/cli/tests.zig"
TEST_ENTRY_PATH_TEXT = "cli/tests.zig"
TEST_IMPORTS = {
    "src/cli/tests.zig": [
        "src/cli.zig",
        "src/db.zig",
        "src/result.zig",
        "src/sqlite.zig",
        "src/cli/args.zig",
        "src/cli/control.zig",
        "src/cli/comparison.zig",
        "src/cli/query.zig",
        "src/cli/workspace.zig",
        "src/cli/timing.zig",
        "src/cli/report.zig",
    ],
}

BUILTIN_IMPORTS = ["std", "builtin"]

IMPORT_CANDIDATE = re.compile(r"@import\b")
DECL_IMPORT = re.compile(r'^(?:pub )?const [A-Za-z_][A-Za-z0-9_]* = @import\("([^"\\]*)"\);\s*$')
ENTRY_IMPORT = re.compile(r'^\s*_ = @import\("([^"\\]*)"\);\s*$')
TEST_BLOCK_START = re.compile(r"^test \{\s*$")
COMMENT_OR_BLANK = re.compile(r"^\s*(//.*)?$")


class Source:
    """One checked file: its lines, its imports, and its test blocks."""

    def __init__(self, path, lines):
        self.path = path
        self.lines = lines
        self.imports = []  # (line number, path text, form)
        self.test_blocks = []  # (first line number, last line number)


def read_source(root, rel_path):
    """Read one file; returns (Source, None), or (None, error text) when it
    cannot be read."""
    try:
        with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
            return Source(rel_path, handle.read().split("\n")), None
    except (OSError, UnicodeDecodeError) as error:
        return None, str(error)


def parse(source, violations):
    """Find the supported imports and the test blocks, and flag anything else
    that looks like an import."""
    for index, line in enumerate(source.lines):
        number = index + 1
        if not IMPORT_CANDIDATE.search(line):
            continue
        decl = DECL_IMPORT.match(line)
        if decl:
            source.imports.append((number, decl.group(1), "decl"))
            continue
        entry = ENTRY_IMPORT.match(line)
        if entry:
            source.imports.append((number, entry.group(1), "entry"))
            continue
        violations.append(
            (source.path, number, "import-form", "unsupported @import form: " + line.strip()[:72])
        )
    depth = 0
    start = None
    for index, line in enumerate(source.lines):
        if start is None:
            if TEST_BLOCK_START.match(line):
                start = index
                depth = 1
            continue
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            source.test_blocks.append((start + 1, index + 1))
            start = None


def resolve(importer, path_text):
    """The project path an import points at, or None when it leaves the
    repository root. A path without a leading dot is relative to the importing
    file's directory, as Zig resolves it."""
    resolved = os.path.normpath(
        os.path.join(os.path.dirname(importer), path_text.replace("/", os.sep))
    )
    if resolved.startswith("..") or os.path.isabs(resolved):
        return None
    return resolved.replace(os.sep, "/")


def check_files(root, sources, violations):
    """Missing approved files, and unknown files under src/cli/."""
    for rel_path in APPROVED_FILES:
        if rel_path not in sources:
            violations.append((rel_path, 0, "missing-file", "the approved file is missing"))
    cli_dir = os.path.join(root, "src", "cli")
    try:
        names = sorted(os.listdir(cli_dir))
    except OSError as error:
        if os.path.exists(cli_dir):
            violations.append(
                ("src/cli", 0, "unreadable-directory", f"could not list src/cli: {error}")
            )
        return
    for name in names:
        if not name.endswith(".zig"):
            continue
        rel_path = "src/cli/" + name
        if rel_path not in APPROVED_FILES:
            violations.append(
                (rel_path, 0, "unknown-file", "a file under src/cli/ that the rules do not know")
            )


def check_imports(sources, violations):
    for rel_path, source in sorted(sources.items()):
        table = PRODUCTION_IMPORTS.get(rel_path)
        if table is None:
            table = TEST_IMPORTS.get(rel_path)
        if table is None:
            continue
        for number, path_text, _form in source.imports:
            if path_text in BUILTIN_IMPORTS:
                continue
            resolved = resolve(rel_path, path_text)
            if resolved is None:
                violations.append(
                    (
                        rel_path,
                        number,
                        "outside-root",
                        f'@import("{path_text}") leaves the repository',
                    )
                )
                continue
            if resolved == TEST_ENTRY_TARGET:
                continue  # checked by check_test_entry
            if resolved not in table:
                violations.append(
                    (
                        rel_path,
                        number,
                        "unapproved-import",
                        f"{rel_path} may not import {resolved}",
                    )
                )


def check_test_entry(sources, violations):
    """The test file is imported exactly once, from the test entry of
    src/cli.zig, and that entry holds nothing else."""
    importers = []
    for rel_path, source in sorted(sources.items()):
        for number, path_text, form in source.imports:
            if resolve(rel_path, path_text) == TEST_ENTRY_TARGET:
                importers.append((rel_path, number, path_text, form))
    if len(importers) != 1:
        violations.append(
            (
                TEST_ENTRY_IMPORTER,
                0,
                "test-entry",
                f"expected exactly one import of {TEST_ENTRY_TARGET}, found {len(importers)}",
            )
        )
        return
    rel_path, number, path_text, form = importers[0]
    if rel_path != TEST_ENTRY_IMPORTER or form != "entry" or path_text != TEST_ENTRY_PATH_TEXT:
        violations.append(
            (
                rel_path,
                number,
                "test-entry",
                f'only {TEST_ENTRY_IMPORTER}\'s test block may import {TEST_ENTRY_TARGET} '
                f'as _ = @import("{TEST_ENTRY_PATH_TEXT}");',
            )
        )
        return
    source = sources[rel_path]
    block = None
    for first, last in source.test_blocks:
        if first <= number <= last:
            block = (first, last)
            break
    if block is None:
        violations.append((rel_path, number, "test-entry", "the test entry is outside a test block"))
        return
    for line_number in range(block[0] + 1, block[1]):
        line = source.lines[line_number - 1]
        if COMMENT_OR_BLANK.match(line):
            continue
        if line_number == number:
            continue
        violations.append(
            (
                rel_path,
                line_number,
                "test-entry",
                "the test entry block holds more than the one import: " + line.strip()[:72],
            )
        )


def check_cycles(sources, violations):
    """Cycles among the production files. The edge to the test file is not part
    of the graph (the test file is not a production file)."""
    graph = {}
    for rel_path in PRODUCTION_FILES:
        edges = []
        source = sources.get(rel_path)
        if source is None:
            continue
        for _number, path_text, _form in source.imports:
            if path_text in BUILTIN_IMPORTS:
                continue
            resolved = resolve(rel_path, path_text)
            if resolved in PRODUCTION_FILES:
                edges.append(resolved)
        graph[rel_path] = edges

    state = {}  # 0 unseen, 1 on the stack, 2 done
    stack = []

    def walk(node):
        state[node] = 1
        stack.append(node)
        for neighbour in graph.get(node, []):
            if state.get(neighbour, 0) == 1:
                cycle = stack[stack.index(neighbour):] + [neighbour]
                violations.append(
                    (neighbour, 0, "cycle", "the production dependency cycle: " + " -> ".join(cycle))
                )
                return True
            if state.get(neighbour, 0) == 0 and walk(neighbour):
                return True
        stack.pop()
        state[node] = 2
        return False

    for node in PRODUCTION_FILES:
        if state.get(node, 0) == 0 and walk(node):
            return


def run(root):
    violations = []
    sources = {}
    for rel_path in APPROVED_FILES:
        if not os.path.isfile(os.path.join(root, rel_path)):
            continue  # reported as missing-file
        source, error = read_source(root, rel_path)
        if error is not None:
            violations.append(
                (rel_path, 0, "unreadable-file", f"could not read the file: {error}")
            )
            continue
        sources[rel_path] = source
    check_files(root, sources, violations)
    for source in sources.values():
        parse(source, violations)
    check_imports(sources, violations)
    check_test_entry(sources, violations)
    check_cycles(sources, violations)
    return violations


def main(argv):
    root = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write("usage: python3 scripts/check_architecture.py [--root DIR]\n")
            return 2
    if root is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write(f"architecture: not a directory: {root}\n")
        return 2
    violations = run(root)
    for rel_path, number, rule, reason in violations:
        print(f"{rel_path}:{number}: {rule}: {reason}")
    if violations:
        print(f"architecture: {len(violations)} violation(s), root={root}")
        return 1
    print(f"architecture: ok ({len(APPROVED_FILES)} files checked, root={root})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
