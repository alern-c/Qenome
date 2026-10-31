# ローカル D1 を調べる

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

カレントディレクトリ以外の wrangler ファイルは `--config <PATH>` で指定します。探し方は [D1 のローカルデータベース](usage.md#d1-のローカルデータベース)に、JSON のフィールドは [docs/json.md](../json.md) に書いてあります。

`wrangler.toml` 付きの動くサンプルは [サンプルプロジェクトを試す](usage.md#サンプルプロジェクトを試す)です。
