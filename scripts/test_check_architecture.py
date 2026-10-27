import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_architecture.py")

FAILURES: list[str] = []

CANONICAL_FILES = {
    "build.zig": '// the module is built as @import("Qenome")\n',
    "src/main.zig": 'const std = @import("std");\nconst Qenome = @import("Qenome");\n',
    "src/root.zig": (
        'pub const sqlite = @import("sqlite.zig");\n'
        'pub const db = @import("db.zig");\n'
        'pub const result = @import("result.zig");\n'
        'pub const cli = @import("cli.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("sqlite.zig");\n'
        '    _ = @import("db.zig");\n'
        '    _ = @import("result.zig");\n'
        '    _ = @import("cli.zig");\n'
        "}\n"
    ),
    "src/db.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const sqlite = @import("sqlite.zig");\n'
        'const result = @import("result.zig");\n'
    ),
    "src/result.zig": 'const std = @import("std");\nconst sqlite = @import("sqlite.zig");\n',
    "src/sqlite.zig": 'const std = @import("std");\n',
    "src/cli.zig": (
        'const std = @import("std");\n'
        'const db = @import("db.zig");\n'
        'const result = @import("result.zig");\n'
        'const cli_args = @import("cli/args.zig");\n'
        'const cli_d1 = @import("cli/d1.zig");\n'
        'const cli_control = @import("cli/control.zig");\n'
        'const cli_comparison = @import("cli/comparison.zig");\n'
        'const cli_query = @import("cli/query.zig");\n'
        'const cli_workspace = @import("cli/workspace.zig");\n'
        'const cli_timing = @import("cli/timing.zig");\n'
        'const cli_report = @import("cli/report.zig");\n'
        'const cli_pair = @import("cli/pair.zig");\n'
        "\n"
        "pub fn run() void {}\n"
        "\n"
        "test {\n"
        '    _ = @import("cli/tests.zig");\n'
        "}\n"
    ),
    "src/cli/args.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const build_options = @import("build_options");\n'
    ),
    "src/cli/control.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
    ),
    "src/cli/d1.zig": 'const std = @import("std");\n',
    "src/cli/comparison.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
    ),
    "src/cli/query.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const sqlite = @import("../sqlite.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
    ),
    "src/cli/workspace.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_query = @import("query.zig");\n'
    ),
    "src/cli/timing.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_query = @import("query.zig");\n'
    ),
    "src/cli/report.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const result = @import("../result.zig");\n'
        'const cli_args = @import("args.zig");\n'
        'const cli_d1 = @import("d1.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_timing = @import("timing.zig");\n'
    ),
    "src/cli/pair.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_d1 = @import("d1.zig");\n'
        'const cli_query = @import("query.zig");\n'
        'const cli_report = @import("report.zig");\n'
        'const cli_timing = @import("timing.zig");\n'
        'const cli_workspace = @import("workspace.zig");\n'
    ),
    "src/cli/tests.zig": (
        'const std = @import("std");\n'
        'const cli = @import("../cli.zig");\n'
        'const db = @import("../db.zig");\n'
        'const sqlite = @import("../sqlite.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_d1 = @import("d1.zig");\n'
    ),
}

def write_file(root, rel_path, text):
    path = os.path.join(root, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)

def write_canonical_tree(root):
    for rel_path, text in CANONICAL_FILES.items():
        write_file(root, rel_path, text)

def run_checker(root, cwd=None, with_root=True, script=None):
    args = [sys.executable, script or CHECKER]
    if with_root:
        args += ["--root", root]
    done = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    return done.returncode, done.stdout + done.stderr

def case(mutate, extra_check=None, cwd=None, with_root=True):
    root = tempfile.mkdtemp(prefix="qenome-arch-")
    try:
        write_canonical_tree(root)
        if mutate is not None:
            mutate(root)
        code, output = run_checker(root, cwd=cwd, with_root=with_root)
        if extra_check is not None:
            extra_check(root)
        return code, output
    finally:
        shutil.rmtree(root, ignore_errors=True)

def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))

def expect_clean(name, code, output):
    expect(name, code == 0, "exit " + str(code) + ", output: " + output.strip())

def expect_rejected(name, code, output, rule, mention=None):
    expect(name, code == 1, "exit " + str(code) + ", output: " + output.strip())
    expect(name + " names the rule", rule in output, output.strip())
    if mention is not None:
        expect(name + " names the place", mention in output, output.strip())

def main():
    code, output = case(None)
    expect_clean("the smallest approved tree passes", code, output)
    expect("the whole tree is checked", "(16 files checked" in output, output.strip())

    code, output = case(lambda root: os.remove(os.path.join(root, "src/cli/tests.zig")))
    expect_rejected("a missing test file fails", code, output, "missing-file", "src/cli/tests.zig")

    code, output = case(lambda root: os.remove(os.path.join(root, "src/cli/query.zig")))
    expect_rejected("a missing module fails", code, output, "missing-file", "src/cli/query.zig")

    for rel_path in ("src/sqlite.zig", "src/result.zig", "src/db.zig", "src/root.zig", "src/main.zig"):
        code, output = case(
            lambda root, rel_path=rel_path: os.remove(os.path.join(root, rel_path))
        )
        expect_rejected("a missing " + rel_path + " fails", code, output, "missing-file", rel_path)

    code, output = case(lambda root: write_file(root, "src/cli/extra.zig", "// new\n"))
    expect_rejected("an unknown file under src/cli fails", code, output, "unknown-file", "extra.zig")

    code, output = case(lambda root: write_file(root, "src/extra.zig", "// new\n"))
    expect_rejected("an unknown file under src fails", code, output, "unknown-file", "src/extra.zig")

    code, output = case(lambda root: shutil.rmtree(os.path.join(root, "src/cli")))
    expect_rejected("a missing src/cli directory fails", code, output, "missing-file", "src/cli/args.zig")

    code, output = case(
        lambda root: write_file(
            root, "src/cli/args.zig", 'const std = @import("std");\nconst sqlite = @import("../sqlite.zig");\n'
        )
    )
    expect_rejected("an unapproved import fails", code, output, "unapproved-import", "src/sqlite.zig")

    code, output = case(
        lambda root: write_file(
            root, "src/sqlite.zig", 'const std = @import("std");\nconst cli = @import("cli.zig");\n'
        )
    )
    expect_rejected(
        "the bottom layer may not import the CLI", code, output, "unapproved-import", "src/cli.zig"
    )

    code, output = case(
        lambda root: write_file(
            root,
            "src/db.zig",
            'const sqlite = @import("sqlite.zig");\nconst result = @import("result.zig");\n'
            'const cli_query = @import("cli/query.zig");\n',
        )
    )
    expect_rejected(
        "the database layer may not import the CLI submodules",
        code,
        output,
        "unapproved-import",
        "src/cli/query.zig",
    )

    code, output = case(
        lambda root: write_file(root, "src/main.zig", 'const db = @import("db.zig");\n')
    )
    expect_rejected(
        "the executable may not import a path", code, output, "unapproved-import", "src/db.zig"
    )

    code, output = case(
        lambda root: write_file(root, "src/db.zig", 'const Qenome = @import("Qenome");\n')
    )
    expect_rejected(
        "only the executable may import the module name",
        code,
        output,
        "unapproved-import",
        "Qenome",
    )

    code, output = case(
        lambda root: (
            write_file(root, "src/result.zig", 'const db = @import("db.zig");\n'),
            write_file(root, "src/db.zig", 'const result = @import("result.zig");\n'),
        )
    )
    expect_rejected(
        "a cycle outside the CLI layer fails", code, output, "cycle", "src/result.zig"
    )

    code, output = case(
        lambda root: write_file(
            root, "src/cli/args.zig", 'const cli = @import("../cli.zig");\n'
        )
    )
    expect_rejected("a child may not import the coordinator", code, output, "unapproved-import", "src/cli.zig")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", 'const outside = @import("../../../outside.zig");\n')
    )
    expect_rejected("an import outside the root fails", code, output, "outside-root", "outside.zig")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", 'const db = @import("some_module");\n')
    )
    expect_rejected("an unknown module fails", code, output, "unapproved-import", "some_module")

    code, output = case(
        lambda root: write_file(
            root, "src/cli/control.zig", 'const build_options = @import("build_options");\n'
        )
    )
    expect_rejected(
        "only the argument parser may import the build options",
        code,
        output,
        "unapproved-import",
        "build_options",
    )

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", "const db = @import(name);\n")
    )
    expect_rejected("a non-literal import fails", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(
            root, "src/cli/args.zig", 'const db = @import(\n    "../db.zig");\n'
        )
    )
    expect_rejected("a multi-line import fails", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", 'const sqlite = @import ("../sqlite.zig");\n')
    )
    expect_rejected("a space before the argument fails", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", 'const db = @import\n    ("../db.zig");\n')
    )
    expect_rejected("an argument on the next line fails", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", 'const db = @import("../db" ++ ".zig");\n')
    )
    expect_rejected("a joined path fails", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(
            root, "src/cli/args.zig", 'const message = "see @import(\\"db.zig\\")";\n'
        )
    )
    expect_rejected("an import-like text in a string fails conservatively", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: write_file(root, "src/cli/args.zig", '// see @import("../db.zig")\n')
    )
    expect_rejected("an import inside a comment fails conservatively", code, output, "import-form", "args.zig:1")

    code, output = case(
        lambda root: (
            write_file(root, "src/cli/args.zig", 'const cli_comparison = @import("comparison.zig");\n'),
            write_file(root, "src/cli/comparison.zig", 'const cli_args = @import("args.zig");\n'),
        )
    )
    expect_rejected("a production cycle fails", code, output, "cycle")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/args.zig",
            'const std = @import("std");\nconst db = @import("../db.zig");\nconst tests = @import("tests.zig");\n',
        )
    )
    expect_rejected("a second import of the test file fails", code, output, "test-entry", "found 2")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli.zig",
            'const std = @import("std");\nconst db = @import("db.zig");\nconst result = @import("result.zig");\n'
            'const cli_args = @import("cli/args.zig");\nconst cli_control = @import("cli/control.zig");\n'
            'const cli_comparison = @import("cli/comparison.zig");\nconst cli_query = @import("cli/query.zig");\n'
            'const cli_workspace = @import("cli/workspace.zig");\nconst cli_timing = @import("cli/timing.zig");\n'
            'const cli_report = @import("cli/report.zig");\n\ntest {\n    _ = @import("tests.zig");\n}\n',
        )
    )
    expect_rejected("a differently written test entry fails", code, output, "test-entry", "cli/tests.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli.zig",
            'const std = @import("std");\nconst db = @import("db.zig");\nconst result = @import("result.zig");\n'
            'const cli_args = @import("cli/args.zig");\nconst cli_control = @import("cli/control.zig");\n'
            'const cli_comparison = @import("cli/comparison.zig");\nconst cli_query = @import("cli/query.zig");\n'
            'const cli_workspace = @import("cli/workspace.zig");\nconst cli_timing = @import("cli/timing.zig");\n'
            'const cli_report = @import("cli/report.zig");\n'
            '_ = @import("cli/tests.zig");\n',
        )
    )
    expect_rejected("a test entry outside a test block fails", code, output, "test-entry", "outside a test block")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli.zig",
            'const std = @import("std");\nconst db = @import("db.zig");\nconst result = @import("result.zig");\n'
            'const cli_args = @import("cli/args.zig");\nconst cli_control = @import("cli/control.zig");\n'
            'const cli_comparison = @import("cli/comparison.zig");\nconst cli_query = @import("cli/query.zig");\n'
            'const cli_workspace = @import("cli/workspace.zig");\nconst cli_timing = @import("cli/timing.zig");\n'
            'const cli_report = @import("cli/report.zig");\n\ntest {\n    _ = @import("cli/tests.zig");\n'
            "    _ = @import(\"cli/tests.zig\");\n}\n",
        )
    )
    expect_rejected("two test entries fail", code, output, "test-entry", "found 2")

    def normalize(root):
        write_file(
            root,
            "src/cli.zig",
            'const std = @import("std");\nconst db = @import("db.zig");\nconst result = @import("result.zig");\n'
            'const cli_args = @import("./cli/args.zig");\nconst cli_control = @import("cli/control.zig");\n'
            'const cli_comparison = @import("cli/comparison.zig");\nconst cli_query = @import("cli/query.zig");\n'
            'const cli_workspace = @import("cli/workspace.zig");\nconst cli_timing = @import("cli/timing.zig");\n'
            'const cli_report = @import("cli/report.zig");\n\ntest {\n    _ = @import("cli/tests.zig");\n}\n',
        )
        write_file(root, "src/cli/args.zig", 'const db = @import("./../db.zig");\n')

    code, output = case(normalize)
    expect_clean("normalized paths pass", code, output)

    def two_violations(root):
        os.remove(os.path.join(root, "src/cli/report.zig"))
        write_file(root, "src/cli/args.zig", 'const sqlite = @import("../sqlite.zig");\n')

    code, output = case(two_violations)
    expect("two violations fail", code == 1, "exit " + str(code))
    expect(
        "both violations are reported",
        "missing-file" in output and "unapproved-import" in output,
        output.strip(),
    )

    def copy_checker(root):
        os.makedirs(os.path.join(root, "scripts"), exist_ok=True)
        shutil.copyfile(CHECKER, os.path.join(root, "scripts", "check_architecture.py"))

    for name, cwd in (("the root resolves from the script location", None),
                      ("the check does not depend on the working directory", os.path.abspath(os.sep))):
        root = tempfile.mkdtemp(prefix="qenome-arch-")
        try:
            write_canonical_tree(root)
            copy_checker(root)
            script = os.path.join(root, "scripts", "check_architecture.py")
            code, output = run_checker(root, cwd=cwd, with_root=False, script=script)
            expect_clean(name, code, output)
            expect(name + " reports the copied root", f"root={root}" in output, output.strip())
        finally:
            shutil.rmtree(root, ignore_errors=True)

    done = subprocess.run(
        [sys.executable, CHECKER, "--root"], capture_output=True, text=True
    )
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
