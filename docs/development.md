# 開発と検証

[概要](overview.md) · [MVPタスク](mvp.md) · [設計条件](design.md)

## 現状と原資料

2026-10-10にmainブランチを確認した。src/main.zigとsrc/root.zigは初期サンプル。この整理ではコード実装、commit、pushを行っていない。

原資料はリポジトリ外のローカルノートで、この文書はその内容を整理したもの。

原資料の「全項目未チェック」という説明と工程0の完了チェックには差がある。工程0は原資料のチェック状態を記録し、今回の実行確認とは区別した。実装済みの判定にはソースと実行結果を使う。

## 環境と既存手順

[build.zig.zon](../build.zig.zon)のminimum_zig_versionは0.17.0。[build.zig](../build.zig)にbuild、run、testの手順がある。[品質チェック設定](../.github/workflows/quality.yml)は版の一致、整形、build、testを検査する。CIの実行結果は今回未確認。

既存の確認コマンドは `zig version`、`zig build --summary all`、`zig build run`、`zig build test --summary all`、`zig fmt --check .`。SQLite比較CLIの実行例は未実装のため掲載しない。

### 工程0の実行確認（2026-10-10、Zig 0.17.0）

同じworktreeで実行した。コマンド実行の前後で `git status --short` は未追跡の作業ファイル4件（task.md、report.md、plan.md、TODO.md）のみで、追跡ファイルの差分は無かった（追跡ファイルの差分はこの記録の追記だけ）。`build.zig`、`build.zig.zon`、`src/*` は既存のまま使い、`zig init` による再初期化はしていない。

- `zig version`：`0.17.0`（`build.zig.zon` の宣言と一致）
- `zig fmt --check .`：出力なし・終了コード0
- `zig build --summary all`：`Build Summary: 3/3 steps succeeded`
- `zig build run`：終了コード0。stdoutは「Run `zig build test` to run the tests.」、stderrは「All your codebase are belong to us.」と「info: arg: ./zig-out/bin/Qenome」。後者は `src/main.zig` の `std.log.info` による引数表示
- `zig build test --summary all`：`Build Summary: 5/5 steps succeeded`

1回目のbuild、run、testはビルドキャッシュが温まっていたため、`--cache-dir /tmp/qenome-cold-cache` で局所キャッシュを作り直して再確認した。`compile exe Qenome debug native success 1s`、`zig build test` は `5/5 steps succeeded; 3/3 tests passed` となり、初回ビルドでも成功する。`build.zig.zon` の依存はすべて例示のコメントで、ネットワーク取得は発生しない。

未確認：Zigの版を固定するツールチェーン設定は無く、`zig version` が0.17.0であることは実行環境に依存する。0.17.0以外の版での挙動は未確認。

## 次の開発の進め方

MVPタスクの順に進める。初期化済みのコードを再生成しない。各工程の未決契約を確認し、最小の変更と検証結果を残す。新しい本番依存、大規模な設計変更、commit、pushは事前確認が必要。

機密ファイル、認証情報、個人情報は読み取り・編集・露出しない。検証用DBはダミーデータで作る。

## 実装時に必要な検証

コード変更後は関連テスト、整形、buildを実行する。挙動の変更にはテストを追加する。入力拒否、WALを含むコピー、元DB保全、結果一致と比較不能、正常・失敗・中断時の後片付けを重点確認する。

固定版・ダミーデータから改善例と効果なし例を再現し、ローカルD1での試用では手順と負担を確認する。実装後は作業ルールに従い品質・性能・安全性の3観点でレビューする。文書のみの今回作業では実装後レビューは対象外。
