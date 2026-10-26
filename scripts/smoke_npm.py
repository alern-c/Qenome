import json
import os
import shutil
import subprocess
import sys
import tempfile

import stage_npm


def node_target():
    done = subprocess.run(
        ["node", "-p", "process.platform + '-' + process.arch"],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    if done.returncode != 0:
        sys.stderr.write(done.stderr)
        raise ValueError("node did not report the platform")
    return done.stdout.strip()


def find_installed(work, dirname):
    candidates = [
        os.path.join(work, "node_modules", "@qenome", dirname),
        os.path.join(work, "node_modules", "qenome", "node_modules", "@qenome", dirname),
    ]
    found = [path for path in candidates if os.path.isdir(path)]
    if len(found) == 1:
        return found[0]
    return None


def install_and_run(pack_dir, version, target):
    paths = {}
    for platform in stage_npm.PLATFORMS:
        filename = stage_npm.tarball_filename(platform["npm"], version)
        path = os.path.join(pack_dir, filename)
        if not os.path.isfile(path):
            raise ValueError("missing tarball " + path)
        paths[platform["npm"]] = os.path.abspath(path)
    launcher = os.path.join(pack_dir, stage_npm.tarball_filename("qenome", version))
    if not os.path.isfile(launcher):
        raise ValueError("missing tarball " + launcher)
    work = tempfile.mkdtemp(prefix="qenome-npm-smoke-")
    try:
        manifest = {
            "private": True,
            "dependencies": {"qenome": "file:" + os.path.abspath(launcher)},
            "overrides": {
                name: "file:" + path for name, path in sorted(paths.items())
            },
        }
        with open(os.path.join(work, "package.json"), "w", encoding="utf-8") as handle:
            handle.write(json.dumps(manifest, indent=2) + "\n")
        env = dict(os.environ)
        env["npm_config_update_notifier"] = "false"
        env.pop("NPM_TOKEN", None)
        env.pop("NODE_AUTH_TOKEN", None)
        print("smoke_npm: npm install --offline in " + work, flush=True)
        installed = subprocess.run(
            ["npm", "install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund"],
            cwd=work,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            env=env,
        )
        sys.stdout.write(installed.stdout)
        sys.stderr.write(installed.stderr)
        if installed.returncode != 0:
            raise ValueError("npm install failed")
        for platform in stage_npm.PLATFORMS:
            found = find_installed(work, platform["dir"])
            if platform["dir"] == target:
                if found is None:
                    raise ValueError("npm did not install " + platform["npm"])
                binary = os.path.join(found, "bin", "qenome")
                if not os.path.isfile(binary) or os.path.getsize(binary) == 0:
                    raise ValueError("installed binary is missing for " + target)
            elif found is not None:
                raise ValueError("npm installed " + platform["npm"] + " on " + target)
        shim = os.path.join(work, "node_modules", ".bin", "qenome")
        if not os.path.exists(shim):
            raise ValueError("npm did not link the qenome command")
        print("smoke_npm: npx qenome --version", flush=True)
        ran = subprocess.run(
            ["npx", "qenome", "--version"],
            cwd=work,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            env=env,
        )
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        output = ran.stdout.replace("\r\n", "\n").replace("\r", "\n")
        expected = "qenome " + version + "\n"
        if ran.returncode != 0 or output != expected:
            raise ValueError(
                "expected " + repr(expected) + " with status 0, got "
                + repr(output)
                + " with status "
                + str(ran.returncode)
            )
        print("smoke_npm: ok " + target + " " + version, flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    root = stage_npm.repo_root()
    pack_dir = None
    rest = argv[1:]
    while rest:
        if rest[0] == "--pack-dir" and len(rest) > 1:
            pack_dir = rest[1]
            rest = rest[2:]
            continue
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
            continue
        sys.stderr.write("usage: python3 scripts/smoke_npm.py [--root DIR] [--pack-dir DIR]\n")
        return 2
    if pack_dir is None:
        pack_dir = os.path.join(root, "dist", "npm")
    try:
        version = stage_npm.read_version(os.path.join(root, "build.zig.zon"))
        target = node_target()
        expected = os.environ.get("QENOME_SMOKE_TARGET", "")
        print("smoke_npm: node target " + target, flush=True)
        if expected and target != expected:
            raise ValueError("this runner is " + target + ", the workflow asked for " + expected)
        known = [platform["dir"] for platform in stage_npm.PLATFORMS]
        if target not in known:
            raise ValueError("no qenome npm package for " + target)
        install_and_run(os.path.abspath(pack_dir), version, target)
    except (OSError, ValueError) as error:
        sys.stderr.write("smoke_npm: " + str(error) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
