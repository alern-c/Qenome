# Rules

- Do not change the original database (open it read-only). `--write` runs only on the sandbox copies, inside a transaction that is rolled back.
- Never report a result that cannot be compared as a match or a success.
- Judge from the rows read, not from the time. `improved` needs a read reduction of at least 1% of the baseline rows read; a smaller reduction is `no-effect`. A write that writes more rows is `needs-check` even when it reads fewer rows.
- Check the verdict against the known-answer corpus in [testdata/accuracy/](../testdata/accuracy/): every change must keep `python3 scripts/check_accuracy.py` green, and a new rule needs a case.
- The size is the increase of the whole database file, not the size of the index alone. A `--migration` run measures the bytes in use instead, so a dropped index reports the freed bytes as a negative value.
- Reject multiple statements, writes outside `--write`, and dangerous DDL. A `--migration` file may hold several index and table changes, but only `CREATE INDEX`, `CREATE UNIQUE INDEX`, `DROP INDEX`, `CREATE TABLE` (not `AS SELECT`), and `ALTER TABLE` (ADD / RENAME / DROP COLUMN and RENAME TO). Data changes, `DROP TABLE`, `ATTACH`, `PRAGMA`, and other statements are rejected.
- Clean up connections and temporary files on success, failure, and interruption.
- Do not guess a D1 database file: stop when the binding does not resolve to exactly one file.
