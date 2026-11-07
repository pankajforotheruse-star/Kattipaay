# 3D game-feel rebuild: owner playtest response

**Branch only:** `feature/chalk-gaon-3d-migration`. No merge to main.

## What the owner's playtest revealed

The existing 3D scene was a **graybox development prototype**, not an art-directed game. Headless tests established code-level behavior but did not validate visual quality, tactile control or actual CPU detection during a player's full match.

## Changes made in this pass

| Owner issue | Change | Remaining acceptance |
|---|---|---|
| Jagged chalk lines | Screen drags interpolate every ~6.5 cm, reproject to the same real collider, batch mesh rebuilds; large discontinuities split strokes | Verify with mouse and Android finger, corners, curved/underside surfaces |
| Movement / clumsy map | Accelerated/decelerated human locomotion, damped third-person camera with collision recast and teleport reset; CPU acceleration and stuck-route recovery | Verify no input latency, camera clipping, collision stalls on real hardware |
| Can't draw freely | Reach increased to 9 m, ray reach 50 m; switching physical surfaces ends/starts strokes rather than silently dropping the rest | Validate walls, roofs, ground, crates, hidden faces; territorial ownership remains a rule |
| Poor coin toss | Animated gold coin with rotating/flip illusion and heads/tails reveal, no full-screen dimmer | Needs authored art, sound sync, accessibility and an actual dedicated coin ceremony state |
| Gray screen at strike phase | Camera follow recasts collision and snaps across phase teleports, preventing the camera traveling through opaque walls | User must reproduce/check: no definitive cause proven without a screenshot/log |
| CPU never strikes | Visibility ray excludes viewing actor's physics RID; CPU physically scans nearby chalk, patrols public courtyard routes, has larger search distances and throttled scan work | In-engine user-defect regression added; verify against real human strokes, obstacles, covers and rooftops |
| Game doesn't end | Result becomes a terminal frozen gameplay state and returns to the existing main menu after a result hold, with replay key available | Confirm UI navigation and result hold in an actual editor/device session |
| Cartoon look | Weathered procedural material variation, procedural sky, sunlight shadows, house architectural trim, tighter camera, animated human silhouettes rather than debug capsules | **Not a finished art pass**: replace all procedural placeholders with licensed PBR models, textures and skeletal character animation |

## Counter-Strike engineering lessons, adapted appropriately

- **Movement responsiveness:** acceleration and deceleration with a camera that respects level collision. The character is still third-person and noncombat; no CS code or mechanics copied.
- **Bot navigation:** collision-aware physical paths, clear waypoint intent, stuck recovery, publicly knowable routes, no access to private stroke positions.
- **Perception and fairness:** eye-position raycasts with correct collision exclusions; physically visible chalk, not a privileged global mark lookup for decision-making.
- **Map readability:** defined two-team zones, recognizable landmarks, sight lines, roof access, looping ground routes and cover, rather than a random scatter of props.
- **Round presentation:** visible coin ceremony, phase boundaries, result lock and return.
- **Instrumentation:** explicit CPU strike and result-state regression checks, 4/4 physical roof traversals, existing 2D regression and Android performance plan.

**Source/legal note:** This is an adaptation of general FPS engineering principles. No Counter-Strike proprietary code, character models, audio, textures or map assets are used.

## Remaining production work (do not claim release ready)

1. **Art direction / assets:** build one cohesive believable Indian village vertical slice with real-scale architecture, modular weathered plaster, brick, terracotta, vegetation, loose objects, ambient props, PBR materials and lighting. Replace procedural humanoid placeholders with appropriately licensed rigged characters, locomotion/turn/crouch/draw/inspect/strike animations and animation blending. All geometry needs correctly aligned collisions and draw-ready surfaces.
2. **Audio and feedback:** footsteps by surface, chalk drag, chalk strike, physical cover lift/drop, UI clicks, coin toss, local ambient sound and spatial audio. Provide volume controls and cue timing.
3. **Full 3D UI/UX:** actual draw/meeting/search/result HUD, gamepad and Android input prompts, contextual cover interaction, aiming reticle, distinct discovery feedback, no debug HUD.
4. **Drawing parity:** uninterrupted curved strokes across irregular triangulated mesh surfaces, underside drawing, surface transition UX, input capture conflict resolution and stroke mesh batching for 100–300 retained marks.
5. **Bot behavior:** explicit DRAW / PATROL / INSPECT / FOLLOW / RECOVER state machine, navigation mesh and off-mesh links for roofs, ground coverage metrics, roof search and descent tests, obstacle-aware defender follow.
6. **Balance:** repeated 100+ seeded matches per difficulty and real human sessions; monitor search coverage, false detections, stuck count, survivor score and win-rate confidence intervals. There is no universal industry-standard target win rate for this ruleset.
7. **Android acceptance:** real-device visual checks, two-thumb movement/draw tests, profiler, memory/thermal tests, GPU budgets and performance fallback quality settings.

## Test evidence policy

The new `ChalkGaon3DPlaytestRegression.gd` is wired into `.github/workflows/village-graybox.yml`. It asserts draw range/sampling, humanoid actors, coin overlay, physical CPU strike and terminal match behavior. Earlier rooftop and owner-rule tests remain. **Only a green workflow for the latest commit proves this exact revision passes headless CI; even that does not certify visual quality.**

Run the 3D test scene directly in Godot 4.4: `scenes/3d/game_world_3d.tscn` (F6). Inspect Godot's Debugger for runtime errors. Send before/after screenshots and a short recording for visual/camera and gray-screen assessment.
