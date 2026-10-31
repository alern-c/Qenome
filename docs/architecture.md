# Architecture

The target dependency order is:

`contract → sqlite → sql → engine → measure → verdict → sandbox → modes → report → cli → main`

A lower layer never imports a higher one. `d1/` and `skill/` are independent components outside the chain: each sits at the rank of the layer it may import, and the layers above that rank may import it. Modes only return report data; only `report/` and `cli/` write to stdout or stderr.

Folders and files that exist now (v0.3.9):

| Layer | Path |
| --- | --- |
| contract | `src/contract/` |
| sqlite | `src/sqlite.zig` |
| sql | `src/sql/` |
| engine | `src/db.zig`, `src/result.zig` |
| report | `src/report/` |
| cli | `src/cli.zig`, `src/cli/` |
| main | `src/main.zig`, `src/root.zig` |
| d1 (independent) | `src/d1/` |
| skill (independent) | `src/skill/` |

The report layer holds `model.zig` (the data the writers take), `format.zig` (counts, durations, sizes, text wrapping and the text shared by the writers), `human.zig`, `kv.zig`, `json.zig`, `batch_writes.zig`, `time.zig`, `scale.zig` and the six test files next to them. It takes plain data: the header carries `db.BindArg` binds, the D1 fields it prints and the tool version, so it does not import `src/cli/args.zig` or `src/cli/d1.zig`.

`src/cli/scale.zig` runs `--scale`: it scales the seed spec, runs the pair comparison once per step on fresh copies, and hands the steps to `src/report/scale.zig`. The step size is checked against the seed limits before a copy is made.

The report layer still imports `src/cli/comparison.zig`, `src/cli/timing.zig` and `src/cli/warnings.zig`. They are the measure, verdict and sandbox layers in the target order and move out of `src/cli/` with that work; `PENDING_MOVE_IMPORTS` in `scripts/check_architecture.py` lists them until then. Remove that list when those files move.

Planned next: split `src/db.zig` into `src/engine/*`, move measure, verdict and sandbox out of `src/cli/`, move the remaining D1 code into `src/d1/`, add `src/modes/`, replace the parsed arguments with a `Command` union, and split `src/cli/tests.zig`.

The source of truth for these boundaries is `scripts/check_architecture.py`; its self-test is `scripts/test_check_architecture.py`. The script owns `APPROVED_FILES` (the only files allowed under `src/`), the import table for every file, `LAYERS` (which layer each folder or file belongs to), `LINE_LIMITS` (the recorded line count of the largest files) with `MAX_LINES` (the cap for a file the table does not list), `WRITE_ALLOWED` with `WRITE_DEBT` (where stdout and stderr may be written), `PENDING_MOVE_IMPORTS` (the temporary lower-layer imports), and the contract values and codes. Add the file or folder to these tables whenever you add one; an unclassified file fails the check.

The contract values (JSON schema versions, exit codes and warning codes) are defined only in `src/contract/values.zig`. Use an import from there; a second definition, including a second copy of a code string, fails the check. `ExitCode` may stay as an alias of the contract type.
