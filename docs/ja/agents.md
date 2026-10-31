# AI エージェントと使う

D1 のスキーマを変えるエージェントは、`CREATE INDEX` を残す前に Qenome を実行します。手順は [skills/qenome/SKILL.md](../../skills/qenome/SKILL.md) です。いつ実行するか、`--d1` と `--config` の渡し方、`schema_version` 2 の読み方、終了コードと warnings への対応が書いてあります。

エージェントにはそのファイルを渡してください。機械が読む報告は `--format json` で、仕様は [docs/json.md](../json.md) です。

AI エージェントのスキルディレクトリへインストールします。

```sh
npx qenome skill install
```

`skills/qenome/SKILL.md` を、検出したエージェントのディレクトリへコピーします。Claude Code は `~/.claude/skills/qenome/`、Codex・Cursor・Gemini CLI が読む共通の場所は `~/.agents/skills/qenome/` です。`--project` はカレントディレクトリ側へ書き、`--target claude` と `--target agents` は対象を選び、`--dry-run` は変更内容の表示だけ、`--yes` は確認なしで上書きします。`qenome skill status` はインストール済みのコピーが最新かを表示し、`qenome skill uninstall` は qenome が入れたコピーだけを削除します。`qenome skill print` はスキルを標準出力へ書きます。

qenome を使わない場合は、skills CLI でも同じファイルを GitHub から入れられます。

```sh
npx skills add alern-c/Qenome --skill qenome -g
```

npm パッケージにも `skills/` が入っているので、同じファイルは `npx qenome` のパッケージ内にもあります。
