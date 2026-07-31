# tools

## Purpose

Release packaging for the addon. Bundles the shippable files into a distributable zip that extracts straight into `Interface/AddOns`.

## Ownership

Owns build/release scripts only. The addon runtime and TOC contracts live in the addon root.

## Local Contracts

- `build-release.js` is zero-dependency Node: it hand-rolls the zip (Node `zlib` deflate + a CRC32 table), so it must stay free of npm dependencies.
- Ships only root `*.lua`, `*.toc`, and `README.md`. Assets and docs (`*.png`, `*.svg`, `CHANGELOG.md`) are intentionally excluded — if a new file must ship, widen the `shipped` filter.
- Output is `Qwesty-<version>-<interface>.zip` written into `builds/` (disposable), with every entry nested under a top-level `Qwesty/` folder.
- Both halves of the name come from the root `.toc`: `<version>` from `## Version`, `<interface>` from `## Interface`. When `## Interface` lists several clients, the **highest** value is used, so the zip is named after the newest client it supports. The `ADDON_NAME` constant must match the addon folder name (`Qwesty`).

## Work Guidance

Run from the addon root:

- `node tools/build-release.js` — writes the zip into `builds/`.
- `node tools/build-release.js -o <dir>` — writes it elsewhere.

## Verification

Run the build and confirm it prints the expected file list and version, then that the named zip exists in the output dir.
