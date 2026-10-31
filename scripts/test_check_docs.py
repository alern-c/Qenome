import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_docs.py")

FAILURES: list[str] = []

README = """# Sample

## Install

```sh
npm install -g qenome
```

## Features

One line.

## Contents

- [Install](#install)
- [Features](#features)
- [Installation](docs/installation.md)
- [Check a local D1](docs/local-d1.md)
- [My D1 bill spiked](docs/bill-spiked.md)
- [Use with AI agents](docs/agents.md)
- [Why not ...](docs/why-not.md)
- [Usage](docs/usage.md)
- [Batch comparisons](docs/batch.md)
- [Output formats](docs/output.md)
- [Accuracy and production D1](docs/accuracy.md)
- [Rules](docs/rules.md)
- [Contributing](#contributing)
- [License](#license)

See [the sample](docs/usage.md#try-the-sample-project) and [the site](https://example.com/missing).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0.
"""

README_JA = """# サンプル

## インストール

```sh
npm install -g qenome
```

## 特徴

1行。

## 目次

- [インストール](#インストール)
- [特徴](#特徴)
- [インストール](docs/ja/installation.md)
- [ローカル D1 を調べる](docs/ja/local-d1.md)
- [D1 の請求が跳ねたとき](docs/ja/bill-spiked.md)
- [AI エージェントと使う](docs/ja/agents.md)
- [なぜ他の方法ではないのか](docs/ja/why-not.md)
- [使い方](docs/ja/usage.md)
- [まとめて比べる](docs/ja/batch.md)
- [出力形式](docs/ja/output.md)
- [精度と本番 D1](docs/ja/accuracy.md)
- [守るルール](docs/ja/rules.md)
- [コントリビュート](#コントリビュート)
- [ライセンス](#ライセンス)

[サンプル](docs/ja/usage.md#サンプルプロジェクトを試す)を参照してください。

## コントリビュート

[CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

## ライセンス

Apache-2.0。
"""

AGENTS = """# AGENTS.md

## Rules

- Run [the development checks](CONTRIBUTING.md#development-checks).
- Read [the architecture](docs/architecture.md).
"""

CONTRIBUTING = """# Contributing

## Development checks

Text.
"""

SKILL = """# Skill

See the [output page](https://example.com/docs/output.md#timing-evidence-and-advisory-warnings).
"""

PAGE_BODIES = {
    "installation": (
        "# Installation\n\n## npm\n\n## From source\n",
        "# インストール\n\n## npm\n\n## ソースからビルド\n",
        "",
    ),
    "local-d1": ("# Check a local D1\n", "# ローカル D1 を調べる\n", ""),
    "bill-spiked": ("# My D1 bill spiked\n", "# D1 の請求が跳ねたとき\n", ""),
    "agents": ("# Use with AI agents\n\n## Install\n", "# AI エージェントと使う\n\n## インストール\n", ""),
    "why-not": ("# Why not ...\n", "# なぜ他の方法ではないのか\n", ""),
    "usage": (
        "# Usage\n\n## Comparing a write\n\n### Try the sample project\n",
        "# 使い方\n\n## 書き込みを比べる\n\n### サンプルプロジェクトを試す\n",
        "",
    ),
    "batch": (
        '# Batch\n\n## Batch comparisons\n\n<img src="logo.svg" alt="demo">\n\n## Index audit\n',
        '# まとめて\n\n## まとめて比べる\n\n<img src="../logo.svg" alt="demo">\n\n## インデックスの監査\n',
        "",
    ),
    "output": (
        "# Output formats\n\n## human\n\n## kv\n\n## json\n",
        "# 出力形式\n\n## human\n\n## kv\n\n## json\n",
        "",
    ),
    "accuracy": (
        "# Accuracy and production D1\n\n## How rows are counted\n\n## What the verdicts mean\n",
        "# 精度と本番 D1\n\n## 行数の数え方\n\n## 判定の意味\n",
        "",
    ),
    "rules": ("# Rules\n", "# 守るルール\n", ""),
}

UNPAIRED = {
    "docs/architecture.md": "# Architecture\n\nText.\n",
    "docs/json.md": "# JSON\n\nText.\n",
    "docs/npm.md": "# npm\n\nText.\n",
}


def expect(name, condition, detail):
    if condition:
        print("ok: " + name)
    else:
        FAILURES.append(name)
        print("FAIL: " + name + " (" + detail.strip() + ")")


def write_file(root, rel_path, text):
    path = os.path.join(root, rel_path)
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def make_tree():
    root = tempfile.mkdtemp(prefix="qenome-docs-test-")
    write_file(root, "README.md", README)
    write_file(root, "README.ja.md", README_JA)
    write_file(root, "AGENTS.md", AGENTS)
    write_file(root, "CONTRIBUTING.md", CONTRIBUTING)
    write_file(root, "skills/qenome/SKILL.md", SKILL)
    write_file(root, "docs/logo.svg", "<svg></svg>\n")
    for name, (english, japanese, _) in PAGE_BODIES.items():
        write_file(root, "docs/" + name + ".md", english)
        write_file(root, "docs/ja/" + name + ".md", japanese)
    for path, text in UNPAIRED.items():
        write_file(root, path, text)
    return root


def read_file(root, rel_path):
    with open(os.path.join(root, rel_path), encoding="utf-8") as handle:
        return handle.read()


def append(root, rel_path, text):
    write_file(root, rel_path, read_file(root, rel_path) + text)


def replace(root, rel_path, old, new):
    write_file(root, rel_path, read_file(root, rel_path).replace(old, new))


def case_pass(name, edit):
    root = make_tree()
    try:
        edit(root)
        code, output = run_checker(root)
        expect(name, code == 0 and "docs: ok" in output, output)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_checker(root):
    done = subprocess.run(
        [sys.executable, CHECKER, "--root", root],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return done.returncode, done.stdout + done.stderr


def case(name, edit, expected):
    root = make_tree()
    try:
        edit(root)
        code, output = run_checker(root)
        expect(name, code != 0 and expected in output, output)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def load_checker():
    spec = importlib.util.spec_from_file_location("check_docs", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_slugs(checker):
    cases = [
        ("Qenome", "qenome"),
        ("Why not ...", "why-not-"),
        ("Index audit (--audit-indexes)", "index-audit---audit-indexes"),
        ("Recording the queries your app runs (--record)", "recording-the-queries-your-app-runs---record"),
        ("Timing evidence and advisory warnings", "timing-evidence-and-advisory-warnings"),
        ("Prebuilt binaries (GitHub Releases)", "prebuilt-binaries-github-releases"),
        ("human (default)", "human-default"),
        ("Try the sample project", "try-the-sample-project"),
        ("`summary` entries", "summary-entries"),
        ("ローカル D1 を調べる", "ローカル-d1-を調べる"),
        ("まとめて比べる（--batch）", "まとめて比べる--batch"),
        ("インデックスの監査（--audit-indexes）", "インデックスの監査--audit-indexes"),
        ("AI エージェントと使う", "ai-エージェントと使う"),
        ("時間のぶれ・信頼区間・警告", "時間のぶれ信頼区間警告"),
    ]
    for heading, expected in cases:
        actual = checker.slug(heading)
        expect("slug " + heading, actual == expected, actual + " != " + expected)
    found = checker.anchors("## Same\n\n## Same\n\n## other\n")
    expect("duplicate anchors", found == {"same", "same-1", "other"}, str(found))


def main():
    checker = load_checker()
    check_slugs(checker)

    root = make_tree()
    try:
        code, output = run_checker(root)
        expect("a valid tree passes", code == 0 and "docs: ok" in output, output)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    case(
        "a broken relative link fails",
        lambda root: replace(root, "README.md", "docs/usage.md#try-the-sample-project", "docs/missing.md"),
        "link target does not exist",
    )
    case(
        "a broken anchor fails",
        lambda root: replace(root, "README.md", "#try-the-sample-project", "#missing"),
        "anchor does not exist",
    )
    case(
        "a broken image fails",
        lambda root: replace(root, "docs/batch.md", 'src="logo.svg"', 'src="missing.svg"'),
        "link target does not exist",
    )
    case(
        "heading levels must match the pair",
        lambda root: replace(root, "docs/ja/installation.md", "## ソースからビルド", "### ソースからビルド"),
        "heading levels differ",
    )
    case(
        "a missing pair fails",
        lambda root: os.remove(os.path.join(root, "docs/ja/rules.md")),
        "page does not exist",
    )
    case(
        "an unregistered page fails",
        lambda root: write_file(root, "docs/new-page.md", "# New\n"),
        "neither a paired page nor a listed developer page",
    )
    case(
        "an unregistered Japanese page fails",
        lambda root: write_file(root, "docs/ja/new-page.md", "# 新規\n"),
        "without a listed English pair",
    )
    case(
        "the README line cap is enforced",
        lambda root: append(root, "README.md", "line\n" * 120),
        "over the cap",
    )
    case(
        "the AGENTS line cap is enforced",
        lambda root: append(root, "AGENTS.md", "line\n" * 120),
        "over the cap",
    )
    case(
        "the README heading shape is enforced",
        lambda root: append(root, "README.md", "\n## Extra\n"),
        "headings",
    )
    case(
        "the contents must link every page",
        lambda root: replace(root, "README.md", "- [Rules](docs/rules.md)\n", ""),
        "the contents do not link to docs/rules.md",
    )
    case_pass(
        "a link inside a code block is ignored",
        lambda root: append(root, "README.md", "\n```sh\n[broken](missing.md)\n```\n"),
    )
    case(
        "a link outside the repository fails",
        lambda root: replace(root, "README.md", "docs/usage.md#try-the-sample-project", "../../outside.md"),
        "link escapes the repository",
    )
    case(
        "the contents must stay in one language tree",
        lambda root: replace(root, "README.md", "docs/installation.md", "docs/ja/installation.md"),
        "the contents link to the other language",
    )

    if FAILURES:
        print("check_docs self-test: " + str(len(FAILURES)) + " failure(s)")
        return 1
    print("check_docs self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
