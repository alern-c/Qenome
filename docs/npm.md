# Publishing to npm

The packages are distributed with `npx qenome`. The only source of truth for the version is `.version` in `build.zig.zon`. Keep `version` at `0.0.0` and `private` at `true` in `npm/*/package.json`, and keep those files in the repository. `python3 scripts/stage_npm.py` creates the publish tree under `dist/npm/` and writes the version into it at that time.

## Packages

| Directory | npm name | Contents |
| --- | --- | --- |
| `npm/qenome` | `qenome` | The Node launcher (`bin` is `qenome`), the recording module `lib/d1.mjs` published as `qenome/d1`, and `skills/qenome/SKILL.md` used by `qenome skill install` |
| `npm/linux-x64` | `@qenome-cli/linux-x64` | The Linux x64 binary |
| `npm/linux-arm64` | `@qenome-cli/linux-arm64` | The Linux arm64 binary |
| `npm/darwin-x64` | `@qenome-cli/darwin-x64` | The macOS x64 binary |
| `npm/darwin-arm64` | `@qenome-cli/darwin-arm64` | The macOS arm64 binary |

The launcher lists the four binary packages in `optionalDependencies` at the same version as `build.zig.zon`. Its `package.json` includes `lib` and `skills` in `files`, and points the `./d1` export at `./lib/d1.mjs`. `scripts/stage_npm.py` copies `lib/d1.mjs` and `skills/qenome/SKILL.md` into the publish tree and checks that they are in the `npm pack` tarballs. Each binary package has `os` and `cpu`, so npm installs only the one that matches the machine. The launcher looks up `@qenome-cli/<platform>-<arch>` from `process.platform` and `process.arch`, and runs the `bin/qenome` inside it.

This is the same shape as esbuild and biome. One package with every binary would install binaries for operating systems the machine does not use. Downloading in postinstall would need a distribution location outside npm. With `optionalDependencies`, one `npx qenome` is enough.

Linux is not split into gnu and musl. Zig's `x86_64-linux-musl` and `aarch64-linux-musl` link libc statically, so one binary runs on both Ubuntu and Alpine. The build flags are the same `ReleaseSafe` and strip as GitHub Releases. There is no npm package for Windows; Windows uses the GitHub Releases assets.

## CI

`.github/workflows/npm.yml` runs on pull requests and pushes to `main`. It cross-compiles the four targets on Ubuntu and runs `npm pack` and `npm publish --dry-run` for each package. It does not send anything to the registry. It passes the tarballs it built to the next runner, installs them with `npm install --offline`, and runs `npx qenome --version`.

On a pull request, when the change touches none of the package binaries, manifests, bundled files or build inputs, the `pack` and `smoke` jobs stay successful, skip the build, pack, upload and download, and log the reason. A push to `main`, or a failure to detect the change, always runs everything.

- `ubuntu-latest` (Linux x64)
- `ubuntu-24.04-arm` (Linux arm64)
- `macos-latest` (macOS arm64)
- `macos-15-intel` (macOS x64)

## First publish

Trusted Publishing can be configured only after the packages already exist on npmjs.com. For the first publish, put no token in the repository or in GitHub Actions secrets, and publish locally.

1. Check out `main` with the version you want to publish in `build.zig.zon`. Do not edit `npm/*/package.json`.
2. Confirm that Zig matches `minimum_zig_version`, and run `python3 scripts/stage_npm.py`.
3. Run `npm login`. The account is `alern-c`, and it must be allowed to publish to the `qenome-cli` org.
4. Publish the platform packages first and the launcher last.

```sh
npm publish --access public dist/npm/darwin-arm64
npm publish --access public dist/npm/darwin-x64
npm publish --access public dist/npm/linux-arm64
npm publish --access public dist/npm/linux-x64
npm publish --access public dist/npm/qenome
```

5. For each of the five published packages, add a Trusted Publisher in the package settings on npmjs.com. The values are the same for all five.

- GitHub Actions
- Organization or user: `alern-c`
- Repository: `Qenome`
- Workflow filename: `publish-npm.yml` (the filename only; do not include the path)
- Environment name: empty
- Allowed actions: allow `npm publish`. Settings created after 2026-09-03 allow only `npm stage publish` by default. To publish directly, explicitly select `npm publish`.

Make the first publish with the setting succeed within two days of creating it. After that the setting expires; delete it and create it again.

## Later publishes

1. Raise `.version` in `build.zig.zon`. Create the changelog, tag and GitHub Release with the usual release steps. Do not edit `npm/*/package.json`.
2. Push the tag `v` + `.version` at the commit that raises `.version` in `build.zig.zon` and is the tip of `main`. After `release.yml` creates the GitHub Release, `publish-npm` starts automatically. It starts only when the `release.yml` run was started by a tag push, succeeded, and is at the commit being published. If `release.yml` failed, if it was started by `workflow_dispatch`, or if you publish by hand, wait until that commit is the tip of `main` with the tag and Release in place, then run `gh workflow run publish-npm.yml --ref main`.
3. The workflow first runs the same checks as `quality.yml` on that commit. If they fail, the package build and the npm publish do not start. After they pass, it publishes with OIDC and adds provenance. It stops if it sees `NPM_TOKEN` or `NODE_AUTH_TOKEN`. It publishes the platform packages first and the launcher last. It skips a package that already has the same version. If a step fails and `main` is still at that commit, the same workflow can be run again.
4. After publishing, it waits until all five packages are visible on the registry at that version, checks that each tarball contains its binary, and runs the improved comparison once with `npx qenome@<version>`. If the comparison fails, the publish job fails.
5. Nothing is published for a commit that is not the tip of `main`, whose tag and Release do not match, or whose quality checks failed. This workflow does not run on pull requests. The automatic start uses the default-branch copy of `publish-npm.yml`, so a tag pushed before this workflow change is on `main` does not start it. A failed `release.yml` run, or a `release.yml` run started by `workflow_dispatch`, does not publish automatically.

Provenance requires the repository to be public. Do not set `registry-url` on `actions/setup-node`. If you do, an empty token goes into `.npmrc` and can be used before OIDC.

`scripts/publish_npm.py` stops before sending anything to the registry when `--publish` is missing, when GitHub Actions OIDC is missing, or when an npm token is present.
