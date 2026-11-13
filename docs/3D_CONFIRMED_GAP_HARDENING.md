# 3D confirmed-gap hardening (Godot 4.4)

Branch: `feature/chalk-gaon-3d-migration` only. **Never merge to main without owner approval.**

## P0 — Equal physical discovery

Both human and CPU strikes now call `ChalkStroke3D.visible_to_eye` using the **same 3.5m maximum eye-to-visible-segment distance**, the same occlusion raycast and the shared `ChalkMatchRules.can_strike` permission. CPU difficulty still changes movement speeds, reaction/strike delay and exploration; it **does not grant farther detection**. The CPU must actually move into range and see an uncovered segment. Existing per-segment visibility behavior remains intact.

## P0 — Multilevel navigation

`MultiLevelNavigation3D` creates one `NavigationRegion3D` per valid roof and a `NavigationLink3D` for each physical ramp. Ramp, landing and roof transitions are sampled against the actual colliding geometry, support normals and vertical elevation. Invalid or missing connections are rejected, not teleported. The existing obstacle-aware `GroundNavigation3D` remains the ground-floor route planner. The live CPU follows the validated multilevel waypoint itinerary using `CharacterBody3D.move_and_slide()`, including the descent.

**Scope limitation:** This is a hybrid *ground grid + multilevel roof regions/links* system, not a universal auto-baked multi-storey navmesh. New ramps/roofs require properly placed transition markers and physical surfaces; ladders, jumps, inaccessible ledges and dynamic re-baking are deliberately unsupported until traversal animations and explicit action links are implemented. No general traversal is claimed for arbitrary buildings without those inputs.

## P1 — CPU drawing throughput

CPU drawing now tracks every physical attempt, failure, actual mark, target and shortfall. A failed placement retries promptly rather than wasting an entire drawing interval. The CPU can plan toward reachable public-surface drawing sites and only places marks after arriving in range and passing live raycasts. Jittered probe origins reduce repeated identical proposals. The remaining target dynamically adjusts the next drawing cadence.

**Honest limitation:** A strict guarantee of 50–180 physically valid marks in 40 seconds is impossible without adequate reachable surface area, speed and search capacity. The system does not create invisible/invalid marks to fake target attainment. The opt-in `3D Scripted Balance Study` must be run for 100+ **complete** matches per difficulty, and any shortfalls investigated from its JSON metrics before balance is certified.

## P1 — Shared owner-approved rules

`ChalkMatchRules.gd` is used by the 2D `SoloMatchDriver`, the 2D `ScoringManager` and the 3D `GameWorld3D`. It owns the same player IDs, phase searcher swap, fair coin result, survivor-wins/draw resolution, opposing-stroke strike permission and CPU target ranges. Existing 2D event-driven state machine remains intact; 3D retains its scene-specific clock/animation adapter. A complete unification of all 2D/3D phase machinery is not claimed.

## P1 — Shape-correct cover replacement

`_can_restore_cover` queries **every active CollisionShape3D** at the exact stored original global transform, excluding only the lifted cover itself. It refuses to restore into characters, walls, other covers or other blocking physics bodies. A failed restoration leaves the cover lifted; the CPU retries and player receives feedback. Physics query regression tests check overlap and clear placement.

## P1 — Authoritative multiplayer milestone

`Chalk3DAuthority.gd` implements a **transport-neutral server-only action gate** with server-assigned peer ownership, monotonically increasing action sequence numbers, phase-epoch replay protection, owner/phase validation and server-side raycast/visibility checks for draw segments, strikes and movable covers. It never trusts client-reported discovery, stroke ownership or coin outcome.

**Still pending:** This class is *not* a working 3D multiplayer mode. The 3D scene still runs its local CPU match. A separate ENet lobby/connection lifecycle, server-owned actor movement and clock, replicated strokes/covers, snapshots, late joins/reconnections, server-side movement anti-cheat, rate limiting, integration of all local inputs with the authority gate, and network fault/latency tests are required before the game can claim server-authoritative 3D multiplayer. Do not enable network gameplay by treating the authority gate alone as sufficient.

## Acceptance and regression

- `scripts/tests/ChalkGaon3DParityHardening.gd`: shared rules, equal detection, four multilevel roof links, rejection of vertical ledges, full cover overlap and CPU target accounting.
- `scripts/tests/ChalkGaon3DAuthorityQA.gd`: unregistered peers, duplicate owner, replay/out-of-order, stale phase, forged actions and server-controlled coin.
- Existing 3D user playtest, CPU physical movement, roof ascent/descent, segment visibility, touch, cover persistence and original 2D CI must all remain green.
- Full match throughput and human win rates need real measured evidence, not just fast CI fixtures.

**Protected main:** No changes or merges to `main`.
