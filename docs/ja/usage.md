# 使い方

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
qenome app.db select.sql index.sql --seed-data seed.json
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000
qenome app.db --write update.sql --index-sql index.sql
qenome --d1 DB select.sql index.sql
qenome app.db --batch batch.json
qenome app.db --batch batch.json --audit-indexes
qenome app.db --batch batch.json --migration 0002_replace_index.sql
qenome app.db select.sql --suggest
qenome app.db --batch batch.json --suggest
qenome --record qenome-record.log --out qenome-manifest
```

パスは DB・SELECT（または書き込み）ファイル・CREATE INDEX ファイルの順に埋まり、`--db` / `--select` / `--write` / `--index-sql` でも指定できます（混在可）。位置指定のパスは、まだ指定されていない最初の役割に埋まります。`--d1` のときは、位置指定の2つのパスが SELECT と CREATE INDEX の役割に入ります。`--write` のときは、位置指定のパスが SELECT の代わりに書き込みファイルへ入ります。`--` の後は `-` で始まるパスとして扱います。

`select.sql` には読み取り専用の SELECT を1本、`index.sql` には候補の `CREATE INDEX` を1本書きます。複数文やその他の文は拒否します。`--migration` のファイルだけは例外で、`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX`・`CREATE TABLE`・`ALTER TABLE` を複数書けます（「まとめて比べる（--batch）」を参照）。

`--write` は `--select` の代わりに、`INSERT`・`UPDATE`・`DELETE`・`REPLACE` を1本受け取ります。先頭の `WITH` と末尾の `RETURNING` は使えます。`--batch`・`--migration`・`--suggest` とは併用できません。文は各コピーでトランザクションの中で実行してロールバックするため、元のデータベースは変更されず、`--runs` の各回は同じ行から始まります。

- `--db <PATH>`: 対象の SQLite データベース（必須、1回だけ。`--d1` とは併用しない）
- `--d1 <BINDING>`: wrangler 設定の `d1_databases` にあるこのバインディングのローカル D1 データベースを `--db` の代わりに使う。「D1 のローカルデータベース」を参照
- `--config <PATH>`: `--d1` が読む wrangler 設定（既定はカレントディレクトリの `wrangler.toml` / `wrangler.jsonc` / `wrangler.json`）
- `--select <FILE>`: 比較する SELECT を1本書いたファイル（必須、1回だけ。`--write` とは併用しない）
- `--write <FILE>`: SELECT の代わりに、`INSERT`・`UPDATE`・`DELETE`・`REPLACE` を1本書いたファイル。サンドボックスの各コピーでトランザクションの中で実行してロールバックする。「書き込みを比べる」を参照。`--select`・`--batch`・`--migration`・`--suggest` とは併用できない
- `--index-sql <FILE>`: 候補の CREATE INDEX を1本書いたファイル（必須、1回だけ）
- `--batch <FILE>`: JSON のマニフェストにある全 SELECT を、全候補 CREATE INDEX と1回の実行で比べる。「まとめて比べる（--batch）」を参照。`--select` / `--index-sql` / `--bind` / 位置指定の SELECT・INDEX、`--runs`、`--format kv` とは併用できない
- `--audit-indexes`: `--batch` と組み合わせて、マニフェストのどのクエリの実行計画にも使われなかったインデックスと、先頭の列がほかのインデックスや主キーに覆われているインデックスを報告し、UNIQUE と PRIMARY KEY のインデックスは別の一覧に分ける。マニフェストは `queries` だけでよく、`candidates` は無視する。`--batch` が必要で、`--suggest`・`--migration`・`--seed-data` とは併用できない。「インデックスの監査（--audit-indexes）」を参照
- `--record <FILE>`: `qenome/d1` が出力した記録を読み、`--out` に `candidates` を持たないマニフェストを書く。データベースは要らない。マニフェストにはバインド値が入るので、ローカルに置いて commit しない。`--out` とセットで使い、`--db`・`--d1`・`--select`・`--write`・`--index-sql`・`--batch`・`--migration`・`--seed-data`・`--bind`・`--runs`・`--suggest`・`--format kv` とは併用できない。`--format human`（既定）または `--format json` と、`--n-plus-one-threshold N` を使える。「実際に実行されたクエリを記録する（--record）」を参照
- `--out <DIR>`: `--record` の出力先。存在しない新しいディレクトリを指定する。ディレクトリは `0700`、ファイルは `0600` で作る
- `--migration <FILE>`: `--batch` の全クエリを実行する前に、この SQL ファイルを variant にだけ適用する。`--batch` と、`candidates` を持たないマニフェストが必要。`--select` / `--index-sql` / `--bind` / `--runs` / `--suggest` / `--format kv` とは併用できない。`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX`・`CREATE TABLE`（`AS SELECT` を除く）・`ALTER TABLE`（ADD / RENAME / DROP COLUMN と RENAME TO）を受け付け、データ変更・`DROP TABLE`・`ATTACH`・`PRAGMA`・その他の文は文番号付きで拒否する。マイグレーションで消した・名前を変えた列やテーブルを参照するクエリがあると実行全体が終了コード `1` で止まる。列を足す・消すと `SELECT *` は結果の列数が変わるため比較できず、終了コード `4` になる。「まとめて比べる（--batch）」を参照
- `--seed-data <FILE>`: 比較の前に、この JSON の指定に従ってサンドボックスのコピーのテーブルを決まったダミーデータで置き換える。元のデータベースは変更しない。`--batch`・`--suggest`・`--migration` を含むすべてのモードで使える。「サンドボックス用のデータを作る」を参照
- `--scale <ROWS,ROWS[,ROWS]>`: `--seed-data` と組み合わせて、2〜3の狭義増加する行数で同じ比較を1回の実行で行い、結果を並べて出す。各段階はそのサイズの新しいサンドボックスのコピーに seed する。spec の中で最も大きいテーブルがその段階の行数になり、ほかのテーブルも同じ倍率で増える。`--batch`・`--suggest`・`--migration`・`--audit-indexes`・`--record`・`--format kv` とは併用できない。「複数のサイズで測る（--scale）」を参照
- `--suggest`: インデックスを自分で用意する代わりに、SQLite の expert に候補のインデックスを提案させ、その提案を比べる。`--batch` のときはマニフェストの `candidates` を省略できる。`--runs`、`--format kv`、インデックスのファイル（`--index-sql` または3番目の位置指定パス）とは併用できない。「候補のインデックスを提案させる（--suggest）」を参照
- `--bind <N>:<TYPE>[:<VALUE>]`: SELECT のパラメータ N に渡す型付きの値。繰り返し指定できる。N は SQLite のパラメータ番号で、名前付きパラメータは最初に現れたときの番号を共有し、`?NNN` は NNN を使う。TYPE は int / real / text / null（null は値を取らない）。1 からパラメータ数までの各番号をちょうど1回ずつ指定する必要があり、パラメータの無い SELECT に `--bind` は付けられない。値は引数の残り全体なので、text には `:` を含められる
- `--runs <N>`: 結果が一致したあとの計測ラウンド数。各ラウンドは各コピーで SELECT を1回計測する。既定は 10、0 で計測しないが読んだ行数と判定は残る、最大 1000。1秒を超える計測は進捗を stderr に出す。`--write` では N は各コピーでロールバックしながら実行する回数（最低1回）で、計測は行わず、毎回同じ件数になることを確かめる
- `--timeout-ms <MS>`: インデックス作成、SELECT 1回、`--write` の1回あたりの制限時間。既定は 30000、0 で無効。1回の実行は全体で、データベースのコピーに加えて `(3 + 4 × runs)` 回分の制限時間に加え、ANALYZE とサイズの診断、SELECT にパラメータがある場合の bind 依存の部分インデックス診断それぞれの制限時間までかかることがある
- `--format <human|kv|json>`: 出力形式（既定 human）。「出力形式」を参照
- `--show-binds`: バインド値を出す。付けない場合、human はバインドを出さず、kv と json は番号・型・テキストの長さだけを出し、値をログに残さない
- `--show-rows`: 片方のコピーだけが返した例の行を出す。付けない場合、どの形式も件数だけを出して行の値をログに残さない。human はこのフラグで再実行するよう案内する
- `--help`, `-h`: 使い方を表示して終了コード 0 で終了する
- `--version`: `build.zig.zon` の版を `qenome <version>` で表示して終了コード 0 で終了する

値を取るオプションは `--db=app.db` のように `=` でも書けます。

Qenome はデータベースを読み取り専用で開き、SQLite の backup API を使って、Linux と macOS では `$TMPDIR`（既定は `/tmp`）、Windows では `%TMP%`、`%TEMP%`、`%USERPROFILE%` のうち設定されている最初の場所の下にある非公開ディレクトリへコピーします。このコピーが baseline で、2つ目のコピーが variant になり、候補のインデックスは variant にだけ作ります。`--seed-data` を付けると、Qenome は variant を作る前に baseline へ spec の行を入れるので、両方のコピーが同じダミーデータを持ちます。SELECT は両方のコピーで実行し、結果の行を多重集合として比較します（同じ行が同じ回数だけ現れること）。行の順序は参考情報として示し、一致判定には含めません。

読んだ行数と書いた行数は、この最初の1回の実行から取るので追加のコストはなく、`--runs 0` でも残ります。結果が一致し、`--runs` が 0 でないとき、SELECT をもう一度両方のコピーで参考値として計測します。各コピーには、行の比較に使った計測しないウォームアップが1回あります。計測ラウンドは baseline→variant と variant→baseline を交互に繰り返します（ABBA）。1ラウンドは reset 文から `SQLITE_DONE` までの `sqlite3_step` を、割り込みの確認を含めて計測します。列の読み取り、prepare、bind、計画の取得は計測しません。各コピーは書き込み直後の接続とページキャッシュを再利用するため、キャッシュはウォームです。非公開ディレクトリは、結果にかかわらず終了前に削除します。`--write` では各回がトランザクションとロールバックの中で行う実際の計測で、計測ラウンドはありません。

Linux と macOS では、このディレクトリを所有者だけがアクセスできる権限（`0700`）で作ります。Windows にはこれに相当する指定がないため、一時ディレクトリのアクセス制御を引き継ぎ、保護はその場所がそのユーザー専用であることに依存します。Qenome は Windows では Ctrl+C と Ctrl+Break、Linux と macOS では SIGINT・SIGTERM・SIGHUP を受けたときに後片付けしますが、コンソールを閉じる・プロセスを強制終了するといった強制的な終了では、コピーが残ることがあります。

判定は読んだ行数から決まり、終了コードを変えません。`--write` では `RETURNING` の行・`changes`・`total_changes` も一致する必要があります。

読んだ行数と書いた行数は、ローカル D1 と同じ数え方（workerd のパッチ）です。Qenome は同梱 SQLite を `workerd` の行数カウントのパッチ付きでビルドします。この数値は、まだ本番 D1 と照合していません。どちらのカウンタも 32 ビットで、それぞれの回数が 1回の実行で 4,294,967,295 を超えると一周して小さい値に戻るため、その場合は巻き戻った値を報告し、判定もその値で比較します。パッチの出どころは `NOTICE`、当て直す手順は `vendor/sqlite3/PROVENANCE.txt` に記録しています。

## 書き込みを比べる

`--write write.sql --index-sql index.sql` は、`INSERT`・`UPDATE`・`DELETE`・`REPLACE` を1本、候補のインデックスの前後で比べます。先頭の `WITH` と末尾の `RETURNING` は使えます。`CREATE`・`DROP`・`ALTER`・`PRAGMA`・`ATTACH`・`VACUUM` と複数文は拒否します。文は SELECT モードと同じ authorizer で準備するため、main スキーマへの書き込みと、読み取り・関数・共通テーブル式だけを許可します。

元のデータベースはこれまでどおり読み取り専用で開き、コピーします。各コピーでトランザクションを開始し、文を実行し、カウンタ・changes・`RETURNING` の行を読み、ロールバックします。次の `--runs` の回は同じ行から始まります。書き込み用の接続はサンドボックスのコピーにだけ開き、SQLite の外部キーを有効にします（`PRAGMA foreign_keys=ON`）。そのため `ON DELETE CASCADE` や `SET NULL` の動作も数え、文と一緒にロールバックします。トリガーも有効で、その書き込みも数えます。ロールバックに失敗したら比較を中止します。サンドボックスを修復しようとはしません。

両方のコピーが同じ変更をしたことを確かめます。比べるのは3つです。`RETURNING` の行の多重集合（`RETURNING` が無ければ空）、`sqlite3_changes`（文自身が変更した行数）、`sqlite3_total_changes` の差（トリガーと外部キーの変更も含む）。どれかが違えば結果の不一致（終了コード `3`）とし、行数から判定しません。

`--runs` の意味はこのモードでは変わります。各コピーでロールバックしながら実行する回数で、最低1回です。最初の実行の値を報告します。2回目以降のカウンタか changes が違えば、同じ行から同じように実行できない文なので、比較不能（終了コード `4`）にして理由を出します。`--runs 0` でも1回は実行します。計測ラウンドは無いため `timing` は `null` で、`time` の行も計測していないと表示します。

実行のたびに結果が変わる関数（`random()`・`randomblob()`・`changes()`・`last_insert_rowid()`・`total_changes()`）、現在時刻を読む関数（`date()`・`datetime()`・`julianday()`・`strftime()` などの時刻関数）、スキーマテーブル（`sqlite_schema`・`sqlite_master`・`sqlite_stat*`）を読む文は実行しません。トリガーがスキーマを読む場合も含みます。比較不能（終了コード `4`）にして、文を実行しなかったと表示します。`RETURNING` は行として比べるので、どの行を変更したかの確認に使えます。

書いた行数は SELECT モードと同じローカル D1（workerd のパッチ）の数え方です。カウンタにはテーブルの行と、セカンダリインデックスの挿入・トリガーの挿入・外部キーの CASCADE が入ります。同梱のパッチはセカンダリインデックスの削除を数えません。そのため `DELETE` や、インデックスの古い項目を消す `UPDATE` は、テーブルの変更は数えてもインデックスの削除は数えません。`DELETE ... WHERE` は、書いた行数が同じまま読んだ行数だけ減ることがあります。書いた行数はパッチが測る範囲であり、インデックス更新の全コストではないと捉えてください。

`--write` は `--d1`・`--seed-data`・`--bind`・`--timeout-ms`・`--show-binds`・`--show-rows` とすべての出力形式で使えます。`--batch`・`--migration`・`--suggest` とは併用できません。これらのモードは SELECT 専用の入力のままで、`--write` を usage エラーで拒否します。

## サンドボックス用のデータを作る

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
| --- | --- | --- |
| `fixed` | `value` | すべての行で同じ値 |
| `uniform` | `values` | 値のどれかを同じ確率で選ぶ |
| `ratio` | `value`、`ratio`、任意の `otherwise` | 指定した割合（`0`〜`1`）の行で `value`、残りで `otherwise`（既定は `null`） |
| `sequence` | 任意の `from`（既定 `1`）と `step`（既定 `1`） | 行ごとに `step` ずつ増える整数 |

JSON の文字列は TEXT、整数は INTEGER、小数を含む数は REAL、`true` / `false` は 1 / 0、`null` は NULL になります。spec に書いたテーブルは先に空にしてから入れるので、行数は `rows` と正確に一致します。書かないテーブルはそのままです。spec に書いたテーブルにトリガーがあると、ほかのテーブルを変えたり seed が制御できない値を生成したりするため、Qenome はそのテーブルを拒否します。大文字小文字だけが違うテーブル名・列名も拒否します。上限は 100 テーブル、1テーブル 10,000,000 行、合計 20,000,000 行です。`--seed-data` は `--batch`・`--suggest`・`--migration` を含むすべてのモードで使えます。

同じ spec と同じ `seed` なら、実行のたびに同じ行になります。レポートに残した比較を再現できます。値は1つのトランザクションで入れ、その中で spec に書いた各テーブルに `ANALYZE` を実行します。そのためプランナは生成した行の統計を見られ、`no_analyze_stats` はこれらのテーブルには当てはまりません。PRIMARY KEY・UNIQUE・NOT NULL・CHECK などの制約に違反すると、SQLite のメッセージを添えて終了コード `1` で止まります。テーブルが `ON CONFLICT IGNORE` や `ON CONFLICT REPLACE` を宣言していても同じです。外部キーはサンドボックスのコピーでは検査しません（SQLite の既定）ので、テーブルはどの順に書いてもかまいません。ダミーデータの生成は `--timeout-ms` の対象外です。Ctrl+C で止めるとコピーも削除します。ダミーデータは非公開のコピーにだけ入り、終了前に削除します。

human の Summary には `seed data` と `seed` の行、kv には `seed-data`・`seed`・`seed-rows`・`seed-tables` とテーブルごとの `seed-table`、json には `path`・`seed`・`rows`・`tables` を持つトップレベルの `seed_data` が加わります。

## 複数のサイズで測る（--scale）

候補のテーブルが 1,000 行未満のとき、human の Summary は `data` の行でそれを示し、`next` の行が次に実行するコマンドです。そのテーブルのフルスキャンはすべての行を読むので、小さい `rows_read` はインデックスがなくても無害だという意味ではありません。テーブルを seed の spec に書いて、測り直します。

```sh
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000 --runs 0
```

パスはこの実行のものです。`--suggest` と `--batch` は `Recommendation:` の下に同じ注意を出します。提案されたインデックスは `index.sql` として保存し、その1件を測り直してください。`--scale` はこれらのモードと併用できません。JSON の警告には `table`、`rows`、`full_scan`、`next_command` が加わり、`schema_version` は `2` のままです。[精度と本番 D1](accuracy.md#判定の意味) を参照してください。

`--scale 1000,10000` は、同じ比較を2〜3の行数で実行し、結果を並べて出します。テーブルが大きくなっても改善が残るかを確かめられます。`--seed-data` が必要です。データの分布とサイズを分けて書ける入力は seed の spec だけだからです。各段階では、spec の中で最も大きいテーブルの行数をそのサイズにし、ほかのテーブルを同じ倍率で（四捨五入し、最低1行に）増やします。テーブル間の比率は変わりません。spec で `rows: 0` のテーブルも1行以上になります。spec に書いた全テーブルが `rows: 0` のときは比率がないので、全テーブルがその段階のサイズになります。spec に書いていないテーブルは `--seed-data` と同じくそのままです。

```sh
qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000 --runs 0
```

```text
scale: 1,000, 10,000 rows in 2 steps
database: app.db
select: select.sql
index: index.sql
seed-data: seed.json
sqlite: 3.53.4
work-dir-parent: <work-dir-parent>

Steps
          rows baseline read variant read   ratio  verdict     result       plan    median
         1,000         1,000            0 0.0000x  improved    match        changed -
        10,000        10,000            2 0.0002x  improved    match        changed -

note: these rows come from generated data measured on this machine; they are not
production D1 billing.
```

各段階は、元のデータベースを新しいサンドボックスへコピーし、そのコピーに seed し、variant に候補のインデックスを作り、既存の比較を実行し、次の段階の前にコピーを削除します。表は1段階1行で、行数、両方のコピーが読んだ行数、variant / baseline の比、`--write` のときの書き込んだ行数、判定、結果、実行計画が変わったか、`--runs` が `0` でないときの中央値を出します。`--show-binds` のときは先頭の項目にバインド値も並べ、`--show-rows` のときは結果が `match` でない段階について、片方のコピーだけが返した行の例も出します。警告は段階で違うときだけ、例えば最も小さい段階の `data_too_small` だけを出します。判定が段階で変わる場合は、`The verdict changes between 1,000 and 10,000 rows.` のように1行で示します。増え方の分類はしません。最後の行に、生成したデータをこのマシンで測ったもので、本番 D1 の請求ではないと書きます。

段階は2〜3個の狭義増加する整数で、各段階は 10,000,000 行以下です。スケールした spec は1テーブル 10,000,000 行、合計 20,000,000 行以内でなければなりません。それ以外は、コピーを作る前の usage エラー（`usage_scale`、終了コード `2`）です。`--scale` は `--d1`・`--write`・`--bind`・`--runs`・`--timeout-ms`・`--show-binds`・`--show-rows` と `--format human` / `json` で使えます。`--batch`・`--suggest`・`--migration`・`--audit-indexes`・`--record`・`--format kv` とは併用できません。

終了コードは、1回の比較と同じ優先順位で、段階の中で最も重いものです（`3`、次に `4`、次に `124`、次に `1`、どれもなければ `0`）。実行できない段階があると、レポートを書く前に実行全体が止まります。

`--format json` では、`scale_schema_version` `1` を持つ別のオブジェクトを出します。`inputs`、`environment`、サイズごとの `steps`（`tables` と `schema_version` 2 の比較全体）、実行全体の `warnings` が入ります。詳細は [docs/json.md](../json.md#scale-report-scale_schema_version-1) にあります。

## D1 のローカルデータベース

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

Qenome はバインディングのマイグレーションも確認します。`d1_databases` のエントリから `migrations_dir`（既定は設定ファイルの隣の `migrations`）と `migrations_table`（既定は `d1_migrations`）を読み、そのディレクトリ直下の `.sql` ファイルを、記録表の名前と比べます。未適用のファイルがあると、`--d1` のどのモードでも `unapplied_migrations` の警告を出し、wrangler の並び順（先頭の番号、次に辞書順）でファイル名を示して、`npx wrangler d1 migrations apply DB --local` を案内します。古いスキーマに対して比べると、インデックスの効果が見えなくなるためです。メッセージに並べるファイル名は最大 10 件で、残りは件数にします。警告は判定・件数・終了コードを変えません。記録表またはディレクトリが無いとき、ローカルのデータベースを読めないとき、記録表やディレクトリが確認の上限を超えて大きいときは出しません。Qenome はローカルのデータベースを読み取り専用で開き、名前だけを読むので、元のデータベースは変わりません。`migrations_pattern` と `[env.<name>]` のバインディングは読みません。

### サンプルプロジェクトを試す

`examples/d1-toml` と `examples/d1-jsonc` には、同じデータベースとクエリを `wrangler.toml` 版と `wrangler.jsonc` 版で置いています。どちらも独立した wrangler プロジェクトで、設定には `DEMO_DB` のバインディング1つだけがあり、`database_id` はデプロイしないプレースホルダーです。wrangler は `npx` で動かすため Node.js が要ります。リポジトリには何もインストールせず、`.wrangler/` は Git の追跡対象外です。

`examples/d1-toml` で次のコマンドを実行します。`examples/d1-jsonc` でも同じコマンドが動きます。

```sh
npx wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql
qenome --d1 DEMO_DB select.sql index.sql --runs 40
```

1行目が `.wrangler/` にローカルのデータベースを作り、20万行を投入します。2行目が `select.sql` と `index.sql` の候補のインデックスを比較し、`result rows` が `match`、`verdict` が `improved`、実行計画が `SCAN events` から `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` に変わり、D1 ブロックに SQLite の版と注意が出ます。終了コードは 0 です。

`schema.sql` は `events` を作り直すので、いつでも再実行できます。デプロイはしません。`qenome` は PATH 上のものを使う想定で、[Build from source](../../CONTRIBUTING.md#build-from-source) の直後は `./zig-out/bin/qenome` です。`4.152.0` はサンプルを確認した wrangler の版です。
