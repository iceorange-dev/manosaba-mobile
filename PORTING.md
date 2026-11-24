# Setting up: from your dump to the device

The steps from a dump of manosaba (Switch version 2.0.4b) to the game running on a Mac, an iPhone or an Android phone. Each names the tool and
what to check before going on. The game's profile, rewriter rules and host code are in `games/manosaba/` ([games/README.md](games/README.md)).

```
your console ──► ExeFS + RomFS + system fonts            (data/switch/…)
tools/build_product.sh ─► product (rewritten modules)   ─► verify/regress.sh
shaders: shader_extract.py ─► shmap_from_capture.py ─► dmsh_build.py ─► c1_guard.py
make -C host ─► dmhost, a run on the Mac
ios/run.sh build / install / push-data / launch;  android/run.sh;  tools/mac_app.sh
```

## 0. Machine and workspace

- Apple silicon Mac, macOS 26 (the host uses Metal 4; `make -C host dmhost_m3` builds for macOS 15+), Xcode with the iOS SDK and the Metal
  toolchain (used: Xcode 27.0).
- Homebrew: `dotnet` (shader translator), `spirv-cross`, `xcodegen` (iOS project); `libvpx` for VP8 / VP9 movies (linked statically into the Mac
  host when installed; without it such movies cannot play); `libimobiledevice` only for the live iOS log (`iproxy`).
- Python 3 venv at `$DM_ROOT/build/cache/dm/venv` (the scripts' default interpreter, `DM_PY` overrides):
  `pip install -r tools/requirements.txt` and `pip install --no-deps -r engines/unity/requirements.txt`.
- The shader translator: `DOTNET_ROOT=$(brew --prefix dotnet)/libexec dotnet build -c Release gfx/tools/dmsh_xlate/dmsh_xlate.csproj -o $DM_ROOT/build/gfx/dmsh_xlate`
  (keep `DOTNET_ROOT` exported when running `dmsh_build.py`).
- For the Android app (`android/`, plan item 301): the casks `android-ndk` (NDK r30), `android-platform-tools` (adb) and
  `android-commandlinetools`, the formula `openjdk@21`, and for the settings panel's Java (classes.dex) `JAVA_HOME=$(brew --prefix openjdk@21)
  sdkmanager --sdk_root=$(brew --prefix)/share/android-commandlinetools "build-tools;35.0.1" "platforms;android-35"` (it asks you to accept the
  Android SDK licence).

`DM_ROOT` (default `~/dm-work`) holds everything that is not source: game data, build outputs, runs. Nothing under it goes into git.

```
$DM_ROOT/data/switch/manosaba-2.0.4b/ExeFS    main, sdk, subsdk0, main.npdm
$DM_ROOT/data/switch/manosaba-2.0.4b/RomFS
$DM_ROOT/data/switch/sysfont                  *.bfttf (the console's shared fonts)
$DM_ROOT/build/…                              product, shaders, stage map (paths in game.json)
$DM_ROOT/run/…                                logs, screenshots, saves of test runs
```

## 1. Dump the game from your console

Only your own copy, from your own console. You need the game with its latest update applied, as ExeFS (`main`, `sdk`, `subsdk*`,
`main.npdm`) and RomFS. Two ways:

- **Packages + keys** (the usual way). On the console, run Lockpick_RCM (`prod.keys`), then in nxdumptool's `user titles menu` → the game
  → `nsp dump options`, dump the base game and the update as NSPs; keep `tik: remove console specific data` on (eShop titles have
  personalized tickets, which cannot be used off the console) and `nca/tik: remove titlekey crypto` off. On the Mac:

  ```sh
  tools/game_extract.sh <prod.keys> $DM_ROOT/data/switch/manosaba-2.0.4b <base.nsp> <update.nsp>
  ```

  It takes `.nsp` and `.xci` in any mix, and the folder nxdumptool writes for a file over 4 GiB on the SD card. It reads only the keys
  common to all consoles from `prod.keys`, layers the newest update over the base game, checks every read against the NCA hash trees and
  prints the module build IDs (C#, LibHac; needs the .NET SDK). It gave the same 667 files, byte for byte, as the console.
- **On the console**, no keys on the Mac: nxdumptool → `nca / nca fs dump options` → `dump update` → the Program NCA; dump the `ExeFS`
  section, then the `Patch RomFS` section with `use base/patch title` set to the base game. Output under
  `sdmc:/nxdt_rw_poc/NCA FS/User/Extracted/<title>/Program #0/<section>`.

**System fonts**: the `*.bfttf` files from the RomFS of system data titles `0100000000000810`–`0100000000000814` (nxdumptool). The host
serves them as `nn::pl` shared fonts.

Keys, dumps and console backups stay out of the repository (`.gitignore` covers `keys/`, `dump/`, `work/` …).

## 2. Rewrite the modules and verify

```sh
tools/build_product.sh            # output: the profile's workspace.product
verify/regress.sh --fuzz          # must end with REGRESS OK
```

Run both again whenever `tools/patch_nso.py` or `games/manosaba/rules.py` changes (the rewriter's stamp changes with them, and the host
checks it).

## 3. Shaders

Every shader of the game is extracted from its files ([engines/unity/README.md](engines/unity/README.md)), mapped and translated. With
`ws() { echo "$DM_ROOT/$(python3 tools/gen_game.py games/manosaba/game.json --get workspace.$1)"; }` and
`PY=$DM_ROOT/build/cache/dm/venv/bin/python`:

```sh
$PY engines/unity/shader_extract.py "$(ws romfs)/Data" "$(ws exefs)/main" "$(ws shader_capture)"
python3 gfx/tools/shmap_from_capture.py "$(ws shader_capture)" "$(ws shader_map)"
IOSOUT="$(ws msl_ios)" $PY gfx/tools/dmsh_build.py "$(ws shader_capture)" "$(ws msl_mac)"
python3 gfx/tools/c1_guard.py "$(ws msl_mac)/b-$(python3 gfx/tools/dmsh_chain.py)" "$(ws c1)"
```

`dmsh_build.py` prints a summary; every shader should be `ok`. If `gfx/tools/dmsh_chain.py --check-tools` reports that your spirv-cross or
Xcode differs from the lock file, run `dmsh_chain.py --update-lock` and `--header`, then rebuild the host. Libraries are keyed by content, so
rebuilding only translates what changed. The Android app's Vulkan bundle: `DM_GAME=manosaba gfx/tools/dmsh_vk.py "$(ws shader_capture)"
$DM_ROOT/build/android/manosaba.dmvk`.

## 4. Run on the Mac

```sh
make -C host
mkdir -p $DM_ROOT/run/manosaba/{save,temp}
DM_ROOT=$DM_ROOT DM_SAVE=$DM_ROOT/run/manosaba/save DM_TEMP=$DM_ROOT/run/manosaba/temp DM_WINDOW=1 DM_AUDIO=1 host/dmhost   # a window
DM_ROOT=$DM_ROOT DM_SAVE=… DM_TEMP=… DM_KEYS="RIGHT@8+0.2,A@10+0.2" DM_NVN_SHOT="600,1500:shots/s%d.png" DM_WATCH=60 host/dmhost   # headless
```

`DM_KEYS` scripts input (buttons, sticks, touches) and `DM_NVN_SHOT` saves screenshots at given frames, so a run can be repeated; `DM_WATCH=<s>`
stops it (exit 142 is the watchdog, not a crash). Every log line with `[red]` is something to look at. The switches are listed in
[host/README.md](host/README.md) and [gfx/README.md](gfx/README.md); for a crash: `tools/fdis.py` / `symaddr.py` (disassembly with symbols),
`DM_PROBE=module:offset`, `DM_CRASH_MEM`, `DM_WATCHPOINT`. Keep `make -C host/tests run`, `make -C gfx/tests run` and `verify/regress.sh`
passing ([DEVELOPMENT.md § Testing](DEVELOPMENT.md#testing)).

## 5. iPhone / iPad, Android and the Mac app

```sh
cp ios/local.env.example ios/local.env     # team, bundle ID, device; DM_FREE_ACCOUNT=1 for a free account
ios/run.sh build && ios/run.sh install && ios/run.sh push-data && ios/run.sh launch
DM_TARGET=android tools/build_product.sh $DM_ROOT/build/android/manosaba.b301    # Android: its product, then the shader bundle of step 3
android/run.sh build && android/run.sh install && android/run.sh launch && android/run.sh push-data && android/run.sh launch
tools/mac_app.sh                           # $DM_ROOT/out/macapp/<title>.app
```

See [ios/README.md](ios/README.md); for Android, [DEVELOPMENT.md § Testing](DEVELOPMENT.md#testing). The app icon comes from the profile's
`workspace.icon` (your own 1024×1024 PNG; never committed).
