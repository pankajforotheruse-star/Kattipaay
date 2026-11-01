# Counter-Strike research → Godot 4.4 migration: baseline audit and implementation gates

**Status:** Initial source-inspection report, not a completed 3D implementation or full test report.  
**Base:** `main` at `2e6115b02ca5f8843f61db06459510d6af78c06a` (2026-11-02 inspection).  
**Work branch:** `feature/cs-research-godot44-3d-playground`. **Never merge automatically into main.**

## Confirmed current architecture (source-inspected)

| Component | Existing source | Verified observation |
|---|---|---|
| Engine configuration | `project.godot` | Godot 4.4 mobile project, main scene `scenes/main.tscn`, 10 autoloads, mobile renderer. |
| Playable world | `scenes/game/game_world.tscn`; `scripts/game/GameWorld.gd` | Top-down Node2D scene with sprites and CharacterBody2D entities. GameWorld constructs scenery, village navigation, cover and defender escort for solo mode. |
| Round lifecycle | `scripts/game/SoloMatchDriver.gd` | DRAWING → MEETING/COIN → two alternating SEARCH phases → scoring/winner; current default 40s draw and 30s each search. |
| Chalk | `scripts/systems/DrawSystem.gd` | Legacy `MAX_ACTIVE_LINES=50` still appears in source alongside solo-mode overrides. It is essential to trace the runtime solo path before asserting that arbitrary caps are gone in all cases. |
| Cover | `scripts/game/HidingRules.gd`; `docs/CHILDHOOD_MVP_RULES.md` | Shared public hiding geometry, owner-defined per-segment visibility requirement and inspectable physical cover; trace exact runtime predicates and edge cases before migration. |
| CPU search | `scripts/systems/CpuSearchController.gd` | Uses public-world patrols and location-limited line discovery. Difficulty controls speed and investigation, not the shared reveal radii. |
| CPU logic | `scripts/bot/GhostBotController.gd` | Contains older prototype prose and code paths alongside solo Play-vs-CPU evolution; verify live solo path separately. |
| Networking | `scripts/autoload/NetworkManager.gd` | Abstraction for session, lobby, migration, reconnect and authority; real multiplayer reliability is not yet established by this source read. |
| Tests | `scripts/tests/KattipaayPlayableSmokeTest.gd` | Existing end-to-end script covers solo loop and regression paths; must reuse tests and add 3D-specific ones rather than deleting them. |

### Documentation conflict / caution
- Root `README.md` still describes sneak penalties and older status statements, while `docs/CHILDHOOD_MVP_RULES.md` explicitly says cheating is deferred by default and the new rule is a five-line penalty when eventually implemented.
- The latter document still has historical feature-branch-only status text though the inspected `main` commit message says that work has been merged. Update documentation only after tracing authoritative runtime flags.
- The 2D `DrawSystem.MAX_ACTIVE_LINES=50` constant remains. That is **not proof** of a current solo cap: use branch-specific solo test paths and code tracing.
- Existing `README` states some features are pending, but it may predate newer merged behavior. Do not represent it as an authoritative current inventory.

## Public Counter-Strike reference matrix

### Counter-Strike 1.6
Reference: https://github.com/rehlds/ReGameDLL_CS  
Scope: reverse-engineered server GameDLL, **not** the GoldSrc engine as a whole.  
Research: round rules, team assignments, server-authoritative decisions, player state transitions.  
Godot translation: a pure round state model with validated phase transitions and team roles, fed into the current `SoloMatchDriver` via an adapter. Do not copy CS rules or theme.

### Counter-Strike: Source
Reference: https://github.com/ValveSoftware/source-sdk-2013  
Scope: official Source 2013 SDK with HL2/HL2DM/TF2 code; **not** complete CS:S source.  
Research: 3D player locomotion, traces/collision, spatial entities, client/server separation, prediction concepts.  
Godot translation: `CharacterBody3D`, `CollisionShape3D`, direct space-state raycasts, `NavigationRegion3D` and `NavigationAgent3D`. Implement independently; review restrictive SDK license.

### Counter-Strike 2
References: https://www.counter-strike.net/cs2 and https://developer.valvesoftware.com/wiki/Counter-Strike_2_Workshop_Tools  
Scope: official documentation, workshop tools and authorized behavioral observation; no claim of CS2 source code access.  
Research: player feedback, map readability, predictable interaction, camera and movement responsiveness.  
Godot translation: configurable 3D movement and inspection UX. Any numeric movement or networking claims need repeatable measurements, not speculation.

**Provenance gate:** Record exact reference commit hashes and source file/function paths when research clones are actually available. Do not claim those have been obtained by inspecting the reference landing pages.

## Proposed independent Godot 4.4 components

- `playground_3d/Playground3D.tscn`: separate experimental 3D scene, no replacement of existing main scene until acceptance.
- `playground_3d/PlayerController3D.gd`: physical movement, camera-relative input, wall and slope handling.
- `playground_3d/ZoneManager3D.gd`: two territories, spawn validators, phase/role permission checks, entry routes.
- `playground_3d/ChalkSurface3D.gd` and `StrokeRegistry3D.gd`: strokes attached to validated physical surfaces, stable identities and serialization.
- `playground_3d/SegmentVisibility3D.gd`: per-subsegment occlusion and cover inspection, never whole-line assumptions.
- `playground_3d/CpuNavigation3D.gd`: navigation-mesh routes, reachability, non-omniscient exploration, physical defender escort.
- `playground_3d/MatchRulesAdapter.gd`: map current drawing/searching/scoring semantics to 3D actors without reimplementing or changing the current rulebook.
- `playground_3d/AuthorityActions3D.gd`: validate zone, distance, visibility and stroke ownership server-side before mutating canonical state.

These are architecture proposals, **not yet created scripts**.

## Hard acceptance invariants
1. No arbitrary human solo stroke quota; >18px valid strokes survive until a legitimate strike or round cleanup.
2. Difficulty-based seeded CPU mark variation; no cheating by reading private line locations.
3. Identical physical discovery predicates for CPU and human, with segment-level visible vs hidden tests.
4. Searcher and defender must physically walk through navigable, collidable space.
5. Two-zone ownership/starting spawns/phase permissions and role swap must match existing rules.
6. Sneak cheating remains disabled by default unless explicitly approved; do not silently implement a historical two-line penalty.
7. Existing UI and 2D Play-vs-CPU flows remain runnable until 3D passes acceptance.
8. Multiplayer is not called production-ready merely because network abstractions exist.

## Execution milestones
1. **Inventory and contract capture:** trace full current scripts and regression tests; document current live solo branches and exact rulebook. No physics changes.
2. **Research provenance:** pin hashes, inspect CS1.6 and Source SDK source paths, measure CS2 behavior using authorized test environment.
3. **3D vertical slice:** scene + walls + both territories + CharacterBody3D + collision and valid walking/navigation. Preserve 2D entry point.
4. **Surface chalk:** strokes on horizontal/vertical/inclined surfaces; occlusion-split samples and movable cover.
5. **CPU search/escort and rules:** navigation-based patrol without secret knowledge; correct catching and scoring.
6. **Networking integration:** authoritative input validation and state replication; deterministic round state.
7. **Regression gate:** Godot 4.4 headless project import, all existing tests, new 3D tests, seeded CPU simulations and device acceptance.

## Test matrix and honest evidence
- **Existing baseline**: main merge commit message reports 546 unit and 200 component assertions, five E2E matches, and six green CI jobs. These are *historical reported results*, not tests executed in this research session.
- **Required new automation**: test two-zone spawn/role permissions, wall collision and traversability, stroke surface projection/serialization, partial occlusion, hidden cover flipping, unrestricted solo mark count, CPU determinism/variation, catch-rule invariants, multiplayer rejection of impossible actions, scoring, cleanup and 2D regression.
- **Manual acceptance**: Android 8+ input ergonomics, frame-rate/memory under hundreds of strokes, movement/camera feel, actual obstacle searching, multiplayer device sessions and measured win-rate balance.
- **Current execution**: code inspection only; no Godot binary executed, no CI triggered, no physical-device test completed. Fail closed on any assertion of test success.

## Main protection
The only permitted development target is `feature/cs-research-godot44-3d-playground`. Never force-push, never merge, and never modify `main`. Any proposed change to an owner-defined rule must be recorded and approved before implementation.
