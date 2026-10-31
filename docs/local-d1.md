# Check a local D1

Use this when the database is a local Cloudflare D1 and you want a verdict before merging an index. You need Node.js for `npx`, a wrangler project, and two SQL files: one `SELECT`, one `CREATE INDEX`.

If the local database does not exist yet, create it once. `DB` is the `d1_databases` binding name:

```sh
npx wrangler d1 execute DB --local --command "SELECT 1"
```

From that project directory:

```sh
npx qenome --d1 DB select.sql index.sql --runs 0 --format json
```

`--runs 0` skips the timing and still returns the verdict. Exit status `0` means the result rows match. Read `verdict` in the JSON: `improved` means the variant read fewer rows, `no-effect` means it did not, and `needs-check` means it read or wrote more. The numbers use the same counting as local D1 (workerd patch). The numbers have not yet been checked against production D1.

`--config <PATH>` names a wrangler file outside the current directory. The lookup rules are in [D1 local databases](usage.md#d1-local-databases). The JSON fields are in [docs/json.md](json.md).

A worked sample with a `wrangler.toml` is in [Try the sample project](usage.md#try-the-sample-project).
