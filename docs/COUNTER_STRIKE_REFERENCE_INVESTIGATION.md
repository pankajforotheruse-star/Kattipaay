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


---

# Second-pass investigation — additive findings (2026-11-03)

**Preservation policy:** All previous report sections above remain intact. This appendix adds findings, revises priorities, and notes limitations; it does not overwrite the first pass. Source links refer to upstream moving branches, not pinned commits.

## A. New source-verified findings

### A1. CS 1.6: outcome checks are explicitly guarded against repeated resolution
In \`regamedll/dlls/multiplay_gamerules.cpp\`, \`CHalfLifeMultiplay::__API_HOOK(CheckWinConditions)\` checks existing round-win status and returns rather than re-resolving an already decided round.
Evidence: https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/multiplay_gamerules.cpp (function \`CheckWinConditions\`).
**New Godot suggestion:** ensure all terminal Chalk Gaon round transitions are idempotent: repeated timer signals, late mark-strike events and reconnection events must never award scoring twice. Implement a validated \`phase_epoch\` or \`round_id\` with terminal-state guards, test duplicate and out-of-order events.

### A2. CS 1.6: round restart orchestrates more than a timer reset
\`CHalfLifeMultiplay::__API_HOOK(RestartRound)\` notifies bots, resets certain entities, manages round count and resets movement settings. This shows a central reset boundary for dependent systems; do not duplicate Counter-Strike settings.
Evidence: same file, function \`RestartRound\`.
**New Godot suggestion:** orchestrate chalk lifecycle, cover open/closed state, AI search memory, actors/spawns, role swap, camera and HUD from one canonical reset event. Ensure stale asynchronous callbacks from the previous phase cannot mutate the new round.

### A3. Source SDK: step movement evaluates alternate physical paths
\`src/game/shared/gamemovement.cpp\` \`CGameMovement::StepMove\` attempts baseline movement versus stepped-up/stepped-down movement and compares progress while using player hull traces.
Evidence: https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/gamemovement.cpp (\`StepMove\`, \`TryPlayerMove\`).
**New Godot suggestion:** define explicit capsule collision, floor snapping, slope-angle and step-height policies for \`CharacterBody3D\`; build approach ramps or traversable rooftop geometry. Test rising and descending edges, low ledges, walls, tight corners and falls. Do not claim current \`playground_3d/PlayerController3D.gd\` already provides step climb: it currently only uses \`move_and_slide\`.

### A4. Source SDK: movement traces account for solid-start and stuck states
\`CGameMovement::TryPlayerMove\` uses \`TracePlayerBBox\`; if entirely solid, movement is blocked, and in certain paths the code rechecks occupancy at a purported clear destination before accepting it.
Evidence: same Source SDK file, functions \`TryPlayerMove\`, \`TracePlayerBBox\`.
**New Godot suggestion:** validate every initial spawn with \`PhysicsDirectSpaceState3D\` shape overlap/cast, and add a safe non-teleporting response to a blocked route: replan or return to last valid reachable position where permitted by established game rules. Add adversarial tests for objects closing on actors, blocked alley, interpenetration and AI path failure.

### A5. CS2: mapping pipeline is an established public tool surface, not gameplay source
Valve's June 6 2023 release notes introduced CS2 Workshop Tools and described Hammer GPU-accelerated ray-tracing for lighting preview/bake.
Evidence: https://store.steampowered.com/news/posts/?appids=730&enddate=1686088105&feed=steam_community_announcements
**New Godot suggestion:** use the *map-design principle* of clear playable geometry and lighting to make hidden versus exposed chalk legible; author original Godot assets and use the Godot mobile renderer. No CS2 source algorithms or workshop assets are incorporated.

## B. New findings from inspecting the current experimental 3D branch
1. \`playground_3d/PlayerController3D.gd\` offers acceleration, drag, gravity and \`move_and_slide\`, but lacks authored climb/step policy, grounded spawn validation, camera-relative navigation, interaction raycasts, roof traversal and controller/touch mapping. Treat this as a graybox only.
2. \`playground_3d/ZoneManager3D.gd\` classifies territory using world X/Z only. It does not validate roof height, connectivity, phase rules, inaccessible islands, or who owns the active territory. Its \`can_draw_in_territory\` is a placeholder geometry predicate, not authoritative permission.
3. \`playground_3d/Playground3D.tscn\` has floor, a single divider obstacle, two actors, and camera/light. There are no wall/roof chalk surfaces, scene navigation regions, reachable interactive covers, opening physics or multiplayer synchronization. Existing 2D main scene remains unaffected.
4. **Important implementation warning:** on the inspected scene the floor \`BoxMesh\` spans X=-6..+6, while spawn positions are X=-3 and +3, so there are two sides. The partial divider centered at X=0, Z=-3 is not a full two-zone phase barrier. The literal positions are graybox coordinates; they must not be confused with the existing 2D village layout.
5. Static-source inspection does not establish Godot 4.4 parser/runtime correctness. Run the actual engine before reporting this scene as functioning.

## C. Revised 3D upgrade priorities

| Priority | Improvement | Target module | Required empirical gate |
|---|---|---|---|
| P0 | Phase-epoch guards and idempotent scoring/reset | Existing SoloMatchDriver through adapter | Repeated/delayed events never double score |
| P0 | Physical collision, legal spawns, reachable alley and rooftops | PlayerController3D, Playground3D, NavigationRegion3D | No wall clipping; tested climb/step/fall routes |
| P0 | Surface-local strokes and per-segment occlusion | New 3D StrokeRegistry/Visibility | Open/wall/roof/movable cover, mixed visibility |
| P0 | No secret CPU location reads | New CPU exploration and shared visibility predicate | Seeded fairness and traceable observations |
| P1 | Authoritative zone, ownership, distance and cover rules | ZoneManager3D + rule adapter | Impossible mark and strike actions rejected |
| P1 | CPU physical escort/replan/recovery | NavigationAgent3D | No wall-phasing or magically instant travel |
| P1 | Original game UI/audio with readable 3D feedback | HUD/audio adapter | 2D parity and Android touch playtests |
| P1 | Mobile performance under hundreds of human marks | Batched/multimesh or pooled stroke rendering | Measure FPS, memory, frame times; no silent deletion |

## D. Suggested implementation architecture
- Use **one canonical \`MatchRulesAdapter\`** to consume existing \`SoloMatchDriver\` state, not a second competing match manager.
- Define \`Actor3D\` physical transform and \`MarkSurface3D\` surface-local coordinate records, with stable serialized IDs; store stroke truth independently of rendered meshes.
- Implement \`VisibilityQuery3D\` returning per-segment classifications (exposed, geometrically occluded, physically covered, revealed after inspection) and evidence for each classification. Both CPU and human queries must share it.
- Implement public-information-only \`CpuWorldModel3D\`: known geometry, visited sites, observed opened covers, detection results; no unrevealed stroke coordinates.
- Gate every draw/inspect/strike action on phase, role, active zone, physical reach, surface/collider, occlusion, and server authority where networked.
- Retain the existing 2D implementation and solo regression suite until all 3D acceptance gates and Android checks pass.

## E. Second-pass limitations and provenance
- The additional source snippets above were examined directly in publicly accessible upstream text; no cloned reference binaries, immutable hash snapshots, CS2 running game or Ghidra analysis were used.
- This is a second source-backed **architecture** pass, not an exhaustive line-by-line audit of all Counter-Strike engines. Actual CS2 gameplay internals remain unavailable.
- No Godot 4.4 test, CPU balance simulation, rooftop playtest or Android device test was run in this pass.
- All additions are research recommendations only; **no gameplay implementation was modified** in this second pass.
