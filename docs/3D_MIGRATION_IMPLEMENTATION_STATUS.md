# 3D migration branch — implementation and release gate

**Branch:** `feature/chalk-gaon-3d-migration` (branched from `feature/3d-village-graybox`). **Never merge to `main` without explicit owner approval.**

## Source-of-truth game rules

Continue to use existing `SoloMatchDriver.gd`, `GameState.gd`, `ScoringManager.gd`, `ChalkLine.gd` (for the original 2D mode), and the game requirements as the rule authority. Counter-Strike is only a **design reference** for spatial gameplay, collision, navigation, cover, jumping and line-of-sight. Do not copy its code, assets or unrelated shooter mechanics.

## Delivered prototype components

- `scripts/3d/Territory3D.gd`: coordinate-based zone classification; draw authorization; phase-aware entry policy, unconnected to old match.
- `scripts/3d/ChalkStroke3D.gd`: per-surface local geometry, depth-tested rendered ribbon, ownership, strike/discovery/sneak metadata, versioned serialization.
- `scripts/3d/CpuSurfacePlanner3D.gd`: environment-only surface candidate probing and occlusion scores (no access to hidden human strokes); navigation and line placement remain unconnected.
- `scripts/3d/DrawController3D.gd`: third-person Camera3D raycasts, no predefined drawing points; max player-to-surface reach, surface collision and territory checks, single-surface strokes and versioned save/restore.
- `scripts/graybox/VillageGraybox.gd`: debug F key toggles mouse cursor and 3D drawing in standalone level.
- `scripts/tests/ChalkGaon3DMigrationTest.gd`: automated territory, mesh, ownership and serialization checks.
- `.github/workflows/village-graybox.yml`: pinned Godot 4.4 headless project import, graybox structure test, 3D logic test and original Play vs CPU regression.

## How to inspect

Open `scenes/graybox/village_graybox.tscn` and run current scene (F6) in Godot 4.4 stable. Move with WASD, orbit with mouse, Space jump, Shift sprint, C crouch, Tab switch debug territory. Press F to toggle drawing mode (cursor visible) and drag left mouse on a nearby physical wall, ground or roof. **Drawing is only permitted on the PLAYER territory in this demonstration.**

This is a **3D drawing prototype**, not a full migrated playable round. Rendering, mouse interaction and occlusion need interactive inspection.

## Migration work still essential before 3D replaces 2D mode

1. **Character integration:** Build new 3D player and CPU entity adapters without changing IDs, event contracts, mouse/touch controls or UI.
2. **Phase/territory enforcement:** Convert `SoloMatchDriver` event transitions to `Territory3D` gates, not just coordinate rules; add physical transitions, meeting alley and role swap for both sides.
3. **CPU navigation:** Bake NavigationRegion3D per territory; NavigationAgent3D ground + climb links; path validation and actions for ramps/ladders; no blind teleport.
4. **CPU mark placement:** Surface sampling with environmental hiding scores, reachable poses, cover visibility and varied difficulty; no predetermined line spots. No artificial fixed human mark limit.
5. **Search discovery:** Per-stroke visibility, actual occlusion and line segments (not single line-wide cover flag); inspection actions, searching around occluders, reveal then strike. No omniscient CPU access to hidden strokes.
6. **Defender sneaks:** Mobile character movement and draw validation while defending; detection based on line-of-sight, proximity, noise/timing and existing penalty rules, not arbitrary global probability.
7. **Round parity:** Existing 40s draw, meeting/coin, two 30s search phases, arguments, defender sneaks, chalk exhaustion, winner/survivor scoring, undo and pause all need event-level tests; values remain configurable.
8. **Persistence/network:** Map old serialized 2D lines to versioned 3D model only with explicit migration; reject cross-surface invalid strokes and unsupported versions. Keep networking 2D compatibility until 3D protocol is ready.
9. **Mobile/Android:** Touch-drawing, camera orbit controls, collision layers, draw reach, performance/LOD, occlusion and UI safe areas need device testing.
10. **Sanity and proof:** Godot 4.4 build/headless tests, 3D complete-round smoke tests, CPU pathfinding test, hidden segment test, save/reload test, 2D regressions and visual walkthrough.

## Current test evidence

Consult the latest run at https://github.com/pankajforotheruse-star/Kattipaay/actions/workflows/village-graybox.yml for exact results. Older runs DO NOT guarantee newer commits pass. Engine parsing and headless structural/logic checks are necessary but not sufficient for real collision, draw pointer placement, or CPU play.

## No-merge policy

Only feature branch changes are authorized. Do not open/merge a pull request targeting `main` until owner explicitly confirms approval. Preserve all existing 2D files and production main scene until 3D mode achieves rules parity, regression coverage and owner sign-off.
