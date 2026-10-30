import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_golden.py")
ROOT = os.path.dirname(HERE)

FAILURES: list[str] = []


def load_checker():
    spec = importlib.util.spec_from_file_location("check_golden", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def main():
    checker = load_checker()
    work_parent = os.path.join(tempfile.gettempdir(), "qenome-golden-parent")
    sample = (
        "Summary\n"
        "  work-dir-parent: " + work_parent + "\n"
        "  debug build (no optimization): the times are slower than a release build\n"
        '{\n'
        '  "qenome_version": "9.9.9",\n'
        '  "build_mode": "debug",\n'
        '  "os": "macos",\n'
        '  "arch": "aarch64",\n'
        '  "work_dir_parent": "' + work_parent + '",\n'
        '  "nested": "{\\"qenome_version\\": \\"9.9.9\\", \\"os\\": \\"macos\\"}"\n'
        "}\n"
    )
    actual = checker.normalize(sample, work_parent)
    expect("the work parent is replaced", work_parent not in actual, actual)
    expect("the plain work parent is a placeholder", "<work-dir-parent>" in actual, actual)
    expect("the escaped work parent is a placeholder", actual.count("<work-dir-parent>") == 2, actual)
    expect("the plain version is a placeholder", '"qenome_version": "<version>"' in actual, actual)
    expect("the escaped version is a placeholder", '\\"qenome_version\\": \\"<version>\\"' in actual, actual)
    expect("the build mode is a placeholder", '"build_mode": "<build-mode>"' in actual, actual)
    expect("the os is a placeholder", '"os": "<os>"' in actual, actual)
    expect("the escaped os is a placeholder", '\\"os\\": \\"<os>\\"' in actual, actual)
    expect("the arch is a placeholder", '"arch": "<arch>"' in actual, actual)
    expect("the debug note is removed", "debug build" not in actual, actual)
    expect("the debug note leaves no blank line", "\n\n" not in actual, repr(actual))

    crlf = checker.normalize("a\r\nb\r\n", work_parent)
    expect("CRLF becomes LF", crlf == "a\nb\n", repr(crlf))

    padded = checker.normalize("a  \nb \t\n", work_parent)
    expect("trailing spaces are dropped", padded == "a\nb\n", repr(padded))

    diff = checker.diff_text("a\nb\n", "a\nc\n", "x.txt")
    expect("a different line is reported", "-b" in diff and "+c" in diff, diff)
    expect("the diff names the golden file", "testdata/golden/x.txt" in diff, diff)

    root = tempfile.mkdtemp(prefix="qenome-golden-test-")
    try:
        checker.write_golden(root, "sample.txt", "hello\n")
        expect("a golden file is written", checker.read_golden(root, "sample.txt") == "hello\n", "read failed")
        try:
            checker.read_golden(root, "missing.txt")
        except checker.Unusable as error:
            expect("a missing golden file is unusable", "cannot read" in str(error), error)
        else:
            expect("a missing golden file is unusable", False, "read succeeded")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    names = [case.name for case in checker.CASES]
    expect("every case has a unique name", len(names) == len(set(names)), names)
    expect("every case uses the fixture", all(case.argv()[0] == checker.FIXTURE for case in checker.CASES), names)
    for name in names:
        path = os.path.join(ROOT, checker.GOLDEN_DIR, name)
        expect("the golden file exists: " + name, os.path.isfile(path), path)

    expect("an unknown argument is refused", checker.main(["check_golden.py", "--unknown"]) == 2, "accepted")

    if FAILURES:
        print("test_check_golden: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("test_check_golden: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
