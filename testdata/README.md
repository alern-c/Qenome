# テストデータ（工程1: ダミーDBと期待値表）

索引の効果を判定するためのダミーDBと、判定基準になる期待値の記録。工程3（計画表示）と工程5（結果比較）は、この表と突き合わせて「改善した／しなかった」を判定する。位置づけは [MVPタスク](../docs/mvp.md) の工程1を参照。

実データ、機密情報、実在の個人情報は含まない（`id` から決まる合成データだけ）。

## ファイル

| パス | 役割 |
|---|---|
| `schema.sql` | `events` テーブル（索引は作らない） |
| `seed.sql` | 20万行の決定論的な投入（`random()` を使わない） |
| `verify.sql` | 不変条件の検査（`sqlite3` CLI 専用） |
| `cases/improved.sql` / `cases/improved.index.sql` | 改善する例の SELECT と候補DDL |
| `cases/no-effect.sql` / `cases/no-effect.index.sql` | 効果のない例の SELECT と候補DDL |
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

`verify.sql` の検査項目: 行数、`id` の最小・最大・重複なし、`customer_id` の非NULL件数・NULL件数・種類数・最小・最大・範囲外0件、`status` 3値の件数と未知値0件、`note` のNULL件数・非NULL件数、ユーザー定義索引0件。

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
| ユーザー定義索引 | 0件 |
| DBサイズ（参考） | 1,242ページ・5,087,232 bytes（約4.85MiB、`page_size` は4096） |

DBサイズは版によって変わりうるため検査には含めず、参考値として記録する。ファイルのバイト一致も保証しない（判定は `verify.sql` の不変条件で行う）。

## 2組のクエリと候補DDL

| | 改善する例 | 効果のない例 |
|---|---|---|
| SELECT | `SELECT id, status, note FROM events WHERE customer_id = ?;` | `SELECT note FROM events WHERE lower(status) = ?;` |
| 代表バインド | 型 INTEGER・値 `1234` | 型 TEXT・値 `'ok'` |
| 候補DDL | `CREATE INDEX ix_events_customer_id ON events(customer_id);` | `CREATE INDEX ix_events_status ON events(status);` |
| 索引が効かない理由 | — | 条件の列を `lower()` で包むため、`status` の索引を使えない |

## 期待値表

代表バインドで実行した値。索引は `baseline`（索引なし）と `variant`（候補DDLを1本だけ適用）の差で見る。

### 改善する例

| 項目 | 索引なし（baseline） | 索引あり（variant） |
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

| 項目 | 索引なし（baseline） | 索引あり（variant） |
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

- 改善する例: 計画が `SEARCH` に変わり、フルスキャン行数が 0（または激減）になる。VMステップも大きく減る
- 効果のない例: 計画・フルスキャン行数・VMステップが索引なしと完全に一致する
- 時間（数値の正解は置かない。文案は工程6の測定設定と合わせて確定する）: 改善する例は索引ありの中央値が索引なしより小さく、反復しても順序が反転しない。効果のない例は両者の中央値の差が測定ノイズ帯（例: 索引なしの±20%以内）にある
- 計画・カウンタと時間が食い違った場合: 「要確認」と報告し、「改善」と判定しない

VMステップは実行形式で数ステップ変わる（改善する例の索引あり: 代表バインド 710 / リテラル 708）。上の表は代表バインドの値で揃えている。この差は関係条件には影響しない。

## 導出コマンド

期待値を再導出する手順。`sqlite3` は基準版を使う。

```sh
d=$(mktemp -d)
cp testdata/generated/qenome-fixture.db "$d/baseline.db"
cp testdata/generated/qenome-fixture.db "$d/improved.db"
cp testdata/generated/qenome-fixture.db "$d/no-effect.db"
sqlite3 "$d/improved.db" ".read testdata/cases/improved.index.sql"    # variant 側にだけ索引を足す
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
- 索引ありの側は `$d/improved.db` / `$d/no-effect.db` に読み替える
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

- **covering index**: 効果のない例の SELECT から `note` を外す（`SELECT status FROM events WHERE lower(status) = ?;`）と、索引ありの計画は `SCAN events USING COVERING INDEX ix_events_status` に変わる。改善していないのに計画が変わるため、SELECT を変えるときは期待値を再導出する
- **`ANALYZE` を入れない**: 統計が入ると計画が統計に依存するため、fixture では `ANALYZE` を実行しない
- **カウンタの取得**: `.stats stmt` の出力に結果行が混ざる。`Fullscan Steps` / `Virtual Machine Steps` の最後の値を採用する
- **版依存**: 期待値は基準版で導出した値。版が変わったら再導出する
- **バイト一致は保証しない**: DBファイルの内容のバイト一致は判定に使わない。`verify.sql` の不変条件で判定する
