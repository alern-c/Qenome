# Installation

## npm

On Linux and macOS, for x64 and arm64, install the command once:

```sh
npm install -g qenome
qenome --version
```

The global install puts `qenome` on your `PATH`, so the examples below run as written. Update it with `npm install -g qenome@latest`.

To try Qenome without installing it, run it through `npx`, which fetches the package and adds no global command:

```sh
npx qenome --version
```

Install it once if you run Qenome often; use `npx qenome` for a one-off check on a D1 project. When the binary is not on your `PATH`, replace `qenome` with `npx qenome` in the examples.

The package is a small launcher plus one optional binary for the machine you are on (`@qenome-cli/linux-x64`, `@qenome-cli/linux-arm64`, `@qenome-cli/darwin-x64`, or `@qenome-cli/darwin-arm64`). The version is `.version` in `build.zig.zon`, and [docs/npm.md](npm.md) covers how the packages are built and published. Windows is not an npm target: use the prebuilt binaries below.

## Prebuilt binaries (GitHub Releases)

Download an asset from the [Releases](https://github.com/alern-c/Qenome/releases) page, together with the `SHA256SUMS` file from the same release.

Prebuilt binaries are provided for Linux, macOS, and Windows. Release assets are uncompressed binaries named `qenome-<version>-<arch>-<os>` (`qenome-<version>-<arch>-<os>.exe` on Windows). For example:

- `qenome-0.3.7-x86_64-linux`
- `qenome-0.3.7-aarch64-macos`
- `qenome-0.3.7-x86_64-windows.exe`

The release page lists the assets that were built; pick the one whose `<arch>` and `<os>` match your machine. `SHA256SUMS` uses the `sha256sum` format: a SHA-256 hash, two spaces, and the file name.

Verify the download before running it. Replace `0.3.7` and the file name in these examples with the version and asset you downloaded.

<details>
<summary>Show the checksum commands for Linux, macOS, and Windows</summary>

Linux:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

macOS:

```sh
grep 'qenome-0.3.7-aarch64-macos$' SHA256SUMS | shasum -a 256 -c
```

Windows (PowerShell):

```powershell
Select-String 'qenome-0.3.7-x86_64-windows.exe$' SHA256SUMS
Get-FileHash .\qenome-0.3.7-x86_64-windows.exe -Algorithm SHA256
```

`Get-FileHash` must print the same SHA-256 hash as the line from `SHA256SUMS` (uppercase letters are fine).

</details>

Then give the binary execute permission (Linux and macOS) and run it:

```sh
chmod +x qenome-0.3.7-aarch64-macos
mv qenome-0.3.7-aarch64-macos qenome
./qenome --version
```

On Windows, run the `.exe` directly.

If macOS refuses to run the binary because it is not notarized, allow it in System Settings → Privacy & Security.

## From source

To build the binary from source, follow [Build from source](../CONTRIBUTING.md#build-from-source). It needs Zig 0.17.0; SQLite is vendored, so no system SQLite is needed.
