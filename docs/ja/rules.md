# 守るルール

- 元のデータベースを変更しない（読み取り専用で開く）。`--write` もサンドボックスのコピーだけで、ロールバックするトランザクションの中で実行する
- 比較できない結果を「一致」「成功」として報告しない
- 改善かどうかは読んだ行数で判定し、時間では判定しない。`improved` になるには baseline の読んだ行数の少なくとも 1% の減少が必要で、それより小さい減少は `no-effect` とする。書き込みは、読んだ行数が減っても書いた行数が増えれば `needs-check` とする
- 判定は [testdata/accuracy/](../../testdata/accuracy/) の既知の答えを持つコーパスで検査する。変更のたびに `python3 scripts/check_accuracy.py` を緑に保ち、新しい規則には事例を足す
- 容量はデータベース全体の増分であり、インデックス単体のサイズではない。`--migration` は使用中のバイト数を測るので、落としたインデックスの解放量が負の値で出る
- 複数文・`--write` 以外の書込・危険な DDL は拒否する。`--migration` のファイルだけは複数のインデックス変更とテーブル変更を許すが、`CREATE INDEX`・`CREATE UNIQUE INDEX`・`DROP INDEX`・`CREATE TABLE`（`AS SELECT` を除く）・`ALTER TABLE`（ADD / RENAME / DROP COLUMN と RENAME TO）に限る。データ変更・`DROP TABLE`・`ATTACH`・`PRAGMA`・その他の文は拒否する
- 正常・失敗・中断のどの経路でも、接続と一時ファイルを後片付けする
- D1 のデータベースファイルを推測しない。バインディングがちょうど1つのファイルに決まらないときは止まる
