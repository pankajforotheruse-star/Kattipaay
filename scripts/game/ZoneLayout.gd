# ZoneLayout.gd — Two-zone game world geometry for the Play VS CPU round
#
# CS-style split: the top-down map is divided into TWO distinct zones with a
# central alley (the meeting point) between them:
#
#   PLAYER ZONE  (y 0 .. 780)    — the human draws + moves here during DRAWING
#   ALLEY        (y 780 .. 1020) — central meeting strip between the zones
#   CPU ZONE     (y 1020 .. 1800)— the ghost's half (CPU ghost lines live here)
#
# Single source of truth for zone rects so DrawSystem, the player entity and
# the GhostBotController all enforce the same bounds. World size matches the
# FogSystem default world bounds (2400 x 1800).
#
# MVP slice 1: only the geometry + clamp helpers. The meeting phase itself
# (MEETING match state, coin decider) is a later slice.

class_name ZoneLayout
extends RefCounted

## Full world size — matches FogSystem's default world bounds.
const WORLD_SIZE := Vector2(2400.0, 1800.0)

## Top edge Y of the central alley (also the player zone's bottom edge).
const ALLEY_Y := 780.0

## Alley height (the meeting strip between the two halves).
const ALLEY_HEIGHT := 240.0

## Player zone: the human's half (top of the map).
const PLAYER_ZONE := Rect2(0.0, 0.0, 2400.0, 780.0)

## Central alley / meeting strip between the zones.
const ALLEY := Rect2(0.0, ALLEY_Y, 2400.0, ALLEY_HEIGHT)

## CPU zone: the ghost's half (bottom of the map).
const CPU_ZONE := Rect2(0.0, 1020.0, 2400.0, 780.0)

## Center of the alley — where the MEETING phase will gather both sides.
const MEETING_POINT := Vector2(1200.0, 900.0)

## Clamp a point into the player zone (used during DRAWING for the human's
## movement targets and chalk stroke samples — drawing outside your own half
## is blocked by clamping to this rect).
static func clamp_to_player_zone(p: Vector2) -> Vector2:
	return clamp_to_zone(p, PLAYER_ZONE)

## Clamp a point into the CPU zone (used by the GhostBotController so every
## ghost line the CPU places stays inside its own half).
static func clamp_to_cpu_zone(p: Vector2) -> Vector2:
	return clamp_to_zone(p, CPU_ZONE)

## Clamp a point into an arbitrary zone rect.
static func clamp_to_zone(p: Vector2, zone: Rect2) -> Vector2:
	return Vector2(
		clampf(p.x, zone.position.x, zone.end.x),
		clampf(p.y, zone.position.y, zone.end.y)
	)

## True when the point lies inside the player zone.
static func point_in_player_zone(p: Vector2) -> bool:
	return PLAYER_ZONE.has_point(p)

## True when the point lies inside the CPU zone.
static func point_in_cpu_zone(p: Vector2) -> bool:
	return CPU_ZONE.has_point(p)