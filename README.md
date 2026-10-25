# Qenome

Qenome は、ローカル SQLite の SELECT 1本に対して、候補の `CREATE INDEX` を1本試したときの変化を比較する CLI です。
データベースを読み取り専用で開いて隔離コピーを作り、索引の前後で結果・実行計画・時間・容量の増分を示します。元のデータベースは変更しません。

## ビルドと使い方

```sh
zig build
zig-out/bin/qenome app.db select.sql index.sql
zig-out/bin/qenome app.db select.sql index.sql --bind 1:int:1234
zig-out/bin/qenome --db app.db --select select.sql --index-sql index.sql --format kv
```

パスは DB・SELECT ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--index-sql` でも指定できます（混在可）。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ）
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータに渡す値。TYPE は int / real / text / null で、繰り返し指定できる。`:name` などの名前付きは最初に現れたときの SQLite の番号（同じ名前は同じ番号）、`?NNN` は NNN を指定する
- `--runs <N>`: 結果が一致したあとの計測ラウンド数（既定 10、0 で計測しない）
- `--timeout-ms <MS>`: 索引作成と SELECT 1回あたりの制限時間（既定 30000、0 で無効）
- `--format <human|kv>`: 出力形式（既定 human）。human は判断に使う Summary・左右比較表・実行計画に絞り、kv は入力・版・計時条件まで含む全項目を1行1項目で出す。`--show-binds` を付けるとバインド値も出す
- `--help`, `-h`: 使い方を表示して終了する
- `--version`: バージョン（`build.zig.zon` の version）を `qenome <version>` で表示して終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

human 出力は集計（Summary）、左右比較表、実行計画を主とし、結果が一致しない・比較できない・行の順序が変わったときにだけ説明と例を足します。入力パス、SQLite と Zig の版、ビルド種別、OS と CPU、作業ディレクトリ、計時条件は `--format kv` に出ます。

## 終了コード

0 = 結果が一致、1 = 入力拒否、2 = 引数の誤り、3 = 結果不一致、4 = 比較不能、5 = 後片付け失敗、124 = 時間上限、129 / 130 / 143 = SIGHUP / SIGINT / SIGTERM による中断。

## 守るルール

- 元のデータベースを変更しない（読み取り専用で開く）
- 比較できない結果を「一致」「成功」として報告しない
- 時間だけで改善と判定しない（計画と件数も合わせて見る）
- 容量はデータベース全体の増分であり、索引単体のサイズではない
- 複数文・書込・危険な DDL は拒否する
- 正常・失敗・中断のどの経路でも、接続と一時ファイルを後片付けする

## 開発時の検査

```sh
zig build test
zig fmt --check .
python3 scripts/test_check_comments.py
python3 scripts/check_comments.py
python3 scripts/test_check_architecture.py
python3 scripts/check_architecture.py
```

コードにコメントは書きません。説明はこの README に書き、ルールの正本は検査スクリプトです。
