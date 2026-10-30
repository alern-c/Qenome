import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
CORPUS_DIR = os.path.join("testdata", "accuracy")
DEFAULT_REPEAT = 3
MAX_REPEAT = 100
MINIMUM_CASES = 20
DEFAULT_TIMEOUT = 600

CASE_KEYS = ("description", "args", "expect", "known_wrong", "timing")
EXPECT_KEYS = (
    "exit",
    "exit_code",
    "result",
    "verdict",
    "plan_changed",
    "baseline_plan",
    "variant_plan",
    "rows_read",
    "rows_written",
    "warnings",
    "batch",
    "suggest",
    "error",
)
PLAN_KEYS = ("contains", "excludes")
ROWS_KEYS = ("direction", "max_ratio")
WARNING_KEYS = ("contains", "excludes")
BATCH_KEYS = ("recommended", "counts")
SUGGEST_KEYS = ("recommended", "leads_with")
ERROR_KEYS = ("code",)
COUNT_KEYS = (
    "improved",
    "no_effect",
    "needs_check",
    "mismatch",
    "incomparable",
    "timeout",
    "not_judged",
)
COUNTER_KEYS = (
    "rows_read",
    "rows_written",
    "fullscan_steps",
    "vm_steps",
    "sort_ops",
    "autoindex_rows",
)
RESULT_VALUES = ("match", "mismatch", "incomparable")
VERDICT_VALUES = ("improved", "no-effect", "needs-check", "regressed", "not-judged")
DIRECTIONS = ("decrease", "same", "increase")
EFFECTS = ("faster", "slower", "no-difference", "insufficient-samples")
HARNESS_OPTIONS = (
    "--format",
    "--db",
    "--d1",
    "--batch",
    "--write",
    "--index-sql",
    "--migration",
    "--seed-data",
)
COMPARISON_KEYS = (
    "result",
    "verdict",
    "plan_changed",
    "baseline_plan",
    "variant_plan",
    "rows_read",
    "rows_written",
    "warnings",
)
COLUMN_SPLIT = re.compile(r",(?![^()]*\))")
LEADING_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class Unusable(Exception):
    pass


class Case:
    __slots__ = ("name", "path", "mode", "args", "expect", "known_wrong", "timing")

    def __init__(self, name, path, mode, args, expect, known_wrong, timing):
        self.name = name
        self.path = path
        self.mode = mode
        self.args = args
        self.expect = expect
        self.known_wrong = known_wrong
        self.timing = timing

    def argv(self, binary):
        argv = [binary, "db.sqlite"]
        if self.mode == "batch":
            argv += ["--batch", "batch.json"]
            if os.path.isfile(os.path.join(self.path, "migration.sql")):
                argv += ["--migration", "migration.sql"]
        elif self.mode == "write":
            argv += ["--write", "write.sql", "--index-sql", "index.sql"]
        elif self.mode == "suggest":
            argv += ["select.sql"]
        else:
            argv += ["select.sql", "index.sql"]
        if os.path.isfile(os.path.join(self.path, "seed.json")):
            argv += ["--seed-data", "seed.json"]
        argv += self.args
        if self.mode in ("compare", "write") and not has_option(self.args, "--runs"):
            argv += ["--runs", "0"]
        argv += ["--format", "json"]
        return argv

    def timing_runs(self):
        raw = option_value(self.args, "--runs")
        if raw is None:
            raise Unusable(self.name + ': "timing": "stable" needs --runs in args')
        try:
            run_count = int(raw)
        except ValueError:
            raise Unusable(self.name + ": --runs value is not a whole number: " + raw) from None
        if run_count < 6:
            raise Unusable(
                self.name
                + ": a timing case needs at least 6 --runs, because fewer rounds report insufficient-samples"
            )
        return run_count


def require(condition, message):
    if not condition:
        raise Unusable(message)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise Unusable("cannot read " + path + ": " + str(error)) from None


def load_json(path):
    text = read_text(path)
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise Unusable("cannot parse " + path + ": " + str(error)) from None


def list_entries(path):
    try:
        return sorted(os.listdir(path))
    except OSError as error:
        raise Unusable("cannot list " + path + ": " + str(error)) from None


def unknown_keys(name, value, allowed):
    unknown = sorted(set(value) - set(allowed))
    if unknown:
        raise Unusable(name + ": unknown key(s): " + ", ".join(unknown) + "; allowed: " + ", ".join(allowed))


def check_string_list(name, value):
    require(isinstance(value, list), name + " must be an array of strings")
    for item in value:
        require(isinstance(item, str) and bool(item), name + " must hold non-empty strings")
        require("\n" not in item, name + " must hold one-line strings")
    return value


def check_plan(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, PLAN_KEYS)
    result = {}
    for key in PLAN_KEYS:
        if key in value:
            result[key] = check_string_list(name + "." + key, value[key])
    require(result, name + " needs contains or excludes")
    return result


def check_rows(name, value):
    if isinstance(value, str):
        value = {"direction": value}
    require(isinstance(value, dict), name + " must be a direction or an object")
    unknown_keys(name, value, ROWS_KEYS)
    require("direction" in value, name + " needs a direction")
    direction = value["direction"]
    require(direction in DIRECTIONS, name + " direction must be one of: " + ", ".join(DIRECTIONS))
    result = {"direction": direction}
    raw = value.get("max_ratio")
    if raw is not None:
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            raise Unusable(name + ".max_ratio must be a number")
        if raw <= 0:
            raise Unusable(name + ".max_ratio must be greater than 0")
        result["max_ratio"] = raw
    return result


def check_warnings(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, WARNING_KEYS)
    result = {}
    for key in WARNING_KEYS:
        if key in value:
            result[key] = check_string_list(name + "." + key, value[key])
    require(result, name + " needs contains or excludes")
    return result


def check_batch(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, BATCH_KEYS)
    result = {}
    recommended = value.get("recommended")
    if "recommended" in value:
        if recommended is not None:
            if not isinstance(recommended, str) or not recommended:
                raise Unusable(name + ".recommended must be a non-empty string or null")
        result["recommended"] = recommended
    if "counts" in value:
        counts = value["counts"]
        require(isinstance(counts, dict), name + ".counts must be an object")
        unknown_keys(name + ".counts", counts, COUNT_KEYS)
        for key, count in counts.items():
            if isinstance(count, bool) or not isinstance(count, int):
                raise Unusable(name + ".counts." + key + " must be a whole number")
            if count < 0:
                raise Unusable(name + ".counts." + key + " must not be negative")
        result["counts"] = counts
    require(result, name + " needs recommended or counts")
    return result


def check_suggest(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, SUGGEST_KEYS)
    result = {}
    if "recommended" in value:
        if not isinstance(value["recommended"], bool):
            raise Unusable(name + ".recommended must be true or false")
        result["recommended"] = value["recommended"]
    if "leads_with" in value:
        result["leads_with"] = check_string_list(name + ".leads_with", value["leads_with"])
    require(result, name + " needs recommended or leads_with")
    return result


def check_error(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, ERROR_KEYS)
    require("code" in value, name + " needs a code")
    code = value["code"]
    require(isinstance(code, str) and bool(code), name + ".code must be a non-empty string")
    return {"code": code}


def load_expect(case_name, value):
    require(isinstance(value, dict), case_name + ": expect must be an object")
    unknown_keys(case_name + ": expect", value, EXPECT_KEYS)
    result = {}

    def whole(key):
        raw = value[key]
        if isinstance(raw, bool) or not isinstance(raw, int):
            raise Unusable(case_name + ": expect." + key + " must be a whole number")
        result[key] = raw

    if "exit" in value:
        whole("exit")
    if "exit_code" in value:
        whole("exit_code")
    if "result" in value:
        require(
            value["result"] in RESULT_VALUES,
            case_name + ": expect.result must be one of: " + ", ".join(RESULT_VALUES),
        )
        result["result"] = value["result"]
    if "verdict" in value:
        require(
            value["verdict"] in VERDICT_VALUES,
            case_name + ": expect.verdict must be one of: " + ", ".join(VERDICT_VALUES),
        )
        result["verdict"] = value["verdict"]
    if "plan_changed" in value:
        require(isinstance(value["plan_changed"], bool), case_name + ": expect.plan_changed must be true or false")
        result["plan_changed"] = value["plan_changed"]
    for key in ("baseline_plan", "variant_plan"):
        if key in value:
            result[key] = check_plan(case_name + ": expect." + key, value[key])
    for key in ("rows_read", "rows_written"):
        if key in value:
            result[key] = check_rows(case_name + ": expect." + key, value[key])
    if "warnings" in value:
        result["warnings"] = check_warnings(case_name + ": expect.warnings", value["warnings"])
    if "batch" in value:
        result["batch"] = check_batch(case_name + ": expect.batch", value["batch"])
    if "suggest" in value:
        result["suggest"] = check_suggest(case_name + ": expect.suggest", value["suggest"])
    if "error" in value:
        result["error"] = check_error(case_name + ": expect.error", value["error"])
    require(result, case_name + ": expect holds no check")
    return result


def has_option(args, name):
    for arg in args:
        if arg == name or arg.startswith(name + "="):
            return True
    return False


def option_value(args, name):
    for index, arg in enumerate(args):
        if arg == name:
            if index + 1 >= len(args):
                raise Unusable("args: " + name + " needs a value")
            return args[index + 1]
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return None


def case_mode(case_dir, args):
    has_batch = os.path.isfile(os.path.join(case_dir, "batch.json"))
    has_write = os.path.isfile(os.path.join(case_dir, "write.sql"))
    has_index = os.path.isfile(os.path.join(case_dir, "index.sql"))
    has_select = os.path.isfile(os.path.join(case_dir, "select.sql"))
    suggest = has_option(args, "--suggest")
    if has_batch:
        require(not has_write, "a batch case must not have write.sql")
        require(not has_index, "a batch case must not have index.sql; the manifest names the candidates")
        return "batch"
    if has_write:
        require(not has_select, "a write case must not have select.sql")
        return "write"
    if suggest:
        require(not has_index, "a --suggest case must not have index.sql")
        return "suggest"
    return "compare"


def load_case(root, name):
    case_dir = os.path.join(root, CORPUS_DIR, name)
    require(os.path.isdir(case_dir), "there is no case directory at " + case_dir)
    path = os.path.join(case_dir, "case.json")
    require(os.path.isfile(path), "there is no case.json at " + path)
    document = load_json(path)
    require(isinstance(document, dict), "case.json must hold one object: " + path)
    unknown_keys(name + ": case.json", document, CASE_KEYS)
    require("description" in document, name + ": case.json needs a description")
    description = document["description"]
    require(isinstance(description, str) and bool(description), name + ": description must be a non-empty string")
    require("\n" not in description, name + ": description must be one line")
    require("args" in document, name + ": case.json needs args (use an empty array)")
    args = document["args"]
    require(isinstance(args, list), name + ": args must be an array")
    for arg in args:
        require(isinstance(arg, str) and bool(arg), name + ": args must hold non-empty strings")
    require("expect" in document, name + ": case.json needs expect")
    expect = load_expect(name, document["expect"])
    known_wrong = document.get("known_wrong")
    if known_wrong is not None:
        require(
            isinstance(known_wrong, str) and bool(known_wrong.strip()),
            name + ": known_wrong must be an issue link",
        )
    timing = document.get("timing")
    if timing is not None:
        require(timing in ("stable",), name + ': timing must be "stable"')
    for option in HARNESS_OPTIONS:
        require(not has_option(args, option), name + ": args must not hold " + option + "; the harness passes it")
    mode = case_mode(case_dir, args)
    case = Case(name, case_dir, mode, list(args), expect, known_wrong, timing)
    check_files(case)
    return case


def check_files(case):
    directory = case.path
    require(os.path.isfile(os.path.join(directory, "schema.sql")), case.name + ": there is no schema.sql")
    has_data = os.path.isfile(os.path.join(directory, "data.sql"))
    has_seed = os.path.isfile(os.path.join(directory, "seed.json"))
    require(not (has_data and has_seed), case.name + ": a case holds data.sql or seed.json, not both")
    if case.mode in ("compare", "suggest"):
        require(os.path.isfile(os.path.join(directory, "select.sql")), case.name + ": there is no select.sql")
    if case.mode in ("compare", "write"):
        require(os.path.isfile(os.path.join(directory, "index.sql")), case.name + ": there is no index.sql")
    if case.mode == "batch":
        check_manifest(case)
    else:
        require(
            not os.path.isfile(os.path.join(directory, "migration.sql")),
            case.name + ": migration.sql needs batch.json",
        )
    if has_option(case.args, "--bind"):
        require(case.mode != "batch", case.name + ": a batch case puts the binds in batch.json, not in args")
    if case.timing is not None:
        require(case.mode == "compare", case.name + ': "timing": "stable" needs a single SELECT comparison')
        case.timing_runs()
    elif has_option(case.args, "--runs"):
        raise Unusable(case.name + ": args must not hold --runs; only a timing case sets it")


def check_manifest(case):
    manifest = load_json(os.path.join(case.path, "batch.json"))
    require(isinstance(manifest, dict), case.name + ": batch.json must hold one object")
    queries = manifest.get("queries")
    require(isinstance(queries, list) and bool(queries), case.name + ": batch.json needs a non-empty queries array")
    has_migration = os.path.isfile(os.path.join(case.path, "migration.sql"))
    candidates = manifest.get("candidates")
    for query in queries:
        require(isinstance(query, dict), case.name + ": every queries entry must be an object")
        select = query.get("select")
        require(isinstance(select, str) and bool(select), case.name + ": every queries entry needs a select path")
        require(
            os.path.isfile(os.path.join(case.path, select)),
            case.name + ": batch.json names a missing select file: " + select,
        )
    if candidates is not None:
        require(isinstance(candidates, list), case.name + ": candidates must be an array")
        for candidate in candidates:
            require(isinstance(candidate, dict), case.name + ": every candidates entry must be an object")
            index_sql = candidate.get("index_sql")
            require(
                isinstance(index_sql, str) and bool(index_sql),
                case.name + ": every candidates entry needs an index_sql path",
            )
            require(
                os.path.isfile(os.path.join(case.path, index_sql)),
                case.name + ": batch.json names a missing index file: " + index_sql,
            )
    if has_migration:
        require(candidates is None or candidates == [], case.name + ": a --migration manifest must omit candidates")
    else:
        require(candidates is not None, case.name + ": batch.json needs candidates without --migration")


def case_names(root):
    catalog = os.path.join(root, CORPUS_DIR)
    require(os.path.isdir(catalog), "there is no corpus directory at " + catalog)
    names = []
    for entry in list_entries(catalog):
        path = os.path.join(catalog, entry)
        if not os.path.isdir(path):
            continue
        require(os.path.isfile(os.path.join(path, "case.json")), "the case directory has no case.json: " + path)
        names.append(entry)
    require(names, "there is no case directory under " + catalog)
    return names


def load_corpus(root):
    return [load_case(root, name) for name in case_names(root)]


def binary_path(root, override):
    if override is not None:
        path = os.path.abspath(override)
        require(os.path.isfile(path), "there is no binary at " + path)
        return path
    name = "qenome.exe" if os.name == "nt" else "qenome"
    path = os.path.join(root, "zig-out", "bin", name)
    require(os.path.isfile(path), "there is no built binary at " + path + "; run zig build first")
    return path


def observation_from(done):
    observation = {
        "exit": done.returncode,
        "exit_code": None,
        "batch": None,
        "comparison": None,
        "comparisons": [],
        "error": None,
    }
    stdout = done.stdout.strip()
    if stdout:
        try:
            report = json.loads(stdout)
        except json.JSONDecodeError as error:
            raise Unusable("the report is not JSON: " + str(error)) from None
        if not isinstance(report, dict):
            raise Unusable("the report is not one JSON object")
        observation["exit_code"] = report.get("exit_code")
        if "batch_schema_version" in report:
            observation["batch"] = report
            comparisons = []
            for result in report.get("results") or []:
                if isinstance(result, dict) and isinstance(result.get("comparison"), dict):
                    comparisons.append(result["comparison"])
            observation["comparisons"] = comparisons
            if len(comparisons) == 1:
                observation["comparison"] = comparisons[0]
        else:
            observation["comparison"] = report
            observation["comparisons"] = [report]
    for line in done.stderr.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            report = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(report, dict) and isinstance(report.get("error"), dict):
            observation["error"] = report
    return observation


def fail_messages(expect, observation):
    failures = []
    if [key for key in COMPARISON_KEYS if key in expect]:
        comparison = observation["comparison"]
        if comparison is None:
            if not observation["comparisons"]:
                return ["there is no comparison object in the report"]
            return [
                "the report holds "
                + str(len(observation["comparisons"]))
                + " comparison objects; the case checks exactly one"
            ]
        failures += comparison_failures(expect, comparison)
    if "exit" in expect and observation["exit"] != expect["exit"]:
        failures.append("exit is " + str(observation["exit"]) + ", expected " + str(expect["exit"]))
    if "exit_code" in expect and observation["exit_code"] != expect["exit_code"]:
        failures.append(
            "the report exit_code is "
            + str(observation["exit_code"])
            + ", expected "
            + str(expect["exit_code"])
        )
    if "batch" in expect:
        failures += batch_failures(expect["batch"], observation["batch"])
    if "suggest" in expect:
        failures += suggest_failures(expect["suggest"], observation["batch"])
    if "error" in expect:
        failures += error_failures(expect["error"], observation["error"])
    return failures


def comparison_failures(expect, comparison):
    failures = []
    for key in ("result", "verdict", "plan_changed"):
        if key in expect and comparison.get(key) != expect[key]:
            failures.append(
                key + " is " + json.dumps(comparison.get(key)) + ", expected " + json.dumps(expect[key])
            )
    for key in ("baseline_plan", "variant_plan"):
        if key in expect:
            failures += plan_failures(key, comparison.get(key[: -len("_plan")]), expect[key])
    for key in ("rows_read", "rows_written"):
        if key in expect:
            failures += rows_failures(key, comparison, expect[key])
    if "warnings" in expect:
        failures += warning_failures(comparison.get("warnings"), expect["warnings"])
    return failures


def plan_details(side):
    if not isinstance(side, dict):
        return []
    details = []
    for step in side.get("plan") or []:
        if isinstance(step, dict):
            details.append(str(step.get("detail", "")))
    return details


def plan_failures(name, side, spec):
    details = plan_details(side)
    failures = []
    for needle in spec.get("contains", []):
        if not any(needle in detail for detail in details):
            failures.append(
                name + " has no step with " + json.dumps(needle) + "; steps: " + json.dumps(details)
            )
    for needle in spec.get("excludes", []):
        for detail in details:
            if needle in detail:
                failures.append(
                    name + " has a step with " + json.dumps(needle) + ": " + json.dumps(detail)
                )
                break
    return failures


def rows_failures(name, comparison, spec):
    baseline = comparison.get("baseline")
    variant = comparison.get("variant")
    if not isinstance(baseline, dict) or not isinstance(variant, dict):
        return [name + " needs both baseline and variant objects"]
    before = (baseline.get("counters") or {}).get(name)
    after = (variant.get("counters") or {}).get(name)
    if not isinstance(before, int) or not isinstance(after, int):
        return [name + " is not a number on both sides"]
    direction = "same"
    if after < before:
        direction = "decrease"
    elif after > before:
        direction = "increase"
    failures = []
    if direction != spec["direction"]:
        failures.append(
            name
            + " is "
            + str(after)
            + " (variant) and "
            + str(before)
            + " (baseline), expected a "
            + spec["direction"]
        )
    max_ratio = spec.get("max_ratio")
    if max_ratio is not None:
        if before <= 0:
            failures.append(name + " max_ratio needs a baseline above 0")
        elif after / before > max_ratio:
            failures.append(
                name
                + " ratio is "
                + str(round(after / before, 6))
                + " (variant "
                + str(after)
                + " / baseline "
                + str(before)
                + "), at most "
                + str(max_ratio)
            )
    return failures


def warning_failures(warnings, spec):
    codes = []
    for warning in warnings or []:
        if isinstance(warning, dict):
            codes.append(str(warning.get("code", "")))
    failures = []
    for code in spec.get("contains", []):
        if code not in codes:
            failures.append("the warnings have no " + code + "; codes: " + json.dumps(codes))
    for code in spec.get("excludes", []):
        if code in codes:
            failures.append("the warnings hold " + code)
    return failures


def batch_failures(spec, batch):
    if not isinstance(batch, dict):
        return ["there is no batch report"]
    failures = []
    if "recommended" in spec and batch.get("recommended") != spec["recommended"]:
        failures.append(
            "recommended is "
            + json.dumps(batch.get("recommended"))
            + ", expected "
            + json.dumps(spec["recommended"])
        )
    counts = spec.get("counts")
    if counts is not None:
        summary = batch.get("summary")
        if not isinstance(summary, list) or not summary or not isinstance(summary[0], dict):
            failures.append("the batch report has no first summary entry")
            return failures
        entry = summary[0]
        for key, count in counts.items():
            if entry.get(key) != count:
                failures.append(
                    "summary[0]." + key + " is " + json.dumps(entry.get(key)) + ", expected " + str(count)
                )
    return failures


def index_columns(sql):
    text = sql.strip()
    start = text.find("(")
    if start < 0:
        raise Unusable("cannot read the index columns from " + json.dumps(sql))
    depth = 0
    end = -1
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                end = index
                break
    if end < 0:
        raise Unusable("cannot read the index columns from " + json.dumps(sql))
    columns = []
    for part in COLUMN_SPLIT.split(text[start + 1 : end]):
        item = part.strip()
        if not item:
            continue
        if item[0] in '"`[':
            closing = {'"': '"', "`": "`", "[": "]"}[item[0]]
            stop = item.find(closing, 1)
            if stop > 0:
                columns.append(item[1:stop].lower())
                continue
        word = item.split()[0]
        if LEADING_IDENTIFIER.match(word):
            columns.append(word.lower())
        else:
            columns.append(item.lower())
    return columns


def suggest_failures(spec, batch):
    if not isinstance(batch, dict):
        return ["there is no batch report"]
    failures = []
    recommended = batch.get("recommended")
    if "recommended" in spec:
        if spec["recommended"] and not (isinstance(recommended, str) and recommended.startswith("suggested:")):
            failures.append("recommended is " + json.dumps(recommended) + ", expected a suggested index")
        if not spec["recommended"] and recommended is not None:
            failures.append("recommended is " + json.dumps(recommended) + ", expected null")
    leads_with = spec.get("leads_with")
    if leads_with is not None:
        if not isinstance(recommended, str):
            failures.append("there is no recommended index to read the columns from")
            return failures
        entry = None
        for summary in batch.get("summary") or []:
            if isinstance(summary, dict) and summary.get("candidate") == recommended:
                entry = summary
                break
        if entry is None:
            failures.append("the summary names no candidate " + json.dumps(recommended))
            return failures
        sql = entry.get("index_sql_text")
        if not isinstance(sql, str):
            failures.append("the summary entry has no index_sql_text")
            return failures
        columns = index_columns(sql)
        expected = [column.lower() for column in leads_with]
        if columns[: len(expected)] != expected:
            failures.append(
                "the suggested index leads with "
                + json.dumps(columns[: len(expected)])
                + ", expected "
                + json.dumps(expected)
            )
    return failures


def error_failures(spec, error):
    if not isinstance(error, dict):
        return ["there is no error object on stderr"]
    code = (error.get("error") or {}).get("code")
    if code != spec["code"]:
        return ["the error code is " + json.dumps(code) + ", expected " + json.dumps(spec["code"])]
    return []


def comparison_signature(comparison):
    result = {}
    for key in ("result", "verdict", "plan_changed"):
        result[key] = comparison.get(key)
    for side in ("baseline", "variant"):
        value = comparison.get(side)
        if not isinstance(value, dict):
            result[side] = None
            continue
        result[side + ".plan"] = plan_details(value)
        counters = value.get("counters")
        if isinstance(counters, dict):
            result[side + ".counters"] = {key: counters.get(key) for key in COUNTER_KEYS}
        else:
            result[side + ".counters"] = None
    return result


def summary_signature(batch):
    summary = batch.get("summary")
    if not isinstance(summary, list):
        return None
    entries = []
    for entry in summary:
        if not isinstance(entry, dict):
            entries.append(None)
            continue
        entries.append(
            {
                "candidate": entry.get("candidate"),
                "counts": {key: entry.get(key) for key in COUNT_KEYS},
            }
        )
    return entries


def signature(observation):
    result = {"exit": observation["exit"], "exit_code": observation["exit_code"]}
    if isinstance(observation["error"], dict):
        result["error.code"] = (observation["error"].get("error") or {}).get("code")
    result["comparisons"] = [comparison_signature(comparison) for comparison in observation["comparisons"]]
    batch = observation["batch"]
    if isinstance(batch, dict):
        result["recommended"] = batch.get("recommended")
        result["summary"] = summary_signature(batch)
    return result


def first_difference(left, right, path=""):
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            child = path + "." + key if path else key
            if key not in left or key not in right:
                return child, left.get(key), right.get(key)
            found = first_difference(left[key], right[key], child)
            if found is not None:
                return found
        return None
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            return path + " (length)", len(left), len(right)
        for index, pair in enumerate(zip(left, right)):
            found = first_difference(pair[0], pair[1], path + "[" + str(index) + "]")
            if found is not None:
                return found
        return None
    if left != right:
        return path, left, right
    return None


def repeat_failures(first, later, later_number):
    difference = first_difference(signature(first), signature(later))
    if difference is None:
        return []
    path, left, right = difference
    return [
        "run 1 and run "
        + str(later_number)
        + " differ at "
        + (path or "the report")
        + ": "
        + json.dumps(left)
        + " and "
        + json.dumps(right)
    ]


def timing_failures(observations):
    effects = []
    for number, observation in enumerate(observations, 1):
        comparison = observation["comparison"]
        timing = comparison.get("timing") if isinstance(comparison, dict) else None
        effect = timing.get("effect") if isinstance(timing, dict) else None
        if effect not in EFFECTS:
            return ["run " + str(number) + " has no timing effect; it is " + json.dumps(effect)]
        effects.append(effect)
    directions = {effect for effect in effects if effect in ("faster", "slower")}
    if len(directions) > 1:
        return ["the timing effect flips between faster and slower: " + ", ".join(effects)]
    return []


def judge(name, case_expect, known_wrong, timing, observations):
    per_run = [fail_messages(case_expect, observation) for observation in observations]
    failures = []
    for number, run_failures in enumerate(per_run, 1):
        for failure in run_failures:
            failures.append("run " + str(number) + ": " + failure)
    stability = []
    for number in range(1, len(observations)):
        stability += repeat_failures(observations[0], observations[number], number + 1)
    if timing is not None:
        stability += timing_failures(observations)
    passing = [number for number, run_failures in enumerate(per_run, 1) if not run_failures]
    if known_wrong is not None:
        if len(passing) == len(observations):
            return "FAIL", "the case passes now; remove known_wrong (" + known_wrong + ")"
        if passing or stability:
            details = []
            if passing:
                details.append("the case passes in run(s) " + ", ".join(str(number) for number in passing))
            details += stability
            return "FAIL", "the known-wrong case is not stable: " + " ; ".join(details[:5])
        return "known-wrong", failures[0] + " (" + known_wrong + ")"
    if not failures:
        failures = stability
    if failures:
        return "FAIL", " ; ".join(failures[:5])
    return "ok", name


def copy_case_files(case, directory):
    for entry in list_entries(case.path):
        source = os.path.join(case.path, entry)
        if entry == "case.json" or not os.path.isfile(source):
            continue
        try:
            shutil.copyfile(source, os.path.join(directory, entry))
        except OSError as error:
            raise Unusable(case.name + ": cannot copy " + entry + ": " + str(error)) from None


def build_database(case, directory):
    schema = read_text(os.path.join(directory, "schema.sql"))
    data_path = os.path.join(directory, "data.sql")
    data = read_text(data_path) if os.path.isfile(data_path) else None
    database = os.path.join(directory, "db.sqlite")
    try:
        if os.path.exists(database):
            os.remove(database)
    except OSError as error:
        raise Unusable(case.name + ": cannot replace " + database + ": " + str(error)) from None
    try:
        connection = sqlite3.connect(database)
    except sqlite3.Error as error:
        raise Unusable(case.name + ": cannot create the database: " + str(error)) from None
    try:
        connection.executescript(schema)
        if data is not None:
            connection.executescript(data)
        connection.commit()
    except sqlite3.Error as error:
        raise Unusable(case.name + ": cannot build the database: " + str(error)) from None
    finally:
        connection.close()
    return database


def run_case(case, repeat, binary, work_parent):
    try:
        directory = tempfile.mkdtemp(prefix="case-", dir=work_parent)
    except OSError as error:
        raise Unusable("cannot create a work directory: " + str(error)) from None
    copy_case_files(case, directory)
    build_database(case, directory)
    env = dict(os.environ)
    env["TMPDIR"] = work_parent
    env["TMP"] = work_parent
    env["TEMP"] = work_parent
    argv = case.argv(binary)
    observations = []
    for _ in range(repeat):
        try:
            done = subprocess.run(
                argv,
                cwd=directory,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                timeout=DEFAULT_TIMEOUT,
                stdin=subprocess.DEVNULL,
            )
        except OSError as error:
            raise Unusable("cannot run " + binary + ": " + str(error)) from None
        except subprocess.TimeoutExpired:
            raise Unusable(
                case.name + ": qenome did not finish within " + str(DEFAULT_TIMEOUT) + " seconds: " + " ".join(argv)
            ) from None
        observations.append(observation_from(done))
    return judge(case.name, case.expect, case.known_wrong, case.timing, observations)


def run(root, cases, repeat, binary):
    try:
        work_parent = tempfile.mkdtemp(prefix="qenome-accuracy-")
    except OSError as error:
        raise Unusable("cannot create the work parent: " + str(error)) from None
    failures = 0
    known_wrong = 0
    try:
        for case in cases:
            status, message = run_case(case, repeat, binary, work_parent)
            if status == "ok":
                print("ok " + case.name, flush=True)
            elif status == "known-wrong":
                known_wrong += 1
                print("known-wrong " + case.name + ": " + message, flush=True)
            else:
                failures += 1
                print("FAIL " + case.name + ": " + message, flush=True)
    finally:
        shutil.rmtree(work_parent, ignore_errors=True)
    return failures, known_wrong


def summarize(root, cases, repeat, failures, known_wrong):
    if known_wrong:
        print(
            "accuracy: "
            + str(failures)
            + " failure(s), "
            + str(known_wrong)
            + " known-wrong case(s), "
            + str(len(cases))
            + " cases, repeat "
            + str(repeat)
            + ", root="
            + root
        )
    elif failures == 0:
        print(
            "accuracy: ok ("
            + str(len(cases))
            + " cases, repeat "
            + str(repeat)
            + ", root="
            + root
            + ")"
        )
    else:
        print("accuracy: " + str(failures) + " failure(s), root=" + root)


def usage():
    sys.stderr.write(
        "usage: python3 scripts/check_accuracy.py [--root DIR] [--case NAME] [--repeat N] [--binary PATH]\n"
    )


def main(argv):
    root = None
    name = None
    repeat_raw = str(DEFAULT_REPEAT)
    binary = None
    rest = argv[1:]
    while rest:
        head = rest[0]
        if head in ("--root", "--case", "--repeat", "--binary"):
            if len(rest) < 2:
                usage()
                return 2
            value = rest[1]
            rest = rest[2:]
            if head == "--root":
                root = value
            elif head == "--case":
                name = value
            elif head == "--repeat":
                repeat_raw = value
            else:
                binary = value
        else:
            usage()
            return 2
    if root is None:
        root = DEFAULT_ROOT
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write("accuracy: not a directory: " + root + "\n")
        return 2
    try:
        try:
            repeat = int(repeat_raw)
        except ValueError:
            raise Unusable("--repeat needs a whole number: " + repeat_raw) from None
        if repeat < 1 or repeat > MAX_REPEAT:
            raise Unusable("--repeat must be from 1 to " + str(MAX_REPEAT))
        all_cases = load_corpus(root)
        if len(all_cases) < MINIMUM_CASES:
            raise Unusable(
                "the corpus holds "
                + str(len(all_cases))
                + " cases; at least "
                + str(MINIMUM_CASES)
                + " are expected"
            )
        if name is not None:
            cases = [case for case in all_cases if case.name == name]
            if not cases:
                raise Unusable("there is no case named " + name)
        else:
            cases = all_cases
        binary = binary_path(root, binary)
    except Unusable as error:
        sys.stderr.write("accuracy: " + str(error) + "\n")
        return 2
    try:
        failures, known_wrong = run(root, cases, repeat, binary)
    except Unusable as error:
        sys.stderr.write("accuracy: " + str(error) + "\n")
        return 2
    summarize(root, cases, repeat, failures, known_wrong)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
