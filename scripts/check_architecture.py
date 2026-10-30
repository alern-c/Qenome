import os
import re
import sys

APPROVED_FILES = [
    "src/sqlite.zig",
    "src/result.zig",
    "src/db.zig",
    "src/root.zig",
    "src/main.zig",
    "src/cli.zig",
    "src/cli/args.zig",
    "src/cli/control.zig",
    "src/cli/d1.zig",
    "src/cli/comparison.zig",
    "src/cli/query.zig",
    "src/cli/workspace.zig",
    "src/cli/timing.zig",
    "src/cli/report.zig",
    "src/cli/pair.zig",
    "src/cli/batch.zig",
    "src/cli/audit.zig",
    "src/cli/record.zig",
    "src/cli/suggest.zig",
    "src/cli/seed.zig",
    "src/cli/tests.zig",
    "src/contract/values.zig",
    "src/sql/lexer.zig",
]

PRODUCTION_FILES = [path for path in APPROVED_FILES if path != "src/cli/tests.zig"]

PRODUCTION_IMPORTS = {
    "src/sqlite.zig": [],
    "src/result.zig": ["src/sqlite.zig"],
    "src/db.zig": ["src/sqlite.zig", "src/result.zig", "src/sql/lexer.zig"],
    "src/root.zig": [
        "src/sqlite.zig",
        "src/db.zig",
        "src/result.zig",
        "src/cli.zig",
        "src/contract/values.zig",
        "src/sql/lexer.zig",
    ],
    "src/main.zig": [],
    "src/cli.zig": [
        "src/db.zig",
        "src/result.zig",
        "src/cli/args.zig",
        "src/cli/d1.zig",
        "src/cli/control.zig",
        "src/cli/comparison.zig",
        "src/cli/query.zig",
        "src/cli/workspace.zig",
        "src/cli/timing.zig",
        "src/cli/report.zig",
        "src/cli/pair.zig",
        "src/cli/batch.zig",
        "src/cli/audit.zig",
        "src/cli/record.zig",
        "src/cli/seed.zig",
    ],
    "src/cli/args.zig": ["src/db.zig", "src/sql/lexer.zig"],
    "src/cli/control.zig": ["src/contract/values.zig"],
    "src/cli/d1.zig": [],
    "src/cli/comparison.zig": ["src/db.zig", "src/result.zig"],
    "src/cli/query.zig": [
        "src/db.zig",
        "src/sqlite.zig",
        "src/result.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
    ],
    "src/cli/workspace.zig": [
        "src/db.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/query.zig",
        "src/cli/seed.zig",
    ],
    "src/cli/timing.zig": [
        "src/db.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/query.zig",
    ],
    "src/cli/report.zig": [
        "src/result.zig",
        "src/contract/values.zig",
        "src/cli/args.zig",
        "src/cli/d1.zig",
        "src/cli/comparison.zig",
        "src/cli/timing.zig",
    ],
    "src/cli/pair.zig": [
        "src/db.zig",
        "src/sqlite.zig",
        "src/result.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/d1.zig",
        "src/cli/query.zig",
        "src/cli/report.zig",
        "src/cli/timing.zig",
        "src/cli/workspace.zig",
    ],
    "src/cli/audit.zig": [
        "src/db.zig",
        "src/contract/values.zig",
        "src/sql/lexer.zig",
        "src/result.zig",
        "src/cli/args.zig",
        "src/cli/batch.zig",
        "src/cli/control.zig",
        "src/cli/query.zig",
        "src/cli/report.zig",
    ],
    "src/cli/batch.zig": [
        "src/db.zig",
        "src/contract/values.zig",
        "src/result.zig",
        "src/sqlite.zig",
        "src/cli/args.zig",
        "src/cli/comparison.zig",
        "src/cli/control.zig",
        "src/cli/d1.zig",
        "src/cli/pair.zig",
        "src/cli/query.zig",
        "src/cli/report.zig",
        "src/cli/suggest.zig",
        "src/cli/workspace.zig",
    ],
    "src/cli/suggest.zig": [
        "src/db.zig",
        "src/sqlite.zig",
        "src/contract/values.zig",
        "src/sql/lexer.zig",
    ],
    "src/cli/record.zig": [
        "src/cli/args.zig",
        "src/cli/control.zig",
        "src/sql/lexer.zig",
    ],
    "src/cli/seed.zig": [
        "src/sqlite.zig",
        "src/cli/control.zig",
    ],
    "src/contract/values.zig": [],
    "src/sql/lexer.zig": [],
}

TEST_ENTRY_IMPORTER = "src/cli.zig"
TEST_ENTRY_TARGET = "src/cli/tests.zig"
TEST_ENTRY_PATH_TEXT = "cli/tests.zig"
TEST_IMPORTS = {
    "src/cli/tests.zig": [
        "src/cli.zig",
        "src/db.zig",
        "src/result.zig",
        "src/sqlite.zig",
        "src/cli/args.zig",
        "src/cli/d1.zig",
        "src/cli/control.zig",
        "src/cli/comparison.zig",
        "src/cli/query.zig",
        "src/cli/workspace.zig",
        "src/cli/timing.zig",
        "src/cli/report.zig",
        "src/cli/pair.zig",
        "src/cli/batch.zig",
        "src/cli/audit.zig",
        "src/cli/suggest.zig",
        "src/cli/seed.zig",
        "src/cli/record.zig",
    ],
}

BUILTIN_IMPORTS = ["std", "builtin"]

MODULE_IMPORTS = {
    "src/main.zig": ["Qenome"],
    "src/cli/args.zig": ["build_options"],
}

LAYERS = [
    ("src/contract/", "contract"),
    ("src/sql/", "sql"),
    ("src/sqlite.zig", "sqlite"),
    ("src/db.zig", "engine"),
    ("src/result.zig", "engine"),
    ("src/cli/", "cli"),
    ("src/cli.zig", "cli"),
    ("src/root.zig", "main"),
    ("src/main.zig", "main"),
]

LAYER_RANK = {
    "contract": 0,
    "sqlite": 1,
    "sql": 2,
    "engine": 3,
    "measure": 4,
    "verdict": 5,
    "sandbox": 6,
    "modes": 7,
    "report": 8,
    "cli": 9,
    "main": 10,
}

LINE_LIMITS = {
    "src/cli/tests.zig": 5744,
    "src/db.zig": 4055,
    "src/cli/report.zig": 2370,
    "src/cli/batch.zig": 1902,
    "src/cli/args.zig": 1780,
    "src/cli/d1.zig": 1034,
    "src/cli/seed.zig": 977,
    "src/cli/suggest.zig": 831,
    "src/cli/record.zig": 827,
}

MAX_LINES = 800

WRITE_ALLOWED = ["src/cli.zig", "src/cli/report.zig", "src/main.zig"]

WRITE_DEBT = [
    "src/cli/audit.zig",
    "src/cli/batch.zig",
    "src/cli/control.zig",
    "src/cli/pair.zig",
    "src/cli/query.zig",
    "src/cli/record.zig",
    "src/cli/seed.zig",
    "src/cli/timing.zig",
    "src/cli/workspace.zig",
]

CONTRACT_PREFIX = "src/contract/"

CONTRACT_VALUES = [
    "schema_version",
    "batch_schema_version",
    "audit_schema_version",
    "warning_codes",
    "warning_messages",
    "bind_dependent_partial_index_message",
]

CONTRACT_ALIASES = ["ExitCode"]

CONTRACT_CODES = [
    "no_analyze_stats",
    "data_too_small",
    "bind_dependent_partial_index",
    "suggest_query_skipped",
    "suggestions_truncated",
    "suggestion_rejected",
    "suggest_failed",
    "no_suggestions",
]

IMPORT_CANDIDATE = re.compile(r"@import\b")
DECL_IMPORT = re.compile(r'^(?:pub )?const [A-Za-z_][A-Za-z0-9_]* = @import\("([^"\\]*)"\);\s*$')
ENTRY_IMPORT = re.compile(r'^\s*_ = @import\("([^"\\]*)"\);\s*$')
TEST_BLOCK_START = re.compile(r"^test \{\s*$")
TEST_BODY_START = re.compile(r"^test\b.*\{\s*$")
COMMENT_OR_BLANK = re.compile(r"^\s*(//.*)?$")
WRITE_CALL = re.compile(r"\b(stdout|stderr)\.[A-Za-z_][A-Za-z0-9_]*\(")
DECLARATION = re.compile(r"^(?:pub )?(?:const|var) ([A-Za-z_][A-Za-z0-9_]*)")
ALIAS_DECLARATION = re.compile(
    r"^(?:pub )?const ([A-Za-z_][A-Za-z0-9_]*) = [A-Za-z_][A-Za-z0-9_]*\.([A-Za-z_][A-Za-z0-9_]*);\s*$"
)
CONTRACT_CODE_TEXT = re.compile(r'"(' + "|".join(CONTRACT_CODES) + r')"')

class Source:

    def __init__(self, path, lines):
        self.path = path
        self.lines = lines
        self.imports = []
        self.test_blocks = []
        self.test_bodies = []

def read_source(root, rel_path):
    try:
        with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
            return Source(rel_path, handle.read().split("\n")), None
    except (OSError, UnicodeDecodeError) as error:
        return None, str(error)

def parse(source, violations):
    for index, line in enumerate(source.lines):
        number = index + 1
        if not IMPORT_CANDIDATE.search(line):
            continue
        decl = DECL_IMPORT.match(line)
        if decl:
            source.imports.append((number, decl.group(1), "decl"))
            continue
        entry = ENTRY_IMPORT.match(line)
        if entry:
            source.imports.append((number, entry.group(1), "entry"))
            continue
        violations.append(
            (source.path, number, "import-form", "unsupported @import form: " + line.strip()[:72])
        )
    depth = 0
    start = None
    for index, line in enumerate(source.lines):
        if start is None:
            if TEST_BLOCK_START.match(line):
                start = index
                depth = 1
            continue
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            source.test_blocks.append((start + 1, index + 1))
            start = None
    depth = 0
    start = None
    for index, line in enumerate(source.lines):
        if start is None:
            if TEST_BODY_START.match(line):
                start = index
                depth = 1
            continue
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            source.test_bodies.append((start + 1, index + 1))
            start = None

def inside(spans, number):
    return any(first <= number <= last for first, last in spans)

def resolve(importer, path_text):
    resolved = os.path.normpath(
        os.path.join(os.path.dirname(importer), path_text.replace("/", os.sep))
    )
    if resolved.startswith("..") or os.path.isabs(resolved):
        return None
    return resolved.replace(os.sep, "/")

def check_directory(root, rel_dir, violations):
    directory = os.path.join(root, rel_dir.replace("/", os.sep))
    try:
        names = sorted(os.listdir(directory))
    except OSError as error:
        if os.path.exists(directory):
            violations.append(
                (rel_dir, 0, "unreadable-directory", f"could not list {rel_dir}: {error}")
            )
        return
    for name in names:
        if not name.endswith(".zig"):
            continue
        rel_path = rel_dir + "/" + name
        if rel_path not in APPROVED_FILES:
            violations.append(
                (
                    rel_path,
                    0,
                    "unknown-file",
                    f"a file under {rel_dir}/ that the rules do not know",
                )
            )

def check_files(root, sources, violations):
    for rel_path in APPROVED_FILES:
        if rel_path not in sources:
            violations.append((rel_path, 0, "missing-file", "the approved file is missing"))
    check_directory(root, "src", violations)
    check_directory(root, "src/cli", violations)
    check_directory(root, "src/contract", violations)
    check_directory(root, "src/sql", violations)

def layer_of(rel_path):
    for prefix, layer in LAYERS:
        if rel_path == prefix or rel_path.startswith(prefix):
            return layer
    return None

def check_layers(sources, violations):
    for rel_path, source in sorted(sources.items()):
        layer = layer_of(rel_path)
        if layer is None:
            violations.append(
                (rel_path, 0, "unknown-layer", "the rules do not place this file in a layer")
            )
            continue
        modules = MODULE_IMPORTS.get(rel_path, [])
        for number, path_text, _form in source.imports:
            if path_text in BUILTIN_IMPORTS or path_text in modules:
                continue
            resolved = resolve(rel_path, path_text)
            if resolved is None:
                continue
            target = layer_of(resolved)
            if target is None:
                continue
            if LAYER_RANK[target] > LAYER_RANK[layer]:
                violations.append(
                    (
                        rel_path,
                        number,
                        "layer-order",
                        f"the {layer} layer may not import the {target} layer: {resolved}",
                    )
                )

def count_lines(lines):
    if lines and lines[-1] == "":
        return len(lines) - 1
    return len(lines)

def check_sizes(sources, violations):
    for rel_path, source in sorted(sources.items()):
        limit = LINE_LIMITS.get(rel_path, MAX_LINES)
        lines = count_lines(source.lines)
        if lines > limit:
            violations.append(
                (
                    rel_path,
                    0,
                    "file-size",
                    f"{lines} lines is more than the limit of {limit}; split the file instead",
                )
            )

def check_writes(sources, violations):
    allowed = WRITE_ALLOWED + WRITE_DEBT
    for rel_path in PRODUCTION_FILES:
        source = sources.get(rel_path)
        if source is None or rel_path in allowed:
            continue
        for number, line in enumerate(source.lines, 1):
            if inside(source.test_bodies, number):
                continue
            if WRITE_CALL.search(line):
                violations.append(
                    (
                        rel_path,
                        number,
                        "stdout-write",
                        "only report/ and cli/ write to stdout or stderr: " + line.strip()[:72],
                    )
                )

def check_contract(sources, violations):
    contract = sources.get("src/contract/values.zig")
    if contract is not None:
        for name in CONTRACT_VALUES + CONTRACT_ALIASES:
            found = False
            for line in contract.lines:
                declaration = DECLARATION.match(line)
                if declaration is not None and declaration.group(1) == name:
                    found = True
                    break
            if not found:
                violations.append(
                    (
                        contract.path,
                        0,
                        "missing-contract",
                        f"the contract does not define {name}",
                    )
                )
    for rel_path in PRODUCTION_FILES:
        source = sources.get(rel_path)
        if source is None or rel_path.startswith(CONTRACT_PREFIX):
            continue
        for number, line in enumerate(source.lines, 1):
            if inside(source.test_bodies, number):
                continue
            declaration = DECLARATION.match(line)
            if declaration is not None:
                name = declaration.group(1)
                if name in CONTRACT_VALUES:
                    violations.append(
                        (
                            rel_path,
                            number,
                            "contract-value",
                            f"{name} is defined in the contract, not here",
                        )
                    )
                if name in CONTRACT_ALIASES:
                    alias = ALIAS_DECLARATION.match(line)
                    if alias is None or alias.group(1) != name or alias.group(2) != name:
                        violations.append(
                            (
                                rel_path,
                                number,
                                "contract-value",
                                f"{name} is defined in the contract; only an alias may stay",
                            )
                        )
            found = CONTRACT_CODE_TEXT.search(line)
            if found is not None:
                violations.append(
                    (
                        rel_path,
                        number,
                        "contract-code",
                        f"{found.group(1)} is defined in the contract, not here",
                    )
                )

def check_imports(sources, violations):
    for rel_path, source in sorted(sources.items()):
        table = PRODUCTION_IMPORTS.get(rel_path)
        if table is None:
            table = TEST_IMPORTS.get(rel_path)
        if table is None:
            continue
        modules = MODULE_IMPORTS.get(rel_path, [])
        for number, path_text, _form in source.imports:
            if path_text in BUILTIN_IMPORTS or path_text in modules:
                continue
            resolved = resolve(rel_path, path_text)
            if resolved is None:
                violations.append(
                    (
                        rel_path,
                        number,
                        "outside-root",
                        f'@import("{path_text}") leaves the repository',
                    )
                )
                continue
            if resolved == TEST_ENTRY_TARGET:
                continue
            if resolved not in table:
                violations.append(
                    (
                        rel_path,
                        number,
                        "unapproved-import",
                        f"{rel_path} may not import {resolved}",
                    )
                )

def check_test_entry(sources, violations):
    importers = []
    for rel_path, source in sorted(sources.items()):
        for number, path_text, form in source.imports:
            if resolve(rel_path, path_text) == TEST_ENTRY_TARGET:
                importers.append((rel_path, number, path_text, form))
    if len(importers) != 1:
        violations.append(
            (
                TEST_ENTRY_IMPORTER,
                0,
                "test-entry",
                f"expected exactly one import of {TEST_ENTRY_TARGET}, found {len(importers)}",
            )
        )
        return
    rel_path, number, path_text, form = importers[0]
    if rel_path != TEST_ENTRY_IMPORTER or form != "entry" or path_text != TEST_ENTRY_PATH_TEXT:
        violations.append(
            (
                rel_path,
                number,
                "test-entry",
                f'only {TEST_ENTRY_IMPORTER}\'s test block may import {TEST_ENTRY_TARGET} '
                f'as _ = @import("{TEST_ENTRY_PATH_TEXT}");',
            )
        )
        return
    source = sources[rel_path]
    block = None
    for first, last in source.test_blocks:
        if first <= number <= last:
            block = (first, last)
            break
    if block is None:
        violations.append((rel_path, number, "test-entry", "the test entry is outside a test block"))
        return
    for line_number in range(block[0] + 1, block[1]):
        line = source.lines[line_number - 1]
        if COMMENT_OR_BLANK.match(line):
            continue
        if line_number == number:
            continue
        violations.append(
            (
                rel_path,
                line_number,
                "test-entry",
                "the test entry block holds more than the one import: " + line.strip()[:72],
            )
        )

def check_cycles(sources, violations):
    graph = {}
    for rel_path in PRODUCTION_FILES:
        edges = []
        source = sources.get(rel_path)
        if source is None:
            continue
        for _number, path_text, _form in source.imports:
            if path_text in BUILTIN_IMPORTS:
                continue
            resolved = resolve(rel_path, path_text)
            if resolved in PRODUCTION_FILES:
                edges.append(resolved)
        graph[rel_path] = edges

    state = {}
    stack = []

    def walk(node):
        state[node] = 1
        stack.append(node)
        for neighbour in graph.get(node, []):
            if state.get(neighbour, 0) == 1:
                cycle = stack[stack.index(neighbour):] + [neighbour]
                violations.append(
                    (neighbour, 0, "cycle", "the production dependency cycle: " + " -> ".join(cycle))
                )
                return True
            if state.get(neighbour, 0) == 0 and walk(neighbour):
                return True
        stack.pop()
        state[node] = 2
        return False

    for node in PRODUCTION_FILES:
        if state.get(node, 0) == 0 and walk(node):
            return

def run(root):
    violations = []
    sources = {}
    for rel_path in APPROVED_FILES:
        if not os.path.isfile(os.path.join(root, rel_path)):
            continue
        source, error = read_source(root, rel_path)
        if error is not None:
            violations.append(
                (rel_path, 0, "unreadable-file", f"could not read the file: {error}")
            )
            continue
        sources[rel_path] = source
    check_files(root, sources, violations)
    for source in sources.values():
        parse(source, violations)
    check_imports(sources, violations)
    check_layers(sources, violations)
    check_sizes(sources, violations)
    check_writes(sources, violations)
    check_contract(sources, violations)
    check_test_entry(sources, violations)
    check_cycles(sources, violations)
    return violations

def main(argv):
    root = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write("usage: python3 scripts/check_architecture.py [--root DIR]\n")
            return 2
    if root is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write(f"architecture: not a directory: {root}\n")
        return 2
    violations = run(root)
    for rel_path, number, rule, reason in violations:
        print(f"{rel_path}:{number}: {rule}: {reason}")
    if violations:
        print(f"architecture: {len(violations)} violation(s), root={root}")
        return 1
    print(f"architecture: ok ({len(APPROVED_FILES)} files checked, root={root})")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
