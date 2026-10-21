# SceneryLayer.gd — static scenery renderer (Commit A, hiding mechanism)
#
# Draws ground surfaces + compound walls; CoverSystem draws tree shade, leaves and bricks so BOTH
# zones read as village ground with places to hide chalk lines, visible to
# both sides from the start (owner Q2). Placeholder art: flat color rects,
# solid/static, no animation. This node never invents layout — HidingRules is
# the single source of geometry truth.
#
# Rendered BELOW entities (GameWorld adds it as the first child).

class_name SceneryLayer
extends Node2D

## Ground tint per strip (player zone / alley / CPU zone) — semi-transparent so
## any world background texture still shows through.
const GROUND_TINT := Color(0.30, 0.26, 0.20, 0.22)
const ALLEY_TINT := Color(0.42, 0.36, 0.26, 0.26)
const WALL_COLOR := Color(0.62, 0.50, 0.34, 1.0)
const WALL_EDGE_COLOR := Color(0.38, 0.30, 0.20, 1.0)

func _draw() -> void:
	# Ground surfaces (identical data for both sides).
	for g in HidingRules.get_ground_surfaces():
		var rect: Rect2 = g
		var tint: Color = ALLEY_TINT if rect == ZoneLayout.ALLEY else GROUND_TINT
		draw_rect(rect, tint, true)
	# Compound walls (both zones, mirrored layout).
	for w in HidingRules.get_all_walls():
		var wall: Rect2 = w
		draw_rect(wall, WALL_COLOR, true)
		draw_rect(wall, WALL_EDGE_COLOR, false, 3.0)