import json
import os
import re
import sys

MAX_FINDINGS_BYTES = 256 * 1024
MAX_VERIFICATION_BYTES = 4096
SHA = re.compile(r"^[0-9a-f]{40}$")
SEVERITIES = {"blocker", "major", "minor", "nit"}
BLOCKING = {"blocker", "major"}
VERDICTS = {"matches", "does_not_match", "could_not_verify"}
VERIFY_KEYS = {"verification", "head_sha"}
KNOWN_OUTCOMES = {"success", "failure", "cancelled", "skipped"}
OUTCOMES = (
    ("zig", "Zig setup"),
    ("head_build", "head build"),
    ("base_build", "merge-base build"),
    ("opencode", "OpenCode"),
)


class Unusable(Exception):
    pass


def reject_duplicates(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate key")
        obj[key] = value
    return obj


def load_strict(path, limit, label):
    if not path or not os.path.isfile(path):
        raise Unusable("the " + label + " file is missing")
    try:
        with open(path, "rb") as handle:
            raw = handle.read(limit + 1)
    except OSError as error:
        raise Unusable("the " + label + " file cannot be read: " + error.__class__.__name__) from None
    if len(raw) > limit:
        raise Unusable("the " + label + " file is larger than " + str(limit) + " bytes")
    if raw.startswith(b"\xef\xbb\xbf"):
        raise Unusable("the " + label + " file has a byte order mark")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Unusable("the " + label + " file is not UTF-8") from None
    body = text.strip()
    if body.startswith("```"):
        raise Unusable("the " + label + " file is wrapped in a fence")
    try:
        return json.loads(body, object_pairs_hook=reject_duplicates)
    except ValueError:
        raise Unusable("the " + label + " file is not strict JSON") from None


def outcome_text(value):
    if value in KNOWN_OUTCOMES:
        return value
    if not value:
        return "missing"
    return "unrecognized"


def outcome_problems(outcomes):
    found = []
    for key, label in OUTCOMES:
        value = outcomes.get(key, "")
        if value != "success":
            found.append(label + " outcome is " + outcome_text(value) + ", want success")
    return found


def verification_problems(data, head_sha):
    found = []
    if not isinstance(data, dict):
        return ["the verification file is not a JSON object"]
    if set(data.keys()) != VERIFY_KEYS:
        found.append("the verification file must have exactly the keys verification and head_sha")
    verdict = data.get("verification")
    if not isinstance(verdict, str) or verdict not in VERDICTS:
        found.append("verification is not matches, does_not_match, or could_not_verify")
    elif verdict != "matches":
        found.append("verification is " + verdict)
    recorded = data.get("head_sha")
    if not isinstance(recorded, str) or SHA.fullmatch(recorded) is None or recorded != head_sha:
        found.append("verification head_sha does not match this pull request head")
    return found


def findings_problems(data):
    if not isinstance(data, list):
        return ["the findings file is not a JSON array"]
    found = []
    blocking = 0
    for item in data:
        if not isinstance(item, dict):
            found.append("a finding is not a JSON object")
            continue
        severity = item.get("severity")
        if not isinstance(severity, str) or severity not in SEVERITIES:
            found.append("a finding severity is not blocker, major, minor, or nit")
            continue
        if severity in BLOCKING:
            blocking += 1
    if blocking:
        found.append("the findings include " + str(blocking) + " blocker or major item(s)")
    return found


def problems(head_sha, verification, findings, outcomes):
    found = []
    if not isinstance(head_sha, str) or SHA.fullmatch(head_sha) is None:
        found.append("the head SHA is not a 40-character hex string")
        safe_sha = ""
    else:
        safe_sha = head_sha
    found.extend(outcome_problems(outcomes))
    found.extend(verification_problems(verification, safe_sha))
    found.extend(findings_problems(findings))
    return found


def fail(message):
    sys.stderr.write("::error::" + message + "\n")


def parse_argv(argv):
    options = {}
    flags = {
        "--head-sha": "head_sha",
        "--verification": "verification",
        "--findings": "findings",
        "--zig-outcome": "zig",
        "--head-build": "head_build",
        "--base-build": "base_build",
        "--opencode": "opencode",
    }
    rest = list(argv[1:])
    while rest:
        item = rest.pop(0)
        key = flags.get(item)
        if key is None or not rest:
            raise Unusable("usage: python3 scripts/review_gate.py --head-sha SHA --verification FILE --findings FILE")
        options[key] = rest.pop(0)
    for key in ("head_sha", "verification", "findings", "zig", "head_build", "base_build", "opencode"):
        if key not in options:
            raise Unusable("missing " + key)
    return options


def run(argv):
    options = parse_argv(argv)
    verification = load_strict(options["verification"], MAX_VERIFICATION_BYTES, "verification")
    findings = load_strict(options["findings"], MAX_FINDINGS_BYTES, "findings")
    found = problems(
        options["head_sha"],
        verification,
        findings,
        {
            "zig": options["zig"],
            "head_build": options["head_build"],
            "base_build": options["base_build"],
            "opencode": options["opencode"],
        },
    )
    for message in found:
        fail(message)
    if found:
        return 1
    print("review-gate: matches for " + options["head_sha"])
    return 0


def main(argv):
    try:
        return run(argv)
    except Unusable as error:
        fail(str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
