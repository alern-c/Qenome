# AGENTS.md

Qenome は、ローカル SQLite の SELECT 1本に対して、候補の `CREATE INDEX` を1本試したときの変化を比較する Zig 製 CLI です。使い方・出力・終了コードは `README.md`（日本語版は `README.ja.md`）が正本です。このファイルには、どの AI ツールで作業しても同じ手順になるように、このリポジトリ固有の事実だけを書きます。

## ビルドとテスト

```sh
zig build
zig build test
```

Zig の版は `build.zig.zon` の `minimum_zig_version`（現在 0.17.0）に固定しています。`zig version` が一致しないと検査は通りません。

## 完了前の検査

作業を終えて報告する前に、必ず次の1コマンドを通してください。CI の quality ワークフローも同じスクリプトを呼ぶので、ローカルと CI の検査内容は同じです。

```sh
python3 scripts/check_all.py
```

最初に失敗した段階で止まり、`check_all: failed at "<段階名>" with exit code N` を出します。どこから実行してもリポジトリのルートで動きます。段階は Zig 版の照合、`zig fmt --check .`、ビルド、テスト、Python の版の表示、ruff、mypy、アーキテクチャ検査の自己テスト、アーキテクチャ検査、コメント検査の自己テスト、コメント検査、npm 公開ツリーのテスト、Quick start 検査の自己テスト、README の Quick start の実行です。ruff と mypy は `uv run --locked` で実行するため、この検査には uv 0.13.1 以上が必要です。必要な版の正本は `pyproject.toml` の `[tool.uv]` の `required-version` です。CI も `.github/workflows/quality.yml` で 0.13.1 を固定しているので、版を上げるときはこの下限もそろえてください。

## 依存

コード（`src/` の Zig、`scripts/` の Python、`npm/` の JavaScript）は各言語の標準ライブラリだけで書きます。コードが使う外部のコードは、`vendor/sqlite3/` に同梱した SQLite だけです。ほかに使ってよいのは、検査にだけ使う開発ツール（`pyproject.toml` の `dev` グループにある ruff と mypy）です。それ以外の依存を足すときは、先に人間の承認を得てください。

## ルールの正本

- アーキテクチャ境界（`src/` に置けるファイルと import の向き）は `scripts/check_architecture.py` が正本です。`src/` にファイルを足すときは、このスクリプトの `APPROVED_FILES` と import の表も更新します。`scripts/test_check_architecture.py` が自己テストです。
- コードにコメントは書きません。説明は `README.md` / `README.ja.md` に書きます。規則の正本は `scripts/check_comments.py`、自己テストは `scripts/test_check_comments.py` です。
- `check_comments.py` は tracked の全ファイルを「コメントを検査する」か「除外する」に分類します。新しい種類のファイルを足すときは、検査対象として扱えるか `EXCLUDED_FILES` に入れるかを決めてください。未分類のまま置くと検査が失敗します。

## npm

npm の版は `build.zig.zon` の `.version` だけを変える。`npm/*/package.json` の `version` は `0.0.0`、`private` は `true` のままにする。公開用ツリーは `python3 scripts/stage_npm.py` が `dist/npm/` に作る。手順は `docs/npm.md`。

## CLAUDE.md

`CLAUDE.md` はこのファイルへの相対 symlink です。内容は `AGENTS.md` にだけ書いてください。
