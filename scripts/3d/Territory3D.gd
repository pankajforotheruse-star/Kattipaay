class_name Territory3D
extends RefCounted
## Shared geometric authority for future gameplay state adapters.
enum Zone { OUTSIDE, PLAYER, CPU, PASSAGE }
const WEST_LIMIT := -54.0
const EAST_LIMIT := 54.0
const NORTH_LIMIT := -25.0
const SOUTH_LIMIT := 25.0
const GATE_HALF_WIDTH := 3.0

static func zone_of(p: Vector3) -> Zone:
	if p.x < WEST_LIMIT or p.x > EAST_LIMIT or p.z < NORTH_LIMIT or p.z > SOUTH_LIMIT:
		return Zone.OUTSIDE
	if absf(p.x) <= 0.4:
		return Zone.PASSAGE
	return Zone.PLAYER if p.x < 0.0 else Zone.CPU

static func can_draw(owner_id: int, position: Vector3) -> bool:
	return (owner_id == 1 and zone_of(position) == Zone.PLAYER) or (owner_id == 2 and zone_of(position) == Zone.CPU)

static func can_enter(owner_id: int, position: Vector3, match_phase: String, searcher_id: int = -1) -> bool:
	var zone := zone_of(position)
	if zone == Zone.OUTSIDE:
		return false
	if match_phase == "DRAWING":
		return zone == Zone.PLAYER if owner_id == 1 else zone == Zone.CPU
	if match_phase == "MEETING":
		return zone == Zone.PASSAGE or absf(position.x) < 4.0
	if match_phase == "SEARCHING":
		if searcher_id == owner_id:
			return zone == (Zone.CPU if owner_id == 1 else Zone.PLAYER) or zone == Zone.PASSAGE
		return zone == (Zone.PLAYER if owner_id == 1 else Zone.CPU)
	return true
