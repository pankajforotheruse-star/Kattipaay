# Chalk Gaon: 2D → 3D migration strategy (Godot 4.4)

**Decision:** Leave the working 2D Play vs CPU in place. This branch contains an **isolated geometry-and-traversal prototype**, not the finished 3D game. Do not merge until the owner inspects the map and explicitly approves integration.

## Actual baseline (inspected)

| Existing file/system | Current 2D contract | Required 3D change (AFTER map approval) |
|---|---|---|
| `scenes/game/game_world.tscn` | `Node2D` world, Sprite2D props, Camera2D | Parallel `Node3D` game scene; keep original as fallback |
| `scripts/game/GameWorld.gd` | `Node2D` root, entity registry, spawns `SoloMatchDriver` | Separate `GameWorld3D` adapter; preserve entity IDs and EventBus |
| `scripts/entities/Player.gd`, `MovementSystem.gd` | 2D entity coordinates and click/tap movement | CharacterBody3D / input adapter with third-person camera, controller, jump and crouch |
| `scripts/game/ZoneLayout.gd` | `Vector2`, `Rect2`, 2400x1800 with alley 780..1020 | 3D convex/volume territories, `Vector3` positions, mapping for phase-based traversal |
| `scripts/systems/DrawSystem.gd` | `Line2D` and `Array[Vector2]` strokes | Raycast to `CollisionObject3D`, store 3D stroke points, mesh/decal rendering; retain ownership/undo/decay/scoring semantics |
| `scripts/systems/ChalkLine.gd` | serialized 2D geometry | Versioned stroke representation; owner, surface path/RID and local stroke coordinates; keep 2D format readable |
| `GhostDrawSystem.gd`, `GhostBotController.gd` | CPU line placement in 2D player/CPU halves | Navigate to reachable surface and generate 3D geometry; do not supply hidden opponent points |
| `CpuSearchController.gd`, `HidingRules.gd` | 2D proximity/reveal and wall concealing rectangles | Raycast/field-of-view, occlusion, deliberate inspection, navigation exploration |
| `FogSystem.gd`, `Camera.gd` | 2D fog and Camera2D | 3D occlusion/fog plus Camera3D collision prevention |
| `SoloMatchDriver.gd`, `GameState.gd` | round state/event rules in existing MVP | Leave rules intact; translate world and stroke data via adapters |
| `scripts/tests/KattipaayPlayableSmokeTest.gd` | 2D end-to-end smoke tests | Preserve regression suite and ADD 3D scene/physics tests |

## 3D scene contract

- X axis separates territories: PLAYER is x < 0, CPU is x > 0. Z is map depth; Y is elevation. 1 Godot unit ≈ 1 metre.
- Central doorway remains geometrically open in this graybox. Apply phase-based access by state-aware physical barriers later.
- Static bodies have group `graybox_surfaces`; movable candidates also have group `future_movable_props`.
- Candidate raycast: `Camera3D.project_ray_origin(screen_pos)` + `Camera3D.project_ray_normal(screen_pos) * max_range`; call `PhysicsDirectSpaceState3D.intersect_ray`; require surface in allowed group/territory.
- Stroke points should be stored **in local coordinates of the hit surface**, not only in global coordinates, so object movement can carry chalk correctly. Persist an explicit stable object ID, local point list, normals and a stroke format version.
- During draw, reject points outside owner territory, require plausible hand-to-surface range, and reject lines crossing different surfaces unless explicitly supported.
- For rendering, consider one mesh ribbon per stroke, offset slightly along surface normal, using depth testing; prevent z-fighting and see-through walls.
- CPU movement: build NavigationRegion3D ground and roof meshes and NavigationLink3D transitions for ladders/jumps (with actual controlled movement). A baked mesh alone does not mean an agent can climb.
- CPU concealment perception must test camera/eye line-of-sight and occlusion against actual objects and use exploration states; avoid omniscient access to hidden strokes.
- 3D HUD remains Control/CanvasLayer. Preserve coin/meeting, search phases, scoring, defender sneaks, arguments, and timed round defaults.

## Incremental integration plan (do not implement during graybox milestone)

1. Owner manually approves graybox geometry, scale, access routes and hidden-surface potential.
2. Add `GameWorld3D` + 3D player scene behind a development-only switch; keep 2D start scene default.
3. Implement one 3D raycast stroke on a wall; test overhead/floor/roof and moving-source surface anchors next.
4. Adapt `ChalkLine` schema with version compatibility and run geometry property tests.
5. Connect territory volumes and draw-time access logic while reusing existing match state events.
6. Implement CPU navmesh, surface ranking and occlusion-aware search without changing score/timing mechanics.
7. Run both old 2D and new 3D CI; manual playtest map and moveable object coverage; only then discuss cutover.

## Godot 4.4 validation commands

Use **Godot 4.4 stable**, available as `godot` or `godot4` on PATH.

```bash
godot --headless --path . --editor --quit
godot --headless --path . --script res://scripts/tests/VillageGrayboxSmokeTest.gd
godot --path . --scene res://scenes/graybox/village_graybox.tscn
```

The first command checks parsing/import, second checks structure, third is a manual visual run. Also run the existing project's CI and Play vs CPU smoke suite per README. **Passing structural checks does NOT prove rooftop ramp reachability, freehand drawing, physics correctness or CPU search.**

## Known tradeoffs / constraints

- New scene and GDScript use Godot **4.x class names/APIs**, but remain **unverified on a running Godot 4.4 binary** as of the branch update.
- The graybox uses static candidate crates and no 3D CPU navigation, drawing or physics interactions.
- Crouch is an independent prototype implementation rather than a port of the production player controller.
- Ramp/roof transitions and the camera clipping through geometry need manual sanity inspection.
- The current 2D view is mobile portrait; adjust 3D viewport, controls and Android performance during later migration, not by changing global configuration now.
- No proprietary Counter-Strike code/assets were used. REA is a reverse-engineering **toolkit**, not Counter-Strike source.
