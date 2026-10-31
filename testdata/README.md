# テストデータ（工程1: ダミーDBと期待値表）

インデックスの効果を判定するためのダミーDBと、判定基準になる期待値の記録。この表と突き合わせて「改善した／しなかった」を判定する。

実データ、機密情報、実在の個人情報は含まない（`id` から決まる合成データだけ）。

## ファイル

| パス | 役割 |
|---|---|
| `schema.sql` | `events` テーブル（インデックスは作らない） |
| `seed.sql` | 20万行の決定論的な投入（`random()` を使わない） |
| `verify.sql` | 不変条件の検査（`sqlite3` CLI 専用） |
| `seed.json` | `--seed-data` 用の50,000行のダミーデータ指定（CONTRIBUTING.md の Quick start で使う。fixture DB は変更しない） |
| `cases/improved.sql` / `cases/improved.index.sql` | 改善する例の SELECT と候補DDL |
| `cases/write.sql` | `--write` の例の INSERT（`cases/improved.index.sql` を候補に使う） |
| `cases/no-effect.sql` / `cases/no-effect.index.sql` | 効果のない例の SELECT と候補DDL |
| `cases/incomparable.sql` / `cases/incomparable.index.sql` | 結果を比較できない例の SELECT と候補DDL |
| `generated/` | 生成したDBの置き場（`.gitignore` 対象。追跡しない） |

## 再生成手順

`schema.sql` → `seed.sql` → `verify.sql` の順に実行する。`seed` の投入は約0.08秒で、検査まで含めても1秒未満（2026-10-10、macOS・SQLite 3.51.2）。macOS の `sh` / `zsh` で確認済み。Windows は未確認。

```sh
mkdir -p testdata/generated
rm -f testdata/generated/qenome-fixture.db
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/schema.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/seed.sql"
sqlite3 testdata/generated/qenome-fixture.db ".read testdata/verify.sql"
```

- 先頭の `mkdir` は必須。ディレクトリが無いと `sqlite3` は `unable to open database file` で exit 1 になり、DBも作られない
- `verify.sql` は17項目を出力する。すべて `ok` なら exit 0、1つでも `FAIL` があれば最後の `INSERT` が `CHECK` 制約違反となり exit 1（実測: `Runtime error near line 32: CHECK constraint failed: ok = 1 (19)`）
- 途中で失敗したら、部分生成されたDBを削除して先頭からやり直す（中途半端なDBを残さない）。削除して再実行できることは確認済み
- 検査で `FAIL` が出たら期待値を書き換えず、まず原因を調べる（記録どおりにならない状態を成功として扱わない）
- この手順を2回実行し、検査の出力が完全に一致することを確認済み（2026-10-10）

`verify.sql` の検査項目: 行数、`id` の最小・最大・重複なし、`customer_id` の非NULL件数・NULL件数・種類数・最小・最大・範囲外0件、`status` 3値の件数と未知値0件、`note` のNULL件数・非NULL件数、ユーザー定義インデックス0件。

`seed.json` は CONTRIBUTING.md の Quick start の `--seed-data` の例で使う。サンドボックスのコピーにある `events` を、`id` と `customer_id` が 1..50,000 の連番、`status` が `ok` 50% / `failed` 50%、`note` が NULL の50,000行で置き換える。`fixture DB` は変更しない。

## 基準版

期待値は次の版で導出した。`testdata/generated` を作る版と揃える。

```text
sqlite3 3.51.2 2026-01-09 17:27:48 b270f8339eb13b504d0b2ba154ebca966b7dde08e40c3ed7d559749818cbalt1 (64-bit)
```

計画の文言とフルスキャン行数は 3.51.0 / 3.53.4 でも同じ値を確認済み。**版が変わったら期待値を再導出する。**

## データの条件（`verify.sql` が検査する値）

| 条件 | 値 |
|---|---|
| 行数 | 200,000 |
| `id` | 1..200,000 の連番（重複なし） |
| `customer_id` | 1..2,000 を巡回。`id%997 = 0` の200行は NULL |
| `status` | `ok` 66,666 / `warn` 66,667 / `failed` 66,667（`id%3` で決まる） |
| `note` | `'note-'||id`。`id%5 = 0` の40,000行は NULL |
| ユーザー定義インデックス | 0件 |
| DBサイズ（参考） | 1,242ページ・5,087,232 bytes（約4.85MiB、`page_size` は4096） |

DBサイズは版によって変わりうるため検査には含めず、参考値として記録する。ファイルのバイト一致も保証しない（判定は `verify.sql` の不変条件で行う）。

## 3組のクエリと候補DDL

| | 改善する例 | 効果のない例 |
|---|---|---|
| SELECT | `SELECT id, status, note FROM events WHERE customer_id = ?;` | `SELECT note FROM events WHERE lower(status) = ?;` |
| 代表バインド | 型 INTEGER・値 `1234` | 型 TEXT・値 `'ok'` |
| 候補DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` | `CREATE INDEX ix_events_status ON events(status);` |
| インデックスが効かない理由 | — | 条件の列を `lower()` で包むため、`status` のインデックスを使えない |

### 比較できない例

| 項目 | 値 |
|---|---|
| SELECT | `SELECT id, note FROM events ORDER BY random() LIMIT 10;` |
| 代表バインド | なし |
| 候補DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` |
| 比較できない理由 | `random()` が実行のたびに別の行を選ぶ（`src/db.zig` の `alwaysIncomparable`） |
| 結果 | `result: incomparable`、終了コード 4、`verdict: not-judged`。SELECT は計測しない |

この組は CONTRIBUTING.md の Quick start で使う。候補DDL は比較の対象としては使われないため、改善する例と同じものを使っている。

### 書き込みの例

| 項目 | 値 |
| --- | --- |
| ファイル | `cases/write.sql` |
| SQL | `INSERT INTO events(customer_id, status, note) VALUES (?, 'ok', 'new');` |
| 代表バインド | 型 INTEGER・値 `1234` |
| 候補DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);`（改善する例と同じ） |
| 期待する書く行数 | baseline 1（テーブル1行）、variant 2（テーブル1行 + 候補インデックスの挿入1行） |
| 期待する変更行数 | 両方 1 |
| 結果 | `result: match`、`verdict: needs-check`、終了コード 0 |
| 期待する読む行数 | 両方 0（INSERT ... VALUES は行を読まない） |

`--write` は文をサンドボックスの各コピーで実行し、トランザクションをロールバックするので、元の DB は変わらない。書く行数は workerd の行数カウントで、テーブルの行とセカンダリインデックスの挿入、トリガーの挿入、外部キーの CASCADE を含む。セカンダリインデックスの削除は含まないため、`DELETE` では書く行数が増えないことがある。`DELETE ... WHERE` の読む行数がインデックスで減ることは、`src/cli/tests.zig` の統合テストで確認する。

## 期待値表

代表バインドで実行した値。インデックスは `baseline`（インデックスなし）と `variant`（候補DDLを1本だけ適用）の差で見る。

### 改善する例

| 項目 | インデックスなし（baseline） | インデックスあり（variant） |
|---|---|---|
| 計画 | `SCAN events` | `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` |
| フルスキャン行数 | 199,999 | 0 |
| VMステップ | 600,407 | 710 |
| 件数 | 100 | 100 |
| `count(customer_id)` / `count(note)` | 100 / 100 | 100 / 100 |
| `sum(id)` / `sum(customer_id)` | 10,023,300 / 123,400 | 同左 |
| `sum(length(note))` | 1,045 | 1,045 |
| `min(id)` / `max(id)` | 1,233 / 199,233 | 同左 |
| 結果の比較（工程5） | — | 一致（`result: match (row multiset)`、終了コード 0、`row-order: same`） |

### 効果のない例

| 項目 | インデックスなし（baseline） | インデックスあり（variant） |
|---|---|---|
| 計画 | `SCAN events` | `SCAN events`（完全一致） |
| フルスキャン行数 | 199,999 | 199,999 |
| VMステップ | 933,339 | 933,339 |
| 件数 | 66,666 | 66,666 |
| `count(note)` | 53,333 | 53,333 |
| `sum(length(note))` | 557,032 | 557,032 |
| `min(note)` / `max(note)` | `note-100002` / `note-99999` | 同左 |
| 結果の比較（工程5） | — | 一致（`result: match (row multiset)`、終了コード 0、`row-order: same`） |

### 判定条件

判定の主軸は数値の絶対値ではなく、次の関係条件にする。

- 改善する例: 結果が一致し、読んだ行数（`rows-read`）がインデックスなしより減る。計画も `SEARCH` に変わる
- 効果のない例: 結果が一致し、読んだ行数・書いた行数がインデックスなしと一致する。計画・フルスキャン行数・VMステップも一致する
- 時間（数値の正解は置かない。判定には使わず、`time-baseline-ns` / `time-variant-ns` に参考値として出す）: 改善する例はインデックスありの中央値が小さく、反復しても順序が反転しない。効果のない例は両者の中央値の差が測定ノイズ帯（例: インデックスなしの±20%以内）にある
- 読んだ行数が減らない場合: 時間が短くても「改善」と判定しない

VMステップは実行形式で数ステップ変わる（改善する例のインデックスあり: 代表バインド 710 / リテラル 708）。上の表は代表バインドの値で揃えている。この差は関係条件には影響しない。

## 導出コマンド

期待値を再導出する手順。`sqlite3` は基準版を使う。

```sh
d=$(mktemp -d)
cp testdata/generated/qenome-fixture.db "$d/baseline.db"
cp testdata/generated/qenome-fixture.db "$d/improved.db"
cp testdata/generated/qenome-fixture.db "$d/no-effect.db"
sqlite3 "$d/improved.db" ".read testdata/cases/improved.index.sql"    # variant 側にだけインデックスを足す
sqlite3 "$d/no-effect.db" ".read testdata/cases/no-effect.index.sql"
```

計画とカウンタ（改善する例。`1234` は代表バインド）:

```sh
sqlite3 "$d/baseline.db" <<'SQL'
.parameter set ?1 1234
.stats stmt
EXPLAIN QUERY PLAN SELECT id, status, note FROM events WHERE customer_id = ?;
SELECT id, status, note FROM events WHERE customer_id = ?;
SQL
```

- 計画は `EXPLAIN QUERY PLAN` の出力から `SCAN` / `SEARCH` の行を読む
- カウンタは `.stats stmt` の `Fullscan Steps` と `Virtual Machine Steps` の**最後の値**を読む。出力に結果行が混ざるため（効果のない例は66,666行出力される）
- インデックスありの側は `$d/improved.db` / `$d/no-effect.db` に読み替える
- 効果のない例は `.parameter set ?1 ok` とし、`SELECT note FROM events WHERE lower(status) = ?;` に差し替える

結果の要約（改善する例）:

```sh
sqlite3 "$d/baseline.db" "SELECT count(*), count(customer_id), count(note), sum(id), sum(customer_id), sum(length(note)), min(id), max(id) FROM events WHERE customer_id = 1234;"
```

結果の要約（効果のない例）:

```sh
sqlite3 "$d/baseline.db" "SELECT count(*), count(note), sum(length(note)), min(note), max(note) FROM events WHERE lower(status) = 'ok';"
```

要約は期待値の確認用。工程5の結果一致判定（値の型・NULL・重複行数を保った行の多重集合の比較）を代替しない。要約が同じでも中身が異なる結果はあり得る。

## 罠

- **covering index**: 効果のない例の SELECT から `note` を外す（`SELECT status FROM events WHERE lower(status) = ?;`）と、インデックスありの計画は `SCAN events USING COVERING INDEX ix_events_status` に変わる。改善していないのに計画が変わるため、SELECT を変えるときは期待値を再導出する
- **`ANALYZE` を入れない**: 統計が入ると計画が統計に依存するため、fixture では `ANALYZE` を実行しない
- **カウンタの取得**: `.stats stmt` の出力に結果行が混ざる。`Fullscan Steps` / `Virtual Machine Steps` の最後の値を採用する
- **版依存**: 期待値は基準版で導出した値。版が変わったら再導出する
- **バイト一致は保証しない**: DBファイルの内容のバイト一致は判定に使わない。`verify.sql` の不変条件で判定する
- **`LIMIT` だけでは比較不能にならない**: `LIMIT` / `OFFSET` を含む SELECT も、行が一致すれば `match` のまま比較と計測を続ける（`LIMIT` / `OFFSET` は行が不一致だったときの理由にだけ現れる）。比較不能になるのは `random()` などの非決定的な関数や schema テーブルを読む SELECT（`src/db.zig` の `alwaysIncomparable`）

## Accuracy corpus (`testdata/accuracy/`)

`testdata/accuracy/` holds known-answer cases for the verdict. `scripts/check_accuracy.py` builds a fresh database for each case in a temporary directory, runs `zig-out/bin/qenome --format json`, and compares the JSON with the answer in `case.json`. It runs each case several times (`--repeat N`, default 3) and fails when the exit status, the report `exit_code`, `result`, `verdict`, `plan_changed`, a plan step detail, or a counter differs between the runs. Every comparison in a batch report is checked, and a batch report also has its `recommended` and summary counts compared. Timing is not compared unless a case opts in with `"timing": "stable"`, and a case checks the timing effect only with `effect`.

One directory per case, `testdata/accuracy/<case>/`:

| Path | Role |
| --- | --- |
| `schema.sql` | Tables and existing indexes; the harness applies it to a new database |
| `data.sql` | Optional deterministic rows and `ANALYZE`; the harness applies it with Python's `sqlite3` module |
| `seed.json` | Optional `--seed-data` spec instead of `data.sql`; the harness passes it to qenome |
| `select.sql` or `write.sql` | The statement to compare |
| `index.sql` | The candidate index for one comparison or `--write` |
| `batch.json` | A `--batch` manifest; a batch case has no `index.sql` |
| `migration.sql` | A migration applied on the variant with `--batch`; a manifest here must omit `candidates` |
| `case.json` | `description`, `args` and `expect`; `known_wrong` and `timing` are optional |

No database file is committed. The harness infers the mode from the files: a `batch.json` means `--batch` (with `--migration` when `migration.sql` exists), a `write.sql` means `--write`, `--suggest` in `args` means one SELECT without `index.sql`, and anything else is one SELECT with `index.sql`. `args` holds only extra qenome options such as `--bind`; the harness adds `--format json` and `--runs 0` (the last one is skipped for a batch, `--suggest`, or a case with `--runs`). A case with `--runs` needs `"timing": "stable"`, and a timing case needs at least 6 rounds.

`expect` keys (an unknown key is an error):

- `exit` (the process status) and `exit_code` (the same field in the JSON report).
- `result` (`match`, `mismatch`, `incomparable`), `verdict`, and `plan_changed`.
- `baseline_plan` / `variant_plan`: `contains` and `excludes` substrings of a plan step `detail`.
- `rows_read` / `rows_written`: `decrease`, `same`, or `increase`, or an object with `direction` and an optional `max_ratio` (the upper bound of variant / baseline).
- `effect`: the timing `effect` of every run, as one value or an array of allowed values from `faster`, `slower`, `no-difference`, and `insufficient-samples`; it needs `"timing": "stable"`.
- `warnings`: warning `code`s that must be in `contains` or `excludes`.
- `human`: `contains` / `excludes` substrings of the `--format human` report. The harness runs that report once, after the JSON runs, so a case can require that the human report shows a warning next to the verdict.
- `batch`: `recommended` and `counts` for `summary[0]` (`improved`, `no_effect`, `needs_check`, `mismatch`, `incomparable`, `timeout`, `not_judged`).
- `suggest`: `recommended` (true or false) and `leads_with` (the leading columns of the recommended index).
- `error`: the `code` of the error object on stderr, for a run that stops before the report.

For one comparison the report itself is the comparison object; for `--batch`, `--migration`, and `--suggest` it is `results[0].comparison`, so a case that checks the comparison holds exactly one result. Run the corpus with `python3 scripts/check_accuracy.py [--case NAME] [--repeat N] [--binary PATH]`.

After the per-case lines the run prints one summary line: the number of cases per expected `verdict` and per expected `result` (`unstated` counts the cases that expect neither), then one line for every case that expects a verdict other than `improved` and got `improved`. Such a case fails the run, including a `known_wrong` case, whose marker records the wrong answer but must not hide it: those cases are listed on their own line with their issue link.

### Case groups

The cases fall into three groups, and each directory is named after the trap it tests.

| Group | What the case protects | Added later |
| --- | --- | --- |
| not improved | the rows match and the variant reads the same rows, so the answer is `no-effect`: an index SQLite does not use, a plan whose text changed without changing the rows read, and an unused index that the timing must never call `faster` | `unused-column-index`, `nocase-index-binary-comparison`, `covering-index-same-rows`, `timing-same-plan` |
| needs review | the rows match but the change costs something: the verdict is `needs-check` when the variant reads or writes more rows, and the warnings must reach the human report next to the verdict | `stale-stats-reads-more`, `insert-index-writes`, `update-indexed-column-writes-more`, `one-row-gain-of-50000`, the same query and index that answer `improved` for one bind and `no-effect` for another (`bind-range-one-row`, `bind-range-every-row`), and the human checks in `small-data` and `no-analyze-stats` |
| results differ | the rows must stay the same where the candidate can only change the plan, and a case where they can differ expects exit `3` or `4` with `verdict` `not-judged`, never `improved` | `nocase-index-match`, `partial-index-range-match`, `order-by-ties-limit` |

To add a case, create the directory with the files above, put the explanation in `description` (the SQL files must not hold comments), and run `python3 scripts/check_accuracy.py --case <case>`. Decide the expected answer from SQLite's documented behaviour and from the baseline and variant plans, not from what the binary prints today. When the binary is wrong, keep the right expectation and mark the case `"known_wrong": "<issue link>"` with a new issue: the harness reports it as `known-wrong` instead of `ok`, and fails once the case starts passing so that the marker gets removed. A change to the verdict rule belongs in its own issue, not in a corpus case. When the expectation deliberately records today's answer while a human decides (as in `one-row-gain-of-50000`), name that issue in `description`. The corpus depends only on the JSON contracts in `docs/json.md` (comparison `schema_version` 2, `batch_schema_version` 1); a new SQLite version can change a plan text or a counter, so recheck the expected values then.

`rows_read` counts the rows a b-tree cursor visits: a full scan visits every row, and an index search visits its matching entries plus one, so one search cannot read more rows than a full scan. Sorter reads count too, so an index that removes an `ORDER BY` sort also lowers the counter. A `needs-check` from one SELECT therefore needs a baseline that already reads fewer rows than the table: `stale-stats-reads-more` writes a `sqlite_stat1` row that makes the planner prefer the candidate index over a better existing one. A write reaches `needs-check` through `rows_written` instead (`insert-index-writes`, `update-indexed-column-writes-more`). A bind decides the direction of one search: `bind-range-one-row` matches one row and reads one, while the same query and index in `bind-range-every-row` matches every row and reads every entry, so the first is `improved` and the second is `no-effect`.

A `mismatch` needs a query whose rows SQL itself leaves open: `group-by-bare-column` uses a bare column beside `GROUP BY`, where the index changes the row SQLite picks. A `LIMIT` query whose rows differ is `incomparable` (exit `4`) instead, because the plan can pick other rows: `order-by-ties-limit` orders by a non-unique column and cuts through tied rows, so the two copies return different rows. A collation does not change the rows on the same data (`nocase-index-match` shows the NOCASE index search returning the same rows); it only decides whether the index can be used, because a NOCASE index does not serve the default BINARY comparison (`nocase-index-binary-comparison`).
