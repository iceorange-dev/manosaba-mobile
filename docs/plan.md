# Plan: what is left

The open plan items, by what each needs (2026-11-24). An entry holds only what is left; what was done for an item is in
[plan-done.md](plan-done.md) under the same number, the state of the port in [DEVELOPMENT.md](../DEVELOPMENT.md#where-the-work-stands-2026-11-24).
A new item takes the next number (332). How these two files are kept: [DEVELOPMENT.md § Testing](../DEVELOPMENT.md#testing).

## What Tears of the Kingdom left behind

The repository is manosaba's alone, on iOS and Android, since 2026-11-24 (the tag `totk-last`: the last commit with the other game). Each
part below goes with its tests, its switches' rows and its records, after a manosaba run before and after it. The open items about these
parts (271, 220, 192, 320g, 320e, 318, 67) stay further down until their part goes.

- 328 · shared code only that game reached, by its gate: the profile's `touch` pad, `virtual_cores`, `ios_mode`, `ios_pool_add_mb`,
  `present_interval`, `window_unfocused`; the fps hold a game asks for (`dm_game_inactivity_fps`, which no game implements); the
  code options; the lists manosaba has none of (`fout.tsv`, `border_msl.txt`, `lodbias_msl.txt`); the wide picture; the translation thread.
- 329 · what a longer manosaba run never executes (the Mac host's coverage; its prologue and trial 1's debate ran 44 % of the functions):
  audren, nfp, codec, motion, VP9 movies. A Mac run does not clear a path that depends on the GPU (`bcdec` is the phones').
- 330 · the documents and comments still naming that game: the README's acknowledgements, docs/sources.md's lists, games/README.md's fields,
  plan-done.md's records, a comment of `games/manosaba/rules.py` (with the next rewriter change: the file is in the stamp).

## The iPhone Air (the test phone)

- 280 · manosaba's trial peak on the phone with the depth targets without memory (`work/scripts/mano_trial_dev.sh`; 3240 MB of RSS before).
- 71b · the fps line's on-screen count after the app has been in the background; the Metal 4 screen (`DM_TEST_NO_METAL4=1` in env.txt); the
  backup exclusion in Settings.
- 219 · the store decisions and the same-target continuation against the default, in turn, three runs each (one run each so far).
- 310 · sound mixed with other apps' (acnh-mobile 8dcd00c: crackles; the user plays music while manosaba runs); memory touched before loading
  after other apps have filled the phone's memory (nxnative-mkw b8f81e4).
- 153 · the latency default (`DM_PRESENT_LATENCY=auto`) on a device. 148 · the settings panel on a device.
- 317a · whether a free-account install receives MetricKit's payloads.
- 170 · the game's text in the app's language (zh-Hans, zh-Hant), for the user to look at on a device.

## The Mac alone

- 271 · CPU per draw: what the profile still shows is small (pool lookups 6.4 % of the translation thread, the snapshots' lookup 3.7 %). Not
  taken so far: 4ppp44 cb21bec / d0d3cb1 (argument blocks reused across a submission's passes, the driver segment filled only where read).
- 220 · MetalFX frame interpolation: with no motion target the camera's motion would come from the depth and two frames' matrices, and moving
  things would ghost.

## The user at the Mac

- 97 · a present with a deadline against the GPU clock drop: a window and `powermetrics` (the password).
- 127 · the window checks by hand: the title bar's drag, the bars.

## The user's choices

- 192 · touch controls after Touchable (its 8-way D-pad, Liquid Glass, face-button slides and layout; the stick, the camera drag and opacity
  are open).
- 280 · manosaba's characters at fewer pixels per unit in the RomFS's `resources.assets` (PR #2's `patch_character_ppu.py`: 1500x3000 →
  1125x2250): an asset change.
- 331 · kept or removed: mods, cheats and pchtxt patches (`host/game/mods.c`, `cheats.c`, `cheat_vm.c`, `pchtxt.c`); `tools/new_game.py` and
  PORTING.md's parts for another game (its §§ 0, 1 and 5 are what the README's Getting started points to); the repository's name.

## Other hardware

- 320g · the iPhone Duo's inner screen (the user's main phone: ask first): the widened present's fps, GPU time, the HUD's proportions.
- 66, 67, 299 · a controller: the printed-letter face buttons of a Switch Pro controller (66); gyro and rumble with a controller and the phone
  (67); Home and Capture kept from the system (nxnative 062cd06), motion (659c69d, cca3333), rumble through `GCHapticsLocalityHandles`
  (2e07a88) (299).
- 71d · a display above 120 Hz (macOS rounds a 60 Hz request to 72 on a 144 Hz panel).
- 62, 62c2, 62g, 318 · other iPhones and iPads: the cold-texture census (56) under a device's memory limit; BC2 / BC3 / BC7 → ASTC and BC4 /
  BC5 → EAC on GPUs without BC (62c2); one varying interface as a fallback library if a log shows "not written by vertex shader" (62g); a
  device before Apple10 to see the shader's LOD bias on (318; the user, 2026-11-10: none for now).

The Android phone (a Redmi K100 Pro Max), for item 301, manosaba on Android:
- 301d2 · the software keyboard (nx2android draws its own), the motion sensors (ASensorManager → `dm_motion_set`), vibration
  (`dm_vibration_take` → the Vibrator through JNI).
- 301e2c · what manosaba never needed: texel buffers, line loops, clears with a channel mask, storage buffers off 64-byte alignment (a chain
  change) or addressed from a uniform slot; the Adreno findings to check for (a varying not written, more than about 700 draws in a command
  buffer, LRZ across passes, subgroups) and 284's items.
- 301e3 · occlusion samples and the counter reports' GPU timestamps, layered passes, the other TBDR rewrites, the write-back of GPU-written
  CPU-visible memory, the 5-bit formats, memory and bandwidth readings; the trial's pass of 3-4 draws that takes 3.3 of 7.4-7.7 ms a frame;
  the NVN fence on the game's last own submission (LASRecompAndroid 54686f6).
- 301f · the interactive class and deadline declaration (performance hint sessions), the energy and per-core readings; the dips left: the
  wait for an idle GPU before a pool's memory is freed (0.5-0.66 s in all), `vkAllocateMemory` (0.44-0.55 s), the game's own main thread.
- 313 · from S2Arm (written anew): the BC4 3D table's slices through an RGBA16UI view (a K100 probe of `vkCmdCopyImage`), the 1x1-viewport
  draw with no target, the vector-indexing workaround (a probe on the 840 and a count first), sub-allocated image memory, occlusion queries,
  the SampledCubeArray capability.
- 314c · the Vulkan vertex formats checked for VERTEX_BUFFER support (32-bit UI2F / I2F fall to R32_UINT / SINT); the swapchain acquire in
  `vk_present.c` bounded (100 ms; S2Arm 4c0bec5).
- 284 · nxport's frame capture replayed pass by pass on both backends; Adreno 740-799 without the quad / warp32 rewrites, subgroup helpers
  inlined, BC4 / BC5 as 8-bit where R16G16 does not filter (upstream 2461649, 758f5d4, 17b4baa); nx2apk's Darwin shim headers.

## When a frame needs it

- 322 · three shaders changed when a run draws with one (`DM_NVN_KEY_WATCH` names the frame and pass): vertex shader 588e242a52f5f7aa's
  stores with no storage buffer; the sample index (PIXLD.MY_INDEX) of manosaba's pixel shaders a1fe71290083482a and 45eb69b3b99c6600.
- 320e · compute writing a widened image and a copy's destination widened after its source (S2Arm's rules); the `[nvn] widening's census`
  line watches.
