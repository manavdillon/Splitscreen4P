# Splitscreen4P

**Four local split-screen players in Call of Duty: Black Ops III on PC** (the game
itself stops at two). Zombies and offline Multiplayer, bots included. One zip,
one double-click.

This is a fork of LocalPlayer123's
[BO3 4-Player Local Splitscreen on PC](https://github.com/LocalPlayer123/BO3-4-Player-Local-Splitscreen-on-PC),
which does the real work: an [ezz BOIII](https://github.com/Ezz-lol/boiii-free)
plugin that makes the PC build behave like the console build at runtime. This
fork keeps that code unchanged and adds what was missing to just play:

- **INSTALL.cmd** finds the game through Steam, checks the game build, installs
  ezz BOIII if needed (hash-verified), puts the mod files in the right place and
  creates a desktop shortcut. Run it again to update.
- **CHECK.cmd** says what is installed, whether ezz loaded the mod on the last
  start, and which controllers Windows sees. **UNINSTALL.cmd** removes the mod.
- **Reproducible builds**: `build.ps1` fetches a pinned MinHook, builds the DLL,
  runs the smoke test and packages the zip; GitHub Actions runs it on every
  push and publishes every tagged release.

Status: **beta**, like upstream. Read upstream's
[OPEN_PROBLEMS.md](docs/OPEN_PROBLEMS.md) before changing game code.

---

## Play

1. Download `Splitscreen4P-<version>.zip` from
   [Releases](https://github.com/manavdillon/Splitscreen4P/releases) and
   extract it anywhere.
2. Double-click **INSTALL.cmd**. Every step prints `[OK]`, `[WARN]` or `[FAIL]`.
3. Connect the controllers (Xbox or PlayStation; Steam Input on, which is
   Steam's default). Connect all of them before players join.
   Mixed controllers (a Steam Controller or PlayStation pad next to an
   Xbox-type pad) need Steam Input for all of them, or two pads drive the same
   player: in Steam right-click the game, Properties, Controller, **Enable
   Steam Input**, and set the Launch Options to
   `"<game folder>\boiii.exe" -launch -nointro %command%`, then start from Steam.
4. Start the game with the new desktop shortcut **Black Ops III - 4 Player
   Splitscreen** (it runs `boiii.exe -launch -nointro`), or from Steam as above.
5. **PLAY OFFLINE**, then **ZOMBIES** or **MULTIPLAYER**. In the lobby every
   extra player presses **A** to join (B leaves). Player 1 on keyboard and
   mouse: the first pad belongs to player 1; once every other pad has joined,
   click **ACTIVATE SPLITSCREEN** and that pad becomes the next player while
   player 1 keeps the keyboard (keyboard + 3 pads = 4 players). Start the
   match: 3 players = 3 screens, 4 players = 2 x 2.
6. Field of view per player: **Options > Controls** has a "Player 2/3/4 field
   of view" slider under the controller choices (2.8.0). Player 1 keeps the
   Graphics slider; a player whose slider was never moved uses player 1's.

Players 3 and 4 can only join offline lobbies: the online lobby allows two
players per PC, a rule of the game. Players 2 to 4 play with a copy of player
1's classes and stats for the session; player 1's save is never changed.

### Requirements

- Black Ops III on Steam, Windows 10/11 64-bit.
- ezz BOIII **3.0.0** (the installer downloads it if `boiii.exe` is missing).
- The game build ezz 3.0.0 runs: `BlackOps3.exe` with PE checksum
  `0x06531394` (Steam build 24784313). If Steam updated the game, ezz offers
  to download the compatible exe on its first start; say yes.

### If something is wrong

Double-click **CHECK.cmd**. It changes nothing and tells you which part is
missing. When reporting a problem, say which map, how many players and what
you did just before, and attach the newest file from
`%LOCALAPPDATA%\boiii\minidumps` if the game crashed. Known issues are in the
zip's `README.txt` (KNOWN ISSUES) and in [docs/OPEN_PROBLEMS.md](docs/OPEN_PROBLEMS.md).

### Manual install

Still works: drag the zip's `boiii` folder into your Black Ops III folder (the
one with ezz's `boiii.exe`) and merge. The mod must end up as
`Black Ops III\boiii\plugins\bo3_local_splitscreen.dll`.

---

## Build

Needs Visual Studio 2022 with "Desktop development with C++". Everything
else is fetched.

```
.\build.ps1                 player build  -> out\bo3_local_splitscreen.dll + dist\Splitscreen4P-<version>.zip
.\build.ps1 -Diag           diagnostic build (trace in %LOCALAPPDATA%\boiii\splitscreen_ui_trace.txt)
.\build.ps1 -NoUpdateCheck  no network code (Nexus Mods rules)
.\build.ps1 -SkipPackage    DLL and smoke test only
```

The script imports the MSVC environment itself (vswhere), downloads MinHook
at a pinned commit into `deps\minhook` (or uses `MINHOOK=<folder>`), compiles
with upstream's exact flags, links, builds and runs `src\standalone\test\smoke.cpp`
(loads the DLL the way ezz does and checks the export, the start trigger and
the pin), then stages the zip with `SHA256SUMS.txt`. The version comes from
the `VERSION` file and is compiled into the DLL for the update notice.

**CI:** [.github/workflows/build.yml](.github/workflows/build.yml) runs the
same script on `windows-2022` for every push and pull request and uploads the
zip as an artifact. Pushing a tag `vX.Y.Z` (which must equal `VERSION`)
publishes a GitHub release with the zip and the matching CHANGELOG section.

**Release checklist:** bump `VERSION`, add the section to `CHANGELOG.md` and
the "NEW IN" block to `docs/PLAYER_README.txt` (its title must name the
version), commit, `git tag vX.Y.Z`, push the tag.

Upstream's `build_standalone.cmd` is kept and still works from an x64 Native
Tools prompt with `MINHOOK` set.

---

## Repository layout

```
setup/                       INSTALL.cmd, CHECK.cmd, UNINSTALL.cmd and splitscreen-setup.ps1 (the installer)
build.ps1                    build + smoke test + package (local and CI)
VERSION                      the one place the version lives
src/component/               the mod (unchanged from upstream except the two build-time macros
                             in splitscreen/16_update_check.inl)
src/ui_scripts/              the three Lua scripts (one line changed: the update notice's link)
src/standalone/              the ezz plugin shell, compat headers and the smoke test
docs/PLAYER_README.txt       the README.txt that goes into the zip
docs/OPEN_PROBLEMS.md        upstream: what is broken or unverified - read before touching game code
docs/EZZ_REQUIRED_CHANGES.md upstream: what ezz BOIII could change natively
docs/PLAN_EZZ_PORT.md        upstream: history of the port to ezz
docs/UPSTREAM_README.md      upstream's README at the time of the fork (how the mod works, in depth)
tools/                       upstream's analysis scripts
```

## What changed against upstream

See [CHANGELOG.md](CHANGELOG.md). In short: one game-side addition, the
per-player field of view (`17_player_fov.inl`, 2.8.0: each pane is drawn with its
own player's FOV; off, with the game as before, when the engine bytes differ). The
lobby script `zz_splitscreen` lends player 1's pad to the next seat when every
connected pad already has one (keyboard player 1, 2.7.1) and adds the FOV
sliders to Options > Controls. The
version string and the update-check URL in `16_update_check.inl` are now
macros that `build.ps1` sets from `VERSION`; the Lua update notice links here;
everything else is new files around the mod.

## Credits

- **LocalPlayer123** wrote the mod, every patch, and the documentation under
  `docs/`. The git history of this fork is theirs up to the fork point.
- **rdevathu** found and fixed the sprint bug for players 3/4 (upstream PR 1).
- **ezz** for the BOIII client and its plugin loader.
- **Tsuda Kageyu** for [MinHook](https://github.com/TsudaKageyu/minhook)
  (BSD 2-Clause; the license text ships in the zip's README.txt).

The upstream repository carries no license file; this fork adds none for the
upstream code and claims nothing over it. The files added by this fork
(`setup/`, `build.ps1`, the workflow, this README, CHANGELOG) may be used
freely.
