import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
GOLDEN_DIR = os.path.join("testdata", "golden")
FIXTURE = os.path.join("testdata", "generated", "qenome-fixture.db")

VOLATILE = re.compile(r'(\\?")(qenome_version|build_mode|os|arch)(\\?": ?\\?")([^"\\]*)(\\?")')
PLACEHOLDERS = {
    "qenome_version": "<version>",
    "build_mode": "<build-mode>",
    "os": "<os>",
    "arch": "<arch>",
}
DEBUG_NOTE = re.compile(r"^  debug build \(no optimization\):.*\n", re.MULTILINE)


class Unusable(Exception):
    pass


class Case:
    __slots__ = ("name", "args", "exit_code")

    def __init__(self, name, args, exit_code=0):
        self.name = name
        self.args = args
        self.exit_code = exit_code

    def argv(self):
        return [FIXTURE] + self.args


CASES = [
    Case(
        "single.human.txt",
        ["testdata/cases/improved.sql", "testdata/cases/improved.index.sql", "--bind", "1:int:1234", "--runs", "0"],
    ),
    Case(
        "single.json",
        [
            "testdata/cases/improved.sql",
            "testdata/cases/improved.index.sql",
            "--bind",
            "1:int:1234",
            "--runs",
            "0",
            "--format",
            "json",
        ],
    ),
    Case(
        "write.human.txt",
        [
            "--write",
            "testdata/cases/write.sql",
            "--index-sql",
            "testdata/cases/improved.index.sql",
            "--bind",
            "1:int:1234",
            "--runs",
            "0",
        ],
    ),
    Case(
        "write.json",
        [
            "--write",
            "testdata/cases/write.sql",
            "--index-sql",
            "testdata/cases/improved.index.sql",
            "--bind",
            "1:int:1234",
            "--runs",
            "0",
            "--format",
            "json",
        ],
    ),
    Case("batch.human.txt", ["--batch", "testdata/batch.json"]),
    Case("batch.json", ["--batch", "testdata/batch.json", "--format", "json"]),
    Case(
        "suggest.human.txt",
        ["testdata/cases/improved.sql", "--bind", "1:int:1234", "--suggest"],
    ),
    Case(
        "suggest.json",
        ["testdata/cases/improved.sql", "--bind", "1:int:1234", "--suggest", "--format", "json"],
    ),
]


def normalize(text, work_parent):
    text = text.replace("\r\n", "\n")
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    text = text.replace(work_parent, "<work-dir-parent>")

    def replace(found):
        return found.group(1) + found.group(2) + found.group(3) + PLACEHOLDERS[found.group(2)] + found.group(5)

    text = VOLATILE.sub(replace, text)
    return DEBUG_NOTE.sub("", text)


def diff_text(expected, actual, name):
    lines = difflib.unified_diff(
        expected.splitlines(keepends=True),
        actual.splitlines(keepends=True),
        fromfile=os.path.join(GOLDEN_DIR, name),
        tofile="actual/" + name,
    )
    return "".join(list(lines)[:200])


def read_golden(root, name):
    path = os.path.join(root, GOLDEN_DIR, name)
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise Unusable("cannot read " + path + ": " + str(error)) from None


def write_golden(root, name, text):
    path = os.path.join(root, GOLDEN_DIR, name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    except OSError as error:
        raise Unusable("cannot write " + path + ": " + str(error)) from None


def binary_path(root):
    name = "qenome.exe" if os.name == "nt" else "qenome"
    path = os.path.join(root, "zig-out", "bin", name)
    if not os.path.isfile(path):
        raise Unusable("there is no built binary at " + path + "; run zig build first")
    return path


def run_sqlite(root, name):
    try:
        done = subprocess.run(
            ["sqlite3", FIXTURE, ".read testdata/" + name],
            cwd=root,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
    except OSError as error:
        raise Unusable("cannot run sqlite3: " + str(error)) from None
    if done.returncode != 0:
        raise Unusable("sqlite3 failed on testdata/" + name + ": " + (done.stderr or done.stdout).strip())


def build_fixture(root):
    path = os.path.join(root, FIXTURE)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            os.remove(path)
    except OSError as error:
        raise Unusable("cannot prepare " + path + ": " + str(error)) from None
    for name in ("schema.sql", "seed.sql", "verify.sql"):
        run_sqlite(root, name)


def run_case(root, case, work_parent):
    env = dict(os.environ)
    env["TMPDIR"] = work_parent
    env["TMP"] = work_parent
    env["TEMP"] = work_parent
    try:
        done = subprocess.run(
            [binary_path(root)] + case.argv(),
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=600,
            stdin=subprocess.DEVNULL,
        )
    except OSError as error:
        raise Unusable("cannot run qenome: " + str(error)) from None
    except subprocess.TimeoutExpired:
        raise Unusable("the golden command did not finish within 600 seconds: " + " ".join(case.argv())) from None
    return done


def run(root, update):
    build_fixture(root)
    work_parent = tempfile.mkdtemp(prefix="qenome-golden-")
    violations = []
    try:
        for case in CASES:
            done = run_case(root, case, work_parent)
            if done.returncode != case.exit_code:
                violations.append(
                    case.name
                    + ": the exit status is "
                    + str(done.returncode)
                    + ", expected "
                    + str(case.exit_code)
                    + "\n"
                    + (done.stderr or done.stdout)[:2000]
                )
                continue
            if done.stderr.strip():
                violations.append(case.name + ": stderr is not empty:\n" + done.stderr[:2000])
                continue
            actual = normalize(done.stdout, work_parent)
            if update:
                write_golden(root, case.name, actual)
                print("golden: updated " + case.name, flush=True)
                continue
            expected = read_golden(root, case.name)
            if expected == actual:
                print("golden: ok " + case.name, flush=True)
                continue
            violations.append(case.name + ": the output differs\n" + diff_text(expected, actual, case.name))
    finally:
        shutil.rmtree(work_parent, ignore_errors=True)
    return violations


def main(argv):
    root = None
    update = False
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        elif rest[0] == "--update":
            update = True
            rest = rest[1:]
        else:
            sys.stderr.write("usage: python3 scripts/check_golden.py [--root DIR] [--update]\n")
            return 2
    if root is None:
        root = DEFAULT_ROOT
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write("golden: not a directory: " + root + "\n")
        return 2
    try:
        violations = run(root, update)
    except Unusable as error:
        sys.stderr.write("golden: " + str(error) + "\n")
        return 2
    for violation in violations:
        print(violation)
    if violations:
        print("golden: " + str(len(violations)) + " violation(s), root=" + root)
        return 1
    if update:
        print("golden: updated " + str(len(CASES)) + " file(s), root=" + root)
    else:
        print("golden: ok (" + str(len(CASES)) + " cases, root=" + root + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
