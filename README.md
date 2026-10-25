# Qenome

Qenome は、ローカル SQLite の SELECT 1本に対して、候補の `CREATE INDEX` を1本試したときの変化を比較する CLI です。
データベースを読み取り専用で開いて隔離コピーを作り、索引の前後で結果・実行計画・時間・容量の増分を示します。元のデータベースは変更しません。

## ビルドと使い方

```sh
zig build
zig-out/bin/qenome app.db select.sql index.sql
zig-out/bin/qenome app.db select.sql index.sql --bind 1:int:1234
zig-out/bin/qenome --db app.db --select select.sql --index-sql index.sql --format kv
zig-out/bin/qenome app.db select.sql index.sql --format json
```

パスは DB・SELECT ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--index-sql` でも指定できます（混在可）。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ）
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータに渡す値。TYPE は int / real / text / null で、繰り返し指定できる。`:name` などの名前付きは最初に現れたときの SQLite の番号（同じ名前は同じ番号）、`?NNN` は NNN を指定する
- `--runs <N>`: 結果が一致したあとの計測ラウンド数（既定 10、0 で計測しない）
- `--timeout-ms <MS>`: 索引作成と SELECT 1回あたりの制限時間（既定 30000、0 で無効）
- `--format <human|kv|json>`: 出力形式（既定 human）。human は判断に使う Summary・左右比較表・実行計画に絞り、kv は入力・版・計時条件まで含む全項目を1行1項目で出し、json は同じ事実と判定を1個の JSON オブジェクトで出す。`--show-binds` を付けるとバインド値も出す。不一致の行の値はどの形式でも既定では出さず、件数だけを出す。`--show-rows` で例を戻す
- `--help`, `-h`: 使い方を表示して終了する
- `--version`: バージョン（`build.zig.zon` の version）を `qenome <version>` で表示して終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

human 出力は集計（Summary）、左右比較表、実行計画を主とし、結果が一致しない・比較できない・行の順序が変わったときに説明と件数を足します。例の行は `--show-rows` のときだけ出し、隠しているときはそのフラグで見られると書きます。入力パス、SQLite と Zig の版、ビルド種別、OS と CPU、作業ディレクトリ、計時条件は `--format kv` と `--format json` に出ます。kv の `baseline-only-row` / `variant-only-row` も `--show-rows` のときだけ出ます。

## 終了コード

0 = 結果が一致、1 = 入力拒否、2 = 引数の誤り、3 = 結果不一致、4 = 比較不能、5 = 後片付け失敗、124 = 時間上限、129 / 130 / 143 = SIGHUP / SIGINT / SIGTERM による中断。

## JSON 出力（CI・エージェント向け）

`--format json` は、比較が終わったときに stdout へ JSON オブジェクトを1個だけ（末尾改行付きで）出します。入力拒否・時間上限・中断では、これまでどおり stdout は空のままで、stderr の error と終了コードで判別します（エラーも JSON で出す機能はありません）。

判定はトップレベルの `verdict` で読めます。

| verdict | 意味 |
| --- | --- |
| `improved` | 仕事量が減り、中央値が 20% 以上下がり、全ラウンドで速い |
| `no-effect` | 計画と件数が同じで、中央値の差が 20% 以内 |
| `needs-check` | 上記以外。`verdict_reasons` に理由が入る |
| `not-judged` | 結果が不一致・比較不能、または `--runs 0`。`verdict_reasons` に理由が入る |

`verdict` だけを読む例:

```sh
qenome app.db select.sql index.sql --format json | jq -r .verdict
```

CI で「結果が一致していて、かつ改善したときだけ通す」例:

```sh
if qenome app.db select.sql index.sql --format json | jq -e '.result == "match" and .verdict == "improved"' > /dev/null; then
  echo "keep the index"
fi
```

主なキー:

| キー | 内容 |
| --- | --- |
| `schema_version` | 形式の版（現在 1） |
| `exit_code` | 比較結果に対応する終了コード（0 / 3 / 4）。後片付けに失敗した場合は、JSON を書いた後にプロセスが 5 で終わる |
| `verdict` / `verdict_reasons` | 時間判定とその理由（`improved` / `no-effect` / `needs-check` / `not-judged`） |
| `result` | 結果行の比較（`match` / `mismatch` / `incomparable`） |
| `row_order` | 行順（`same` / `differs` / `not-applicable`）。一致判定には含めず、`match` のときだけ `same` / `differs` になる参考情報 |
| `result_reasons` | 比較できない理由。各要素は `text` と `hint`（無いときは `null`） |
| `row_differences` | `baseline_only` / `variant_only` の件数。`baseline_only_examples` / `variant_only_examples` は配列のままで、既定は空。`--show-rows` で最大 5 件の例の行が入る |
| `plan_changed` | 実行計画が baseline と variant で変わったか |
| `baseline` / `variant` | それぞれの `rows`、`plan`（`id` / `parent` / `kind` / `covering` / `automatic` / `detail`）、`counters`（`fullscan_steps` / `vm_steps` / `sort_ops` / `autoindex_rows`） |
| `timing` | `rounds`、`variant_faster_rounds`、`ratio`、`baseline` / `variant` の `median_ns` / `p25_ns` / `p75_ns` / `min_ns` / `max_ns`。計時しなければ `null`、baseline の median が 0 なら `ratio` は `null` |
| `size_bytes` | `baseline` / `variant` / `increase`（データベース全体のバイト数。索引単体ではない） |
| `inputs` | `database` / `select` / `index_sql` のパス |
| `environment` | `qenome_version`（`--version` と同じ、`build.zig.zon` の版） / `sqlite_version` / `sqlite_source_id` / `zig_version` / `build_mode` / `os` / `arch` / `work_dir_parent` |
| `measurement` | 計時条件（`runs_per_copy` / `warmup` / `order` / `scope` / `cache`） |
| `binds` | `number` / `type`。text は `text_bytes` も持つ。`--show-binds` を付けたときだけ値が `value` に入る |

- 文字列値では、バックスラッシュを `\\`、非 UTF-8 のバイトを `\xNN`（バイト 0xFF なら `\xff`）と書いてから JSON としてエスケープします。4文字の `\xff` は `\\xff` になり、バイト 0xFF とは別の文字列です。元のバイト列に戻すときは、`\\` をバックスラッシュ1個、`\xNN` をそのバイト、それ以外の文字をそのまま読みます。入力パス、計画の detail、理由、bind の text がこの規則です。`--show-rows` で出す例の行の TEXT も同じ規則（前後に `'`。例: `'\xff'`）で、BLOB は `x'00ff'` です。
- `binds` は kv と同じ秘匿方針です。`--show-binds` が無いときは値を出さず、番号・型・テキストの長さだけを出します。real の非有限値（inf）は JSON 数値にできないため、`"inf"` / `"-inf"` の文字列で出します。
- `row_differences` の件数（`baseline_only` / `variant_only`）は常に出します。例の配列キーも残しますが、既定では空です。行の値を入れるのは `--show-rows` を付けたときだけです。human と kv も同じフラグで、既定では件数だけを出します。human は例を隠しているとき、`examples` に `--show-rows` で見られると書きます。
- `row_order` は参考情報で、結果の一致判定には含めません。

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
