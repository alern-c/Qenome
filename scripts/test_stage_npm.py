import contextlib
import glob
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage_npm

ROOT = stage_npm.repo_root()
FAILURES: list[str] = []


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
        return
    FAILURES.append(name)
    print("FAIL: " + name + ": " + str(detail))


def snapshot(root):
    base = os.path.join(root, "npm")
    found = {}
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            with open(path, "rb") as handle:
                found[path] = handle.read()
    zon = os.path.join(root, "build.zig.zon")
    with open(zon, "rb") as handle:
        found[zon] = handle.read()
    return found


def test_version():
    version = stage_npm.read_version(os.path.join(ROOT, "build.zig.zon"))
    expect("zon version is semver", stage_npm.SEMVER.match(version) is not None, version)
    expect(
        "zon version is not the placeholder",
        version != stage_npm.PLACEHOLDER_VERSION,
        version,
    )
    return version


def test_filenames():
    expect(
        "scoped tarball names drop the scope",
        stage_npm.tarball_filename("@qenome-cli/linux-x64", "1.2.3") == "qenome-cli-linux-x64-1.2.3.tgz",
        stage_npm.tarball_filename("@qenome-cli/linux-x64", "1.2.3"),
    )
    expect(
        "launcher tarball name uses the package name",
        stage_npm.tarball_filename("qenome", "1.2.3") == "qenome-1.2.3.tgz",
        stage_npm.tarball_filename("qenome", "1.2.3"),
    )


def test_sources():
    try:
        stage_npm.validate_sources(ROOT)
    except ValueError as error:
        expect("source packages match the platform table", False, error)
        return
    expect("source packages match the platform table", True, "")


def test_render(version):
    path = stage_npm.source_manifest_path(ROOT, stage_npm.MAIN_DIR)
    before = stage_npm.load_json(path)
    rendered = stage_npm.render_manifest(before, version)
    after = stage_npm.load_json(path)
    expect("render keeps the source placeholder", after == before, after.get("version"))
    expect("render writes the zon version", rendered["version"] == version, rendered["version"])
    expect("render drops private", "private" not in rendered, rendered.get("private"))
    expect(
        "render keeps the keywords",
        rendered.get("keywords") == before.get("keywords") and bool(before.get("keywords")),
        rendered.get("keywords"),
    )
    optional = rendered["optionalDependencies"]
    expect(
        "render sets every optional dependency to the zon version",
        set(optional) == {platform["npm"] for platform in stage_npm.PLATFORMS} and set(optional.values()) == {version},
        optional,
    )
    broken = dict(before)
    broken["version"] = version
    try:
        stage_npm.render_manifest(broken, version)
    except ValueError as error:
        expect("render rejects a source version that is already real", "0.0.0" in str(error), error)
    else:
        expect("render rejects a source version that is already real", False, "render succeeded")


def test_stage(version):
    work = tempfile.mkdtemp(prefix="qenome-stage-")
    dest = os.path.join(work, "dist")
    binaries = {}
    try:
        before = snapshot(ROOT)
        for platform in stage_npm.PLATFORMS:
            path = os.path.join(work, "fake", platform["dir"])
            os.makedirs(path)
            binary = os.path.join(path, "qenome")
            with open(binary, "wb") as handle:
                handle.write(b"fake-" + platform["dir"].encode("ascii"))
            binaries[platform["dir"]] = binary
        staged_version = stage_npm.stage_distribution(ROOT, dest, binaries)
        expect("stage reports the zon version", staged_version == version, staged_version)
        expect("stage does not rewrite the source tree", snapshot(ROOT) == before, "source changed")
        launcher = stage_npm.load_json(os.path.join(dest, "qenome", "package.json"))
        expect("staged launcher version", launcher["version"] == version, launcher["version"])
        expect("staged launcher is publishable", "private" not in launcher, launcher.get("private"))
        source_launcher = stage_npm.load_json(stage_npm.source_manifest_path(ROOT, stage_npm.MAIN_DIR))
        expect(
            "staged launcher keeps the keywords",
            launcher.get("keywords") == source_launcher.get("keywords"),
            launcher.get("keywords"),
        )
        mode = os.stat(os.path.join(dest, "qenome", "bin", "qenome.js")).st_mode
        expect("staged launcher is executable", mode & stat.S_IXUSR != 0, oct(mode))
        module = os.path.join(dest, "qenome", "lib", "d1.mjs")
        expect(
            "staged launcher ships the d1 module",
            os.path.isfile(module) and os.path.getsize(module) > 0,
            module,
        )
        source_skill = os.path.join(ROOT, "skills", "qenome", "SKILL.md")
        staged_skill = os.path.join(dest, "qenome", "skills", "qenome", "SKILL.md")
        expect(
            "staged launcher ships the bundled skill",
            os.path.isfile(staged_skill) and open(staged_skill, "rb").read() == open(source_skill, "rb").read(),
            staged_skill,
        )
        for platform in stage_npm.PLATFORMS:
            manifest = stage_npm.load_json(os.path.join(dest, platform["dir"], "package.json"))
            binary = os.path.join(dest, platform["dir"], "bin", "qenome")
            with open(binary, "rb") as handle:
                body = handle.read()
            expect(
                "staged " + platform["dir"] + " version",
                manifest["version"] == version and "private" not in manifest,
                manifest.get("version"),
            )
            source_platform = stage_npm.load_json(stage_npm.source_manifest_path(ROOT, platform["dir"]))
            expect(
                "staged " + platform["dir"] + " keywords",
                manifest.get("keywords") == source_platform.get("keywords") and bool(source_platform.get("keywords")),
                manifest.get("keywords"),
            )
            expect(
                "staged " + platform["dir"] + " binary",
                body == b"fake-" + platform["dir"].encode("ascii"),
                body,
            )
            expect(
                "staged " + platform["dir"] + " license",
                "Apache License" in open(os.path.join(dest, platform["dir"], "LICENSE"), encoding="utf-8").read(),
                platform["dir"],
            )
        readme = open(os.path.join(dest, "qenome", "README.md"), encoding="utf-8").read()
        expect("staged readme names npx", "npx qenome --version" in readme, readme)
    except ValueError as error:
        expect("stage with fake binaries", False, error)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_build_binary():
    work = tempfile.mkdtemp(prefix="qenome-build-")
    pattern = os.path.join(tempfile.gettempdir(), "qenome-npm-*")
    before = set(glob.glob(pattern))
    calls = []

    def writing_run(args, **kwargs):
        calls.append(args)
        prefix = args[args.index("--prefix") + 1]
        os.makedirs(os.path.join(prefix, "bin"))
        with open(os.path.join(prefix, "bin", "qenome"), "wb") as handle:
            handle.write(b"built-binary")
        return subprocess.CompletedProcess(args, 0, stdout="build output\n")

    def failing_run(args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 2, stdout="compile error\n")

    def silent_run(args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, stdout="ok\n")

    original = stage_npm.subprocess.run
    try:
        stage_npm.subprocess.run = writing_run
        dest = os.path.join(work, "built", "bin", "qenome")
        log = stage_npm.build_binary(ROOT, "aarch64-macos", dest)
        expect("build_binary copies the built binary", open(dest, "rb").read() == b"built-binary", dest)
        expect("build_binary returns the build log", log == "build output\n", log)
        expect(
            "build_binary makes the binary executable",
            stat.S_IMODE(os.stat(dest).st_mode) == 0o755,
            oct(stat.S_IMODE(os.stat(dest).st_mode)),
        )
        expect(
            "build_binary passes the release target",
            any("-Doptimize=ReleaseSafe" in args and "-Dtarget=aarch64-macos" in args for args in calls),
            calls,
        )
        blocker = os.path.join(work, "blocker")
        with open(blocker, "w", encoding="utf-8") as handle:
            handle.write("x")
        try:
            stage_npm.build_binary(ROOT, "x86_64-linux-musl", os.path.join(blocker, "bin", "qenome"))
        except stage_npm.BuildError as error:
            expect("an install failure keeps the log", error.log == "build output\n", error.log)
            expect("an install failure names its target", "x86_64-linux-musl" in str(error), error)
        else:
            expect("an install failure keeps the log", False, "build succeeded")
        stage_npm.subprocess.run = failing_run
        try:
            stage_npm.build_binary(ROOT, "x86_64-macos", os.path.join(work, "failed", "bin", "qenome"))
        except stage_npm.BuildError as error:
            expect("a failed build names its target", "x86_64-macos" in str(error), error)
            expect("a failed build keeps the log", error.log == "compile error\n", error.log)
        else:
            expect("a failed build names its target", False, "build succeeded")
        stage_npm.subprocess.run = silent_run
        try:
            stage_npm.build_binary(ROOT, "aarch64-linux-musl", os.path.join(work, "silent", "bin", "qenome"))
        except stage_npm.BuildError as error:
            expect("a build without a binary is refused", "did not write a binary" in str(error), error)
            expect("a build without a binary keeps the log", error.log == "ok\n", error.log)
        else:
            expect("a build without a binary is refused", False, "build succeeded")
        expect("build_binary does not leave a temp prefix", set(glob.glob(pattern)) == before, glob.glob(pattern))
    finally:
        stage_npm.subprocess.run = original
        shutil.rmtree(work, ignore_errors=True)


def test_parallel_builds():
    work = tempfile.mkdtemp(prefix="qenome-parallel-")
    targets = [(platform, os.path.join(work, platform["dir"], "bin", "qenome")) for platform in stage_npm.PLATFORMS]
    barrier = threading.Barrier(len(targets), timeout=30)
    seen = []
    lock = threading.Lock()

    def builder(root, zig_target, dest):
        with lock:
            seen.append(zig_target)
        barrier.wait()
        return "log for " + zig_target + "\n"

    def failing_builder(root, zig_target, dest):
        with lock:
            seen.append(zig_target)
        if zig_target == "x86_64-macos":
            raise stage_npm.BuildError("zig build failed for " + zig_target, "boom\n")
        return "log for " + zig_target + "\n"

    try:
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            stage_npm.build_binaries(ROOT, targets, builder)
        expect(
            "every target is built",
            sorted(seen) == sorted(platform["zig"] for platform in stage_npm.PLATFORMS),
            seen,
        )
        output = captured.getvalue()
        for platform in stage_npm.PLATFORMS:
            block = "stage_npm: zig build -Dtarget=" + platform["zig"] + "\nlog for " + platform["zig"] + "\n"
            expect("the log for " + platform["zig"] + " is one block", block in output, output)
        seen.clear()
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            try:
                stage_npm.build_binaries(ROOT, targets, failing_builder)
            except stage_npm.BuildError as error:
                expect("a parallel failure names its target", "x86_64-macos" in str(error), error)
            else:
                expect("a parallel failure names its target", False, "builds succeeded")
        expect(
            "a parallel failure still builds every target",
            sorted(seen) == sorted(platform["zig"] for platform in stage_npm.PLATFORMS),
            seen,
        )
        output = captured.getvalue()
        expect("a failed target prints its log", "boom\n" in output, output)
        expect("a failed log is printed once", output.count("boom\n") == 1, output)
        headers = ["stage_npm: zig build -Dtarget=" + platform["zig"] + "\n" for platform in stage_npm.PLATFORMS]
        expect("every target prints a block on failure", all(header in output for header in headers), output)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_empty_binary():
    work = tempfile.mkdtemp(prefix="qenome-empty-")
    binaries = {}
    try:
        for platform in stage_npm.PLATFORMS:
            directory = os.path.join(work, "fake", platform["dir"])
            os.makedirs(directory)
            binary = os.path.join(directory, "qenome")
            with open(binary, "wb") as handle:
                handle.write(b"")
            binaries[platform["dir"]] = binary
        try:
            stage_npm.stage_distribution(ROOT, os.path.join(work, "dist"), binaries)
        except ValueError as error:
            expect("an empty binary is refused", "empty binary" in str(error), error)
            return
        expect("an empty binary is refused", False, "stage succeeded")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_launcher_permissions():
    if shutil.which("node") is None:
        print("skip: the launcher test needs node")
        return
    done = subprocess.run(
        ["node", "-p", "process.platform + '-' + process.arch"],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    target = done.stdout.strip()
    known = [platform["dir"] for platform in stage_npm.PLATFORMS]
    if done.returncode != 0 or target not in known:
        print("skip: the launcher test needs a supported node target")
        return
    with open(stage_npm.launcher_path(ROOT), "rb") as handle:
        launcher = handle.read()
    work = tempfile.mkdtemp(prefix="qenome-launcher-")
    try:
        app = os.path.join(work, "app")
        os.makedirs(os.path.join(app, "bin"))
        package = os.path.join(app, "node_modules", "@qenome-cli", target)
        os.makedirs(os.path.join(package, "bin"))
        with open(os.path.join(package, "package.json"), "w", encoding="utf-8") as handle:
            handle.write('{"name": "@qenome-cli/' + target + '", "version": "0.0.0"}\n')
        script = os.path.join(app, "bin", "qenome.js")
        with open(script, "wb") as handle:
            handle.write(launcher)
        binary = os.path.join(package, "bin", "qenome")
        with open(binary, "wb") as handle:
            handle.write(b"#!/bin/sh\necho launcher-ok\n")
        os.chmod(binary, 0o500)
        done = subprocess.run(["node", script], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        output = done.stdout.replace("\r\n", "\n")
        expect(
            "an executable binary starts without chmod",
            done.returncode == 0 and output == "launcher-ok\n",
            (done.returncode, done.stdout, done.stderr),
        )
        mode = stat.S_IMODE(os.stat(binary).st_mode)
        expect("an executable binary keeps its mode", mode == 0o500, oct(mode))
        os.chmod(binary, 0o644)
        done = subprocess.run(["node", script], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        output = done.stdout.replace("\r\n", "\n")
        expect(
            "a binary without the execute bits still starts",
            done.returncode == 0 and output == "launcher-ok\n",
            (done.returncode, done.stdout, done.stderr),
        )
        mode = stat.S_IMODE(os.stat(binary).st_mode)
        expect("a binary without the execute bits is made executable", mode == 0o755, oct(mode))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_publish_guards():
    env = dict(os.environ)
    env.pop("ACTIONS_ID_TOKEN_REQUEST_URL", None)
    env.pop("NPM_TOKEN", None)
    env.pop("NODE_AUTH_TOKEN", None)
    script = os.path.join(HERE, "publish_npm.py")

    def run(args, publish_env):
        return subprocess.run(
            [sys.executable, script] + args,
            capture_output=True,
            text=True,
            env=publish_env,
        )

    done = run([], env)
    expect("publish without --publish is refused", done.returncode == 2, done.stderr)
    expect("the refusal says refusing", "refusing" in done.stderr, done.stderr)
    done = run(["--publish"], env)
    expect("publish without OIDC is refused", done.returncode == 2, done.stderr)
    expect("the refusal names OIDC", "OIDC" in done.stderr, done.stderr)
    token_env = dict(env)
    token_env["ACTIONS_ID_TOKEN_REQUEST_URL"] = "https://example.invalid/token"
    token_env["NPM_TOKEN"] = "not-a-real-token"
    done = run(["--publish"], token_env)
    expect("publish with a token is refused", done.returncode == 2, done.stderr)
    expect("the refusal names a token", "token" in done.stderr, done.stderr)


def main():
    version = test_version()
    test_filenames()
    test_sources()
    test_render(version)
    test_stage(version)
    test_build_binary()
    test_parallel_builds()
    test_empty_binary()
    test_launcher_permissions()
    test_publish_guards()
    if FAILURES:
        print(str(len(FAILURES)) + " case(s) failed: " + ", ".join(FAILURES))
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
