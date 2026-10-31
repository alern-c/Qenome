# インストール

## npm

Linux と macOS の x64 と arm64 では、次の1回でコマンドをインストールできます。

```sh
npm install -g qenome
qenome --version
```

グローバルにインストールすると `qenome` が `PATH` に入るので、下の例はそのまま実行できます。更新は `npm install -g qenome@latest` です。

インストールせずに試すときは `npx` で実行します。`npx` はその実行のためにパッケージを取得し、グローバルにはコマンドを追加しません。

```sh
npx qenome --version
```

Qenome をよく使うなら1回インストールし、D1 プロジェクトで一時的に調べるときは `npx qenome` を使います。バイナリが `PATH` に無いときは、下の例の `qenome` を `npx qenome` に置き換えてください。

入るのは小さなランチャーと、そのマシン向けのバイナリ1つです（`@qenome-cli/linux-x64`、`@qenome-cli/linux-arm64`、`@qenome-cli/darwin-x64`、`@qenome-cli/darwin-arm64` のいずれか）。版は `build.zig.zon` の `.version` で、組み立てと公開の手順は [docs/npm.md](../npm.md) にあります。Windows は npm の対象外なので、下のビルド済みバイナリを使ってください。

## ビルド済みバイナリ（GitHub Releases）

[Releases](https://github.com/alern-c/Qenome/releases) ページから、使う環境のアセットと、同じリリースの `SHA256SUMS` をダウンロードします。

配布するアセットは圧縮していないバイナリで、名前は `qenome-<version>-<arch>-<os>`（Windows は `qenome-<version>-<arch>-<os>.exe`）です。例:

- `qenome-0.3.8-x86_64-linux`
- `qenome-0.3.8-aarch64-macos`
- `qenome-0.3.8-x86_64-windows.exe`

ビルド済みバイナリは Linux・macOS・Windows 向けに提供します。リリースページに、そのリリースでビルドしたアセットが並ぶので、`<arch>` と `<os>` が自分の環境に合うものを選んでください。`SHA256SUMS` は sha256sum 形式（SHA-256 のハッシュ、半角スペース2個、ファイル名）です。

実行する前にダウンロードを検証します。次の例では、`0.3.8` とファイル名を、ダウンロードした版とアセットに置き換えてください。

<details>
<summary>Linux・macOS・Windows のチェックサム確認コマンドを表示</summary>

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.3.8-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows（PowerShell）:

```powershell
Select-String 'qenome-0.3.8-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.3.8-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` のハッシュが、`SHA256SUMS` の該当行と同じであることを確認してください（大文字・小文字は問いません）。

</details>

次に実行権限を付けて実行します（Linux・macOS）。

```sh
chmod +x qenome-0.3.8-aarch64-macos
mv qenome-0.3.8-aarch64-macos qenome
./qenome --version
```

Windows では `.exe` をそのまま実行できます。

macOS で、公証されていないバイナリという理由で実行を拒否された場合は、システム設定 → プライバシーとセキュリティで許可してください。

## ソースからビルド

ソースからビルドする手順は [CONTRIBUTING.md](../../CONTRIBUTING.md) の [Build from source](../../CONTRIBUTING.md#build-from-source) にあります。Zig 0.17.0 が必要で、SQLite は同梱しているためシステムの SQLite は不要です。
