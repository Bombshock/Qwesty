# Changelog

All notable changes to Qwesty are documented here.

## [1.1] - 2026-08-01

**Preparation for patch 12.1 — no new features.** This release exists so Qwesty is ready when 12.1 lands; how it accepts and turns in quests is unchanged.

### Changed
- **Runs on both the live client and the 12.1 PTR** — the TOC now declares both (`120007, 120100`), so this single build loads without an "out of date" flag on either, and will keep working the day 12.1 goes live with no update needed. The addon previously still declared `120000`, so it had been showing as out of date on the live client; that is fixed as a side effect.

### Added
- **Release packaging** — `tools/build-release.js` bundles the shippable files into `builds/Qwesty-<version>.zip`, matching the other addons. Zero dependencies; run `node tools/build-release.js` from the addon root.

## [1.0] - 2026-06-28

### Added
- Initial release of **Qwesty**.
- Automatic quest accepting and turning in, deliberately never choosing between multiple dialog options so branching quests are always left to you.
- A checkbox on the gossip frame to toggle automation without leaving the quest window.
