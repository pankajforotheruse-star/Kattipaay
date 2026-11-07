# Chalk Gaon 3D — production presentation, balance and Android QA

**Protected branch:** `feature/chalk-gaon-3d-migration`. This work does not change or merge `main`.

## What is now implemented

### Visual presentation and audio

- `VillageArt3D.gd`: original authored modular 3D village dressing: doors, timber rafters, brick plinths, shutters, clay pots, village well, charpai, straw bundles, pennants and two GPU-batched vegetation layers. Decorative geometry has **no collision**, so it does not compromise hidden chalk, navigation or roof routes. Low/balanced/high detail settings.
- `VillageGraybox.gd`: physically collidable two-zone courtyard with four walkable roofs and ramps, directional shadows, procedural sky, plaster/wood/stone materials; cached surface materials and configurable rendering resolution.
- `CharacterRig3D.gd`: articulated, state-blended procedural locomotion, breathing, crouch, draw, search/inspect, strike, argument and coin gestures driven by actual game actions.
- `VillageSoundscape3D.gd`: original generated PCM spatial wind, cicadas, birds, soil/stone footfalls. Uses small 11.025kHz mono streams and disables playback in headless tests. Existing `AudioManager` handles timer/coin/chalk/argument cues.
- `GameWorld3D.gd`: round timer/progress bar, aiming reticle, contextual controls, touch pause, coin and result UI.

**Important art limitation:** These are original procedural low-poly assets and articulated animation, not licensed photogrammetry, professionally textured PBR GLB assets, motion-captured skeletal animations, or recorded field ambience. They improve the *playable 3D vertical slice*; a professional artist/audio pass and actual in-editor/device screenshot reviews are still required to certify shipping-level realism.

### Real-world balance instrumentation

- Every completed local 3D match records difficulty, result, marks/survivors, CPU inspections, distinct 2m search cells, roof visits, and input activity in `user://chalk_gaon_3d_match_telemetry.jsonl`.
- `MatchAnalytics3D.gd` computes per-difficulty human win rates, 95% Wilson confidence intervals, mean CPU search coverage and mark counts. **Scripted matches are excluded from human statistics.**
- `scripts/analyze_3d_playtests.py <jsonl>` generates a report and explicitly marks difficulties with fewer than 100 complete recorded matches as not certified.
- `ChalkGaon3DScriptedMatchBatch.gd` runs seeded clock-driven full matches against a **scripted physical player**, with actual CPU placement, movement, sight and scoring. The script labels these as simulated/scripted and never presents them as real human sessions.
- `.github/workflows/3d-scripted-balance.yml` is a **manual opt-in** 100+ complete match study per difficulty (four parallel jobs, 40s drawing + 15s meeting + 2×30s search). The normal CI only runs one accelerated harness smoke. **Do not report 100+ runs as performed unless the manual workflow succeeds and its artifacts have been examined.**

### Android QA and performance

- `AndroidPerformance3D.gd`: opt-in runtime sampling every 0.5s, p50/p95/p99 per-frame game-loop delta from a bounded 0.5ms histogram (not GPU presentation timing), mean draw calls, physics frame time and peak static memory. In-game QA HUD and CSV/JSON export.
- F9 or the **SAVE QA** touch button writes `user://chalk_gaon_3d_perf.csv` and `chalk_gaon_3d_perf_summary.json`; F10 or **SNAP** captures a PNG.
- `.github/workflows/3d-android-qa.yml` provides a **manual opt-in** Android QA APK build per render tier. It must be run and verified before claiming an APK is available.\n- `scripts/android_3d_qa.sh build [low|balanced|high]` temporarily selects the 3D scene as Android launch scene and enables profiling. It restores `project.godot` and `export_presets.cfg` on exit. Requires Godot 4.4, Android SDK/JDK, and Godot Android export templates already configured.
- `scripts/android_3d_qa.sh collect <folder>` collects ADB gfxinfo, meminfo, battery/thermal service information (where available), and debug-build `user://` files. Debug APK must be installed and running; `adb run-as` may not be available on non-debuggable builds.
- Android quality profiles: low (0.75 render scale, no dynamic shadows/fog, reduced vegetation), balanced (0.9), high (1.0, increased vegetation). These are initial settings, not empirically tuned device presets.
- Existing touch arbitration regression remains, plus presentation, stats/export and scripted-match harness tests.

## How to perform actual acceptance

1. **Visual QA:** open `scenes/3d/game_world_3d.tscn` in Godot 4.4, record drawing, coin, both searches, roofs, hidden cover, animation and end screen. Compare screenshots against an agreed village art-direction reference. Validate text contrast, color accessibility, audio loudness and mobile landscape/portrait safe areas.
2. **Balance:** obtain at least 100 completed **human-controlled** matches per difficulty, across multiple players and strategies. Record which sessions were actually played by humans. Analyze with `python3 scripts/analyze_3d_playtests.py <collected-jsonl>`. Review confidence intervals, win rates, search coverage, strikes, mark counts and roof coverage. No universal industry-standard win-rate threshold exists; choose difficulty-specific targets based on your game design and player testing.
3. **Scripted regression:** manually dispatch `3D Scripted Balance Study` with 100+ per difficulty. Check its JSON and log artifacts. These are reproducible regression data, **not** substitutes for human balance.
4. **Device QA:** on at least one entry-tier and one mid-tier Android 8+ device (preferably a third higher-tier phone), build/install the 3D QA APK and play a complete match with two thumbs. Validate screen safe areas, audio, touch release, background/resume, roof traversal, cover and 100–300 strokes.
5. **Sustained performance:** run for 30 minutes with CPU search, rooftop visits and 300 chalk marks. Collect ADB diagnostics and in-game CSV. Initial targets: entry-tier ≥30fps and mid-tier ≥60fps when supported, with controlled p95/p99 frame pacing, no runaway memory growth or critical thermal throttling. Thermal and battery must be measured from the device/OEM tools; Godot does not expose universal thermal data.
6. **Release review:** complete actual PBR model and skeletal animation authoring/licensing, sound mixing, accessibility, UX polish and real-device profiling before claiming AAA/industry-grade production quality.

## Automated evidence policy

- Headless Godot import and automated tests verify scripts, geometry, physical rules and synthesized sound buffers. They **cannot** verify rendered visual fidelity, speaker quality, touch comfort, device FPS, thermal behavior or genuine human play.
- `ChalkGaon3DProductionPresentation.gd`: authored art structure, sound generation, character poses and HUD.
- `ChalkGaon3DAnalyticsQA.gd`: statistical formulas and QA export using **synthetic fixtures only**.
- `ChalkGaon3DScriptedMatchBatch.gd -- --fast`: short complete-match harness smoke; manual workflow runs full clocks.
- Existing 3D gameplay/rooftop/visibility/cover/touch/CPU regression and original 2D CI remain in place.
- Only the exact latest feature-branch commit with passing workflows is considered code-verified.

**Merge policy:** No merge or direct edits to `main`. Do not merge the 3D feature branch until the owner explicitly approves and human/device release gates are met.
