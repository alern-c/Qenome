# アーキテクチャ（工程別の責務・依存・所有者）

[概要](overview.md) · [設計条件](design.md) · [開発と検証](development.md) · [MVPタスク](mvp.md)

この文書は、変更時に「どこを触ってよく、どこへ依存してよいか」を判断するための正本（人間向け）。同じルールの機械向けの対応物は [scripts/check_architecture.py](../scripts/check_architecture.py) で、`scripts/test_check_architecture.py` がその検証になっている。ルールを変えるときは、この文書・チェッカー・自己テストを同じ変更で更新する。作業用の計画文書には依存しない。

## 工程（ファイル）と責務

| ファイル | 責務 | 依存してよいもの |
| --- | --- | --- |
| `src/cli.zig` | 進行役。工程順、資源の寿命、失敗時の分岐、判定から終了コードへの変換、公開APIの互換入口、test入口 | 7つの子モジュール、db、result、std／builtin |
| `src/cli/args.zig` | 引数解析、`--bind` の解析、SQLファイルの読取、usage、入力エラー文言 | db、std |
| `src/cli/control.zig` | `ExitCode`、中断状態（signal handlerが書き、他は借用する）、`finalExitCode`、中断診断 | std、builtin |
| `src/cli/comparison.zig` | 一致・不一致・比較不能の判定と理由・ヒント。接続・statement・writerを受け取らない | db、result、std |
| `src/cli/query.zig` | `QuerySession`（読取専用接続とstatementの所有）、prepare／bind／DDL検査／plan／実行／reset／counter、DB・実行エラー診断、SQLite版文字列 | db、sqlite、result、comparison、control、std |
| `src/cli/workspace.zig` | 一時ディレクトリ（0700）とsnapshot、baseline／variant、`applyCandidate`（variant限定の索引適用）、コピーの容量取得 | db、comparison、control、query、std |
| `src/cli/timing.zig` | ABBA計時、統計、改善判定、plan比較、計時外の進捗表示 | db、comparison、control、query、std |
| `src/cli/report.zig` | 完成した表示データの出力。DB・FFIを呼ばない | result、args、comparison、timing、std／builtin |
| `src/cli/tests.zig` | `run` を通す統合テストと共通fixture。テスト専用で、通常のビルドからは到達しない | 上記すべて、db、sqlite、std |

変更しない層:

- `src/db.zig`: 読取専用接続、SQLの許可リストとauthorizer、snapshot、索引適用の実装。CLI側の資格情報ではなくデータ保護の中心なので、工程分割の対象にしない。
- `src/result.zig`: 結果行の正規化（型とバイト）と比較。
- `src/sqlite.zig`: 同梱SQLiteのFFI。
- `src/main.zig` / `src/root.zig` / `build.zig` / vendor: エントリ・公開面・ビルド・同梱物。`src/cli/tests.zig` の取込みも `src/cli.zig` のtest入口で行う。

## 処理の流れ

```text
args → cli進行役
         ├ workspace: snapshot → baseline / variant
         ├ query: baselineのSELECT準備・bind・候補DDL検査
         ├ workspace: variantへの候補索引適用
         ├ query: baseline / variantの実行・行収集
         ├ comparison: 結果一致・不一致・比較不能とヒント
         ├ timing: 一致時だけABBA計時・統計・改善判定
         ├ workspace: コピーの容量取得
         └ report: 完成した結果の表示
```

## 依存の向き

- 子モジュールは `src/cli.zig` をimportしない（進行役への逆依存を禁止）。例外は `src/cli/tests.zig` だけで、統合テストの入口として `src/cli.zig` 自身が指定のtestブロックから読む。
- 本番モジュールは `src/cli/tests.zig` をimportしない。
- 本番の依存グラフに循環を作らない。`cli → tests → cli` はテスト用の循環として認める。
- 生SQLite API（`sqlite3_*`）を使う本番モジュールは `src/cli/query.zig` だけ。他の工程はdbの操作APIを使う。
- 表示（`report`）と判定（`comparison`）は接続・statementを受け取らない。SQLiteの版とsource idは `query` が取得して文字列として渡す。

許可表（機械検査はこの表と同じものを持つ）:

| 本番ファイル | 許可するプロジェクト依存 |
| --- | --- |
| `src/cli.zig` | `src/db.zig`、`src/result.zig`、7つの子モジュール |
| `src/cli/args.zig` | `src/db.zig` |
| `src/cli/control.zig` | なし |
| `src/cli/comparison.zig` | `src/db.zig`、`src/result.zig` |
| `src/cli/query.zig` | `src/db.zig`、`src/sqlite.zig`、`src/result.zig`、`src/cli/comparison.zig`、`src/cli/control.zig` |
| `src/cli/workspace.zig` | `src/db.zig`、`src/cli/comparison.zig`、`src/cli/control.zig`、`src/cli/query.zig` |
| `src/cli/timing.zig` | `src/db.zig`、`src/cli/comparison.zig`、`src/cli/control.zig`、`src/cli/query.zig` |
| `src/cli/report.zig` | `src/result.zig`、`src/cli/args.zig`、`src/cli/comparison.zig`、`src/cli/timing.zig` |
| `src/cli/tests.zig`（テスト表） | `src/cli.zig`、7つの子モジュール、`src/db.zig`、`src/result.zig`、`src/sqlite.zig` |

`std` と `builtin` はどのファイルでも使える。この表は処理の実行順ではなくソースの依存方向を表す。

## 資源の所有者と寿命

| 資源 | 所有者 | 制約 |
| --- | --- | --- |
| 元DB | `workspace` のコピー準備 | 読取専用でだけ開く。WALを含むsnapshot方式は変えない |
| 一時ディレクトリとコピー | `workspace`（作った `run` が寿命を管理） | 0700で作り、既存名を再利用しない。削除責任は作ったrun |
| variantの索引 | `workspace.applyCandidate` | 自分の `variant_path` にだけ書く。呼び出し側は任意のパスを渡せない |
| 読取接続とstatement | `query.QuerySession` | 呼び出し側の固定位置に置いて開き、開いた値を返したり移動したりしない。statementをfinalizeしてから接続を閉じる |
| SQL・引数・パス・plan・計時サンプル | `run` のarena | 参照する工程が終わるまで保持する |
| 結果行と共有予算 | `runChecked` のcollector | 表示が終わるまで保持する（比較の例示行は借用） |
| 中断フラグ | `control` | signal handlerが書き、`db.StepControl` は借用する。同じプロセスで複数runを並行させない |
| stdout／stderr | `main` | 従来のflushと終了処理を変えない |

解放の順は、statementのfinalize → 接続のclose → 一時ディレクトリの削除。closeまたは削除に失敗したら `cleanup_failed` に集約し、本来0で終わるrunだけを5にする（他の終了コードは上書きしない）。

## 変更するときのルール

- 1つの変更は原則1工程に閉じる。工程をまたぐときは、入力・出力・失敗時の扱いを先に決めてから両方を直す。
- 工程間の契約（型、文言、終了コード、表示の項目と順序）を変えるときは、呼び出し側と関連テストを同じ変更で更新する。
- `src/root.zig` から見える公開名（`max_sql_bytes`、`SqlFileError`、`readSqlFile`、`default_timeout_ms`、`default_runs`、`max_runs`、`ExitCode`、`Args`、`ParseError`、`parseArgs`、`usage`、`run`、`finalExitCode`）を変えるときは、互換の扱いを先に決める。
- この文書・チェッカーのルール表・自己テストのどれかを変えたら、3つを同時に更新する。
- `src/db.zig` の内部（SQL検査、snapshot、資源の解放）を変えるときは、データ保護に関わるので独立レビューを行う。

## 並列開発のルール

- 同じworktreeのwriterは常に1つにする。
- 並列にしてよい: 共有資源・工程間の契約・進行役・公開export・test配線が重ならないタスク（例: 別々の工程の内部改善）。
- 直列にする: 入出力型、進行役、公開export、共通fixture、依存配線を変えるタスク。`src/db.zig` を触るタスク同士。
- worktreeを作る場合は、プロジェクトの規則（最新のリモートをfetchし、Herdrで作成し、ignoredファイルをコピーする）に従う。

## 自動検査（境界チェック）

```sh
python3 --version
python3 scripts/test_check_architecture.py
python3 scripts/check_architecture.py
```

- Python 3.9以上・標準ライブラリのみ。ソースを変更しない。`--root DIR` を付けると別のツリーを検査できる（付けなければスクリプトの位置からリポジトリrootを解決し、作業ディレクトリに依存しない）。
- CIでは [quality.yml](../.github/workflows/quality.yml) の `verify` ジョブが同じコマンドを実行する。ジョブ名と既存のZig検証（版の一致・整形・build・test）は変えない。
- 検出する: 必須ファイル（進行役・7子・tests.zig）の欠落、`src/cli/` 配下の未承認ファイル、許可表外のimport、root外へのimport、子から進行役へのimport、本番からtests.zigへのimport（指定のtest入口以外）、本番依存グラフの循環、対応外のimport形式。違反は `ファイル:行: ルール: 理由` で表示し、0以外で終了する。
- 検出しない（受け入れた限界）: dbメンバ単位の誤用や禁止symbol（例: 通常の関数からテスト専用helperを呼ぶ）、importを経ない間接的な操作、実行時の資源寿命・データ保護・cleanup、Zigの全構文の解析や型解決。文字列やコメントの中の `@import` 風の記述は、コードと区別できないため保守的に失敗させる（正しい書き方でも失敗しうる誤検出を許容する）。
- 検査が通ることは、元DBの保全・後片付け・測定範囲の正しさを意味しない。それらは `zig build test` とレビューで確認する。

## 現状と目標

- 現状: 上の構成は実装済み。境界チェックはローカルで実行でき、`quality.yml` の `verify` に配線している。
- 目標: 工程ごとの変更が他の工程へ波及しにくいこと、不具合の影響範囲を狭められること。完全な障害隔離（同一プロセスのクラッシュ・メモリ破壊）や、1ファイルだけでの機能追加は保証しない。
