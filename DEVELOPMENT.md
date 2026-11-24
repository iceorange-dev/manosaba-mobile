# Development notes

Where the work stands and how to pick it up again, on this machine or a new one. The repository holds all code, tools and notes; what it
does not hold (and must not: keys, dumps, anything derived from the game) is listed below with the way to get it back. Beside this file:
[docs/plan.md](docs/plan.md) (what is left to do, by what each item needs), [docs/plan-done.md](docs/plan-done.md) (every finished plan item in
a few lines; code comments and commit subjects cite them as "plan item N") and [docs/sources.md](docs/sources.md) (the projects we draw from,
how far each was read, what was taken and what not).

## Restoring a working copy

```sh
git clone https://github.com/iceorange-dev/manosaba-mobile.git "manosaba ios" && cd "manosaba ios"   # work on main, which tracks origin/main
git remote add upstream https://github.com/jhaizhou-ops/d2r-mobile.git      # fetch only, never push there
```

Then the machine: [PORTING.md § 0](PORTING.md#0-machine-and-workspace) (Xcode, Homebrew packages, the Python venv, the shader translator).
This working copy uses `DM_ROOT=<repo>/work` (git ignores `work/`).

| Not in git | Where it lived | How to get it back |
|---|---|---|
| Console keys | `keys/` | From your own console; keep your own backup |
| Game dump (NSP, ExeFS, RomFS) | `dump/`, `extracted/2.0.4b/` | [PORTING.md § 1](PORTING.md#1-dump-the-game-from-your-console): `tools/game_extract.sh keys/prod.keys <out dir> dump/*.nsp` rebuilds ExeFS and RomFS from the two NSPs. `work/data/switch/manosaba-2.0.4b/RomFS` was a link to `extracted/2.0.4b/RomFS` |
| System fonts | `work/data/switch/sysfont` | PORTING.md § 1 (nxdumptool, system data titles 0100000000000810–814) |
| Console and SD card backups | `sd_backup_*/` | Only your own backup |
| Product (rewritten modules) | `work/build/cache/dm/out/…` | `tools/build_product.sh && verify/regress.sh` |
| Shaders, stage map | `work/build/…` (paths in `games/<id>/game.json`) | PORTING.md § 3 |
| App icon | `workspace.icon` | Your own 1024×1024 PNG of the game's icon |
| Device saves | Device `Documents/save`; copies in `work/run/ios/*_save_*` | Files app → this app → `save`, or `devicectl device copy from` |
| iOS signing settings | `ios/local.env` | From `ios/local.env.example`. Keep the bundle ID of the installed app (`xcrun devicectl device info apps --device <id>`): another bundle ID is another app with an empty data container |

Keep `keys/`, the dump, the backups and the device saves in a separate private backup (for example an encrypted external disk); they stay
out of git by design.

## Testing

Check a working copy with `make -C host/tests run`, `make -C host/tests run-ubsan`, `make -C gfx/tests run`, `make -C gfx/tests run-m3`,
`make -C gfx/tex/tests run`, the tool tests (`for t in tools/tests/t_*.py; do python -I "$t"; done` in the venv), `verify/regress.sh --fuzz`,
`tools/audit_public.py`, then a Mac run (README, Getting started) and `ios/run.sh build`. For Android (plan item 301): `make -C android
GAME=manosaba`, `apk` and `test` (NDK r30; the APK's checks in `tools/tests/t_apk.py`), and with the test phone connected `make -C android
run-tests`, a headless run of manosaba under adb (`work/scripts/android_smoke.sh <dir> <seconds>`: the RomFS and system font pushed once to
`/data/local/tmp/dm`) and a run of the app (`work/scripts/android_app_smoke.sh <dir> <seconds>`: installed through the phone's root, a test save of its
own, shown over the lock screen: HyperOS allows it with its "show on lock screen" setting for the app, on on the test phone; a locked phone
without it is reported as skipped). `android/run.sh` builds, installs and runs the app by hand; `t_vk_be` tests the Vulkan backend there.
The APK carries the Vulkan shader bundle (`DM_GAME=manosaba gfx/tools/dmsh_vk.py work/shextract work/build/android/manosaba.dmvk`, DM_ROOT the
workspace; again after a change of the game's shaders or of dmsh_vk.py; `tools/tests/t_dmsh_vk.py` checks the workspace's). To play on the
phone without touching it, `work/scripts/android_live.sh start [<save dir>]` (DM_LIVE_ENV: more NAME=value words for env.txt), `key
<name>...`, `cmd <line>` (e.g. `passdump 2`), `shot <png>` (the game's frame, vk_shot.c), `screen <png>` (the screen), `stop [<boot.txt>]` drive the app
through its command channel (DM_CMD, host/front/cmdchan.c) with a test save of its own (a copy of the given save; HyperOS's pocket mode takes
touches while the phone's top is covered, the channel's keys are not touches).

**How a change is made.** One plan item at a time, each with a unit test and a broken version of the change that must fail it. A batch of
items ends with the gfx tests (Metal 4 and Metal 3), the texture tests, the host tests and their sanitizer run, the public audit and the tool
tests; `verify/regress.sh --fuzz` when the rewriter, a game's rules or `verify/equiv.py` changed; both IPAs (`ios/run.sh ipa`, `DM_IOS_M3=1
ios/run.sh ipa`); the Android host and its tests, on the phone when it is connected, with a 40 s headless run; a short Mac run of the game
(its prologue, and the first trial's debate from a save) against the previous batch's screenshots and red lines; then one commit whose subject
starts with "Plan batch N". A change to `tools/patch_nso.py` or a game's `rules.py` changes the rewriter stamp in the products, so they are built again.
The repository is public: `tools/audit_public.py` checks the git index before every push.

**How the plan is kept.** A batch's record is its commit message: what changed, the measurements, the test results. The documents keep only
the outcome. [docs/plan.md](docs/plan.md) holds what is left, at most three lines an item, and an item leaves it when nothing is left;
[docs/plan-done.md](docs/plan-done.md) gets one record an item, one to three lines: what was done, the number that shows it or decided against
it, where it lives, whose work it follows. No batch entries, no test counts, no history of how it was found; a number is written in one place.
The status below carries its date and is rewritten when the devices or the state change.

- **Memory over repeated loads on the Mac**: `games/manosaba/reload_loop.sh [--stay] <run dir> <save dir> <cycles> [host binary] [VAR=value …]`
  loads a save's newest autosave every 40 s by tapping through the game's own menus; `tools/memstat_cycles.py <run dir>/mem.tsv` prints one
  row per load. With `DM_GUEST_ENV="GC_PRINT_STATS=1" DM_DBG=1` the IL2CPP collector logs every collection; `tools/gc_stats.py <run dir>/log.txt`
  summarizes it. The managed heap census (`DM_HEAP_CENSUS`, `DM_HEAP_WATCH`, `DM_HEAP_REFS`, …) is in [host/README.md](host/README.md).
- **A memory limit kill on iOS** leaves no crash report as a rule (JetsamEvent reports are rate-limited, the crash is "non-actionable"). With the
  device connected: `sudo /usr/bin/log collect --device-udid <UDID> --start '<yyyy-mm-dd hh:mm:ss>' --output kill.logarchive`, then
  `/usr/bin/log show kill.logarchive | grep -E 'ReportSystemMemory|killed by jetsam'`. `DM_MEMSTAT` (relative paths land in `Documents`) and the
  low-memory watch in `host/diag/memstat.m` show what grew.
- **Performance on the iPhone**: compare builds in pairs run one after the other, each after a rest, and judge the sustained rate after the
  first minute (the phone allows a burst of about 60 s, see below). Capped frames lower the clocks, so GPU milliseconds at a held rate
  understate a saving (it shows as a lower clock).
- **Pitfalls**: zsh has a `log` builtin (use `/usr/bin/log`); zsh does not split words (`set -- $var` does not do what bash does); make compares
  modification times, so two edits within one second can skip a rebuild; copy a host binary elsewhere before a long test if you will rebuild
  the host meanwhile; Apple's Metal HUD crashes with `CAMetalDisplayLink` on iOS 18.6 (keep it off there).

## Where the work stands (2026-11-25)

The repository is manosaba's alone, on iOS and Android, since 2026-11-24 (the user): Tears of the Kingdom, which it also ran until then, left
with its game directory, and the tag `totk-last` is the last commit with it. The shared code only that game reached left in the batches that
followed (196 to 209; plan item 328's record), and the game stays at 16:9 (the user, 2026-11-25). None of those batches has run on a phone
yet; what is owed is in [docs/plan.md](docs/plan.md).

What plays is in the README's status; what is left is [docs/plan.md](docs/plan.md). Supported systems: macOS 26 and iOS 26 / 27 (Metal 4); iOS
18 and macOS 15 through the Metal 3 builds (`DM_IOS_M3=1`, `DM_MAC_M3=1`); iOS 17 is not supported. Devices: a Mac with an M5; the test phone,
an iPhone Air (iOS 27.0.1, a free developer account) since 2026-10-27 and an iPhone 17 Pro (iOS 26.4) before it; the iPhone Duo for its two
displays (302); a Redmi K100 Pro Max (Android 17) for the Android app; manosaba also on an iPad mini 7 (iOS 18.6.2) and an iPad Pro M4 (iOS 18.5,
the unsigned IPA) up to 2026-10-16.

**manosaba 2.0.4b** plays on the Mac and the iPhone, and as an Android app through its title, prologue and first trial (301). Open:
1. **The game's own memory leak.** Every save load builds one more set of Naninovel's `ScriptManager` and `ResourceProviderManager`
   (`DM_HEAP_WATCH`) and the old sets stay referenced: live data grows about 20 MB a load, the heap about 28 MB. The root reference is not found.
   Next: trace every old instance of the two managers, bound each object by its class's `instance_size`, scan the guest stacks too; then clear
   the root from a `games/manosaba` hook after a load.
2. **A trial's loading peak.** Its depth and stencil targets have no memory since plan item 280's batch (the Mac's sampled peak 2,458-2,656 →
   2,120-2,199 MB of RSS); the phone's peak (3,240 MB of RSS on the Air before that) is not measured again. Without the increased memory limit an
   iPad mini 7 allows about 3.4 GB and an A16 iPad 3071 MB (killed at a trial's start); a free account signs the limit (65, 211).
3. Smaller: 13 NVN functions looked up but unknown (NULL, never called); compute dispatch never seen; keyboard, mouse and controller untested
   with this game.
