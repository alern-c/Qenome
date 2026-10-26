import ast
import io
import os
import subprocess
import sys
import tokenize

EXCLUDED_FILES = [
    "AGENTS.md",
    "CHANGELOG.md",
    "CLAUDE.md",
    "LICENSE",
    "NOTICE",
    "README.md",
    "README.ja.md",
    "docs/demo.gif",
    "testdata/README.md",
    "vendor/sqlite3/PROVENANCE.txt",
    "vendor/sqlite3/patches/0001-row-counts-plain.patch",
    "vendor/sqlite3/sqlite3.c",
    "vendor/sqlite3/sqlite3.h",
]

KINDS_BY_SUFFIX = {
    ".zig": "zig",
    ".zon": "zig",
    ".py": "python",
    ".sh": "hash",
    ".sql": "sql",
    ".tape": "hash",
    ".toml": "toml",
    ".jsonc": "jsonc",
    ".yml": "yaml",
    ".yaml": "yaml",
}

KINDS_BY_NAME = {
    ".gitignore": "hash",
    ".gitattributes": "hash",
}


class Comment:
    __slots__ = ("first_line", "first_column", "last_line", "last_column", "label")

    def __init__(self, first_line, first_column, last_line, last_column, label):
        self.first_line = first_line
        self.first_column = first_column
        self.last_line = last_line
        self.last_column = last_column
        self.label = label


def skip_quoted_char(line, start, quote):
    index = start + 1
    length = len(line)
    while index < length:
        char = line[index]
        if char == "\\":
            index += 2
            continue
        if char == quote:
            return index + 1
        index += 1
    return length


def scan_zig(text):
    comments = []
    for number, line in enumerate(text.split("\n"), 1):
        if line.lstrip(" \t").startswith("\\\\"):
            continue
        index = 0
        length = len(line)
        while index < length:
            char = line[index]
            if char == '"' or char == "'":
                index = skip_quoted_char(line, index, char)
                continue
            if char == "\\" and line[index + 1 : index + 2] == "\\":
                break
            if char == "/" and line[index + 1 : index + 2] == "/":
                comments.append(Comment(number, index, number, length, "a Zig line comment"))
                break
            index += 1
    return comments


def scan_python(text):
    comments = []
    tokens = tokenize.generate_tokens(io.StringIO(text).readline)
    for token in tokens:
        if token.type == tokenize.COMMENT:
            first_line, first_column = token.start
            last_line, last_column = token.end
            comments.append(
                Comment(first_line, first_column, last_line, last_column, "a Python comment")
            )
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if not isinstance(
            node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
        ):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if (
            isinstance(first, ast.Expr)
            and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)
        ):
            value = first.value
            comments.append(
                Comment(
                    value.lineno,
                    value.col_offset,
                    value.end_lineno,
                    value.end_col_offset,
                    "a Python docstring",
                )
            )
    comments.sort(key=lambda comment: (comment.first_line, comment.first_column))
    return comments


def advance(text, start, end, line, column):
    piece = text[start:end]
    newlines = piece.count("\n")
    if newlines == 0:
        return line, column + len(piece)
    return line + newlines, len(piece) - piece.rfind("\n") - 1


def sql_quoted_end(text, start, quote):
    index = start + 1
    length = len(text)
    while index < length:
        if text[index] == quote:
            if text[index + 1 : index + 2] == quote:
                index += 2
                continue
            return index + 1
        index += 1
    return length


def scan_sql(text):
    comments = []
    index = 0
    line = 1
    column = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "'" or char == '"' or char == "`":
            end = sql_quoted_end(text, index, char)
            line, column = advance(text, index, end, line, column)
            index = end
            continue
        if char == "[":
            end = text.find("]", index + 1)
            end = length if end < 0 else end + 1
            line, column = advance(text, index, end, line, column)
            index = end
            continue
        if char == "-" and text[index + 1 : index + 2] == "-":
            end = text.find("\n", index)
            end = length if end < 0 else end
            comments.append(
                Comment(line, column, line, column + (end - index), "a SQL line comment")
            )
            index = end
            continue
        if char == "/" and text[index + 1 : index + 2] == "*":
            end = text.find("*/", index + 2)
            end = length if end < 0 else end + 2
            end_line, end_column = advance(text, index, end, line, column)
            comments.append(
                Comment(line, column, end_line, end_column, "a SQL block comment")
            )
            index = end
            line, column = end_line, end_column
            continue
        if char == "\n":
            line += 1
            column = 0
            index += 1
            continue
        index += 1
        column += 1
    return comments


def scan_markers(text, markers):
    comments = []
    for number, line in enumerate(text.split("\n"), 1):
        for marker, label in markers:
            index = line.find(marker)
            while index >= 0:
                comments.append(
                    Comment(
                        number,
                        index,
                        number,
                        index + len(marker),
                        label + str(index + 1),
                    )
                )
                index = line.find(marker, index + len(marker))
    comments.sort(key=lambda comment: (comment.first_line, comment.first_column))
    return comments


def scan_yaml(text):
    return scan_markers(text, [("#", "a YAML # character at column ")])


def scan_toml(text):
    return scan_markers(text, [("#", "a TOML # character at column ")])


def scan_jsonc(text):
    return scan_markers(
        text,
        [("//", "a JSONC // at column "), ("/*", "a JSONC /* at column ")],
    )


def scan_hash_lines(text):
    comments = []
    for number, line in enumerate(text.split("\n"), 1):
        if line.startswith("#"):
            comments.append(Comment(number, 0, number, len(line), "a comment line"))
    return comments


def iter_comments(kind, text):
    if kind == "zig":
        return scan_zig(text)
    if kind == "python":
        return scan_python(text)
    if kind == "sql":
        return scan_sql(text)
    if kind == "yaml":
        return scan_yaml(text)
    if kind == "toml":
        return scan_toml(text)
    if kind == "jsonc":
        return scan_jsonc(text)
    return scan_hash_lines(text)


def classify(rel_path):
    if rel_path in EXCLUDED_FILES:
        return None, None
    name = os.path.basename(rel_path)
    kind = KINDS_BY_NAME.get(name)
    if kind is not None:
        return kind, None
    kind = KINDS_BY_SUFFIX.get(os.path.splitext(name)[1])
    if kind is None:
        return None, "neither checked nor excluded"
    return kind, None


def tracked_files(root):
    try:
        done = subprocess.run(
            ["git", "-C", root, "ls-files", "-z"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        return None, str(error)
    if done.returncode != 0:
        text = done.stderr.decode("utf-8", "replace").strip()
        return None, text or "git ls-files exited with " + str(done.returncode)
    names = done.stdout.decode("utf-8", "surrogateescape").split("\0")
    return [name for name in names if name], None


def run(root):
    violations = []
    paths, error = tracked_files(root)
    if paths is None:
        return None, 0, 0, error
    checked = 0
    excluded = 0
    for rel_path in paths:
        kind, problem = classify(rel_path)
        if problem is not None:
            violations.append((rel_path, 0, "unclassified-file", problem))
            continue
        if kind is None:
            excluded += 1
            continue
        checked += 1
        try:
            with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError) as error:
            violations.append((rel_path, 0, "unreadable-file", str(error)))
            continue
        try:
            found = iter_comments(kind, text)
        except (SyntaxError, tokenize.TokenError) as error:
            violations.append((rel_path, 0, "unreadable-python", str(error)))
            continue
        for comment in found:
            violations.append((rel_path, comment.first_line, "comment", comment.label))
    violations.sort(key=lambda violation: (violation[0], violation[1], violation[3]))
    return violations, checked, excluded, None


def main(argv):
    root = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write("usage: python3 scripts/check_comments.py [--root DIR]\n")
            return 2
    if root is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write(f"comments: not a directory: {root}\n")
        return 2
    violations, checked, excluded, error = run(root)
    if violations is None:
        sys.stderr.write(f"comments: cannot list the tracked files: {error}\n")
        return 2
    for rel_path, number, rule, reason in violations:
        print(f"{rel_path}:{number}: {rule}: {reason}")
    if violations:
        print(f"comments: {len(violations)} violation(s), root={root}")
        return 1
    print(f"comments: ok ({checked} files checked, {excluded} excluded, root={root})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
