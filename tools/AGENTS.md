# tools

## Purpose

Release packaging for the addon. Bundles the shippable files into a distributable zip that extracts straight into `Interface/AddOns`.

## Ownership

Owns build/release scripts only. The addon runtime and TOC contracts live in the addon root.

## Local Contracts

- `build-release.js` is zero-dependency Node: it hand-rolls the zip (Node `zlib` deflate + a CRC32 table), so it must stay free of npm dependencies.
- Ships only root `*.lua`, `*.toc`, and `README.md`. Assets and docs (`*.png`, `*.svg`, `CHANGELOG.md`) are intentionally excluded — if a new file must ship, widen the `shipped` filter.
- Output is `Qwesty-<version>.zip` written into `builds/` (disposable), with every entry nested under a top-level `Qwesty/` folder.
- Version comes from the `## Version` line in the root `.toc`. The `ADDON_NAME` constant must match the addon folder name (`Qwesty`).
- The zip name deliberately carries **no** interface/client version. One build serves every client listed in `## Interface`, so the release is identified by addon version alone; client compatibility is upload metadata, not part of the filename.

## Work Guidance

Run from the addon root:

- `node tools/build-release.js` — writes the zip into `builds/`.
- `node tools/build-release.js -o <dir>` — writes it elsewhere.

## Verification

Run the build and confirm it prints the expected file list and version, then that the named zip exists in the output dir.
