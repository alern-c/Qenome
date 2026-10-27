import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ZON = os.path.join(ROOT, "build.zig.zon")
MINIMUM_ZIG_VERSION = re.compile(r'minimum_zig_version\s*=\s*"([^"]*)"')
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"


def start_stage(name):
    print(("::group::" if IN_ACTIONS else "check_all: ") + name, flush=True)


def end_stage():
    if IN_ACTIONS:
        print("::endgroup::", flush=True)


def verify_zig_version():
    try:
        with open(ZON, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as error:
        sys.stderr.write("check_all: cannot read " + ZON + ": " + str(error) + "\n")
        return 1
    found = MINIMUM_ZIG_VERSION.search(text)
    expected = found.group(1) if found else ""
    done = subprocess.run(["zig", "version"], cwd=ROOT, capture_output=True, text=True)
    actual = done.stdout.strip()
    print("build.zig.zon minimum_zig_version: " + (expected or "<not found>"), flush=True)
    print("effective zig version: " + (actual or "<none>"), flush=True)
    if done.returncode != 0:
        sys.stderr.write(done.stderr)
        return done.returncode if done.returncode > 0 else 1
    if not expected or actual != expected:
        return 1
    return 0


def command(argv):
    def run():
        return subprocess.run(argv, cwd=ROOT).returncode

    return run


def run_stage(name, action):
    start_stage(name)
    try:
        code = action()
    except OSError as error:
        sys.stderr.write("check_all: cannot run the stage: " + str(error) + "\n")
        code = 1
    end_stage()
    if code != 0:
        sys.stderr.write('check_all: failed at "' + name + '" with exit code ' + str(code) + "\n")
        return code if code > 0 else 1
    return 0


def main():
    stages = [
        ("Verify the effective Zig version", verify_zig_version),
        ("Check formatting", command(["zig", "fmt", "--check", "."])),
        ("Build", command(["zig", "build", "--summary", "all"])),
        ("Test", command(["zig", "build", "test", "--summary", "all"])),
        ("Show the Python version", command([sys.executable, "--version"])),
        (
            "Check the Python code with ruff",
            command(["uv", "run", "--locked", "--group", "dev", "ruff", "check", "."]),
        ),
        (
            "Type-check the Python code with mypy",
            command(["uv", "run", "--locked", "--group", "dev", "mypy"]),
        ),
        (
            "Test the architecture checker",
            command([sys.executable, "scripts/test_check_architecture.py"]),
        ),
        (
            "Check the architecture boundaries",
            command([sys.executable, "scripts/check_architecture.py"]),
        ),
        (
            "Test the comment checker",
            command([sys.executable, "scripts/test_check_comments.py"]),
        ),
        ("Check for comments", command([sys.executable, "scripts/check_comments.py"])),
        (
            "Test the npm package staging",
            command([sys.executable, "scripts/test_stage_npm.py"]),
        ),
        (
            "Test the Quick start checker",
            command([sys.executable, "scripts/test_check_quick_start.py"]),
        ),
        (
            "Run the README Quick start",
            command([sys.executable, "scripts/check_quick_start.py"]),
        ),
    ]
    for name, action in stages:
        code = run_stage(name, action)
        if code != 0:
            return code
    print(f"check_all: ok ({len(stages)} stages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
