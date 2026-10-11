# 開発と検証

[概要](overview.md) · [MVPタスク](mvp.md) · [設計条件](design.md)

## 現状と原資料

2026-10-10にmainブランチを確認した。src/main.zigとsrc/root.zigは初期サンプル。この整理ではコード実装、commit、pushを行っていない。

2026-10-11時点：工程2（入力と読取制限）の実装をmainへ取り込み済み（単位1〜4。2026-10-11時点のmainは `0d7e632`）。`src/main.zig` は `src/cli.zig` のCLIへ接続し、`src/root.zig` は `cli` / `db` / `sqlite` を再エクスポートする。同梱SQLite（3.51.2）でDBを読み取り専用に開き、SELECT 1文・型付きバインド・候補CREATE INDEXの検証と、時間上限・Ctrl+Cによる中断までを実装した。

原資料はリポジトリ外のローカルノートで、この文書はその内容を整理したもの。

原資料の「全項目未チェック」という説明と工程0の完了チェックには差がある。工程0は原資料のチェック状態を記録し、今回の実行確認とは区別した。実装済みの判定にはソースと実行結果を使う。

## 環境と既存手順

[build.zig.zon](../build.zig.zon)のminimum_zig_versionは0.17.0。[build.zig](../build.zig)にbuild、run、testの手順がある。[品質チェック設定](../.github/workflows/quality.yml)は版の一致、整形、build、testを検査する。CIの実測（2026-10-11にGitHub APIで再確認。runの開始から完了まで）は、PR #2が44秒、PR #1が143秒、PR #2のマージ後のmain pushが127秒で、いずれも10分枠（`timeout-minutes: 10`）に十分収まる。

既存の確認コマンドは `zig version`、`zig build --summary all`、`zig build run`、`zig build test --summary all`、`zig fmt --check .`。SQLite比較CLIは `--help` で使い方と終了コードを確認できる（終了コード0）。

```sh
zig build run -- --help
zig build run -- --db <DB> --select <SELECTファイル> --index-sql <候補DDLファイル> --bind 1:int:1234
```

### 同梱SQLite

- 使う版は3.51.2。[src/sqlite.zig](../src/sqlite.zig)の `pinned_version` と一致することをテストで確認する。取得元のURL、公式公開SHA3-256、source id、同梱2ファイルのハッシュ、コンパイルフラグは [vendor/sqlite3/PROVENANCE.txt](../vendor/sqlite3/PROVENANCE.txt) に記録する
- `vendor/sqlite3/sqlite3.c` / `sqlite3.h` は `build.zig` の `Qenome` モジュール1か所にだけ登録し、実行ファイルと2つのテストが同じ定義を共有する（二重定義を避ける。Cソースのコンパイルは各アーティファクトのビルドで行われる）。システムの `libsqlite3` や `sqlite3` CLIには依存しない
- CIに追加パッケージは不要。`quality.yml` の手順は `mlugg/setup-zig`、Zigの版の一致確認、整形、build、testだけで、パッケージ導入のステップがない（同梱SQLiteのCソースはZigがコンパイルする）

### 工程0の実行確認（2026-10-10、Zig 0.17.0）

同じworktreeで実行した。コマンド実行の前後で `git status --short` は未追跡の作業ファイル4件（task.md、report.md、plan.md、TODO.md）のみで、追跡ファイルの差分は無かった（追跡ファイルの差分はこの記録の追記だけ）。`build.zig`、`build.zig.zon`、`src/*` は既存のまま使い、`zig init` による再初期化はしていない。

- `zig version`：`0.17.0`（`build.zig.zon` の宣言と一致）
- `zig fmt --check .`：出力なし・終了コード0
- `zig build --summary all`：`Build Summary: 3/3 steps succeeded`
- `zig build run`：終了コード0。stdoutは「Run `zig build test` to run the tests.」、stderrは「All your codebase are belong to us.」と「info: arg: ./zig-out/bin/Qenome」。後者は `src/main.zig` の `std.log.info` による引数表示
- `zig build test --summary all`：`Build Summary: 5/5 steps succeeded`

1回目のbuild、run、testはビルドキャッシュが温まっていたため、`--cache-dir /tmp/qenome-cold-cache` で局所キャッシュを作り直して再確認した。`compile exe Qenome debug native success 1s`、`zig build test` は `5/5 steps succeeded; 3/3 tests passed` となり、初回ビルドでも成功する。`build.zig.zon` の依存はすべて例示のコメントで、ネットワーク取得は発生しない。

未確認：Zigの版を固定するツールチェーン設定は無く、`zig version` が0.17.0であることは実行環境に依存する。0.17.0以外の版での挙動は未確認。

### 工程2の実行確認（2026-10-11、Zig 0.17.0・同梱SQLite 3.51.2）

フィクスチャは [testdata/README.md](../testdata/README.md) の手順で生成した（SQLite CLI 3.51.2、`verify.sql` は17項目すべて `ok`、終了コード0）。生成した `testdata/generated/` は追跡しない。

リポジトリ外に置いたSQLファイル（書込SQL、複数文、重いSELECT）と実バイナリ `zig-out/bin/Qenome` で、次を確認した。改善する例・効果のない例のSELECTと候補DDLは `testdata/cases/` のものを使った。

| 実行 | 終了コード | 出力 |
| --- | --- | --- |
| 改善する例（`--bind 1:int:1234`） | 0 | stdoutに `rows: 100`。stderrなし |
| 効果のない例（`--bind 1:text:ok`） | 0 | stdoutに `rows: 66666`。stderrなし |
| 書込SQL（`INSERT`） | 1 | stderrに `error: --select: the statement is not allowed here: not authorized` |
| 複数文（`SELECT 1; SELECT 2;`） | 1 | stderrに `error: --select: the file must hold exactly one statement` |
| バインド不足（1つも与えない）・重複（`?1` へ2つ） | 1 | stderrに `error: --bind: ...` |
| 候補DDLがCREATE INDEXでない | 1 | stderrに `error: --index-sql: the statement is not allowed here: not authorized` |
| 重いSELECT（fixtureのクロス結合）＋ `--timeout-ms 50` | 124（実測89ms） | stderrに `error: --select exceeded the time limit of 50 ms` |
| 同じ重いSELECT＋SIGINT（開始約1秒後に `kill -INT`） | 130 | stderrに `error: interrupted by SIGINT` |

実行の前後で `testdata/generated/qenome-fixture.db` のSHA-256は `ddca8dd288e9a1fee22e441e51064362c19a9d2646bd990f940b700c7bf87d39` のまま変わらず、`testdata/generated` に `-journal` / `-wal` / `-shm` は残らなかった。

未確認：時間上限はSELECTの実行中だけ効き、prepare段階は対象外。WAL構成のDBの読み取りは工程4で扱う。Windowsは未対応（シグナル処理がPOSIXのみ）。

### 工程3の計画表示と実行確認（2026-10-11、Zig 0.17.0・同梱SQLite 3.51.2）

受け付けたSELECTの実行後、stdoutの `index-sql:` と `rows:` の間に `measured-on: db (candidate index not applied)` を出す。`rows`・`plan:`・カウンタはすべて `--db` に指定したDBそのもので測ったもので、候補CREATE INDEXは検査しただけで適用していない、という意味（DBにもともと索引が入っていても同じ表示）。続けて `rows:` の後に次を出す。

- `sqlite:` / `sqlite-source-id:`：実行時の `sqlite3_libversion()` / `sqlite3_sourceid()`
- `plan:`：`EXPLAIN QUERY PLAN` の各行。`id` / `parent` と目安のラベル（`kind` = scan / search / temp_btree / other、`covering`、`automatic`）、行末にSQLiteの文言そのもの（`detail=`）
- `fullscan-steps:` / `vm-steps:` / `sort-ops:` / `autoindex-rows:`：実行に使ったstatementの `sqlite3_stmt_status`（`SQLITE_STMTSTATUS_FULLSCAN_STEP` / `VM_STEP` / `SORT` / `AUTOINDEX`）

計画は、同じSQLと同じバインドで別に用意したstatementに `sqlite3_stmt_explain(S, 2)` をかけて読む。実行用statementを切り替えると計画用の命令がプログラムに残り、VMステップが増えるため（実測で11,705→11,807）。ラベルは文言の先頭語と `USING` 以降から付ける目安で、EQPの文言は安定APIではない。判定にはカウンタを主に使い、版を上げたら分類テストと下表を再確認する。計画が読めなければ終了コード1でstdoutは空。時間切れ・SIGINTでは計画もカウンタも出さない。

参照資料：sqlite.org の「EXPLAIN QUERY PLAN」説明、`vendor/sqlite3/sqlite3.h` の `sqlite3_stmt_explain` と `sqlite3_stmt_status` / `SQLITE_STMTSTATUS_*` の説明。

[testdata/README.md](../testdata/README.md) の手順でfixtureを作り（SHA-256は工程2と同じ `ddca8dd2…`）、実バイナリで確認した。索引ありは、一時コピーに `testdata/cases/*.index.sql` を適用したDB。

| 実行 | 計画（kind / detail） | fullscan-steps | vm-steps | rows |
| --- | --- | --- | --- | --- |
| 改善する例・索引なし（`--bind 1:int:1234`） | scan / `SCAN events` | 199,999 | 600,407 | 100 |
| 改善する例・索引あり | search / `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)` | 0 | 710 | 100 |
| 効果のない例・索引なし（`--bind 1:text:ok`） | scan / `SCAN events` | 199,999 | 933,339 | 66,666 |
| 効果のない例・索引あり | scan / `SCAN events` | 199,999 | 933,339 | 66,666 |

いずれも終了コード0で、README の期待値表と一致した。重いSELECTに `--timeout-ms 50` を付けた実行は終了コード124・stdout 0バイト。実行の前後でfixtureのSHA-256は変わらず、`-journal` / `-wal` / `-shm` は残らなかった。

未確認：計画を読めないときの終了コード1の分岐（再現が難しくテストなし）。窓関数・仮想テーブル・トリガー関連のEQP文言の分類。計画の取得と実行の間に外部プロセスが元DBのスキーマや統計を変えると、表示した計画と実行計画が食い違いうる（工程4のsnapshotで解消予定）。

### 工程4の整合コピーと実行確認（2026-10-11、Zig 0.17.0・同梱SQLite 3.51.2）

工程4から、SELECTの検証・計画・実行は元DBではなく、一時フォルダに作ったsnapshot（baseline）で行う。stdoutの `measured-on:` は `baseline (candidate index not applied)` になり、`db:` には `--db` に指定したパスをそのまま出す。

処理の順番は次のとおり。

1. `$TMPDIR`（未設定・空なら `/tmp`）の下に `qenome-<乱数24桁>` を権限0700で作る。同じ名前がすでにあれば、別の乱数で作り直す。
2. 元DBを読み取り専用で開き、`sqlite3_backup_step(-1)` を1回だけ呼んで `baseline.db` に写す。1回の呼び出しは1つの読み取りトランザクションの中で全ページを写すので、WALのうちcheckpointされていない確定分も含めて、ある1時点のsnapshotになる。
3. baseline の `journal_mode` を DELETE に戻して閉じる。1ページ目はそのまま写るので、元DBがWALなら baseline もWALになっていて、工程5の索引作成が `-wal` 側に入ってしまうため。
4. 閉じた baseline を通常のファイルコピーで `variant.db` にする（工程5で使う）。
5. 終わり方にかかわらず、すべての接続を閉じてから一時フォルダごと削除する。

元DBへの接続には `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` を設定し、close 時に元DBへcheckpointが走らないようにする。元DBがbusyのときは待たずに終了コード1にする。

終了コードの一覧：

| 終了コード | 意味 |
| --- | --- |
| 0 | 受け付けて実行した |
| 1 | 入力の拒否（ファイル、DB、snapshot、一時フォルダ、SQL、DDL、バインド、計画、実行） |
| 2 | 引数を使えない |
| 5 | 本来は成功した実行の後片付け（接続のclose、一時フォルダの削除）に失敗した。1/124/129/130/143 のときは元のコードを保つ。どちらの場合も残ったパスをstderrに出す |
| 124 | 時間上限 |
| 129 / 130 / 143 | SIGHUP / SIGINT / SIGTERM で中断した。stderrにシグナル名を出す。続けて別のシグナルを受けても、最初に受けたものを採る |

#### 利用条件と制約

- **WALのDBの付属ファイル**：読み取り専用で開いても、SQLiteは元DBの横に `-shm` と `-wal` を作る（すでにある場合も、`-shm` の中身は書き換わりうる）。本体ファイルの中身は変えない。「元DBを変更しない」は、本体の中身を変えないことを指す（D-001）。
- **外部writerがいる場合**：WALのDBなら、外部writerを止めずにcopy開始時点のsnapshotを取れる。ただしcopyの間は、外部側のcheckpointがcopy開始時点より先へ進めない（`-wal` が大きくなり、RESTART/TRUNCATE checkpointは待たされるか、BUSYになる）。通常方式（rollback journal）のDBでは、copyの間ずっと外部writerのコミットを待たせる（相手に待ち時間の設定がなければ、相手側が `SQLITE_BUSY` になる）（D-002）。
- **中断のタイミング**：copy（`backup_step(-1)`）は途中で止められない。SIGINT・SIGTERM・SIGHUP はcopyが終わった時点で反映し、後片付けをしてから終了する。時間上限はSELECTの実行中だけに効き、copyには効かない。SQLの誤りも、copyが終わった後で見つかる。
- **強制終了**：`kill -9` や、猶予の後にSIGKILLを送る仕組み（docker・systemdなど）で止めると、一時フォルダが残る（大きなDBではcopyが猶予より長くかかりうる）。中身は元DBのコピーなので、`$TMPDIR/qenome-*` を手で消す。自動の掃除はしない。
- **一時領域**：元DBの約2倍の空き容量が必要。`$TMPDIR` がメモリ上（Linuxのtmpfsなど）にあると、ディスクI/Oが実DBと違うので、時間の前提が崩れる。工程6では測定先のファイルシステムも記録する候補にする。
- **hot journal**：通常方式のDBに、クラッシュしたwriterのhot journalが残っている場合、読み取り専用では元に戻せないので終了コード1になる。

#### 実行確認

[testdata/README.md](../testdata/README.md) の手順で作ったfixture（SHA-256は工程2と同じ `ddca8dd2…`）と実バイナリで、`TMPDIR` を作業用の空フォルダにして確認した。各実行の後、そのフォルダは空だった。

| 実行 | 終了コード | 出力 |
| --- | --- | --- |
| 改善する例（`--bind 1:int:1234`） | 0 | `measured-on: baseline …`、`rows: 100`、`SCAN events`、fullscan-steps 199,999、vm-steps 600,407（工程3と同じ） |
| 効果のない例（`--bind 1:text:ok`） | 0 | `rows: 66666`、fullscan-steps 199,999、vm-steps 933,339（工程3と同じ） |
| 書込SQL | 1 | `error: --select: the statement is not allowed here: not authorized` |
| 重いSELECT＋`--timeout-ms 50` | 124 | 約0.07秒、stdout 0バイト |
| 重いSELECT＋開始約1秒後に SIGINT / SIGTERM / SIGHUP | 130 / 143 / 129 | `error: interrupted by SIGINT` / `SIGTERM` / `SIGHUP` |
| `TMPDIR` が書込不可のフォルダ | 1 | `error: cannot create a temporary directory under '…': AccessDenied` |
| `TMPDIR` が空文字列 | 0 | `/tmp` を使い、`/tmp` に `qenome-*` は残らない |

WALのDBは、fixtureのコピーをWALにして確認した（Python の sqlite3 で、自動checkpointを止めた書込接続を開いたまま実行）。

| 実行 | 終了コード | 結果 |
| --- | --- | --- |
| checkpointされていない確定分が `-wal` にある（customer_id=1234 を100行追加） | 0 | `rows: 200`。元DB本体と `-wal` のSHA-256は前後で同じ |
| 実行中も別スレッドがINSERTを続ける | 0 | `rows: 9182`（copy開始時点の件数） |
| 書込が止まっていて `-wal` / `-shm` が無いWALのDB | 0 | `rows: 100`。本体のSHA-256は同じ。実行後、本体の横に `-shm` と `-wal` が残った（D-001どおり） |
| 通常方式のDBで、別接続が `BEGIN EXCLUSIVE` 中 | 1 | `error: cannot copy '…': the database is locked by another connection: database is locked` |

一時フォルダの削除失敗は、独立した実行確認で `chflags uchg` により baseline.db を削除不能にして再現した。終了コード5で、stdoutには通常の結果が出て、stderrに `the temporary directory '…' could not be removed: PermissionDenied` と残ったパスが出た。

未確認：hot journal が残る通常方式のDBで終了コード1になる分岐（読み取り専用では戻せない hot journal を安定して作れなかった）。Linux（tmpfs、`copy_file_range`）。

## 次の開発の進め方

MVPタスクの順に進める。初期化済みのコードを再生成しない。各工程の未決契約を確認し、最小の変更と検証結果を残す。新しい本番依存、大規模な設計変更、commit、pushは事前確認が必要。

機密ファイル、認証情報、個人情報は読み取り・編集・露出しない。検証用DBはダミーデータで作る。

## 実装時に必要な検証

コード変更後は関連テスト、整形、buildを実行する。挙動の変更にはテストを追加する。入力拒否、WALを含むコピー、元DB保全、結果一致と比較不能、正常・失敗・中断時の後片付けを重点確認する。

固定版・ダミーデータから改善例と効果なし例を再現し、ローカルD1での試用では手順と負担を確認する。実装後は作業ルールに従い品質・性能・安全性の3観点でレビューする。文書のみの今回作業では実装後レビューは対象外。
