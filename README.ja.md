# Qenome

[English](README.md) | 日本語

Qenome は、ローカル SQLite の SELECT 1本に対して、候補の `CREATE INDEX` を1本試したときの変化を比較する CLI です。
データベースを読み取り専用で開いて隔離コピーを作り、索引の前後で結果・実行計画・時間・容量の増分を示します。元のデータベースは変更しません。

## インストール

### ビルド済みバイナリ（GitHub Releases）

[Releases](https://github.com/alern-c/Qenome/releases) ページから、使う環境のアセットと、同じリリースの `SHA256SUMS` をダウンロードします。

配布するアセットは圧縮していないバイナリで、名前は `qenome-<version>-<arch>-<os>`（Windows は `qenome-<version>-<arch>-<os>.exe`）です。例:

- `qenome-0.2.0-x86_64-linux`
- `qenome-0.2.0-aarch64-macos`
- `qenome-0.2.0-x86_64-windows.exe`

ビルド済みバイナリは Linux・macOS・Windows 向けに提供します。リリースページに、そのリリースでビルドしたアセットが並ぶので、`<arch>` と `<os>` が自分の環境に合うものを選んでください。`SHA256SUMS` は sha256sum 形式（SHA-256 のハッシュ、半角スペース2個、ファイル名）です。

実行する前にダウンロードを検証します。次の例では、`0.2.0` とファイル名を、ダウンロードした版とアセットに置き換えてください。

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.2.0-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows（PowerShell）:

```powershell
Select-String 'qenome-0.2.0-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.2.0-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` のハッシュが、`SHA256SUMS` の該当行と同じであることを確認してください（大文字・小文字は問いません）。

次に実行権限を付けて実行します（Linux・macOS）。

```sh
chmod +x qenome-0.2.0-aarch64-macos
mv qenome-0.2.0-aarch64-macos qenome
./qenome --version
```

Windows では `.exe` をそのまま実行できます。

macOS で、公証されていないバイナリという理由で実行を拒否された場合は、システム設定 → プライバシーとセキュリティで許可してください。

### ソースからビルド

必要な Zig は 0.17.0 です（`build.zig.zon` の `minimum_zig_version`。CI もこの版でビルドします）。SQLite は `vendor/sqlite3` に同梱してコンパイルするため、システムの SQLite は不要です。

```sh
zig build
./zig-out/bin/qenome --version
```

`zig build` はバイナリを `zig-out/bin/qenome`（Windows は `zig-out\bin\qenome.exe`）に書き出します。リリースビルドに近い時間を測るには `zig build -Doptimize=ReleaseFast` でビルドしてください。

## 使い方

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
```

パスは DB・SELECT ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--index-sql` でも指定できます（混在可）。位置指定のパスは、まだ指定されていない最初の役割に埋まります。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。複数文・書込・その他の文は拒否します。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ）
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータ N に渡す型付きの値。繰り返し指定できる。N は SQLite のパラメータ番号で、名前付きパラメータは最初に現れたときの番号を共有し、`?NNN` は NNN を使う。TYPE は int / real / text / null（null は値を取らない）。1 からパラメータ数までの各番号をちょうど1回ずつ指定する必要があり、パラメータの無い SELECT に `--bind` は付けられない。値は引数の残り全体なので、text には `:` を含められる
- `--runs <N>`: 結果が一致したあとの計測ラウンド数。各ラウンドは各コピーで SELECT を1回計測する。既定は 10、0 で計測しない、最大 1000。1秒を超える計測は進捗を stderr に出す
- `--timeout-ms <MS>`: 索引作成と SELECT 1回あたりの制限時間。既定は 30000、0 で無効。1回の実行は全体で、データベースのコピーに加えて `(3 + 2 × runs)` 回分の制限時間までかかることがある
- `--format <human|kv|json>`: 出力形式（既定 human）。「出力形式」を参照
- `--show-binds`: バインド値を出す。付けない場合、human はバインドを出さず、kv と json は番号・型・テキストの長さだけを出し、値をログに残さない
- `--show-rows`: 片方のコピーだけが返した例の行を出す。付けない場合、どの形式も件数だけを出して行の値をログに残さない。human はこのフラグで再実行するよう案内する
- `--help`, `-h`: 使い方を表示して終了コード 0 で終了する
- `--version`: `build.zig.zon` の版を `qenome <version>` で表示して終了コード 0 で終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

Qenome はデータベースを読み取り専用で開き、SQLite の backup API を使って、Linux と macOS では `$TMPDIR`（既定は `/tmp`）、Windows では `%TMP%`、`%TEMP%`、`%USERPROFILE%` のうち設定されている最初の場所の下にある非公開ディレクトリへコピーします。このコピーが baseline で、2つ目のコピーが variant になり、候補の索引は variant にだけ作ります。SELECT は両方のコピーで実行し、結果の行を多重集合として比較します（同じ行が同じ回数だけ現れること）。行の順序は参考情報として示し、一致判定には含めません。

結果が一致し、`--runs` が 0 でないとき、SELECT をもう一度両方のコピーで計測します。各コピーには、行の比較に使った計測しないウォームアップが1回あります。計測ラウンドは baseline→variant と variant→baseline を交互に繰り返します（ABBA）。1ラウンドは reset 文から `SQLITE_DONE` までの `sqlite3_step` を、割り込みの確認を含めて計測します。列の読み取り、prepare、bind、計画の取得は計測しません。各コピーは書き込み直後の接続とページキャッシュを再利用するため、キャッシュはウォームです。非公開ディレクトリは、結果にかかわらず終了前に削除します。

Linux と macOS では、このディレクトリを所有者だけがアクセスできる権限（`0700`）で作ります。Windows にはこれに相当する指定がないため、一時ディレクトリのアクセス制御を引き継ぎ、保護はその場所がそのユーザー専用であることに依存します。Qenome は Windows では Ctrl+C と Ctrl+Break、Linux と macOS では SIGINT・SIGTERM・SIGHUP を受けたときに後片付けしますが、コンソールを閉じる・プロセスを強制終了するといった強制的な終了では、コピーが残ることがあります。

時間の判定は終了コードを変えません。

## 出力形式

### human（既定）

human は判断に必要なものを出します。

- Summary: 結果の行が一致したか、時間の判定とその理由、計画が変わったか、時間の中央値とラウンド数、容量の増分、デバッグビルドのときはその注意
- baseline と variant の左右比較表: 行数、フルスキャン行数、VMステップ数、0 でないときはソート回数と autoindex 行数、計測したときは p25 / p75 の時間、データベースファイルのバイト数
- 両方のコピーの実行計画。`kind` / `covering` / `automatic` は SQLite の文言から読んだヒント

行が一致しない・比較できない・行の順序が変わったときは、説明と片方だけの件数を足します。例の行は `--show-rows` のときだけ出し、隠しているときはそのフラグで再実行するよう案内します。`--show-binds` を付けるとバインド値も出します。

入力パス、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件は kv と json にだけ出ます。

### kv

kv は全項目を1行1項目の `key: value` で出し、スクリプトとログに向きます。human が出さない入力、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件も含みます。`baseline-only-row` / `variant-only-row` は `--show-rows` のときだけ出ます。

### json

json は、比較が終わったときに stdout へ JSON オブジェクトを1個だけ（末尾改行付きで）出します。入力拒否・時間上限・中断のときは stdout を空のままにし、stderr のエラーと終了コードで判別します。エラーを JSON で出す機能はありません。

判定はトップレベルの `verdict` で読めます。

| `verdict` | 意味 |
| --- | --- |
| `improved` | 仕事量が減り、中央値が 20% を超えて下がり、全ラウンドで速い |
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
| `exit_code` | 比較結果に対応する終了コード（0 / 3 / 4）。一致したあとの後片付けに失敗した場合は、JSON を書いた後にプロセスが 5 で終わる |
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
| `measurement` | 計時条件（`runs_per_copy`（各コピーの計測ラウンド数。計時しないときは 0）/ `warmup` / `order` / `scope` / `cache`） |
| `binds` | `number` / `type`。text は `text_bytes` も持つ。`--show-binds` を付けたときだけ値が `value` に入る |

- 文字列値では、バックスラッシュを `\\`、非 UTF-8 のバイトを `\xNN`（バイト 0xFF なら `\xff`）と書いてから JSON としてエスケープします。4文字の `\xff` は `\\xff` になり、バイト 0xFF とは別の文字列です。元のバイト列に戻すときは、`\\` をバックスラッシュ1個、`\xNN` をそのバイト、それ以外の文字をそのまま読みます。入力パス、計画の detail、理由、bind の text がこの規則です。`--show-rows` で出す例の行の TEXT も同じ規則（前後に `'`。例: `'\xff'`。JSON のテキストでは `'\\xff'`）で、BLOB は `x'00ff'` です。200 バイトを超える例の値は切り詰め、`...(N bytes)` を付けます。
- `binds` は kv と同じ秘匿方針です。`--show-binds` が無いときは値を出さず、番号・型・テキストの長さだけを出します。real の非有限値（`inf` / `-inf`）は JSON 数値にできないため、文字列で出します。
- `row_differences` の件数（`baseline_only` / `variant_only`）は常に出します。例の配列キーも残しますが、既定では空です。行の値を入れるのは `--show-rows` を付けたときだけです。human と kv も同じフラグで、既定では件数だけを出します。human は例を隠しているとき、`--show-rows` で見られると書きます。
- `row_order` は参考情報で、結果の一致判定には含めません。

### 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 結果が一致した |
| 1 | 入力を拒否した（読めないファイル、不正・拒否された SQL、バインドの不一致、索引の作成失敗） |
| 2 | 引数の誤り |
| 3 | 結果が一致しない |
| 4 | 結果を比較できない |
| 5 | 比較のあとの後片付けに失敗した（0 のときだけ置き換え、それ以外のコードはそのまま） |
| 124 | 時間上限に達した（`--timeout-ms`） |
| 129 / 130 / 143 | `SIGHUP` / `SIGINT` / `SIGTERM` による中断（POSIX） |

`--format json` は比較結果を `exit_code` に 0 / 3 / 4 で出します。JSON を書いた後にプロセスが 5 で終わることはあります。

## 守るルール

- 元のデータベースを変更しない（読み取り専用で開く）
- 比較できない結果を「一致」「成功」として報告しない
- 時間だけで改善と判定しない（計画と件数も合わせて見る）
- 容量はデータベース全体の増分であり、索引単体のサイズではない
- 複数文・書込・危険な DDL は拒否する
- 正常・失敗・中断のどの経路でも、接続と一時ファイルを後片付けする

## 開発時の検査

```sh
zig fmt --check .
zig build
zig build test
python3 scripts/test_check_comments.py
python3 scripts/check_comments.py
python3 scripts/test_check_architecture.py
python3 scripts/check_architecture.py
```

コードにコメントは書きません。説明は README に書き、ルールの正本は検査スクリプトです。

## ライセンス

Qenome は Apache License 2.0 で公開しています。全文は [LICENSE](LICENSE) を参照してください。
