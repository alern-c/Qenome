# 複数のクエリと候補を比べる

## まとめて比べる（--batch）

`--batch manifest.json` は、マニフェストにある全 SELECT を、全候補 `CREATE INDEX` と比べます。マニフェストは、必要な配列を持つ JSON オブジェクトです。

```json
{
  "queries": [
    { "select": "queries/orders.sql", "binds": ["1:int:1234"] },
    { "select": "queries/recent.sql" }
  ],
  "writes": [
    { "write": "writes/mark.sql", "binds": ["1:int:1234"] }
  ],
  "candidates": [
    { "index_sql": "candidates/a.sql" },
    { "index_sql": "candidates/b.sql" }
  ]
}
```

- `queries` は1〜100件。`candidates` は1〜100件で、`--suggest` が提案を足すとき、または `--migration` が variant の変更を渡すときは省略（または `[]`）できる。マニフェストは1 MiBまで。
- `writes` は1〜100件で、`--migration` のときだけ受け付ける。`--migration` なしで書くと、何も実行する前に終了コード `1` と `batch_manifest_invalid` で拒否する。各項目は、`INSERT`・`UPDATE`・`DELETE`・`REPLACE` のいずれか1本を持つファイルのパス。先頭の `WITH` と末尾の `RETURNING` は使え、`--write` と同じ検査と制限時間がかかる。
- 同じパスを `queries` の中で2回、`writes` の中で2回、または `candidates` の中で2回書くことはできない。
- `--migration` のとき、`candidates` は省略または `[]` にし、マニフェストは `queries` と任意の `writes` を持つ。
- `select`・`write`・`index_sql` はファイルのパス。カレントディレクトリではなく、マニフェストのディレクトリを基準に解決する。各ファイルは読み取り専用の SELECT 1本、書き込み文1本、または `CREATE INDEX` 1本で、1 MiBまで。
- `binds` は任意で、`--bind` と同じ `N:TYPE:VALUE` 形式。クエリと書き込み文はそれぞれ自分の `binds` を持つ。パスとバインド値は NUL バイトを含まない JSON 文字列にする。
- `select`・`write`・`index_sql` の文字列は、JSON の報告には書いたとおりに出す。human の報告では、絶対パスを、同じ一覧のほかのパスと末尾が重ならない最短の部分に短くして出す（別のディレクトリにある候補は `a/x.sql` と `b/x.sql` のように区別できる）。相対パスと `suggested:N` のラベルは書いたとおりに出す。フルパスは JSON の報告に残り、`--migration` では `migration:` の行にも出る。

Qenome はデータベースを1回コピーし、何かを実行する前に全 SELECT・全書き込み文・全候補を検査します。そのあと候補をマニフェスト順に処理し、候補ごとに baseline をもう一度コピーして、そのコピーにだけインデックスを作り、全クエリを両方のコピーで実行します。baseline の SELECT は候補ごとに実行し直します。`--migration` のときは、候補のクエリのあとに、マニフェストの全書き込み文を同じ2つのコピーで実行します。

`--migration <FILE>` を付けると、variant の変更は候補インデックスではなく、マイグレーションのファイル全体になります。ファイルは 1 MiB までです。Qenome は variant を触る前にファイルを検査し、セミコロンで区切った `CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX`・`CREATE TABLE`（`AS SELECT` を除く）・`ALTER TABLE`（ADD COLUMN / RENAME COLUMN / DROP COLUMN / RENAME TO）を許可します。`INSERT`・`UPDATE`・`DELETE`・`DROP TABLE`・`ATTACH`・`PRAGMA`・その他の文は文番号付きで拒否し、variant と元のデータベースは触りません。そのあと文をファイル順に variant にだけ適用するので、列を追加してインデックスを張る、列やテーブルの名前を変える、同じ名前のインデックスを落として作り直す、といった変更ができます。各文は `--timeout-ms` の制限時間を持ちます。元のデータベースは変更しません。レポートには、human では `migration:` の節、json ではトップレベルの `migration` オブジェクトとして、パスと適用した全文を出します。マイグレーションが追加した列やテーブルを使うクエリは baseline では実行できないため、variant だけで計測し、計画と行数を判定 `not-judged` として出します。理由は `verdict_reasons` に入り、終了コードは変わりません。human は `not-judged` の summary 列と `Not judged` の一覧を追加し、JSON は `summary.not_judged` で数え、比較オブジェクトの `baseline` を `null` にします。マイグレーションが壊すクエリがあると、実行全体が止まります。マニフェストが、マイグレーションで消した・名前を変えた列やテーブルを参照していると、variant ではその `SELECT` を準備できないため、stdout には何も書かずに終了コード `1` で止まり、`error:` 行でどのクエリかとマイグレーションのファイルのパスを示します（JSON では `batch_variant_failed`）。CI もそこで 0 以外で止まります。マニフェストにはマイグレーション後の名前を書いてください。列を足す・消すと、`SELECT *` は結果の列数が変わるため比較できず、`incomparable` になり、batch は終了コード `4` で終わります。比べたいときは、必要な列を明示した `SELECT` をマニフェストに書いてください。結果の行が一致しても、マイグレーション後にクエリの読んだ行数か書いた行数が増えた場合、そのクエリの判定は `regressed` になります。human の `Results` 表は `regressed`、JSON は `results[].comparison.verdict` が `"regressed"` です。`summary` の件数キーは `needs_check` のままで、そのクエリを数えます。batch の終了コードは `6` です。結果の不一致 `3`、変更の拒否 `1`、時間切れ `124`、比較不能 `4` が優先されます。`no-effect` だけなら `0` です。ほかのモードでは同じ条件を `needs-check` と呼びます。`no_analyze_stats` と `data_too_small` の警告は、マイグレーションが複数のテーブルを触り得るため出しません。`bind_dependent_partial_index` の警告は variant の計画だけで判定できるため、マイグレーションでも出します。

`writes` は `--migration` の実行で書き込み文を比べます。候補のクエリのあと、Qenome は各書き込み文を baseline と variant の両方で実行し、それぞれトランザクションの中で実行してロールバックします。次の文は同じ行から始まり、元のデータベースにもサンドボックスのコピーにも変更は残りません。各文は実行前に `EXPLAIN` で計画を読み、`--timeout-ms` は計画の読み取り・baseline の実行・variant の実行にそれぞれかかります。報告には両方のコピーの `rows read` と `rows written` を出します。判定はクエリと同じく `rows read` で決まります。増えたら `regressed`（batch は終了コード `6`）、同じか baseline の読んだ行数の 1% 未満の減少なら `no-effect`、1% 以上の減少なら `improved` です。`rows written` は報告するだけで判定は変えません。マイグレーションが足すインデックスの分、`INSERT` や `UPDATE` は必ず1件以上多く書くためです。行の一致は `--write` と同じで、`RETURNING` の行、`changes`、`total_changes` の差が両方のコピーで同じでなければならず、違えば `mismatch` で終了コード `3` です。スキーマ・現在時刻・非決定的な関数を読む書き込み文は実行せず、判定 `not-judged`・`result` `incomparable` として終了コード `4` に寄与します。同梱の D1 の行数パッチは二次インデックスの削除を数えないため、インデックスを消すマイグレーションでは `rows written` は減らず、変化は `rows read` にだけ出ます（[accuracy](accuracy.md) を参照）。マイグレーションが追加した列やテーブルを使う書き込み文は baseline では実行できないため、variant だけで実行し、クエリと同じく baseline の理由と variant の行数を `not-judged` として報告し、終了コードは変えません。variant が準備できない書き込み文や、実行に失敗する書き込み文（たとえばマイグレーションが足した UNIQUE 制約に違反する場合）は、報告の前に実行全体を止めます。stdout は空、終了コードは `1`、エラーコードは `batch_write_failed` です。計画の読み取りが `--timeout-ms` に達した場合も同じく止まり、`batch_write_timeout` と終了コード `124` になります。variant の実行が `--timeout-ms` に達した書き込み文は、比較なしの `timeout` として記録し、batch は終了コード `124` で続行します。マイグレーションは、クエリが推薦の条件を満たし、かつ `mismatch`・`incomparable`・timeout・`regressed` の書き込み文がないときだけ `Recommendation:` になります。`not-judged` の書き込み文は推薦を妨げません。human は `Writes` の節を追加し、文ごとの行と数え方の限界の注記を出します。`Summary` の表はクエリの件数だけを数えます。JSON はマニフェストに `writes` があるときだけトップレベルの `writes` 配列を追加します。書き込み文が失敗したときの `error:` 行は SQLite のメッセージをそのまま含むため、データベースの行やバインド値の文字列（トリガーの `RAISE()` のメッセージなど）が入ることがあります。stderr はマニフェストと同じくらい慎重に扱い、保存する CI のログにも同じ注意を払ってください。

`--migration` の `size increase` は、ファイルサイズの差ではなく、使用中ページが持つバイト数（`(page_count - freelist_count) * page_size`）の差です。`DROP INDEX` はページを SQLite の freelist に移すだけでファイルを縮めないため、ファイルサイズの差は `0 B` のままですが、使用中のバイト数では解放された量が `-2.06 MiB` のような負の値で出ます。ファイル自体が縮むのは `VACUUM` の後です。`--migration` を使わない実行は、これまでどおりファイルサイズの差を出します。

<details>
<summary>候補の失敗・終了コード・実行時間</summary>

インデックスを作れなかった候補は記録して次へ進みます。

| 状態 | 意味 | 終了コードへの寄与 |
| --- | --- | --- |
| `index_rejected` | SQLite が `CREATE INDEX` を拒否した（例: 重複する行への UNIQUE 制約） | `1` |
| `index_timeout` | インデックスの作成が `--timeout-ms` に達した | `124` |
| `variant_timeout` | variant 側の SELECT が `--timeout-ms` に達した。そのクエリは判定せず、ほかのクエリの結果は残す | `124` |

全体に影響する失敗では、報告を書く前に止まり、stdout は空のままです。baseline の SELECT の失敗・時間切れ、マイグレーションの後に variant で実行できない SELECT（消した・名前を変えた列やテーブルを使うもの）、variant が準備できない・実行できない書き込み文、baseline の書き込み実行や計画の読み取りの失敗・時間切れ、シグナル、variant / baseline の接続の失敗、一時コピーの作成・削除の失敗、ディスク不足などの保存の失敗が該当します。候補単位の失敗は `error:` 行にはしません。variant で制限時間に達した書き込み文は `Writes` と `writes` の中で `timeout` として記録し、実行は続きます。

報告を書けた場合、終了コードは、結果の不一致 `3`、インデックスまたはマイグレーションの作成失敗 `1`、候補の時間切れ `124`、比較不能 `4`、クエリまたは書き込み文の `--migration` の退行 `6`、`0` のうち一番重いものです。後片付けの失敗は `0` のときだけ `5` に置き換えます。そのため batch は、報告を書きながら `1`・`6`・`124` で終わることがあります。どれかは stdout で見分けます。

human 出力は候補の表、`Recommendation:`、クエリと候補の判定表を出し、`--migration` と `writes` があるときは `Writes` の節も出します。おすすめは、不一致・比較不能・`needs-check`（`--migration` では `needs_check` が `regressed` のクエリを数える）・時間切れがなく、改善が1件以上ある候補のうち、改善したクエリが最も多いものです。`mismatch`・`incomparable`・timeout・`regressed` の書き込み文があると、そのマイグレーションは `Recommendation:` になりません。variant だけで計測した `not-judged` の書き込み文は、推薦を妨げません。variant だけで計測した `not-judged` のクエリは、それだけではおすすめの条件を外しません。`Results` 表では、そのクエリの `result` 列が `variant-only`、`verdict` 列が `not-judged` になり、比較オブジェクト（JSON）の `result` は `baseline` を `null` にしたまま `incomparable` です。同じなら `bind_dependent_partial_index` 警告のない候補が先、次に容量の増分が小さい順、次に入力順（マニフェストの候補の後ろに提案）です。警告は判定・batch の件数・終了コードを変えません。human は判定表の後に `Warnings` の節を出し、候補ごとの警告を `<候補>: <code>: <message>` の形で（`no_analyze_stats` と `data_too_small`）、比較ごとの警告を `<クエリ> -> <候補>: <code>: <message>` の形で（`bind_dependent_partial_index`）1行ずつ示します。パスとインデックス名はほかの警告と同じ規則で制御文字を可視化し、パスは上で説明した短い表示を使います。batch のトップレベルの `warnings`（`--suggest` の警告と `unapplied_migrations`）はそのあとに `warning: <code>: <message>` の形で出します。`--format json` では [docs/json.md](../json.md) に書いた `batch_schema_version` 1 のオブジェクトを出します。

インデックスの作成・SELECT 1回・診断文1回は、それぞれ `--timeout-ms` の制限時間を持ちます。batch は全体で、データベースのコピー1回と、候補ループの前に全クエリの baseline SELECT を1回ずつ実行する分に加えて、候補ごとにインデックスの作成1回とクエリごとの SELECT 2回、さらに診断文（ANALYZE とサイズの警告に最大3つ、パラメータがあるクエリでは bind 依存の部分インデックス診断として計画1回・カタログ1回・使用インデックスごとに最大2文（テーブル名の取得と `PRAGMA index_list`））それぞれの制限時間までかかることがあります。`--show-binds` と `--show-rows` は各比較オブジェクトに適用します。

</details>

batch の報告を録画したものが2本あります。1本目は1本の SELECT と候補2本を比べます。列の順番が逆の複合インデックスは読んだ行数が変わらず（`200000 -> 200000`、`no-effect`）、`index.sql` は `101` 行を読むので `Recommendation` になります。

<img src="../demo-candidates.gif" width="1200" alt="qenome --d1 DEMO_DB --batch candidates.json で select.sql を複合インデックスと index.sql の2本と比べるターミナル。複合インデックスは読んだ行数 200000 -> 200000 の no-effect、index.sql は 200000 -> 101 の improved で、おすすめは index.sql">

2本目は `0002_reindex.sql` を適用します。このマイグレーションは `ix_events_customer_id` を落として、その代わりに複合インデックスを作ります。`select.sql` は `regressed`（`101 -> 200000`）、`failed.sql` は `improved`（`101 -> 35`）になり、実行は終了コード `6` で終わります。

<img src="../demo-migration.gif" width="1200" alt="qenome --d1 DEMO_DB --batch queries.json --migration 0002_reindex.sql で、variant のコピーにマイグレーションを適用するターミナル。select.sql は読んだ行数 101 -> 200000 の regressed、failed.sql は 101 -> 35 の improved で、シェルには exit=6 と出る">

どちらの録画も、`examples/d1-toml` のサンプルに `docs/demo` の入力を組み合わせています。

## インデックスの監査（--audit-indexes）

`qenome app.db --batch manifest.json --audit-indexes` は、マニフェストのクエリが使わなかった既存のインデックスと、先頭の列がほかのインデックスや主キーに覆われているインデックスを報告します。読み取り専用のコピー1つで全クエリの実行計画を取るだけで、variant を作らず、データベースも変更しません。マニフェストは `queries` だけでよく、`--record` が作ったマニフェストをそのまま使えます。`candidates` は無視します。

出力は3つの一覧です。

| 一覧 | 内容 |
| --- | --- |
| `Unused in this manifest` | どの実行計画にも名前が出なかったインデックス。部分インデックスには注記を付ける（別のバインド値では使われうるため） |
| `Redundant candidates` | キー列が、同じテーブルのほかのインデックスまたは主キーの先頭部分と、照合順序・ASC/DESC まで一致する通常のインデックス。`covered by` が覆っているインデックスの名前。`INTEGER PRIMARY KEY` は rowid の主キーを表す |
| `Kept for constraints` | UNIQUE と PRIMARY KEY のインデックス。削除候補にはしない |

同じインデックスが「未使用」と「冗長の候補」の両方に出ることがあります。キー列は `PRAGMA index_list` と `PRAGMA index_xinfo` から取ります。部分インデックスは冗長と判定せず、式インデックスは比較せず、照合順序や ASC/DESC が違うものは覆っているとみなしません。マニフェストの SELECT が `INDEXED BY` を使っているときは、そのクエリが強制するインデックスを指さないよう、冗長の一覧を判定しません。

このレポートは「このマニフェストでは使われなかった」という事実で、「削除してよい」という推薦ではありません。実行計画はマニフェストの SELECT だけを対象にするので、`UPDATE`・`DELETE`・外部キーの保守・マニフェスト外のクエリで使うインデックスはここには出ません。`ORDER BY` や `GROUP BY` のためだけに使うインデックスは計画に出るので、未使用にはなりません。SQLite がその実行で選ばなかったインデックスも、使えるインデックスであり続けます。

レポートを書けたときの終了コードは `0` です。一覧が空でなくても変わりません。`--d1` のときは JSON に `warnings` 配列が、human に `Warnings` の節が付き、`unapplied_migrations` を出します。一覧と終了コードは変わりません。インデックスは終了コードではなく stdout で見つけてください。`--audit-indexes` には `--batch` が必要で、`--suggest`・`--migration`・`--seed-data` とは併用できません。`--d1`、`--timeout-ms`（実行計画とカタログの読み取りごと）、`--format human`（既定）または `--format json` を使えます。JSON は [docs/json.md](../json.md) に書いた `audit_schema_version` 1 のオブジェクトです。

## 実際に実行されたクエリを記録する（--record）

人がマニフェストを書くと、ORM が組み立てたクエリを書き漏らしても気づけません。`qenome/d1` は、アプリがローカルの D1 に実際に発行した SELECT とバインド値を記録し、`--record` がその記録からマニフェストを作ります。使うのはローカルの開発とテストの間だけにしてください。

1. `qenome` を開発用の依存として入れます。

```sh
npm install -D qenome
```

1. テストまたは開発用の Worker エントリで、D1 のバインディングを `wrapD1` で包みます。アプリの変更はこの1行だけです。

```js
import { wrapD1 } from "qenome/d1";

export default {
  async fetch(request, env) {
    const db = wrapD1(env.DB);
    const { results } = await db
      .prepare("SELECT id FROM events WHERE customer_id = ?")
      .bind(1234)
      .all();
    return Response.json(results);
  },
};
```

1. アプリを動かし、出力を新しいファイルに残します。`umask 077` を付けると、記録した SQL とバインド値が他の利用者から読めません。

```sh
(umask 077; npx wrangler dev --local 2>&1 | tee qenome-record.log)
```

テストでも同じです。テストランナーが `console.log` の出力を表示する設定にしてください。

```sh
(umask 077; npx vitest run 2>&1 | tee qenome-record.log)
```

1. 記録からマニフェストを作ります。`--out` には存在しない新しいディレクトリを指定します。

```sh
npx qenome --record qenome-record.log --out qenome-manifest
```

`--out` の下に `manifest.json` と `queries/q001.sql` のような SQL ファイルができます。ディレクトリは `0700`、ファイルは `0600` で作り、stdout にはバインド値を出しません。`manifest.json` には実値が入るので commit しないでください。記録に使ったログも、マニフェストを作ったあとに削除してください。

1. 作ったマニフェストを比べるか、使っているインデックスを監査します。`queries` だけを持つので、`--suggest`・`--migration`・`--audit-indexes` と組み合わせます。

```sh
npx qenome --d1 DB --batch qenome-manifest/manifest.json --suggest
```

候補を自分で用意するときは、`manifest.json` に `candidates` を足してください。

`--record` の動き:

- 同じ SQL は1件にまとめます。文字列・コメントの外側の空白だけが違う SQL は同じとみなし、代表のバインド値は最初に実行された1組を使います。何回実行されたかは stdout に出ます。
- INSERT・UPDATE・DELETE・REPLACE はマニフェストに入れず、件数だけ出します。`exec` と、BLOB・真偽値・NUL を含むテキストのバインドを使う文も入れません（BLOB は `--bind` で表せないため）。スキップした理由と件数は `skipped:` の行に出ます。
- 異なる SELECT が100件を超える、マニフェストが 1 MiB を超える、SQL が 1 MiB を超える、記録が 16 MiB を超える場合は、`--out` を作る前に止まります。
- `--record` はデータベースを必要とせず、`--db`・`--d1`・`--batch`・`--migration`・`--suggest`・`--seed-data`・`--bind`・`--runs` などとは併用できません。`--format human`（既定）または `--format json` と、`--n-plus-one-threshold N` を使えます。

`--record` は、値だけ違う同じ「形」の文が何度も実行されたことも報告します。これは N+1 のパターンです。

```text
repeated shapes:
  queries/q002.sql  shape: 50 executions, 50 different values, longest run 50 (possible N+1; fetch the rows in one query with IN (...) or a JOIN, or send the statements with db.batch())
```

形は値ではなく文で決まります。`WHERE post_id = ?`・`= ?1`・`= :id`・`= 17`・`= 'a'` は 1 つの形、`IN (?, ?)` と `IN (?, ?, ?)` も 1 つの形で、列・テーブル・演算子が違えば別の形です。10 種類以上の値で実行された形を報告します。`--n-plus-one-threshold N` でその数を変えられ（2〜1,000,000）、`0` で報告を止めます。報告する形は最大 20 件で、値の種類が多い順、実行回数の多い順に並べ、何件を省いたかも出します。`INSERT` や `UPDATE` のループも書き込み向けのヒント付きで報告し、`db.batch()` の記録はすでに 1 往復なので閾値には数えません。報告する形がバッチでも実行されていた場合は、その件数（`20 batched`）を行に出します。`repeated shapes: none` は、閾値を超えた形がなかったという意味です。`--format json` では同じ内容を `record_schema_version` 1 の 1 オブジェクトで出し、`repeated_shapes` 配列に上記の値と `batched`・`previous_shape_example`・`manifest_select`（その形の `queries/qNNN.sql`）・`hint` が入ります。キーの一覧は [docs/json.md](../json.md) にあります。どちらの形式でもバインド値は出しません。

この報告は往復回数と繰り返し作業についてのヒントであり、計測ではありません。行数・実行時間・マニフェスト・終了コードは変わりません。

記録はローカルの開発とテストのためだけのものです。ラッパーは記録した SQL とバインド値をそのまま出力に書くので、本番の Worker には入れないでください。`withSession` と Durable Object の中の SQL は記録しません。

## 候補のインデックスを提案させる（--suggest）

`--suggest` は、SQLite の expert（同梱の SQLite ソースからビルドする sqlite3expert）に候補のインデックスを提案させ、その提案を同じ batch の仕組みで比べます。インデックスのファイルは要りません。

```sh
qenome app.db select.sql --suggest
qenome --d1 DB select.sql --suggest --bind 1:int:1234
qenome app.db --batch batch.json --suggest
```

SELECT ファイルを1本だけ渡したときは、その SELECT を batch のクエリ1件として扱い、`--bind` もそのクエリに適用します。`--batch` のときは、提案をマニフェストの候補の後ろに足します（`candidates` は省略しても空でもよい）。`--suggest` は `--runs`、`--format kv`、インデックスのファイルとは併用できません。

Qenome は baseline のコピーに2つ目の読み取り専用接続を開き、expert のサンプリングを `0` に設定します。そのため expert が利用者のデータベースから読むのはスキーマだけです。検査済みの全 SELECT を expert に渡します。expert を動かす前に、`sqlite_schema` の各行を検査します。各行は1文で、`CREATE TABLE`、`CREATE INDEX`、`CREATE UNIQUE INDEX`、`CREATE VIEW`、`CREATE TRIGGER`、`CREATE VIRTUAL TABLE` のいずれかで始まり、`expert` 仮想テーブルを使わないこと。これを満たさないデータベースは `suggest_schema_rejected`（終了コード `1`、stdout 空）で拒否し、マニフェストに候補があっても続けません。expert を動かしている間は、それが開く接続に一時的なガードを付けます。`ATTACH` と `DETACH` を拒否し、`index_list` と `index_xinfo` の PRAGMA だけを許し、接続できるデータベース数の上限を `0` にします。expert のオブジェクトを作ったあと、expert は自分の解析用コピーに独自の authorizer を設定しますが、接続できるデータベース数の上限はそこでも有効です。Qenome は expert を破棄したあとにガードを外します。ガードを設定できなければ、expert を呼ばずに止まります。これらで、細工されたスキーマがほかのデータベースファイルを作成・変更するのを防ぎます。レポートの `CREATE INDEX` は SQLite 自身の文の解析器で切り出します（引用符の中の `;` では切りません）。提案はマニフェストの候補と同じ検査を通し、落ちたものは `suggestion_rejected` の warning を付けて捨てます。ラベルは `suggested:1`、`suggested:2`… で、比べる提案は最大20件、マニフェストの候補と合わせて最大100件です。

出力は batch の報告です。`summary` の各候補に `source`（`manifest` / `suggested`）と `index_sql_text` が付き、トップレベルの `warnings` に、捨てたもの・できなかったことが入ります。比較単位の警告（`bind_dependent_partial_index` を含む）は各 `results[].comparison.warnings` に入り、トップレベルの `warnings` は `--suggest` 用のままです。human は候補単位の警告を候補名と、比較単位の警告をクエリと候補を添えて `Warnings` の節に出します。

| warning の `code` | 意味 |
| --- | --- |
| `suggest_query_skipped` | 1本の SELECT を SQLite が解析できなかった。ほかの SELECT は続ける |
| `suggestion_rejected` | 提案が `CREATE INDEX` の検査に落ちた |
| `suggestions_truncated` | 20件または100件の上限で、提案の後ろを捨てた |
| `no_suggestions` | SQLite の提案が0件だった。マニフェストの候補だけを比べた |
| `suggest_failed` | expert を開始・解析できなかった。マニフェストの候補だけを比べた |

比べる候補が1件も残らないときは、終了コード `1`・stdout 空・エラーコード `no_candidates` で止まります。提案は、終了コードとおすすめの判定では、マニフェストの候補と同じ重さで数えます。提案は出発点であり、判定ではありません。結果の行・読んだ行数・終了コードは、実際の比較から出ます。

`--suggest` は候補を探すときに使ってください。CI の判定には `--suggest` を付けず、名前を付けたインデックスを比べます。そうすれば SQLite の助言が変わってもビルドの結果は変わりません。batch の報告は `batch_schema_version` `1` のままで、`source`、`index_sql_text`、`warnings` は追加です。
