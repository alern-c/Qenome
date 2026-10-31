import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))

README_FILES = ("README.md", "README.ja.md")
README_MAX_LINES = 100
AGENTS_FILE = "AGENTS.md"
AGENTS_MAX_LINES = 60
README_HEADING_LEVELS = (1, 2, 2, 2, 2, 2)
AGENTS_MAX_HEADING_LEVEL = 2
CONTENTS_HEADINGS = {"README.md": "Contents", "README.ja.md": "目次"}
LANGUAGE_TREES = {"README.md": "docs/", "README.ja.md": "docs/ja/"}
FIXED_FILES = (
    "README.md",
    "README.ja.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "skills/qenome/SKILL.md",
)
PAGE_PAIRS = (
    "installation",
    "local-d1",
    "bill-spiked",
    "agents",
    "why-not",
    "usage",
    "batch",
    "output",
    "accuracy",
    "rules",
)
UNPAIRED_DOCS = ("docs/architecture.md", "docs/json.md", "docs/npm.md")

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE = re.compile(r"^\s*```")
IMAGE = re.compile(r"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_TARGET = re.compile(r"(?:href|src)=\"([^\"]+)\"")
HTML_TAG = re.compile(r"<[^>]+>")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


class Unusable(Exception):
    pass


def read_text(root, rel_path):
    path = os.path.join(root, rel_path)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise Unusable("cannot read " + rel_path + ": " + str(error)) from None


def strip_markdown(text):
    text = HTML_TAG.sub("", text)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return text.replace("`", "")


def slug(text):
    text = strip_markdown(text).strip().lower()
    kept = []
    for char in text:
        if char in " -_" or char.isalnum() or unicodedata.category(char).startswith("M"):
            kept.append(char)
    return "".join(kept).replace(" ", "-")


def fenced_lines(text):
    lines = text.split("\n")
    inside = False
    for line in lines:
        if FENCE.match(line):
            inside = not inside
            yield line, True
            continue
        yield line, inside


def headings(text):
    found = []
    for line, inside in fenced_lines(text):
        if inside:
            continue
        match = HEADING.match(line)
        if match:
            found.append((len(match.group(1)), match.group(2)))
    return found


def heading_levels(text):
    return tuple(level for level, _ in headings(text))


def anchors(text):
    seen = {}
    result = set()
    for _, title in headings(text):
        base = slug(title)
        count = seen.get(base, 0)
        seen[base] = count + 1
        result.add(base if count == 0 else base + "-" + str(count))
    return result


def inline_code_spans(line):
    spans = []
    index = 0
    while index < len(line):
        if line[index] == "`":
            end = index
            while end < len(line) and line[end] == "`":
                end += 1
            marker = line[index:end]
            close = line.find(marker, end)
            if close == -1:
                break
            spans.append((index, close + len(marker)))
            index = close + len(marker)
            continue
        index += 1
    return spans


def in_spans(position, spans):
    return any(start <= position < end for start, end in spans)


def link_targets(line):
    spans = inline_code_spans(line)
    targets = []
    for match in IMAGE.finditer(line):
        if not in_spans(match.start(), spans):
            targets.append((match.start(), match.group(2)))
    for match in LINK.finditer(line):
        if not in_spans(match.start(), spans):
            targets.append((match.start(), match.group(2)))
    for match in HTML_TARGET.finditer(line):
        if not in_spans(match.start(), spans):
            targets.append((match.start(), match.group(1)))
    return targets


def resolve(root, source, target):
    path = target.split("#", 1)[0]
    path = path.split("?", 1)[0]
    if not path:
        return source
    joined = os.path.normpath(os.path.join(os.path.dirname(source), path))
    if joined.startswith("..") or os.path.isabs(joined):
        return None
    return joined


def check_target(root, source, line_number, target, violations, anchor_cache):
    if SCHEME.match(target) or target.startswith("//"):
        return
    if target.startswith("#"):
        path = source
        anchor = target[1:]
    else:
        path = resolve(root, source, target)
        if path is None:
            violations.append(source + ":" + str(line_number) + ": link escapes the repository: " + target)
            return
        anchor = target.split("#", 1)[1] if "#" in target else ""
    if not os.path.exists(os.path.join(root, path)):
        violations.append(source + ":" + str(line_number) + ": link target does not exist: " + target)
        return
    if not anchor or not path.endswith(".md"):
        return
    if path not in anchor_cache:
        anchor_cache[path] = anchors(read_text(root, path))
    if anchor not in anchor_cache[path]:
        violations.append(source + ":" + str(line_number) + ": anchor does not exist: " + target)


def add_link_violations(root, rel_path, text, violations, anchor_cache):
    for number, (line, inside) in enumerate(fenced_lines(text), 1):
        if inside:
            continue
        for _, target in link_targets(line):
            check_target(root, rel_path, number, target, violations, anchor_cache)


def section(text, wanted):
    lines = text.split("\n")
    start = None
    wanted = wanted.strip().lower()
    for index, line in enumerate(lines):
        match = HEADING.match(line)
        if match and len(match.group(1)) == 2 and match.group(2).strip().lower() == wanted:
            start = index + 1
            continue
        if start is not None and match and len(match.group(1)) <= 2:
            return "\n".join(lines[start:index])
    if start is None:
        return None
    return "\n".join(lines[start:])


def contents_links(text, heading):
    body = section(text, heading)
    if body is None:
        return None
    found = []
    for match in LINK.finditer(body):
        found.append(match.group(2))
    return found


def in_other_tree(rel_path, path):
    if not path.startswith("docs/"):
        return False
    if rel_path == "README.md":
        return path.startswith("docs/ja/")
    return not path.startswith("docs/ja/")


def check_readme(root, rel_path, violations):
    text = read_text(root, rel_path)
    line_count = len(text.splitlines())
    if line_count > README_MAX_LINES:
        violations.append(rel_path + ": " + str(line_count) + " lines, over the cap of " + str(README_MAX_LINES))
    levels = heading_levels(text)
    if levels != README_HEADING_LEVELS:
        violations.append(rel_path + ": headings " + str(levels) + " do not match " + str(README_HEADING_LEVELS))
    links = contents_links(text, CONTENTS_HEADINGS[rel_path])
    if links is None:
        violations.append(rel_path + ": no ## " + CONTENTS_HEADINGS[rel_path] + " section")
        return
    language_tree = LANGUAGE_TREES[rel_path]
    for target in links:
        path = target.split("#", 1)[0]
        if in_other_tree(rel_path, path):
            violations.append(rel_path + ": the contents link to the other language: " + target)
    for name in PAGE_PAIRS:
        expected = language_tree + name + ".md"
        if expected not in links:
            violations.append(rel_path + ": the contents do not link to " + expected)


def check_agents(root, violations):
    text = read_text(root, AGENTS_FILE)
    line_count = len(text.splitlines())
    if line_count > AGENTS_MAX_LINES:
        violations.append(AGENTS_FILE + ": " + str(line_count) + " lines, over the cap of " + str(AGENTS_MAX_LINES))
    for level, title in headings(text):
        if level > AGENTS_MAX_HEADING_LEVEL:
            violations.append(AGENTS_FILE + ": heading is too deep for an index: " + title)


def list_markdown(directory):
    try:
        return sorted(name for name in os.listdir(directory) if name.endswith(".md"))
    except OSError as error:
        raise Unusable("cannot list " + directory + ": " + str(error)) from None


def check_pages(root, violations):
    for path in UNPAIRED_DOCS:
        if not os.path.isfile(os.path.join(root, path)):
            violations.append(path + ": listed developer page does not exist")
    paired = set()
    for name in PAGE_PAIRS:
        english = "docs/" + name + ".md"
        japanese = "docs/ja/" + name + ".md"
        paired.add(english)
        paired.add(japanese)
        for path in (english, japanese):
            if not os.path.isfile(os.path.join(root, path)):
                violations.append(path + ": page does not exist")
    docs_dir = os.path.join(root, "docs")
    if not os.path.isdir(docs_dir):
        return
    for name in list_markdown(docs_dir):
        path = "docs/" + name
        if path not in paired and path not in UNPAIRED_DOCS:
            violations.append(path + ": neither a paired page nor a listed developer page")
    ja_dir = os.path.join(docs_dir, "ja")
    if not os.path.isdir(ja_dir):
        return
    for name in list_markdown(ja_dir):
        path = "docs/ja/" + name
        if path not in paired:
            violations.append(path + ": a docs/ja page without a listed English pair")


def check_pairs(root, violations):
    for name in PAGE_PAIRS:
        english = "docs/" + name + ".md"
        japanese = "docs/ja/" + name + ".md"
        if not os.path.isfile(os.path.join(root, english)) or not os.path.isfile(os.path.join(root, japanese)):
            continue
        english_levels = heading_levels(read_text(root, english))
        japanese_levels = heading_levels(read_text(root, japanese))
        if english_levels != japanese_levels:
            violations.append(
                english
                + " and "
                + japanese
                + ": heading levels differ: "
                + str(english_levels)
                + " != "
                + str(japanese_levels)
            )


def checked_files(root):
    files: list[str] = list(FIXED_FILES)
    docs_dir = os.path.join(root, "docs")
    for directory in (docs_dir, os.path.join(docs_dir, "ja")):
        if not os.path.isdir(directory):
            continue
        for name in list_markdown(directory):
            path = os.path.relpath(os.path.join(directory, name), root)
            if path not in files:
                files.append(path)
    return files


def run(root):
    violations = []
    anchor_cache = {}
    for rel_path in FIXED_FILES:
        if not os.path.isfile(os.path.join(root, rel_path)):
            violations.append(rel_path + ": file does not exist")
    for rel_path in README_FILES:
        if os.path.isfile(os.path.join(root, rel_path)):
            check_readme(root, rel_path, violations)
    if os.path.isfile(os.path.join(root, AGENTS_FILE)):
        check_agents(root, violations)
    check_pages(root, violations)
    check_pairs(root, violations)
    for rel_path in checked_files(root):
        if not os.path.isfile(os.path.join(root, rel_path)):
            continue
        add_link_violations(root, rel_path, read_text(root, rel_path), violations, anchor_cache)
    return violations, len(checked_files(root))


def main(argv):
    root = None
    rest = argv[1:]
    if rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
        else:
            sys.stderr.write("usage: python3 scripts/check_docs.py [--root DIR]\n")
            return 1
    if root is None:
        root = os.path.dirname(HERE)
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write("docs: not a directory: " + root + "\n")
        return 1
    try:
        violations, checked = run(root)
    except Unusable as error:
        sys.stderr.write("docs: " + str(error) + "\n")
        return 1
    if violations:
        for violation in violations:
            print("docs: " + violation)
        print("docs: " + str(len(violations)) + " violation(s), root=" + root)
        return 1
    print("docs: ok (" + str(checked) + " files checked, " + str(len(PAGE_PAIRS)) + " page pairs, root=" + root + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
