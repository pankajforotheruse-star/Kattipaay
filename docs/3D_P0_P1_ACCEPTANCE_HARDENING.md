# 3D P0/P1 acceptance hardening — November 2026

**Protected branch:** `feature/chalk-gaon-3d-migration` only. Do not merge into `main` without explicit owner approval.

This iteration hardens the existing Godot 4.4 independent 3D scene; it does not replace the original 2D game or claim a production-ready 3D release.

## Engineering changes by owner priority

| Priority | Feature | New implementation | Evidence / remaining release risk |
|---|---|---|---|
| P0 | Rooftop and obstacle traversal | Ground graph supports nearest valid endpoints; CPU chooses nearest publicly mapped rooftop and plans physical ramp ascent, rooftop anchor, descent and return. Stuck-route recovery and cumulative rooftop metrics exist. | Four-roof capsule physics test; new real-CPU-controller ascent/descent test. Multilevel dynamic navigation, arbitrary roof coverage and off-mesh actions still need device/playtest validation. |
| P0 | Segment-level chalk visibility | Real per-segment raycasts, actor self-exclusion, conservative moving-parent bounding sphere, shared material. No marks are silently removed. | New physical barrier/partial-exposure/cover reveal/300-stroke test and CPU blocked-line regression. Complex irregular meshes, undersides and 300-stroke device frame time remain open. |
| P0 | Round reset and scoring safeguards | Result finalization is idempotent; no post-result strokes or phase advances; drawing strokes finalize on phase exit; safe cover reset after meeting teleport; versioned isolated result history includes search telemetry. | Playtest, parity, persistence and full 3D cycle tests. Complete in-progress save/resume and long-running replay soak remain open. |
| P0 | Fair CPU exploration | CPU chooses public map routes independent of hidden human coordinates; visible chalk only through physics raycasts; cover inspection requires real CPU distance, sight and opponent territory; inspections are time-limited. | Occluded mark must remain unstruck until physical blocker is removed. Empirical 100+ round difficulty balancing and real human behavior profiles remain open. |
| P1 | Authoritative interaction checks | Drawing is raycast/territory/range/surface validated; searching and cover interactions have phase/role gates; defender is restricted to own zone; close-cover action blocks replacement into an actor. | Requires full online server authority if multiplayer is implemented, physics shape overlap for all props and negative-case device tests. |
| P1 | Camera/UI/audio | Smoothed, recast camera; animated coin, winner banner, compact contrast-safe phase clock HUD; original chalk-strike, coin and timer audio; physical path-based defender follow with manual override. | Real skeletal animations, PBR art, tactile audio, accessibility, safe-area review and Android screenshot/video walkthrough still outstanding. |
| P1 | Android performance | Distant chalk broad-phase culling, shared material, one mesh rebuild per drag event, CPU perception throttling, human reveal scans at ~8Hz, 300-stroke retention test, simulated touch separation. | **No Android FPS, memory, battery or thermal measurements yet.** 300 separate stroke meshes may still produce high draw calls; batching/LOD requires profiling before shipping. |

## Automated acceptance scripts

- `ChalkGaon3DRoofPhysics.gd`: actual `CharacterBody3D` physics across four roofs
- `ChalkGaon3DCpuRoofMotion.gd`: real CPU controller ascent and descent via its route (not only generic physics tester)
- `ChalkGaon3DNavigationAuthority.gd`: CPU public roof itinerary and defender territory/path checks
- `ChalkGaon3DVisibilityStress.gd`: partial exposure, occlusion, movable cover, 300 retained marks, serialization
- `ChalkGaon3DPlaytestRegression.gd`: CPU strikes visible chalk but not occluded chalk, result idempotence
- `ChalkGaon3DTouchArbitration.gd`: simulated movement/draw touch IDs, release and pause
- Existing CPU balance, owner parity, cover persistence, round smoke, E2E and full original game tests remain mandatory

Workflow: `https://github.com/pankajforotheruse-star/Kattipaay/actions/workflows/village-graybox.yml`.

**Acceptance standard:** Only a successful workflow run at the exact latest commit establishes these headless assertions passed. Tests do not measure graphics, perceived movement quality or Android performance.

## Required Android and visual QA before 3D MVP

1. Export Godot 4.4 Android APK/AAB; verify Android 8+ startup, orientation, input, pause/resume, audio, touch safe areas and rendering on low/mid/high tier phones.
2. Record full 40s drawing + two 30s searching sessions, using real fingers, with roof and cover strokes and 100–300 persistent marks.
3. Profile `RenderingServer` draw calls, 99th-percentile frame time, physics/raycast CPU time, memory and battery/thermal over at least 30 minutes. Suggested starting targets: stable 30fps entry class, 60fps mid-tier, subject to actual device capability.
4. Replace remaining primitive props and placeholder rigs with properly licensed, optimized PBR village assets and rigged locomotion/inspection/drawing/striking animations.
5. Run at least 100 complete reproducible games per difficulty and human profile, with saved telemetry and human playtesting. Validate increasing difficulty without unfair omniscience; no universal industry-standard win-rate exists for this ruleset.
6. Validate multiplayer only after designing actual server-authoritative commands, replay/reconnect and abuse-resistant state transitions. The current 3D match is offline and not a network authority.

**Release decision:** Do not merge to main or claim full parity until the above manual, empirical and production-art gates pass.
