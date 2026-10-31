# Architecture

The target dependency order is:

`contract → sqlite → sql → engine → measure → verdict → sandbox → modes → report → cli → main`

A lower layer never imports a higher one. `d1/` and `skill/` are independent components outside the chain: each sits at the rank of the layer it may import, and the layers above that rank may import it. Modes only return report data; only `report/` and `cli/` write to stdout or stderr.

Folders and files that exist now (v0.3.7):

| Layer | Path |
| --- | --- |
| contract | `src/contract/` |
| sqlite | `src/sqlite.zig` |
| sql | `src/sql/` |
| engine | `src/db.zig`, `src/result.zig` |
| cli | `src/cli.zig`, `src/cli/` |
| main | `src/main.zig`, `src/root.zig` |
| d1 (independent) | `src/d1/` |

Planned for v0.3.8: split `src/db.zig` into `src/engine/*`, move measure, verdict and sandbox out of `src/cli/`, move the remaining D1 code into `src/d1/`, and split the report out of `src/cli/report.zig`. Planned for v0.3.9: add `src/modes/`, replace the parsed arguments with a `Command` union, and split `src/cli/tests.zig`.

The source of truth for these boundaries is `scripts/check_architecture.py`; its self-test is `scripts/test_check_architecture.py`. The script owns `APPROVED_FILES` (the only files allowed under `src/`), the import table for every file, `LAYERS` (which layer each folder or file belongs to), `LINE_LIMITS` (the recorded line count of the largest files) with `MAX_LINES` (the cap for a file the table does not list), `WRITE_ALLOWED` with `WRITE_DEBT` (where stdout and stderr may be written), and the contract values and codes. Add the file or folder to these tables whenever you add one; an unclassified file fails the check.

The contract values (JSON schema versions, exit codes and warning codes) are defined only in `src/contract/values.zig`. Use an import from there; a second definition, including a second copy of a code string, fails the check. `ExitCode` may stay as an alias of the contract type.
