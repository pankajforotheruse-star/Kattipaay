# Counter-Strike reference-code investigation — evidence and migration decisions

Date: 2026-11-02. Target: Godot 4.4. Branch: `feature/cs-research-godot44-3d-playground`. No main merge.

## Evidence classification and limitations
- **SOURCE-VERIFIED** means a named function or declaration was inspected in a public source file.
- **DOCUMENTED** means an official tool/repository description, not internal source code.
- **PROPOSED** means a new Chalk Gaon design; it is not an original Counter-Strike algorithm.
- Public web-rendered files were inspected; runtime measurements, full local clones, and precise reference commit SHAs **were not obtainable** because outbound git network resolution failed. The browser links below are to moving `master` paths, **not immutable pinned snapshots**. Therefore this completes the accessible *architecture reference investigation*, not exhaustive function-by-function code or CS2 reverse engineering.

## CS 1.6 — ReGameDLL_CS (SOURCE-VERIFIED)
Repository: https://github.com/rehlds/ReGameDLL_CS
- `regamedll/dlls/gamerules.h`: `CGameRules` defines spawn permissions, player damage, team relationship, client join/disconnect, game-over state and round-level lifecycle. `CHalfLifeMultiplay` declares `RestartRound`, `CheckWinConditions`, `CleanUpMap`, `ChangePlayerTeam`, and `InitializePlayerCounts`.
  Evidence: https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/gamerules.h
- `regamedll/dlls/multiplay_gamerules.cpp`: `CHalfLifeMultiplay::ReadMultiplayCvars` reads the configured round/freezing times; constructor initializes round state. `CHalfLifeMultiplay::__API_HOOK(CheckWinConditions)` explicitly guards already resolved rounds, initializes team counts, then checks conditions in prioritized sequence and stops at the first terminal condition. A `RestartRound` routine exists as declared in the header.
  Evidence: https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/multiplay_gamerules.cpp
- **Transferable pattern:** explicitly centralize phase/rule evaluation, short-circuit terminal conditions, maintain authoritative role and team state, and make reset a deliberate operation. Do **not** adopt kill, weapon, bomb, hostage or economy conditions.

### Chalk Gaon mapping
`scripts/game/SoloMatchDriver.gd` already owns DRAW → MEETING/COIN → SEARCH 1 → SEARCH 2 → SCORE/WINNER. Preserve its rules and isolate a phase validation interface; don't rewrite phase logic simply to imitate CS. `scripts/autoload/NetworkManager.gd` currently separates transport and authority concerns; adapt action validation rather than assuming the network layer is production-ready.

## Counter-Strike: Source — Source SDK 2013 (SOURCE-VERIFIED, indirect engine reference)
Repository: https://github.com/ValveSoftware/source-sdk-2013
Official README explicitly lists HL2, HL2 Deathmatch and TF2; this is **not** complete CS:S game code. Source SDK 2013 license is non-commercial and restricts reuse. Architectural study must not result in copied source shipped as GDScript.
- `src/game/shared/gamemovement.cpp`: `CGameMovement`, `PlayerSolidMask`, `TestPlayerPosition`, `TracePlayerBBox`, `CategorizeGroundSurface` show the movement design's separation of player hull traces, solidity masks and surface friction. Conditional client prediction and command/difference diagnostics appear in the shared movement implementation.
  Evidence: https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/gamemovement.cpp
- `src/game/server/player.h`: `CBasePlayer::PlayerRunCommand(CUserCmd *, IMoveHelper *)` declaration and team/command members expose the per-command simulation boundary on the server.
  Evidence: https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/player.h
- **Transferable pattern:** drive character motion through repeatable physics ticks, collide using a *body volume* rather than an origin point, perform surface/visibility traces separately from motion, and validate incoming actions against authoritative actor state. No assertion that Godot 4.4 replicates Source prediction or physics identically.

### Chalk Gaon mapping
- Existing 2D: `scripts/game/GameWorld.gd` adds `CharacterBody2D` collision and navigable wall geometry.
- 3D target: `CharacterBody3D.move_and_slide` for locomotion, `CollisionShape3D` for physical hull; `NavigationAgent3D` / reachable navmesh for CPU routes; `PhysicsDirectSpaceState3D.intersect_ray` for stroke placement, visibility and interaction queries. Physics collision masks must discriminate terrain, markable surfaces, interactable covers, and actors.
- Record exact actor position, eye position, trace hit object, surface normal, local stroke data, cover state and timestamp when evaluating a discover/strike action. Compute visibility **per visible stroke segment**; a single boolean 'whole line hidden' is incorrect.
- Implement independently within experimental `playground_3d/`; do not replace 2D scene as main scene.

## Counter-Strike 2 — legitimate documentation/behavior ONLY (DOCUMENTED)
Official site: https://www.counter-strike.net/cs2
Valve Developer Community Workshop Tools: https://developer.valvesoftware.com/wiki/Counter-Strike_2_Workshop_Tools
- The public materials establish CS2's Source 2 content creation and Workshop/Hammer workflow. They do **not** expose a complete official CS2 game-server/client codebase.
- Controlled local gameplay observation (movement acceleration, jumping and step feel, camera interpolation, visibility/readability, obstacle traversal and input latency) would require an installed authorized CS2 environment and recorded measurement protocol; none was available in this session.
- Do **not** claim CS2 has a particular internal algorithm solely from marketing material, gameplay video or pseudocode generated by a decompiler.
- No need to decompile protected CS2 client binaries or bypass anti-cheat.

### Chalk Gaon mapping
Proposed (not source-recovered): smooth but responsive camera; recognizable cover shapes; clear inspector feedback; surface-normal-aligned chalk art; readable distance cues; controls tuned via device tests. No firearm/economy/bomb logic.

## Code-level decision / evidence matrix

| Topic | Evidence | Proposed Chalk Gaon action | Test gate |
|---|---|---|---|
| Round transitions | CS1.6 `gamerules.h`, `multiplay_gamerules.cpp` | Preserve `SoloMatchDriver`; add phase permission validator with explicit early exits | Two searches, correct toss and winner, clean replay |
| Teams / spawn | CS1.6 `CGameRules`/ `CHalfLifeMultiplay` | 3D two-zone role-aware spawns; reject illegal actions | Spawn in correct side, gate controls movement/draw/search |
| Collision | Source `CGameMovement::TestPlayerPosition` | 3D collider + physical paths, no teleport through obstacles | Solid wall and accessible approach tests |
| Surface properties | Source `CategorizeGroundSurface` | Surface type/normal/allowed stroke metadata | Ground, wall, roof orientation and restrictions |
| Search visibility | Source trace APIs as conceptual reference | Multiple eye-to-stroke-segment queries, separate cover inspection checks | Mixed visible/hidden stroke, obstacle occlusion |
| Input / authority | Source `PlayerRunCommand` and CS1.6 rule gates | Validate canonical phase, actor position, ownership, stroke and line strike | Reject remote impossible strikes |
| Navigational exploration | General 3D engine principle, not CS algorithm | CPU navmesh targets PUBLIC geometry only | No private mark coordinate leaks |
| UX feedback | CS2 documentation and eventual observed testing | Clear draw/search/inspect affordances | Android usability trials |

## Priority findings from current Chalk Gaon main
1. `project.godot` targets Godot 4.4 mobile and `res://scenes/main.tscn`; no modification to main scene is warranted at research phase.
2. `scripts/game/GameWorld.gd` uses `Node2D`, character colliders, `VillageNavigation`, `CoverSystem`, `DefenderEscort`; therefore the 3D conversion must reuse gameplay contracts rather than discard the proven 2D systems.
3. `scripts/systems/DrawSystem.gd` still defines `MAX_ACTIVE_LINES=50` for legacy modes. Owner's solo rule in `docs/CHILDHOOD_MVP_RULES.md` overrides historical caps. Full execution-path verification remains necessary.
4. Older `README.md` and older code comments describe alternate sneak rules, while the newer owner revision defers cheating by default. Any migration must retain disabled-by-default semantics pending explicit approval.
5. Code and historical merged-CI claims are not equivalent to newly executed Godot 4.4 tests. No tests run as part of this reference research.

## Recommended next implementation order
1. Audit live solo predicates, hidden-cover state, stroke storage and original 2D regression tests.
2. Validate the standalone 3D scene through Godot 4.4 headless import and script parser before integrating it anywhere.
3. Build 3D stroke projection/serialization and per-segment visibility with unit tests.
4. Add navmesh CPU exploration and defender escort; preserve information symmetry.
5. Integrate authoritative phase/zone/strike validation against existing `SoloMatchDriver`; keep 2D entry point.
6. Run existing and new headless tests, then Android and multiplayer manual tests.
7. Make no merge into `main` without explicit owner approval.

## Research provenance / open items
- Reference repository immutable SHAs and broader per-function code audits: **pending** (no local GitHub clone/network; inspected moving web source).
- CS2 observed measurements in real client/Workshop Tools: **pending** (no authorized running CS2 installation).
- Godot 4.4 execution and new 3D runtime integration: **not part of this research task; not tested**.
- No proprietary Source SDK/CS2 code or game assets copied into the project.
