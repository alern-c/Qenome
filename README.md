# Qenome

English | [日本語](README.ja.md)

Qenome is a CLI that compares one read-only `SELECT` on a local SQLite database before and after one candidate `CREATE INDEX`. It opens the database read-only, copies it into an isolated snapshot, and reports what changed: the result rows, the query plan, the time, and the size increase. The original database is never modified.

## Installation

### Prebuilt binaries (GitHub Releases)

Download an asset from the [Releases](https://github.com/alern-c/Qenome/releases) page, together with the `SHA256SUMS` file from the same release.

Prebuilt binaries are provided for Linux, macOS, and Windows. Release assets are uncompressed binaries named `qenome-<version>-<arch>-<os>` (`qenome-<version>-<arch>-<os>.exe` on Windows). For example:

- `qenome-0.2.0-x86_64-linux`
- `qenome-0.2.0-aarch64-macos`
- `qenome-0.2.0-x86_64-windows.exe`

The release page lists the assets that were built; pick the one whose `<arch>` and `<os>` match your machine. `SHA256SUMS` uses the `sha256sum` format: a SHA-256 hash, two spaces, and the file name.

Verify the download before running it. Replace `0.2.0` and the file name in these examples with the version and asset you downloaded.

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.2.0-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows (PowerShell):

```powershell
Select-String 'qenome-0.2.0-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.2.0-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` must print the same SHA-256 hash as the line from `SHA256SUMS` (uppercase letters are fine).

Then give the binary execute permission (Linux and macOS) and run it:

```sh
chmod +x qenome-0.2.0-aarch64-macos
mv qenome-0.2.0-aarch64-macos qenome
./qenome --version
```

On Windows, run the `.exe` directly.

If macOS refuses to run the binary because it is not notarized, allow it in System Settings → Privacy & Security.

### From source

Qenome needs Zig 0.17.0, the `minimum_zig_version` in `build.zig.zon` (CI builds with exactly this version). SQLite is vendored in `vendor/sqlite3` and compiled in, so no system SQLite is needed.

```sh
zig build
./zig-out/bin/qenome --version
```

`zig build` writes the binary to `zig-out/bin/qenome` (`zig-out\bin\qenome.exe` on Windows). For timings that match a release build, build with `zig build -Doptimize=ReleaseFast`.

## Usage

```sh
qenome app.db select.sql index.sql
qenome app.db select.sql index.sql --bind 1:int:1234
qenome --db app.db --select select.sql --index-sql index.sql --format kv
qenome app.db select.sql index.sql --format json
```

The three paths fill the roles in this order: database, SELECT file, CREATE INDEX file. Each role can also be given with `--db`, `--select`, or `--index-sql`, and the two forms can be mixed; a positional path fills the first role that is still empty. After `--`, every argument is treated as a path, including paths that start with `-`.

`select.sql` holds one read-only `SELECT`; `index.sql` holds one candidate `CREATE INDEX`. Qenome rejects multiple statements, writes, and any other statement.

- `--db <PATH>`: the SQLite database to read (required, once)
- `--select <FILE>`: a file holding the one `SELECT` to compare (required, once)
- `--index-sql <FILE>`: a file holding the one candidate `CREATE INDEX` (required, once)
- `--bind <N>:<TYPE>[:<VALUE>]`: a typed value bound to parameter `N`; repeatable. `N` is SQLite's parameter number: named parameters share the number of their first appearance, and `?NNN` uses `NNN`. `TYPE` is `int`, `real`, `text`, or `null` (null takes no value). Every number in `1..parameter count` must be given exactly once, and a `SELECT` without parameters takes no `--bind`. The value is the rest of the argument, so text may contain `:`.
- `--runs <N>`: timed rounds after the results match; each round times the `SELECT` once per copy. The default is `10`; `0` skips the timing; the maximum is `1000`. A timing that takes longer than a second reports its progress on stderr.
- `--timeout-ms <MS>`: time limit for building the index and for each `SELECT` run; the default is `30000`; `0` disables the limit. The whole run can therefore take up to the database copy plus `(3 + 2 × runs)` time limits.
- `--format <human|kv|json>`: output format (default `human`). See [Output formats](#output-formats).
- `--show-binds`: print the bind values. Without it, `human` leaves the binds out, and `kv` and `json` print only their numbers, types, and text lengths, so the values stay out of logs.
- `--show-rows`: print the example rows that only one copy returned. Without it, every format prints only the counts, so row values stay out of logs; `human` says to rerun with this flag.
- `--help`, `-h`: print the usage and exit with status 0.
- `--version`: print the version from `build.zig.zon` as `qenome <version>` and exit with status 0.

Options that take a value can also be written as `--db=app.db`.

Qenome opens the database read-only and copies it, through SQLite's backup API, into a private directory under `$TMPDIR` (default `/tmp`). The copy is the baseline; a second copy becomes the variant, and the candidate index is built only on the variant. The `SELECT` runs on both copies, and the result rows are compared as a multiset: each distinct row must appear the same number of times. Row order is reported as a reference and is not part of the match.

When the rows match and `--runs` is not `0`, the `SELECT` is timed again on both copies. Each copy gets one warm-up run whose rows were compared and that is not timed. The timed rounds alternate baseline-variant and variant-baseline (ABBA). A round times `sqlite3_step` from the reset statement to `SQLITE_DONE`, including the interrupt checks; it does not read columns and does not time prepare, bind, or the plan read. The cache is warm, since each copy reuses its connection and page cache after its file was just written. The private directory is removed before exit, whatever the result.

The time verdict never changes the exit status.

## Output formats

### human (default)

`--format human` prints what a decision needs:

- a Summary: whether the result rows match, the time verdict with its reasons, whether the plan changed, the median times and rounds, the size increase, and a note when the build is a debug build;
- a side-by-side table of baseline and variant: rows, full-scan steps, VM steps, sort operations and autoindex rows when they are not zero, the p25 and p75 times when timed, and the database file bytes;
- the query plan for both copies, with `kind`, `covering`, and `automatic` as hints read from SQLite's wording.

When the rows differ, cannot be compared, or come in another order, the human output adds an explanation and the one-sided counts. Example rows appear only with `--show-rows`; when they are hidden, the human output says to rerun with that flag. `--show-binds` adds the bind values.

Input paths, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions appear only in `kv` and `json`.

### kv

`--format kv` prints every fact as one `key: value` line, for scripts and logs. It includes the inputs, the SQLite and Zig versions, the build mode, the OS and architecture, the work directory, and the timing conditions, which the human output leaves out. `baseline-only-row` and `variant-only-row` appear only with `--show-rows`.

### json

`--format json` prints one JSON object with a trailing newline after a comparison finishes. When an input is rejected, the time limit is reached, or the run is interrupted, stdout stays empty; read the error on stderr and the exit status. Qenome does not print errors as JSON.

The verdict is in the top-level `verdict` field:

| `verdict` | Meaning |
| --- | --- |
| `improved` | Less work, a median more than 20% lower, and faster in every round |
| `no-effect` | The same plan and counters, with medians within 20% |
| `needs-check` | Anything else; `verdict_reasons` holds the reasons |
| `not-judged` | The rows differ or cannot be compared, or `--runs` is 0; `verdict_reasons` holds the reasons |

Print only the verdict:

```sh
qenome app.db select.sql index.sql --format json | jq -r .verdict
```

In CI, keep the index only when the results match and the verdict is `improved`:

```sh
if qenome app.db select.sql index.sql --format json | jq -e '.result == "match" and .verdict == "improved"' > /dev/null; then
  echo "keep the index"
fi
```

Main keys:

| Key | Contents |
| --- | --- |
| `schema_version` | Version of the output format (currently `1`) |
| `exit_code` | Exit status for the comparison (`0`, `3`, or `4`). If cleanup fails after a match, the JSON is written first and the process exits with `5` instead of `0` |
| `verdict` / `verdict_reasons` | Time verdict and its reasons (`improved` / `no-effect` / `needs-check` / `not-judged`) |
| `result` | Result row comparison (`match` / `mismatch` / `incomparable`) |
| `row_order` | Row order (`same` / `differs` / `not-applicable`). Reference only and not part of the match; `same` or `differs` only when `result` is `match` |
| `result_reasons` | Why the rows cannot be compared. Each element has `text` and `hint` (`null` when there is none) |
| `row_differences` | `baseline_only` and `variant_only` counts. `baseline_only_examples` and `variant_only_examples` are arrays; they stay empty by default, and `--show-rows` fills them with up to 5 example rows |
| `plan_changed` | Whether the query plan differs between baseline and variant |
| `baseline` / `variant` | `rows`; `plan` (`id`, `parent`, `kind`, `covering`, `automatic`, `detail`); `counters` (`fullscan_steps`, `vm_steps`, `sort_ops`, `autoindex_rows`) |
| `timing` | `rounds`, `variant_faster_rounds`, `ratio`, and `baseline` / `variant` with `median_ns`, `p25_ns`, `p75_ns`, `min_ns`, `max_ns`. `null` when not timed; `ratio` is `null` when the baseline median is `0` |
| `size_bytes` | `baseline`, `variant`, and `increase` (the whole database file, not the index alone) |
| `inputs` | `database`, `select`, and `index_sql` paths |
| `environment` | `qenome_version` (the same version as `--version`, from `build.zig.zon`), `sqlite_version`, `sqlite_source_id`, `zig_version`, `build_mode`, `os`, `arch`, `work_dir_parent` |
| `measurement` | Timing conditions: `runs_per_copy` (timed rounds per copy; `0` when not timed), `warmup`, `order`, `scope`, `cache` |
| `binds` | `number` and `type`; text also has `text_bytes`. `value` appears only with `--show-binds` |

- String values write a backslash as `\\` and each byte that is not valid UTF-8 as `\xNN` (byte 0xFF becomes `\xff`), and the result is then escaped as JSON. A literal four-character `\xff` therefore becomes `\\xff` and is a different string from the byte 0xFF. To recover the original bytes, read `\\` as one backslash and `\xNN` as that byte, and leave everything else as it is. Paths, plan details, reasons, and bind text use this rule. Text values in the example rows use it too, surrounded by single quotes (for example `'\xff'`, which appears as `'\\xff'` in the JSON text); BLOBs are written as `x'00ff'`. Example values longer than 200 bytes are cut and followed by `...(N bytes)`.
- `binds` keeps the same secrecy as kv. Without `--show-binds`, only the number, the type, and the text length appear. A non-finite real value (`inf` or `-inf`) is written as a string, because JSON numbers cannot represent it.
- `row_differences` always has both counts. The example array keys are always present but empty unless `--show-rows` is set; human and kv use the same flag and print only the counts by default.
- `row_order` is a reference, not part of the result match.

### Exit status

| Code | Meaning |
| --- | --- |
| 0 | The result rows match |
| 1 | An input was rejected (unreadable file, invalid or rejected SQL, bind mismatch, index creation failure) |
| 2 | A usage error |
| 3 | The result rows differ |
| 4 | The results cannot be compared |
| 5 | Cleanup failed after the comparison (this replaces 0; every other code is kept) |
| 124 | A time limit was reached (`--timeout-ms`) |
| 129 / 130 / 143 | Interrupted by `SIGHUP` / `SIGINT` / `SIGTERM` (POSIX) |

`--format json` reports the comparison result in `exit_code` as `0`, `3`, or `4`. The process can still exit with `5` after writing the JSON.

## Rules

- Do not change the original database (open it read-only).
- Never report a result that cannot be compared as a match or a success.
- Never judge an improvement by time alone; check the plan and the counters as well.
- The size is the increase of the whole database file, not the size of the index alone.
- Reject multiple statements, writes, and dangerous DDL.
- Clean up connections and temporary files on success, failure, and interruption.

## Development checks

```sh
zig fmt --check .
zig build
zig build test
python3 scripts/test_check_comments.py
python3 scripts/check_comments.py
python3 scripts/test_check_architecture.py
python3 scripts/check_architecture.py
```

The codebase carries no comments: explanations live in the README, and the checks are the source of truth for the rules they enforce.

## License

Qenome is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
