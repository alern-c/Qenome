import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_quick_start.py")

FAILURES = []

COMMANDS = (
    "./tools/qenome result=match verdict=improved code=0  "
    "# expect: result=match verdict=improved exit=0",
    "./tools/qenome result=match verdict=no-effect code=0  "
    "# expect: result=match verdict=no-effect exit=0",
    "./tools/qenome result=incomparable verdict=not-judged code=4  "
    "# expect: result=incomparable verdict=not-judged exit=4",
)

FAKE_QENOME = (
    "#!/bin/sh\n"
    "result=match\n"
    "verdict=improved\n"
    "code=0\n"
    "summary=1\n"
    'for arg in "$@"; do\n'
    '  case "$arg" in\n'
    "    result=*) result=${arg#result=} ;;\n"
    "    verdict=*) verdict=${arg#verdict=} ;;\n"
    "    code=*) code=${arg#code=} ;;\n"
    "    summary=*) summary=${arg#summary=} ;;\n"
    "  esac\n"
    "done\n"
    'if [ "$summary" = 0 ]; then\n'
    '  echo "the comparison failed"\n'
    '  exit "$code"\n'
    "fi\n"
    'printf "Summary\\n"\n'
    'printf "  result rows   %s (the same rows on both copies)\\n" "$result"\n'
    'printf "  time verdict  %s: for the test\\n" "$verdict"\n'
    'printf "  time          median 1.00 ms -> 2.00 ms (2.000x)\\n"\n'
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


def readme(commands, heading):
    return (
        "# Sample\n"
        "\n"
        "## Installation\n"
        "\n"
        "Build it first.\n"
        "\n"
        "## "
        + heading
        + "\n"
        "\n"
        "Prepare the database:\n"
        "\n"
        "```sh\n"
        "mkdir -p work\n"
        "```\n"
        "\n"
        "```sh\n"
        + "\n".join(commands)
        + "\n"
        "```\n"
        "\n"
        "## Usage\n"
        "\n"
        "Nothing else.\n"
    )


def run_checker(root, args=None):
    argv = [sys.executable, CHECKER]
    argv += ["--root", root] if args is None else args
    done = subprocess.run(argv, capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


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


def rewrite(rel_path, text):
    def mutate(root):
        write_file(root, rel_path, text)

    return mutate


def case(mutate=None):
    root = tempfile.mkdtemp(prefix="qenome-quick-start-")
    try:
        write_file(root, "tools/qenome", FAKE_QENOME)
        make_executable(os.path.join(root, "tools/qenome"))
        write_file(root, "README.md", readme(COMMANDS, "Quick start"))
        write_file(root, "README.ja.md", readme(COMMANDS, "クイックスタート"))
        if mutate is not None:
            mutate(root)
        return run_checker(root)
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
    checker = load_checker()
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
    expect("the canonical tree counts the commands", "3 commands checked" in output, output.strip())
    expect("the canonical tree shows each verdict", "verdict=no-effect" in output, output.strip())
    expect("the canonical tree reports the root", "root=" in output, output.strip())

    code, output = case(
        patch(
            "README.md",
            "# expect: result=match verdict=no-effect exit=0",
            "# expect: result=match verdict=improved exit=0",
        )
    )
    expect_rejected(
        "a verdict that differs fails", code, output, "the verdict differs: the README expects"
    )

    code, output = case(
        patch(
            "README.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=3",
        )
    )
    expect_rejected("an exit status that differs fails", code, output, "the exit status differs")

    code, output = case(
        patch("README.md", "# expect: result=incomparable", "# expect: result=mismatch")
    )
    expect_rejected("a result that differs fails", code, output, "the result differs")

    code, output = case(
        rewrite("README.md", readme((COMMANDS[0], COMMANDS[2]), "Quick start"))
    )
    expect_rejected(
        "a missing required result fails",
        code,
        output,
        "needs a checked example with result=match verdict=no-effect exit=0",
    )

    replaced = (
        COMMANDS[0],
        COMMANDS[1],
        "./tools/qenome result=match verdict=improved code=0  "
        "# expect: result=match verdict=improved exit=0",
    )

    def replace_both(root):
        write_file(root, "README.md", readme(replaced, "Quick start"))
        write_file(root, "README.ja.md", readme(replaced, "クイックスタート"))

    code, output = case(replace_both)
    expect_rejected(
        "an example replaced by the same verdict fails",
        code,
        output,
        "needs a checked example with result=incomparable verdict=not-judged exit=4",
    )

    def unmark_japanese(root):
        text = read_file(root, "README.ja.md")
        write_file(
            root,
            "README.ja.md",
            text.replace("  # expect: result=match verdict=no-effect exit=0", ""),
        )

    code, output = case(unmark_japanese)
    expect_rejected(
        "a marker on one side only fails", code, output, "the expect marker differs"
    )
    expect(
        "a marker on one side only is named",
        "<no expect marker>" in output,
        output.strip(),
    )

    def fence_both(root):
        for name in ("README.md", "README.ja.md"):
            text = read_file(root, name)
            write_file(
                root,
                name,
                text.replace(
                    "```sh\n./tools/qenome result=match verdict=improved",
                    "```bash\n./tools/qenome result=match verdict=improved",
                ),
            )

    code, output = case(fence_both)
    expect_rejected(
        "a block that is not sh fails", code, output, 'the code block is not "```sh"'
    )

    code, output = case(
        insert_before(
            "README.md",
            "## Usage",
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
        patch(
            "README.ja.md",
            "./tools/qenome result=match verdict=improved code=0",
            "./tools/qenome result=match verdict=improved code=1",
        )
    )
    expect_rejected("a Japanese command that differs fails", code, output, "the command differs from")

    code, output = case(
        patch(
            "README.ja.md",
            "# expect: result=match verdict=no-effect exit=0",
            "# expect: result=match verdict=no-effect exit=5",
        )
    )
    expect_rejected(
        "a Japanese expect marker that differs fails", code, output, "the expect marker differs"
    )

    code, output = case(rewrite("README.ja.md", readme(COMMANDS[0:2], "クイックスタート")))
    expect_rejected("a Japanese section with fewer commands fails", code, output, "has 3 command(s)")

    code, output = case(
        insert_before(
            "README.md",
            "## Usage",
            "```sh\n./tools/qenome result=match verdict=improved code=0\n```\n\n",
        )
    )
    expect_rejected("a qenome command without a marker fails", code, output, 'has no "# expect:')

    code, output = case(
        insert_before(
            "README.md",
            "## Usage",
            "```sh\nmkdir -p work  # expect: result=match verdict=improved exit=0\n```\n\n",
        )
    )
    expect_rejected("a marker on a setup command fails", code, output, "belongs on a qenome command")

    code, output = case(insert_before("README.md", "## Usage", "```sh\nfalse\n```\n\n"))
    expect_rejected(
        "a setup command that fails stops the check", code, output, "the setup command exited with 1"
    )

    code, output = case(
        patch(
            "README.md",
            "./tools/qenome result=match verdict=improved code=0",
            "./tools/qenome result=match verdict=improved code=0 summary=0",
        )
    )
    expect_rejected("output without a Summary fails", code, output, 'has no "result rows" line')

    code, output = case(
        patch(
            "README.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved",
        )
    )
    expect_rejected("an expect marker without exit fails", code, output, "has no exit token")

    code, output = case(
        patch(
            "README.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=many",
        )
    )
    expect_rejected("an expect marker with a bad exit fails", code, output, "a whole number")

    code, output = case(
        patch(
            "README.md",
            "# expect: result=match verdict=improved exit=0",
            "# expect: result=match verdict=improved exit=0 extra=1",
        )
    )
    expect_rejected("an expect marker with a bad token fails", code, output, "needs result=")

    code, output = case(
        insert_before("README.md", "## Usage", "```sh\necho one \\\n  two\n```\n\n")
    )
    expect_rejected(
        "a command that continues on the next line fails", code, output, "continues on the next line"
    )

    code, output = case(insert_before("README.md", "## Usage", "```sh\necho open\n"))
    expect_unusable("an unclosed code block is unusable", code, output, "is not closed")

    code, output = case(rewrite("README.md", readme(COMMANDS, "Getting started")))
    expect_unusable(
        "a missing Quick start section is unusable", code, output, 'has no "## Quick start"'
    )

    code, output = case(rewrite("README.ja.md", readme(COMMANDS, "Quick start")))
    expect_unusable(
        "a Japanese file without its heading is unusable",
        code,
        output,
        'has no "## クイックスタート"',
    )

    code, output = case(rewrite("README.md", readme(("mkdir -p work",), "Quick start")))
    expect_rejected(
        "a section without a checked command fails",
        code,
        output,
        'no command with an "# expect:" marker',
    )

    code, output = case(
        append_to("README.md", "\n```sh\n./tools/qenome result=match\n```\n")
    )
    expect_clean("a command outside the section is ignored", code, output)

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
