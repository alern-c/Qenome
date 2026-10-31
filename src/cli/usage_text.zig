const std = @import("std");
const contract = @import("../contract/values.zig");

pub const synopsis = "       qenome skill <print|install|uninstall|status> [options]";

pub const body =
    \\Compares one read-only SELECT before and after one candidate CREATE INDEX
    \\on a local SQLite database, without changing the database. With --write,
    \\it compares one INSERT, UPDATE, DELETE, or REPLACE instead.
    \\
    \\options (a value may also be written as --option=value):
    \\  --db <PATH>          SQLite database file (required, once; not with --d1)
    \\  --d1 <BINDING>       use the local D1 database of this d1_databases
    \\                       binding from a wrangler config instead of --db
    \\  --config <PATH>      wrangler config for --d1 (default: wrangler.toml,
    \\                       wrangler.jsonc or wrangler.json in the current
    \\                       directory)
    \\  --batch <FILE>       compare every SELECT in a batch manifest with
    \\                       every candidate CREATE INDEX, instead of --select
    \\                       and --index-sql; see the batch manifest below
    \\  --audit-indexes      with --batch, report the indexes that no query in
    \\                       the manifest used, the indexes whose leading keys
    \\                       another index or the primary key covers, and the
    \\                       UNIQUE and PRIMARY KEY indexes that are kept for
    \\                       their constraint; it needs --batch and does not
    \\                       take --suggest, --migration, or --seed-data
    \\  --rank               with --batch, measure every SELECT on the baseline
    \\                       and rank it by rows read. executions, written by
    \\                       --record or by hand, multiplies rows read; that
    \\                       product is a relative indicator, not a bill. A
    \\                       likely full scan is flagged and the run exits 7
    \\                       when any query is flagged. candidates and writes
    \\                       are ignored. It needs --batch and does not take
    \\                       --suggest, --migration, or --audit-indexes
    \\  --record <FILE>      read the records that qenome/d1 wrote to the output
    \\                       of wrangler dev or a test run, and write a batch
    \\                       manifest without candidates to --out; no database
    \\                       is needed; every manifest holds the bind values,
    \\                       so keep it local and out of version control;
    \\                       stdout also reports the shapes that ran many
    \\                       times with different values
    \\  --out <DIR>          new directory for --record; the command writes
    \\                       manifest.json and queries/ there, with mode 0700
    \\                       on the directory and 0600 on the files, and stops
    \\                       when the directory already exists
    \\  --n-plus-one-threshold <N>
    \\                       with --record, report the shapes that ran with at
    \\                       least N different values (default 10); 0 turns
    \\                       the report off; the range is 2 to 1000000
    \\  --migration <FILE>   apply this SQL file to the variant only before
    \\                       the --batch queries run; the manifest must omit
    \\                       candidates; CREATE INDEX, DROP INDEX, CREATE
    \\                       TABLE, and ALTER TABLE are allowed; a query
    \\                       that needs the new schema is measured on the
    \\                       variant only and is not judged
    \\  --seed-data <FILE>   replace the listed tables in the sandbox copy
    \\                       with deterministic dummy rows before comparing;
    \\                       the original database is not changed; see the
    \\                       README for the JSON spec
    \\  --scale <ROWS,ROWS[,ROWS]>
    \\                       with --seed-data, measure the same comparison
    \\                       at 2 or 3 strictly increasing row counts and
    \\                       show the results side by side; the largest
    \\                       table in the spec gets the step size and the
    \\                       other tables scale with it; each step seeds a
    \\                       fresh copy; not with --batch, --suggest,
    \\                       --migration, --audit-indexes, --rank, --record,
    \\                       or --format kv
    \\  --suggest            ask SQLite for candidate indexes instead of
    \\                       naming them, and compare the suggestions; with
    \\                       --batch the manifest may omit candidates
    \\  --select <FILE>      file holding one read-only SELECT (required, once;
    \\                       not with --write). - reads the SELECT from stdin
    \\  --sql <SQL>          the SELECT text itself, instead of --select, for
    \\                       one comparison or --suggest; not with --batch,
    \\                       --write, --record, or --migration
    \\  --write <FILE>       file holding one INSERT, UPDATE, DELETE, or REPLACE
    \\                       (required, once; not with --select). The statement
    \\                       runs in a transaction on each sandbox copy and is
    \\                       rolled back. Rows written include secondary-index,
    \\                       trigger, and foreign-key cascade changes. --write
    \\                       does not take --batch, --migration, or --suggest.
    \\  --index-sql <FILE>   file holding one candidate CREATE INDEX (required, once)
    \\  --bind <N>:<TYPE>[:<VALUE>]
    \\                       typed value bound to parameter N, repeatable;
    \\                       N is SQLite's parameter number; named parameters
    \\                       share the number of their first appearance and
    \\                       ?NNN uses NNN; TYPE is int, real, text or null
    \\                       (null takes no value); every number in 1..parameter
    \\                       count must be given exactly once
    \\  --timeout-ms <MS>    time limit for the index build, each SELECT run,
    \\                       and each --write execution; 0 disables it
    \\                       (default 30000); a run can wait up to the copy
    \\                       plus (3 + 4 x runs) limits plus up to three
    \\                       diagnostic statement limits
    \\  --runs <N>           timed rounds after a match, each timing the SELECT
    \\                       once per copy plus two baseline A/A runs; 0 skips
    \\                       the timing but keeps the row counts and verdict
    \\                       (default 10, at most
    \\                       1000); a timing that takes longer than a second
    \\                       reports its progress on stderr. With --write, N is
    \\                       the number of rolled-back executions per copy (at
    \\                       least 1); every execution must report the same
    \\                       counts
    \\  --format <FORMAT>    human (default), kv or json
    \\  --show-binds         print the bind values: human lists them in the
    \\                       summary, and kv and json add them after the
    \\                       number and type; without it, human leaves the
    \\                       binds out and kv and json print only their
    \\                       numbers, types and text lengths, so that the
    \\                       values stay out of logs
    \\  --show-rows          print the example rows that only one copy
    \\                       returned, in human, kv and json. Without it,
    \\                       only the counts are printed, so row values stay
    \\                       out of logs. Human says to rerun with this flag
    \\  --version            print the version and exit with status 0
    \\  --help, -h           print this message and exit with status 0
    \\
    \\The three paths may also be given by position: database, SELECT (or
    \\write) file, CREATE INDEX file. They fill the first role not yet given.
    \\Use -- before a path that starts with '-'.
    \\
    \\examples:
    \\  qenome app.db select.sql index.sql
    \\  qenome app.db select.sql index.sql --bind 1:int:1234
    \\  qenome --db app.db --select select.sql --index-sql index.sql --format kv
    \\  qenome app.db select.sql index.sql --format json
    \\  qenome app.db --write update.sql --index-sql index.sql
    \\  qenome --db app.db --write update.sql --index-sql index.sql --format json
    \\  qenome --d1 DB select.sql index.sql
    \\  qenome app.db --batch batch.json
    \\  qenome --db app.db --batch batch.json --format json
    \\  qenome app.db --batch batch.json --audit-indexes
    \\  qenome app.db --batch batch.json --rank
    \\  qenome app.db --batch batch.json --migration 0002.sql
    \\  qenome app.db select.sql index.sql --seed-data seed.json
    \\  qenome app.db select.sql index.sql --seed-data seed.json --scale 1000,10000
    \\  qenome app.db select.sql --suggest
    \\  qenome app.db --sql "SELECT a FROM t WHERE a = 1" --suggest
    \\  qenome app.db - index.sql
    \\  qenome app.db --batch batch.json --suggest
    \\  qenome --record record.log --out qenome-manifest
    \\  qenome --record record.log --out qenome-manifest --format json
    \\
    \\The same paths can be given as --db, --select and --index-sql.
    \\--sql <SQL> passes the SELECT text instead of a file, for one comparison
    \\or --suggest (and --scale). A SELECT path of - reads that SELECT from
    \\stdin. --sql and - are rejected for --batch, --write, --record, and
    \\--migration, which keep their own files. - is not an index, write,
    \\batch, or migration path.
    \\With --d1, the two positional paths fill the SELECT and CREATE INDEX
    \\roles, whatever the order of the paths and the option. With --write,
    \\a positional path fills the write file instead of the SELECT file.
    \\
    \\--d1 reads the top-level d1_databases bindings of a wrangler config and
    \\uses preview_database_id (database_id when it is not set) to find
    \\<config dir>/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/<id>.sqlite,
    \\the file that wrangler dev and wrangler d1 execute --local create. It
    \\stops with status 4 when the config or the binding cannot be chosen, or
    \\when that file does not exist yet. The comparison uses the bundled
    \\SQLite 3.53.4, the same version the local D1 engine runs, but the
    \\two builds use different compile options, so plans and times can
    \\differ, and the times come from this local copy, not from
    \\production D1.
    \\
    \\With --batch, the manifest is a JSON object with queries and
    \\candidates: {"queries":[{"select":"a.sql","binds":["1:int:1"]}],
    \\"candidates":[{"index_sql":"i.sql"}]}. The paths are relative to the
    \\manifest. Each list takes 1 to 100 entries, and the same path cannot
    \\repeat. --suggest lets the candidates list be omitted or empty.
    \\With --migration the manifest may also hold writes: [{"write":
    \\"w.sql","binds":["1:int:1"]}], one INSERT, UPDATE, DELETE, or
    \\REPLACE per entry. Without --migration the manifest is rejected.
    \\--batch compares every query with every candidate, keeps going
    \\when one candidate is rejected, and prints a batch report with a
    \\recommendation. It does not time the runs and does not take --bind,
    \\--select, --index-sql, --runs or --format kv. With --batch, exit 1 and
    \\124 can still have a report on stdout; stdout is empty when the run
    \\stopped before the report.
    \\
    \\--rank measures every manifest SELECT once on the baseline copy and
    \\orders the queries by rows read, highest first. When a query has
    \\executions, the order uses rows read x runs instead. That figure is
    \\a relative indicator, not a bill. A query is a likely full scan when
    \\its full-scan counter is above zero or its plan has a SCAN step that
    \\does not use an index. The report flags those queries and exits 7
    \\when at least one is flagged; otherwise it exits 0. The manifest
    \\needs only queries, so a manifest from --record works, and candidates
    \\and writes are ignored. The last line names the top query for
    \\--suggest. It needs --batch and takes --format human or json, --d1,
    \\--seed-data, and --timeout-ms.
    \\
    \\--audit-indexes reads the plans of the manifest queries on one
    \\read-only copy and reports three lists: the indexes that no plan
    \\named (Unused in this manifest), plain indexes whose key columns are
    \\a prefix of another index or of the primary key with the same
    \\collation and order (Redundant candidates), and UNIQUE and PRIMARY
    \\KEY indexes (Kept for constraints). The manifest needs only queries;
    \\candidates are ignored. The report says a fact about this manifest,
    \\not that an index can be dropped: UPDATE, DELETE, foreign-key
    \\maintenance, and queries outside the manifest are not planned. A
    \\partial index depends on the bound values, and the redundancy list is
    \\not judged when a manifest SELECT uses INDEXED BY. The run does not
    \\change the database, writes the report with exit status 0, and takes
    \\--format human or json, --d1, and --timeout-ms.
    \\
    \\--migration applies the file to the variant copy before the manifest
    \\queries run. It needs --batch, takes a manifest without candidates,
    \\and does not take --select, --index-sql, --bind, --runs, --suggest,
    \\or --format kv. The file may hold several CREATE INDEX, CREATE
    \\UNIQUE INDEX, DROP INDEX, CREATE TABLE, and ALTER TABLE (ADD,
    \\RENAME, or DROP COLUMN, and RENAME TO) statements separated by
    \\semicolons; other statements, including INSERT, UPDATE, DELETE,
    \\DROP TABLE, ATTACH, and PRAGMA, are rejected with status 1 and
    \\the number of the statement. The report names the migration and
    \\every applied statement. A query that uses a column or table the
    \\migration adds is measured on the variant only: its plan and row
    \\counts are reported with verdict not-judged, and it does not
    \\change the exit status. If the result rows match but a query reads
    \\or writes more rows after the migration, the run exits with status
    \\6 so that a CI gate can stop. The optional writes entries run on
    \\both copies after the queries, each inside a transaction that is
    \\rolled back, and report the rows read and written for both copies.
    \\A write that reads more rows is regressed; more rows written is
    \\reported but does not change the verdict, because an index the
    \\migration adds makes every write touch one more entry. The bundled
    \\D1 counting patch does not count secondary-index deletes, so a
    \\dropped index does not lower the rows written.
    \\
    \\--seed-data reads a JSON spec, replaces the listed tables in the
    \\baseline copy, and copies that baseline to the variant. The tables
    \\listed in the spec are emptied first, so their row count is exactly
    \\the number in the spec. Each column takes kind fixed, uniform, ratio,
    \\or sequence. The same spec and seed give the same rows, and the
    \\original database is never changed. --seed-data works with every
    \\mode, including --batch, --suggest, --migration, and --rank.
    \\
    \\--suggest asks SQLite's expert for candidate indexes for the SELECT
    \\files and compares them with the manifest candidates (with --batch) or
    \\alone (with one SELECT file). It does not take --runs, --format kv, or
    \\an index file. Suggestions pass the same CREATE INDEX check as
    \\manifest candidates and are dropped with a warning when they fail.
    \\The report adds warnings and marks each candidate's source. It keeps
    \\at most 20 suggestions and at most 100 candidates with the manifest.
    \\A database whose schema is not one plain CREATE statement is
    \\rejected with status 1.
    \\When the current plan already needs no index, it exits 0 and reports
    \\no index needed, with that plan and the rows read. When a suggestion
    \\cannot be produced, or every suggestion is rejected, it stops with
    \\status 1 (suggest_failed or no_candidates). no_suggestions stays a
    \\warning when manifest candidates are still compared.
    \\Do not use --suggest in CI gates; keep it for finding candidates.
    \\
    \\exit status: 0 result rows match, 1 rejected, 2 usage error,
    \\3 result rows differ, 4 results cannot be compared or --d1 cannot
    \\locate the local database, 5 cleanup failure, 6 a --migration query
    \\read or wrote more rows, 7 a --rank report found a likely full scan,
    \\124 time limit reached,
    \\129 / 130 / 143 interrupted by SIGHUP / SIGINT / SIGTERM
    \\
    \\The database is opened read-only and copied as one snapshot into a
    \\private directory under $TMPDIR (default /tmp) as a baseline and a
    \\variant; the candidate index is built on the variant only. The SELECT
    \\runs on both copies and their result rows are compared. When they
    \\match, the SELECT is timed again on both copies in alternating rounds.
    \\With --write, the statement runs once per requested round inside a
    \\transaction on each copy and is rolled back, so the next round starts
    \\from the same rows. The original database is never opened for writing.
    \\The directory is removed before exit.
    \\
    \\output (stdout, written once after every run; empty when an input is
    \\rejected, the time limit is reached, or the run is interrupted):
    \\  The default (--format human) aims at a decision: a summary (whether
    \\  the result rows match, the rows read and written on each copy, the
    \\  verdict, whether the plan changed, the median times with the
    \\  direction from the paired rounds when they allow it, the size of
    \\  the change when the medians agree, and the size increase), the
    \\  counters and times of both copies side by side, the query plans,
    \\  and a Warnings section when an advisory warning applies. A
    \\  difference, a comparison that is not possible, or rows in another
    \\  order adds the explanation and the one-sided counts. The example
    \\  rows are printed only with --show-rows; otherwise human says to
    \\  rerun with that flag. --show-binds adds the bind values; a build
    \\  without optimization adds a note that its times are slower.
    \\  The kv format prints every fact as one `key: value` per line, for
    \\  scripts and logs: it keeps the inputs, the SQLite and Zig
    \\  versions, the build mode, the OS and architecture, the work
    \\  directory, and the timing conditions below, which the human
    \\  output leaves out. Example row values appear only with --show-rows.
    \\  The json format prints one JSON object and a trailing newline:
    \\  schema_version, the verdict and its reasons, the result
    \\  comparison with its reasons, the counts, and example rows only
    \\  when --show-rows is set (the arrays are empty otherwise), both
    \\  plans and counters, the times and sizes, the inputs, versions,
    \\  timing conditions, and the binds with the same secrecy as kv.
    \\  On failure with --format json, stdout stays empty and stderr is
    \\  one JSON object: schema_version, exit_code, and error with code,
    \\  message, and hint (the next step). human and kv keep a text
    \\  error on stderr.
    \\  Timing conditions: each copy gets one warm-up run whose rows were
    \\  compared and that is not timed; the timed rounds alternate
    \\  baseline-variant and variant-baseline (ABBA); a round times
    \\  sqlite3_step from the reset statement to SQLITE_DONE with the
    \\  interrupt checks, and does not read columns or time prepare, bind,
    \\  or the plan read; the cache is warm, since each copy reuses its
    \\  connection and page cache after its file was just written.
    \\  Result rows are compared as a multiset: each distinct row must
    \\  appear the same number of times. Row order is a reference only
    \\  and is not part of the result: rows may change order without
    \\  ORDER BY or among equal ORDER BY keys, and ORDER BY itself is not
    \\  checked.
    \\  Verdict, from the rows read: improved (the rows match and the variant
    \\  reads at least 1% fewer rows, and writes no more), no-effect (the rows
    \\  match and the variant does not, including a smaller reduction, which
    \\  the reasons explain), needs-check (the rows match but the variant reads
    \\  or writes more, with the reasons), or not-judged (the rows differ or
    \\  cannot be compared, with the reasons; --runs 0 is still judged). A
    \\  migration batch calls the needs-check case regressed, and its JSON
    \\  summary counts those queries under needs_check. The
    \\  rows read and rows written use the same counting as local D1
    \\  (workerd patch). They are 32-bit counters that wrap past
    \\  4294967295. With --write, the result rows are the RETURNING rows (none
    \\  without RETURNING) and both copies must also report the same changes
    \\  and total_changes; a difference is a mismatch. The times are a
    \\  reference only and never change the verdict or the exit status. Plan
    \\  labels (kind, covering, automatic) are hints read from SQLite's
    \\  wording; the detail text is what SQLite reported.
    \\
    \\AI agents: use `qenome skill print` or `qenome skill install`.
    \\
;

test "the verdict help names the minimum read gain" {
    const needle = std.fmt.comptimePrint("at least {d}% fewer", .{contract.min_read_gain_percent});
    try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
}
