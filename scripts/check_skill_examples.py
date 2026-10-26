import json
import os
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
SKILL = os.path.join("skills", "qenome", "SKILL.md")
MARKER = "# qenome-ci:"


def parse_examples(text):
    examples = []
    in_shell = False
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            if not in_shell:
                in_shell = stripped == "```sh" or stripped.startswith("```sh ")
            else:
                in_shell = False
            continue
        if not in_shell or not stripped:
            continue
        at = stripped.find(MARKER)
        if at < 0:
            continue
        command = stripped[:at].strip()
        spec = stripped[at + len(MARKER) :].strip()
        mode, _, rest = spec.partition(" ")
        examples.append(
            {"line": number, "command": command, "mode": mode, "rest": rest}
        )
    return examples


def parse_spec(rest):
    spec = {
        "exit": None,
        "stdout": None,
        "fields": [],
        "verdict": None,
        "result": None,
        "error": None,
    }
    for token in rest.split():
        key, separator, value = token.partition("=")
        if not separator:
            continue
        if key == "exit":
            spec["exit"] = int(value)
        elif key == "stdout":
            spec["stdout"] = value
        elif key == "fields":
            spec["fields"] = [part for part in value.split(",") if part]
        elif key == "verdict":
            spec["verdict"] = value
        elif key == "result":
            spec["result"] = value
        elif key == "error":
            spec["error"] = value
    return spec


def lookup(value, path):
    current = value
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return None, False
        current = current[part]
    return current, True


def load_json(text):
    body = text.strip()
    start = body.find("{")
    if start > 0:
        body = body[start:]
    return json.loads(body)


def check_report(payload, spec, returncode):
    problems = []
    if not isinstance(payload, dict):
        return ["stdout JSON is not an object"]
    if payload.get("schema_version") != 2:
        problems.append("schema_version is not 2")
    if payload.get("exit_code") != returncode:
        problems.append(
            "exit_code "
            + str(payload.get("exit_code"))
            + " does not match the process exit "
            + str(returncode)
        )
    if spec["verdict"] is not None and payload.get("verdict") != spec["verdict"]:
        problems.append(
            "verdict is "
            + str(payload.get("verdict"))
            + ", expected "
            + spec["verdict"]
        )
    if spec["result"] is not None and payload.get("result") != spec["result"]:
        problems.append(
            "result is " + str(payload.get("result")) + ", expected " + spec["result"]
        )
    for field in spec["fields"]:
        found_value, found = lookup(payload, field)
        if not found:
            problems.append("missing field " + field)
            continue
        if field.endswith("rows_read") or field.endswith("rows_written") or field in (
            "schema_version",
            "exit_code",
        ):
            if not isinstance(found_value, int) or isinstance(found_value, bool):
                problems.append(field + " is not an integer")
    return problems


def check_error(payload, spec, returncode):
    problems = []
    if not isinstance(payload, dict):
        return ["stderr JSON is not an object"]
    if payload.get("schema_version") != 2:
        problems.append("schema_version is not 2")
    if payload.get("exit_code") != returncode:
        problems.append(
            "error exit_code "
            + str(payload.get("exit_code"))
            + " does not match the process exit "
            + str(returncode)
        )
    failure = payload.get("error")
    if not isinstance(failure, dict):
        problems.append("error object is missing")
        return problems
    if spec["error"] is not None and failure.get("code") != spec["error"]:
        problems.append(
            "error.code is " + str(failure.get("code")) + ", expected " + spec["error"]
        )
    for key in ("code", "message", "hint"):
        value = failure.get(key)
        if not isinstance(value, str) or not value:
            problems.append("error." + key + " is missing")
    return problems


def check_output(spec, returncode, stdout, stderr):
    problems = []
    if spec["exit"] is None:
        problems.append("the marker needs exit=")
    elif returncode != spec["exit"]:
        problems.append(
            "process exit "
            + str(returncode)
            + " does not match exit="
            + str(spec["exit"])
        )
    if spec["stdout"] == "report":
        if stderr.strip():
            problems.append("stderr is not empty: " + stderr.strip()[:400])
        try:
            payload = load_json(stdout)
        except json.JSONDecodeError as error:
            problems.append("stdout is not JSON: " + str(error))
            return problems
        problems.extend(check_report(payload, spec, returncode))
        return problems
    if spec["stdout"] == "empty":
        if stdout.strip():
            problems.append("stdout is not empty")
        try:
            payload = load_json(stderr)
        except json.JSONDecodeError as error:
            problems.append("stderr is not JSON: " + str(error))
            return problems
        problems.extend(check_error(payload, spec, returncode))
        return problems
    problems.append("the marker needs stdout=report or stdout=empty")
    return problems


def command_argv(command, binary):
    try:
        argv = shlex.split(command)
    except ValueError as error:
        return None, str(error)
    if len(argv) >= 2 and argv[0] == "npx" and argv[1] == "qenome":
        return [binary] + argv[2:], None
    if argv and os.path.basename(argv[0]) in ("qenome", "qenome.exe"):
        return [binary] + argv[1:], None
    return None, "the command does not start with npx qenome or qenome"


def self_test():
    text = (
        "```sh\n"
        "npx qenome a --format json  # qenome-ci: run exit=0 stdout=report verdict=improved fields=schema_version,verdict\n"
        "npx qenome --d1 DB a b --format json  # qenome-ci: pending TODO(core): warnings are not emitted yet\n"
        "```\n"
    )
    found = parse_examples(text)
    if len(found) != 2 or found[0]["mode"] != "run" or found[1]["mode"] != "pending":
        return "the sample skill did not parse"
    if "TODO(core):" not in found[1]["rest"]:
        return "the pending line lost its TODO"
    spec = parse_spec(found[0]["rest"])
    ok = check_output(
        spec,
        0,
        '{"schema_version": 2, "verdict": "improved", "exit_code": 0}\n',
        "",
    )
    if ok:
        return "a matching report was rejected: " + "; ".join(ok)
    stale = check_output(
        spec,
        0,
        '{"schema_version": 1, "verdict": "improved", "exit_code": 0}\n',
        "",
    )
    if not stale:
        return "schema_version 1 was accepted"
    missing = check_output(
        spec,
        0,
        '{"schema_version": 2, "exit_code": 0}\n',
        "",
    )
    if not any("verdict" in item for item in missing):
        return "a missing verdict was accepted"
    failure = check_output(
        {
            "exit": 4,
            "stdout": "empty",
            "fields": [],
            "verdict": None,
            "result": None,
            "error": "d1_config_not_found",
        },
        4,
        "",
        '{"schema_version": 2, "exit_code": 4, "error": {"code": "d1_config_not_found", "message": "no wrangler config", "hint": "Pass --config"}}\n',
    )
    if failure:
        return "a matching error was rejected: " + "; ".join(failure)
    argv, problem = command_argv("npx qenome --d1 DB select.sql", "/opt/qenome")
    if problem or argv != ["/opt/qenome", "--d1", "DB", "select.sql"]:
        return "npx qenome was not rewritten"
    return None


def prepare_fixture(root):
    import sqlite3

    directory = os.path.join(root, "testdata", "skill")
    schema_path = os.path.join(directory, "schema.sql")
    database = os.path.join(directory, "app.db")
    if os.path.exists(database):
        os.remove(database)
    with open(schema_path, encoding="utf-8") as handle:
        script = handle.read()
    connection = sqlite3.connect(database)
    try:
        connection.executescript(script)
        connection.commit()
    finally:
        connection.close()


def read_skill(root):
    path = os.path.join(root, SKILL)
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main(argv):
    problem = self_test()
    if problem is not None:
        sys.stderr.write("skill-examples: self-test failed: " + problem + "\n")
        return 1
    root = DEFAULT_ROOT
    rest = argv[1:]
    while rest:
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write(
                "usage: python3 scripts/check_skill_examples.py [--root DIR]\n"
            )
            return 2
    root = os.path.abspath(root)
    binary = os.path.join(root, "zig-out", "bin", "qenome")
    if not os.path.isfile(binary):
        sys.stderr.write("skill-examples: build qenome first (zig build)\n")
        return 1
    try:
        prepare_fixture(root)
        text = read_skill(root)
    except OSError as error:
        sys.stderr.write("skill-examples: " + str(error) + "\n")
        return 1
    examples = parse_examples(text)
    problems = []
    ran = 0
    pending = 0
    for example in examples:
        label = SKILL + ":" + str(example["line"])
        if example["mode"] == "pending":
            if "TODO" not in example["rest"]:
                problems.append(label + ": a pending marker needs a TODO")
                continue
            pending += 1
            message = example["rest"]
            if not message.startswith("TODO"):
                message = "TODO " + message
            print(message)
            continue
        if example["mode"] != "run":
            problems.append(label + ": unknown qenome-ci mode " + example["mode"])
            continue
        spec = parse_spec(example["rest"])
        argv_run, problem = command_argv(example["command"], binary)
        if problem is not None:
            problems.append(label + ": " + problem)
            continue
        try:
            done = subprocess.run(
                argv_run,
                cwd=root,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            problems.append(label + ": " + str(error))
            continue
        found = check_output(spec, done.returncode, done.stdout, done.stderr)
        if found:
            detail = done.stdout.strip() or done.stderr.strip()
            problems.append(label + ": " + "; ".join(found) + "\n    " + detail[:800])
            continue
        ran += 1
        print(label + ": exit=" + str(done.returncode))
    if ran == 0:
        problems.append("skill-examples: no runnable example")
    for item in problems:
        print(item)
    if problems:
        print(
            "skill-examples: "
            + str(len(problems))
            + " problem(s), "
            + str(ran)
            + " ran, "
            + str(pending)
            + " pending"
        )
        return 1
    print(
        "skill-examples: ok ("
        + str(ran)
        + " ran, "
        + str(pending)
        + " pending, root="
        + root
        + ")"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
