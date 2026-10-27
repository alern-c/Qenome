<div align="center">

<img src="docs/logo.svg" width="96" height="96" alt="Qenome のロゴ。虫めがねの中の DNA 二重らせんと、1か所だけ色の違う塩基対">

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

入るのは小さなランチャーと、そのマシン向けのバイナリ1つです（`@qenome/linux-x64`、`@qenome/linux-arm64`、`@qenome/darwin-x64`、`@qenome/darwin-arm64` のいずれか）。版は `build.zig.zon` の `.version` で、組み立てと公開の手順は [docs/npm.md](docs/npm.md) にあります。Windows は npm の対象外なので、下のビルド済みバイナリを使ってください。

### ビルド済みバイナリ（GitHub Releases）

[Releases](https://github.com/alern-c/Qenome/releases) ページから、使う環境のアセットと、同じリリースの `SHA256SUMS` をダウンロードします。

配布するアセットは圧縮していないバイナリで、名前は `qenome-<version>-<arch>-<os>`（Windows は `qenome-<version>-<arch>-<os>.exe`）です。例:

- `qenome-0.3.2-x86_64-linux`
- `qenome-0.3.2-aarch64-macos`
- `qenome-0.3.2-x86_64-windows.exe`

ビルド済みバイナリは Linux・macOS・Windows 向けに提供します。リリースページに、そのリリースでビルドしたアセットが並ぶので、`<arch>` と `<os>` が自分の環境に合うものを選んでください。`SHA256SUMS` は sha256sum 形式（SHA-256 のハッシュ、半角スペース2個、ファイル名）です。

実行する前にダウンロードを検証します。次の例では、`0.3.2` とファイル名を、ダウンロードした版とアセットに置き換えてください。

<details>
<summary>Linux・macOS・Windows のチェックサム確認コマンドを表示</summary>

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.3.2-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows（PowerShell）:

```powershell
Select-String 'qenome-0.3.2-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.3.2-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` のハッシュが、`SHA256SUMS` の該当行と同じであることを確認してください（大文字・小文字は問いません）。

</details>

次に実行権限を付けて実行します（Linux・macOS）。

```sh
chmod +x qenome-0.3.2-aarch64-macos
mv qenome-0.3.2-aarch64-macos qenome
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

この手順では、テスト用データベースを作り、Qenome をビルドし、3つの例を実行します。コマンドはリポジトリのルートで、ブロックごとに Linux か macOS で実行してください。必要なものは Zig 0.17.0（「ソースからビルド」を参照）と `sqlite3` コマンドラインツールです。`sqlite3` は SQL ファイルを新しいデータベースへ読み込みます。

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

3つの例は `zig-out/bin/qenome` を実行します。各コマンドの末尾には、その例が返すべき結果（Summary の `result` と `verdict`、終了コード）を書いてあります。`python3 scripts/check_all.py` と CI の quality ワークフローは、これらの行を書いてあるとおりに実行するので、README とプログラムのずれは見つかります。`--runs 40` は、負荷のあるマシンでも中央値を安定させるための指定です（既定は `10`）。

全走査をなくすインデックス: 候補のインデックスで `SCAN events` が `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` に変わり、読んだ行数が 200,000 から 101 に減り、両方のコピーが同じ100行を返します。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/improved.sql testdata/cases/improved.index.sql --bind 1:int:1234 --runs 40  # expect: result=match verdict=improved exit=0
```

効果のないインデックス: SELECT が列を `lower()` で包むため、SQLite は `status` のインデックスを使えません。計画・読んだ行数・書いた行数は変わりません。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/no-effect.sql testdata/cases/no-effect.index.sql --bind 1:text:ok --runs 40  # expect: result=match verdict=no-effect exit=0
```

比較できない SELECT: `ORDER BY random()` は実行するたびに別の行を選ぶため、Qenome は行が一致したと報告せず、比較できないと報告します。この例では SELECT を計測も判定もしません。ここでの終了コード 4 は期待どおりの結果で、エラーではありません。

```sh
./zig-out/bin/qenome testdata/generated/qenome-fixture.db testdata/cases/incomparable.sql testdata/cases/incomparable.index.sql  # expect: result=incomparable verdict=not-judged exit=4
```

データベースの作成はおよそ1秒、計測する例はそれぞれ数秒で終わります。fixture・クエリ・期待する計画と件数は `testdata/README.md` に記録しています。

## 使い方

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
qenome --d1 DB select.sql index.sql
```

パスは DB・SELECT ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--index-sql` でも指定できます（混在可）。位置指定のパスは、まだ指定されていない最初の役割に埋まります。`--d1` のときは、位置指定の2つのパスが SELECT と CREATE INDEX の役割に入ります。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。複数文・書込・その他の文は拒否します。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ。`--d1` とは併用しない）
- `--d1 <BINDING>`: wrangler 設定の `d1_databases` にあるこのバインディングのローカル D1 データベースを `--db` の代わりに使う。「D1 のローカルデータベース」を参照
- `--config <PATH>`: `--d1` が読む wrangler 設定（既定はカレントディレクトリの `wrangler.toml` / `wrangler.jsonc` / `wrangler.json`）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ）
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータ N に渡す型付きの値。繰り返し指定できる。N は SQLite のパラメータ番号で、名前付きパラメータは最初に現れたときの番号を共有し、`?NNN` は NNN を使う。TYPE は int / real / text / null（null は値を取らない）。1 からパラメータ数までの各番号をちょうど1回ずつ指定する必要があり、パラメータの無い SELECT に `--bind` は付けられない。値は引数の残り全体なので、text には `:` を含められる
- `--runs <N>`: 結果が一致したあとの計測ラウンド数。各ラウンドは各コピーで SELECT を1回計測する。既定は 10、0 で計測しないが読んだ行数と判定は残る、最大 1000。1秒を超える計測は進捗を stderr に出す
- `--timeout-ms <MS>`: インデックス作成と SELECT 1回あたりの制限時間。既定は 30000、0 で無効。1回の実行は全体で、データベースのコピーに加えて `(3 + 4 × runs)` 回分の制限時間に加え、最大3つの診断文それぞれの制限時間までかかることがある
- `--format <human|kv|json>`: 出力形式（既定 human）。「出力形式」を参照
- `--show-binds`: バインド値を出す。付けない場合、human はバインドを出さず、kv と json は番号・型・テキストの長さだけを出し、値をログに残さない
- `--show-rows`: 片方のコピーだけが返した例の行を出す。付けない場合、どの形式も件数だけを出して行の値をログに残さない。human はこのフラグで再実行するよう案内する
- `--help`, `-h`: 使い方を表示して終了コード 0 で終了する
- `--version`: `build.zig.zon` の版を `qenome <version>` で表示して終了コード 0 で終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

Qenome はデータベースを読み取り専用で開き、SQLite の backup API を使って、Linux と macOS では `$TMPDIR`（既定は `/tmp`）、Windows では `%TMP%`、`%TEMP%`、`%USERPROFILE%` のうち設定されている最初の場所の下にある非公開ディレクトリへコピーします。このコピーが baseline で、2つ目のコピーが variant になり、候補のインデックスは variant にだけ作ります。SELECT は両方のコピーで実行し、結果の行を多重集合として比較します（同じ行が同じ回数だけ現れること）。行の順序は参考情報として示し、一致判定には含めません。

読んだ行数と書いた行数は、この最初の1回の実行から取るので追加のコストはなく、`--runs 0` でも残ります。結果が一致し、`--runs` が 0 でないとき、SELECT をもう一度両方のコピーで参考値として計測します。各コピーには、行の比較に使った計測しないウォームアップが1回あります。計測ラウンドは baseline→variant と variant→baseline を交互に繰り返します（ABBA）。1ラウンドは reset 文から `SQLITE_DONE` までの `sqlite3_step` を、割り込みの確認を含めて計測します。列の読み取り、prepare、bind、計画の取得は計測しません。各コピーは書き込み直後の接続とページキャッシュを再利用するため、キャッシュはウォームです。非公開ディレクトリは、結果にかかわらず終了前に削除します。

Linux と macOS では、このディレクトリを所有者だけがアクセスできる権限（`0700`）で作ります。Windows にはこれに相当する指定がないため、一時ディレクトリのアクセス制御を引き継ぎ、保護はその場所がそのユーザー専用であることに依存します。Qenome は Windows では Ctrl+C と Ctrl+Break、Linux と macOS では SIGINT・SIGTERM・SIGHUP を受けたときに後片付けしますが、コンソールを閉じる・プロセスを強制終了するといった強制的な終了では、コピーが残ることがあります。

判定は読んだ行数から決まり、終了コードを変えません。

読んだ行数と書いた行数は、ローカル D1 と同じ数え方（workerd のパッチ）です。Qenome は同梱 SQLite を `workerd` の行数カウントのパッチ付きでビルドします。この数値は、まだ本番 D1 と照合していません。どちらのカウンタも 32 ビットで、それぞれの回数が 1回の実行で 4,294,967,295 を超えると一周して小さい値に戻るため、その場合は巻き戻った値を報告し、判定もその値で比較します。パッチの出どころは `NOTICE`、当て直す手順は `vendor/sqlite3/PROVENANCE.txt` に記録しています。

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

## 出力形式

### human（既定）

human は判断に必要なものを出します。

- Summary: 結果の行が一致したか、コピーごとの読んだ行数と書いた行数、判定とその理由、計画が変わったか、時間の中央値とラウンド数、容量の増分、デバッグビルドのときはその注意
- baseline と variant の左右比較表: 読んだ行数、書いた行数、結果の行数、フルスキャン行数、VMステップ数、0 でないときはソート回数と autoindex 行数、計測したときは p25 / p75 の時間、データベースファイルのバイト数
- 両方のコピーの実行計画。`kind` / `covering` / `automatic` は SQLite の文言から読んだヒント
- `--d1` のときは D1 ブロック: バインディング、設定ファイル、データベース id、ローカルファイル、SQLite の版の違い、本番 D1 についての注意

行が一致しない・比較できない・行の順序が変わったときは、説明と片方だけの件数を足します。例の行は `--show-rows` のときだけ出し、隠しているときはそのフラグで再実行するよう案内します。`--show-binds` を付けるとバインド値も出します。

入力パス、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件は kv と json にだけ出ます。`--d1` のときは、human も上記の D1 ブロックを出します。

### kv

kv は全項目を1行1項目の `key: value` で出し、スクリプトとログに向きます。human が出さない入力、SQLite と Zig の版、ビルド種別、OS とアーキテクチャ、作業ディレクトリ、計時条件も含みます。`--d1` のときは `d1-binding` / `d1-config` / `d1-database-id` / `d1-local-database` / `d1-sqlite-version` / `d1-sqlite-version-note` / `d1-caution` を加えます。`baseline-only-row` / `variant-only-row` は `--show-rows` のときだけ出ます。

### json

json は、比較が終わったときに stdout へ JSON オブジェクトを1個だけ（末尾改行付きで）出します。フィールド（次のコア変更で予約している名前を含む）は [docs/json.md](docs/json.md) が仕様です。入力拒否・時間上限・中断のときは stdout を空のままにします。`--format json` のとき、stderr は JSON オブジェクト1個です（`schema_version`、`exit_code`、`error` の `code` / `message` / `hint`）。`human` と `kv` はテキストの `error:` 行のままです。

判定はトップレベルの `verdict` で読めます。

| `verdict` | 意味 |
| --- | --- |
| `improved` | 結果が一致し、variant の読んだ行数が減った |
| `no-effect` | 結果が一致し、variant の読んだ行数が変わらない |
| `needs-check` | 結果は一致するが、variant の読んだ行数か書いた行数が増えた。`verdict_reasons` に理由が入る |
| `not-judged` | 結果が不一致・比較不能。`verdict_reasons` に理由が入る |

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
| `size_bytes` | `baseline` / `variant` / `increase`（データベース全体のバイト数。インデックス単体ではない） |
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
| 124 | 時間上限に達した（`--timeout-ms`） |
| 129 / 130 / 143 | `SIGHUP` / `SIGINT` / `SIGTERM` による中断（POSIX） |

`--format json` は比較結果を `exit_code` に 0 / 3 / 4 で出します。JSON を書いた後にプロセスが 5 で終わることはあります。

## 守るルール

- 元のデータベースを変更しない（読み取り専用で開く）
- 比較できない結果を「一致」「成功」として報告しない
- 改善かどうかは読んだ行数で判定し、時間では判定しない（読んだ行数が減らない SELECT は改善ではない）
- 容量はデータベース全体の増分であり、インデックス単体のサイズではない
- 複数文・書込・危険な DDL は拒否する
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

6回未満は `too-few-rounds`（5回の最大有限区間は93.75%、6回は96.875%）、計測時間に0があれば `zero-duration`、差が全同値なら時計分解能を精度と取り違えないよう `no-observed-variation` として区間を null にし、effect は `insufficient-samples` です。区間が0を含むか、差の中央値の絶対値が A/A幅以下なら `no-difference`。それ以外が `faster` / `slower` です。これは補助説明で行数判定・終了コードには影響しません。A/Aを先に測る順序、キャッシュ、負荷のドリフト、時間依存、少数標本があるため、実機や本番で95%を厳密保証するものではありません。

`warnings` は非計時・比較不能でも配列として出し、human/kvにも同じcode/messageを表示します。`no_analyze_stats` は候補のインデックスの対象テーブルに、baseline上で空でない sqlite_stat1 エントリがない場合。別表の統計では解消しません。鮮度・完全性は確認せず、部分インデックスの統計だけでも存在扱いです。`data_too_small` はその表の `SELECT 1 ... LIMIT 1000` が1000件未満の場合。1000件到達は「1000件以上」であり、正確な件数ではありません。結果件数・読取行数・統計推定値は使いません。1000は代表性を保証しない目安です。

診断は計時後にコピーだけを読み、ANALYZE/PRAGMA optimizeを実行しません。追加実行・診断を既存rows_read/rows_writtenへ混入させません。警告は判定を止めず終了コードも変えません。診断の失敗・時間上限・中断は既存のエラー処理に従います。

</details>
