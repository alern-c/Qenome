# npm への公開

`npx qenome` で配る。版の正本は `build.zig.zon` の `.version` だけ。`npm/*/package.json` の `version` は `0.0.0`、`private` は `true` のままリポジトリに置く。`python3 scripts/stage_npm.py` が公開用のディレクトリを `dist/npm/` に作り、そのとき版を書き込む。

## パッケージ

| ディレクトリ | npm の名前 | 中身 |
| --- | --- | --- |
| `npm/qenome` | `qenome` | Node のランチャー（`bin` は `qenome`）、`qenome/d1` で公開する記録用の `lib/d1.mjs`、`qenome skill install` が使う `skills/qenome/SKILL.md` |
| `npm/linux-x64` | `@qenome-cli/linux-x64` | Linux x64 のバイナリ |
| `npm/linux-arm64` | `@qenome-cli/linux-arm64` | Linux arm64 のバイナリ |
| `npm/darwin-x64` | `@qenome-cli/darwin-x64` | macOS x64 のバイナリ |
| `npm/darwin-arm64` | `@qenome-cli/darwin-arm64` | macOS arm64 のバイナリ |

ランチャーの `optionalDependencies` に4つのバイナリパッケージを、`build.zig.zon` と同じ版で書く。`package.json` の `files` に `lib` と `skills` を入れ、`exports` の `./d1` を `./lib/d1.mjs` に向ける。`scripts/stage_npm.py` は `lib/d1.mjs` と `skills/qenome/SKILL.md` を公開用ツリーに写し、`npm pack` の tarball にそれらが入っていることを確かめる。各バイナリパッケージは `os` と `cpu` を持つので、npm はそのマシンに合うものだけを入れる。ランチャーは `process.platform` と `process.arch` から `@qenome-cli/<platform>-<arch>` を探し、その中の `bin/qenome` を起動する。

この形は esbuild と biome と同じ。一つのパッケージに全バイナリを入れると、使わない OS のバイナリまで落ちる。postinstall でダウンロードすると、npm 以外の配布場所が要る。optionalDependencies なら `npx qenome` の1回で足りる。

Linux は gnu と musl に分けない。Zig の `x86_64-linux-musl` と `aarch64-linux-musl` は libc を静的リンクするので、Ubuntu でも Alpine でも同じ1個で動く。ビルドフラグは GitHub Releases と同じ `ReleaseSafe` と strip。Windows 向けの npm パッケージは作らない。Windows は GitHub Releases のアセットを使う。

## CI

`.github/workflows/npm.yml` は pull request と `main` への push で動く。Ubuntu 上で4ターゲットをクロスコンパイルし、各パッケージで `npm pack` と `npm publish --dry-run` を行う。レジストリへは送らない。作った tarball を次の runner に入れ、`npm install --offline` のあと `npx qenome --version` を実行する。

pull request では、変更がパッケージのバイナリ・マニフェスト・同梱ファイル・ビルド入力のどれにも触れないとき、`pack` と `smoke` のジョブは成功のまま、ビルド・pack・upload・download を飛ばして理由をログに出す。`main` への push と、変更の検出に失敗したときは常に全部動かす。

- `ubuntu-latest`（Linux x64）
- `ubuntu-24.04-arm`（Linux arm64）
- `macos-latest`（macOS arm64）
- `macos-15-intel`（macOS x64）

## 最初の公開

Trusted Publishing は、npmjs.com にパッケージが既にあるときだけ設定できる。最初の1回は、リポジトリにも GitHub Actions の secrets にもトークンを置かず、手元で公開する。

1. 出したい版が `build.zig.zon` に入った `main` をチェックアウトする。`npm/*/package.json` は編集しない。
2. Zig が `minimum_zig_version` と一致していることを確認し、`python3 scripts/stage_npm.py` を実行する。
3. `npm login` する。アカウントは `alern-c` で、org `qenome-cli` に公開できること。
4. プラットフォームを先に、ランチャーを最後に公開する。

```sh
npm publish --access public dist/npm/darwin-arm64
npm publish --access public dist/npm/darwin-x64
npm publish --access public dist/npm/linux-arm64
npm publish --access public dist/npm/linux-x64
npm publish --access public dist/npm/qenome
```

5. 公開した5パッケージそれぞれについて、npmjs.com のパッケージ設定で Trusted Publisher を追加する。値は5つとも同じ。

- GitHub Actions
- Organization or user: `alern-c`
- Repository: `Qenome`
- Workflow filename: `publish-npm.yml`（ファイル名だけ。パスは書かない）
- Environment name: 空欄
- Allowed actions: `npm publish` を許可する。2026-09-03 より後に作った設定は、初期状態では `npm stage publish` だけが許可される。直接公開するには `npm publish` を明示して選ぶ。

設定を作ってから2日以内に、その設定での最初の公開を成功させる。過ぎると設定は失効するので、消して作り直す。

## 2回目以降

1. `build.zig.zon` の `.version` を上げる。changelog、タグ、GitHub Release は、これまで通りのリリース手順で出す。`npm/*/package.json` は編集しない。
2. そのコミットが `main` の先頭になり、タグ `v` + `.version` がそのコミットを指し、同じタグの GitHub Release ができてから、Actions の `publish-npm` を手動実行する。選ぶブランチは `main`。
3. ワークフローは先に `quality.yml` と同じ検査をそのコミットで実行する。失敗したらパッケージのビルドと npm への公開は始まらない。通ったあと、OIDC で公開し、provenance を付ける。`NPM_TOKEN` と `NODE_AUTH_TOKEN` は見ると中止する。プラットフォームを先に公開し、ランチャーを最後にする。同じ版が既にあるパッケージは飛ばす。途中で失敗したら、`main` がそのコミットのままなら同じワークフローを再実行できる。
4. 公開のあと、5パッケージがその版でレジストリに見えるまで待ち、各 tarball にバイナリが入っていることを確かめ、`npx qenome@<version>` で improved の比較を1回実行する。比較が失敗したら公開ジョブは失敗する。
5. `main` 以外、タグと Release が一致しないコミット、品質検査が失敗したコミットでは公開しない。pull request ではこのワークフローは動かない。タグを打っただけでは npm には出さない。

provenance には、リポジトリが public であることが要る。`actions/setup-node` に `registry-url` を付けない。付けると空のトークンが `.npmrc` に入り、OIDC より先に使われることがある。

`scripts/publish_npm.py` は、`--publish` が無く、GitHub Actions の OIDC が無く、または npm トークンがあるときは、レジストリへ送る前に止まる。
