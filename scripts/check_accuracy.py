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
    "effect",
    "warnings",
    "human",
    "batch",
    "suggest",
    "error",
    "writes",
    "scale",
)
PLAN_KEYS = ("contains", "excludes")
ROWS_KEYS = ("direction", "max_ratio")
WARNING_KEYS = ("contains", "excludes")
HUMAN_KEYS = ("contains", "excludes")
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
    "effect",
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

    def argv(self, binary, fmt="json"):
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
        argv += ["--format", fmt]
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
                self.name + ": a timing case needs at least 6 --runs, because fewer rounds report insufficient-samples"
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


def check_human(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, HUMAN_KEYS)
    result = {}
    for key in HUMAN_KEYS:
        if key in value:
            result[key] = check_string_list(name + "." + key, value[key])
    require(result, name + " needs contains or excludes")
    return result


def check_effect(name, value):
    if isinstance(value, str):
        value = [value]
    require(isinstance(value, list) and bool(value), name + " must be an effect or an array of effects")
    for item in value:
        require(item in EFFECTS, name + " must hold one of: " + ", ".join(EFFECTS))
    return list(value)


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


def check_comparison(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, COMPARISON_KEYS)
    result = {}
    if "result" in value:
        require(value["result"] in RESULT_VALUES, name + ".result must be one of: " + ", ".join(RESULT_VALUES))
        result["result"] = value["result"]
    if "verdict" in value:
        require(value["verdict"] in VERDICT_VALUES, name + ".verdict must be one of: " + ", ".join(VERDICT_VALUES))
        result["verdict"] = value["verdict"]
    if "plan_changed" in value:
        require(isinstance(value["plan_changed"], bool), name + ".plan_changed must be true or false")
        result["plan_changed"] = value["plan_changed"]
    for key in ("baseline_plan", "variant_plan"):
        if key in value:
            result[key] = check_plan(name + "." + key, value[key])
    for key in ("rows_read", "rows_written"):
        if key in value:
            result[key] = check_rows(name + "." + key, value[key])
    if "warnings" in value:
        result["warnings"] = check_warnings(name + ".warnings", value["warnings"])
    return result


def check_writes(name, value):
    require(isinstance(value, list) and bool(value), name + " must be a non-empty array")
    result = []
    for index, entry in enumerate(value):
        spec = check_comparison(name + "[" + str(index) + "]", entry)
        require(spec, name + "[" + str(index) + "] needs a comparison check")
        result.append(spec)
    return result


def whole_number(name, value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise Unusable(name + " must be a whole number")
    return value


def check_scale_step(name, value):
    require(isinstance(value, dict), name + " must be an object")
    comparison = {}
    extra = {}
    allowed = ("rows", "baseline_rows_read_at_most", "baseline_rows_read_at_least")
    for key, item in value.items():
        if key in COMPARISON_KEYS:
            comparison[key] = item
        elif key in allowed:
            extra[key] = whole_number(name + "." + key, item)
        else:
            raise Unusable(name + ": unknown key(s): " + key)
    result = check_comparison(name, comparison) if comparison else {}
    result.update(extra)
    require(result, name + " needs a check")
    return result


def check_scale(name, value):
    require(isinstance(value, dict), name + " must be an object")
    unknown_keys(name, value, ("steps", "grows"))
    steps = value.get("steps")
    require(isinstance(steps, list) and bool(steps), name + ".steps must be a non-empty array")
    checked = [check_scale_step(name + ".steps[" + str(index) + "]", step) for index, step in enumerate(steps)]
    result = {"steps": checked}
    if "grows" in value:
        require(value["grows"] is True, name + ".grows must be true")
        result["grows"] = True
    return result


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
    result.update(
        check_comparison(case_name + ": expect", {key: value[key] for key in COMPARISON_KEYS if key in value})
    )
    if "effect" in value:
        result["effect"] = check_effect(case_name + ": expect.effect", value["effect"])
    if "human" in value:
        result["human"] = check_human(case_name + ": expect.human", value["human"])
    if "batch" in value:
        result["batch"] = check_batch(case_name + ": expect.batch", value["batch"])
    if "suggest" in value:
        result["suggest"] = check_suggest(case_name + ": expect.suggest", value["suggest"])
    if "error" in value:
        result["error"] = check_error(case_name + ": expect.error", value["error"])
    if "writes" in value:
        result["writes"] = check_writes(case_name + ": expect.writes", value["writes"])
    if "scale" in value:
        result["scale"] = check_scale(case_name + ": expect.scale", value["scale"])
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
    if "effect" in case.expect:
        require(case.timing is not None, case.name + ': expect.effect needs "timing": "stable"')


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
    writes = manifest.get("writes")
    if writes is not None:
        require(isinstance(writes, list) and bool(writes), case.name + ": writes must be a non-empty array")
        require(has_migration, case.name + ": a manifest with writes needs --migration")
        for write in writes:
            require(isinstance(write, dict), case.name + ": every writes entry must be an object")
            path = write.get("write")
            require(isinstance(path, str) and bool(path), case.name + ": every writes entry needs a write path")
            require(
                os.path.isfile(os.path.join(case.path, path)),
                case.name + ": batch.json names a missing write file: " + path,
            )


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
        "writes": [],
        "error": None,
        "scale": None,
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
            writes = []
            for entry in report.get("writes") or []:
                if isinstance(entry, dict) and isinstance(entry.get("comparison"), dict):
                    writes.append(entry["comparison"])
            observation["writes"] = writes
        elif "scale_schema_version" in report:
            observation["scale"] = report
            comparisons = []
            for step in report.get("steps") or []:
                if isinstance(step, dict) and isinstance(step.get("comparison"), dict):
                    comparisons.append(step["comparison"])
            observation["comparisons"] = comparisons
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
    if "writes" in expect:
        failures += write_failures(expect["writes"], observation["writes"])
    if "exit" in expect and observation["exit"] != expect["exit"]:
        failures.append("exit is " + str(observation["exit"]) + ", expected " + str(expect["exit"]))
    if "exit_code" in expect and observation["exit_code"] != expect["exit_code"]:
        failures.append(
            "the report exit_code is " + str(observation["exit_code"]) + ", expected " + str(expect["exit_code"])
        )
    if "batch" in expect:
        failures += batch_failures(expect["batch"], observation["batch"])
    if "suggest" in expect:
        failures += suggest_failures(expect["suggest"], observation["batch"])
    if "error" in expect:
        failures += error_failures(expect["error"], observation["error"])
    if "scale" in expect:
        failures += scale_failures(expect["scale"], observation.get("scale"))
    return failures


def baseline_rows_read(comparison):
    if not isinstance(comparison, dict):
        return None
    baseline = comparison.get("baseline")
    if not isinstance(baseline, dict):
        return None
    counters = baseline.get("counters")
    if not isinstance(counters, dict):
        return None
    return counters.get("rows_read")


def scale_failures(spec, report):
    if not isinstance(report, dict):
        return ["there is no scale report"]
    steps = report.get("steps")
    if not isinstance(steps, list):
        return ["the scale report has no steps"]
    wanted = spec["steps"]
    if len(steps) != len(wanted):
        return ["the scale report has " + str(len(steps)) + " steps, expected " + str(len(wanted))]
    failures = []
    baselines = []
    for index, (expect, step) in enumerate(zip(wanted, steps)):
        prefix = "steps[" + str(index) + "]"
        if not isinstance(step, dict):
            failures.append(prefix + " is not an object")
            baselines.append(None)
            continue
        if "rows" in expect and step.get("rows") != expect["rows"]:
            failures.append(prefix + " rows is " + json.dumps(step.get("rows")) + ", expected " + str(expect["rows"]))
        comparison = step.get("comparison")
        if not isinstance(comparison, dict):
            failures.append(prefix + " has no comparison")
            baselines.append(None)
            continue
        failures += [prefix + ": " + failure for failure in comparison_failures(expect, comparison)]
        baseline = baseline_rows_read(comparison)
        baselines.append(baseline)
        ceiling = expect.get("baseline_rows_read_at_most")
        if ceiling is not None and (not isinstance(baseline, int) or baseline > ceiling):
            failures.append(prefix + " baseline rows_read is " + json.dumps(baseline) + ", at most " + str(ceiling))
        floor = expect.get("baseline_rows_read_at_least")
        if floor is not None and (not isinstance(baseline, int) or baseline < floor):
            failures.append(prefix + " baseline rows_read is " + json.dumps(baseline) + ", at least " + str(floor))
    if spec.get("grows"):
        first, last = baselines[0], baselines[-1]
        if not isinstance(first, int) or not isinstance(last, int):
            failures.append("baseline rows_read is not a number on the first and last steps")
        elif last < first * 10:
            failures.append(
                "baseline rows_read grows from " + str(first) + " to " + str(last) + ", expected at least 10x"
            )
    return failures


def write_failures(specs, observed):
    if len(observed) != len(specs):
        return ["the report holds " + str(len(observed)) + " write comparisons; the case checks " + str(len(specs))]
    failures = []
    for index, (spec, comparison) in enumerate(zip(specs, observed)):
        failures += ["writes[" + str(index) + "]: " + failure for failure in comparison_failures(spec, comparison)]
    return failures


def comparison_failures(expect, comparison):
    failures = []
    for key in ("result", "verdict", "plan_changed"):
        if key in expect and comparison.get(key) != expect[key]:
            failures.append(key + " is " + json.dumps(comparison.get(key)) + ", expected " + json.dumps(expect[key]))
    for key in ("baseline_plan", "variant_plan"):
        if key in expect:
            failures += plan_failures(key, comparison.get(key[: -len("_plan")]), expect[key])
    for key in ("rows_read", "rows_written"):
        if key in expect:
            failures += rows_failures(key, comparison, expect[key])
    if "warnings" in expect:
        failures += warning_failures(comparison.get("warnings"), expect["warnings"])
    return failures


def effect_samples(observations):
    samples = []
    for observation in observations:
        comparison = observation["comparison"]
        timing = comparison.get("timing") if isinstance(comparison, dict) else None
        samples.append(timing.get("effect") if isinstance(timing, dict) else None)
    return samples


def effect_failure(number, effect, allowed):
    return (
        "run "
        + str(number)
        + ": the timing effect is "
        + json.dumps(effect)
        + ", expected one of "
        + json.dumps(allowed)
    )


def effect_notice(name, outliers, allowed, total):
    runs = ", ".join("run " + str(number) + " is " + json.dumps(effect) for number, effect in outliers)
    return (
        "note "
        + name
        + ": "
        + runs
        + ", outside "
        + json.dumps(allowed)
        + "; at most half of the "
        + str(total)
        + " runs, so the effect check passes"
    )


def effect_majority(name, expect, observations):
    allowed = expect.get("effect")
    if allowed is None:
        return [], None
    outliers = [
        (number, effect) for number, effect in enumerate(effect_samples(observations), 1) if effect not in allowed
    ]
    if not outliers:
        return [], None
    if len(outliers) * 2 > len(observations):
        return [effect_failure(number, effect, allowed) for number, effect in outliers], None
    return [], effect_notice(name, outliers, allowed, len(observations))


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
            failures.append(name + " has no step with " + json.dumps(needle) + "; steps: " + json.dumps(details))
    for needle in spec.get("excludes", []):
        for detail in details:
            if needle in detail:
                failures.append(name + " has a step with " + json.dumps(needle) + ": " + json.dumps(detail))
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
            "recommended is " + json.dumps(batch.get("recommended")) + ", expected " + json.dumps(spec["recommended"])
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
                failures.append("summary[0]." + key + " is " + json.dumps(entry.get(key)) + ", expected " + str(count))
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


def human_failures(spec, human):
    if not isinstance(human, dict) or not isinstance(human.get("stdout"), str):
        return ["there is no human report"]
    text = human["stdout"]
    failures = []
    for needle in spec.get("contains", []):
        if needle not in text:
            failures.append("the human report has no " + json.dumps(needle))
    for needle in spec.get("excludes", []):
        if needle in text:
            failures.append("the human report holds " + json.dumps(needle))
    return failures


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
    result["writes"] = [comparison_signature(comparison) for comparison in observation["writes"]]
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


def timing_failures(observations, effect_expected):
    effects = effect_samples(observations)
    for number, effect in enumerate(effects, 1):
        if effect not in EFFECTS:
            return ["run " + str(number) + " has no timing effect; it is " + json.dumps(effect)]
    if effect_expected:
        return []
    directions = {effect for effect in effects if effect in ("faster", "slower")}
    if len(directions) > 1:
        return ["the timing effect flips between faster and slower: " + ", ".join(effects)]
    return []


def judge(name, case_expect, known_wrong, timing, observations, extra_failures=(), notes=None):
    per_run = [fail_messages(case_expect, observation) for observation in observations]
    majority_failures, notice = effect_majority(name, case_expect, observations)
    if notice is not None and notes is not None:
        notes.append(notice)
    failures = list(extra_failures)
    for number, run_failures in enumerate(per_run, 1):
        for failure in run_failures:
            failures.append("run " + str(number) + ": " + failure)
    failures += majority_failures
    stability = []
    for number in range(1, len(observations)):
        stability += repeat_failures(observations[0], observations[number], number + 1)
    if timing is not None:
        stability += timing_failures(observations, "effect" in case_expect)
    passing = [number for number, run_failures in enumerate(per_run, 1) if not run_failures]
    if known_wrong is not None:
        if len(passing) == len(observations) and not majority_failures and not stability:
            details = ["the case passes now; remove known_wrong (" + known_wrong + ")"] + list(extra_failures)
            return "FAIL", " ; ".join(details[:5])
        if 0 < len(passing) < len(observations) or stability:
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


def observed_verdicts(observations):
    verdicts = []
    for observation in observations:
        for comparison in observation["comparisons"]:
            verdict = comparison.get("verdict") if isinstance(comparison, dict) else None
            if isinstance(verdict, str):
                verdicts.append(verdict)
    return verdicts


def run_human(case, binary, directory, env):
    argv = case.argv(binary, "human")
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
    return {"stdout": done.stdout, "exit": done.returncode}


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
    extra_failures = []
    if "human" in case.expect:
        human = run_human(case, binary, directory, env)
        extra_failures = human_failures(case.expect["human"], human)
    notes = []
    status, message = judge(case.name, case.expect, case.known_wrong, case.timing, observations, extra_failures, notes)
    return status, message, notes, observed_verdicts(observations)


def run(root, cases, repeat, binary):
    try:
        work_parent = tempfile.mkdtemp(prefix="qenome-accuracy-")
    except OSError as error:
        raise Unusable("cannot create the work parent: " + str(error)) from None
    failures = 0
    known_wrong = 0
    rows = []
    try:
        for case in cases:
            status, message, notes, verdicts = run_case(case, repeat, binary, work_parent)
            rows.append(
                {
                    "name": case.name,
                    "expected_verdict": case.expect.get("verdict"),
                    "expected_result": case.expect.get("result"),
                    "verdicts": verdicts,
                    "known_wrong": case.known_wrong,
                    "status": status,
                }
            )
            if status == "ok":
                print("ok " + case.name, flush=True)
            elif status == "known-wrong":
                known_wrong += 1
                print("known-wrong " + case.name + ": " + message, flush=True)
            else:
                failures += 1
                print("FAIL " + case.name + ": " + message, flush=True)
            for note in notes:
                print(note, flush=True)
    finally:
        shutil.rmtree(work_parent, ignore_errors=True)
    return failures, known_wrong, rows


def count_phrase(label, values, counts):
    parts = []
    for value in values + (None,):
        count = counts.get(value, 0)
        if count:
            parts.append((value if value is not None else "unstated") + " " + str(count))
    return label + " " + ", ".join(parts)


def summary_line(rows):
    verdicts = {}
    results = {}
    for row in rows:
        verdict = row["expected_verdict"]
        result = row["expected_result"]
        verdicts[verdict] = verdicts.get(verdict, 0) + 1
        results[result] = results.get(result, 0) + 1
    return (
        "accuracy summary: "
        + count_phrase("expected verdicts", VERDICT_VALUES, verdicts)
        + "; "
        + count_phrase("expected results", RESULT_VALUES, results)
    )


def improved_rows(rows):
    wrong = []
    known = []
    for row in rows:
        expected = row["expected_verdict"]
        if expected is None or expected == "improved":
            continue
        if "improved" not in row["verdicts"]:
            continue
        if row["known_wrong"]:
            known.append(row)
        else:
            wrong.append(row)
    return wrong, known


def uncounted_improved_rows(known):
    return [row for row in known if row["status"] != "FAIL"]


def summarize(root, cases, repeat, failures, known_wrong, rows):
    print(summary_line(rows), flush=True)
    wrong, known = improved_rows(rows)
    if wrong:
        print(
            "accuracy: expected a verdict other than improved but got improved: "
            + ", ".join(row["name"] for row in wrong),
            flush=True,
        )
    if known:
        print(
            "accuracy: known-wrong cases that answer improved: "
            + ", ".join(row["name"] + " (" + row["known_wrong"] + ")" for row in known),
            flush=True,
        )
    total = failures + len(uncounted_improved_rows(known))
    if known_wrong:
        print(
            "accuracy: "
            + str(total)
            + " failure(s), "
            + str(known_wrong)
            + " known-wrong case(s), "
            + str(len(cases))
            + " cases, repeat "
            + str(repeat)
            + ", root="
            + root
        )
    elif total == 0:
        print("accuracy: ok (" + str(len(cases)) + " cases, repeat " + str(repeat) + ", root=" + root + ")")
    else:
        print("accuracy: " + str(total) + " failure(s), root=" + root)
    return total


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
                "the corpus holds " + str(len(all_cases)) + " cases; at least " + str(MINIMUM_CASES) + " are expected"
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
        failures, known_wrong, rows = run(root, cases, repeat, binary)
    except Unusable as error:
        sys.stderr.write("accuracy: " + str(error) + "\n")
        return 2
    total_failures = summarize(root, cases, repeat, failures, known_wrong, rows)
    return 1 if total_failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
