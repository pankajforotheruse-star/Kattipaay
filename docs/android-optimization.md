# Chalk Gaon — Android Optimization (Prompt 16)

Everything done for the "APK < 30 MB, mobile-friendly prototype" pass, with the
numbers behind each decision. All changes are static (no engine run on this
machine); anything that needs a real Godot import, Android build, or on-device
listen is called out in [§9 What needs an engine / device build](#9-what-needs-an-engine--device-build).

---

## 1. Export preset (`export_presets.cfg`)

A single Android preset, **arm64-v8a only**:

| Setting | Value | Why |
|---|---|---|
| `gradle_build/use_gradle_build` | `true` | AAPT2 + zipflinger; proper APK compression |
| `architectures/arm64-v8a` | `true` | Android 8+ phones are arm64; dropping armeabi-v7a/x86 removes ~10 MB of dead template code |
| `gradle_build/min_sdk` | `"26"` | Android 8.0 — the game's stated floor |
| `gradle_build/target_sdk` | `"34"` | Godot 4.3 default; current Play requirement |
| `screen/immersive_mode` | `true` | Hide status/nav bars — 720×1280 canvas stays full |
| `permissions` | INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_STATE, CHANGE_NETWORK_STATE, ACCESS_FINE_LOCATION, NEARBY_WIFI_DEVICES, VIBRATE | Minimal set for WiFi-Direct local play + Nakama online. No storage/camera/mic. `NEARBY_WIFI_DEVICES` covers Android 13+ peer discovery |
| `script_export_mode` | `2` | Binary tokenization (smaller, faster-loading scripts) |
| `gradle_build/compress_native_libraries` | `true` | Smaller APK (at the cost of slower cold start) |
| `package/unique_name` | `com.chalkgaon.ghostlines` | Placeholder — owner should claim before Play |

### APK size math (estimate — verify with a real build)
- Godot 4.3 Android **release** template, arm64 only: **≈ 23–27 MB** (the
  libgodot_android.so release build is ~14 MB; Kotlin/AndroidX/Gradle assets
  add the rest).
- PCK (project data): scripts < 50 KB + imported textures ≈ 3–4 MB (see §2) +
  atlas sources ~0.5 MB → **≈ 4 MB**.
- **Estimated total: ≈ 27–31 MB.** Under budget but tight. If a real build
  lands over 30 MB, cheapest levers (in order): disable
  `textures/vram_compression/import_etc2_astc` (saves ~1.2 MB PCK, see §2),
  then ship an **AAB** (Play splits per-ABI — effective install size drops to
  ~the arm64 slice). Neither is done here so the prototype stays side-loadable
  and ASTC-enabled.

## 2. Texture compression (`project.godot` `[importer_defaults]` + ground `.import`)

Mechanism (Godot 4 static import config):
- `[importer_defaults] texture = { "compress/mode": 2, ... }` — every texture
  imports as **VRAM-compressed** (ETC2 on Android Vulkan; ASTC when the device
  supports it and the project setting below is on). No `.import` files needed
  for the 28 sprites; defaults apply on first editor import.
- `rendering/textures/vram_compression/import_etc2_astc = true` — also
  generates the **ASTC** variant for Android 8+/Vulkan devices.
- `assets/backgrounds/village_ground_2048x1536.png.import` — hand-written
  override for the ground only: `compress/mode=2` + **`mipmaps/generate=true`**
  (the one texture that gets scaled down; sprites are drawn near 1:1 and would
  only waste 33% extra VRAM on mip chains). The PNG itself is untouched.
- `mipmaps/generate=false` is the global default for the 28 sprites.

### VRAM math (loaded on a phone)
| Texture | RGBA8 (uncompressed) | ETC2 | ASTC 8×8 |
|---|---|---|---|
| Ground 2048×1536 (opaque → RGB format, +mips) | 12.0 MB | 1.5 MB (+mips 2.0) | 0.75 MB (+mips 1.0) |
| 28 sprites (RGBA → ETC2 RGBA8) | 2.9 MB | 0.73 MB | 0.18 MB |
| **Total** | **14.9 MB** | **≈ 2.7 MB** | **≈ 1.2 MB** |

**≈ 5.5× VRAM reduction at ETC2, ≈ 12× at ASTC.** PCK size impact: ETC2 +
ASTC variants together ≈ 3.9 MB of texture data (vs 1.74 MB of source PNGs) —
the price of instant device-adaptive format selection. The APK math in §1
includes this.

> **Engine verification needed:** the `.import` file's uid/path hash were
> written by hand (md5 of the res:// path). Godot re-imports and rewrites the
> file if the hash mismatches — expected and harmless on first editor open.
> Confirm in the Import dock that the ground shows "VRAM Compressed, Mipmaps
> ON" and sprites "VRAM Compressed, Mipmaps OFF".

## 3. Audio compression + budget (`AudioManager.gd`)

Audio is 100% procedural (AudioStreamGenerator, zero packaged files), so the
**packaged budget is 0 bytes** vs the GDD §11 allowance of ≤ 4 MB.

Change made: **`SAMPLE_RATE` 44100 → 22050 Hz**. Every generated sound is a
simple tone with a maximum frequency of **1200 Hz** (the timer tick) — well
under the 22.05 kHz Nyquist limit (11 kHz), so the halving is inaudible while
cutting CPU and transient memory in half. Frames were already computed mono
and mirrored to both channels (`Vector2(val, val)`).

### RAM math
| Sound | Duration | Frames @22.05k | Peak transient (Vector2 = 8 B) |
|---|---|---|---|
| cow_moo (longest) | 0.8 s | 17,640 | **141 KB** |
| argument_start | 0.5 s | 11,025 | 88 KB |
| argument_result (chime) | 0.39 s | 8,602 | 69 KB |
| timer_warning | 0.24 s | 5,292 | 42 KB |
| accusation_blurt | 0.15 s | 3,308 | 26 KB |
| **Steady state** (generator buffer 0.1 s) | — | 2,205 | **17.6 KB** |

Equivalent 16-bit WAV PCM totals (if these were packaged files): ≈ 0.19 MB —
far under the 4 MB budget either way.

> **Verify on device:** the generator's internal buffer is
> `BUFFER_LENGTH (0.1 s) × mix_rate` frames. Frames pushed past the buffer are
> dropped by `push_frame` — so on the shipped code every sound may be capped at
> ~0.1 s of playback. That is pre-existing behavior, unchanged here; if a
> device listen shows truncated sounds, the fix is either a larger
> `BUFFER_LENGTH` or pushing pending frames from `_process` (a small follow-up,
> deliberately out of scope to avoid changing sound feel in this pass).

## 4. Object pooling (`scripts/systems/Pool.gd`)

New generic pool (RefCounted): `acquire()` / `release()`, LIFO, stale-instance
guards, plus `Pool.reset_line2d()` for clean Line2D recycling.

| Consumer | Before | After | Churn removed |
|---|---|---|---|
| `DrawSystem` (chalk strokes) | `Line2D.new()` + `queue_free()` per stroke, up to 50 active + preview | pooled, pre-warmed ×16 | node alloc/free + add/remove_child per stroke |
| `GhostDrawSystem` (ghost lines) | same | pooled, pre-warmed ×8 | same |
| `TutorialBurst` (feedback rings) | `new()` + `queue_free()` every 0.55 s, bursts can stack during celebrations | static pool, pre-warmed ×4 | node alloc/free per burst |

Public behavior identical: systems emit the same events, lines fade/decay the
same way, bursts animate the same. Pooled Line2D nodes stay parented but
hidden — zero add/remove churn on reuse. Materials are still allocated per
line (the fade tween owns per-line `alpha_mult`); pooling materials per chalk
type is a possible follow-up if profiling shows material allocs.

## 5. Draw-call audit

Godot 4 model: **draw calls ≈ canvas items** (each `_draw()` is one item; items
with the same material/texture batch). Primitive count inside an item affects
CPU vertex generation + upload, not the call count. Audit with estimates:

| Scene / object | Before | After (this PR) |
|---|---|---|
| **Main game scene, idle** (grid, 2 entities, fog rect, 2 HUD labels) | ≈ 8–10 calls | unchanged (already batched) |
| **Chalk lines, full board** (50 × unique ShaderMaterial, TIME-based shader → no batching) | ≈ 50 calls | unchanged count (pooling removes alloc, not calls) — documented as the top future lever |
| **Ghost lines** (≤ 8 visible on ghost client) | ≈ 8 calls | unchanged (pooled) |
| **HintMarker** | 1 call/item, redrawn 60 fps | redrawn **30 fps** (halved vertex gen; pulse/orbit are slow) |
| **Tutorial scene** root `_draw` (dots/rings/stamp/flash) | 1 call/item, redrawn 60 fps | redrawn **30 fps** (60 fps only during the 26 Hz accuse wobble) |
| **GhostHand** (11 prims/item, redrawn 60 fps) | 1 call, ~11 prims rebuilt + uploaded 60×/s | 1 call, **3 prims** (baked texture + glow + ripple), redrawn **30 fps** |
| **Villager / Cow / FogSystem** | redraw only when dirty / throttled already | unchanged — already good |

Net effect: draw-call count is essentially flat (it was already item-bounded),
but per-frame **vertex rebuild/upload and allocation churn are roughly halved**
on the tutorial scene and HintMarkers — the actual jank source on low-end
phones. The future big win, enabled by §6: when the 28 village sprites are
placed, using the atlas means all same-texture sprites **batch into 1–2 draw
calls** instead of 28 texture switches.

## 6. Sprite atlas (`assets/atlases/`, `tools/pack_atlas.py`)

Two atlases built from the originals (which are **kept untouched**):

| Atlas | Sprites | Canvas | PNG size |
|---|---|---|---|
| `environment_atlas.png` | 22 props | 256×1768 | 444 KB |
| `entities_atlas.png` | 6 entities | 256×152 | 33 KB |

Each sprite has a `.tres` **AtlasTexture** resource
(`assets/atlases/<category>/<name>.tres`) referencing its region, plus a JSON
manifest per atlas. Regenerate any time with `python3 tools/pack_atlas.py`
(needs Pillow). Layout is shelf-packed for minimal area, padded to 4 px
(ETC2/ASTC block alignment).

Impact: 28 GPU textures → 2 (≈ 1.2 MB → ~0.45 MB VRAM at ETC2 for the same
pixels, plus batching once sprites are placed), and PCK shrinks (atlas PNGs
0.48 MB vs 0.73 MB separate). **No scene references the atlases yet** — that's
the village-integration task; the .tres resources are the packaging path.
Flagged for engine-time validation: open one .tres in the editor and confirm
the region shows the right sprite.

## 7. Memory profiling (`scripts/debug/ProfilerOverlay.gd`)

Autoload (`ProfilerOverlay` in `project.godot`) — a compact top-right panel
showing FPS, frame time, **draw calls**
(`Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME`), 2D item count, static RAM
(`OS.get_static_memory_usage`, peak), and node count. Refreshes at 2 Hz.

- **Toggle:** F3 (keyboard) or **third simultaneous finger down** — chosen so
  it never collides with the 1-finger move or 2-finger draw gestures.
- **Release builds:** `OS.is_debug_build()` is false on Android release
  exports → the autoload creates no UI and disables `_process`/`_input`.
  Zero cost.
- **Profiling on a real device:**
  1. Export a **debug** APK (keeps the overlay) and `adb install`.
  2. `adb shell am start -n com.chalkgaon.ghostlines/.MainActivity` or launch
     from the launcher, then toggle the overlay in-game.
  3. Android Studio → Profiler (or `adb shell dumpsys meminfo
     com.chalkgaon.ghostlines`) for the system-level RAM view; the overlay's
     "RAM" line is Godot's own allocator view — the two differ by native libs
     and OS overhead.
  4. For frame-by-frame GPU work, Profile GPU Rendering on the device
     (Developer options) while the overlay is on.

## 8. Documentation updates

- `assets/ASSETS.md` — §"Atlas packaging" documents the atlases, regions,
  regeneration script, and that originals remain canonical.
- `architecture.md` (shared team doc) — new §7.15 Pool + §7.16 ProfilerOverlay
  in the existing style.
- This file is the in-repo record of every optimization + its numbers.

## 9. What needs an engine / device build to verify

1. **Export preset** — real `export apk` (needs Android SDK + templates);
   confirm the APK size lands < 30 MB and the listed permissions appear in the
   merged manifest.
2. **Texture import** — first editor open re-imports everything; check the
   ground shows VRAM-compressed + mipmaps and sprites VRAM-compressed without
   mips. The hand-written `.import` uid/hash may be rewritten — fine.
3. **Audio** — listen on device: sounds should sound identical at 22.05 kHz;
   confirm whether truncation to buffer length (~0.1 s) is audible (see §3).
4. **Pooling** — play a full round drawing/erasing lines and run the tutorial
   bursts; visuals/behavior must be pixel-identical to before.
5. **GhostHand bake** — the SubViewport one-frame bake must complete (hand
   visible at full quality). If the bake viewport misbehaves on some device,
   the fallback `_draw_hand_body()` keeps the hand rendering.
6. **Profiler overlay** — toggles on debug builds, absent on release.
7. **Atlas .tres** — spot-check regions in the editor.
