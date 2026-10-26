import os
import subprocess
import sys

import stage_npm


def npm_env():
    env = dict(os.environ)
    env["npm_config_update_notifier"] = "false"
    return env


def guard(argv):
    if "--publish" not in argv:
        sys.stderr.write("publish_npm: refusing to publish without --publish\n")
        return 2
    if os.environ.get("NPM_TOKEN") or os.environ.get("NODE_AUTH_TOKEN"):
        sys.stderr.write(
            "publish_npm: refusing because an npm token is set. This path uses trusted publishing.\n"
        )
        return 2
    if not os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL"):
        sys.stderr.write(
            "publish_npm: refusing because GitHub Actions did not provide an OIDC token.\n"
        )
        return 2
    return None


def registry_state(name, version):
    done = subprocess.run(
        ["npm", "view", name + "@" + version, "version"],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        env=npm_env(),
    )
    if done.returncode == 0:
        return "present"
    text = done.stderr + "\n" + done.stdout
    if "E404" in text or "404" in text:
        return "absent"
    sys.stderr.write(text)
    return "unknown"


def publish_one(directory, manifest):
    name = manifest["name"]
    version = manifest["version"]
    state = registry_state(name, version)
    if state == "unknown":
        sys.stderr.write("publish_npm: could not read the registry for " + name + "\n")
        return 1
    if state == "present":
        print("publish_npm: " + name + "@" + version + " is already published", flush=True)
        return 0
    print("publish_npm: publishing " + name + "@" + version, flush=True)
    done = subprocess.run(
        ["npm", "publish", "--access", "public", "--provenance", "--ignore-scripts"],
        cwd=directory,
        stdin=subprocess.DEVNULL,
        env=npm_env(),
    )
    return done.returncode


def main(argv):
    refused = guard(argv)
    if refused is not None:
        return refused
    root = stage_npm.repo_root()
    dest = os.path.join(root, "dist", "npm")
    try:
        version = stage_npm.read_version(os.path.join(root, "build.zig.zon"))
    except ValueError as error:
        sys.stderr.write("publish_npm: " + str(error) + "\n")
        return 1
    if version == stage_npm.PLACEHOLDER_VERSION:
        sys.stderr.write("publish_npm: refusing placeholder version\n")
        return 1
    directories = [platform["dir"] for platform in stage_npm.PLATFORMS]
    directories.append(stage_npm.MAIN_DIR)
    planned = []
    for directory in directories:
        path = os.path.join(dest, directory)
        manifest_path = os.path.join(path, "package.json")
        if not os.path.isfile(manifest_path):
            sys.stderr.write(
                "publish_npm: missing "
                + manifest_path
                + ". Run python3 scripts/stage_npm.py first.\n"
            )
            return 1
        manifest = stage_npm.load_json(manifest_path)
        if manifest.get("version") != version or "private" in manifest:
            sys.stderr.write("publish_npm: " + directory + " is not a staged publishable package\n")
            return 1
        if manifest.get("name") != "qenome":
            binary = os.path.join(path, "bin", "qenome")
            if not os.path.isfile(binary) or os.path.getsize(binary) == 0:
                sys.stderr.write("publish_npm: missing binary in " + directory + "\n")
                return 1
        planned.append((path, manifest))
    for path, manifest in planned:
        code = publish_one(path, manifest)
        if code != 0:
            return code
    print("publish_npm: done " + version, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
