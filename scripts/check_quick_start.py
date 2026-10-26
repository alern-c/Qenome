import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)

SOURCE = "README.md"
TRANSLATION = "README.ja.md"
HEADINGS = {SOURCE: "Quick start", TRANSLATION: "クイックスタート"}
EXPECT_KEYS = ("result", "verdict", "exit")
WINDOWS_SKIP = "skipped on Windows: the Quick start commands are for Linux and macOS"

FENCE = re.compile(r"^```(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
EXPECT = re.compile(r"^(.+?)\s+#\s*expect:\s*(.+)$")
RESULT_ROW = re.compile(r"^\s+result rows\s+(\S+)")
VERDICT = re.compile(r"^\s+verdict\s+([A-Za-z][A-Za-z-]*)")
REQUIRED_RESULTS = (
    {"result": "match", "verdict": "improved", "exit": 0},
    {"result": "match", "verdict": "no-effect", "exit": 0},
    {"result": "incomparable", "verdict": "not-judged", "exit": 4},
)


class Unusable(Exception):
    pass


class Step:
    __slots__ = ("file", "line", "command", "expected")

    def __init__(self, file, line, command, expected):
        self.file = file
        self.line = line
        self.command = command
        self.expected = expected

    def label(self):
        return self.file + ":" + str(self.line)


def read_text(root, name):
    path = os.path.join(root, name)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise Unusable("cannot read " + path + ": " + str(error)) from None


def section_lines(name, text, heading):
    wanted = heading.strip().lower()
    lines = text.split("\n")
    start = None
    for index, line in enumerate(lines):
        found = HEADING.match(line)
        if found is None or len(found.group(1)) != 2:
            continue
        if found.group(2).strip().lower() == wanted:
            start = index + 1
            break
    if start is None:
        raise Unusable(name + ' has no "## ' + heading + '" section')
    collected = []
    for index in range(start, len(lines)):
        line = lines[index]
        found = HEADING.match(line)
        if found is not None and len(found.group(1)) <= 2:
            break
        collected.append((index + 1, line))
    return collected


def block_lines(name, lines, violations):
    collected = []
    kind = None
    for number, line in lines:
        fence = FENCE.match(line)
        if kind is None:
            if fence is not None:
                kind = fence.group(1).strip()
            continue
        if fence is not None:
            kind = None
            continue
        if not line.strip():
            continue
        if kind == "sh":
            collected.append((number, line.strip()))
        elif "# expect:" in line or is_qenome(line.strip()):
            violations.append(
                name
                + ":"
                + str(number)
                + ': the code block is not "```sh", so the check cannot run this line: '
                + line.strip()
            )
    if kind is not None:
        raise Unusable(name + " has a code block that is not closed")
    return collected


def is_qenome(command):
    words = command.split()
    if not words:
        return False
    return os.path.basename(words[0]) in ("qenome", "qenome.exe")


def parse_expect(text):
    values = {}
    for token in text.split():
        key, separator, value = token.partition("=")
        if not separator or key not in EXPECT_KEYS or not value:
            return None, "the expect marker needs result=, verdict=, and exit= tokens"
        if key in values:
            return None, "the expect marker repeats " + key
        values[key] = value
    missing = [key for key in EXPECT_KEYS if key not in values]
    if missing:
        return None, "the expect marker has no " + ", ".join(missing) + " token"
    if not values["exit"].isdigit():
        return None, "the expect marker needs a whole number for exit"
    values["exit"] = int(values["exit"])
    return values, None


def parse_steps(name, lines, violations):
    steps = []
    for number, text in block_lines(name, lines, violations):
        label = name + ":" + str(number)
        if text.endswith("\\"):
            violations.append(label + ": a command that continues on the next line is not supported")
            continue
        marker = EXPECT.match(text)
        if marker is None:
            steps.append(Step(name, number, text, None))
            continue
        expected, problem = parse_expect(marker.group(2))
        if problem is not None:
            violations.append(label + ": " + problem)
            continue
        steps.append(Step(name, number, marker.group(1).strip(), expected))
    for step in steps:
        if is_qenome(step.command) and step.expected is None:
            violations.append(
                step.label()
                + ': the qenome command has no "# expect: result=... verdict=... exit=..." marker: '
                + step.command
            )
        elif not is_qenome(step.command) and step.expected is not None:
            violations.append(
                step.label() + ": the expect marker belongs on a qenome command: " + step.command
            )
    return steps


def steps_for(root, name, violations):
    text = read_text(root, name)
    lines = section_lines(name, text, HEADINGS[name])
    return parse_steps(name, lines, violations)


def summary_lines(stdout):
    collected = []
    inside = False
    for line in stdout.splitlines():
        if not inside:
            if line.strip() == "Summary":
                inside = True
            continue
        if not line.strip():
            break
        collected.append(line.rstrip())
    return collected


def summarised(summary):
    result = None
    verdict = None
    for line in summary:
        found = RESULT_ROW.match(line)
        if found is not None and result is None:
            result = found.group(1).lower()
        found = VERDICT.match(line)
        if found is not None and verdict is None:
            verdict = found.group(1).lower()
    return result, verdict


def details(step, done, summary):
    lines = [step.label() + ": command: " + step.command]
    if summary:
        lines.extend("    " + line.strip() for line in summary)
    else:
        output = [line.rstrip() for line in (done.stdout + done.stderr).splitlines() if line.strip()]
        lines.extend("    " + line for line in output[:6])
    return "\n".join(lines)


def execute(root, step, violations):
    try:
        done = subprocess.run(
            ["sh", "-c", step.command], cwd=root, capture_output=True, text=True, timeout=600
        )
    except OSError as error:
        violations.append(step.label() + ": the command could not run: " + str(error))
        return False, None, None
    except subprocess.TimeoutExpired:
        violations.append(step.label() + ": the command did not finish within 600 seconds: " + step.command)
        return False, None, None
    if step.expected is None:
        if done.returncode == 0:
            return True, None, None
        violations.append(
            step.label()
            + ": the setup command exited with "
            + str(done.returncode)
            + "\n"
            + details(step, done, summary_lines(done.stdout))
        )
        return False, None, None
    summary = summary_lines(done.stdout)
    result, verdict = summarised(summary)
    problems = []
    if result is None:
        problems.append('the output has no "result rows" line in the Summary')
    if verdict is None:
        problems.append('the output has no "verdict" line in the Summary')
    for key, observed in (("result", result), ("verdict", verdict)):
        if observed is not None and step.expected[key] != observed:
            problems.append(
                "the "
                + key
                + ' differs: the README expects "'
                + str(step.expected[key])
                + '", the command reported "'
                + observed
                + '"'
            )
    if done.returncode != step.expected["exit"]:
        problems.append(
            "the exit status differs: the README expects "
            + str(step.expected["exit"])
            + ", the command exited "
            + str(done.returncode)
        )
    if not problems:
        return True, result, verdict
    violations.append(step.label() + ": " + "; ".join(problems) + "\n" + details(step, done, summary))
    return False, result, verdict


def describe_expected(expected):
    if expected is None:
        return "<no expect marker>"
    return (
        "result="
        + str(expected["result"])
        + " verdict="
        + str(expected["verdict"])
        + " exit="
        + str(expected["exit"])
    )


def compare(english, japanese, violations):
    if len(english) != len(japanese):
        violations.append(
            TRANSLATION
            + ": the Quick start has "
            + str(len(japanese))
            + " command(s), but "
            + SOURCE
            + " has "
            + str(len(english))
        )
        return
    for left, right in zip(english, japanese, strict=True):
        if left.command != right.command:
            violations.append(
                right.label()
                + ": the command differs from "
                + left.label()
                + "\n    "
                + SOURCE
                + ": "
                + left.command
                + "\n    "
                + TRANSLATION
                + ": "
                + right.command
            )
            continue
        if left.expected != right.expected:
            violations.append(
                right.label()
                + ": the expect marker differs from "
                + left.label()
                + "\n    "
                + SOURCE
                + ": "
                + describe_expected(left.expected)
                + "\n    "
                + TRANSLATION
                + ": "
                + describe_expected(right.expected)
            )


def run(root):
    violations = []
    english = steps_for(root, SOURCE, violations)
    japanese = steps_for(root, TRANSLATION, violations)
    compare(english, japanese, violations)
    checked = 0
    for step in english:
        ok, result, verdict = execute(root, step, violations)
        if step.expected is None:
            if not ok:
                break
            continue
        if not ok:
            continue
        checked += 1
        print(step.label() + ": result=" + str(result) + " verdict=" + str(verdict), flush=True)
    declared = [step.expected for step in english if step.expected is not None]
    if not declared:
        violations.append(
            SOURCE + ': the Quick start has no command with an "# expect:" marker to check'
        )
    else:
        for required in REQUIRED_RESULTS:
            if required not in declared:
                violations.append(
                    SOURCE
                    + ": the Quick start needs a checked example with "
                    + describe_expected(required)
                )
    return violations, checked


def windows_skip_reason(platform_name):
    if platform_name == "nt":
        return WINDOWS_SKIP
    return None


def main(argv):
    root = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write("usage: python3 scripts/check_quick_start.py [--root DIR]\n")
            return 2
    if root is None:
        root = DEFAULT_ROOT
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write("quick-start: not a directory: " + root + "\n")
        return 2
    skip = windows_skip_reason(os.name)
    if skip is not None:
        print("quick-start: " + skip)
        return 0
    try:
        violations, checked = run(root)
    except Unusable as error:
        sys.stderr.write("quick-start: " + str(error) + "\n")
        return 2
    for violation in violations:
        print(violation)
    if violations:
        print("quick-start: " + str(len(violations)) + " violation(s), root=" + root)
        return 1
    print(
        "quick-start: ok ("
        + str(checked)
        + " commands checked, "
        + TRANSLATION
        + " has the same commands, root="
        + root
        + ")"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
