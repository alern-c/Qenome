# Why not ...

**EXPLAIN QUERY PLAN.** The plan says whether SQLite expects to touch an index. It does not run the `SELECT` on a copy of the data, so it cannot show that the result rows changed, how many rows were read or written, or how much the database file grew. Qenome runs the statement on both sandbox copies and counts with the same counting as local D1 (workerd patch).

**`wrangler d1 execute --local`.** A local wrangler command can print one duration for the whole call. That duration moves from run to run, and wrangler does not build your candidate index on a copy and compare it with the current schema. Qenome leaves the original database unchanged and judges the index from the row counts. The times are a reference next to that verdict.

**Production D1 metrics.** The numbers have not yet been checked against production D1. Qenome measures the local database only.

**Applying the index and watching the app.** That writes the index into the database you ship. Qenome tries it on a sandbox copy, so a candidate that does not help can be dropped before the merge.
