import argparse
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCH = os.path.join(ROOT, "vendor", "sqlite3", "patches", "0001-row-counts-plain.patch")
PATCH_SHA256 = "ffafcb374b0f433964fec75d79cb5e690aa3fbe8c0df3d0a9413001deda3951c"
PRISTINE_SHA3_256 = {
    "sqlite3.c": "67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16",
    "sqlite3.h": "89d0de498b1012938bb78dc18b68fea52e26f7f7b6db6347d126a2e58b86a05c",
}
TARGETS = {
    "sqlite-src-pristine/src/vdbe.c": ("sqlite3.c",),
    "sqlite-src-pristine/src/vdbeInt.h": ("sqlite3.c",),
    "sqlite-src-pristine/src/vdbeapi.c": ("sqlite3.c",),
    "sqlite-src-pristine/src/sqlite.h.in": ("sqlite3.c", "sqlite3.h"),
}
SKIPPED = {
    "sqlite-src-pristine/src/shell.c.in": ("the shell is not vendored; it is not part of the build"),
}
DECORATED = {
    "int sqlite3_stmt_status(sqlite3_stmt *pStmt, int op, int resetFlag){": (
        "SQLITE_API int sqlite3_stmt_status(sqlite3_stmt *pStmt, int op, int resetFlag){"
    ),
}
SECTION = re.compile(r"^diff -u5 -r (\S+) (\S+)$")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class Failure(Exception):
    pass


def read_bytes(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as error:
        raise Failure("cannot read " + path + ": " + str(error)) from None


def digest(name, data):
    return hashlib.new(name, data).hexdigest()


def sections(text, patch_path):
    found = []
    for part in re.split(r"(?m)^(?=diff -u5 -r )", text):
        if not part.strip():
            continue
        lines = part.split("\n")
        header = SECTION.match(lines[0])
        if header is None:
            raise Failure(patch_path + ": cannot read the file header: " + lines[0])
        hunks = []
        current = None
        for number, line in enumerate(lines[1:], 2):
            if line.startswith("--- ") or line.startswith("+++ "):
                continue
            header_at = HUNK.match(line)
            if header_at is not None:
                current = {"at": int(header_at.group(1)), "lines": []}
                hunks.append(current)
                continue
            if line == "":
                continue
            if current is None:
                raise Failure(patch_path + ": line " + str(number) + " is outside a hunk")
            if line[0] not in " -+":
                raise Failure(patch_path + ": line " + str(number) + " has no patch prefix")
            current["lines"].append(line)
        found.append({"source": header.group(1), "hunks": hunks})
    return found


def old_block(hunk):
    return [line[1:] for line in hunk["lines"] if line[0] in " -"]


def accepted(actual, expected):
    return actual == expected or actual == DECORATED.get(expected)


def locate(lines, hunk, name):
    block = old_block(hunk)
    if not block:
        raise Failure(name + ": the hunk at source line " + str(hunk["at"]) + " has no context")
    places = []
    for start in range(len(lines) - len(block) + 1):
        if all(accepted(lines[start + offset], block[offset]) for offset in range(len(block))):
            places.append(start)
    if not places:
        raise Failure(
            name
            + ": the hunk at source line "
            + str(hunk["at"])
            + " does not match, so the patch cannot be applied without changing it"
        )
    if len(places) > 1:
        raise Failure(
            name
            + ": the hunk at source line "
            + str(hunk["at"])
            + " matches at "
            + ", ".join(str(place + 1) for place in places)
            + ", so the target line is ambiguous"
        )
    return places[0]


def applied_block(actual, hunk):
    result = []
    index = 0
    for line in hunk["lines"]:
        if line[0] == " ":
            result.append(actual[index])
            index += 1
        elif line[0] == "-":
            index += 1
        else:
            result.append(line[1:])
    return result


def apply_hunks(lines, hunks, name):
    placement = []
    for hunk in hunks:
        placement.append((locate(lines, hunk, name), hunk))
    placement.sort(key=lambda entry: entry[0])
    output = []
    position = 0
    for start, hunk in placement:
        if start < position:
            raise Failure(name + ": the hunks at source lines overlap")
        output.extend(lines[position:start])
        count = len(old_block(hunk))
        output.extend(applied_block(lines[start : start + count], hunk))
        position = start + count
    output.extend(lines[position:])
    return output


def build(source_dir, patch_path):
    patch_bytes = read_bytes(patch_path)
    patch_digest = digest("sha256", patch_bytes)
    if patch_digest != PATCH_SHA256:
        raise Failure(
            patch_path
            + ": SHA-256 is "
            + patch_digest
            + ", expected "
            + PATCH_SHA256
            + "; the patch must stay as it was fetched"
        )
    text = patch_bytes.decode("utf-8", "surrogateescape")
    per_target = {}
    skipped = []
    for section in sections(text, patch_path):
        if section["source"] in SKIPPED:
            skipped.append(section)
            continue
        names = TARGETS.get(section["source"])
        if names is None:
            raise Failure(patch_path + ": no target is known for " + section["source"])
        for name in names:
            per_target.setdefault(name, []).extend(section["hunks"])
    files = {}
    for name in sorted(per_target):
        path = os.path.join(source_dir, name)
        data = read_bytes(path)
        pristine = digest("sha3_256", data)
        if pristine != PRISTINE_SHA3_256[name]:
            raise Failure(
                path
                + ": SHA3-256 is "
                + pristine
                + ", expected "
                + PRISTINE_SHA3_256[name]
                + " (SQLite 3.53.4 as published by sqlite.org; the patch is already applied,"
                + " or the file is another release)"
            )
        lines = data.decode("utf-8", "surrogateescape").split("\n")
        files[name] = "\n".join(apply_hunks(lines, per_target[name], name)).encode("utf-8", "surrogateescape")
    return files, skipped


def main(argv):
    parser = argparse.ArgumentParser(
        description="Apply the workerd row-count patches to the SQLite 3.53.4 amalgamation."
    )
    parser.add_argument("--source", default=os.path.join(ROOT, "vendor", "sqlite3"))
    parser.add_argument("--output", default=None)
    parser.add_argument("--patch", default=PATCH)
    options = parser.parse_args(argv[1:])
    output_dir = options.output if options.output is not None else options.source
    try:
        files, skipped = build(options.source, options.patch)
    except Failure as error:
        sys.stderr.write("row-counts-patch: " + str(error) + "\n")
        return 1
    for section in skipped:
        for name, reason in SKIPPED.items():
            if section["source"] == name:
                print("skipped: " + name + " (" + reason + ")")
    try:
        os.makedirs(output_dir, exist_ok=True)
        for name in sorted(files):
            path = os.path.join(output_dir, name)
            with open(path, "wb") as handle:
                handle.write(files[name])
            print(name + ": sha256=" + digest("sha256", files[name]) + " lines=" + str(files[name].count(b"\n")))
    except OSError as error:
        sys.stderr.write("row-counts-patch: cannot write " + output_dir + ": " + str(error) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
