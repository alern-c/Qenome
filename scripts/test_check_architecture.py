import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_architecture.py")
CONTRACT_FILE = "src/contract/values.zig"

FAILURES: list[str] = []


def configured(pattern):
    with open(CHECKER, encoding="utf-8") as handle:
        body = handle.read()
    found = re.search(pattern, body, re.MULTILINE)
    if found is None:
        raise SystemExit("the checker does not define " + pattern)
    return int(found.group(1))


def line_count(body):
    return body.count("\n")

CANONICAL_FILES = {
    "build.zig": '// the module is built as @import("Qenome")\n',
    "src/main.zig": 'const std = @import("std");\nconst Qenome = @import("Qenome");\n',
    "src/root.zig": (
        'pub const contract = @import("contract/values.zig");\n'
        'pub const sql = @import("sql/lexer.zig");\n'
        'pub const sqlite = @import("sqlite.zig");\n'
        'pub const db = @import("db.zig");\n'
        'pub const result = @import("result.zig");\n'
        'pub const cli = @import("cli.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("contract/values.zig");\n'
        '    _ = @import("sql/lexer.zig");\n'
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
        'const sql_lexer = @import("sql/lexer.zig");\n'
    ),
    "src/result.zig": 'const std = @import("std");\nconst sqlite = @import("sqlite.zig");\n',
    "src/sqlite.zig": 'const std = @import("std");\n',
    "src/sql/lexer.zig": 'const std = @import("std");\n',
    "src/contract/values.zig": (
        'const std = @import("std");\n'
        "\n"
        "pub const schema_version: u8 = 2;\n"
        "pub const batch_schema_version: u8 = 1;\n"
        "pub const audit_schema_version: u8 = 1;\n"
        "pub const record_schema_version: u8 = 1;\n"
        "pub const ExitCode = enum(u8) { ok = 0 };\n"
        'pub const warning_codes = [_][]const u8{"no_analyze_stats"};\n'
        'pub const warning_messages = [_][]const u8{"a message"};\n'
        'pub const bind_dependent_partial_index_message = "the message";\n'
        'pub const unapplied_migrations_message = "the message";\n'
        "pub const code = struct {\n"
        '    pub const suggest_failed = "suggest_failed";\n'
        "};\n"
    ),
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
        'const report_model = @import("report/model.zig");\n'
        'const report_human = @import("report/human.zig");\n'
        'const report_kv = @import("report/kv.zig");\n'
        'const report_json = @import("report/json.zig");\n'
        'const cli_pair = @import("cli/pair.zig");\n'
        'const cli_batch = @import("cli/batch.zig");\n'
        'const cli_audit = @import("cli/audit.zig");\n'
        'const cli_record = @import("cli/record.zig");\n'
        'const cli_seed = @import("cli/seed.zig");\n'
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
        'const sql_lexer = @import("../sql/lexer.zig");\n'
        'const build_options = @import("build_options");\n'
        'const usage_text = @import("usage_text.zig");\n'
    ),
    "src/cli/control.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const contract = @import("../contract/values.zig");\n'
        "pub const ExitCode = contract.ExitCode;\n"
    ),
    "src/cli/d1.zig": (
        'const std = @import("std");\n'
        'const config = @import("../d1/config.zig");\n'
    ),
    "src/d1/config.zig": 'const std = @import("std");\n',
    "src/d1/migrations.zig": (
        'const std = @import("std");\n'
        'const sqlite = @import("../sqlite.zig");\n'
    ),
    "src/cli/warnings.zig": (
        'const std = @import("std");\n'
        'const contract = @import("../contract/values.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_d1_migrations = @import("../d1/migrations.zig");\n'
        'const cli_suggest = @import("suggest.zig");\n'
    ),
    "src/cli/d1_tests.zig": (
        'const std = @import("std");\n'
        'const contract = @import("../contract/values.zig");\n'
        'const cli = @import("../cli.zig");\n'
    ),
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
        'const cli_seed = @import("seed.zig");\n'
    ),
    "src/cli/timing.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_query = @import("query.zig");\n'
    ),
    "src/report/model.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const cli_comparison = @import("../cli/comparison.zig");\n'
        'const cli_timing = @import("../cli/timing.zig");\n'
        'const cli_warnings = @import("../cli/warnings.zig");\n'
    ),
    "src/report/format.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const model = @import("model.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("format_tests.zig");\n'
        "}\n"
    ),
    "src/report/human.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const contract = @import("../contract/values.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_comparison = @import("../cli/comparison.zig");\n'
        'const cli_warnings = @import("../cli/warnings.zig");\n'
        'const model = @import("model.zig");\n'
        'const format = @import("format.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("human_tests.zig");\n'
        "}\n"
    ),
    "src/report/kv.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const result = @import("../result.zig");\n'
        'const cli_warnings = @import("../cli/warnings.zig");\n'
        'const model = @import("model.zig");\n'
        'const format = @import("format.zig");\n'
        'const time = @import("time.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("kv_tests.zig");\n'
        "}\n"
    ),
    "src/report/json.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const contract = @import("../contract/values.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_comparison = @import("../cli/comparison.zig");\n'
        'const cli_timing = @import("../cli/timing.zig");\n'
        'const cli_warnings = @import("../cli/warnings.zig");\n'
        'const model = @import("model.zig");\n'
        'const format = @import("format.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("json_tests.zig");\n'
        "}\n"
    ),
    "src/report/time.zig": (
        'const std = @import("std");\n'
        'const cli_timing = @import("../cli/timing.zig");\n'
    ),
    "src/report/format_tests.zig": (
        'const std = @import("std");\n'
        'const format = @import("format.zig");\n'
    ),
    "src/report/human_tests.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const model = @import("model.zig");\n'
        'const format = @import("format.zig");\n'
        'const human = @import("human.zig");\n'
    ),
    "src/report/kv_tests.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const model = @import("model.zig");\n'
        'const kv = @import("kv.zig");\n'
    ),
    "src/report/json_tests.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const model = @import("model.zig");\n'
        'const format = @import("format.zig");\n'
        'const json = @import("json.zig");\n'
    ),
    "src/cli/pair.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_query = @import("query.zig");\n'
        'const report_model = @import("../report/model.zig");\n'
        'const cli_timing = @import("timing.zig");\n'
        'const cli_workspace = @import("workspace.zig");\n'
    ),
    "src/cli/audit.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const cli_args = @import("args.zig");\n'
        'const cli_batch = @import("batch.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_query = @import("query.zig");\n'
        'const report_human = @import("../report/human.zig");\n'
        'const report_json = @import("../report/json.zig");\n'
    ),
    "src/cli/batch.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const result = @import("../result.zig");\n'
        'const sqlite = @import("../sqlite.zig");\n'
        'const cli_args = @import("args.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_pair = @import("pair.zig");\n'
        'const cli_query = @import("query.zig");\n'
        'const report_model = @import("../report/model.zig");\n'
        'const report_json = @import("../report/json.zig");\n'
        'const cli_suggest = @import("suggest.zig");\n'
        'const cli_workspace = @import("workspace.zig");\n'
    ),
    "src/cli/batch_report.zig": 'const std = @import("std");\n',
    "src/cli/record.zig": (
        'const std = @import("std");\n'
        'const builtin = @import("builtin");\n'
        'const cli_args = @import("args.zig");\n'
        'const cli_control = @import("control.zig");\n'
    ),
    "src/cli/suggest.zig": (
        'const std = @import("std");\n'
        'const db = @import("../db.zig");\n'
        'const sqlite = @import("../sqlite.zig");\n'
    ),
    "src/cli/seed.zig": (
        'const std = @import("std");\n'
        'const sqlite = @import("../sqlite.zig");\n'
        'const cli_control = @import("control.zig");\n'
    ),
    "src/cli/tests.zig": (
        'const std = @import("std");\n'
        'const cli = @import("../cli.zig");\n'
        'const db = @import("../db.zig");\n'
        'const sqlite = @import("../sqlite.zig");\n'
        'const cli_comparison = @import("comparison.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_d1 = @import("d1.zig");\n'
        'const cli_suggest = @import("suggest.zig");\n'
        'const cli_seed = @import("seed.zig");\n'
        'const cli_record = @import("record.zig");\n'
    ),
    "src/cli/usage_text.zig": 'pub const body = "";\n',
    "src/cli/skill.zig": (
        'const std = @import("std");\n'
        'const cli_args = @import("args.zig");\n'
        'const cli_control = @import("control.zig");\n'
        'const cli_workspace = @import("workspace.zig");\n'
        'const skill = @import("../skill/skill.zig");\n'
        "\n"
        "test {\n"
        '    _ = @import("skill_tests.zig");\n'
        "}\n"
    ),
    "src/cli/record_shapes.zig": (
        'const std = @import("std");\n'
        'const contract = @import("../contract/values.zig");\n'
        'const report_model = @import("../report/model.zig");\n'
        'const report_json = @import("../report/json.zig");\n'
    ),
    "src/cli/record_tests.zig": (
        'const std = @import("std");\n'
        'const cli = @import("../cli.zig");\n'
        'const cli_record = @import("record.zig");\n'
    ),
    "src/sql/shape.zig": (
        'const std = @import("std");\n'
        'const lexer = @import("lexer.zig");\n'
    ),
    "src/cli/skill_tests.zig": (
        'const std = @import("std");\n'
        'const cli = @import("../cli.zig");\n'
        'const cli_skill = @import("skill.zig");\n'
        'const skill = @import("../skill/skill.zig");\n'
    ),
    "src/skill/skill.zig": (
        'const std = @import("std");\n'
        'const diff = @import("diff.zig");\n'
    ),
    "src/skill/diff.zig": 'const std = @import("std");\n',
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
    expect("the whole tree is checked", "(45 files checked" in output, output.strip())

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

    code, output = case(lambda root: write_file(root, "src/skill/rogue.zig", "// new\n"))
    expect_rejected(
        "an unknown file under src/skill fails", code, output, "unknown-file", "src/skill/rogue.zig"
    )

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
            'const report_model = @import("report/model.zig");\n'
            'const report_human = @import("report/human.zig");\n'
            'const report_kv = @import("report/kv.zig");\n'
            'const report_json = @import("report/json.zig");\n'
            '\ntest {\n    _ = @import("tests.zig");\n}\n',
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
            'const report_model = @import("report/model.zig");\n'
            'const report_human = @import("report/human.zig");\n'
            'const report_kv = @import("report/kv.zig");\n'
            'const report_json = @import("report/json.zig");\n'
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
            'const report_model = @import("report/model.zig");\n'
            'const report_human = @import("report/human.zig");\n'
            'const report_kv = @import("report/kv.zig");\n'
            'const report_json = @import("report/json.zig");\n'
            '\ntest {\n    _ = @import("cli/tests.zig");\n'
            "    _ = @import(\"cli/tests.zig\");\n}\n",
        )
    )
    expect_rejected("two test entries fail", code, output, "test-entry", "found 2")

    code, output = case(
        lambda root: write_file(
            root, "src/sql/lexer.zig", CANONICAL_FILES["src/sql/lexer.zig"] + 'const db = @import("../db.zig");\n'
        )
    )
    expect_rejected("the sql layer may not import the engine", code, output, "layer-order", "src/db.zig")

    code, output = case(
        lambda root: write_file(
            root, CONTRACT_FILE, CANONICAL_FILES[CONTRACT_FILE] + 'const cli = @import("../cli.zig");\n'
        )
    )
    expect_rejected("the contract layer may not import the cli", code, output, "layer-order", "src/cli.zig")

    code, output = case(
        lambda root: write_file(
            root, "src/d1/config.zig", CANONICAL_FILES["src/d1/config.zig"] + 'const db = @import("../db.zig");\n'
        )
    )
    expect_rejected("the d1 component may not import the engine", code, output, "layer-order", "src/db.zig")

    code, output = case(
        lambda root: write_file(
            root, "src/d1/config.zig", CANONICAL_FILES["src/d1/config.zig"] + 'const cli = @import("../cli.zig");\n'
        )
    )
    expect_rejected("the d1 component may not import the cli", code, output, "layer-order", "src/cli.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/report/model.zig",
            CANONICAL_FILES["src/report/model.zig"] + 'const cli_query = @import("../cli/query.zig");\n',
        )
    )
    expect_rejected(
        "the report layer may not import a cli module outside the pending list",
        code,
        output,
        "layer-order",
        "src/cli/query.zig",
    )

    code, output = case(
        lambda root: write_file(
            root,
            "src/report/time.zig",
            CANONICAL_FILES["src/report/time.zig"] + 'const cli = @import("../cli.zig");\n',
        )
    )
    expect_rejected(
        "the report layer may not import the cli coordinator",
        code,
        output,
        "layer-order",
        "src/cli.zig",
    )

    code, output = case(lambda root: write_file(root, "src/d1/extra.zig", "// new\n"))
    expect_rejected("an unknown file under src/d1 fails", code, output, "unknown-file", "src/d1/extra.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/d1/migrations.zig",
            CANONICAL_FILES["src/d1/migrations.zig"] + 'const db = @import("../db.zig");\n',
        )
    )
    expect_rejected("the d1 component may not import the engine", code, output, "layer-order", "src/db.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/d1_tests.zig",
            'const label = "unapplied_migrations";\nconst cli = @import("../cli.zig");\n',
        )
    )
    expect_clean("a test module may hold a contract code and import the cli", code, output)

    code, output = case(
        lambda root: write_file(root, "src/cli/d1_tests.zig", 'const config = @import("../d1/config.zig");\n')
    )
    expect_rejected("a test module needs an approved import", code, output, "unapproved-import", "src/d1/config.zig")

    code, output = case(lambda root: write_file(root, "src/cli/d1.zig", CANONICAL_FILES["src/cli/d1.zig"] + "x\n"))
    expect_clean("an extra line under the cap passes", code, output)

    max_lines = configured(r"^MAX_LINES = (\d+)$")
    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/query.zig",
            CANONICAL_FILES["src/cli/query.zig"] + "const pad = 0;\n" * (max_lines + 1),
        )
    )
    expect_rejected("a new file over the cap fails", code, output, "file-size", "src/cli/query.zig")

    record_limit = configured(r'"src/cli/record.zig": (\d+)')
    at_limit = record_limit - line_count(CANONICAL_FILES["src/cli/record.zig"])

    code, output = case(
        lambda root: write_file(
            root, "src/cli/record.zig", CANONICAL_FILES["src/cli/record.zig"] + "const pad = 0;\n" * at_limit
        )
    )
    expect_clean("a ratcheted file at its limit passes", code, output)

    code, output = case(
        lambda root: write_file(
            root, "src/cli/record.zig", CANONICAL_FILES["src/cli/record.zig"] + "const pad = 0;\n" * (at_limit + 1)
        )
    )
    expect_rejected("a ratcheted file that grows fails", code, output, "file-size", "src/cli/record.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/d1.zig",
            CANONICAL_FILES["src/cli/d1.zig"]
            + 'pub fn shout(stdout: anytype) void {\n    stdout.print("x", .{});\n}\n',
        )
    )
    expect_rejected("a new stdout writer fails", code, output, "stdout-write", "src/cli/d1.zig")

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/query.zig",
            CANONICAL_FILES["src/cli/query.zig"]
            + 'pub fn quiet(stderr: anytype) void {\n    stderr.writeAll("x") catch {};\n}\n',
        )
    )
    expect_clean("an allowlisted writer passes", code, output)

    code, output = case(
        lambda root: write_file(
            root,
            "src/cli/d1.zig",
            CANONICAL_FILES["src/cli/d1.zig"]
            + 'test "a writer in a test" {\n    stdout.print("x", .{});\n}\n',
        )
    )
    expect_clean("a write inside a test block passes", code, output)

    code, output = case(
        lambda root: write_file(
            root, "src/report/human.zig", CANONICAL_FILES["src/report/human.zig"] + "const schema_version: u8 = 2;\n"
        )
    )
    expect_rejected(
        "a contract value defined outside the contract fails", code, output, "contract-value", "schema_version"
    )

    code, output = case(
        lambda root: write_file(
            root, "src/report/human.zig", CANONICAL_FILES["src/report/human.zig"] + "const ExitCode = enum { ok };\n"
        )
    )
    expect_rejected("a redefinition of ExitCode fails", code, output, "contract-value", "ExitCode")

    code, output = case(
        lambda root: write_file(
            root,
            "src/report/human.zig",
            CANONICAL_FILES["src/report/human.zig"] + 'const label = "no_analyze_stats";\n',
        )
    )
    expect_rejected("a contract code outside the contract fails", code, output, "contract-code", "no_analyze_stats")

    code, output = case(
        lambda root: write_file(
            root,
            "src/report/human.zig",
            CANONICAL_FILES["src/report/human.zig"] + 'test "codes" {\n    const label = "data_too_small";\n}\n',
        )
    )
    expect_clean("a contract code inside a test passes", code, output)

    code, output = case(
        lambda root: write_file(
            root, CONTRACT_FILE, 'const std = @import("std");\npub const ExitCode = enum(u8) { ok = 0 };\n'
        )
    )
    expect_rejected("the contract must declare every value", code, output, "missing-contract", "schema_version")

    def normalize(root):
        write_file(
            root,
            "src/cli.zig",
            'const std = @import("std");\nconst db = @import("db.zig");\nconst result = @import("result.zig");\n'
            'const cli_args = @import("./cli/args.zig");\nconst cli_control = @import("cli/control.zig");\n'
            'const cli_comparison = @import("cli/comparison.zig");\nconst cli_query = @import("cli/query.zig");\n'
            'const cli_workspace = @import("cli/workspace.zig");\nconst cli_timing = @import("cli/timing.zig");\n'
            'const report_model = @import("report/model.zig");\n'
            'const report_human = @import("report/human.zig");\n'
            'const report_kv = @import("report/kv.zig");\n'
            'const report_json = @import("report/json.zig");\n'
            '\ntest {\n    _ = @import("cli/tests.zig");\n}\n',
        )
        write_file(root, "src/cli/args.zig", 'const db = @import("./../db.zig");\n')

    code, output = case(normalize)
    expect_clean("normalized paths pass", code, output)

    def two_violations(root):
        os.remove(os.path.join(root, "src/report/human.zig"))
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
