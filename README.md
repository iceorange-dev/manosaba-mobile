# 魔法少女ノ魔女裁判 (manosaba) on iPhone, iPad and Android, natively

This repository runs the Nintendo Switch game **魔法少女ノ魔女裁判** (manosaba), version 2.0.4b, on iPhone, iPad, Android and Mac without
emulating the CPU. A Switch and these devices use the same class of processor, so the game's own aarch64 code executes directly. Only the few
instructions that cannot run under the device's kernel are rewritten offline; the console's system services and its NVN graphics API are
reimplemented by a small host (on Apple's frameworks and Metal; on Android, Vulkan); the game's shaders are translated ahead of time. Found a
problem? [Report it](#reporting-problems).

It is a fork of [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile), which ported Diablo II: Resurrected the same way; the D2R-specific code
has been removed here.

**No game content is in this repository.** You dump your own copy from your own console; everything derived from it (rewritten modules,
translated shaders, the app icon) is generated on your machine and stays out of git.

## Status (manosaba 2.0.4b)

Verified on a Mac (Apple silicon, macOS 26), an iPhone 17 Pro (iOS 26) and an iPhone Air (iOS 27):

- boot, title screen, new game, story scenes with sprites, CG, text and UI, the opening movie, a trial including presenting evidence;
- native touch input (one rewriter rule turns on Unity's touchscreen device): scripted touches on the Mac, by hand on the iPhone;
- saving and loading, with transactional commits; iCloud sync of the save files (needs a paid developer account's entitlements; not tested);
- long sessions and repeated scene loads: a 16-minute iPhone session through scene changes and a trip to the background stayed between 1.2
  and 1.5 GB resident with no upward trend; 54 reloads of a trial on the Mac ran without a crash or a warning;
- graphics settings in the Settings app (frame rate 60 / 30 fps, render resolution, MetalFX upscaling): 720p with MetalFX used on the iPhone;
  30 fps not yet tried there. On the Mac the render resolution barely changes this game's GPU load; 30 fps is the setting that lowers it;
- rewrite equivalence: `verify/regress.sh --fuzz` passes on all three modules.

Not verified or known open: compute shader dispatch (none happens in the story or in a trial); 13 NVN functions the game looks up and never
calls; keyboard, mouse and game controller input with this game. Memory over hours of play: the game's own memory grows by some 30 MB per
scene load (every save load builds a new set of Naninovel's script and resource managers and the old ones stay referenced), and a trial's
loading adds over a gigabyte for a moment, so after about two hours a trial's loading went past an 8 GB iPad's limit without the increased
memory limit; restarting the app before then avoids it, and a free account can sign that limit (6.1 GB on the iPhone 17 Pro). The Switch
version is reported to end with an error now and then in long sessions too.

On Android (plan item 301, under way): on a Redmi K100 Pro Max (Android 17) manosaba runs as an app of this repository's own (no Android SDK:
`android/tools/apk.py` writes and signs the APK) at 60 fps, with sound (AAudio), touch, game controllers and saves, drawn by a Vulkan backend
of its own (`gfx/nvn/vk/`, the game's shaders from the same translation as Metal's): the title, the prologue and the first trial checked so far,
at 60 fps; what is left is plan item 301 in [docs/plan.md](docs/plan.md).

## How it works

| Part | Directory | What it does |
|---|---|---|
| Rewriter | `tools/patch_nso.py` | Rewrites x18, thread pointer, `svc` and timer instructions into jumps to small patch blocks; the rest of the code is untouched |
| Verification | `verify/` | Proves the rewritten modules equivalent to the originals (structure, per site, per function, gates) |
| Host | `host/` | Loader (rtld), kernel calls, `nn::` services (file system, input, audio, time, movies, fonts, …) |
| Graphics | `gfx/` | NVN on Metal (on Vulkan for Android), record and replay; offline shader translation (Ryujinx translator → SPIR-V → MSL → metallib) |
| Apps | `ios/`, `android/`, `tools/mac_app.sh` | iOS app; Android app; Mac command-line host and `.app` |
| The game | `games/manosaba/`, `engines/unity/` | Game profile, rewriter rules, hooks; Unity shader extraction |

## Getting started

1. Requirements and workspace: [PORTING.md § 0](PORTING.md#0-machine-and-workspace).
2. Dump the game (ExeFS, RomFS, system fonts) from your console into `$DM_ROOT/data/switch/` ([§ 1](PORTING.md#1-dump-the-game-from-your-console));
   for manosaba the expected paths are in [games/manosaba/game.json](games/manosaba/game.json).
3. Build and check the product, the shaders and the host:

   ```sh
   export DM_ROOT=~/dm-work
   tools/build_product.sh && verify/regress.sh
   # shaders: PORTING.md § 3
   make -C host
   DM_SAVE=$DM_ROOT/run/save DM_TEMP=$DM_ROOT/run/temp DM_WINDOW=1 DM_AUDIO=1 host/dmhost
   ```

4. iPhone / iPad: [ios/README.md](ios/README.md). Mac app: `tools/mac_app.sh`.
5. Android (see above): `DM_TARGET=android tools/build_product.sh $DM_ROOT/build/android/manosaba.b301`, the shader bundle
   (`DM_GAME=manosaba gfx/tools/dmsh_vk.py <shader captures> $DM_ROOT/build/android/manosaba.dmvk`), then
   `android/run.sh build`, `install`, `launch` once, `push-data`, `launch` (NDK r30; [DEVELOPMENT.md § Testing](DEVELOPMENT.md#testing)).

## Reporting problems

Problems are welcome as [GitHub issues](https://github.com/iceorange-dev/manosaba-ios/issues/new/choose). Please say:

- the game's version, the device and its iOS, Android or macOS version;
- the build: the commit, and iOS 26, iOS 18 (`DM_IOS_M3=1`) or Android;
- what happened and how to get there (where in the game, what you pressed);
- on iOS, attach the diagnostics file: touch and hold the app's icon → Export Diagnostics (device, GPU, memory, settings and the last logs;
  [ios/README.md](ios/README.md#on-the-device)). On the Mac, the log: `~/Library/Logs/<game id>/host.log` for the `.app`, the terminal
  output for `host/dmhost`.

Do not attach game files, keys, dumps, rewritten modules or IPAs.

## Documentation

| Document | Covers |
|---|---|
| [PORTING.md](PORTING.md) | Setting up: from your dump to the device |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Restoring a working copy, test procedures, where the work stands |
| [docs/plan.md](docs/plan.md), [docs/plan-done.md](docs/plan-done.md) | What is left to do; every finished plan item in a few lines (the "plan item N" of code comments) |
| [docs/sources.md](docs/sources.md) | Community ports drawn from, how far each was read, what was taken from each and what not |
| [games/README.md](games/README.md) | Game directory: `game.json`, `rules.py`, C hooks |
| [host/README.md](host/README.md) | Loader, services, files, environment variables |
| [gfx/README.md](gfx/README.md), [gfx/nvn_metal_mapping.md](gfx/nvn_metal_mapping.md), [gfx/tex/README.md](gfx/tex/README.md) | Graphics layer, shader chain, NVN → Metal mapping, textures |
| [ios/README.md](ios/README.md) | iOS app: setup, signing, data on the device |
| [verify/README.md](verify/README.md) | Rewrite equivalence checks |
| [tools/README.md](tools/README.md), [engines/unity/README.md](engines/unity/README.md) | Tools; Unity-specific notes |
| [third_party/README.md](third_party/README.md) | Bundled third-party code and licenses |

## Legal

Use this only with games you own, dumped from your own console. This is an independent, non-commercial project, not affiliated with or
endorsed by Nintendo or any game publisher. Nintendo Switch is a trademark of Nintendo.

## Acknowledgements

What was taken from each, item by item: [docs/sources.md § Taken from each project](docs/sources.md#taken-from-each-project); every
port is also credited where it lives in the code.

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** ([jhaizhou](https://github.com/jhaizhou-ops), MIT): the architecture and most of
  the host, graphics layer and verification tools, and later fixes; its contributors [SepheTT](https://github.com/SepheTT) and
  [BossaMelon](https://github.com/BossaMelon).
- **[nxnative](https://github.com/seedds/nxnative)** ([seedds](https://github.com/seedds), MIT) and **botw-mobile**
  ([Tommy Lau](https://github.com/TommyLau), MIT; no longer on GitHub), ports built on d2r-mobile: host and replay fixes and the extraction tool's
  model.
- **[tomodachi-native](https://github.com/kuosuko/tomodachi-native)** ([kuosuko](https://github.com/kuosuko), MIT), a fork of nxnative: the
  duplicated colour slot, memory snapshots, a translator fix, attachment copies.
- **[MacNativeGames](https://github.com/ly05010419/MacNativeGames)** ([ly05010419](https://github.com/ly05010419), MIT), a port on the same
  lineage: the movie decoder's behaviour, uniform snapshots and much of the graphics layer.
- **[LASRecomp](https://github.com/peiikai/LASRecomp)** ([Peiikai](https://github.com/peiikai), MIT), a static recompilation of Link's
  Awakening: CPU-filled textures, wait and lock rules, GPU time, instruction test vectors.
- **[nx2android](https://github.com/shirai91/nx2android)** ([shirai91](https://github.com/shirai91), MIT as its README states), nxnative's
  Android port: the rewriter's Android target, the APK written without the Android SDK, facts for the Android port.
- **[S2Arm](https://github.com/jhaizhou-ops/S2Arm)** ([jhaizhou-ops](https://github.com/jhaizhou-ops), Apache-2.0; written anew from what it
  does, no code taken): checks and measurements for the iPhone (bandwidth, sleeps, diagnostics, the install flow).
- **[mush8](https://github.com/c22dev/mush8)** ([c22dev](https://github.com/c22dev), GPL-3.0; ideas only, no code taken): three rewriter
  safeguards.
- **Single fixes from other ports**: [Kamisorara/d2r-mobile](https://github.com/Kamisorara/d2r-mobile),
  [jiangjifeng/nxnative](https://github.com/jiangjifeng/nxnative), [GirlNet/d2r-mobile](https://github.com/GirlNet/d2r-mobile),
  [lordran-native](https://github.com/Nishikori-Yui/lordran-native), [SkyRecomp](https://github.com/Apolinario-coder/SkyRecomp),
  [nxport](https://github.com/nxporting/nxport), [BotWRecomp](https://github.com/IshaanKalra2103/BotWRecomp),
  [4ppp44/d2r-mobile-ios17](https://github.com/4ppp44/d2r-mobile-ios17), [GirlNet/nxnative](https://github.com/GirlNet/nxnative),
  [RogelioLB/nxnative-android](https://github.com/RogelioLB/nxnative-android),
  [PKShield-Android](https://github.com/simipoB/PKShield-Android), [doom-port](https://github.com/Desm0nt/doom-port).
- **[LibHac](https://www.nuget.org/packages/LibHac/0.19.0)** ([Alex Barney](https://github.com/Thealexbarney), MIT; the NuGet package, as its
  GitHub repository is no longer reachable): reads NSP, XCI and NCA containers in `tools/game_extract`.
- **[Ryujinx](https://ryujinx.app)** (MIT; source on the project's own Forgejo instance): the shader translator in `third_party/ryujinx`.
- **[deko3d](https://github.com/devkitPro/deko3d)** (devkitPro, zlib): the texture layout size algorithm in `gfx/nvn/nvn_tex.c`; its format table
  told the bit order of the 16-bit formats (`gfx/tex/nvn_fmt_mtl.c`).
- **nvn.h** ([h1k421](https://github.com/h1k421), MIT): NVN declarations in `gfx/nvn/include/nvn.h`.
- **[bcdec](https://github.com/iOrange/bcdec)** ([iOrange](https://github.com/iOrange), MIT or Unlicense): BC texture decoding.
- Tools: [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
  [.NET](https://dotnet.microsoft.com/), [Capstone](https://github.com/capstone-engine/capstone),
  [Unicorn](https://github.com/unicorn-engine/unicorn), [python-lz4](https://github.com/python-lz4/python-lz4),
  [UnityPy](https://github.com/K0lb3/UnityPy), [hactool](https://github.com/SciresM/hactool),
  [nxdumptool](https://github.com/DarkMatterCore/nxdumptool), [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice).

## License

MIT, see [LICENSE](LICENSE). Third-party code keeps its own license in its own directory.
