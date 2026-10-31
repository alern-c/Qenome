# Use with AI agents

An agent that changes a D1 schema should run Qenome before it keeps a `CREATE INDEX`. The instructions are [skills/qenome/SKILL.md](../skills/qenome/SKILL.md): when to run, how to pass `--d1` and `--config`, how to read `schema_version` 2, and what to do with exit codes and warnings.

Point the agent at that file. `--format json` is the machine-readable report, specified in [docs/json.md](json.md).

Install the skill into an agent's skills directory:

```sh
npx qenome skill install
```

It copies `skills/qenome/SKILL.md` into each detected agent directory: Claude Code (`~/.claude/skills/qenome/`) and the cross-agent location that Codex, Cursor, and Gemini CLI read (`~/.agents/skills/qenome/`). `--project` writes under the current directory instead, `--target claude` or `--target agents` picks one, `--dry-run` shows what would change, and `--yes` overwrites without asking. `qenome skill status` shows whether the installed copy is up to date, `qenome skill uninstall` removes only the copy that qenome installed, and `qenome skill print` writes the skill to stdout.

Without qenome, the skills CLI installs the same file from GitHub:

```sh
npx skills add alern-c/Qenome --skill qenome -g
```

The npm package ships `skills/`, so the same file is also inside `npx qenome`.
