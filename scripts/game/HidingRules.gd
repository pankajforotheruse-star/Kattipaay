# HidingRules.gd — SINGLE source of truth for the hiding mechanic (Commit A)
#
# Owner "Deviation Fix #3" (2026-10-11) — Commit A scope: wall + ground base
# drawing/occlusion. Every rule that BOTH sides (human searcher and CPU
# searcher) must share lives here and ONLY here:
#
#   - Reveal radii: an opponent's chalk line becomes visible (revealed) when
#     the searcher's character is within the proximity radius of the line's
#     NEAREST point. Open-ground lines reveal at REVEAL_RADIUS_OPEN; lines
#     classified wall-concealed (a draw stroke intersecting a wall object)
#     reveal at REVEAL_RADIUS_OCCLUDED — STRICTLY smaller, so lines hidden
#     on/behind walls are genuinely harder to find (childhood-game intent).
#   - Identical for both sides (owner Q2) and constant across all four
#     difficulties (owner Q3 — difficulty changes CPU behavior ONLY, never the
#     physics/proximity rules).
#   - Scenery geometry: compound walls + ground surfaces, identical layout in
#     both zones, visible to both sides from the start. The SceneryLayer node
#     only renders what is defined here (this file is the layout truth).
#
# Chosen values (tune-for-feel points, owner deviation #5 — AI-proposed):
#   R = 160px open-ground, R_occluded = 90px wall-concealed. The 70px gap is
#   the "hidden behind a wall" tax: a searcher must walk right up to the
#   concealed line instead of sweeping past it.

class_name HidingRules
extends RefCounted

# ── Reveal radii (ONE constants place — both sides, all difficulties) ────────

## Proximity radius (px) at which an OPEN-GROUND line reveals to the searcher.
const REVEAL_RADIUS_OPEN := 160.0

## Proximity radius (px) at which a WALL-CONCEALED line reveals to the
## searcher. STRICTLY smaller than REVEAL_RADIUS_OPEN (the hiding tax).
const REVEAL_RADIUS_OCCLUDED := 90.0

## Difficulty-independent, side-independent reveal radii for a line by its
## concealment flag. Asserted identical across both systems by the smoke test.
static func reveal_radius_for(wall_concealed: bool) -> float:
	return REVEAL_RADIUS_OCCLUDED if wall_concealed else REVEAL_RADIUS_OPEN

# ── Scenery geometry ──────────────────────────────────────────────────────────

## Player-zone compound walls (simple rectangles — placeholder art; the
## SceneryLayer renders them). Kept away from the meeting point (1200,900) and
## the search-entry walkways so play is never blocked.
static func get_zone_walls() -> Array:
	return [
		Rect2(640.0, 480.0, 500.0, 24.0),   # low compound wall, mid zone
		Rect2(1560.0, 560.0, 24.0, 220.0),  # wall along the zone's right side
		Rect2(900.0, 650.0, 260.0, 22.0),   # low wall, lower-middle zone
	]

## CPU-zone walls — the SAME layout as the player zone, offset by the CPU
## zone's top edge so both halves are identical (owner Q2).
static func get_cpu_walls() -> Array:
	var out: Array = []
	for w in get_zone_walls():
		out.append(Rect2(w.position + Vector2(0.0, ZoneLayout.CPU_ZONE.position.y), w.size))
	return out

## Every wall in the world (both zones).
static func get_all_walls() -> Array:
	var out: Array = []
	out.append_array(get_zone_walls())
	out.append_array(get_cpu_walls())
	return out

## Ground surfaces: the three playable strips (player zone / alley / CPU zone).
## The world's floor — identical for both sides, drawn with a zone tint by the
## SceneryLayer so the halves read as separate village grounds.
static func get_ground_surfaces() -> Array:
	return [
		ZoneLayout.PLAYER_ZONE,
		ZoneLayout.ALLEY,
		ZoneLayout.CPU_ZONE,
	]

# ── Wall-conceal classification + reveal predicate ───────────────────────────

## True when any stroke segment of the line intersects a wall object (or has
## an endpoint inside one) — the Commit A line classification. Pure geometry,
## no state; used by DrawSystem (human strokes), GhostDrawSystem (ghost lines)
## and GhostBotController (CPU lines) alike.
static func is_wall_concealed(points: Array) -> bool:
	if points.size() < 2:
		return false
	var walls := get_all_walls()
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		for w in walls:
			var wall: Rect2 = w
			if _segment_intersects_rect(a, b, wall):
				return true
	return false

## Nearest point on the line's polyline to `pos` (world px). The reveal rule
## measures distance from the SEARCHER to this point — same measure for both
## sides.
static func nearest_point_on_line(points: Array, pos: Vector2) -> Vector2:
	if points.is_empty():
		return pos
	if points.size() == 1:
		return points[0]
	var best: Vector2 = points[0]
	var best_d := INF
	for i in range(points.size() - 1):
		var p := _closest_point_on_segment(pos, points[i], points[i + 1])
		var d: float = p.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = p
	return best

## The core Commit A rule: a line is revealed when the searcher is within the
## line's reveal radius (R open / R_occluded wall-concealed) of its nearest
## point. BOTH searchers use this exact predicate (GhostDrawSystem for the
## human, CpuSearchController for the CPU).
static func is_revealed(points: Array, searcher_pos: Vector2, wall_concealed: bool) -> bool:
	if points.size() < 2:
		return false
	var np: Vector2 = nearest_point_on_line(points, searcher_pos)
	return searcher_pos.distance_to(np) <= reveal_radius_for(wall_concealed)

## Random point INSIDE a wall object of the given zone (`cpu_zone` true = the
## ghost's half). Used by GhostBotController to anchor a wall-concealed line —
## a line that starts inside a wall is classified concealed by the shared rule.
static func random_wall_anchor_for_zone(cpu_zone: bool, rng: RandomNumberGenerator) -> Vector2:
	var walls := get_cpu_walls() if cpu_zone else get_zone_walls()
	if walls.is_empty():
		return ZoneLayout.MEETING_POINT if not cpu_zone else Vector2(1200.0, 1500.0)
	var wall: Rect2 = walls[rng.randi_range(0, walls.size() - 1)]
	return Vector2(
		rng.randf_range(wall.position.x, wall.position.x + wall.size.x),
		rng.randf_range(wall.position.y, wall.position.y + wall.size.y)
	)

# ── Geometry helpers ──────────────────────────────────────────────────────────

## Segment-vs-rect intersection: true if either endpoint is inside the rect or
## the segment crosses any of the rect's four edges.
static func _segment_intersects_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b):
		return true
	var edges := [
		[Vector2(rect.position.x, rect.position.y), Vector2(rect.position.x + rect.size.x, rect.position.y)],
		[Vector2(rect.position.x + rect.size.x, rect.position.y), Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y)],
		[Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y), Vector2(rect.position.x, rect.position.y + rect.size.y)],
		[Vector2(rect.position.x, rect.position.y + rect.size.y), Vector2(rect.position.x, rect.position.y)],
	]
	for edge in edges:
		if _segments_intersect(a, b, edge[0], edge[1]):
			return true
	return false

## 2D segment-segment intersection (proper crossing or T-touch).
static func _segments_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1: float = _cross(p4 - p3, p1 - p3)
	var d2: float = _cross(p4 - p3, p2 - p3)
	var d3: float = _cross(p2 - p1, p3 - p1)
	var d4: float = _cross(p2 - p1, p4 - p1)
	if ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) \
			and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)):
		return true
	# Inclusive endpoints: touching counts as intersecting (a line starting on
	# a wall face is concealed).
	if _cross(p4 - p3, p1 - p3) == 0.0 and _on_segment(p3, p4, p1):
		return true
	if _cross(p4 - p3, p2 - p3) == 0.0 and _on_segment(p3, p4, p2):
		return true
	if _cross(p2 - p1, p3 - p1) == 0.0 and _on_segment(p1, p2, p3):
		return true
	if _cross(p2 - p1, p4 - p1) == 0.0 and _on_segment(p1, p2, p4):
		return true
	return false

static func _cross(a: Vector2, b: Vector2) -> float:
	return a.x * b.y - a.y * b.x

static func _on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return p.x >= minf(a.x, b.x) - 0.001 and p.x <= maxf(a.x, b.x) + 0.001 \
		and p.y >= minf(a.y, b.y) - 0.001 and p.y <= maxf(a.y, b.y) + 0.001

## Closest point on segment AB to pos.
static func _closest_point_on_segment(pos: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t: float = clampf((pos - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t