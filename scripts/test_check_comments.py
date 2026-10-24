import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_comments.py")

FAILURES = []

CANONICAL_FILES = {
    ".gitattributes": "*.c linguist-vendored\n",
    ".gitignore": "\\#escaped\n.zig-cache/\npath#name\n",
    ".github/workflows/quality.yml": (
        "name: sample\n"
        'description: "a quoted value"\n'
        "literal: 'another value'\n"
        "script: |\n"
        '  echo "inside"\n'
        "  echo 'multi\n"
        "  still inside the string\n"
        "  done'\n"
    ),
    "build.zig": (
        'const std = @import("std");\n'
        'const url = "https://example.com//path";\n'
        "const text =\n"
        "    \\\\SELECT 1 -- not a comment\n"
        "    \\\\-- still text // not a comment\n"
        ";\n"
    ),
    "build.zig.zon": (
        ".{\n"
        "    .name = .sample,\n"
        '    .version = "0.0.0",\n'
        "    .paths = .{\n"
        '        "build.zig",\n'
        "    },\n"
        "}\n"
    ),
    "README.md": "# excluded\n",
    "scripts/tool.py": (
        "import os\n"
        "\n"
        'TEXT = "# not a comment"\n'
        'BLOCK = """line\n'
        "# not a comment\n"
        '"""\n'
        'JOINED = os.path.join("a#b", "c")\n'
    ),
    "src/main.zig": (
        'const std = @import("std");\n'
        "const quote = '\\'';\n"
        "const slash = '/';\n"
        'const url = "a // b";\n'
        "\n"
        "test {\n"
        "    _ = std;\n"
        "    _ = quote;\n"
        "    _ = slash;\n"
        "    _ = url;\n"
        "}\n"
    ),
    "testdata/README.md": "# excluded\n",
    "testdata/query.sql": (
        "SELECT '--', \"--\", '/*', '*/';\n"
        "SELECT 1 AS [--], 2 AS `--`;\n"
    ),
    "vendor/sqlite3/PROVENANCE.txt": "# not checked\n",
    "vendor/sqlite3/sqlite3.c": "/* vendored */\n",
    "vendor/sqlite3/sqlite3.h": "/* vendored */\n",
}

MAIN_ZIG_LINES = CANONICAL_FILES["src/main.zig"].count("\n")


def write_file(root, rel_path, text):
    path = os.path.join(root, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def read_file(root, rel_path):
    with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
        return handle.read()


def git(root, *args):
    return subprocess.run(
        ["git", "-C", root] + list(args), capture_output=True, text=True
    )


def init_repo(root):
    done = git(root, "init", "-q")
    if done.returncode != 0:
        raise RuntimeError("git init failed: " + done.stderr)


def write_canonical_tree(root):
    for rel_path, text in CANONICAL_FILES.items():
        write_file(root, rel_path, text)


def add_all(root):
    done = git(root, "add", "-A")
    if done.returncode != 0:
        raise RuntimeError("git add failed: " + done.stderr)


def run_checker(root, cwd=None, with_root=True, script=None):
    args = [sys.executable, script or CHECKER]
    if with_root:
        args += ["--root", root]
    done = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    return done.returncode, done.stdout + done.stderr


def case(mutate=None, post_add=None):
    root = tempfile.mkdtemp(prefix="qenome-comments-")
    try:
        init_repo(root)
        write_canonical_tree(root)
        if mutate is not None:
            mutate(root)
        add_all(root)
        if post_add is not None:
            post_add(root)
        return run_checker(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def append(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, read_file(root, rel_path) + text)

    return mutate


def prepend(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, text + read_file(root, rel_path))

    return mutate


def create(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, text)

    return mutate


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def expect_clean(name, code, output):
    expect(name, code == 0, "exit " + str(code) + ", output: " + output.strip())


def expect_rejected(name, code, output, mention=None, label=None):
    expect(name, code == 1, "exit " + str(code) + ", output: " + output.strip())
    expect(name + " reports a comment", "comment" in output, output.strip())
    if mention is not None:
        expect(name + " names the place", mention in output, output.strip())
    if label is not None:
        expect(name + " names the kind", label in output, output.strip())


def main():
    code, output = case()
    expect_clean("the canonical tree passes", code, output)
    expect("the canonical tree reports its root", "root=" in output, output.strip())
    expect("the canonical tree counts the checked files", "8 files checked" in output, output.strip())
    expect("the canonical tree counts the excluded files", "5 excluded" in output, output.strip())

    code, output = case(append("src/main.zig", "// note\n"))
    expect_rejected(
        "a Zig line comment fails",
        code,
        output,
        "src/main.zig:" + str(MAIN_ZIG_LINES + 1),
        "a Zig line comment",
    )

    code, output = case(append("src/main.zig", "/// doc\n"))
    expect_rejected("a Zig doc comment fails", code, output, "src/main.zig:", "a Zig line comment")

    code, output = case(append("src/main.zig", "//! container doc\n"))
    expect_rejected(
        "a Zig container doc comment fails", code, output, "src/main.zig:", "a Zig line comment"
    )

    code, output = case(append("src/main.zig", "const trailing = 1; // note\n"))
    expect_rejected(
        "a trailing Zig comment fails",
        code,
        output,
        "src/main.zig:" + str(MAIN_ZIG_LINES + 1),
        "a Zig line comment",
    )

    code, output = case(prepend("src/main.zig", "// first line\n"))
    expect_rejected(
        "the reported line number is 1", code, output, "src/main.zig:1:", "a Zig line comment"
    )

    code, output = case(append("src/main.zig", 'const kept = "a // b";\n'))
    expect_clean("a Zig string with // passes", code, output)

    code, output = case(append("src/main.zig", "const kept_char = '/';\n"))
    expect_clean("a Zig char literal passes", code, output)

    code, output = case(
        append("src/main.zig", "const kept_multiline =\n    \\\\-- not a comment // no\n;\n")
    )
    expect_clean("a Zig multiline string passes", code, output)

    code, output = case(append("build.zig", "// note\n"))
    expect_rejected("a build.zig comment fails", code, output, "build.zig:", "a Zig line comment")

    code, output = case(append("build.zig.zon", "// note\n"))
    expect_rejected(
        "a build.zig.zon comment fails", code, output, "build.zig.zon:", "a Zig line comment"
    )

    code, output = case(append("scripts/tool.py", "# note\n"))
    expect_rejected(
        "a Python comment fails", code, output, "scripts/tool.py:", "a Python comment"
    )

    code, output = case(
        append("scripts/tool.py", 'def helper():\n    """doc"""\n    return 1\n')
    )
    expect_rejected(
        "a Python function docstring fails", code, output, "scripts/tool.py:", "a Python docstring"
    )

    code, output = case(
        append("scripts/tool.py", 'class Box:\n    """doc"""\n\n    value = 1\n')
    )
    expect_rejected(
        "a Python class docstring fails", code, output, "scripts/tool.py:", "a Python docstring"
    )

    code, output = case(create("scripts/module.py", '"""module doc"""\n\nVALUE = 1\n'))
    expect_rejected(
        "a Python module docstring fails", code, output, "scripts/module.py:", "a Python docstring"
    )

    code, output = case(
        append("scripts/tool.py", "def helper():\n    value = 1\n    'not a docstring'\n    return value\n")
    )
    expect_clean("a bare string that is not a docstring passes", code, output)

    code, output = case(append("scripts/tool.py", "OTHER = '# not a comment'\n"))
    expect_clean("a Python string with # passes", code, output)

    code, output = case(append("scripts/tool.py", 'ANOTHER = """line\n# not a comment\n"""\n'))
    expect_clean("a Python triple-quoted value passes", code, output)

    code, output = case(append("testdata/query.sql", "SELECT 1; -- note\n"))
    expect_rejected(
        "a SQL line comment fails", code, output, "testdata/query.sql:", "a SQL line comment"
    )

    code, output = case(append("testdata/query.sql", "/* note */\n"))
    expect_rejected(
        "a SQL block comment fails", code, output, "testdata/query.sql:", "a SQL block comment"
    )

    code, output = case(append("testdata/query.sql", "SELECT '--', '/*';\n"))
    expect_clean("a SQL string with markers passes", code, output)

    code, output = case(append("testdata/query.sql", 'SELECT 1 AS "--";\n'))
    expect_clean("a SQL quoted identifier passes", code, output)

    code, output = case(append(".github/workflows/quality.yml", "# note\n"))
    expect_rejected(
        "a YAML # fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 1",
    )

    code, output = case(append(".github/workflows/quality.yml", "key: value # note\n"))
    expect_rejected(
        "a trailing YAML # fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 12",
    )

    code, output = case(append(".github/workflows/quality.yml", 'key: "a # b"\n'))
    expect_rejected(
        "a YAML # inside a double-quoted value fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 9",
    )

    code, output = case(append(".github/workflows/quality.yml", "other: 'c # d'\n"))
    expect_rejected(
        "a YAML # inside a single-quoted value fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 11",
    )

    code, output = case(append(".github/workflows/quality.yml", "other: |\n  echo hi # note\n"))
    expect_rejected(
        "a YAML # inside a block scalar fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 11",
    )

    code, output = case(
        append(".github/workflows/quality.yml", "more: |\n  echo 'multi\n  # inside the string\n  done'\n")
    )
    expect_rejected(
        "a YAML # inside a multiline shell string fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 3",
    )

    code, output = case(
        append(
            ".github/workflows/quality.yml",
            "steps:\n  - run: |\n      echo ok\n    name: don't # note\n",
        )
    )
    expect_rejected(
        "a YAML # after an array block scalar fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 17",
    )

    code, output = case(append(".github/workflows/quality.yml", "plain: a-' # note\n"))
    expect_rejected(
        "a YAML # after a plain scalar quote-like character fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 12",
    )

    code, output = case(
        append(".github/workflows/quality.yml", 'key: !<tag:yaml.org,2002:str> "text # literal"\n')
    )
    expect_rejected(
        "a YAML # inside a quoted value after a verbatim tag fails",
        code,
        output,
        ".github/workflows/quality.yml:",
        "a YAML # character at column 37",
    )

    code, output = case(append(".github/workflows/quality.yml", "key: plain value\n"))
    expect_clean("a YAML value without # passes", code, output)

    code, output = case(append(".github/workflows/quality.yml", "key: [one, two]\n"))
    expect_clean("a YAML flow sequence without # passes", code, output)

    code, output = case(append(".github/workflows/quality.yml", "key: |\n  echo ok\n"))
    expect_clean("a YAML block scalar without # passes", code, output)

    code, output = case(append(".github/workflows/quality.yml", "two: a # b # c\n"))
    expect("two YAML # characters fail", code == 1, "exit " + str(code))
    expect(
        "both YAML # characters are reported",
        "column 8" in output and "column 12" in output,
        output.strip(),
    )

    code, output = case(append(".gitignore", "# note\n"))
    expect_rejected("a .gitignore comment fails", code, output, ".gitignore:", "a comment line")

    code, output = case(append(".gitignore", "\\# note\n"))
    expect_clean("an escaped .gitignore marker passes", code, output)

    code, output = case(append(".gitignore", "path#name\n"))
    expect_clean("a .gitignore marker inside a pattern passes", code, output)

    code, output = case(append(".gitattributes", "# note\n"))
    expect_rejected(
        "a .gitattributes comment fails", code, output, ".gitattributes:", "a comment line"
    )

    code, output = case(append("README.md", "# note\n"))
    expect_clean("an excluded document passes", code, output)

    code, output = case(append("testdata/README.md", "# note\n"))
    expect_clean("an excluded test data document passes", code, output)

    code, output = case(append("vendor/sqlite3/sqlite3.c", "// note\n"))
    expect_clean("an excluded vendored file passes", code, output)

    code, output = case(post_add=lambda root: write_file(root, "scratch.zig", "// note\n"))
    expect_clean("an untracked file is not checked", code, output)

    code, output = case(create("data.json", "{}\n"))
    expect_rejected("an unclassified file fails", code, output, "unclassified-file", "data.json")

    code, output = case(create("notes.md", "# note\n"))
    expect_rejected(
        "an unclassified document fails", code, output, "unclassified-file", "notes.md"
    )

    code, output = case(append("src/main.zig", "// one\n// two\n"))
    expect("two comments in one file fail", code == 1, "exit " + str(code))
    expect(
        "both comments are reported",
        "src/main.zig:" + str(MAIN_ZIG_LINES + 1) + ":" in output
        and "src/main.zig:" + str(MAIN_ZIG_LINES + 2) + ":" in output,
        output.strip(),
    )

    code, output = case(append("src/main.zig", "// note\n"))
    expect(
        "the output uses path:line: rule: reason",
        "src/main.zig:" + str(MAIN_ZIG_LINES + 1) + ": comment: " in output,
        output.strip(),
    )

    def copy_checker(root):
        os.makedirs(os.path.join(root, "scripts"), exist_ok=True)
        shutil.copyfile(CHECKER, os.path.join(root, "scripts", "check_comments.py"))

    for name, cwd in (
        ("the root resolves from the script location", None),
        ("the check does not depend on the working directory", os.path.abspath(os.sep)),
    ):
        root = tempfile.mkdtemp(prefix="qenome-comments-")
        try:
            init_repo(root)
            write_canonical_tree(root)
            add_all(root)
            copy_checker(root)
            add_all(root)
            script = os.path.join(root, "scripts", "check_comments.py")
            code, output = run_checker(root, cwd=cwd, with_root=False, script=script)
            expect_clean(name, code, output)
            expect(name + " reports the copied root", f"root={root}" in output, output.strip())
        finally:
            shutil.rmtree(root, ignore_errors=True)

    root = tempfile.mkdtemp(prefix="qenome-comments-")
    try:
        init_repo(root)
        write_canonical_tree(root)
        add_all(root)
        before = {rel_path: read_file(root, rel_path) for rel_path in CANONICAL_FILES}
        run_checker(root)
        after = {rel_path: read_file(root, rel_path) for rel_path in CANONICAL_FILES}
        expect("the check does not write the files", before == after, "a file changed")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    root = tempfile.mkdtemp(prefix="qenome-comments-")
    try:
        write_file(root, "src/main.zig", "// note\n")
        code, output = run_checker(root)
        expect("a tree without git is a usage error", code == 2, "exit " + str(code) + ", " + output)
        expect("a tree without git explains the failure", "tracked files" in output, output.strip())
    finally:
        shutil.rmtree(root, ignore_errors=True)

    done = subprocess.run([sys.executable, CHECKER, "--root"], capture_output=True, text=True)
    expect("a missing --root value is a usage error", done.returncode == 2, done.returncode)

    done = subprocess.run(
        [sys.executable, CHECKER, "--root", os.path.join(tempfile.gettempdir(), "qenome-no-such-tree")],
        capture_output=True,
        text=True,
    )
    expect("a missing root is a usage error", done.returncode == 2, done.returncode)

    if FAILURES:
        print(f"{len(FAILURES)} case(s) failed: " + ", ".join(FAILURES))
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
