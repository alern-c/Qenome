import os
import shutil
import subprocess
import sys
import tempfile
import time

import stage_npm

ATTEMPTS = 24
PAUSE_SECONDS = 10
COMPARE_ATTEMPTS = 3


def package_names():
    return [platform["npm"] for platform in stage_npm.PLATFORMS] + ["qenome"]


def clean_env():
    env = dict(os.environ)
    env["npm_config_update_notifier"] = "false"
    env.pop("NPM_TOKEN", None)
    env.pop("NODE_AUTH_TOKEN", None)
    return env


def registry_version(name, version):
    done = subprocess.run(
        ["npm", "view", name + "@" + version, "version"],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        env=clean_env(),
    )
    if done.returncode == 0:
        return done.stdout.strip()
    text = done.stderr + "\n" + done.stdout
    if "E404" in text or "404" in text:
        return ""
    raise ValueError("could not read the registry for " + name + "@" + version)


def wait_for_packages(version, view, attempts, pause):
    last = package_names()
    last_error = ""
    for attempt in range(attempts):
        try:
            last = []
            last_error = ""
            for name in package_names():
                if view(name, version) != version:
                    last.append(name)
        except ValueError as error:
            last = package_names()
            last_error = str(error)
        if not last:
            return []
        if attempt + 1 < attempts:
            pause()
    if last_error:
        raise ValueError(last_error)
    return last


def download_package(name, version, dest):
    done = subprocess.run(
        [
            "npm",
            "pack",
            name + "@" + version,
            "--json",
            "--ignore-scripts",
            "--pack-destination",
            dest,
        ],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        env=clean_env(),
    )
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip()
        raise ValueError(detail or "npm pack failed for " + name)
    packed = stage_npm.parse_pack_json(done.stdout)
    filename = packed[0]["filename"]
    path = os.path.join(dest, filename)
    stage_npm.check_tarball(path, {"name": name, "version": version})


def build_fixture(root, database):
    for name in ("schema.sql", "seed.sql", "verify.sql"):
        path = os.path.join(root, "testdata", name)
        done = subprocess.run(
            ["sqlite3", database, ".read " + path],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            env=clean_env(),
        )
        if done.returncode != 0:
            detail = (done.stderr or done.stdout).strip()
            raise ValueError("fixture " + name + " failed: " + detail)


def comparison_command(version, database, root):
    cases = os.path.join(root, "testdata", "cases")
    return [
        "npx",
        "--yes",
        "qenome@" + version,
        database,
        os.path.join(cases, "improved.sql"),
        os.path.join(cases, "improved.index.sql"),
        "--bind",
        "1:int:1234",
        "--runs",
        "0",
    ]


def comparison_problem(returncode, stdout):
    if returncode != 0:
        return "comparison exited " + str(returncode)
    if "verdict" not in stdout or "improved" not in stdout:
        return "comparison did not report verdict improved"
    return None


def run_comparison(version, root, database, attempts, pause):
    command = comparison_command(version, database, root)
    last = "comparison did not run"
    work = tempfile.mkdtemp(prefix="qenome-npm-compare-")
    try:
        for attempt in range(attempts):
            done = subprocess.run(
                command,
                cwd=work,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                env=clean_env(),
                timeout=180,
            )
            sys.stdout.write(done.stdout)
            sys.stderr.write(done.stderr)
            found = comparison_problem(done.returncode, done.stdout)
            if found is None:
                return
            last = found
            if attempt + 1 < attempts:
                pause()
        raise ValueError(last)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def parse_args(argv):
    version = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--version" and len(rest) > 1:
            version = rest[1]
            rest = rest[2:]
            continue
        raise ValueError("usage: python3 scripts/verify_published_npm.py [--version VERSION]")
    return version


def pause():
    time.sleep(PAUSE_SECONDS)


def main(argv):
    try:
        chosen = parse_args(argv)
    except ValueError as error:
        sys.stderr.write("verify_published_npm: " + str(error) + "\n")
        return 2
    root = stage_npm.repo_root()
    try:
        version = chosen
        if version is None:
            version = stage_npm.read_version(os.path.join(root, "build.zig.zon"))
        if stage_npm.SEMVER.match(version) is None or version == stage_npm.PLACEHOLDER_VERSION:
            raise ValueError("version is not a release version")
        print("verify_published_npm: waiting for " + version, flush=True)
        missing = wait_for_packages(version, registry_version, ATTEMPTS, pause)
        if missing:
            raise ValueError("still missing " + ", ".join(missing))
        print(
            "verify_published_npm: all " + str(len(package_names())) + " packages are on the registry",
            flush=True,
        )
        dest = tempfile.mkdtemp(prefix="qenome-npm-pack-")
        try:
            for name in package_names():
                download_package(name, version, dest)
                print("verify_published_npm: " + name + "@" + version + " is installable", flush=True)
        finally:
            shutil.rmtree(dest, ignore_errors=True)
        fixture = tempfile.mkdtemp(prefix="qenome-npm-fixture-")
        try:
            database = os.path.join(fixture, "qenome-fixture.db")
            build_fixture(root, database)
            run_comparison(version, root, database, COMPARE_ATTEMPTS, pause)
        finally:
            shutil.rmtree(fixture, ignore_errors=True)
    except ValueError as error:
        sys.stderr.write("verify_published_npm: " + str(error) + "\n")
        return 1
    except subprocess.TimeoutExpired:
        sys.stderr.write("verify_published_npm: the comparison timed out\n")
        return 1
    except OSError as error:
        sys.stderr.write("verify_published_npm: " + str(error) + "\n")
        return 1
    print("verify_published_npm: ok " + version, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
