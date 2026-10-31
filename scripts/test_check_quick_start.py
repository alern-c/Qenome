import atexit
import contextlib
import importlib.util
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_quick_start.py")

FAILURES: list[str] = []

COMMANDS = (
    "./tools/qenome result=match verdict=improved code=0  # expect: result=match verdict=improved exit=0",
    "./tools/qenome result=match verdict=no-effect code=0  # expect: result=match verdict=no-effect exit=0",
    "./tools/qenome result=incomparable verdict=not-judged code=4  "
    "# expect: result=incomparable verdict=not-judged exit=4",
    "./tools/qenome --batch batch.json recommended=cases/improved.index.sql  "
    "# expect: recommended=cases/improved.index.sql exit=0",
)

FAKE_QENOME = (
    "#!/bin/sh\n"
    "result=match\n"
    "verdict=improved\n"
    "code=0\n"
    "summary=1\n"
    "recommended=none\n"
    'for arg in "$@"; do\n'
    '  case "$arg" in\n'
    "    result=*) result=${arg#result=} ;;\n"
    "    verdict=*) verdict=${arg#verdict=} ;;\n"
    "    code=*) code=${arg#code=} ;;\n"
    "    summary=*) summary=${arg#summary=} ;;\n"
    "    recommended=*) recommended=${arg#recommended=} ;;\n"
    "  esac\n"
    "done\n"
    'if [ "$summary" = 0 ]; then\n'
    '  echo "the comparison failed"\n'
    '  exit "$code"\n'
    "fi\n"
    'printf "Summary\\n"\n'
    'printf "  result rows   %s (the same rows on both copies)\\n" "$result"\n'
    'printf "  verdict       %s: for the test\\n" "$verdict"\n'
    'printf "  time          median 1.00 ms -> 2.00 ms (2.000x)\\n"\n'
    'printf "\\nRecommendation: %s\\n" "$recommended"\n'
    'printf "\\nPlan\\n"\n'
    'exit "$code"\n'
)


def load_checker():
    spec = importlib.util.spec_from_file_location("check_quick_start", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKER_MODULE = load_checker()


def write_file(root, rel_path, text):
    path = os.path.join(root, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def read_file(root, rel_path):
    with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
        return handle.read()


def make_executable(path):
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


FAKE_DIR: str | None = None


def fake_qenome():
    global FAKE_DIR
    if FAKE_DIR is None:
        root = tempfile.mkdtemp(prefix="qenome-fake-")
        write_file(root, "qenome", FAKE_QENOME)
        make_executable(os.path.join(root, "qenome"))
        atexit.register(shutil.rmtree, root, ignore_errors=True)
        FAKE_DIR = root
    return FAKE_DIR


def install_fake_qenome(root):
    link = os.path.join(root, "tools", "qenome")
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(os.path.join(fake_qenome(), "qenome"), link)


def contributing(commands):
    return (
        "# Contributing\n"
        "\n"
        "## Build from source\n"
        "\n"
        "Build it first.\n"
        "\n"
        "## Quick start\n"
        "\n"
        "Prepare the database:\n"
        "\n"
        "```sh\n"
        "mkdir -p work\n"
        "```\n"
        "\n"
        "```sh\n" + "\n".join(commands) + "\n"
        "```\n"
        "\n"
        "## Development checks\n"
        "\n"
        "Nothing else.\n"
    )


README = "# Sample\n\nSee [CONTRIBUTING.md](CONTRIBUTING.md) for the Quick start.\n"

README_JA = "# サンプル\n\nQuick start は [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。\n"


def run_checker(root, args=None):
    argv = [sys.executable, CHECKER]
    argv += ["--root", root] if args is None else args
    done = subprocess.run(argv, capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


def run_in_process(root):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = CHECKER_MODULE.main(["check_quick_start.py", "--root", root])
    return code, out.getvalue() + err.getvalue()


def patch(rel_path, old, new):
    def mutate(root):
        text = read_file(root, rel_path)
        write_file(root, rel_path, text.replace(old, new))

    return mutate


def append_to(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, read_file(root, rel_path) + text)

    return mutate


def insert_before(rel_path, anchor, text):
    def mutate(root):
        body = read_file(root, rel_path)
        index = body.find(anchor)
        if index < 0:
            raise RuntimeError("the sample file has no " + anchor)
        write_file(root, rel_path, body[:index] + text + body[index:])

    return mutate


def remove_file(rel_path):
    def mutate(root):
        os.remove(os.path.join(root, rel_path))

    return mutate


def rewrite(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, text)

    return mutate


def case(mutate=None):
    root = tempfile.mkdtemp(prefix="qenome-quick-start-")
    try:
        install_fake_qenome(root)
        write_file(root, "CONTRIBUTING.md", contributing(COMMANDS))
        write_file(root, "README.md", README)
        write_file(root, "README.ja.md", README_JA)
        if mutate is not None:
            mutate(root)
        return run_in_process(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def finish(message):
    if FAILURES:
        print("test_quick_start: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("test_quick_start: " + message)
    return 0


def expect_clean(name, code, output):
    expect(name, code == 0, "exit " + str(code) + ", output: " + output.strip())


def expect_rejected(name, code, output, mention):
    expect(name, code == 1, "exit " + str(code) + ", output: " + output.strip())
    expect(name + " explains why", mention in output, output.strip())


def expect_unusable(name, code, output, mention):
    expect(name, code == 2, "exit " + str(code) + ", output: " + output.strip())
    expect(name + " explains why", mention in output, output.strip())


def main():
    checker = CHECKER_MODULE
    windows = checker.windows_skip_reason("nt")
    expect("Windows is skipped", windows is not None, windows)
    expect("the skip names Windows", windows is not None and "Windows" in windows, windows)
    expect("the skip says skipped", windows is not None and "skipped" in windows, windows)
    expect("Linux and macOS are checked", checker.windows_skip_reason("posix") is None, "posix")
    expect("an empty platform name is checked", checker.windows_skip_reason("") is None, "empty")
    skip = checker.windows_skip_reason(os.name)
    if skip is not None:
        return finish(skip)

    code, output = case()
    expect_clean("the canonical tree passes", code, output)
    expect("the canonical tree counts the commands", "4 commands checked" in output, output.strip())
    expect("the canonical tree shows each verdict", "verdict=no-effect" in output, output.strip())
    expect("the canonical tree reports the root", "root=" in output, output.strip())

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: result=match verdict=no-effect exit=0",
            "# expect: result=match verdict=improved exit=0",
        )
    )
    expect_rejected("a verdict that differs fails", code, output, "the verdict differs: the CONTRIBUTING.md expects")

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=3",
        )
    )
    expect_rejected("an exit status that differs fails", code, output, "the exit status differs")

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: recommended=cases/improved.index.sql exit=0",
            "# expect: recommended=cases/no-effect.index.sql exit=0",
        )
    )
    expect_rejected("a recommendation that differs fails", code, output, "the recommendation differs")

    code, output = case(patch("CONTRIBUTING.md", "# expect: result=incomparable", "# expect: result=mismatch"))
    expect_rejected("a result that differs fails", code, output, "the result differs")

    code, output = case(rewrite("CONTRIBUTING.md", contributing(COMMANDS[0:2])))
    expect_rejected(
        "a missing required result fails",
        code,
        output,
        "needs a checked example with result=incomparable verdict=not-judged exit=4",
    )

    replaced = (
        COMMANDS[0],
        COMMANDS[1],
        "./tools/qenome result=match verdict=improved code=0  # expect: result=match verdict=improved exit=0",
    )

    code, output = case(rewrite("CONTRIBUTING.md", contributing(replaced)))
    expect_rejected(
        "an example replaced by the same verdict fails",
        code,
        output,
        "needs a checked example with result=incomparable verdict=not-judged exit=4",
    )

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "  # expect: result=match verdict=no-effect exit=0",
            "",
        )
    )
    expect_rejected("a qenome command without a marker fails", code, output, 'has no "# expect:')

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "```sh\n./tools/qenome result=match verdict=improved",
            "```bash\n./tools/qenome result=match verdict=improved",
        )
    )
    expect_rejected("a block that is not sh fails", code, output, 'the code block is not "```sh"')

    code, output = case(
        insert_before(
            "CONTRIBUTING.md",
            "## Development checks",
            "```\n./tools/qenome result=match verdict=improved code=0\n```\n\n",
        )
    )
    expect_rejected(
        "a block without a language that holds a command fails",
        code,
        output,
        'the code block is not "```sh"',
    )

    code, output = case(
        insert_before(
            "CONTRIBUTING.md",
            "## Development checks",
            "```sh\n./tools/qenome result=match verdict=improved code=0\n```\n\n",
        )
    )
    expect_rejected("a qenome command without a marker fails", code, output, 'has no "# expect:')

    code, output = case(
        insert_before(
            "CONTRIBUTING.md",
            "## Development checks",
            "```sh\nmkdir -p work  # expect: result=match verdict=improved exit=0\n```\n\n",
        )
    )
    expect_rejected("a marker on a setup command fails", code, output, "belongs on a qenome command")

    code, output = case(insert_before("CONTRIBUTING.md", "## Development checks", "```sh\nfalse\n```\n\n"))
    expect_rejected("a setup command that fails stops the check", code, output, "the setup command exited with 1")

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "./tools/qenome result=match verdict=improved code=0",
            "./tools/qenome result=match verdict=improved code=0 summary=0",
        )
    )
    expect_rejected("output without a Summary fails", code, output, 'has no "result rows" line')

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved",
        )
    )
    expect_rejected("an expect marker without exit fails", code, output, "has no exit token")

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=many",
        )
    )
    expect_rejected("an expect marker with a bad exit fails", code, output, "a whole number")

    code, output = case(
        patch(
            "CONTRIBUTING.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=0 extra=1",
        )
    )
    expect_rejected("an expect marker with a bad token fails", code, output, "needs result=")

    code, output = case(insert_before("CONTRIBUTING.md", "## Development checks", "```sh\necho one \\\n  two\n```\n\n"))
    expect_rejected("a command that continues on the next line fails", code, output, "continues on the next line")

    code, output = case(insert_before("CONTRIBUTING.md", "## Development checks", "```sh\necho open\n"))
    expect_unusable("an unclosed code block is unusable", code, output, "is not closed")

    missing_heading = contributing(COMMANDS).replace("## Quick start", "## Getting started")
    code, output = case(rewrite("CONTRIBUTING.md", missing_heading))
    expect_unusable("a missing Quick start section is unusable", code, output, 'has no "## Quick start"')

    code, output = case(rewrite("CONTRIBUTING.md", contributing(("mkdir -p work",))))
    expect_rejected(
        "a section without a checked command fails",
        code,
        output,
        'no command with an "# expect:" marker',
    )

    code, output = case(append_to("CONTRIBUTING.md", "\n```sh\n./tools/qenome result=match\n```\n"))
    expect_clean("a command outside the section is ignored", code, output)

    code, output = case(patch("README.ja.md", "[CONTRIBUTING.md](CONTRIBUTING.md)", "the guide"))
    expect_rejected("a README without the link fails", code, output, "the README must link to CONTRIBUTING.md")

    code, output = case(remove_file("CONTRIBUTING.md"))
    expect_unusable("a missing CONTRIBUTING.md is unusable", code, output, "cannot read")

    root = tempfile.mkdtemp(prefix="qenome-quick-start-")
    try:
        code, output = run_checker(root, ["--unknown"])
        expect_unusable("an unknown argument is refused", code, output, "usage:")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    code, output = run_checker(os.path.join(tempfile.gettempdir(), "qenome-missing-root"))
    expect_unusable("a missing root is refused", code, output, "not a directory")

    return finish("ok")


if __name__ == "__main__":
    sys.exit(main())
