import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage_npm

ROOT = stage_npm.repo_root()
FAILURES = []


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
        stage_npm.tarball_filename("@qenome/linux-x64", "1.2.3") == "qenome-linux-x64-1.2.3.tgz",
        stage_npm.tarball_filename("@qenome/linux-x64", "1.2.3"),
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
    optional = rendered["optionalDependencies"]
    expect(
        "render sets every optional dependency to the zon version",
        set(optional) == {platform["npm"] for platform in stage_npm.PLATFORMS}
        and set(optional.values()) == {version},
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
        mode = os.stat(os.path.join(dest, "qenome", "bin", "qenome.js")).st_mode
        expect("staged launcher is executable", mode & stat.S_IXUSR != 0, oct(mode))
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
    test_empty_binary()
    test_publish_guards()
    if FAILURES:
        print(str(len(FAILURES)) + " case(s) failed: " + ", ".join(FAILURES))
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
