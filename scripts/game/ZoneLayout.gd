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
# MVP slice 1 delivered the geometry + clamp helpers; slice 2 added the
# MEETING phase (match state, coin decider) and the search-entry points.

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

## Where the human searcher walks to at the start of search #1: the alley's
## bottom exit, just inside the CPU zone (the winner walks from the meeting
## into the opponent's half).
const SEARCH_ENTRY_HUMAN := Vector2(1200.0, 1040.0)

## Where the CPU searcher will walk to in the later zone+role swap slice:
## the alley's top exit, just inside the player zone. Kept here now so both
## slice halves share one geometry source.
const SEARCH_ENTRY_CPU := Vector2(1200.0, 760.0)

## Where the human DEFENDER stands while the CPU searches the player zone
## (center of the player zone, visible to the camera with the CPU's targets).
const DEFEND_POS_HUMAN := Vector2(1200.0, 390.0)

## Where the CPU (NPC) DEFENDER patrols/stands while the human searches the
## CPU zone (center of the CPU zone).
const DEFEND_POS_CPU := Vector2(1200.0, 1410.0)

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