# D1 の請求が跳ねたとき: 足りないインデックスを見つけて直す

読んだ行数が跳ねる原因は、テーブルを走査している文であることが多いです。このページでは、ローカルのコピーでその文を見つけ、SQLite にインデックスを1本提案させ、別のクエリを悪化させないようにマイグレーションを検査します。Qenome は Cloudflare の請求を読まず、ここで成功しても請求は下がりません。`rows read x runs` は相対的な指標であり、請求ではありません。ローカルの数値が本番 D1 とどこで違うかは[精度と本番 D1](accuracy.md)にあります。

以下のコマンドは、リポジトリのルートで、ビルドした `qenome` を `testdata/accuracy/rank-full-scan-above-indexed` のフィクスチャに対して実行したものです（`events` は 200 行、`customer_id` にインデックスがあり、`note` にはありません）。データベース、ログ、マニフェストは `testdata/generated/bill-spiked/` にあり、コミットしません。マニフェストにはバインド値が入るので、コミットしないでください。

`--batch`、`--rank`、`--suggest`、`--migration` は、データベースのパスの代わりに `--d1 <BINDING>` を取れます。その形は[ローカル D1 を調べる](local-d1.md)にあります。以下の実行はデータベースファイルを使いました。

## 跳ねたところを見つける

請求の入力になるのは、D1 自身が数えた読んだ行数です。どこを見るかは次の Cloudflare のページが基準です。このガイドは、そのページに書いてある以上のダッシュボード操作を足しません。

- データベースごと: [Metrics and analytics](https://developers.cloudflare.com/d1/observability/metrics-analytics/) は、Cloudflare のダッシュボードで D1 のページを開き、データベースを選び、Metrics タブを開く、と書いています。`rowsRead` は走査した行数です。時間の範囲は既定で直近 24 時間です。
- アカウント全体: [Billing](https://developers.cloudflare.com/d1/observability/billing/) は、Billing を開いてから Billable Usage を開く、と書いています。その履歴は最大 30 日です。
- 請求における「読んだ行数」の定義は [Pricing](https://developers.cloudflare.com/d1/platform/pricing/) にあります。同じサイトの長い手順は [Find slow and expensive queries](https://developers.cloudflare.com/d1/observability/find-expensive-queries/) です。

メトリクスのページは `wrangler d1 insights` も説明しています。experimental で、リモートの D1 を読み、API トークンには Account Analytics Read が必要です。このフィクスチャでは実行していません。このリポジトリがすでに書いていて、そのページと一致する呼び出しは次です。

```sh
npx wrangler d1 insights <database> --sort-by=reads --sort-type=avg --time-period=7d --json
```

`<database>` はデータベースの名前、バインディング、または id です。名前を省くとアカウント内のクエリを一覧し、各行に `databaseId` が付きます。アカウント id やデータベース id をガイドやコミットに貼らないでください。このコマンドはクエリのテキストでまとめ、バインド値は返しません。`avgRowsRead` はその期間の平均であり、1つの値に対する Qenome の `rows_read` ではありません。[本番と自分で照合する方法](accuracy.md#本番と自分で照合する方法)を参照してください。

## クエリを記録する

Insights が示すのは SQL のテキストです。Qenome には、バインド値も入ったマニフェストが必要です。`qenome/d1` がローカルの D1 からその両方を記録します。Worker での手順は[実際に実行されたクエリを記録する（--record）](batch.md#実際に実行されたクエリを記録する--record)にあります。ラッパーはローカルの開発とテストだけで使い、本番に載せないでください。

以下の実行は、後続のコマンドにマニフェストを渡すため、同じ `wrapD1` を代用のデータベースに対して呼びます。インデックスのない文を 40 回、インデックスのある文を 1 回実行します。`umask 077` により、ログは自分だけが読めます。

```sh
rm -rf testdata/generated/bill-spiked
mkdir -p testdata/generated/bill-spiked
sqlite3 testdata/generated/bill-spiked/app.db < testdata/accuracy/rank-full-scan-above-indexed/schema.sql
(umask 077; node --input-type=module <<'EOF' > testdata/generated/bill-spiked/record.log
import { wrapD1 } from "./npm/qenome/lib/d1.mjs";
const db = wrapD1({
  prepare(sql) {
    const statement = {
      bind() { return statement; },
      async all() { return { results: [] }; },
    };
    return statement;
  },
});
const scan = "SELECT note FROM events WHERE note = 'missing'";
const lookup = "SELECT note FROM events WHERE customer_id = ?";
for (let i = 0; i < 40; i++) await db.prepare(scan).all();
await db.prepare(lookup).bind(1).all();
EOF
)
qenome --record testdata/generated/bill-spiked/record.log --out testdata/generated/bill-spiked/manifest
```

この実行は終了コード 0 で、次を出力しました。

```text
record: 41 record lines
manifest: testdata/generated/bill-spiked/manifest/manifest.json
queries: 2 distinct read-only statements (41 executions)
  queries/q001.sql  40 executions
  queries/q002.sql  1 execution
repeated shapes: none
skipped: none
warning: the manifest holds bind values; keep it local and do not commit it
```

`executions` はその文を実行した回数です。比較のモードは無視します。`--rank` は読んだ行数にこの回数を掛けます。公開されている import は `qenome/d1` で、上のスクリプトはこのリポジトリ内のコピーを読みます。

## マニフェストを順位づける

```sh
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --rank
```

終了コード 7 は、レポートが書かれ、少なくとも 1 本が likely full scan だった、という意味です。1本もなければ終了コード 0 です。`work-dir-parent` の行は、実行したマシンのサンドボックスの親ディレクトリなので、ここでは省きます。残りはこの実行の出力です。

```text
baseline rank: 2 queries
database: testdata/generated/bill-spiked/app.db
sqlite: 3.53.4
likely full scans: 1
note: rows read x runs is a relative indicator, not a bill

#1  queries/q001.sql
  flag: likely full scan
  rows read: 200
  rows returned: 0
  rows read / rows returned: n/a
  fullscan steps: 199
  scan: SCAN events
  runs: 40
  rows read x runs (not a bill): 8000

#2  queries/q002.sql
  rows read: 2
  rows returned: 1
  rows read / rows returned: 2
  fullscan steps: 0
  scan: none
  runs: 1
  rows read x runs (not a bill): 2

next: qenome <DB> queries/q001.sql --suggest
```

`8000` は、読んだ行数 200 に実行回数 40 を掛けた値です。並び順に使います。請求額ではありません。`next` のパスはマニフェストのファイルからの相対パスです。[baseline の読み取りを順位づける（--rank）](batch.md#baseline-の読み取りを順位づける--rank)を参照してください。

## インデックスを提案させる

```sh
qenome testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/manifest/queries/q001.sql --suggest
```

終了コードは 0 でした。この実行は `CREATE INDEX events_idx_000160d6 ON events(note);` と `Recommendation: suggested:1` を出し、`improved` で `200 -> 0` でした。`Warnings` の下には次が出ました。

```text
  suggested:1: data_too_small: The candidate index table has fewer than 1000 rows. This heuristic does not establish representative performance; test with more representative data.
```

`events` は 200 行です。この警告は判定も終了コードも変えません。自分の実行の `Suggested by SQLite` から `CREATE INDEX` の行をマイグレーションのファイルへコピーしてください。CI の検査では `--suggest` を付けずにそのファイルを比べます。SQLite の提案が後から変わっても、ビルドの結果が変わらないようにするためです。[候補のインデックスを提案させる（--suggest）](batch.md#候補のインデックスを提案させる--suggest)を参照してください。

このブランチでは、読んだ行数が少しでも減れば `improved` です。[PR #142](https://github.com/alern-c/Qenome/pull/142) は未マージで、このブランチには入っていません。入ると、少なくとも 1% 少ないことが条件になり、それ未満は `no-effect` になります。`200 -> 0` はその基準を超えています。

`queries/q002.sql` はすでに `idx_events_customer` を使っています。`--bind 1:int:1` を付けた `--suggest` は終了コード 1 で、stdout には何も書きませんでした。stderr は次です。

```text
error: no candidate index to compare: SQLite suggested no index for these queries
hint: Check that the SELECT has a WHERE or ORDER BY clause, or write a candidate CREATE INDEX file and compare it without --suggest.
```

このエラーは `no_candidates` です。[PR #143](https://github.com/alern-c/Qenome/pull/143) は未マージで、このブランチには入っていません。今の計画にインデックスが不要なとき、終了コード 0 になり、レポートの先頭が `no index needed` になります。`--sql` と、stdin 用の SELECT パス `-` も受け付けるようになります。このページが使う SQL ファイルは、このブランチでも使えます。

## マイグレーションを検査する

提案された文を保存します。この実行では `testdata/generated/bill-spiked/0002_note.sql` を書いてから比べました。

```sh
printf '%s\n' "CREATE INDEX events_idx_000160d6 ON events(note);" > testdata/generated/bill-spiked/0002_note.sql
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --migration testdata/generated/bill-spiked/0002_note.sql
```

終了コードは 0 でした。`queries/q001.sql` は `improved`（`200 -> 0`）、`queries/q002.sql` は `no-effect`（`2 -> 2`）でした。`Recommendation:` はそのマイグレーションのファイルを指しました。元のデータベースは変更していません。

列挙したクエリのいずれかがより多くの行を読むと `regressed` になり、batch は終了コード 6 で終わります。2本目が使っているインデックスを落とすと、そうなります。

```sh
printf '%s\n' "DROP INDEX idx_events_customer;" > testdata/generated/bill-spiked/drop_customer.sql
qenome testdata/generated/bill-spiked/app.db --batch testdata/generated/bill-spiked/manifest/manifest.json --migration testdata/generated/bill-spiked/drop_customer.sql
```

終了コードは 6 でした。`queries/q002.sql` は `regressed`（`2 -> 200`）、`queries/q001.sql` は `no-effect`（`200 -> 200`）でした。`Recommendation:` は `none` でした。CI にはマージするつもりのマイグレーションを渡し、終了コード 6 でジョブを失敗させてください。規則は[まとめて比べる（--batch）](batch.md#まとめて比べる--batch)にあります。

`--rank` は `--migration` と併用できません。インデックスを入れたあとのスキーマを順位づけるには、この実行ではデータベースをコピーし、コピーに `0002_note.sql` を適用してから順位づけました。

```sh
cp testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/indexed.db
sqlite3 testdata/generated/bill-spiked/indexed.db < testdata/generated/bill-spiked/0002_note.sql
qenome testdata/generated/bill-spiked/indexed.db --batch testdata/generated/bill-spiked/manifest/manifest.json --rank
```

終了コードは 0 でした。`likely full scans: 0` です。`queries/q001.sql` の読んだ行数は 0 でした。

## デプロイ後にもう一度見る

マイグレーションがリモートのデータベースに入ったあと、同じメトリクスをもう一度読みます。[本番と自分で照合する方法](accuracy.md#本番と自分で照合する方法)は、同じ期間の長さで `d1 insights` を実行し、`avgRowsRead` を比べる、と書いています。2つの期間の間でトラフィックは変わるので、平均が下がっても確認にとどまります。インデックスが原因だった証明にはならず、請求が下がった証明にもなりません。

## ローカルのテーブルが小さすぎるとき

200 行でも `flag: likely full scan` は出ます。比較が `improved` でも、絶対的な行数は小さいままです。同じ走査が大きなテーブルで払うコストは、その小ささに隠れます。`data_too_small` は、候補の対象テーブルが 1,000 行未満だという意味です。このブランチの警告文は次のコマンドを示さず、判定も変えません。[PR #145](https://github.com/alern-c/Qenome/pull/145) は未マージで、このブランチには入っていません。入ると判定はそのままで、レポートに `--seed-data` と `--scale` の提案コマンドが加わります。

`--scale` は、このブランチですでに使えます。`--suggest`、`--batch`、`--rank` とは併用できないので、先にインデックスをファイルにします。seed が置き換えるのはサンドボックスのコピーの中の `events` だけです。seed した `note` はすべて `n` で、クエリは `missing` を探すので、走査は全行を読み、インデックスは 1 行も読みません。

```sh
cat > testdata/generated/bill-spiked/seed.json <<'EOF'
{
  "seed": 7,
  "tables": {
    "events": {
      "rows": 100,
      "columns": {
        "id": { "kind": "sequence" },
        "customer_id": { "kind": "sequence" },
        "note": { "kind": "fixed", "value": "n" }
      }
    }
  }
}
EOF
qenome testdata/generated/bill-spiked/app.db testdata/generated/bill-spiked/manifest/queries/q001.sql testdata/generated/bill-spiked/0002_note.sql --seed-data testdata/generated/bill-spiked/seed.json --scale 100,10000 --runs 0
```

終了コードは 0 でした。`work-dir-parent` の行は上と同じ理由で省いています。この実行の出力は次です。

```text
scale: 100, 10,000 rows in 2 steps
database: testdata/generated/bill-spiked/app.db
select: testdata/generated/bill-spiked/manifest/queries/q001.sql
index: testdata/generated/bill-spiked/0002_note.sql
seed-data: testdata/generated/bill-spiked/seed.json
sqlite: 3.53.4

Steps
          rows baseline read variant read   ratio  verdict     result       plan    median
           100           100            0 0.0000x  improved    match        changed -
        10,000        10,000            0 0.0000x  improved    match        changed -

Warnings
  warning at 100 rows: data_too_small: The candidate index table has fewer than
    1000 rows. This heuristic does not establish representative performance;
    test with more representative data.

note: these rows come from generated data measured on this machine; they are not
production D1 billing.
```

100 行の段階では baseline が 100 行を読み、`data_too_small` が出ます。10,000 行の段階では baseline が 10,000 行を読み、その警告は消えます。判定は `improved` のままです。末尾の注記はレポート自身の文です。生成したデータをこのマシンで測ったものであり、本番 D1 の請求ではありません。[サンドボックス用のデータを作る](usage.md#サンドボックス用のデータを作る)と[複数のサイズで測る（--scale）](usage.md#複数のサイズで測る--scale)を参照してください。
