# 開発と検証

[概要](overview.md) · [MVPタスク](mvp.md) · [設計条件](design.md)

## 現状と原資料

2026-10-10にmainブランチを確認した。src/main.zigとsrc/root.zigは初期サンプル。この整理ではコード実装、commit、pushを行っていない。

2026-10-11時点：工程2（入力と読取制限）の実装をmainへ取り込み済み（単位1〜4。2026-10-11時点のmainは `0d7e632`）。`src/main.zig` は `src/cli.zig` のCLIへ接続し、`src/root.zig` は `cli` / `db` / `sqlite` を再エクスポートする。同梱SQLite（3.51.2）でDBを読み取り専用に開き、SELECT 1文・型付きバインド・候補CREATE INDEXの検証と、時間上限・Ctrl+Cによる中断までを実装した。

原資料はリポジトリ外のローカルノートで、この文書はその内容を整理したもの。

原資料の「全項目未チェック」という説明と工程0の完了チェックには差がある。工程0は原資料のチェック状態を記録し、今回の実行確認とは区別した。実装済みの判定にはソースと実行結果を使う。

## 環境と既存手順

[build.zig.zon](../build.zig.zon)のminimum_zig_versionは0.17.0。[build.zig](../build.zig)にbuild、run、testの手順がある。[品質チェック設定](../.github/workflows/quality.yml)は版の一致、整形、build、test、境界チェック（アーキテクチャ）を検査する。工程別の責務・依存の向き・所有者のルールは [アーキテクチャ](architecture.md) を参照する。CIの実測（2026-10-11にGitHub APIで再確認。runの開始から完了まで）は、PR #2が44秒、PR #1が143秒、PR #2のマージ後のmain pushが127秒で、いずれも10分枠（`timeout-minutes: 10`）に十分収まる。

既存の確認コマンドは `zig version`、`zig build --summary all`、`zig build run`、`zig build test --summary all`、`zig fmt --check .`、`python3 scripts/test_check_architecture.py`、`python3 scripts/check_architecture.py`。SQLite比較CLIは `--help` で使い方と終了コードを確認できる（終了コード0）。

```sh
zig build run -- --help
zig build run -- --db <DB> --select <SELECTファイル> --index-sql <候補DDLファイル> --bind 1:int:1234
python3 scripts/test_check_architecture.py   # 境界チェック自身の検証
python3 scripts/check_architecture.py        # 実ツリーの境界検査（違反0で終了0）
```

### 同梱SQLite

- 使う版は3.51.2。[src/sqlite.zig](../src/sqlite.zig)の `pinned_version` と一致することをテストで確認する。取得元のURL、公式公開SHA3-256、source id、同梱2ファイルのハッシュ、コンパイルフラグは [vendor/sqlite3/PROVENANCE.txt](../vendor/sqlite3/PROVENANCE.txt) に記録する
- `vendor/sqlite3/sqlite3.c` / `sqlite3.h` は `build.zig` の `Qenome` モジュール1か所にだけ登録し、実行ファイルと2つのテストが同じ定義を共有する（二重定義を避ける。Cソースのコンパイルは各アーティファクトのビルドで行われる）。システムの `libsqlite3` や `sqlite3` CLIには依存しない
- CIに追加パッケージは不要。`quality.yml` の手順は `mlugg/setup-zig`、Zigの版の一致確認、整形、build、test、境界チェック（ランナー標準のpython3）だけで、パッケージ導入のステップがない（同梱SQLiteのCソースはZigがコンパイルする）

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

未確認：時間上限はSELECTの実行中だけ効き、prepare段階は対象外（工程5から索引作成にも効く。「工程5の索引適用と結果比較」）。WAL構成のDBの読み取りは工程4で扱う。Windowsは未対応（シグナル処理がPOSIXのみ）。

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

工程5で0の意味を「結果が一致した」に変え、3・4を足した（「工程5の索引適用と結果比較」の終了コード表）。

#### 利用条件と制約

- **WALのDBの付属ファイル**：読み取り専用で開いても、SQLiteは元DBの横に `-shm` と `-wal` を作る（すでにある場合も、`-shm` の中身は書き換わりうる）。本体ファイルの中身は変えない。「元DBを変更しない」は、本体の中身を変えないことを指す（D-001）。
- **外部writerがいる場合**：WALのDBなら、外部writerを止めずにcopy開始時点のsnapshotを取れる。ただしcopyの間は、外部側のcheckpointがcopy開始時点より先へ進めない（`-wal` が大きくなり、RESTART/TRUNCATE checkpointは待たされるか、BUSYになる）。通常方式（rollback journal）のDBでは、copyの間ずっと外部writerのコミットを待たせる（相手に待ち時間の設定がなければ、相手側が `SQLITE_BUSY` になる）（D-002）。
- **中断のタイミング**：copy（`backup_step(-1)`）は途中で止められない。SIGINT・SIGTERM・SIGHUP はcopyが終わった時点で反映し、後片付けをしてから終了する。時間上限はcopyには効かない（SELECTの実行と、工程5からは索引作成に効く）。SQLの誤りも、copyが終わった後で見つかる。
- **強制終了**：`kill -9` や、猶予の後にSIGKILLを送る仕組み（docker・systemdなど）で止めると、一時フォルダが残る（大きなDBではcopyが猶予より長くかかりうる）。中身は元DBのコピーなので、`$TMPDIR/qenome-*` を手で消す。自動の掃除はしない。
- **一時領域**：元DBの約2倍の空き容量が必要。`$TMPDIR` がメモリ上（Linuxのtmpfsなど）にあると、ディスクI/Oが実DBと違うので、時間の前提が崩れる。工程6では一時フォルダの場所（`work-dir-parent:`）を出す。ファイルシステムの種類は出さない。
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

### 工程5の索引適用と結果比較（2026-10-12、Zig 0.17.0・同梱SQLite 3.51.2）

工程5から、候補索引を variant だけに作り、同じSELECTとバインドを baseline と variant の両方で実行して、計画・カウンタ・結果を並べる。結果は行の多重集合として比べ、一致・不一致・比較不能のどれかを終了コードとstdoutで示す。

処理の順番は次のとおり。

1. 工程4のとおり、一時フォルダに baseline と variant を作る。
2. baseline を読み取り専用で開き、SELECTの検査・バインド・候補CREATE INDEXの検査を行う（工程2のまま）。このとき authorizer が、SELECTが呼ぶ関数名・読む表・ビュー / WITH句経由かを記録する（拒否はしない）。
3. variant だけを読み書きで開いて候補索引を作る。同じ DDL 許可リストで prepare と実行を行い、終わったら閉じる。読み書きで開くのはこの接続だけで、SELECTを実行する接続はすべて読み取り専用のまま。
4. baseline で計画を読んでSELECTを実行し、行を集める。続いて variant を読み取り専用で開き、同じことをする。
5. 行を比べ、結果を決めてから、stdoutに1回だけ書く。どの終わり方でも接続を閉じて一時フォルダを消す（工程4のまま）。

索引作成を先に行うのは、UNIQUE索引が重複行で失敗する場合などを、重いSELECTの前に見つけるため。

#### 行の比べ方

- 各行を「型＋値」に直して比べる。INTEGER・REAL・TEXT・BLOB・NULLを区別するので、`1`・`1.0`・`'1'` は別の値、NULLと `''` と `x''` も別の値。REALはビット単位で比べる（`0.0` と `-0.0` も別）。同じ行の数（重複）も比べる。
- 並び順は無視する（行の多重集合）。ORDER BY があっても同じ。並びが同じだったかは `row-order:` に参考として出すだけで、結果には影響しない。ORDER BY の正しさは確かめない。
- 保持する行は baseline と variant の合計で 64MiB まで（正規化した値のバイト数と、行ごとの管理分）。数えるのは保持するデータの量で、配列の伸び方により実際のメモリはおよそ1.5倍まで上回りうる。超えた場合やメモリが足りない場合は比較不能にする。

#### 比較不能にする条件

比較不能のときは、理由（`incomparable-reason:`）ごとに、次に試すこと（`incomparable-hint:`）を1行ずつ対で出す（列数違いとメモリ不足はヒントなし）。

| 条件 | 扱い | 理由（例） | ヒント（要旨） |
| --- | --- | --- | --- |
| 実行のたびに値が変わる関数：`random`、`randomblob`、`changes`、`last_insert_rowid`、`total_changes` | 常に比較不能。行を集めず比べない（計画とカウンタは出す） | `the SELECT calls random(), whose result changes between runs` | その関数を外したSELECTで比べる |
| スキーマを表す表：`sqlite_schema`、`sqlite_master`、`sqlite_temp_schema`、`sqlite_temp_master`、`sqlite_stat*` | 常に比較不能（スキーマ表は候補索引で中身が変わる。`sqlite_stat*` は ANALYZE しない限り変わらないが、安全側として含める） | `the SELECT reads sqlite_master, which describes the database itself` | 対象外 |
| 行の保持が 64MiB を超えた | 常に比較不能 | `the result rows exceed the 64 MiB kept for the comparison` | WHERE で行を絞る（LIMIT は使わない） |
| メモリが足りない、列の数が違う | 常に比較不能 | `out of memory while keeping the result rows` など | なし |
| 日付・時刻の関数：`date`、`time`、`datetime`、`julianday`、`unixepoch`、`strftime`、`timediff`、`current_date`、`current_time`、`current_timestamp`（`'now'` や引数なしで現在時刻を読みうる） | 一致なら一致。不一致なら比較不能（片側だけの行の件数と例も出す） | `the rows differ, and the SELECT calls date(), which can read the current time ...` | 現在時刻を読むなら、時刻をバインド値で固定する |
| 読む順で結果が変わりうる集約・ウィンドウ関数：`sum`、`avg`、`total`、`group_concat`、`string_agg`、`json_group_array`、`json_group_object`、`jsonb_group_array`、`jsonb_group_object`、`row_number`、`ntile`、`first_value`、`last_value`、`nth_value`、`lag`、`lead` | 同上 | `the rows differ, and the SELECT calls sum(), ...` | `sum` / `avg` / `total` は末尾の桁の違いか片側だけの行で確かめる。連結は関数の中に ORDER BY、ウィンドウは OVER の ORDER BY を一意な列で終える |
| SQLの文字列に LIMIT か OFFSET がある（文字列リテラル・コメント・引用した名前・バインド名は除く） | 同上 | `the rows differ, and the SELECT has LIMIT or OFFSET, ...` | LIMIT の箇所の ORDER BY を NOT NULL で一意な列で終えるか、LIMIT / OFFSET を外す。変えたSELECTの計画に候補索引が出るか確かめる |
| ビューか WITH句（CTE）を通して読む | 同上 | `the rows differ, and the SELECT reads through a view or a WITH clause, ...` | ビューやWITH句の中身のSELECTを直接比べる |

ヒントに従ってSELECTを変えると、元とは別のSELECTになる。比べたい候補索引が変えたSELECTでも使われているかを、`plan:` の行で確かめてから結果を読む。

関数名は、同梱SQLiteの組み込み関数一覧（`pragma_function_list`）とテストで突き合わせている。SQLiteの版を上げて関数が増えると、分類するまでテストが失敗する。

`INDEXED BY` で候補索引の名前を指定したSELECTは、候補索引のない baseline では prepare できないので、入力の拒否（終了コード1）にする。stderrに「SELECT（参照するビューを含む）が INDEXED BY で候補索引を指定しているが、baseline にはその索引がない」と出す。

#### 制限（不一致と出うるもの）

次は名前では見つけられないので、答えが正しくても「不一致（3）」と出ることがある。不一致の文言は「索引が結果を壊した」と断定しない（`the cause is not determined`）。

- GROUP BY の対象外の列（どの行の値が出るか決まっていない）
- 等しいとみなされる別の値のうち、どれが代表として返るか（`min` / `max`、DISTINCT・GROUP BY・UNION のキー。NOCASE の大文字小文字、`1` と `1.0`、`0.0` と `-0.0` など）
- ROWS で範囲を決める窓で使う集約関数（`count(*) OVER (ORDER BY a ROWS ...)` など）
- スカラーサブクエリが複数行のうち先頭の1行だけを使う場合

反対に、比べられるのに比較不能になるものもある（安全側）。`changes()` は読み取り専用の接続では両側0でも比較不能、ビューの使わない列にある関数も検出される、列名 `offset` も LIMIT/OFFSET と見なす。

日付・時刻の関数（D-512）には次の性質がある。`'now'` を使うSELECTは、2回の実行の間に時刻が進むと結果が変わるので、同じSELECTでも実行ごとに0と4が入れ替わりうる（`date('now')` は日の境目、`datetime('now')` は秒の境目をまたいだときだけ、`julianday('now')` や `strftime('%f', 'now')` はほぼ毎回4）。また、日付・時刻の関数を使うSELECTでは、本当の不一致も3ではなく4になる。終了コードで判断するスクリプトでは、時刻をバインド値で固定する。

#### 終了コード

| 終了コード | 意味 |
| --- | --- |
| 0 | 受け付けて両方で実行し、結果が一致した（行の多重集合） |
| 1 | 入力の拒否（工程4の一覧に加え、索引作成の失敗、variant 側の失敗、INDEXED BY で候補索引を指定したSELECT） |
| 2 | 引数を使えない |
| 3 | 受け付けて両方で実行し、結果が違った |
| 4 | 受け付けて両方で実行したが、結果を比べられない |
| 5 | 0になるはずだった実行の後片付けに失敗した。1/3/4/124/129/130/143 のときは元のコードを保つ。どの場合も残ったパスをstderrに出す |
| 124 | 時間上限（索引作成、baseline のSELECT、variant のSELECT のどこか。stderrにどこかを出す） |
| 129 / 130 / 143 | SIGHUP / SIGINT / SIGTERM で中断した |

1・124・129/130/143 では stdout は空。3・4 でも stdout に要約を出す。要約を書けなかったときは1。

時間上限（`--timeout-ms`、既定30秒）は、索引作成・baseline のSELECT・variant のSELECT のそれぞれに、同じ値を別々にかける。copy は止められないので、最悪の待ち時間は copy＋上限の3倍（工程6からは計時の分も加わる。「工程6の反復測定とレポート」）。索引作成と SELECT の上限を別々には指定できない。索引作成の中断は、外部ソートの書き出しや fsync の間は効かず、止まるまで遅れることがある。

#### stdoutの形式

入力（`db:`・`select:`・`index-sql:`）を1回出し、baseline の段落（`measured-on: baseline (candidate index not applied)` から。工程3・4と同じ文字列）と variant の段落（`measured-on: variant (candidate index applied)`、`rows:`・`plan:`・カウンタ）を順に出す。キーが段落ごとに繰り返されるので、行の順番で読む。最後に比較結果を出す。

| キー | 内容 |
| --- | --- |
| `result:` | `match (row multiset)` / `mismatch (row multiset; the cause is not determined)` / `incomparable` |
| `incomparable-reason:` | 比較不能の理由。複数あれば1行ずつ |
| `incomparable-hint:` | 直前の理由に対して次に試すこと（ないときは出さない） |
| `baseline-only-rows:` / `variant-only-rows:` | 片側にしかない行の件数（行を比べて違ったときだけ） |
| `baseline-only-row:` / `variant-only-row:` | その例を最大5件ずつ。`[値, 値, ...]` の1行 |
| `row-order:` | 一致のときだけ `same` / `differs`（参考）。それ以外は `not applicable` |

例の値の書き方：INTEGERは10進、REALは元の値に戻せる最短の指数形式（`1e0`、`-0e0`）、TEXTは `'...'` で `\\`・`\'`・`\n`・`\r`・`\t`・`\xNN`（ASCIIの制御文字と不正なUTF-8）・`\uXXXX`（C1制御文字、行・段落区切り、双方向の上書き）をエスケープ、BLOBは `x'...'`、NULLは `NULL`。TEXTとBLOBは200バイトで切り、`...(N bytes)` を添える。DBの中身が端末を操作したり、行を分けたりしないようにするため。

不一致のときは **DBの行の内容が最大5行×2 stdoutに出る**。stdoutをCIのログなどに残す使い方では、個人情報を含むDBに注意する。

#### 実行確認

[testdata/README.md](../testdata/README.md) の手順で作ったfixture（SHA-256 `ddca8dd2…`）と実バイナリで、`TMPDIR` を作業用の空フォルダにして確認した。各実行の後、そのフォルダは空で、fixtureのSHA-256は変わらなかった。

| 実行 | 終了コード | 出力 |
| --- | --- | --- |
| 改善する例（`--bind 1:int:1234`） | 0 | baseline `SCAN events`・fullscan 199,999・vm 600,407、variant `SEARCH events USING INDEX ix_events_customer_id (customer_id=?)`・fullscan 0・vm 710、rows 100 / 100、`result: match`、`row-order: same` |
| 効果のない例（`--bind 1:text:ok`） | 0 | 両方 `SCAN events`・199,999・933,339、rows 66,666 / 66,666、`result: match` |
| `SELECT id, random() FROM events WHERE customer_id = ?` | 4 | 両方の計画（variant は SEARCH）と `the SELECT calls random(), ...`、ヒント `compare the SELECT without random()` |
| `SELECT name FROM sqlite_schema` | 4 | rows 1 / 2（variant には候補索引の行が増える）と `the SELECT reads sqlite_master, which describes the database itself` |
| `SELECT id FROM events WHERE customer_id > ? LIMIT 3`（`1:int:1990`） | 4 | baseline と variant で別の3行。`the rows differ, and the SELECT has LIMIT or OFFSET, ...` |
| 改善する例＋`--timeout-ms 1` | 124 | stdout 0バイト、stderr `error: --index-sql exceeded the time limit of 1 ms` |
| 重いSELECT中に SIGINT | 130 | stdout 0バイト |
| 70行×1MiBの BLOB を返すSELECT | 4 | 両方の段落と `the result rows exceed the 64 MiB kept for the comparison` |
| 日付の列を持つ5,000行のDBで `WHERE date(created_at) = ?` と式索引 `ON orders(date(created_at))` | 0 | variant `SEARCH orders USING INDEX ix_d (<expr>=?)`、`result: match` |
| 同じDBで `WHERE created_at > datetime('now', '-400 days')` | 0 | 2回の実行の間で結果が同じだった |
| 同じDBで `SELECT id, julianday('now') ...` | 4 | `the rows differ, and the SELECT calls julianday(), ...` とヒント `bind a fixed time instead` |

独立した実行時評価では、ほかに GROUP BY の対象外の列で3、UNIQUE索引の重複で1、INDEXED BY の3通り（大小違い・引用符・別の索引名）で1、索引作成中の SIGINT で130、SELECT中の SIGTERM / SIGHUP で143 / 129、WAL構成のDBで0を確認した。

未確認：Linux（tmpfs）。索引作成の中断が止まるまでの遅れ（大きなDB）。不一致の例の表示で、U+200E/U+200F・ゼロ幅文字など見た目を偽れる文字はエスケープしていない。

### 工程6の反復測定とレポート（2026-10-12、Zig 0.17.0・同梱SQLite 3.51.2）

工程6から、結果が一致したSELECTを baseline と variant で交互に繰り返し実行して時間を測る。時間の代表値とばらつき、DB容量の増分、測定条件、版を表示し、計画・カウンタと時間を合わせて判定する。終了コードは工程5と同じで、時間の判定では変わらない（時間だけで成功としない）。

処理の順番は次のとおり（1〜2は工程5と同じ）。

1. baseline・variant で1回ずつ実行し、行を比べる。この1回を各側のウォームアップとし、計時しない。計画・カウンタはこの1回の値を出す（カウンタは繰り返すと積み上がるため、後で読み直さない）。
2. 結果が一致しないとき（3・4）と `--runs 0` のときは計時しない（D-601）。
3. `--runs N`（既定10、0〜1000）ラウンドの計時を行う。1ラウンドで両側を1回ずつ実行し、1・3・5…ラウンド目は baseline→variant、2・4・6…ラウンド目は variant→baseline の順にする（ABBA。番号は stderr の表示と同じく1から数える）。マシンの状態がだんだん変わっても、その影響が片側だけに乗らないようにするため（D-601）。
4. 各回は、文をリセットしてから `sqlite3_step` で最後まで進める時間を測る。列の値は読まない。prepare・バインド・計画の読み取りは含まない。時間上限と中断の確認（約1000命令ごとに時計を読む）は含む。この確認は命令数に比例するので、遅い側ほど多くかかるが、規模は小さい。
5. 一時フォルダの baseline.db と variant.db（索引作成後）のファイルサイズを読む。
6. 判定してから、stdoutに1回だけ書く。

時間上限は各回に別々にかかるので、最悪の待ち時間は copy＋上限×(3＋2×runs) になる（索引作成1回、最初の実行2回、計時2×runs回）。既定値（30秒、10ラウンド）では約11分30秒。

#### 統計と判定（D-602）

各側について、中央値・四分位（p25・p75）・最小・最大をナノ秒で出す。四分位は、並べた値の位置 q×(n−1) で前後を直線で補う方式（Hyndman–Fan 第7法。偶数個の中央値は真ん中2つの平均）。

| 判定 | 条件 |
| --- | --- |
| `improved` | どのカウンタも増えず、vm-steps が減り、variant の中央値が baseline の中央値より20%を超えて小さく、全ラウンドで variant が速い |
| `no-effect` | 計画（各行の文言と親子関係）と4つのカウンタがすべて同じで、中央値の差が baseline の中央値の±20%以内 |
| `needs-check` | 上のどちらでもない。`time-verdict-reason:` に理由を出す（仕事は減ったが速くないラウンドがある／差がノイズ帯の中／計画やカウンタは変わったが vm-steps が減っていない／仕事は同じなのに20%を超える差／baseline の中央値が0） |
| `not-judged` | 結果が一致しない・比較できない、または `--runs 0` |

±20%は testdata/README.md の判定条件の例をそのまま使う固定値。計画の比較では `id` を見ない（VMの命令位置で、計画が同じでも変わりうるため）。索引で遅くなった場合は「悪化」とは出さず、`needs-check` になる。

#### 失敗時の動作

計時中に時間上限を超えたら124、シグナルなら129/130/143、実行の失敗なら1。どれも stdout は空。時間上限と実行の失敗では、stderr に側と回（`on the variant (timed run 3)`）も出す。結果の比較がすでに済んでいても要約は出さない（失敗時は stdout が空、という工程5までの約束を保つ）。ファイルサイズを読めなければ1。`--runs` が範囲外なら2。

#### stdoutの形式（工程6で足した行）

工程5の `row-order:` の後に続ける。工程5までの行の位置と文言は変えない。

| キー | 内容 |
| --- | --- |
| `bind:` | バインドを1つずつ（なければ `none`）。既定では値を出さず、`1:int`・`1:real`・`1:null`・`1:text (12 bytes)` のように番号・型・TEXTのバイト数だけ。`--show-binds` のときだけ `N:型:値` で値を出す（TEXTは例の値と同じエスケープ）（D-605） |
| `measure-runs:` | 計時したラウンド数（計時しなかったときは0） |
| `measure-warmup:` / `measure-order:` / `measure-scope:` / `measure-cache:` | ウォームアップ回数、順番（ABBA）、測った範囲、キャッシュ条件（同じ接続を使い回すので温まっている） |
| `work-dir-parent:` | 一時フォルダを作った場所。メモリ上のファイルシステム（Linuxのtmpfsなど）だと時間の前提が実DBと違う |
| `zig:` / `build-mode:` / `os-arch:` | Zigの版、最適化の種類、OSとCPU。`debug` の時間は参考にならないので、測定は `zig build -Doptimize=ReleaseFast` で作ったバイナリで行う |
| `time-baseline-ns:` / `time-variant-ns:` | `median= p25= p75= min= max=` と、行末に読みやすい単位にした中央値 `(median 3.01 ms)`（計時したときだけ。単位は ASCII の `ns`・`us`・`ms`・`s`。丸めた後で1000未満になる最大の単位）（D-603） |
| `time-ratio:` | variant の中央値 ÷ baseline の中央値（計時したときだけ） |
| `variant-faster-rounds:` | variant が速かったラウンド数／全ラウンド数（計時したときだけ） |
| `db-bytes-baseline:` / `db-bytes-variant:` / `db-bytes-increase:` | snapshot のファイルサイズ、索引作成後の variant のファイルサイズ、その差。DBファイル全体の増分で、索引単体の大きさではない |
| `time-verdict:` / `time-verdict-reason:` | 判定と理由（理由は0〜3行） |

バインド値を既定で隠すのは、実データをバインドした要約をCIのログなどに残すと値が漏れるため（D-605）。ただし `--bind` の値はコマンドライン自体にも残る（CIのステップ表示や `set -x`）。不一致の行の例（工程5）は今も値を出す。

ローカルの測定は、本番D1などの速度を保証しない（[概要](overview.md)）。

#### 進み具合（D-603）

計時に1秒以上かかると、前の表示から1秒以上たったラウンドの終わりごとに、stderr へ `progress: timed round k of N done` を出してすぐ書き出す。表示は計時の外で行うので、測定値には入らない。速い測定では何も出ない。そのため、**成功時でも stderr に `progress:` 行が出ることがある**（stdout と終了コードは変わらない。`2>/dev/null` で消せる）。stderr に書けなかったら、それ以降の進み具合は出さず、終了コードも変えない。

進み具合は計時の間だけ出す。copy・索引作成・最初の2回の実行の間は何も出ず、1ラウンドは最大で上限の2倍かかるので、何も出ない時間は最悪で copy＋上限の3倍程度（既定で約90秒）残る。

#### 実行確認

[testdata/README.md](../testdata/README.md) の手順で作ったfixture（SHA-256 `ddca8dd2…`）と、`zig build -Doptimize=ReleaseFast` の実バイナリ（macOS・aarch64）で、`TMPDIR` を作業用の空フォルダにして既定の10ラウンドで3回ずつ実行した。各実行の後、そのフォルダは空で、fixtureのSHA-256は変わらなかった。

| 実行 | 終了コード | 判定 | baseline 中央値 | variant 中央値 | 比 | variantが速いラウンド | 容量の増分 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 改善する例（`--bind 1:int:1234`） | 0 | 3回とも `improved` | 約2.9〜3.0 ms | 約25〜29 µs | 0.008〜0.010 | 10/10 | 2,170,880 バイト |
| 効果のない例（`--bind 1:text:ok`） | 0 | 3回とも `no-effect` | 約11.4〜11.7 ms | 約11.4〜11.7 ms | 0.992〜1.003 | 5〜7/10 | 2,584,576 バイト |
| 効果のない例＋`--runs 1000`、開始約2秒後に SIGINT | 130 | — | — | — | — | — | stdout 0バイト、一時フォルダなし |

Debug ビルドでは、改善する例の baseline 中央値が約58 ms で、ReleaseFast の約20倍だった。

効果のない例を `--runs 200` で実行すると、約1秒ごとに `progress: timed round 43 of 200 done` などが実行中に出て、判定は `no-effect`（終了コード0）だった。stderr を閉じた実行（`2>&-`）でも終了コードは0だった。

未確認：Linux（tmpfs）。OSのページキャッシュを空にした状態（cold）での測定。他のマシンで効果のない例が±20%に収まるか。

## 次の開発の進め方

MVPタスクの順に進める。初期化済みのコードを再生成しない。各工程の未決契約を確認し、最小の変更と検証結果を残す。新しい本番依存、大規模な設計変更、commit、pushは事前確認が必要。

機密ファイル、認証情報、個人情報は読み取り・編集・露出しない。検証用DBはダミーデータで作る。

## 実装時に必要な検証

コード変更後は関連テスト、整形、buildを実行する。挙動の変更にはテストを追加する。入力拒否、WALを含むコピー、元DB保全、結果一致と比較不能、正常・失敗・中断時の後片付けを重点確認する。

固定版・ダミーデータから改善例と効果なし例を再現し、ローカルD1での試用では手順と負担を確認する。実装後は作業ルールに従い品質・性能・安全性の3観点でレビューする。文書のみの今回作業では実装後レビューは対象外。
