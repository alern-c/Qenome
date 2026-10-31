<div align="center">

<img src="docs/logo.svg" width="96" height="96" alt="Qenome のロゴ。2回ねじれる DNA 二重らせんと、1か所だけ色の違う塩基対">

# Qenome

**読んだ行数や書いた行数が増えていませんか？マージする前にインデックスを確かめましょう。**

[![npm の版](https://img.shields.io/npm/v/qenome?style=flat-square)](https://www.npmjs.com/package/qenome)
[![ライセンス: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](LICENSE)
[![品質検査](https://github.com/alern-c/Qenome/actions/workflows/quality.yml/badge.svg)](https://github.com/alern-c/Qenome/actions/workflows/quality.yml)

[English](README.md) | 日本語

<img src="docs/demo-suggest.gif" width="1200" alt="D1 のサンプルプロジェクトで qenome --d1 DEMO_DB select.sql --suggest を実行するターミナル。SQLite が提案したインデックス1本を比べ、結果の行が一致し、読んだ行数が 200000 から 101 に減り、おすすめが suggested:1 になっている">

</div>

<p align="center"><sub>この録画は <a href="docs/ja/usage.md#サンプルプロジェクトを試す"><code>examples/d1-toml</code></a> のもの。サンプルは手元でコマンド2本で再現できます。</sub></p>

ローカルの D1 データベースがある wrangler プロジェクトで、次の1コマンドを実行すると、SQLite に候補のインデックスを尋ね、サンドボックスのコピーで比べます。

```sh
npx qenome --d1 DEMO_DB select.sql --suggest
```

サンプルプロジェクト（`examples/d1-toml`）では、次の結果になります。

```text
Recommendation: suggested:1

Results
  query       candidate    result        verdict       rows read
  select.sql  suggested:1  match         improved      200000 -> 101
```

読んだ行数は 200,000 から 101 に減り、終了コードは 0 です。元のデータベースは変更しません。上の録画も同じ実行です。セットアップの2コマンドは[サンプルプロジェクトを試す](docs/ja/usage.md#サンプルプロジェクトを試す)を参照してください。

読み取り専用の `SELECT` を1本と、候補の `CREATE INDEX` を1本渡します。`--write` を付けると、代わりに `INSERT`・`UPDATE`・`DELETE`・`REPLACE` を1本渡します。ローカルの SQLite ファイル、またはローカルの Cloudflare D1（`--d1 <BINDING>` と `--config`）をサンドボックスのコピーにして比較します。元のデータベースは変更しません。

## インストール

Linux と macOS の x64 と arm64 では、次の1回でコマンドをインストールできます。

```sh
npm install -g qenome
qenome --version
```

インストールせずに試すときは `npx qenome` で実行できます。Windows は npm の対象外なので、[Releases](https://github.com/alern-c/Qenome/releases) のビルド済みバイナリを `SHA256SUMS` で確認してから使ってください。全プラットフォームの手順とソースからのビルドは[インストール](docs/ja/installation.md)にあります。

## 特徴

- **元のデータベースは変更しません。** 読み取り専用で開き、サンドボックスのコピーで比較するので、役に立たない候補のインデックスはマージの前に捨てられます。
- **判定は時間ではなく、読んだ行数。** 読んだ行数と書いた行数は、ローカル D1 と同じ数え方（workerd のパッチ）。`--runs 0` でも判定は残り、計時だけを省きます。
- **結果の行も照合します。** 2つのコピーが同じ行を同じ回数返すかを多重集合として比べ、一致しない・比較できない結果は合格にせず報告します。
- **インデックスが書き込みに与えるコストも見られます。** `--write` は `INSERT`・`UPDATE`・`DELETE`・`REPLACE` を1本、各コピーでロールバックするトランザクションの中で実行し、セカンダリインデックスの挿入・トリガー・外部キーの CASCADE を含む書いた行数を両側で報告します。[書き込みを比べる](docs/ja/usage.md#書き込みを比べる)を参照してください。
- **ローカル D1 のバインディングだけで試せます。** `--d1 <BINDING>` が wrangler の設定からローカルデータベースを探し、`--config` で設定ファイルを指定できます。
- **複数のクエリをまとめて比較。** `--batch <FILE>` は JSON のマニフェストにある全 SELECT と全候補 `CREATE INDEX` を組み合わせて、各組み合わせの判定を出します。[まとめて比べる（--batch）](docs/ja/batch.md#まとめて比べる--batch)を参照してください。
- **マニフェストで使っていないインデックスを見つけられます。** `--batch manifest.json --audit-indexes` は、どのクエリの実行計画にも出てこなかったインデックス、先頭の列がほかのインデックスや主キーに覆われているインデックス、制約のために残す UNIQUE / PRIMARY KEY のインデックスを一覧にします。[インデックスの監査（--audit-indexes）](docs/ja/batch.md#インデックスの監査--audit-indexes)を参照してください。
- **アプリが実行したクエリからマニフェストを作れます。** `qenome/d1` はローカルの D1 に実際に発行された SELECT とバインド値を記録し、`--record` がそのまま比較に使えるマニフェストにします。[実際に実行されたクエリを記録する（--record）](docs/ja/batch.md#実際に実行されたクエリを記録する--record)を参照してください。
- **クエリから候補のインデックスを探せます。** `--suggest` は SQLite の expert に候補のインデックスを提案させて比較するので、SELECT ファイルだけで済みます。[候補のインデックスを提案させる（--suggest）](docs/ja/batch.md#候補のインデックスを提案させる--suggest)を参照してください。
- **AI エージェントと CI 向けの JSON。** `--format json` は `schema_version` 2 のレポートを出し、終了コードが一致・不一致・比較不能を分けます。
- **判定の根拠も同じレポートに。** 実行計画、時間の中央値、データベース全体の容量の増分、助言の警告を出します。

> この数値は、まだ本番 D1 と照合していません。Qenome が測るのはローカルのデータベースだけです。行数の数え方と本番 D1 との違いは、英語の[精度と本番 D1](docs/accuracy.md)で説明しています。

## 目次

- [インストール](#インストール): Linux と macOS の npm、インストールせずに `npx qenome`
- [特徴](#特徴)
- [インストールの詳細](docs/ja/installation.md): npm、ビルド済みバイナリ、チェックサム、ソースからのビルド
- [ローカル D1 を調べる](docs/ja/local-d1.md): wrangler プロジェクトでの最初の比較
- [AI エージェントと使う](docs/ja/agents.md): スキル、JSON レポート、インストールのコマンド
- [なぜ他の方法ではないのか](docs/ja/why-not.md): EXPLAIN QUERY PLAN、wrangler、本番の数値、インデックスを適用する方法との違い
- [使い方](docs/ja/usage.md): すべてのオプション、書き込み、シードデータ、D1 のローカルデータベース
- [まとめて比べる](docs/ja/batch.md): 複数のクエリと候補、インデックスの監査、記録、提案
- [出力形式](docs/ja/output.md): human、kv、json、終了コード、時間の根拠
- [精度と本番 D1](docs/ja/accuracy.md): 行数の数え方、判定の意味、本番 D1 との違い
- [守るルール](docs/ja/rules.md): Qenome が守るものと拒否するもの
- [コントリビュート](#コントリビュート)
- [ライセンス](#ライセンス)

この README だけで、D1 の開発者またはその AI エージェントは、数分でローカル D1 の判定を取れます。[ローカル D1 を調べる](docs/ja/local-d1.md)と [AI エージェントと使う](docs/ja/agents.md)を見てください。

## コントリビュート

ソースからのクイックスタート、開発時の検査、golden 出力の更新方法は [CONTRIBUTING.md](CONTRIBUTING.md) にあります。

## ライセンス

Qenome は Apache License 2.0 で公開しています。全文は [LICENSE](LICENSE) を参照してください。

同梱の SQLite amalgamation はパブリックドメインのままで、`vendor/sqlite3/patches` の行数カウントのパッチは独自の帰属表示を保ちます。どちらも [NOTICE](NOTICE) に記録しています。
