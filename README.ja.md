<div align="center">

<img src="docs/logo.svg" width="96" height="96" alt="Qenome のロゴ。2回ねじれる DNA 二重らせんと、1か所だけ色の違う塩基対">

# Qenome

**インデックスをマージする前に、そのインデックスがクエリの役に立つかを調べる CLI。**

[![npm の版](https://img.shields.io/npm/v/qenome?style=flat-square)](https://www.npmjs.com/package/qenome)
[![ライセンス: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](LICENSE)
[![品質検査](https://github.com/alern-c/Qenome/actions/workflows/quality.yml/badge.svg)](https://github.com/alern-c/Qenome/actions/workflows/quality.yml)

[English](README.md) | 日本語

<img src="docs/demo.gif" width="860" alt="D1 のサンプルプロジェクトで qenome --d1 DEMO_DB select.sql index.sql --runs 40 を実行するターミナル。結果の行が一致し、判定が improved で、D1 ブロックに SQLite の版と注意が出ている">

</div>

<p align="center"><sub>この録画は <a href="#サンプルプロジェクトを試す"><code>examples/d1-toml</code></a> のもの。サンプルは手元でコマンド2本で再現できます。</sub></p>

読み取り専用の `SELECT` を1本と、候補の `CREATE INDEX` を1本渡します。ローカルの SQLite ファイル、またはローカルの Cloudflare D1（`--d1 <BINDING>` と `--config`）をサンドボックスのコピーにして比較します。元のデータベースは変更しません。

## 特徴

- **元のデータベースは変更しません。** 読み取り専用で開き、サンドボックスのコピーで比較するので、役に立たない候補のインデックスはマージの前に捨てられます。
- **判定は時間ではなく、読んだ行数。** 読んだ行数と書いた行数は、ローカル D1 と同じ数え方（workerd のパッチ）。`--runs 0` でも判定は残り、計時だけを省きます。
- **結果の行も照合します。** 2つのコピーが同じ行を同じ回数返すかを多重集合として比べ、一致しない・比較できない結果は合格にせず報告します。
- **ローカル D1 のバインディングだけで試せます。** `--d1 <BINDING>` が wrangler の設定からローカルデータベースを探し、`--config` で設定ファイルを指定できます。
- **複数のクエリをまとめて比較。** `--batch <FILE>` は JSON のマニフェストにある全 SELECT と全候補 `CREATE INDEX` を組み合わせて、各組み合わせの判定を出します。[まとめて比べる（--batch）](#まとめて比べる--batch)を参照してください。
- **クエリから候補のインデックスを探せます。** `--suggest` は SQLite の expert に候補のインデックスを提案させて比較するので、SELECT ファイルだけで済みます。[候補のインデックスを提案させる（--suggest）](#候補のインデックスを提案させる--suggest)を参照してください。
- **AI エージェントと CI 向けの JSON。** `--format json` は `schema_version` 2 のレポートを出し、終了コードが一致・不一致・比較不能を分けます。
- **判定の根拠も同じレポートに。** 実行計画、時間の中央値、データベース全体の容量の増分、助言の警告を出します。

> この数値は、まだ本番 D1 と照合していません。Qenome が測るのはローカルのデータベースだけです。

## 目次

- [特徴](#特徴)
- [インストール](#インストール)
- [ローカル D1 を調べる](#ローカル-d1-を調べる)
- [AI エージェントと使う](#ai-エージェントと使う)
- [なぜ他の方法ではないのか](#なぜ他の方法ではないのか)
- [クイックスタート](#クイックスタート)
- [使い方](#使い方)
- [サンドボックス用のデータを作る](#サンドボックス用のデータを作る)
- [まとめて比べる（--batch）](#まとめて比べる--batch)
- [出力形式](#出力形式)
- [守るルール](#守るルール)
- [開発時の検査](#開発時の検査)
- [ライセンス](#ライセンス)

この README だけで、D1 の開発者またはその AI エージェントは、数分でローカル D1 の判定を取れます。[ローカル D1 を調べる](#ローカル-d1-を調べる)と [AI エージェントと使う](#ai-エージェントと使う)を見てください。

## インストール

### npm

Linux と macOS の x64 と arm64 では、次で実行できます。

```sh
npx qenome --version
```

D1 のプロジェクトでは、このコマンドで Qenome を実行します。`npx` はパッケージを取得し、グローバルにはインストールしません。バイナリが `PATH` に無いときは、下の例の `qenome` を `npx qenome` に置き換えてください。`npm install --global qenome` でも同じコマンドが入ります。

入るのは小さなランチャーと、そのマシン向けのバイナリ1つです（`@qenome-cli/linux-x64`、`@qenome-cli/linux-arm64`、`@qenome-cli/darwin-x64`、`@qenome-cli/darwin-arm64` のいずれか）。版は `build.zig.zon` の `.version` で、組み立てと公開の手順は [docs/npm.md](docs/npm.md) にあります。Windows は npm の対象外なので、下のビルド済みバイナリを使ってください。

### ビルド済みバイナリ（GitHub Releases）

[Releases](https://github.com/alern-c/Qenome/releases) ページから、使う環境のアセットと、同じリリースの `SHA256SUMS` をダウンロードします。

配布するアセットは圧縮していないバイナリで、名前は `qenome-<version>-<arch>-<os>`（Windows は `qenome-<version>-<arch>-<os>.exe`）です。例:

- `qenome-0.3.3-x86_64-linux`
- `qenome-0.3.3-aarch64-macos`
- `qenome-0.3.3-x86_64-windows.exe`

ビルド済みバイナリは Linux・macOS・Windows 向けに提供します。リリースページに、そのリリースでビルドしたアセットが並ぶので、`<arch>` と `<os>` が自分の環境に合うものを選んでください。`SHA256SUMS` は sha256sum 形式（SHA-256 のハッシュ、半角スペース2個、ファイル名）です。

実行する前にダウンロードを検証します。次の例では、`0.3.3` とファイル名を、ダウンロードした版とアセットに置き換えてください。

<details>
<summary>Linux・macOS・Windows のチェックサム確認コマンドを表示</summary>

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.3.3-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows（PowerShell）:

```powershell
Select-String 'qenome-0.3.3-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.3.3-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` のハッシュが、`SHA256SUMS` の該当行と同じであることを確認してください（大文字・小文字は問いません）。

</details>

次に実行権限を付けて実行します（Linux・macOS）。

```sh
chmod +x qenome-0.3.3-aarch64-macos
mv qenome-0.3.3-aarch64-macos qenome
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

## ローカル D1 を調べる

データベースがローカルの Cloudflare D1 で、インデックスをマージする前に判定が欲しいときに使います。必要なものは、`npx` のための Node.js、wrangler のプロジェクト、`SELECT` を1本入れたファイル、`CREATE INDEX` を1本入れたファイルです。

ローカルのデータベースがまだ無いときは、一度だけ作ります。`DB` は `d1_databases` のバインディング名です。

```sh
npx wrangler d1 execute DB --local --command "SELECT 1"
```

そのプロジェクトのディレクトリで実行します。

```sh
npx qenome --d1 DB select.sql index.sql --runs 0 --format json
```

`--runs 0` は計時を飛ばし、判定は出します。終了ステータス `0` は結果の行が一致したという意味です。JSON の `verdict` を読みます。`improved` は variant の読んだ行数が減った、`no-effect` は減らなかった、`needs-check` は読んだ行数か書いた行数が増えた、という意味です。数値はローカル D1 と同じ数え方（workerd のパッチ）です。この数値は、まだ本番 D1 と照合していません。

カレントディレクトリ以外の wrangler ファイルは `--config <PATH>` で指定します。探し方は [D1 のローカルデータベース](#d1-のローカルデータベース)に、JSON のフィールドは [docs/json.md](docs/json.md) に書いてあります。

`wrangler.toml` 付きの動くサンプルは [サンプルプロジェクトを試す](#サンプルプロジェクトを試す)です。

## AI エージェントと使う

D1 のスキーマを変えるエージェントは、`CREATE INDEX` を残す前に Qenome を実行します。手順は [skills/qenome/SKILL.md](skills/qenome/SKILL.md) です。いつ実行するか、`--d1` と `--config` の渡し方、`schema_version` 2 の読み方、終了コードと warnings への対応が書いてあります。

エージェントにはそのファイルを渡してください。機械が読む報告は `--format json` で、仕様は [docs/json.md](docs/json.md) です。

## なぜ他の方法ではないのか

**EXPLAIN QUERY PLAN。** 計画は、SQLite がインデックスに触るつもりかを示します。データのコピーに対して `SELECT` を実行しないので、結果の行が変わったか、何行読み書きしたか、データベースファイルがどれだけ増えたかは出ません。Qenome は両方のサンドボックスコピーで文を実行し、ローカル D1 と同じ数え方（workerd のパッチ）で数えます。

**`wrangler d1 execute --local`。** ローカルの wrangler は、呼び出し全体の所要時間を1つ出せます。その時間は実行のたびに動き、候補のインデックスをコピー上に作って現在のスキーマと比較することはしません。Qenome は元のデータベースを変えず、行数でインデックスを判定します。時間はその判定の横に置く参考値です。

**本番 D1 のメトリクス。** この数値は、まだ本番 D1 と照合していません。Qenome が測るのはローカルのデータベースだけです。

**インデックスを入れてアプリを見る。** それは出荷するデータベースへインデックスを書き込みます。Qenome はサンドボックスのコピーで試すので、役に立たない候補はマージの前に捨てられます。

## クイックスタート

この手順では、テスト用データベースを作り、Qenome をビルドし、6つの例を実行します。コマンドはリポジトリのルートで、ブロックごとに Linux か macOS で実行してください。必要なものは Zig 0.17.0（「ソースからビルド」を参照）と `sqlite3` コマンドラインツールです。`sqlite3` は SQL ファイルを新しいデータベースへ読み込みます。

`testdata/schema.sql` と `testdata/seed.sql` からテスト用データベースを作ります。`verify.sql` は17項目それぞれについて `ok` を1行出力し、期待値と違う値があればその時点で失敗します。

```sh
mkdir -p testdata/generated
rm -f testdata/generated/qenome-fixture.db
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/schema.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/seed.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/verify.sql"
```

Qenome をビルドします。

```sh
zig build
```

6つの例は `zig-out/bin/qenome` を実行します。各コマンドの末尾には、その例が返すべき結果（Summary の `result` と `verdict`、batch では `recommended`、終了コード）を書いてあります。`python3 scripts/check_all.py` と CI の quality ワークフローは、これらの行を書いてあるとおりに実行するので、README とプログラムのずれは見つかります。`--runs 40` は、負荷のあるマシンでも中央値を安定させるための指定です（既定は `10`）。

全走査をなくすインデックス: 候補のインデックスで `SCAN events` が `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` に変わり、読んだ行数が 200,000 から 101 に減り、両方のコピーが同じ100行を返します。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 40  # expect: result=match verdict=improved exit=0
```

自分で選んだデータでインデックスを試す: `--seed-data testdata/seed.json` は、元のデータベースを変えずに、サンドボックスのコピーの `events` を 50,000 行の決まったデータで置き換えます。同じクエリはその中の `1234` の行を見つけ、判定は `improved` のままです。「サンドボックス用のデータを作る」を参照してください。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --seed-data testdata/seed.json --runs 0  # expect: result=match verdict=improved exit=0
```

効果のないインデックス: SELECT が列を `lower()` で包むため、SQLite は `status` のインデックスを使えません。計画・読んだ行数・書いた行数は変わりません。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/no-effect.sql testdata/cases/no-effect.index.sql --bind 1:text:ok --runs 40  # expect: result=match verdict=no-effect exit=0
```

比較できない SELECT: `ORDER BY random()` は実行するたびに別の行を選ぶため、Qenome は行が一致したと報告せず、比較できないと報告します。この例では SELECT を計測も判定もしません。ここでの終了コード 4 は期待どおりの結果で、エラーではありません。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/incomparable.sql testdata/cases/incomparable.index.sql  # expect: result=incomparable verdict=not-judged exit=4
```

batch は、複数のクエリと複数の候補のインデックスを1回の実行で比べます。`testdata/batch.json` は改善する例と効果のない例を、2つの候補のインデックスそれぞれと組み合わせます。Qenome は組ごとに1行を出し、不一致がなく改善した候補をおすすめするので、`cases/improved.index.sql` だけが資格を得ます。「まとめて比べる（--batch）」を参照してください。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db --batch testdata/batch.json  # expect: recommended=cases/improved.index.sql exit=0
```

提案されたインデックス（インデックスのファイルなし）: `--suggest` は SQLite に、その SELECT に効くインデックスを尋ね、Qenome がその提案を同じ batch の仕組みで比べます。提案には `suggested:1` というラベルが付き、効けばおすすめになります。「候補のインデックスを提案させる（--suggest）」を参照してください。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql --bind 1:int:1234 --suggest  # expect: recommended=suggested:1 exit=0
```

データベースの作成はおよそ1秒、計測する例はそれぞれ数秒で終わります。fixture・クエリ・期待する計画と件数は `testdata/README.md` に記録しています。

## 使い方

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
qenome app.db select.sql index.sql --seed-data seed.json
qenome --d1 DB select.sql index.sql
qenome app.db --batch batch.json
qenome app.db --batch batch.json --migration 0002_replace_index.sql
qenome app.db select.sql --suggest
qenome app.db --batch batch.json --suggest
```

パスは DB・SELECT ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--index-sql` でも指定できます（混在可）。位置指定のパスは、まだ指定されていない最初の役割に埋まります。`--d1` のときは、位置指定の2つのパスが SELECT と CREATE INDEX の役割に入ります。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。複数文・書込・その他の文は拒否します。`--migration` のファイルだけは例外で、`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX` を複数書けます（「まとめて比べる（--batch）」を参照）。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ。`--d1` とは併用しない）
- `--d1 <BINDING>`: wrangler 設定の `d1_databases` にあるこのバインディングのローカル D1 データベースを `--db` の代わりに使う。「D1 のローカルデータベース」を参照
- `--config <PATH>`: `--d1` が読む wrangler 設定（既定はカレントディレクトリの `wrangler.toml` / `wrangler.jsonc` / `wrangler.json`）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ）
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--batch <FILE>`: JSON のマニフェストにある全 SELECT を、全候補 CREATE INDEX と1回の実行で比べる。「まとめて比べる（--batch）」を参照。`--select` / `--index-sql` / `--bind` / 位置指定の SELECT・INDEX、`--runs`、`--format kv` とは併用できない
- `--migration <FILE>`: `--batch` の全クエリを実行する前に、この SQL ファイルを variant にだけ適用する。`--batch` と、`candidates` を持たないマニフェストが必要。`--select` / `--index-sql` / `--bind` / `--runs` / `--suggest` / `--format kv` とは併用できない。`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX` だけを受け付ける。「まとめて比べる（--batch）」を参照
- `--seed-data <FILE>`: 比較の前に、この JSON の指定に従ってサンドボックスのコピーのテーブルを決まったダミーデータで置き換える。元のデータベースは変更しない。`--batch`・`--suggest`・`--migration` を含むすべてのモードで使える。「サンドボックス用のデータを作る」を参照
- `--suggest`: インデックスを自分で用意する代わりに、SQLite の expert に候補のインデックスを提案させ、その提案を比べる。`--batch` のときはマニフェストの `candidates` を省略できる。`--runs`、`--format kv`、インデックスのファイル（`--index-sql` または3番目の位置指定パス）とは併用できない。「候補のインデックスを提案させる（--suggest）」を参照
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータ N に渡す型付きの値。繰り返し指定できる。N は SQLite のパラメータ番号で、名前付きパラメータは最初に現れたときの番号を共有し、`?NNN` は NNN を使う。TYPE は int / real / text / null（null は値を取らない）。1 からパラメータ数までの各番号をちょうど1回ずつ指定する必要があり、パラメータの無い SELECT に `--bind` は付けられない。値は引数の残り全体なので、text には `:` を含められる
- `--runs <N>`: 結果が一致したあとの計測ラウンド数。各ラウンドは各コピーで SELECT を1回計測する。既定は 10、0 で計測しないが読んだ行数と判定は残る、最大 1000。1秒を超える計測は進捗を stderr に出す
- `--timeout-ms <MS>`: インデックス作成と SELECT 1回あたりの制限時間。既定は 30000、0 で無効。1回の実行は全体で、データベースのコピーに加えて `(3 + 4 × runs)` 回分の制限時間に加え、最大3つの診断文それぞれの制限時間までかかることがある
- `--format <human|kv|json>`: 出力形式（既定 human）。「出力形式」を参照
- `--show-binds`: バインド値を出す。付けない場合、human はバインドを出さず、kv と json は番号・型・テキストの長さだけを出し、値をログに残さない
- `--show-rows`: 片方のコピーだけが返した例の行を出す。付けない場合、どの形式も件数だけを出して行の値をログに残さない。human はこのフラグで再実行するよう案内する
- `--help`, `-h`: 使い方を表示して終了コード 0 で終了する
- `--version`: `build.zig.zon` の版を `qenome <version>` で表示して終了コード 0 で終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

Qenome はデータベースを読み取り専用で開き、SQLite の backup API を使って、Linux と macOS では `$TMPDIR`（既定は `/tmp`）、Windows では `%TMP%`、`%TEMP%`、`%USERPROFILE%` のうち設定されている最初の場所の下にある非公開ディレクトリへコピーします。このコピーが baseline で、2つ目のコピーが variant になり、候補のインデックスは variant にだけ作ります。`--seed-data` を付けると、Qenome は variant を作る前に baseline へ spec の行を入れるので、両方のコピーが同じダミーデータを持ちます。SELECT は両方のコピーで実行し、結果の行を多重集合として比較します（同じ行が同じ回数だけ現れること）。行の順序は参考情報として示し、一致判定には含めません。

読んだ行数と書いた行数は、この最初の1回の実行から取るので追加のコストはなく、`--runs 0` でも残ります。結果が一致し、`--runs` が 0 でないとき、SELECT をもう一度両方のコピーで参考値として計測します。各コピーには、行の比較に使った計測しないウォームアップが1回あります。計測ラウンドは baseline→variant と variant→baseline を交互に繰り返します（ABBA）。1ラウンドは reset 文から `SQLITE_DONE` までの `sqlite3_step` を、割り込みの確認を含めて計測します。列の読み取り、prepare、bind、計画の取得は計測しません。各コピーは書き込み直後の接続とページキャッシュを再利用するため、キャッシュはウォームです。非公開ディレクトリは、結果にかかわらず終了前に削除します。

Linux と macOS では、このディレクトリを所有者だけがアクセスできる権限（`0700`）で作ります。Windows にはこれに相当する指定がないため、一時ディレクトリのアクセス制御を引き継ぎ、保護はその場所がそのユーザー専用であることに依存します。Qenome は Windows では Ctrl+C と Ctrl+Break、Linux と macOS では SIGINT・SIGTERM・SIGHUP を受けたときに後片付けしますが、コンソールを閉じる・プロセスを強制終了するといった強制的な終了では、コピーが残ることがあります。

判定は読んだ行数から決まり、終了コードを変えません。

読んだ行数と書いた行数は、ローカル D1 と同じ数え方（workerd のパッチ）です。Qenome は同梱 SQLite を `workerd` の行数カウントのパッチ付きでビルドします。この数値は、まだ本番 D1 と照合していません。どちらのカウンタも 32 ビットで、それぞれの回数が 1回の実行で 4,294,967,295 を超えると一周して小さい値に戻るため、その場合は巻き戻った値を報告し、判定もその値で比較します。パッチの出どころは `NOTICE`、当て直す手順は `vendor/sqlite3/PROVENANCE.txt` に記録しています。

### サンドボックス用のデータを作る

`--seed-data spec.json` は、比較の前にサンドボックスのコピーへ決まったダミーデータを入れます。ローカルのデータベースが空でも少量でも、インデックスが何行読むかを確かめられます。元のデータベースは読み取り専用で開くだけで、変更しません。ダミーデータは baseline のコピーに入り、そのコピーが variant にもなります。

spec は JSON オブジェクト1個です。`tables` はテーブル名から `rows` と任意の `columns` への対応です。書かない列は SQLite の既定値か rowid になりますが、既定値はリテラルに限ります。式の既定値を持つ列は、生成する行を再現できるよう spec に書いてください。`seed` は任意で、既定は `0` です。

```json
{
  "seed": 7,
  "tables": {
    "events": {
      "rows": 50000,
      "columns": {
        "id": { "kind": "sequence" },
        "customer_id": { "kind": "sequence" },
        "status": { "kind": "ratio", "value": "ok", "ratio": 0.5, "otherwise": "failed" },
        "note": { "kind": "fixed", "value": null }
      }
    }
  }
}
```

各列は `kind` を1つ持ちます。

| `kind` | キー | 意味 |
| `fixed` | `value` | すべての行で同じ値 |
| `uniform` | `values` | 値のどれかを同じ確率で選ぶ |
| `ratio` | `value`、`ratio`、任意の `otherwise` | 指定した割合（`0`〜`1`）の行で `value`、残りで `otherwise`（既定は `null`） |
| `sequence` | 任意の `from`（既定 `1`）と `step`（既定 `1`） | 行ごとに `step` ずつ増える整数 |

JSON の文字列は TEXT、整数は INTEGER、小数を含む数は REAL、`true` / `false` は 1 / 0、`null` は NULL になります。spec に書いたテーブルは先に空にしてから入れるので、行数は `rows` と正確に一致します。書かないテーブルはそのままです。spec に書いたテーブルにトリガーがあると、ほかのテーブルを変えたり seed が制御できない値を生成したりするため、Qenome はそのテーブルを拒否します。大文字小文字だけが違うテーブル名・列名も拒否します。上限は 100 テーブル、1テーブル 10,000,000 行、合計 20,000,000 行です。`--seed-data` は `--batch`・`--suggest`・`--migration` を含むすべてのモードで使えます。

同じ spec と同じ `seed` なら、実行のたびに同じ行になります。レポートに残した比較を再現できます。値は1つのトランザクションで入れ、その中で spec に書いた各テーブルに `ANALYZE` を実行します。そのためプランナは生成した行の統計を見られ、`no_analyze_stats` はこれらのテーブルには当てはまりません。PRIMARY KEY・UNIQUE・NOT NULL・CHECK などの制約に違反すると、SQLite のメッセージを添えて終了コード `1` で止まります。テーブルが `ON CONFLICT IGNORE` や `ON CONFLICT REPLACE` を宣言していても同じです。外部キーはサンドボックスのコピーでは検査しません（SQLite の既定）ので、テーブルはどの順に書いてもかまいません。ダミーデータの生成は `--timeout-ms` の対象外です。Ctrl+C で止めるとコピーも削除します。ダミーデータは非公開のコピーにだけ入り、終了前に削除します。

human の Summary には `seed data` と `seed` の行、kv には `seed-data`・`seed`・`seed-rows`・`seed-tables` とテーブルごとの `seed-table`、json には `path`・`seed`・`rows`・`tables` を持つトップレベルの `seed_data` が加わります。

### D1 のローカルデータベース

`--d1 <BINDING>` は、`--db` で指定したファイルの代わりに Cloudflare D1 のローカルコピーを比較します。wrangler 設定のトップレベルの `d1_databases` を読み、バインディング名からそのコピーを探します。

- 設定はカレントディレクトリの `wrangler.toml` / `wrangler.jsonc` / `wrangler.json`。`--config <PATH>` を付けるとその1ファイルを使う。JSONC のコメント（`//` と `/* */`）と末尾カンマを許す
- データベース id は `preview_database_id` があればそれを、無ければ `database_id` を使う（wrangler のローカル開発と同じ選び方）
- ファイルは `<設定ファイルのディレクトリ>/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/<id>.sqlite`。`<id>` は miniflare がデータベース id から導出する識別子。この規則は wrangler 3.114.17 と 4.152.0 が書いたローカル DB で確認した

```sh
qenome --d1 DB select.sql index.sql
qenome --d1 DB select.sql index.sql --config packages/api/wrangler.toml
```

1つに決められないときは比較せず、理由を stderr に出し、stdout を空のまま終了コード 4 で止まります。

- カレントディレクトリに設定ファイルが無い（`--config` を付けるか、wrangler プロジェクトで実行する）
- 設定ファイルが複数あり、設定自体が曖昧
- バインディング名がトップレベルの `d1_databases` に無い、または複数ある
- バインディングに `database_id` も `preview_database_id` も無い
- ローカルの `.sqlite` がまだ無い。プロジェクトで `npx wrangler d1 execute DB --local --command "SELECT 1"` を実行するか、`npx wrangler dev` でデータベースを1回使って作る

`--d1` の比較では、どの形式でも次の2点を出します。

- 比較に使う同梱 SQLite は 3.53.4 で、D1 のローカルエンジンが動かすのも同じ版。ただしビルドのコンパイルオプションが違うため、計画と時間が変わりうる。D1 は `select sqlite_version()` を拒否するため、3.53.4 は wrangler のローカルエンジンに埋め込まれた版文字列から確認した値
- 時間はこのローカルコピーで測ったもので、本番 D1 の速さを保証しない

`[env.<name>]` ごとの設定と独自の保存先（`--persist-to`）は読みません。

#### サンプルプロジェクトを試す

`examples/d1-toml` と `examples/d1-jsonc` には、同じデータベースとクエリを `wrangler.toml` 版と `wrangler.jsonc` 版で置いています。どちらも独立した wrangler プロジェクトで、設定には `DEMO_DB` のバインディング1つだけがあり、`database_id` はデプロイしないプレースホルダーです。wrangler は `npx` で動かすため Node.js が要ります。リポジトリには何もインストールせず、`.wrangler/` は Git の追跡対象外です。

`examples/d1-toml` で次のコマンドを実行します。`examples/d1-jsonc` でも同じコマンドが動きます。

```sh
npx wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql
qenome --d1 DEMO_DB select.sql index.sql --runs 40
```

1行目が `.wrangler/` にローカルのデータベースを作り、20万行を投入します。2行目が `select.sql` と `index.sql` の候補のインデックスを比較し、`result rows` が `match`、`verdict` が `improved`、実行計画が `SCAN events` から `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` に変わり、D1 ブロックに SQLite の版と注意が出ます。終了コードは 0 です。

`schema.sql` は `events` を作り直すので、いつでも再実行できます。デプロイはしません。`qenome` は PATH 上のものを使う想定で、[ソースからビルド](#ソースからビルド) の直後は `./zig-out/bin/qenome` です。`4.152.0` はサンプルを確認した wrangler の版です。

### まとめて比べる（--batch）

`--batch manifest.json` は、マニフェストにある全 SELECT を、全候補 `CREATE INDEX` と比べます。マニフェストは2つの配列を持つ JSON オブジェクトです。

```json
{
  "queries": [
    { "select": "queries/orders.sql", "binds": ["1:int:1234"] },
    { "select": "queries/recent.sql" }
  ],
  "candidates": [
    { "index_sql": "candidates/a.sql" },
    { "index_sql": "candidates/b.sql" }
  ]
}
```

- `queries` は1〜100件。`candidates` は1〜100件で、`--suggest` が提案を足すとき、または `--migration` が variant の変更を渡すときは省略（または `[]`）できる。マニフェストは1 MiBまで。
- 同じパスを `queries` の中で2回、または `candidates` の中で2回書くことはできない。
- `--migration` のとき、`candidates` は省略または `[]` にし、マニフェストは `queries` だけを持つ。
- `select` と `index_sql` はファイルのパス。カレントディレクトリではなく、マニフェストのディレクトリを基準に解決する。各ファイルは読み取り専用の SELECT 1本、または `CREATE INDEX` 1本で、1 MiBまで。
- `binds` は任意で、`--bind` と同じ `N:TYPE:VALUE` 形式。パスとバインド値は NUL バイトを含まない JSON 文字列にする。
- `select` と `index_sql` の文字列は、書いたとおりに報告へ出す。

Qenome はデータベースを1回コピーし、何かを実行する前に全 SELECT と全候補を検査します。そのあと候補をマニフェスト順に処理し、候補ごとに baseline をもう一度コピーして、そのコピーにだけインデックスを作り、全クエリを両方のコピーで実行します。baseline の SELECT は候補ごとに実行し直します。

`--migration <FILE>` を付けると、variant の変更は候補インデックスではなく、マイグレーションのファイル全体になります。ファイルは 1 MiB までです。Qenome は variant を触る前にファイルを検査し、セミコロンで区切った `CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX` だけを許可します。そのあと文をファイル順に variant にだけ適用するので、同じ名前のインデックスを落として作り直せます。各文は `--timeout-ms` の制限時間を持ちます。元のデータベースは変更しません。レポートには、human では `migration:` の節、json ではトップレベルの `migration` オブジェクトとして、パスと適用した全文を出します。結果の行が一致しても、マイグレーション後にクエリの読んだ行数か書いた行数が増えた場合、そのクエリの判定は `regressed` になります。human の `Results` 表は `regressed`、JSON は `results[].comparison.verdict` が `"regressed"` です。`summary` の件数キーは `needs_check` のままで、そのクエリを数えます。batch の終了コードは `6` です。結果の不一致 `3`、変更の拒否 `1`、時間切れ `124`、比較不能 `4` が優先されます。`no-effect` だけなら `0` です。ほかのモードでは同じ条件を `needs-check` と呼びます。`no_analyze_stats` と `data_too_small` の警告は、マイグレーションが複数のテーブルを触り得るため出しません。

`--migration` の `size increase` は、ファイルサイズの差ではなく、使用中ページが持つバイト数（`(page_count - freelist_count) * page_size`）の差です。`DROP INDEX` はページを SQLite の freelist に移すだけでファイルを縮めないため、ファイルサイズの差は `0 B` のままですが、使用中のバイト数では解放された量が `-2.06 MiB` のような負の値で出ます。ファイル自体が縮むのは `VACUUM` の後です。`--migration` を使わない実行は、これまでどおりファイルサイズの差を出します。

<details>
<summary>候補の失敗・終了コード・実行時間</summary>

インデックスを作れなかった候補は記録して次へ進みます。

| 状態 | 意味 | 終了コードへの寄与 |
| --- | --- | --- |
| `index_rejected` | SQLite が `CREATE INDEX` を拒否した（例: 重複する行への UNIQUE 制約） | `1` |
| `index_timeout` | インデックスの作成が `--timeout-ms` に達した | `124` |
| `variant_timeout` | variant 側の SELECT が `--timeout-ms` に達した。そのクエリは判定せず、ほかのクエリの結果は残す | `124` |

全体に影響する失敗では、報告を書く前に止まり、stdout は空のままです。baseline の SELECT の失敗・時間切れ、シグナル、variant / baseline の接続の失敗、一時コピーの作成・削除の失敗、ディスク不足などの保存の失敗が該当します。候補単位の失敗は `error:` 行にはしません。

報告を書けた場合、終了コードは、結果の不一致 `3`、インデックスまたはマイグレーションの作成失敗 `1`、候補の時間切れ `124`、比較不能 `4`、`--migration` の退行 `6`、`0` のうち一番重いものです。後片付けの失敗は `0` のときだけ `5` に置き換えます。そのため batch は、報告を書きながら `1`・`6`・`124` で終わることがあります。どれかは stdout で見分けます。

human 出力は候補の表、`Recommendation:`、クエリと候補の判定表を出します。おすすめは、不一致・比較不能・`needs-check`（`--migration` では `needs_check` が `regressed` のクエリを数える）・時間切れがなく、改善が1件以上ある候補のうち、改善したクエリが最も多いものです。同じなら容量の増分が小さい順、次に入力順（マニフェストの候補の後ろに提案）です。`--format json` では [docs/json.md](docs/json.md) に書いた `batch_schema_version` 1 のオブジェクトを出します。

インデックスの作成・SELECT 1回・診断文1回は、それぞれ `--timeout-ms` の制限時間を持ちます。batch は全体で、データベースのコピー1回と、候補ループの前に全クエリの baseline SELECT を1回ずつ実行する分に加えて、候補ごとにインデックスの作成1回とクエリごとの SELECT 2回、さらに最大3つの診断文それぞれの制限時間までかかることがあります。`--show-binds` と `--show-rows` は各比較オブジェクトに適用します。

</details>

### 候補のインデックスを提案させる（--suggest）

`--suggest` は、SQLite の expert（同梱の SQLite ソースからビルドする sqlite3expert）に候補のインデックスを提案させ、その提案を同じ batch の仕組みで比べます。インデックスのファイルは要りません。

```sh
qenome app.db select.sql --suggest
qenome --d1 DB select.sql --suggest --bind 1:int:1234
qenome app.db --batch batch.json --suggest
```

SELECT ファイルを1本だけ渡したときは、その SELECT を batch のクエリ1件として扱い、`--bind` もそのクエリに適用します。`--batch` のときは、提案をマニフェストの候補の後ろに足します（`candidates` は省略しても空でもよい）。`--suggest` は `--runs`、`--format kv`、インデックスのファイルとは併用できません。

Qenome は baseline のコピーに2つ目の読み取り専用接続を開き、expert のサンプリングを `0` に設定します。そのため expert が利用者のデータベースから読むのはスキーマだけです。検査済みの全 SELECT を expert に渡します。expert を動かす前に、`sqlite_schema` の各行を検査します。各行は1文で、`CREATE TABLE`、`CREATE INDEX`、`CREATE UNIQUE INDEX`、`CREATE VIEW`、`CREATE TRIGGER`、`CREATE VIRTUAL TABLE` のいずれかで始まり、`expert` 仮想テーブルを使わないこと。これを満たさないデータベースは `suggest_schema_rejected`（終了コード `1`、stdout 空）で拒否し、マニフェストに候補があっても続けません。expert を動かしている間は、それが開く接続に一時的なガードを付けます。`ATTACH` と `DETACH` を拒否し、`index_list` と `index_xinfo` の PRAGMA だけを許し、接続できるデータベース数の上限を `0` にします。expert のオブジェクトを作ったあと、expert は自分の解析用コピーに独自の authorizer を設定しますが、接続できるデータベース数の上限はそこでも有効です。Qenome は expert を破棄したあとにガードを外します。ガードを設定できなければ、expert を呼ばずに止まります。これらで、細工されたスキーマがほかのデータベースファイルを作成・変更するのを防ぎます。レポートの `CREATE INDEX` は SQLite 自身の文の解析器で切り出します（引用符の中の `;` では切りません）。提案はマニフェストの候補と同じ検査を通し、落ちたものは `suggestion_rejected` の warning を付けて捨てます。ラベルは `suggested:1`、`suggested:2`… で、比べる提案は最大20件、マニフェストの候補と合わせて最大100件です。

出力は batch の報告です。`summary` の各候補に `source`（`manifest` / `suggested`）と `index_sql_text` が付き、トップレベルの `warnings` に、捨てたもの・できなかったことが入ります。

| warning の `code` | 意味 |
| `suggest_query_skipped` | 1本の SELECT を SQLite が解析できなかった。ほかの SELECT は続ける |
| `suggestion_rejected` | 提案が `CREATE INDEX` の検査に落ちた |
| `suggestions_truncated` | 20件または100件の上限で、提案の後ろを捨てた |
| `no_suggestions` | SQLite の提案が0件だった。マニフェストの候補だけを比べた |
| `suggest_failed` | expert を開始・解析できなかった。マニフェストの候補だけを比べた |

比べる候補が1件も残らないときは、終了コード `1`・stdout 空・エラーコード `no_candidates` で止まります。提案は、終了コードとおすすめの判定では、マニフェストの候補と同じ重さで数えます。提案は出発点であり、判定ではありません。結果の行・読んだ行数・終了コードは、実際の比較から出ます。

`--suggest` は候補を探すときに使ってください。CI の判定には `--suggest` を付けず、名前を付けたインデックスを比べます。そうすれば SQLite の助言が変わってもビルドの結果は変わりません。batch の報告は `batch_schema_version` `1` のままで、`source`、`index_sql_text`、`warnings` は追加です。

## 出力形式

### human（既定）

human は判断に必要なものを出します。

- Summary: 結果の行が一致したか、コピーごとの読んだ行数と書いた行数、判定とその理由、計画が変わったか、`--seed-data` のときは `seed data` と `seed` の行、ペアのラウンドから決めた時間の向き（判定できないときは向きを付けない中央値の比）、中央値が同じ向きのときの変化の大きさ（`230x faster`）、容量の増分、デバッグビルドのときはその注意
- baseline と variant の左右比較表: 読んだ行数、書いた行数、結果の行数、フルスキャン行数、VMステップ数、0 でないときはソート回数と autoindex 行数、計測したときは p25 / p75 の時間、データベースファイルのバイト数
- 両方のコピーの実行計画。`kind` / `covering` / `automatic` は SQLite の文言から読んだヒント
- 助言の警告があるときは `Warnings` の節に `warning: <code>: <message>` の行
- `--suggest` のときは `Suggested by SQLite:` の節。提案ごとに `suggested:N: CREATE INDEX ...` と SQL 本文を出し、表の後ろに `warning: <code>: <message>` の行で、捨てたもの・できなかったことを出す
- `--d1` のときは D1 ブロック: バインディング、設定ファイル、データベース id、ローカルファイル、SQLite の版の違い、本番 D1 についての注意

行が一致しない・比較できない・行の順序が変わったときは、説明と片方だけの件数を足します。例の行は `--show-rows` のときだけ出し、隠しているときはそのフラグで再実行するよう案内します。`--show-binds` を付けるとバインド値も出します。

入力パスのうち `--seed-data` 以外、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件は kv と json にだけ出ます。時間の根拠（`effect`、`median_difference_ns`、`noise_band`、`confidence_interval`）も kv と json にだけ出ます。`--d1` のときは、human も上記の D1 ブロックを出します。

### kv

kv は全項目を1行1項目の `key: value` で出し、スクリプトとログに向きます。human が出さない入力、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件も含みます。`--d1` のときは `d1-binding` / `d1-config` / `d1-database-id` / `d1-local-database` / `d1-sqlite-version` / `d1-sqlite-version-note` / `d1-caution` を加えます。`--seed-data` のときは `seed-data` / `seed` / `seed-rows` / `seed-tables` とテーブルごとの `seed-table` を加えます。`baseline-only-row` / `variant-only-row` は `--show-rows` のときだけ出ます。

### json

json は、比較が終わったときに stdout へ JSON オブジェクトを1個だけ（末尾改行付きで）出します。`--batch` のときは、上記で説明した別の `batch_schema_version` 1 のオブジェクトを出します（「まとめて比べる（--batch）」と [docs/json.md](docs/json.md) を参照）。`--seed-data` のときは、どちらのオブジェクトにもトップレベルの `seed_data` が加わります。フィールド（次のコア変更で予約している名前を含む）は [docs/json.md](docs/json.md) が仕様です。入力拒否・時間上限・中断のときは stdout を空のままにします。`--format json` のとき、stderr は JSON オブジェクト1個です（`schema_version`、`exit_code`、`error` の `code` / `message` / `hint`）。`human` と `kv` はテキストの `error:` 行のままです。

判定はトップレベルの `verdict` で読めます。

| `verdict` | 意味 |
| --- | --- |
| `improved` | 結果が一致し、variant の読んだ行数が減った |
| `no-effect` | 結果が一致し、variant の読んだ行数が変わらない |
| `needs-check` | 結果は一致するが、variant の読んだ行数か書いた行数が増えた。`verdict_reasons` に理由が入る |
| `not-judged` | 結果が不一致・比較不能。`verdict_reasons` に理由が入る |

`--migration` の batch では、`needs-check` と同じ条件を `regressed` と呼びます。マイグレーションはすでに書かれた変更だからです。単発・`--batch`・`--suggest` の判定は `needs-check` のままです。batch の `summary` の件数キーも `needs_check` のままです。「まとめて比べる（--batch）」を参照。

判定は、ローカル D1 と同じ数え方（workerd のパッチ）で数えた読んだ行数と書いた行数で決まります。時間は参考値なので、`--runs 0` でも判定は出ます。この数値は、まだ本番 D1 と照合していません。

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
| `exit_code` | 比較結果に対応する終了コード（0 / 3 / 4）。一致したあとの後片付けに失敗した場合は、JSON を書いた後にプロセスが 5 で終わる |
| `verdict` / `verdict_reasons` | 読んだ行数による判定とその理由（`improved` / `no-effect` / `needs-check` / `not-judged`） |
| `result` | 結果行の比較（`match` / `mismatch` / `incomparable`） |
| `row_order` | 行順（`same` / `differs` / `not-applicable`）。一致判定には含めず、`match` のときだけ `same` / `differs` になる参考情報 |
| `result_reasons` | 比較できない理由。各要素は `text` と `hint`（無いときは `null`） |
| `row_differences` | `baseline_only` / `variant_only` の件数。`baseline_only_examples` / `variant_only_examples` は配列のままで、既定は空。`--show-rows` で最大 5 件の例の行が入る |
| `plan_changed` | 実行計画が baseline と variant で変わったか |
| `baseline` / `variant` | それぞれの `rows`、`plan`（`id` / `parent` / `kind` / `covering` / `automatic` / `detail`）、`counters`（`rows_read` / `rows_written` / `fullscan_steps` / `vm_steps` / `sort_ops` / `autoindex_rows`） |
| `timing` | `rounds`、`variant_faster_rounds`、`ratio`、`baseline` / `variant` の `median_ns` / `p25_ns` / `p75_ns` / `min_ns` / `max_ns`。計時しなければ `null`、baseline の median が 0 なら `ratio` は `null`。`noise_band`、`confidence_interval`、`median_difference_ns`、`effect`、`unavailable_reason` は下記の時間統計 |
| `size_bytes` | `baseline` / `variant` / `increase`（データベース全体のバイト数。インデックス単体ではない。`--migration` では使用中のバイト数。「まとめて比べる（--batch）」を参照） |
| `inputs` | `database` / `select` / `index_sql` のパス |
| `d1` | `--d1` のときだけ出る: `binding` / `config` / `database_id` / `local_database` / `sqlite_version`（D1 側の 3.53.4） / `sqlite_version_note` / `caution` |
| `environment` | `qenome_version`（`--version` と同じ、`build.zig.zon` の版） / `sqlite_version` / `sqlite_source_id` / `zig_version` / `build_mode` / `os` / `arch` / `work_dir_parent` |
| `measurement` | 計時条件（`runs_per_copy`（各コピーの計測ラウンド数。計時しないときは 0）/ `warmup` / `order` / `scope` / `cache`） |
| `binds` | `number` / `type`。text は `text_bytes` も持つ。`--show-binds` を付けたときだけ値が `value` に入る |
| `warnings` | `{code, message}` の配列（`no_analyze_stats`、`data_too_small`）。判定と終了コードは変えない |
| `sqlite` | 予約済みで、まだ出ない。`bundled_version` と `db_header_version`。それまでは同梱版を `environment.sqlite_version` で読む |

- 文字列値では、バックスラッシュを `\\`、非 UTF-8 のバイトを `\xNN`（バイト 0xFF なら `\xff`）と書いてから JSON としてエスケープします。4文字の `\xff` は `\\xff` になり、バイト 0xFF とは別の文字列です。元のバイト列に戻すときは、`\\` をバックスラッシュ1個、`\xNN` をそのバイト、それ以外の文字をそのまま読みます。入力パス、計画の detail、理由、bind の text がこの規則です。`--show-rows` で出す例の行の TEXT も同じ規則（前後に `'`。例: `'\xff'`。JSON のテキストでは `'\\xff'`）で、BLOB は `x'00ff'` です。200 バイトを超える例の値は切り詰め、`...(N bytes)` を付けます。
- `binds` は kv と同じ秘匿方針です。`--show-binds` が無いときは値を出さず、番号・型・テキストの長さだけを出します。real の非有限値（`inf` / `-inf`）は JSON 数値にできないため、文字列で出します。
- `row_differences` の件数（`baseline_only` / `variant_only`）は常に出します。例の配列キーも残しますが、既定では空です。行の値を入れるのは `--show-rows` を付けたときだけです。human と kv も同じフラグで、既定では件数だけを出します。human は例を隠しているとき、`--show-rows` で見られると書きます。
- `row_order` は参考情報で、結果の一致判定には含めません。

</details>

### 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 結果が一致した |
| 1 | 入力を拒否した（読めないファイル、不正・拒否された SQL、バインドの不一致、インデックスの作成失敗） |
| 2 | 引数の誤り |
| 3 | 結果が一致しない |
| 4 | 結果を比較できない、または `--d1` がローカルデータベースをちょうど1つに決められない（設定が無い、設定が複数、設定が読めない・不正、バインディングが不明か重複、database id が無い、ローカルファイルが未作成、ローカルファイルを開けない） |
| 5 | 比較のあとの後片付けに失敗した（0 のときだけ置き換え、それ以外のコードはそのまま） |
| 6 | `--migration` で結果の行は一致したが、クエリの読んだ行数か書いた行数が増えた。`--migration` の batch だけが返す |
| 124 | 時間上限に達した（`--timeout-ms`） |
| 129 / 130 / 143 | `SIGHUP` / `SIGINT` / `SIGTERM` による中断（POSIX） |

`--format json` は比較結果を `exit_code` に 0 / 3 / 4 で出します。JSON を書いた後にプロセスが 5 で終わることはあります。

`--batch` の報告は、終了コード `1`・`6`・`124` で書かれることがあります。stdout が batch のオブジェクトなら実行は最後まで進み、失敗は報告の中にあります。stdout が空なら実行は途中で止まり、stderr にエラーオブジェクトがあります。

## 守るルール

- 元のデータベースを変更しない（読み取り専用で開く）
- 比較できない結果を「一致」「成功」として報告しない
- 改善かどうかは読んだ行数で判定し、時間では判定しない（読んだ行数が減らない SELECT は改善ではない）
- 容量はデータベース全体の増分であり、インデックス単体のサイズではない。`--migration` は使用中のバイト数を測るので、落としたインデックスの解放量が負の値で出る
- 複数文・書込・危険な DDL は拒否する。`--migration` のファイルだけは複数のインデックス変更を許すが、`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX` に限る
- 正常・失敗・中断のどの経路でも、接続と一時ファイルを後片付けする
- D1 のデータベースファイルを推測しない。バインディングがちょうど1つのファイルに決まらないときは止まる

## 開発時の検査

```sh
python3 scripts/check_all.py
```

CI の quality ワークフローも同じスクリプトを呼びます。Zig の版の照合、`zig fmt --check .`、ビルド、テスト、アーキテクチャとコメントの検査を順に実行し、最初に失敗した段階で止まります。最後の2段階は[クイックスタート](#クイックスタート)の検査です。`scripts/check_quick_start.py` は英語版 `README.md` のコマンドを書いてあるとおりに実行して各結果を `# expect:` と照合し、`README.ja.md`（このファイル）が同じコマンドを持っていることも確かめます。クイックスタートに例を足すときは、この印も付けてください。CI がその例も検査します。`improved`・`no-effect`・`incomparable` の例は、それぞれ1つ以上残っている必要があります。クイックスタートの2段階は Linux と macOS で実行します。Windows では skip を表示し、ほかの段階はそのまま実行します。

コードにコメントは書きません。説明は README に書き、ルールの正本は検査スクリプトです。

`docs/demo.gif` は、`zig build -Doptimize=ReleaseFast` のあと、リポジトリのルートで `vhs docs/demo.tape` を実行して撮り直します。台本は `examples/d1-toml` を一時ディレクトリへコピーし、サンプルの投入中はターミナルのエコーを止めるので、録画に残るのは Qenome のコマンドと出力だけです。

## ライセンス

Qenome は Apache License 2.0 で公開しています。全文は [LICENSE](LICENSE) を参照してください。

同梱の SQLite amalgamation はパブリックドメインのままで、`vendor/sqlite3/patches` の行数カウントのパッチは独自の帰属表示を保ちます。どちらも [NOTICE](NOTICE) に記録しています。

### 時間のぶれ・信頼区間・警告

<details>
<summary>時間のぶれ・信頼区間・警告の詳細</summary>

各ラウンドは baseline を2回実行する A/A のあと、baseline/variant を AB・BA 交互に計時します。比較済みの実行が warmup で、A/A は追加実行です。`noise_band.threshold_ns` は A/A の絶対時間差の経験的95パーセンタイル（nearest rank: ceil(0.95*n)）です。標本数は `pairs`。統計的に校正した有意差閾値ではなく、観測された差が0でも真のばらつき0は意味しません。

`median_difference_ns` はラウンドごとの variant−baseline の差の中央値です。2つの中央値の差ではありません。既存 ratio は variant中央値/baseline中央値のままです。`confidence_interval` は独立同分布の連続な差を仮定する二項分布の順位区間で、将来の単発時間の範囲ではありません。要求水準 `level` は0.95、保守的な理論被覆率が `coverage`。再標本化はしません。式と根拠は [英語版](README.md#timing-evidence-and-advisory-warnings) を参照してください。

6回未満は `too-few-rounds`（5回の最大有限区間は93.75%、6回は96.875%）、計測時間に0があれば `zero-duration`、差が全同値なら時計分解能を精度と取り違えないよう `no-observed-variation` として区間を null にし、effect は `insufficient-samples` です。区間が0を含むか、差の中央値の絶対値が A/A幅以下なら `no-difference`。それ以外が `faster` / `slower` です。これは補助説明で行数判定・終了コードには影響しません。A/Aを先に測る順序、キャッシュ、負荷のドリフト、時間依存、少数標本があるため、実機や本番で95%を厳密保証するものではありません。human は時間の中央値と、ペアのラウンドから決めた向きを出し、中央値が同じ向きのときだけ変化の大きさを添えます。ペアのラウンドで向きを判定できないときは、向きを付けずに中央値の比を出し、判定できないと明記します。上記の根拠は kv と json に出します。

`warnings` は非計時・比較不能でも配列として出し、human/kvにも同じcode/messageを表示します。`no_analyze_stats` は候補のインデックスの対象テーブルに、baseline上で空でない sqlite_stat1 エントリがない場合。別表の統計では解消しません。鮮度・完全性は確認せず、部分インデックスの統計だけでも存在扱いです。`data_too_small` はその表の `SELECT 1 ... LIMIT 1000` が1000件未満の場合。1000件到達は「1000件以上」であり、正確な件数ではありません。結果件数・読取行数・統計推定値は使いません。1000は代表性を保証しない目安です。

診断は計時後にコピーだけを読み、ANALYZE/PRAGMA optimizeを実行しません。追加実行・診断を既存rows_read/rows_writtenへ混入させません。警告は判定を止めず終了コードも変えません。診断の失敗・時間上限・中断は既存のエラー処理に従います。

</details>
