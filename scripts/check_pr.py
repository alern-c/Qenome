import json
import re
import subprocess
import sys

HEADINGS = (
    "## 1. What was the problem",
    "## 2. What was changed",
    "## 3. What was considered",
    "## 4. Verification and conclusion",
    "## 5. Decisions or agreement needed",
    "## 6. Quality checks",
)
TYPES = ("feat", "fix", "docs", "test", "refactor", "perf", "build", "ci", "chore")
TITLE = re.compile(r"^(?:" + "|".join(TYPES) + r")(?:\([^()]+\))?!?: \S")
REVERT = re.compile(r'^Revert ".*"(?: \(#[0-9]+\))?$')
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
FENCE = re.compile(r"^(`{3,}|~{3,})")
TABLE_SEPARATOR = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")
CLOSES_PLACEHOLDER = re.compile(r"^\s*Closes #<n>\s*$")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)|<img|github\.com/user-attachments", re.I)
NO_IMAGE = re.compile(r"^\s*(?:[-*]\s+)?No image:\s*\S")
SUMMARY_LINE = re.compile(r"^<summary>.*</summary>$")
IGNORABLE_LINES = ("<details>", "</details>")
IMAGE_DIRS = ("src/", "npm/", "skills/")


class Unusable(Exception):
    pass


def code_free(body):
    kept = []
    marker = ""
    for line in body.split("\n"):
        stripped = line.lstrip()
        fence = FENCE.match(stripped)
        if marker:
            if fence and fence.group(1)[0] == marker[0] and len(fence.group(1)) >= len(marker):
                marker = ""
            continue
        if fence:
            marker = fence.group(1)
            continue
        kept.append(line)
    return "\n".join(kept)


def preprocess(body):
    text = (body or "").replace("\r\n", "\n")
    text = HTML_COMMENT.sub("", text)
    return code_free(text)


def empty_section(lines):
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped in IGNORABLE_LINES or SUMMARY_LINE.match(stripped):
            continue
        return False
    return True


def check_title(title, problems):
    if TITLE.match(title) or REVERT.match(title):
        return
    problems.append(
        'title: "'
        + title
        + '" is not "<type>(<scope>): <summary>" with a type in '
        + ", ".join(TYPES)
        + ', nor Revert "<title>"'
    )


def heading_positions(lines):
    positions = {}
    for position, line in enumerate(lines):
        if line in HEADINGS:
            positions.setdefault(line, []).append(position)
    return positions


def check_headings(positions, problems):
    for heading in HEADINGS:
        found = positions.get(heading, [])
        if not found:
            problems.append('body: the heading "' + heading + '" is missing')
        elif len(found) > 1:
            problems.append('body: the heading "' + heading + '" appears ' + str(len(found)) + " times")
    present = [heading for heading in HEADINGS if positions.get(heading)]
    first = [positions[heading][0] for heading in present]
    for position in range(1, len(first)):
        if first[position] < first[position - 1]:
            problems.append('body: the heading "' + present[position] + '" is out of order')
            break


def sections_of(lines, positions):
    sections = {}
    for heading in HEADINGS:
        found = positions.get(heading)
        if not found:
            continue
        start = found[0] + 1
        end = len(lines)
        for position in range(start, len(lines)):
            if lines[position].startswith("## "):
                end = position
                break
        sections[heading] = lines[start:end]
    return sections


def check_sections(sections, problems):
    for heading, lines in sections.items():
        if empty_section(lines):
            problems.append('body: the section "' + heading + '" is empty')


def check_tables(lines, problems):
    position = 0
    while position < len(lines):
        if not lines[position].lstrip().startswith("|"):
            position += 1
            continue
        end = position
        while end < len(lines) and lines[end].lstrip().startswith("|"):
            end += 1
        if end - position > 1 and not TABLE_SEPARATOR.match(lines[position + 1]):
            problems.append(
                'body: the table starting with "' + lines[position].strip() + '" has no separator row of --- cells'
            )
        position = end


def under_image_dirs(files):
    return [path for path in files if path.startswith(IMAGE_DIRS)]


def check_image(body, sections, files, problems):
    changed = under_image_dirs(files)
    if not changed:
        return
    if IMAGE.search(body):
        return
    for line in sections.get(HEADINGS[3], []):
        if NO_IMAGE.match(line):
            return
    problems.append(
        "body: the change to "
        + ", ".join(changed)
        + ' needs an image in the body or a "No image: <reason>" line in section 4'
    )


def check(title, body, files):
    problems: list[str] = []
    check_title((title or "").strip(), problems)
    text = preprocess(body)
    lines = [line.rstrip() for line in text.split("\n")]
    positions = heading_positions(lines)
    check_headings(positions, problems)
    sections = sections_of(lines, positions)
    check_sections(sections, problems)
    if any(CLOSES_PLACEHOLDER.match(line) for line in lines):
        problems.append('body: the template placeholder "Closes #<n>" is left in the body')
    check_tables(lines, problems)
    check_image(text, sections, files, problems)
    return problems


def one_line(text):
    return " ".join(text.split())


def read_event(path):
    try:
        with open(path, encoding="utf-8") as handle:
            event = json.load(handle)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise Unusable("cannot read the event JSON " + path + ": " + str(error)) from None
    pull = event.get("pull_request") if isinstance(event, dict) else None
    if not isinstance(pull, dict):
        raise Unusable("the event JSON " + path + " has no pull_request object")
    return pull.get("title") or "", pull.get("body")


def changed_files():
    try:
        done = subprocess.run(
            ["git", "diff", "--name-only", "HEAD^1", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        raise Unusable("cannot run git: " + str(error)) from None
    if done.returncode != 0:
        detail = one_line(done.stderr) or "exit " + str(done.returncode)
        raise Unusable("cannot list the changed files with git diff HEAD^1 HEAD: " + detail)
    return [line for line in done.stdout.splitlines() if line]


def main(argv):
    path = None
    rest = argv[1:]
    if len(rest) == 2 and rest[0] == "--event":
        path = rest[1]
    if path is None:
        sys.stderr.write("usage: python3 scripts/check_pr.py --event PATH\n")
        return 2
    try:
        title, body = read_event(path)
        files = changed_files()
    except Unusable as error:
        sys.stderr.write("pr-format: " + str(error) + "\n")
        return 2
    problems = check(title, body, files)
    for problem in problems:
        print(problem)
    if problems:
        print("pr-format: " + str(len(problems)) + " problem(s)")
        return 1
    print("pr-format: ok (" + str(len(files)) + " changed files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
