# Changelog

Versions before 2.7.0 are upstream's (LocalPlayer123); their notes are in
`docs/PLAYER_README.txt` under "NEW IN".

## 2.7.0 - 2026-10-29

First release of the fork. The game code is 2.6.9, unchanged.

**Players**
- One-click setup: `INSTALL.cmd` finds the game through Steam (every library,
  any drive), checks `BlackOps3.exe` is build `0x06531394`, installs ezz BOIII
  3.0.0 when `boiii.exe` is missing or older (downloaded from the ezz GitHub
  release, SHA-256 verified, old file kept as `.bak`), copies the plugin and
  the three `ui_scripts`, renames a leftover `XINPUT9_1_0.dll` from mod 2.0,
  verifies the zip's own files against `SHA256SUMS.txt`, and creates a desktop
  shortcut that runs `boiii.exe -launch`. Re-running updates. Run from a
  source checkout, it fetches the newest release zip instead.
- `CHECK.cmd`: read-only diagnosis (game build, ezz version, every mod file,
  `boiii_players\plugins.log` of the last start, newest crash dump,
  controllers Windows sees). `UNINSTALL.cmd` removes the mod, keeps ezz.
- Setup logs to `%LOCALAPPDATA%\BO3-Splitscreen-4P\setup.log`.
- The in-game update notice checks this fork's releases and names
  `INSTALL.cmd`.

**Developers**
- `build.ps1`: one command for the DLL, the smoke test and the zip, on a PC or
  in CI. Finds MSVC through vswhere, fetches MinHook at a pinned commit
  (v1.3.4), uses upstream's exact compiler and linker flags, force-includes
  the version and update URL from `VERSION`, fills the README placeholders,
  writes `SHA256SUMS.txt`.
- GitHub Actions: build and smoke test on every push and PR, artifact
  upload, release on `v*` tags (tag must equal `VERSION`; notes taken from
  this file).
- `16_update_check.inl`: version and update path are `SS_MOD_VERSION` /
  `SS_UPDATE_REPO_PATH` macros with the fork's defaults; no other source line
  of the component changed.
- `docs/UPSTREAM_README.md` preserves upstream's README; the new README is
  written for players first.
