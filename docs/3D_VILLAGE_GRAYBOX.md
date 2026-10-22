# Independent 3D village graybox (experimental)

This is a **separate Godot 4.4 Node3D prototype**, not a conversion of the existing 2D game. It is deliberately NOT wired to `scenes/main.tscn` or `scenes/game/game_world.tscn`. Existing Play vs CPU, drawing, scoring, search, and UI remain unchanged.

## Run

Open `project.godot` in Godot 4.4. Open `scenes/graybox/village_graybox.tscn` and press **F6** (Run Current Scene). You can also use the CLI: `godot --path . --scene res://scenes/graybox/village_graybox.tscn`.

WASD/arrows: move. Mouse: orbit/look. Space: jump. Shift: sprint. Tab: debug switch to the other territory. Escape: free mouse. Click to recapture.

## Scope delivered

- Two approximately 46m-wide territories with different graybox placements and marked spawn areas.
- A central opening in the separating walls, perimeter collision, floor geometry, lighting.
- Two hollow houses per zone with accessible interiors, flat roofs, parapets and incline ramps.
- Broken-wall alcoves, low shelter, static crates, fallen log, stones and tree obstacles.
- A third-person CharacterBody3D explorer with physics and camera.

## Explicit limitations (do not infer these are complete)

- **No REA-assisted Counter-Strike binary reverse engineering was performed.** The linked `morluto/rea` repository is a reverse-engineering toolkit, not Counter-Strike game source.
- No Counter-Strike asset/code copying; environment is a clean-room game-design prototype.
- DrawSystem currently uses **2D Line2D/Vector2**; the new scene does not implement 3D drawing, searching, CPU navigation, or match state transitions.
- Graybox boxes are static (crate movement not implemented).
- The central crossing is always open; phase-based territory locks are not implemented.
- Roof ramps and camera occlusion require **local visual/manual testing**; a sloped ramp may require tuning and a jump to reach its roof.
- The prototype isn't meant to pass production requirements yet; it is for assessing movement and hiding opportunities.

## Mandatory local sanity checks

1. Run existing main scene and execute existing Play vs CPU smoke tests to ensure regression-free 2D behavior.
2. Run the separate graybox scene. Verify both spawn regions by pressing Tab.
3. Walk around both territories, enter each house through the front doorway, and reach each rooftop from the side ramp (jump if required).
4. Inspect surfaces behind the crates and log; enter the recessed wall alcove; check low shelter.
5. Check visibility and collision for walls, roofs, perimeter walls, and the central passage.
6. Attempt to leave the map and note any escape/stuck areas.
7. Review free-drawing *potential* for accessible walls, roofs, ground, undersides and occluded surfaces (drawing itself is NOT available).
8. Mark each visual/manual result PASS/FAIL/NOT TESTED, never fabricate successful tests.

## Next stage (not implemented)

After owner approval: determine 3D coordinate migration strategy from `ZoneLayout.gd` and `ChalkLine.gd`, add camera-raycast-based 3D strokes with occlusion and surface attachment, then migrate CPU navigation/perception. These are substantial migrations, not trivial scene swaps.

## REA source

https://github.com/morluto/rea describes Reverse Engineer Anything (REA), an MCP/CLI reverse-engineering toolkit. It requires a specific lawfully accessible target binary or program plus a configured local analysis runtime to examine a game's actual implementation. Do not represent REA's own repository as containing Counter-Strike source or claim its architecture was reverse engineered.
