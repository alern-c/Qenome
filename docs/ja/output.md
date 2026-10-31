# 出力形式

## human（既定）

human は判断に必要なものを出します。

- Summary: 結果の行が一致したか、コピーごとの読んだ行数と書いた行数、判定とその理由、計画が変わったか、`--seed-data` のときは `seed data` と `seed` の行、ペアのラウンドから決めた時間の向き（判定できないときは向きを付けない中央値の比）、計時したときだけ出る `time noise` の行（baseline の A/A 2回の絶対時間差の経験的95パーセンタイルとペア数。参考値であり、判定も終了コードも変えない。詳細は[英語版の `timing.noise_band`](../output.md#timing-evidence-and-advisory-warnings)）、中央値が同じ向きのときの変化の大きさ（`230x faster`）、容量の増分、デバッグビルドのときはその注意。`--write` では `write` のファイル、`returning rows`、`rows changed`、`total changed`、`write runs` を足し、左右比較表にも `rows changed` と `total changed` を足す
- baseline と variant の左右比較表: 読んだ行数、書いた行数、結果の行数、フルスキャン行数、VMステップ数、0 でないときはソート回数と autoindex 行数、計測したときは p25 / p75 の時間、データベースファイルのバイト数
- 両方のコピーの実行計画。`kind` / `covering` / `automatic` は SQLite の文言から読んだヒント
- 助言の警告があるときは `Warnings` の節に `warning: <code>: <message>` の行
- `--suggest` のときは `Suggested by SQLite:` の節。提案ごとに `suggested:N: CREATE INDEX ...` と SQL 本文を出し、表の後ろに `warning: <code>: <message>` の行で、捨てたもの・できなかったことを出す
- `--d1` のときは D1 ブロック: バインディング、設定ファイル、データベース id、ローカルファイル、SQLite の版の違い、本番 D1 についての注意

行が一致しない・比較できない・行の順序が変わったときは、説明と片方だけの件数を足します。例の行は `--show-rows` のときだけ出し、隠しているときはそのフラグで再実行するよう案内します。`--show-binds` を付けるとバインド値も出します。

入力パスのうち `--seed-data` 以外、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件は kv と json にだけ出ます。時間の根拠のうち `effect`、`median_difference_ns`、`confidence_interval` も kv と json にだけ出ます。human の Summary は時間の中央値、向き、A/A ノイズ幅を出します。`--d1` のときは、human も上記の D1 ブロックを出します。

## kv

kv は全項目を1行1項目の `key: value` で出し、スクリプトとログに向きます。human が出さない入力、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件も含みます。`--d1` のときは `d1-binding` / `d1-config` / `d1-database-id` / `d1-local-database` / `d1-sqlite-version` / `d1-sqlite-version-note` / `d1-caution` を加えます。`--seed-data` のときは `seed-data` / `seed` / `seed-rows` / `seed-tables` とテーブルごとの `seed-table` を加えます。`--write` のときは `select` の代わりに `write` を出し、`result-kind`、`write-changes-baseline`、`write-changes-variant`、`write-total-changes-baseline`、`write-total-changes-variant`、`write-runs` を加え、`measure-*` の行も書き込み用の内容にします。`baseline-only-row` / `variant-only-row` は `--show-rows` のときだけ出ます。

## json

json は、比較が終わったときに stdout へ JSON オブジェクトを1個だけ（末尾改行付きで）出します。`--batch` のときは、上記で説明した別の `batch_schema_version` 1 のオブジェクトを出します（「まとめて比べる（--batch）」と [docs/json.md](../json.md) を参照）。`--scale` のときは、サイズごとの比較を並べた別の `scale_schema_version` 1 のオブジェクトを出します（[複数のサイズで測る](usage.md#複数のサイズで測る--scale)を参照）。`--seed-data` のときは、どちらのオブジェクトにもトップレベルの `seed_data` が加わります。フィールド（次のコア変更で予約している名前を含む）は [docs/json.md](../json.md) が仕様です。入力拒否・時間上限・中断のときは stdout を空のままにします。`--format json` のとき、stderr は JSON オブジェクト1個です（`schema_version`、`exit_code`、`error` の `code` / `message` / `hint`）。`human` と `kv` はテキストの `error:` 行のままです。

判定はトップレベルの `verdict` で読めます。

| `verdict` | 意味 |
| --- | --- |
| `improved` | 結果が一致し、variant の読んだ行数が減った |
| `no-effect` | 結果が一致し、variant の読んだ行数が変わらない |
| `needs-check` | 結果は一致するが、variant の読んだ行数か書いた行数が増えた。`verdict_reasons` に理由が入る |
| `not-judged` | 結果が不一致・比較不能。`verdict_reasons` に理由が入る |

`--migration` の batch では、`needs-check` と同じ条件を `regressed` と呼びます。マイグレーションはすでに書かれた変更だからです。マニフェストの `writes` に並べた書き込み文も同じ名前を使い、判定は `rows read` だけで決まります。`rows written` が増えても数値を出すだけで、判定は `no-effect` のままです。単発・`--batch`・`--suggest` の判定は `needs-check` のままです。batch の `summary` の件数キーも `needs_check` のままで、数えるのはクエリだけです。variant だけで実行できるクエリは `not-judged` で、終了コードは変わりません。「まとめて比べる（--batch）」を参照。

判定は、ローカル D1 と同じ数え方（workerd のパッチ）で数えた読んだ行数と書いた行数で決まります。時間は参考値なので、`--runs 0` でも判定は出ます。この数値は、まだ本番 D1 と照合していません。`--write` では、`result` は `RETURNING` の行（`RETURNING` が無ければ空）を比べ、両方のコピーの `changes` と `total_changes` も一致しなければなりません。違えば `mismatch` と終了コード `3` になり、行数からは判定しません。

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

<details>
<summary>主なキーと文字列のエスケープ規則</summary>

主なキー:

| キー | 内容 |
| --- | --- |
| `schema_version` | 形式の版（現在 2。1 は時間判定の版） |
| `statement` | `select` または `write` |
| `exit_code` | 比較結果に対応する終了コード（0 / 3 / 4）。一致したあとの後片付けに失敗した場合は、JSON を書いた後にプロセスが 5 で終わる |
| `verdict` / `verdict_reasons` | 読んだ行数による判定とその理由（`improved` / `no-effect` / `needs-check` / `not-judged`） |
| `result` | 結果行の比較（`match` / `mismatch` / `incomparable`） |
| `row_order` | 行順（`same` / `differs` / `not-applicable`）。一致判定には含めず、`match` のときだけ `same` / `differs` になる参考情報 |
| `result_reasons` | 比較できない理由。各要素は `text` と `hint`（無いときは `null`） |
| `row_differences` | `baseline_only` / `variant_only` の件数。`baseline_only_examples` / `variant_only_examples` は配列のままで、既定は空。`--show-rows` で最大 5 件の例の行が入る |
| `plan_changed` | 実行計画が baseline と variant で変わったか |
| `baseline` / `variant` | それぞれの `rows`、`plan`（`id` / `parent` / `kind` / `covering` / `automatic` / `detail`）、`counters`（`rows_read` / `rows_written` / `fullscan_steps` / `vm_steps` / `sort_ops` / `autoindex_rows`）。`--write` ではさらに `changes` / `total_changes` / `executions` |
| `timing` | `rounds`、`variant_faster_rounds`、`ratio`、`baseline` / `variant` の `median_ns` / `p25_ns` / `p75_ns` / `min_ns` / `max_ns`。計時しなければ `null`、baseline の median が 0 なら `ratio` は `null`。`noise_band`、`confidence_interval`、`median_difference_ns`、`effect`、`unavailable_reason` は下記の時間統計 |
| `size_bytes` | `baseline` / `variant` / `increase`（データベース全体のバイト数。インデックス単体ではない。`--migration` では使用中のバイト数。「まとめて比べる（--batch）」を参照） |
| `inputs` | `database` / `select` / `index_sql` のパス。`--write` では `select` の代わりに `write` |
| `d1` | `--d1` のときだけ出る: `binding` / `config` / `database_id` / `local_database` / `sqlite_version`（D1 側の 3.53.4） / `sqlite_version_note` / `caution` |
| `environment` | `qenome_version`（`--version` と同じ、`build.zig.zon` の版） / `sqlite_version` / `sqlite_source_id` / `zig_version` / `build_mode` / `os` / `arch` / `work_dir_parent` |
| `measurement` | 計時条件（`runs_per_copy`（各コピーの計測ラウンド数。計時しないときは 0）/ `warmup` / `order` / `scope` / `cache`）。`--write` では `runs_per_copy` は各コピーでロールバックしながら実行する回数 |
| `binds` | `number` / `type`。text は `text_bytes` も持つ。`--show-binds` を付けたときだけ値が `value` に入る |
| `warnings` | `{code, message}` の配列（`no_analyze_stats`、`data_too_small`、`bind_dependent_partial_index`、`unapplied_migrations`）。判定と終了コードは変えない |
| `sqlite` | 予約済みで、まだ出ない。`bundled_version` と `db_header_version`。それまでは同梱版を `environment.sqlite_version` で読む |

- 文字列値では、バックスラッシュを `\\`、非 UTF-8 のバイトを `\xNN`（バイト 0xFF なら `\xff`）と書いてから JSON としてエスケープします。4文字の `\xff` は `\\xff` になり、バイト 0xFF とは別の文字列です。元のバイト列に戻すときは、`\\` をバックスラッシュ1個、`\xNN` をそのバイト、それ以外の文字をそのまま読みます。入力パス、計画の detail、理由、bind の text がこの規則です。`--show-rows` で出す例の行の TEXT も同じ規則（前後に `'`。例: `'\xff'`。JSON のテキストでは `'\\xff'`）で、BLOB は `x'00ff'` です。200 バイトを超える例の値は切り詰め、`...(N bytes)` を付けます。
- `binds` は kv と同じ秘匿方針です。`--show-binds` が無いときは値を出さず、番号・型・テキストの長さだけを出します。real の非有限値（`inf` / `-inf`）は JSON 数値にできないため、文字列で出します。
- `row_differences` の件数（`baseline_only` / `variant_only`）は常に出します。例の配列キーも残しますが、既定では空です。行の値を入れるのは `--show-rows` を付けたときだけです。human と kv も同じフラグで、既定では件数だけを出します。human は例を隠しているとき、`--show-rows` で見られると書きます。
- `row_order` は参考情報で、結果の一致判定には含めません。

</details>

## 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 結果が一致した |
| 1 | 入力を拒否した（読めないファイル、不正・拒否された SQL、バインドの不一致、インデックスの作成失敗、`--write` の文の拒否） |
| 2 | 引数の誤り |
| 3 | 結果が一致しない、または `--write` が違う変更をした（`changes` か `total_changes`） |
| 4 | 結果を比較できない、`--write` がスキーマ・現在時刻・非決定的な関数を読むため実行されなかった、または `--d1` がローカルデータベースをちょうど1つに決められない（設定が無い、設定が複数、設定が読めない・不正、バインディングが不明か重複、database id が無い、ローカルファイルが未作成、ローカルファイルを開けない） |
| 5 | 比較のあとの後片付けに失敗した（0 のときだけ置き換え、それ以外のコードはそのまま） |
| 6 | `--migration` で結果の行は一致したが、クエリの読んだ行数か書いた行数が増えた、または書き込み文の読んだ行数が増えた。`--migration` の batch だけが返す |
| 124 | 時間上限に達した（`--timeout-ms`） |
| 129 / 130 / 143 | `SIGHUP` / `SIGINT` / `SIGTERM` による中断（POSIX） |

行数の数え方と判定の意味は、[精度と本番 D1](accuracy.md)で説明しています。

`--format json` は比較結果を `exit_code` に 0 / 3 / 4 で出します。JSON を書いた後にプロセスが 5 で終わることはあります。

`--batch` の報告は、終了コード `1`・`6`・`124` で書かれることがあります。stdout が batch のオブジェクトなら実行は最後まで進み、失敗は報告の中にあります。stdout が空なら実行は途中で止まり、stderr にエラーオブジェクトがあります。


## 時間のぶれ・信頼区間・警告

<details>
<summary>時間のぶれ・信頼区間・警告の詳細</summary>

各ラウンドは baseline を2回実行する A/A のあと、baseline/variant を AB・BA 交互に計時します。比較済みの実行が warmup で、A/A は追加実行です。`noise_band.threshold_ns` は A/A の絶対時間差の経験的95パーセンタイル（nearest rank: ceil(0.95*n)）です。標本数は `pairs`。統計的に校正した有意差閾値ではなく、観測された差が0でも真のばらつき0は意味しません。

`median_difference_ns` はラウンドごとの variant−baseline の差の中央値です。2つの中央値の差ではありません。既存 ratio は variant中央値/baseline中央値のままです。`confidence_interval` は独立同分布の連続な差を仮定する二項分布の順位区間で、将来の単発時間の範囲ではありません。要求水準 `level` は0.95、保守的な理論被覆率が `coverage`。再標本化はしません。式と根拠は [英語版](../output.md#timing-evidence-and-advisory-warnings) を参照してください。

6回未満は `too-few-rounds`（5回の最大有限区間は93.75%、6回は96.875%）、計測時間に0があれば `zero-duration`、差が全同値なら時計分解能を精度と取り違えないよう `no-observed-variation` として区間を null にし、effect は `insufficient-samples` です。区間が0を含むか、差の中央値の絶対値が A/A幅以下なら `no-difference`。それ以外が `faster` / `slower` です。これは補助説明で行数判定・終了コードには影響しません。A/Aを先に測る順序、キャッシュ、負荷のドリフト、時間依存、少数標本があるため、実機や本番で95%を厳密保証するものではありません。human は時間の中央値と、ペアのラウンドから決めた向き、A/A ノイズ幅を出し、中央値が同じ向きのときだけ変化の大きさを添えます。ペアのラウンドで向きを判定できないときは、向きを付けずに中央値の比を出し、判定できないと明記します。上記の時間の根拠のうち `effect`・`median_difference_ns`・`confidence_interval` は kv と json に出します。

`warnings` は非計時・比較不能でも配列として出し、human/kvにも同じcode/messageを表示します。`no_analyze_stats` は候補のインデックスの対象テーブルに、baseline上で空でない sqlite_stat1 エントリがない場合。別表の統計では解消しません。鮮度・完全性は確認せず、部分インデックスの統計だけでも存在扱いです。`data_too_small` はその表の `SELECT 1 ... LIMIT 1000` が1000件未満の場合。1000件到達は「1000件以上」であり、正確な件数ではありません。結果件数・読取行数・統計推定値は使いません。1000は代表性を保証しない目安です。

`bind_dependent_partial_index` は、variant の計画が、バインド値が部分インデックスの `WHERE` 句を満たすためにその部分インデックスを使っている場合に、そのインデックス名を出します。Qenome は variant の計画をバインド値ありで読み、次に全パラメータを `NULL` にして同じ SELECT の計画を読みます。部分インデックスが前者にあって後者にないとき、その名前を出します。`NULL` では部分インデックスの `WHERE` 句を満たすことを示せないため、この差は「バインド値のおかげで使えている」ことを意味します。別の値やパラメータの渡し方では使われなくなり、`improved` はその実行の値でだけ成り立ちます。variant の計画だけで判定できるため、variant だけで計測する `--migration` のクエリでも出します。ただし best-effort です。追加の計画やインデックスのカタログを読めないとき（時間切れ・中断を含む）は警告を出さずに比較を続け、判定・終了コード・batch の件数は変えません。batch では `results[].comparison.warnings` に入り、human は `Warnings` の節にクエリと候補を添えて出します。`no_analyze_stats` と `data_too_small` も、batch と `--suggest` の human では候補ごとに `Warnings` の節へ出ます。

診断は計時後にコピーだけを読み、ANALYZE/PRAGMA optimizeを実行しません。追加実行・診断を既存rows_read/rows_writtenへ混入させません。警告は判定を止めず終了コードも変えません。`no_analyze_stats` と `data_too_small` の診断の失敗・時間上限・中断は既存のエラー処理に従います。`bind_dependent_partial_index` は best-effort で、追加の読み取りに失敗したら警告を出さずに続けます。

</details>
