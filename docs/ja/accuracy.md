# 精度と本番 D1

[English](../accuracy.md)

Qenome はローカルのデータベースのサンドボックスのコピーを比較します。元のデータベースは変更せず、本番 D1 のメトリクスも読みません。このページでは、結果をどこまで信頼できるかを説明します。行数の数え方、各判定の意味、本番 D1 と異なる点、自分の手で本番と照合する手順です。

数値はローカル D1 と同じ数え方（workerd のパッチ）ですが、手元のデータと統計から出たものです。まだ本番 D1 と照合していません。同じコピーでインデックスの前後を比べるために使い、本番の測定値としては使わないでください。JSON の契約は [docs/json.md](../json.md) にあります。

## 行数の数え方

Qenome は同梱の SQLite（このツリーでは 3.53.4）を、Cloudflare の `workerd` の行数カウントのパッチ付きでビルドします。[NOTICE](../../NOTICE) がパッチを、[vendor/sqlite3/PROVENANCE.txt](../../vendor/sqlite3/PROVENANCE.txt) がハッシュと当て直し方を記録しています。パッチはプリペアドステートメントのカウンタを2つ、`LIBSQL_STMTSTATUS_ROWS_READ`（1025）と `LIBSQL_STMTSTATUS_ROWS_WRITTEN`（1026）を追加し、Qenome はそれを `rows_read` と `rows_written` として報告します。ローカル D1 も同じパッチで動くため、レポートはローカル D1 と同じ数え方（workerd のパッチ）になります。

ローカル D1 も、1回の実行について同じ2つの値をすでに返します。`wrangler dev` では `run` と `all`（エイリアスとして文書化されています）と `batch` が、結果の `meta` に `rows_read` と `rows_written` を返します。`raw`、`first`、`exec` は返しません。`wrangler d1 execute --local --json` は、そのコマンドの `meta` に同じ値を返します。これらの数値はローカル D1 のエンジンから出ます。Qenome の数値はパッチを当てた独自のビルドから出ます。[2つのビルドはコンパイルオプションが違います](#本番-d1-と異なる点)。そのため行数は一致しないことがあります。どちらも本番 D1 の請求ではありません。[なぜ他の方法ではないのか](why-not.md)に、これらの道具がすでに渡すものと、比較が足すものを書いています。

パッチは読み取りカウンタを `OP_Count`、`OP_Seek*`、`OP_NotExists`、`OP_SeekRowid`、`OP_Last`、`OP_Rewind`、`OP_Next`、`OP_VNext` で増やし、書き込みカウンタを `OP_Insert`、`OP_IdxInsert`、`OP_Delete`、`OP_Clear`、`OP_VUpdate` で増やします（ephemeral カーソルは除く）。実際には次のようになります。

- **読んだ行数**は、スキャンがたどる行とインデックスのエントリを数えます。位置決めの操作（`OP_Seek*`、`OP_NotExists`、`OP_SeekRowid`、`OP_Last`、`OP_Rewind`）は試行1回につき1を加え、行が見つからない場合も数えることがあります。`OP_Count` は返す行数を加えます。
- **書いた行数**は、文が挿入するテーブルの行とセカンダリインデックスのエントリ、さらにトリガーと外部キーの動作が挿入・削除する行を数えます。削除したテーブルの行は数えますが、対応するセカンダリインデックスのエントリの削除は数えません。
- どちらも、各コピーで文を最初に実行したときの値です。比較のために追加の実行はしないので、`--runs 0` でも両方の値が出ます。

トリガーも外部キーの動作もないテーブルにセカンダリインデックスが1本ある場合、単純な `INSERT` はテーブルの行1つとインデックスのエントリ1つを書くので、インデックスのあるコピーは書いた行数を2と報告します。その行を1つ削除する `DELETE` は、テーブルの行は数え、インデックスのエントリは数えないため、書いた行数は1です。`DELETE ... WHERE` は、書いた行数が同じままで読んだ行数だけ減ることがあります。古いインデックスのエントリを消す `UPDATE` は、インデックス更新の全コストより少なく報告します。

どちらのカウンタも32ビットです。それぞれ 4,294,967,295 を超えると一周するため、1回の実行で超えた文は巻き戻った値を報告します。判定は読み取った値のまま比較します。

## 判定の意味

結果の行は多重集合として比較します。同じ行が両方のコピーに同じ回数現れる必要があります。行の順序は参考情報で、一致判定には含めません。`--write` では、`RETURNING` の行（`RETURNING` が無ければ空）、`sqlite3_changes`、`sqlite3_total_changes` も一致する必要があります。

| 判定 | 意味 |
| --- | --- |
| `improved` | 結果の行が一致し、variant の読んだ行数が baseline より少なくとも 1% 少なく、variant の書いた行数が増えていない。 |
| `no-effect` | 結果の行が一致し、variant の読んだ行数が 1% 以上は減っていない。同じ行数も、それより小さい減少も、ここになる。variant の書いた行数は増えていない。それより小さい減少は `verdict_reasons` に書く。 |
| `needs-check` | 結果の行は一致するが、variant の読んだ行数か書いた行数が増えた。 |
| `regressed` | 結果の行は一致するが、マイグレーションで variant の読んだ行数か書いた行数が増えた。`--migration` の batch だけで、不一致・変更の拒否・時間切れ・比較不能が優先されない場合に batch の終了コードが `6` になる。 |
| `not-judged` | 結果の行が違う、比較できない、または `--migration` で variant だけでしか実行できないクエリ。実行されなかった `--write` にも使う。 |

判定は `rows_read` と `rows_written` で決まります。時間は参考値で、判定も終了コードも変えません。そのため `--runs 0` でも判定は残り、計時だけを省きます。baseline の `rows_read` の 1% 未満の減少は `improved` になりません。[意味のある最小の改善](#意味のある最小の改善)を参照してください。

`result` は結果の行を比較できたかを表します。

| 結果 | 意味 |
| --- | --- |
| `match` | 両方のコピーで結果の行が同じ。`--write` では、同じ `RETURNING` の行、`changes`、`total_changes` も必要。 |
| `mismatch` | 結果の行が違う、または `--write` が違う変更をした。終了コードは `3`。 |
| `incomparable` | 結果の行を比較できない。両側がある比較は終了コード `4`。variant だけで実行する `--migration` のクエリは `not-judged` で、その比較の終了コードは `0`、batch の終了コードは変えない。 |

警告は助言で、判定・行数・終了コードを変えません。コードの定義は [src/contract/values.zig](../../src/contract/values.zig) にあります。

| コード | 意味 | 対処 |
| --- | --- | --- |
| `no_analyze_stats` | 候補のインデックスのテーブルに、baseline のコピーで空でない `sqlite_stat1` エントリがない。 | 代表的なデータを入れて `ANALYZE` したコピーで試す。Qenome は `ANALYZE` を実行しない。`--seed-data` は spec に書いたテーブルで実行する。 |
| `data_too_small` | 候補のインデックスのテーブルが 1,000 行未満。 | より代表的なデータで試す。この警告は目安で、データが代表的である証明ではない。 |
| `bind_dependent_partial_index` | variant の計画が、バインド値が `WHERE` 句を満たすためだけに部分インデックスを使っている。 | 実際にデプロイする値で試す。改善はこの実行の値でだけ成り立ち、別のバインド値やパラメータの渡し方ではインデックスが使われなくなることがある。 |
| `unapplied_migrations` | ローカルの D1 データベースに、wrangler の設定にあるこれらのマイグレーションが適用されていない。 | `npx wrangler d1 migrations apply <BINDING> --local` を実行してから、もう一度比較する。テストしているスキーマがマイグレーションより古いため。 |

`--migration` の batch は、マイグレーションが複数のテーブルを触り得るため、`no_analyze_stats` と `data_too_small` を出しません。

## 意味のある最小の改善

`improved` になるには、variant の読んだ行数が baseline より少なくとも 1% 少なくなければなりません。判定は 2 つの `rows_read` を整数で比べます。`(baseline - variant) * 100 >= baseline` です。数え始める最小の減少は、baseline の 100 行につき 1 行で、端数は切り上げます。ちょうど 1% の減少は `improved` です。それより小さい減少は `no-effect` で、`verdict_reasons` に、baseline の読んだ行数の 1% 未満だと書きます。カウンタの値はそのままレポートに残り、`schema_version` は `2` のままです。

同じ判定を `--write` の比較と、`--migration` の batch の書き込み文にも使います。読んだ行数が増えた場合は、これまでどおり `needs-check`、その batch では `regressed` です。SELECT で書いた行数が増えた場合も、これまでどおり `needs-check` です。マイグレーションの書き込みでは、書いた行数は報告するだけで、判定は変えません。

1% は固定の目安で、`data_too_small` の警告が 1,000 行を使うのと同じ種類です。コマンドラインのフラグではありません。`rows_read` は両方とも表示したままなので、別の基準で読み直せます。小さいテーブルの点検索は `improved` のままです。100 行が 1 行になる減少は 1% を大きく超えるためです。100 行のような絶対数の下限にすると、その点検索が `no-effect` になります。[行数の数え方](#行数の数え方)の位置決めは試行 1 回につき 1 を足すので、大きいスキャンで 1 行だけ違う差はその 1 と同じ大きさであり、インデックスを残す理由にはしません。

精度コーパスには、この規則の既知の答えが 3 つあります。

- [testdata/accuracy/one-row-gain-of-50000/](../../testdata/accuracy/one-row-gain-of-50000/) は baseline が 50,000 行、variant が 49,999 行を読みます。判定は `no-effect` です。
- [testdata/accuracy/one-percent-gain-of-50000/](../../testdata/accuracy/one-percent-gain-of-50000/) は baseline が 50,000 行、variant が 49,500 行を読みます。ちょうど 1% で、判定は `improved` です。
- [testdata/accuracy/clear-gain-equality/](../../testdata/accuracy/clear-gain-equality/) は、同じ 50,000 行のテーブルに対する等値検索です。variant は 26 行を読み、判定は `improved` です。

## 本番 D1 と異なる点

結果はローカルのコピーの測定値です。本番の結果は、次のどれかの理由で変わります。

- **データの大きさと分布。** ローカルのデータベースや `--seed-data` の行は本番のデータではありません。行数や重複・NULL の数が違えば、行数が変わり、計画も変わることがあります。
- **統計。** プランナーは `sqlite_stat1` の `ANALYZE` データを使います。ローカルのコピーには統計がない（`no_analyze_stats`）か、別のデータの統計があるかもしれません。本番には別の統計があるか、まったくないかもしれません。Qenome は `--seed-data` に書いたテーブル以外では `ANALYZE` を実行しません。
- **SQLite の版とビルド。** レポートは同梱の版を `environment.sqlite_version` に、`--d1` ではローカル D1 エンジンの版を `d1.sqlite_version` に記録します。このツリーではどちらも SQLite 3.53.4 です。同梱のビルドとローカル D1 のビルドはコンパイルオプションが違い、本番 D1 は独自のビルドで動きます。版やビルドが違えば、計画と時間が変わることがあります。
- **クエリプランナー。** 別のデータや統計では、SQLite が別のインデックス、別の結合順、フルスキャンを選ぶことがあります。ローカルの計画は本番を約束するものではありません。
- **実際のトラフィック。** Qenome は渡したバインド値でクエリを実行します。本番では別の値で、それぞれの頻度で実行され、独自のキャッシュと同時書き込みがあります。`d1 insights` の `avgRowsRead` は、その期間に実行された値全体の平均で、1つの値の行数ではありません。
- **書き込み。** 書き込みカウンタはセカンダリインデックスの削除を数えません（[行数の数え方](#行数の数え方)を参照）。そのため、古いインデックスのエントリを消す `DELETE` や `UPDATE` は、インデックス更新の全コストより少なく報告します。
- **スキーマ。** ローカルの D1 データベースは、wrangler の設定にあるマイグレーションより古いことがあります。`unapplied_migrations` の警告は、適用されていないマイグレーションのファイルを一覧にします。そのスキーマでの結果は、インデックスの効果を隠すことがあります。
- **請求。** D1 は独自のカウンタで請求します。Qenome はローカルのコピーで `sqlite3_stmt_status` を読み、本番のカウンタは読みません。そのため、レポートから D1 の請求額は分かりません。ここでの `rows_read` が小さいことは、請求が小さいことではありません。

## 本番と自分で照合する方法

wrangler のコマンドは、データベース名またはバインディングを `<database>` の位置に書きます。`wrangler d1 insights` は wrangler で experimental とされており、リモートの D1 データベースに対して動きます。アカウントに **Account Analytics: Read** の権限が必要です。API トークンを使う場合は、その権限をトークンに追加してください。

1. 読んだ行数の平均が大きいクエリを一覧にします。

   ```sh
   npx wrangler d1 insights <database> --sort-by=reads --sort-type=avg --time-period=7d --json
   ```

   `--time-period` は日・時間・分（`7d`、`24h`、`60m`）を受け付け、最大は31日です。`--limit` の既定は5です。見たいクエリが一覧にないときは値を増やしてください。`d1 insights` はクエリのテキストでまとめ、バインド値は記録しません。

2. クエリを1つ選び、`avgRowsRead`、`avgRowsWritten`、`numberOfTimesRun` を控えます。平均は、その期間のそのクエリテキストのすべてのバインド値とすべての実行に対する値です。

3. 同じクエリを、本番に近いローカルのコピーで、代表的なバインド値を使って Qenome にかけます。ローカルの D1 データベース、行数が近い `--seed-data`、または使用を許されたエクスポートのコピーを使います。ローカルの D1 データベースには `--d1 <BINDING>` を、エクスポートにはデータベースのパスを使ってください。baseline の `rows_read` と `avgRowsRead` を比べます。

   ```sh
   npx qenome --d1 <BINDING> select.sql index.sql --bind 1:int:1234 --runs 0 --format json
   ```

   JSON では `baseline.counters.rows_read`、human では `rows read` 行の左側に値が出ます。データ・統計・版・バインド値が違えば差は出ます。[本番 D1 と異なる点](#本番-d1-と異なる点)を参照してください。2つの値が近いときに、この比較は役に立ちます。

4. 任意で、代表的な値を使って本番でクエリを1回実行し、結果の `meta` にある `rows_read` を読みます。

   ```sh
   npx wrangler d1 execute <database> --remote --json --command "SELECT ..."
   ```

   これは本番で実行するので、利用として数えられます。`--command` にはバインドのオプションがないため、値を SQL に書いてください。1つの値での1回の実行であり、平均ではありません。

5. インデックスをデプロイしたあと、同じ期間の長さで `d1 insights` をもう一度実行し、`avgRowsRead` を比べます。期間の間でトラフィックは変わるので、平均が下がっても、インデックスが原因だという証明にはならず、確認にとどまります。期間の長さとクエリのテキストは同じにしてください。

ローカルの `rows_read` と本番の `avgRowsRead` は別の測定です。一致することはありますが、同じ測定ではありません。

## 回帰を示す例

`--migration` は、クエリが使うインデックスを落とす場合を含むスキーマ変更を検査します。精度のコーパスには、[testdata/accuracy/migration-regressed/](../../testdata/accuracy/migration-regressed/) に既知の答えのケースがあります。

- `select.sql`: `SELECT id, note FROM events WHERE customer_id = ?;`
- `migration.sql`: `DROP INDEX idx_customer;`

マイグレーションの前の計画は `SEARCH events USING INDEX idx_customer (customer_id=?)`、あとは `SCAN events` です。結果の行は一致しますが、variant はより多くの行を読みます。判定は `regressed`、batch の終了コードは `6` です。JSON では判定が `results[].comparison.verdict` に入り、そのクエリは `summary.needs_check` の件数に数えられ、`recommended` は `null` になります。human は `Results` 表に `regressed` を出します。

このケースに新しいコードは不要です。コーパスがすでに検査しています。
