import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "review_gate.py")
HEAD = "ab" * 20
OTHER = "cd" * 20
FAILURES: list[str] = []


def load_gate():
    spec = importlib.util.spec_from_file_location("review_gate", GATE)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + GATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(name, condition, detail=None):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def outcomes(**overrides):
    values = {"zig": "success", "head_build": "success", "base_build": "success", "opencode": "success"}
    values.update(overrides)
    return values


def verification(verdict="matches", sha=HEAD, extra=None):
    data = {"verification": verdict, "head_sha": sha}
    if extra:
        data.update(extra)
    return data


def finding(severity="nit"):
    return {"path": "docs/automerge.md", "line": 1, "severity": severity, "body": "A note."}


def write_json(directory, name, payload, raw=None):
    path = os.path.join(directory, name)
    with open(path, "wb") as handle:
        if raw is None:
            handle.write(json.dumps(payload).encode("utf-8"))
        else:
            handle.write(raw)
    return path


def main():
    gate = load_gate()
    passed = gate.problems(HEAD, verification(), [], outcomes())
    expect("a matching review with no findings passes", passed == [], passed)
    nits = gate.problems(HEAD, verification(), [finding("minor"), finding("nit")], outcomes())
    expect("minor and nit findings pass", nits == [], nits)
    blocked = gate.problems(HEAD, verification(), [finding("blocker"), finding("major")], outcomes())
    expect("blocker and major findings fail", any("blocker or major" in item for item in blocked), blocked)
    mismatch = gate.problems(HEAD, verification("does_not_match"), [], outcomes())
    expect("does_not_match fails", any("does_not_match" in item for item in mismatch), mismatch)
    unverified = gate.problems(HEAD, verification("could_not_verify"), [], outcomes())
    expect("could_not_verify fails", any("could_not_verify" in item for item in unverified), unverified)
    stale = gate.problems(HEAD, verification(sha=OTHER), [], outcomes())
    expect("a different head SHA fails", any("head_sha" in item for item in stale), stale)
    extra = gate.problems(HEAD, verification(extra={"note": "x"}), [], outcomes())
    expect("an extra verification key fails", any("exactly the keys" in item for item in extra), extra)
    missing = gate.problems(HEAD, {"verification": "matches"}, [], outcomes())
    expect("a missing head_sha key fails", any("exactly the keys" in item for item in missing), missing)
    fenced_value = gate.problems(HEAD, "matches", [], outcomes())
    expect("a non-object verification fails", any("not a JSON object" in item for item in fenced_value), fenced_value)
    bad_severity = gate.problems(HEAD, verification(), [finding("critical")], outcomes())
    expect("an unknown severity fails closed", any("severity" in item for item in bad_severity), bad_severity)
    not_list = gate.problems(HEAD, verification(), {"severity": "nit"}, outcomes())
    expect("findings that are not an array fail", any("not a JSON array" in item for item in not_list), not_list)
    builds = gate.problems(
        HEAD,
        verification(),
        [],
        outcomes(zig="failure", head_build="skipped", base_build="", opencode="cancelled"),
    )
    expect("a failed Zig setup is named", any(item.startswith("Zig setup") for item in builds), builds)
    expect("a skipped head build is named", any(item.startswith("head build") for item in builds), builds)
    expect("a missing merge-base build is named", any("merge-base build" in item for item in builds), builds)
    expect("a cancelled OpenCode step is named", any(item.startswith("OpenCode") for item in builds), builds)
    weird = gate.problems(HEAD, verification(), [], outcomes(opencode="injected\nvalue"))
    expect("an unrecognized outcome is not echoed", any("unrecognized" in item for item in weird), weird)
    expect("the injected outcome text is absent", all("injected" not in item for item in weird), weird)
    bad_sha = gate.problems("HEAD", verification(sha="HEAD"), [], outcomes())
    expect("a short head SHA fails", any("40-character" in item for item in bad_sha), bad_sha)

    work = tempfile.mkdtemp(prefix="review-gate-")
    try:
        verification_path = write_json(work, "verification.json", verification())
        findings_path = write_json(work, "findings.json", [])
        code = gate.run(
            [
                "review_gate.py",
                "--head-sha",
                HEAD,
                "--verification",
                verification_path,
                "--findings",
                findings_path,
                "--zig-outcome",
                "success",
                "--head-build",
                "success",
                "--base-build",
                "success",
                "--opencode",
                "success",
            ]
        )
        expect("the command passes a valid pair of files", code == 0, code)
        fenced = write_json(
            work,
            "fenced.json",
            None,
            raw=b'```json\n{"verification":"matches","head_sha":"' + HEAD.encode("ascii") + b'"}\n```\n',
        )
        try:
            gate.load_strict(fenced, gate.MAX_VERIFICATION_BYTES, "verification")
            expect("a fenced verification file fails", False, "loaded")
        except gate.Unusable as error:
            expect("a fenced verification file fails", "fence" in str(error), error)
        duplicate = write_json(
            work,
            "duplicate.json",
            None,
            raw=b'{"verification":"matches","verification":"does_not_match","head_sha":"'
            + HEAD.encode("ascii")
            + b'"}',
        )
        try:
            gate.load_strict(duplicate, gate.MAX_VERIFICATION_BYTES, "verification")
            expect("a duplicate key fails", False, "loaded")
        except gate.Unusable as error:
            expect("a duplicate key fails", "strict JSON" in str(error), error)
        trailing = write_json(work, "trailing.json", None, raw=b'{"verification":"matches"} trailing')
        try:
            gate.load_strict(trailing, gate.MAX_VERIFICATION_BYTES, "verification")
            expect("trailing junk fails", False, "loaded")
        except gate.Unusable as error:
            expect("trailing junk fails", "strict JSON" in str(error), error)
        missing_code = gate.main(
            [
                "review_gate.py",
                "--head-sha",
                HEAD,
                "--verification",
                os.path.join(work, "absent.json"),
                "--findings",
                findings_path,
                "--zig-outcome",
                "success",
                "--head-build",
                "success",
                "--base-build",
                "success",
                "--opencode",
                "success",
            ]
        )
        expect("a missing verification file fails closed", missing_code == 1, missing_code)
    finally:
        for name in os.listdir(work):
            os.remove(os.path.join(work, name))
        os.rmdir(work)

    if FAILURES:
        print("review_gate self-test: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("review_gate self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
