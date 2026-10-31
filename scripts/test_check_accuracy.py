import importlib.util
import io
import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_accuracy.py")
ROOT = os.path.dirname(HERE)

FAILURES: list[str] = []

SCHEMA = "CREATE TABLE events (id INTEGER PRIMARY KEY, customer_id INTEGER);\n"
SELECT = "SELECT id FROM events WHERE customer_id = ?;\n"
INDEX = "CREATE INDEX idx_customer ON events(customer_id);\n"

PLAIN_FILES = {
    "schema.sql": SCHEMA,
    "select.sql": SELECT,
    "index.sql": INDEX,
}

COUNTERS_BASELINE = {
    "rows_read": 20000,
    "rows_written": 0,
    "fullscan_steps": 19999,
    "vm_steps": 60000,
    "sort_ops": 0,
    "autoindex_rows": 0,
}

COUNTERS_VARIANT = {
    "rows_read": 11,
    "rows_written": 0,
    "fullscan_steps": 0,
    "vm_steps": 80,
    "sort_ops": 0,
    "autoindex_rows": 0,
}

COUNT_KEYS = (
    "improved",
    "no_effect",
    "needs_check",
    "mismatch",
    "incomparable",
    "timeout",
    "not_judged",
)


def load_checker():
    spec = importlib.util.spec_from_file_location("check_accuracy", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(name: str, condition: bool, detail: Any = None) -> None:
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def finish(message: str) -> int:
    if FAILURES:
        print("test_accuracy: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("test_accuracy: " + message)
    return 0


def write_file(root: str, rel_path: str, text: str) -> None:
    path = os.path.join(root, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def make_root() -> str:
    root = tempfile.mkdtemp(prefix="qenome-accuracy-test-")
    os.makedirs(os.path.join(root, "testdata", "accuracy"), exist_ok=True)
    return root


def make_case(root: str, name: str, files: dict[str, str]) -> str:
    directory = os.path.join(root, "testdata", "accuracy", name)
    os.makedirs(directory, exist_ok=True)
    for filename, text in files.items():
        write_file(root, os.path.join("testdata", "accuracy", name, filename), text)
    return directory


def document(expect: dict[str, Any] | None = None, args: list[str] | None = None, **extra: Any) -> str:
    value = {
        "description": "A case for the self test.",
        "args": [] if args is None else args,
        "expect": {"exit": 0} if expect is None else expect,
    }
    value.update(extra)
    return json.dumps(value, indent=2) + "\n"


def with_case(case_document: str, **files: str) -> dict[str, str]:
    merged = dict(PLAIN_FILES)
    merged.update(files)
    merged["case.json"] = case_document
    return merged


def batch_manifest(candidates: list[dict[str, str]] | None = None, select: str = "select.sql") -> str:
    manifest: dict[str, Any] = {"queries": [{"select": select}]}
    if candidates is not None:
        manifest["candidates"] = candidates
    return json.dumps(manifest, indent=2) + "\n"


def refuse_case(checker, label: str, files: dict[str, str], mention: str) -> None:
    root = make_root()
    try:
        make_case(root, "broken", files)
        try:
            checker.load_case(root, "broken")
        except checker.Unusable as error:
            expect(label, mention in str(error), str(error))
        else:
            expect(label, False, "no error")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def refuse_expect(checker, label: str, value: dict[str, Any], mention: str) -> None:
    try:
        checker.load_expect("x", value)
    except checker.Unusable as error:
        expect(label, mention in str(error), str(error))
    else:
        expect(label, False, "no error")


def comparison(**overrides: Any) -> dict[str, Any]:
    value = {
        "schema_version": 2,
        "exit_code": 0,
        "result": "match",
        "verdict": "improved",
        "plan_changed": True,
        "baseline": {"rows": 10, "plan": [{"detail": "SCAN events"}], "counters": dict(COUNTERS_BASELINE)},
        "variant": {
            "rows": 10,
            "plan": [{"detail": "SEARCH events USING INDEX idx_customer (customer_id=?)"}],
            "counters": dict(COUNTERS_VARIANT),
        },
        "warnings": [{"code": "data_too_small", "message": "few rows"}],
        "timing": None,
    }
    value.update(overrides)
    return value


def observation(
    checker,
    report: dict[str, Any] | None = None,
    batch: dict[str, Any] | None = None,
    error: dict[str, Any] | None = None,
    exit_code: int = 0,
    stderr: str = "",
):
    stdout = ""
    if report is not None:
        stdout = json.dumps(report) + "\n"
    if batch is not None:
        stdout = json.dumps(batch) + "\n"
    if error is not None:
        stderr = json.dumps({"schema_version": 2, "exit_code": exit_code, "error": error}) + "\n"
    done = subprocess.CompletedProcess(["qenome"], exit_code, stdout, stderr)
    return checker.observation_from(done)


def batch_report(
    recommended: str | None = None,
    counts: dict[str, int] | None = None,
    index_sql: str | None = None,
    results: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    entry: dict[str, Any] = {"status": "compared", "index_sql_text": index_sql or INDEX}
    for key in COUNT_KEYS:
        entry[key] = 0
    for key, value in (counts or {}).items():
        entry[key] = value
    entry["candidate"] = "candidate.sql" if recommended is None else recommended
    return {
        "batch_schema_version": 1,
        "exit_code": 0,
        "recommended": recommended,
        "summary": [entry],
        "results": results if results is not None else [],
        "warnings": [],
    }


def multi_batch(second: dict[str, Any] | None = None, count: int = 2, recommended: str | None = None) -> dict[str, Any]:
    results = [
        {"comparison": comparison()},
        {"comparison": comparison() if second is None else second},
    ]
    return {
        "batch_schema_version": 1,
        "exit_code": 0,
        "recommended": recommended,
        "summary": [],
        "results": results[:count],
        "warnings": [],
    }


def check_pass(checker, name: str, expect_spec: dict[str, Any], observed) -> None:
    failures = checker.fail_messages(expect_spec, observed)
    expect(name, failures == [], failures)


def check_fail(checker, name: str, expect_spec: dict[str, Any], observed, mention: str) -> None:
    failures = checker.fail_messages(expect_spec, observed)
    expect(name, bool(failures) and any(mention in failure for failure in failures), failures)


def parser_tests(checker) -> None:
    root = make_root()
    try:
        make_case(root, "plain", with_case(document()))
        case = checker.load_case(root, "plain")
        expect("a plain case loads", case.mode == "compare", case.mode)
        argv = case.argv("/qenome")
        expected = ["/qenome", "db.sqlite", "select.sql", "index.sql", "--runs", "0", "--format", "json"]
        expect("a plain case builds the compare command", argv == expected, argv)

        timing_files = with_case(document(args=["--runs", "6"], timing="stable"))
        make_case(root, "timing", timing_files)
        case = checker.load_case(root, "timing")
        argv = case.argv("/qenome")
        expect("a timing case keeps its --runs", argv[argv.index("--runs") + 1] == "6", argv)
        expect("a timing case adds no second --runs", argv.count("--runs") == 1, argv)

        suggest_files = {
            "schema.sql": SCHEMA,
            "select.sql": SELECT,
            "case.json": document(args=["--suggest", "--bind", "1:int:1"]),
        }
        make_case(root, "suggest", suggest_files)
        case = checker.load_case(root, "suggest")
        expect("a suggest case loads", case.mode == "suggest", case.mode)
        expect("a suggest case has no --runs", "--runs" not in case.argv("/qenome"), case.argv("/qenome"))

        write_files = {
            "schema.sql": SCHEMA,
            "write.sql": "UPDATE events SET customer_id = 1 WHERE id = ?;\n",
            "index.sql": INDEX,
            "case.json": document(),
        }
        make_case(root, "write", write_files)
        case = checker.load_case(root, "write")
        argv = case.argv("/qenome")
        expect("a write case uses --write", case.mode == "write" and "--write" in argv, argv)
        expect("a write case passes the index file", "--index-sql" in argv, argv)

        migration_files = {
            "schema.sql": SCHEMA,
            "select.sql": SELECT,
            "batch.json": batch_manifest(),
            "migration.sql": INDEX,
            "case.json": document(),
        }
        make_case(root, "migration", migration_files)
        case = checker.load_case(root, "migration")
        argv = case.argv("/qenome")
        expect("a migration case uses --batch", case.mode == "batch" and "--batch" in argv, argv)
        expect("a migration case uses --migration", "--migration" in argv, argv)

        batch_files = {
            "schema.sql": SCHEMA,
            "select.sql": SELECT,
            "candidate.sql": INDEX,
            "batch.json": batch_manifest([{"index_sql": "candidate.sql"}]),
            "case.json": document(),
        }
        make_case(root, "batch", batch_files)
        case = checker.load_case(root, "batch")
        expect("a batch case uses --batch", case.mode == "batch" and "--batch" in case.argv("/qenome"), case.mode)

        seeded_files = {
            "schema.sql": SCHEMA,
            "seed.json": "{}\n",
            "select.sql": SELECT,
            "index.sql": INDEX,
            "case.json": document(),
        }
        make_case(root, "seeded", seeded_files)
        case = checker.load_case(root, "seeded")
        expect("a seeded case passes --seed-data", "--seed-data" in case.argv("/qenome"), case.argv("/qenome"))

        refuse_case(checker, "an unknown case key is refused", with_case(document(surprise=1)), "surprise")
        refuse_case(
            checker,
            "an unknown expect key is refused",
            with_case(document(expect={"exit": 0, "wibble": 1})),
            "wibble",
        )
        refuse_case(
            checker,
            "a missing description is refused",
            with_case(json.dumps({"args": [], "expect": {"exit": 0}}) + "\n"),
            "description",
        )
        refuse_case(
            checker,
            "a two-line description is refused",
            with_case(document(description="one\ntwo")),
            "one line",
        )
        refuse_case(
            checker,
            "a missing schema.sql is refused",
            {"select.sql": SELECT, "index.sql": INDEX, "case.json": document()},
            "schema.sql",
        )
        refuse_case(
            checker,
            "a missing select.sql is refused",
            {"schema.sql": SCHEMA, "index.sql": INDEX, "case.json": document()},
            "select.sql",
        )
        refuse_case(
            checker,
            "a missing index.sql is refused",
            {"schema.sql": SCHEMA, "select.sql": SELECT, "case.json": document()},
            "index.sql",
        )
        refuse_case(
            checker,
            "data.sql with seed.json is refused",
            with_case(document(), **{"data.sql": "ANALYZE;\n", "seed.json": "{}\n"}),
            "not both",
        )
        refuse_case(
            checker,
            "a stray migration.sql is refused",
            with_case(document(), **{"migration.sql": INDEX}),
            "migration.sql",
        )
        refuse_case(
            checker,
            "a write case with select.sql is refused",
            with_case(document(), **{"write.sql": "DELETE FROM events;\n"}),
            "select.sql",
        )
        refuse_case(
            checker,
            "a suggest case with index.sql is refused",
            with_case(document(args=["--suggest"])),
            "index.sql",
        )
        refuse_case(
            checker,
            "a case that sets --format is refused",
            with_case(document(args=["--format", "json"])),
            "--format",
        )
        refuse_case(
            checker,
            "a case without timing that sets --runs is refused",
            with_case(document(args=["--runs", "2"])),
            "--runs",
        )
        refuse_case(
            checker,
            "a timing case without --runs is refused",
            with_case(document(timing="stable")),
            "timing",
        )
        refuse_case(
            checker,
            "a timing case with fewer than 6 runs is refused",
            with_case(document(args=["--runs", "3"], timing="stable")),
            "6",
        )
        refuse_case(
            checker,
            "a timing write case is refused",
            {
                "schema.sql": SCHEMA,
                "write.sql": "DELETE FROM events;\n",
                "index.sql": INDEX,
                "case.json": document(args=["--runs", "6"], timing="stable"),
            },
            "single SELECT",
        )
        refuse_case(
            checker,
            "an effect without a timing case is refused",
            with_case(document(expect={"effect": "no-difference"})),
            "timing",
        )
        refuse_case(
            checker,
            "an unknown result value is refused",
            with_case(document(expect={"result": "fine"})),
            "result",
        )
        refuse_case(
            checker,
            "an unknown verdict value is refused",
            with_case(document(expect={"verdict": "good"})),
            "verdict",
        )
        refuse_case(
            checker,
            "an unknown plan key is refused",
            with_case(document(expect={"baseline_plan": {"holds": ["x"]}})),
            "holds",
        )
        refuse_case(
            checker,
            "a max_ratio of zero is refused",
            with_case(document(expect={"rows_read": {"direction": "decrease", "max_ratio": 0}})),
            "max_ratio",
        )
        refuse_case(
            checker,
            "an unknown summary count is refused",
            with_case(document(expect={"batch": {"counts": {"wow": 1}}})),
            "wow",
        )
        refuse_case(
            checker,
            "a manifest naming a missing file is refused",
            {
                "schema.sql": SCHEMA,
                "select.sql": SELECT,
                "batch.json": batch_manifest(select="gone.sql"),
                "migration.sql": INDEX,
                "case.json": document(),
            },
            "gone.sql",
        )
        refuse_case(
            checker,
            "a migration manifest with candidates is refused",
            {
                "schema.sql": SCHEMA,
                "select.sql": SELECT,
                "candidate.sql": INDEX,
                "batch.json": batch_manifest([{"index_sql": "candidate.sql"}]),
                "migration.sql": INDEX,
                "case.json": document(),
            },
            "omit candidates",
        )
        refuse_case(
            checker,
            "a batch case without candidates or migration is refused",
            {
                "schema.sql": SCHEMA,
                "select.sql": SELECT,
                "batch.json": batch_manifest(),
                "case.json": document(),
            },
            "candidates",
        )
        refuse_case(
            checker,
            "a batch case with --bind in args is refused",
            {
                "schema.sql": SCHEMA,
                "select.sql": SELECT,
                "batch.json": batch_manifest([]),
                "case.json": document(args=["--bind", "1:int:1"]),
            },
            "batch.json",
        )
        make_case(root, "no-case-json", {"schema.sql": SCHEMA})
        try:
            checker.load_case(root, "no-case-json")
        except checker.Unusable as error:
            expect("a case without case.json is refused", "case.json" in str(error), str(error))
        else:
            expect("a case without case.json is refused", False, "no error")
        try:
            checker.load_case(root, "absent")
        except checker.Unusable as error:
            expect("an unknown case directory is refused", "absent" in str(error), str(error))
        else:
            expect("an unknown case directory is refused", False, "no error")
        os.makedirs(os.path.join(root, "testdata", "accuracy", "unclassified"), exist_ok=True)
        try:
            checker.case_names(root)
        except checker.Unusable as error:
            expect("a case directory without case.json stops the corpus", "case.json" in str(error), str(error))
        else:
            expect("a case directory without case.json stops the corpus", False, "no error")
        try:
            checker.case_names(os.path.join(root, "nope"))
        except checker.Unusable as error:
            expect("a missing corpus is refused", "corpus" in str(error), str(error))
        else:
            expect("a missing corpus is refused", False, "no error")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def parser_value_tests(checker) -> None:
    root = make_root()
    try:
        make_case(root, "plain", with_case(document()))
        case = checker.load_case(root, "plain")
        expect("a case holds the normalized expect", case.expect == {"exit": 0}, case.expect)
        expect("a case has no known_wrong", case.known_wrong is None, case.known_wrong)
        expect("a case has no timing", case.timing is None, case.timing)
        expect("a case has a name", case.name == "plain", case.name)

        normalized = checker.load_expect("x", {"rows_read": "decrease"})
        expect(
            "a row direction string is normalized",
            normalized == {"rows_read": {"direction": "decrease"}},
            normalized,
        )
        normalized = checker.load_expect("x", {"warnings": {"contains": ["data_too_small"]}})
        expect(
            "a warning list is kept",
            normalized == {"warnings": {"contains": ["data_too_small"]}},
            normalized,
        )
        normalized = checker.load_expect("x", {"error": {"code": "no_candidates"}})
        expect("an error code is kept", normalized == {"error": {"code": "no_candidates"}}, normalized)

        normalized = checker.load_expect("x", {"effect": "no-difference"})
        expect(
            "an effect string is normalized to a list",
            normalized == {"effect": ["no-difference"]},
            normalized,
        )
        normalized = checker.load_expect("x", {"effect": ["no-difference", "insufficient-samples"]})
        expect(
            "an effect list is kept",
            normalized == {"effect": ["no-difference", "insufficient-samples"]},
            normalized,
        )
        normalized = checker.load_expect("x", {"human": {"contains": ["verdict"], "excludes": ["error:"]}})
        expect(
            "a human spec is kept",
            normalized == {"human": {"contains": ["verdict"], "excludes": ["error:"]}},
            normalized,
        )

        refuse_expect(checker, "an empty expect is refused", {}, "no check")
        refuse_expect(checker, "a plan without checks is refused", {"baseline_plan": {}}, "contains")
        refuse_expect(checker, "a warning spec without checks is refused", {"warnings": {}}, "contains")
        refuse_expect(checker, "a batch spec without checks is refused", {"batch": {}}, "recommended")
        refuse_expect(checker, "a suggest spec without checks is refused", {"suggest": {}}, "recommended")
        refuse_expect(checker, "a human spec without checks is refused", {"human": {}}, "contains")
        refuse_expect(
            checker,
            "an unknown human key is refused",
            {"human": {"holds": ["x"]}},
            "holds",
        )
        refuse_expect(
            checker,
            "an unknown effect is refused",
            {"effect": "faster-but-not"},
            "no-difference",
        )
        refuse_expect(checker, "an empty effect list is refused", {"effect": []}, "array")
        refuse_expect(
            checker,
            "a bad plan value is refused",
            {"baseline_plan": {"contains": "x"}},
            "array",
        )
        refuse_expect(checker, "a bad direction is refused", {"rows_read": "sideways"}, "direction")
        refuse_expect(
            checker,
            "a bool count is refused",
            {"batch": {"counts": {"improved": True}}},
            "whole number",
        )
        refuse_expect(
            checker,
            "a non-bool suggestion flag is refused",
            {"suggest": {"recommended": "yes"}},
            "true or false",
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)


def expectation_tests(checker) -> None:
    good = observation(checker, report=comparison())
    other_exit = observation(checker, report=dict(comparison(), exit_code=3), exit_code=3)

    check_pass(checker, "exit matches", {"exit": 0}, good)
    check_fail(checker, "a different exit fails", {"exit": 4}, good, "exit is 0")
    check_pass(checker, "exit_code matches", {"exit_code": 0}, good)
    check_fail(checker, "a different exit_code fails", {"exit_code": 3}, good, "exit_code is 0")
    check_fail(checker, "a different exit fails the process code", {"exit": 0}, other_exit, "exit is 3")

    check_pass(checker, "result matches", {"result": "match"}, good)
    check_fail(checker, "a different result fails", {"result": "incomparable"}, good, "result is")
    check_pass(checker, "verdict matches", {"verdict": "improved"}, good)
    check_fail(checker, "a different verdict fails", {"verdict": "no-effect"}, good, "verdict is")
    check_pass(checker, "plan_changed matches", {"plan_changed": True}, good)
    check_fail(checker, "a different plan_changed fails", {"plan_changed": False}, good, "plan_changed is")

    check_pass(checker, "a contained plan detail passes", {"baseline_plan": {"contains": ["SCAN"]}}, good)
    check_fail(
        checker,
        "a missing plan detail fails",
        {"baseline_plan": {"contains": ["SEARCH"]}},
        good,
        "no step with",
    )
    check_fail(
        checker,
        "an excluded plan detail fails",
        {"baseline_plan": {"excludes": ["SCAN"]}},
        good,
        "has a step with",
    )
    check_pass(checker, "an absent plan detail passes", {"variant_plan": {"excludes": ["TEMP B-TREE"]}}, good)

    check_pass(checker, "a decreasing rows_read passes", {"rows_read": {"direction": "decrease"}}, good)
    check_fail(
        checker,
        "an equal rows_read fails a decrease",
        {"rows_read": {"direction": "same"}},
        good,
        "expected a same",
    )
    check_pass(
        checker,
        "a max_ratio within the bound passes",
        {"rows_read": {"direction": "decrease", "max_ratio": 0.01}},
        good,
    )
    check_fail(
        checker,
        "a max_ratio over the bound fails",
        {"rows_read": {"direction": "decrease", "max_ratio": 0.00001}},
        good,
        "at most",
    )
    check_pass(checker, "an unchanged rows_written passes", {"rows_written": {"direction": "same"}}, good)
    increasing = dict(comparison()["variant"])
    increasing["counters"] = dict(COUNTERS_VARIANT, rows_written=2)
    increasing_observation = observation(checker, report=dict(comparison(), variant=increasing))
    check_fail(
        checker,
        "an increasing rows_written fails a same check",
        {"rows_written": {"direction": "same"}},
        increasing_observation,
        "expected a same",
    )
    zero_baseline = dict(comparison()["baseline"])
    zero_baseline["counters"] = dict(COUNTERS_BASELINE, rows_read=0)
    zero = observation(checker, report=dict(comparison(), baseline=zero_baseline))
    check_fail(
        checker,
        "a zero baseline cannot use max_ratio",
        {"rows_read": {"direction": "same", "max_ratio": 0.5}},
        zero,
        "above 0",
    )

    check_pass(checker, "a contained warning passes", {"warnings": {"contains": ["data_too_small"]}}, good)
    check_fail(
        checker,
        "a missing warning fails",
        {"warnings": {"contains": ["no_analyze_stats"]}},
        good,
        "no no_analyze_stats",
    )
    check_fail(
        checker,
        "an excluded warning fails",
        {"warnings": {"excludes": ["data_too_small"]}},
        good,
        "hold data_too_small",
    )

    report = batch_report(recommended="migration.sql", counts={"improved": 1})
    batch = observation(checker, batch=dict(report, exit_code=6), exit_code=6)
    check_pass(checker, "a recommended match passes", {"batch": {"recommended": "migration.sql"}}, batch)
    check_fail(checker, "a different recommendation fails", {"batch": {"recommended": None}}, batch, "recommended is")
    check_pass(checker, "a summary count matches", {"batch": {"counts": {"improved": 1}}}, batch)
    check_fail(
        checker,
        "a different summary count fails",
        {"batch": {"counts": {"needs_check": 1}}},
        batch,
        "summary[0].needs_check",
    )
    check_pass(checker, "a batch exit_code matches", {"exit_code": 6}, batch)
    check_fail(checker, "a missing batch report fails", {"batch": {"recommended": None}}, good, "no batch report")

    suggested = batch_report(
        recommended="suggested:1",
        counts={"improved": 1},
        index_sql="CREATE INDEX x ON events(customer_id, status);",
    )
    suggest = observation(checker, batch=suggested)
    check_pass(checker, "a suggested recommendation passes", {"suggest": {"recommended": True}}, suggest)
    check_fail(checker, "a missing suggestion fails", {"suggest": {"recommended": False}}, suggest, "expected null")
    check_pass(checker, "a leading column passes", {"suggest": {"leads_with": ["customer_id"]}}, suggest)
    check_fail(checker, "a wrong leading column fails", {"suggest": {"leads_with": ["status"]}}, suggest, "leads with")
    check_fail(
        checker,
        "a suggestion check needs a batch report",
        {"suggest": {"recommended": True}},
        good,
        "no batch report",
    )

    error = observation(checker, error={"code": "no_candidates", "message": "none", "hint": "add one"}, exit_code=1)
    check_pass(checker, "an error code matches", {"error": {"code": "no_candidates"}}, error)
    check_fail(checker, "a missing error object fails", {"error": {"code": "no_candidates"}}, good, "no error object")
    check_fail(checker, "a wrong error code fails", {"error": {"code": "suggest_failed"}}, error, "the error code is")

    two = {
        "batch_schema_version": 1,
        "exit_code": 0,
        "recommended": None,
        "summary": [],
        "results": [{"comparison": comparison()}, {"comparison": comparison()}],
        "warnings": [],
    }
    check_fail(
        checker,
        "a two-comparison report fails a single-comparison check",
        {"result": "match"},
        observation(checker, batch=two),
        "2 comparison objects",
    )
    check_fail(
        checker,
        "a report without a comparison fails",
        {"result": "match"},
        observation(checker, exit_code=1),
        "no comparison object",
    )
    one = dict(two, results=[{"comparison": comparison()}])
    check_pass(checker, "a one-comparison batch report passes", {"result": "match"}, observation(checker, batch=one))


def repeat_tests(checker) -> None:
    first = observation(checker, report=comparison())
    failures = checker.repeat_failures(first, first, 2)
    expect("identical runs hold no difference", failures == [], failures)

    flipped = observation(checker, report=comparison(verdict="no-effect"))
    failures = checker.repeat_failures(first, flipped, 2)
    expect("a verdict flip is reported", bool(failures) and "verdict" in failures[0], failures)
    expect("a verdict flip names the run", bool(failures) and "run 2" in failures[0], failures)

    plan = dict(comparison()["variant"])
    plan["plan"] = [{"detail": "SCAN events"}]
    failures = checker.repeat_failures(first, observation(checker, report=dict(comparison(), variant=plan)), 3)
    expect("a plan flip is reported", bool(failures) and "variant.plan[0]" in failures[0], failures)

    baseline = dict(comparison()["baseline"])
    baseline["counters"] = dict(COUNTERS_BASELINE, rows_read=19999)
    failures = checker.repeat_failures(first, observation(checker, report=dict(comparison(), baseline=baseline)), 2)
    expect("a counter flip is reported", bool(failures) and "baseline.counters.rows_read" in failures[0], failures)

    failures = checker.repeat_failures(first, observation(checker, report=comparison(plan_changed=False)), 2)
    expect("a plan_changed flip is reported", bool(failures) and "plan_changed" in failures[0], failures)

    failures = checker.repeat_failures(first, observation(checker, report=dict(comparison(), exit_code=3)), 2)
    expect("an exit_code flip is reported", bool(failures) and "exit_code" in failures[0], failures)

    timing = comparison(timing={"effect": "no-difference"})
    failures = checker.repeat_failures(first, observation(checker, report=timing), 2)
    expect("a timing effect is not part of the signature", failures == [], failures)

    multi = observation(checker, batch=multi_batch())
    second_verdict = observation(checker, batch=multi_batch(comparison(verdict="no-effect")))
    failures = checker.repeat_failures(multi, second_verdict, 2)
    expect(
        "a second comparison verdict flip is reported",
        bool(failures) and "comparisons[1].verdict" in failures[0],
        failures,
    )

    second_plan = dict(comparison()["variant"])
    second_plan["plan"] = [{"detail": "SCAN events"}]
    plans = observation(checker, batch=multi_batch(dict(comparison(), variant=second_plan)))
    failures = checker.repeat_failures(multi, plans, 2)
    expect(
        "a second comparison plan flip is reported",
        bool(failures) and "comparisons[1].variant.plan[0]" in failures[0],
        failures,
    )

    second_counters = dict(comparison()["variant"])
    second_counters["counters"] = dict(COUNTERS_VARIANT, rows_read=99)
    counters = observation(checker, batch=multi_batch(dict(comparison(), variant=second_counters)))
    failures = checker.repeat_failures(multi, counters, 2)
    expect(
        "a second comparison counter flip is reported",
        bool(failures) and "comparisons[1].variant.counters.rows_read" in failures[0],
        failures,
    )

    fewer = observation(checker, batch=multi_batch(count=1))
    failures = checker.repeat_failures(multi, fewer, 2)
    expect("a changed comparison count is reported", bool(failures) and "comparisons" in failures[0], failures)

    recommended = observation(checker, batch=multi_batch(recommended="other.sql"))
    failures = checker.repeat_failures(multi, recommended, 2)
    expect("a changed recommendation is reported", bool(failures) and "recommended" in failures[0], failures)


def effect_tests(checker) -> None:
    allowed = ["no-difference", "insufficient-samples", "slower"]

    def effect_runs(*values, expect_spec=None):
        observations = []
        for value in values:
            if value is None:
                observations.append(observation(checker, report=comparison()))
            else:
                observations.append(observation(checker, report=comparison(timing={"effect": value, "rounds": 6})))
        spec = {"effect": allowed} if expect_spec is None else expect_spec
        return checker.effect_majority("case", spec, observations)

    failures, note = effect_runs("no-difference", "no-difference", "no-difference")
    expect("allowed timing effects pass", failures == [] and note is None, (failures, note))
    failures, note = effect_runs("slower", "insufficient-samples", "no-difference")
    expect("every allowed label passes", failures == [] and note is None, (failures, note))
    failures, note = effect_runs("faster", "no-difference", "no-difference")
    expect("one disallowed effect in three runs passes", failures == [], failures)
    expect(
        "one disallowed effect in three runs is noted",
        note is not None and note.startswith('note case: run 1 is "faster", outside'),
        note,
    )
    expect("the note names the allowed labels", note is not None and json.dumps(allowed) in note, note)
    expect(
        "the note says the effect check passes",
        note is not None and note.endswith("; at most half of the 3 runs, so the effect check passes"),
        note,
    )
    failures, note = effect_runs(
        "faster", "no-difference", "slower", "no-difference", expect_spec={"effect": ["no-difference"]}
    )
    expect(
        "two different disallowed effects share one note line",
        failures == [] and note is not None and 'run 1 is "faster"' in note and 'run 3 is "slower"' in note,
        note,
    )
    failures, note = effect_runs("faster", "faster", "no-difference")
    expect(
        "two disallowed effects in three runs fail",
        len(failures) == 2 and note is None and failures[0].startswith("run 1: the timing effect is"),
        failures,
    )
    failures, note = effect_runs("faster", "faster", "faster")
    expect("three disallowed effects fail", len(failures) == 3 and note is None, failures)
    failures, note = effect_runs("faster")
    expect("one run with a disallowed effect fails", len(failures) == 1 and note is None, failures)
    failures, note = effect_runs("faster", "no-difference")
    expect("half of two runs is not a majority", failures == [] and note is not None, (failures, note))
    failures, note = effect_runs("faster", "faster", "no-difference", "no-difference")
    expect("half of four runs is not a majority", failures == [] and note is not None, (failures, note))
    failures, note = effect_runs("faster", "faster", "faster", "no-difference", "no-difference")
    expect("three of five runs is a majority", len(failures) == 3 and note is None, failures)
    failures, note = effect_runs("faster", "no-difference", expect_spec={"verdict": "improved"})
    expect(
        "a case without an effect expectation holds no effect check",
        failures == [] and note is None,
        (failures, note),
    )
    failures, note = effect_runs(None, "no-difference", "no-difference")
    expect(
        "a missing timing effect counts as an outlier",
        failures == [] and note is not None and "run 1 is null" in note,
        note,
    )
    failures, note = effect_runs(None, None, None)
    expect("a missing timing effect in every run fails", len(failures) == 3, failures)


def timing_tests(checker) -> None:
    def effects(*values, effect_expected=False):
        observations = []
        for value in values:
            if value is None:
                observations.append(observation(checker, report=comparison()))
            else:
                observations.append(observation(checker, report=comparison(timing={"effect": value, "rounds": 6})))
        return checker.timing_failures(observations, effect_expected)

    steady = effects("faster", "faster", "faster")
    expect("a steady faster effect passes", steady == [], steady)
    flip = effects("faster", "slower")
    expect("a faster to slower flip fails", bool(flip), flip)
    reverse = effects("slower", "faster")
    expect("a slower to faster flip fails", bool(reverse), reverse)
    expected = effects("faster", "slower", effect_expected=True)
    expect("an expected effect skips the flip check", expected == [], expected)
    expected_steady = effects("faster", "faster", "slower", effect_expected=True)
    expect("an expected effect keeps a steady direction", expected_steady == [], expected_steady)
    neutral = effects("faster", "no-difference")
    expect("no-difference is not a flip", neutral == [], neutral)
    samples = effects("faster", "insufficient-samples")
    expect("insufficient-samples is not a flip", samples == [], samples)
    missing = effects(None)
    expect("a missing effect fails", bool(missing), missing)
    missing_expected = effects(None, effect_expected=True)
    expect("a missing effect fails with an expected effect", bool(missing_expected), missing_expected)
    no_comparison = checker.timing_failures([observation(checker, exit_code=1)], False)
    expect("a missing comparison fails", bool(no_comparison), no_comparison)


def judge_tests(checker) -> None:
    good = observation(checker, report=comparison())
    flipped = observation(checker, report=comparison(verdict="no-effect"))

    status, message = checker.judge("case", {"verdict": "improved"}, None, None, [good, good])
    expect("matching runs pass", status == "ok", message)

    status, message = checker.judge("case", {"verdict": "improved"}, None, None, [good, flipped])
    expect("a repeated flip fails", status == "FAIL" and "run 2" in message, message)

    status, message = checker.judge("case", {"verdict": "improved"}, None, None, [flipped])
    expect("a wrong expectation fails", status == "FAIL" and "verdict is" in message, message)

    status, message = checker.judge("case", {"verdict": "improved"}, "https://example.test/1", None, [flipped])
    expect("a known-wrong case passes as known-wrong", status == "known-wrong" and "example.test" in message, message)

    status, message = checker.judge("case", {"verdict": "improved"}, "https://example.test/1", None, [good])
    expect("a known-wrong case that passes fails", status == "FAIL" and "remove known_wrong" in message, message)

    faster = observation(checker, report=comparison(timing={"effect": "faster", "rounds": 6}))
    slower = observation(checker, report=comparison(timing={"effect": "slower", "rounds": 6}))
    status, message = checker.judge("case", {"verdict": "improved"}, None, "stable", [faster, slower])
    expect("a timing flip fails the case", status == "FAIL" and "flips" in message, message)

    quieter = observation(checker, report=comparison(timing={"effect": "no-difference", "rounds": 6}))
    status, message = checker.judge("case", {"verdict": "improved"}, None, "stable", [faster, quieter])
    expect("a timing change that is not a flip passes", status == "ok", message)

    status, message = checker.judge("case", {"exit": 0}, None, None, [good, flipped])
    expect("a repeat flip fails when the expectation alone passes", status == "FAIL" and "verdict" in message, message)

    wrong_one = observation(checker, report=comparison(verdict="no-effect"))
    wrong_two = observation(checker, report=comparison(verdict="regressed"))
    status, message = checker.judge(
        "case", {"verdict": "improved"}, "https://example.test/1", None, [wrong_one, wrong_two]
    )
    expect("a known-wrong case with unstable results fails", status == "FAIL" and "not stable" in message, message)

    unstable_timing = [
        observation(checker, report=comparison(verdict="no-effect", timing={"effect": "faster", "rounds": 6})),
        observation(checker, report=comparison(verdict="no-effect", timing={"effect": "slower", "rounds": 6})),
    ]
    status, message = checker.judge(
        "case", {"verdict": "improved"}, "https://example.test/1", "stable", unstable_timing
    )
    expect(
        "a known-wrong case with a timing flip fails",
        status == "FAIL" and "not stable" in message and "flips" in message,
        message,
    )

    status, message = checker.judge("case", {"verdict": "improved"}, "https://example.test/1", None, [good, flipped])
    expect(
        "a known-wrong case that passes in one run fails",
        status == "FAIL" and "passes in run(s) 1" in message,
        message,
    )

    extra = ['the human report has no "verdict"']
    status, message = checker.judge("case", {"verdict": "improved"}, None, None, [flipped, flipped], extra)
    expect(
        "an extra failure fails the case once",
        status == "FAIL" and message.startswith('the human report has no "verdict"'),
        message,
    )

    status, message = checker.judge("case", {"verdict": "improved"}, "https://example.test/1", None, [flipped], extra)
    expect("a known-wrong case keeps its extra failure", status == "known-wrong" and "human report" in message, message)

    status, message = checker.judge("case", {"verdict": "improved"}, "https://example.test/1", None, [good], extra)
    expect(
        "a known-wrong case whose answer is right reports both the marker and the extra failure",
        status == "FAIL" and "remove known_wrong" in message and "human report" in message,
        message,
    )

    expected_effect = {"verdict": "improved", "effect": ["no-difference"]}
    notes: list[str] = []
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, quieter, quieter], notes=notes)
    expect("one disallowed timing effect in three runs passes the case", status == "ok", message)
    expect(
        "one disallowed timing effect in three runs prints one note",
        len(notes) == 1 and "run 1" in notes[0] and '"faster"' in notes[0],
        notes,
    )
    notes = []
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, faster, quieter], notes=notes)
    expect(
        "two disallowed timing effects fail the case",
        status == "FAIL" and "the timing effect is" in message,
        message,
    )
    expect("a failing effect majority prints no note", notes == [], notes)
    notes = []
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, faster, faster], notes=notes)
    expect("three disallowed timing effects fail the case", status == "FAIL" and notes == [], message)
    notes = []
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, quieter], notes=notes)
    expect("half of two runs passes the case", status == "ok" and len(notes) == 1, (message, notes))
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, quieter, quieter])
    expect("a note is dropped when the caller keeps no notes", status == "ok", message)
    mixed = observation(checker, report=comparison(verdict="no-effect", timing={"effect": "no-difference"}))
    notes = []
    status, message = checker.judge("case", expected_effect, None, "stable", [faster, mixed, quieter], notes=notes)
    expect(
        "a tolerated timing effect does not hide another expectation",
        status == "FAIL" and "run 2" in message and "verdict is" in message,
        message,
    )
    expect("a tolerated timing effect still prints its note", len(notes) == 1, notes)
    untimed = observation(checker, report=comparison())
    notes = []
    status, message = checker.judge("case", expected_effect, None, "stable", [untimed, quieter, quieter], notes=notes)
    expect(
        "a missing timing effect fails a timing case as a minority",
        status == "FAIL" and "has no timing effect" in message,
        message,
    )
    expect("a missing timing effect still prints the effect note", len(notes) == 1, notes)

    notes = []
    inside = {"effect": ["no-difference"]}
    status, message = checker.judge("case", inside, "https://example.test/1", "stable", [faster, faster, faster])
    expect(
        "a known-wrong case whose only effect failure is the majority is not fixed",
        status == "known-wrong" and "the timing effect is" in message,
        message,
    )
    status, message = checker.judge("case", inside, "https://example.test/1", "stable", [quieter, quieter, quieter])
    expect(
        "a known-wrong case whose effect now passes fails as fixed",
        status == "FAIL" and "remove known_wrong" in message,
        message,
    )
    status, message = checker.judge("case", inside, "https://example.test/1", "stable", [faster, quieter, quieter])
    expect(
        "a known-wrong case with a tolerated effect outlier fails as fixed",
        status == "FAIL" and "remove known_wrong" in message,
        message,
    )


def run_output_tests(checker) -> None:
    note = (
        'note case: run 1 is "faster", outside ["no-difference"]; '
        "at most half of the 3 runs, so the effect check passes"
    )
    case = checker.Case("case", "", "compare", [], {"exit": 0}, None, None)
    original = checker.run_case
    checker.run_case = lambda case, repeat, binary, work_parent: ("ok", case.name, [note], ["improved"])
    try:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            failures, known_wrong, rows = checker.run("/root", [case], 3, "/nonexistent/qenome")
    finally:
        checker.run_case = original
    lines = buffer.getvalue().splitlines()
    expect("a passing case prints its ok line and then its note", lines == ["ok case", note], lines)
    expect("a note does not count as a failure", failures == 0 and known_wrong == 0, (failures, known_wrong))


def human_tests(checker) -> None:
    output = {
        "stdout": "Summary\n  verdict       improved: the rows match\n\nWarnings\n  warning: data_too_small: small\n",
        "exit": 0,
    }
    failures = checker.human_failures({"contains": ["verdict       improved", "data_too_small:"]}, output)
    expect("a contained human string passes", failures == [], failures)
    failures = checker.human_failures({"contains": ["no_analyze_stats:"]}, output)
    expect("a missing human string fails", bool(failures) and "no_analyze_stats:" in failures[0], failures)
    failures = checker.human_failures({"excludes": ["data_too_small:"]}, output)
    expect("an excluded human string fails", bool(failures) and "holds" in failures[0], failures)
    failures = checker.human_failures({"excludes": ["error:"]}, output)
    expect("an absent human string passes an exclusion", failures == [], failures)
    failures = checker.human_failures({"contains": ["verdict"]}, None)
    expect("a missing human report fails", bool(failures) and "no human report" in failures[0], failures)


def summary_tests(checker) -> None:
    rows: list[dict[str, Any]] = [
        {
            "name": "a",
            "expected_verdict": "improved",
            "expected_result": "match",
            "verdicts": ["improved"],
            "known_wrong": None,
        },
        {
            "name": "b",
            "expected_verdict": "no-effect",
            "expected_result": "match",
            "verdicts": ["no-effect"],
            "known_wrong": None,
        },
        {
            "name": "c",
            "expected_verdict": "needs-check",
            "expected_result": "mismatch",
            "verdicts": [],
            "known_wrong": None,
        },
        {"name": "d", "expected_verdict": None, "expected_result": None, "verdicts": [], "known_wrong": None},
    ]
    line = checker.summary_line(rows)
    expect(
        "the summary line counts the expected verdicts",
        "expected verdicts improved 1, no-effect 1, needs-check 1, unstated 1" in line,
        line,
    )
    expect(
        "the summary line counts the expected results",
        "expected results match 2, mismatch 1, unstated 1" in line,
        line,
    )
    wrong, known = checker.improved_rows(rows)
    expect("no case answers improved wrongly", wrong == [] and known == [], (wrong, known))
    rows[1]["verdicts"] = ["improved"]
    wrong, known = checker.improved_rows(rows)
    expect(
        "a case that expects no-effect and answers improved is listed",
        [row["name"] for row in wrong] == ["b"],
        wrong,
    )
    rows[1]["known_wrong"] = "https://example.test/1"
    wrong, known = checker.improved_rows(rows)
    expect(
        "a known-wrong case that answers improved is listed apart",
        wrong == [] and [row["name"] for row in known] == ["b"],
        (wrong, known),
    )
    rows[0]["verdicts"] = ["no-effect"]
    wrong, known = checker.improved_rows(rows)
    expect(
        "an improved expectation that answers no-effect is not listed",
        wrong == [] and [row["name"] for row in known] == ["b"],
        (wrong, known),
    )

    rows = [
        {
            "name": "a",
            "expected_verdict": "no-effect",
            "expected_result": "match",
            "verdicts": ["no-effect"],
            "known_wrong": None,
            "status": "ok",
        },
        {
            "name": "b",
            "expected_verdict": "no-effect",
            "expected_result": "match",
            "verdicts": ["improved"],
            "known_wrong": None,
            "status": "FAIL",
        },
        {
            "name": "c",
            "expected_verdict": "needs-check",
            "expected_result": "match",
            "verdicts": ["improved"],
            "known_wrong": "https://example.test/1",
            "status": "known-wrong",
        },
        {
            "name": "d",
            "expected_verdict": "no-effect",
            "expected_result": "match",
            "verdicts": ["no-effect", "improved"],
            "known_wrong": "https://example.test/2",
            "status": "FAIL",
        },
    ]
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        total = checker.summarize("/root", [], 3, 2, 2, rows)
    text = buffer.getvalue()
    expect(
        "the summary line prints the case counts",
        "accuracy summary: expected verdicts no-effect 3, needs-check 1" in text,
        text,
    )
    expect(
        "a case that answers improved wrongly is listed",
        "expected a verdict other than improved but got improved: b" in text,
        text,
    )
    expect(
        "a known-wrong case that answers improved is listed apart",
        "known-wrong cases that answer improved: c (https://example.test/1), d (https://example.test/2)" in text,
        text,
    )
    expect("a known-wrong case that answers improved fails the run", total == 3, total)
    expect(
        "the last line counts the improved failures once",
        "accuracy: 3 failure(s), 2 known-wrong case(s), 0 cases, repeat 3, root=/root" in text,
        text,
    )

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        quiet = checker.summarize("/root", [], 3, 0, 0, rows[0:1])
    expect("a run without failures and without improvements is ok", quiet == 0, quiet)
    quiet_text = buffer.getvalue()
    expect("the quiet run ends with ok", "accuracy: ok (0 cases, repeat 3, root=/root)" in quiet_text, quiet_text)


def column_tests(checker) -> None:
    single = checker.index_columns("CREATE INDEX x ON events(customer_id);")
    expect("a single column is read", single == ["customer_id"], single)
    decorated = checker.index_columns("CREATE INDEX x ON events(a, b COLLATE NOCASE DESC);")
    expect("a collation and a direction are dropped", decorated == ["a", "b"], decorated)
    expression = checker.index_columns("CREATE INDEX x ON events(lower(name));")
    expect("an expression is kept", expression == ["lower(name)"], expression)
    quoted = checker.index_columns('CREATE INDEX x ON events("customer_id");')
    expect("a quoted column is unquoted", quoted == ["customer_id"], quoted)
    try:
        checker.index_columns("CREATE INDEX x ON events")
    except checker.Unusable as error:
        expect("an index without columns is refused", "cannot read" in str(error), str(error))
    else:
        expect("an index without columns is refused", False, "no error")


def observation_tests(checker) -> None:
    plain = observation(checker, report=comparison())
    expect("a comparison report is read", plain["comparison"] is not None and plain["batch"] is None, plain)
    report = batch_report(recommended="migration.sql", results=[{"comparison": comparison()}])
    batch = observation(checker, batch=report)
    expect("a batch comparison is read", batch["batch"] is not None and batch["comparison"] is not None, batch)
    expect("a batch report keeps its comparison count", len(batch["comparisons"]) == 1, batch["comparisons"])

    error = observation(checker, error={"code": "no_candidates", "message": "none", "hint": "add one"}, exit_code=1)
    expect("an error object is read from stderr", error["error"] is not None and error["exit_code"] is None, error)

    try:
        checker.observation_from(subprocess.CompletedProcess(["qenome"], 0, "{", ""))
    except checker.Unusable as broken:
        expect("a broken JSON report is unusable", "not JSON" in str(broken), str(broken))
    else:
        expect("a broken JSON report is unusable", False, "no error")
    try:
        checker.observation_from(subprocess.CompletedProcess(["qenome"], 0, "[]", ""))
    except checker.Unusable as array:
        expect("a JSON array report is unusable", "one JSON object" in str(array), str(array))
    else:
        expect("a JSON array report is unusable", False, "no error")


def command_line_tests(checker) -> None:
    root = make_root()
    try:
        make_case(root, "plain", with_case(document()))
        unknown = checker.main(["check_accuracy.py", "--unknown"])
        expect("an unknown argument is refused", unknown == 2, unknown)
        missing = checker.main(["check_accuracy.py", "--case"])
        expect("a missing option value is refused", missing == 2, missing)
        zero = checker.main(["check_accuracy.py", "--repeat", "0"])
        expect("a repeat of zero is refused", zero == 2, zero)
        word = checker.main(["check_accuracy.py", "--repeat", "many"])
        expect("a non-number repeat is refused", word == 2, word)
        no_root = checker.main(["check_accuracy.py", "--root", os.path.join(root, "nope")])
        expect("a missing root is refused", no_root == 2, no_root)
        small = checker.main(["check_accuracy.py", "--root", root])
        expect("a root with too few cases is refused", small == 2, small)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    try:
        checker.binary_path(ROOT, "/nonexistent/qenome")
    except checker.Unusable as missing_binary:
        expect("a missing binary is unusable", "no binary" in str(missing_binary), str(missing_binary))
    else:
        expect("a missing binary is unusable", False, "no error")
    try:
        checker.binary_path(tempfile.gettempdir(), None)
    except checker.Unusable as unbuilt:
        expect("a missing default binary is unusable", "zig build" in str(unbuilt), str(unbuilt))
    else:
        expect("a missing default binary is unusable", False, "no error")
    accepted = checker.binary_path(ROOT, CHECKER) == os.path.abspath(CHECKER)
    expect("an existing binary is accepted", accepted, "rejected")

    cases = checker.load_corpus(ROOT)
    names = [case.name for case in cases]
    expect("the corpus holds at least 20 cases", len(cases) >= checker.MINIMUM_CASES, len(cases))
    expect("every corpus case has a unique name", len(names) == len(set(names)), names)
    expect("every corpus case holds a check", all(case.expect for case in cases), names)
    for case in cases:
        schema = os.path.join(case.path, "schema.sql")
        expect("the corpus case has a schema: " + case.name, os.path.isfile(schema), case.path)
    absent = checker.main(["check_accuracy.py", "--case", "no-such-case"])
    expect("an unknown corpus case is refused", absent == 2, absent)


def main() -> int:
    checker = load_checker()
    parser_tests(checker)
    parser_value_tests(checker)
    expectation_tests(checker)
    repeat_tests(checker)
    effect_tests(checker)
    timing_tests(checker)
    judge_tests(checker)
    run_output_tests(checker)
    human_tests(checker)
    summary_tests(checker)
    column_tests(checker)
    observation_tests(checker)
    command_line_tests(checker)
    return finish("ok")


if __name__ == "__main__":
    sys.exit(main())
