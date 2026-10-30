import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

PLACEHOLDER_VERSION = "0.0.0"
MAIN_DIR = "qenome"
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
LAUNCHER_MAP = re.compile(
    r'"((?:darwin|linux)-(?:arm64|x64))": "(@qenome-cli/(?:darwin|linux)-(?:arm64|x64))"'
)
REQUIRED_FILES = ["bin", "LICENSE", "NOTICE", "README.md"]
PLATFORMS = [
    {
        "dir": "darwin-arm64",
        "npm": "@qenome-cli/darwin-arm64",
        "zig": "aarch64-macos",
        "kind": "macho",
        "os": ["darwin"],
        "cpu": ["arm64"],
    },
    {
        "dir": "darwin-x64",
        "npm": "@qenome-cli/darwin-x64",
        "zig": "x86_64-macos",
        "kind": "macho",
        "os": ["darwin"],
        "cpu": ["x64"],
    },
    {
        "dir": "linux-arm64",
        "npm": "@qenome-cli/linux-arm64",
        "zig": "aarch64-linux-musl",
        "kind": "elf",
        "os": ["linux"],
        "cpu": ["arm64"],
    },
    {
        "dir": "linux-x64",
        "npm": "@qenome-cli/linux-x64",
        "zig": "x86_64-linux-musl",
        "kind": "elf",
        "os": ["linux"],
        "cpu": ["x64"],
    },
]


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def source_manifest_path(root, directory):
    return os.path.join(root, "npm", directory, "package.json")


def launcher_path(root):
    return os.path.join(root, "npm", MAIN_DIR, "bin", "qenome.js")


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def read_version(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("cannot read " + path + ": " + str(error)) from None
    found = re.search(r'^\s*\.version\s*=\s*"([^"]*)"', text, re.MULTILINE)
    if found is None:
        raise ValueError("build.zig.zon has no .version")
    version = found.group(1)
    if SEMVER.match(version) is None:
        raise ValueError("version is not semver: " + version)
    return version


def tarball_filename(npm_name, version):
    return npm_name.replace("@", "").replace("/", "-") + "-" + version + ".tgz"


def check_common(directory, manifest):
    if manifest.get("version") != PLACEHOLDER_VERSION:
        raise ValueError(directory + " version must be " + PLACEHOLDER_VERSION)
    if manifest.get("private") is not True:
        raise ValueError(directory + " must be private")
    if manifest.get("license") != "Apache-2.0":
        raise ValueError(directory + " license must be Apache-2.0")
    repository = manifest.get("repository") or {}
    url = repository.get("url") or ""
    if "github.com/alern-c/Qenome" not in url:
        raise ValueError(directory + " repository url is missing")
    if repository.get("directory") != "npm/" + directory:
        raise ValueError(directory + " repository.directory must be npm/" + directory)
    access = (manifest.get("publishConfig") or {}).get("access")
    if access != "public":
        raise ValueError(directory + " publishConfig.access must be public")
    files = manifest.get("files")
    if not isinstance(files, list) or not set(REQUIRED_FILES).issubset(files):
        raise ValueError(directory + " files must include bin, LICENSE, NOTICE, and README.md")
    if not manifest.get("description"):
        raise ValueError(directory + " needs a description")
    keywords = manifest.get("keywords")
    if not isinstance(keywords, list) or not keywords:
        raise ValueError(directory + " keywords must be a non-empty list")
    if not all(isinstance(keyword, str) and keyword for keyword in keywords):
        raise ValueError(directory + " keywords must be non-empty strings")
    if len(set(keywords)) != len(keywords):
        raise ValueError(directory + " keywords must not repeat")


def check_launcher(root, expected):
    path = launcher_path(root)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.startswith("#!/usr/bin/env node\n"):
        raise ValueError("launcher must start with a node shebang")
    matches = LAUNCHER_MAP.findall(text)
    if len(matches) != len(expected) or dict(matches) != expected:
        raise ValueError("launcher package map does not match optionalDependencies")


def validate_sources(root):
    expected_optional = {}
    for platform in PLATFORMS:
        manifest = load_json(source_manifest_path(root, platform["dir"]))
        check_common(platform["dir"], manifest)
        if manifest.get("name") != platform["npm"]:
            raise ValueError(platform["dir"] + " has the wrong package name")
        if manifest.get("os") != platform["os"] or manifest.get("cpu") != platform["cpu"]:
            raise ValueError(platform["dir"] + " os/cpu does not match the platform table")
        if manifest.get("preferUnplugged") is not True:
            raise ValueError(platform["dir"] + " must set preferUnplugged")
        if "bin" in manifest or "optionalDependencies" in manifest:
            raise ValueError(platform["dir"] + " must not set bin or optionalDependencies")
        expected_optional[platform["npm"]] = PLACEHOLDER_VERSION
    manifest = load_json(source_manifest_path(root, MAIN_DIR))
    check_common(MAIN_DIR, manifest)
    if manifest.get("name") != "qenome":
        raise ValueError("launcher package name must be qenome")
    if "os" in manifest or "cpu" in manifest:
        raise ValueError("launcher package must not set os or cpu")
    if manifest.get("bin") != {"qenome": "bin/qenome.js"}:
        raise ValueError("launcher bin must be bin/qenome.js")
    if "lib" not in manifest.get("files", []):
        raise ValueError("launcher files must include lib")
    if "skills" not in manifest.get("files", []):
        raise ValueError("launcher files must include skills")
    exports = manifest.get("exports") or {}
    if exports.get("./d1") != "./lib/d1.mjs":
        raise ValueError("launcher exports must map ./d1 to ./lib/d1.mjs")
    if exports.get("./package.json") != "./package.json":
        raise ValueError("launcher exports must map ./package.json to itself")
    module_path = os.path.join(root, "npm", MAIN_DIR, "lib", "d1.mjs")
    if not os.path.isfile(module_path) or os.path.getsize(module_path) == 0:
        raise ValueError("launcher needs a non-empty npm/" + MAIN_DIR + "/lib/d1.mjs")
    if manifest.get("optionalDependencies") != expected_optional:
        raise ValueError("launcher optionalDependencies do not match the platform packages")
    if manifest.get("engines", {}).get("node") != ">=18":
        raise ValueError("launcher engines.node must be >=18")
    expected = {name.split("/")[-1]: name for name in expected_optional}
    check_launcher(root, expected)


def render_manifest(manifest, version):
    if SEMVER.match(version) is None or version == PLACEHOLDER_VERSION:
        raise ValueError("refusing version " + version)
    rendered = copy.deepcopy(manifest)
    if rendered.get("version") != PLACEHOLDER_VERSION:
        raise ValueError("source version must be " + PLACEHOLDER_VERSION)
    if rendered.get("private") is not True:
        raise ValueError("source package must be private")
    rendered["version"] = version
    del rendered["private"]
    optional = rendered.get("optionalDependencies")
    if optional is not None:
        for key in list(optional):
            if optional[key] != PLACEHOLDER_VERSION:
                raise ValueError(
                    "optional dependency " + key + " must use the placeholder version"
                )
            optional[key] = version
    return rendered


def readme_text(manifest):
    name = manifest["name"]
    description = manifest["description"]
    if name == "qenome":
        return (
            "# qenome\n"
            "\n"
            + description
            + "\n"
            "\n"
            "```sh\n"
            "npx qenome --version\n"
            "```\n"
            "\n"
            "`qenome skill install` copies the bundled Agent Skill into an AI agent's "
            "skills directory, and `qenome skill print` writes it to stdout.\n"
            "\n"
            "This package is a launcher. npm installs one of `@qenome-cli/linux-x64`, "
            "`@qenome-cli/linux-arm64`, `@qenome-cli/darwin-x64`, or `@qenome-cli/darwin-arm64` "
            "for the machine you are on. Linux and macOS on x64 and arm64 are supported.\n"
            "\n"
            "Source: https://github.com/alern-c/Qenome\n"
        )
    return (
        "# "
        + name
        + "\n"
        "\n"
        + description
        + "\n"
        "\n"
        "Install the `qenome` package. npm selects this binary when the machine matches it.\n"
    )


def write_tree(directory, manifest, root):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "package.json"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    for name in ("LICENSE", "NOTICE"):
        shutil.copyfile(os.path.join(root, name), os.path.join(directory, name))
    with open(os.path.join(directory, "README.md"), "w", encoding="utf-8") as handle:
        handle.write(readme_text(manifest))


def build_binary(root, zig_target, dest):
    prefix = tempfile.mkdtemp(prefix="qenome-npm-")
    try:
        print("stage_npm: zig build -Dtarget=" + zig_target, flush=True)
        subprocess.run(
            [
                "zig",
                "build",
                "-Doptimize=ReleaseSafe",
                "-Dstrip=true",
                "-Dtarget=" + zig_target,
                "--prefix",
                prefix,
                "--summary",
                "all",
            ],
            cwd=root,
            check=True,
            stdin=subprocess.DEVNULL,
        )
        source = os.path.join(prefix, "bin", "qenome")
        if not os.path.isfile(source) or os.path.getsize(source) == 0:
            raise ValueError("zig build did not write a binary for " + zig_target)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(source, dest)
        os.chmod(dest, 0o755)
    finally:
        shutil.rmtree(prefix, ignore_errors=True)


def assert_binary_kind(path, kind):
    with open(path, "rb") as handle:
        header = handle.read(4)
    if kind == "elf":
        ok = header == b"\x7fELF"
    elif kind == "macho":
        ok = header in (
            b"\xcf\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xca\xfe\xba\xbe",
            b"\xbe\xba\xfe\xca",
        )
    else:
        raise ValueError("unknown binary kind " + kind)
    if not ok:
        raise ValueError(path + " is not a " + kind + " binary")


def stage_distribution(root, dest, binaries=None):
    validate_sources(root)
    version = read_version(os.path.join(root, "build.zig.zon"))
    if version == PLACEHOLDER_VERSION:
        raise ValueError("refusing to stage placeholder version " + version)
    if binaries is not None:
        missing = [platform["dir"] for platform in PLATFORMS if platform["dir"] not in binaries]
        if missing:
            raise ValueError("missing binaries: " + ", ".join(missing))
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    for platform in PLATFORMS:
        directory = os.path.join(dest, platform["dir"])
        manifest = render_manifest(load_json(source_manifest_path(root, platform["dir"])), version)
        write_tree(directory, manifest, root)
        binary = os.path.join(directory, "bin", "qenome")
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        if binaries is None:
            build_binary(root, platform["zig"], binary)
            assert_binary_kind(binary, platform["kind"])
        else:
            shutil.copyfile(binaries[platform["dir"]], binary)
            os.chmod(binary, 0o755)
        if os.path.getsize(binary) == 0:
            raise ValueError("empty binary for " + platform["dir"])
    directory = os.path.join(dest, MAIN_DIR)
    manifest = render_manifest(load_json(source_manifest_path(root, MAIN_DIR)), version)
    write_tree(directory, manifest, root)
    launcher = os.path.join(directory, "bin", "qenome.js")
    os.makedirs(os.path.dirname(launcher), exist_ok=True)
    shutil.copyfile(launcher_path(root), launcher)
    os.chmod(launcher, 0o755)
    module = os.path.join(directory, "lib", "d1.mjs")
    os.makedirs(os.path.dirname(module), exist_ok=True)
    shutil.copyfile(os.path.join(root, "npm", MAIN_DIR, "lib", "d1.mjs"), module)
    os.chmod(module, 0o644)
    skill = os.path.join(directory, "skills", "qenome", "SKILL.md")
    os.makedirs(os.path.dirname(skill), exist_ok=True)
    shutil.copyfile(os.path.join(root, "skills", "qenome", "SKILL.md"), skill)
    os.chmod(skill, 0o644)
    print("stage_npm: staged " + version + " in " + dest, flush=True)
    return version


def parse_pack_json(text):
    start = text.find("[")
    end = text.rfind("]")
    if start < 0 or end < start:
        raise ValueError("npm pack did not return JSON: " + text.strip())
    return json.loads(text[start : end + 1])


def check_tarball(path, manifest):
    with tarfile.open(path, "r:gz") as archive:
        names = set(archive.getnames())
        required = [
            "package/package.json",
            "package/LICENSE",
            "package/NOTICE",
            "package/README.md",
        ]
        if manifest["name"] == "qenome":
            binary = "package/bin/qenome.js"
            required.append("package/lib/d1.mjs")
            required.append("package/skills/qenome/SKILL.md")
        else:
            binary = "package/bin/qenome"
        required.append(binary)
        for name in required:
            if name not in names:
                raise ValueError(path + " is missing " + name)
        if archive.getmember(binary).mode & 0o111 == 0:
            raise ValueError(binary + " is not executable in " + path)
        packed_source = archive.extractfile("package/package.json")
        if packed_source is None:
            raise ValueError(path + " has no package/package.json")
        try:
            packed = json.load(packed_source)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise ValueError(path + " package.json is not valid JSON: " + str(error)) from None
    if packed.get("name") != manifest["name"] or packed.get("version") != manifest["version"]:
        raise ValueError("packed manifest does not match " + manifest["name"])
    if "private" in packed:
        raise ValueError("packed manifest is private: " + manifest["name"])


def npm_pack(directory, dest, manifest):
    done = subprocess.run(
        ["npm", "pack", "--json", "--ignore-scripts"],
        cwd=directory,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    if done.returncode != 0:
        sys.stderr.write(done.stdout)
        sys.stderr.write(done.stderr)
        raise ValueError("npm pack failed for " + manifest["name"])
    filename = parse_pack_json(done.stdout)[0]["filename"]
    expected = tarball_filename(manifest["name"], manifest["version"])
    if filename != expected:
        raise ValueError("tarball name " + filename + " != " + expected)
    target = os.path.join(dest, filename)
    os.replace(os.path.join(directory, filename), target)
    check_tarball(target, manifest)
    print("stage_npm: packed " + filename, flush=True)
    return target


def npm_dry_run(directory):
    print("stage_npm: npm publish --dry-run in " + directory, flush=True)
    done = subprocess.run(
        ["npm", "publish", "--dry-run", "--access", "public", "--ignore-scripts"],
        cwd=directory,
        stdin=subprocess.DEVNULL,
    )
    return done.returncode


def remove_tarballs(directory):
    for name in os.listdir(directory):
        if name.endswith(".tgz"):
            os.remove(os.path.join(directory, name))


def pack_staged(dest):
    version = None
    packed = []
    directories = [platform["dir"] for platform in PLATFORMS] + [MAIN_DIR]
    for directory in directories:
        path = os.path.join(dest, directory)
        manifest = load_json(os.path.join(path, "package.json"))
        if "private" in manifest:
            raise ValueError("staged package is still private: " + directory)
        if version is None:
            version = manifest["version"]
        elif manifest["version"] != version:
            raise ValueError("staged versions differ in " + directory)
        packed.append(npm_pack(path, dest, manifest))
        code = npm_dry_run(path)
        if code != 0:
            raise ValueError("npm publish --dry-run failed for " + manifest["name"])
        remove_tarballs(path)
    return packed


def parse_args(argv):
    root = repo_root()
    dest = None
    pack = False
    rest = argv[1:]
    while rest:
        if rest[0] == "--pack":
            pack = True
            rest = rest[1:]
            continue
        if rest[0] == "--root" and len(rest) > 1:
            root = rest[1]
            rest = rest[2:]
            continue
        if rest[0] == "--dest" and len(rest) > 1:
            dest = rest[1]
            rest = rest[2:]
            continue
        raise ValueError("usage: python3 scripts/stage_npm.py [--root DIR] [--dest DIR] [--pack]")
    if dest is None:
        dest = os.path.join(root, "dist", "npm")
    return os.path.abspath(root), os.path.abspath(dest), pack


def main(argv):
    try:
        root, dest, pack = parse_args(argv)
        stage_distribution(root, dest)
        if pack:
            pack_staged(dest)
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError, json.JSONDecodeError) as error:
        sys.stderr.write("stage_npm: " + str(error) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
