# CpuSearchController.gd — information-limited CPU exploration for Play VS CPU.
# The CPU plans its path from PUBLIC territory geometry, not from the hidden
# human lines. It may only strike a non-sneak line after the actual CPU entity
# enters the SAME reveal radius used by the human. Unvisited sneaks cannot be
# noticed through an end-of-route roll. No hidden line coordinates drive travel.

class_name CpuSearchController
extends Node

const GHOST_ENTITY_ID := 2
const DEFAULT_SWEEP_SPEED := 420.0
## Strike radius around each line's center (world pixels).
const STRIKE_PAUSE_SECONDS := 0.8
const WAYPOINT_REACHED_RADIUS := 28.0
const SWEEP_EDGE_MARGIN := 115.0
const SWEEP_LANE_SPACING := 170.0
## Sneak-notice proximity: the CPU notices a sneak line only while sweeping
## within this radius of the line's center (once per line per phase).
const NOTICE_RADIUS := 170.0
## Pause after a NOTICED penalty so the defender sees the strikes.
const NOTICE_PAUSE_SECONDS := 0.6
## Auto-strike radius around a noticed sneak line for the extra penalty lines.
const PENALTY_RADIUS := 240.0
## How many existing defender lines the penalty strikes besides the sneak.
const PENALTY_EXTRA_STRIKES := 2
## Per-difficulty notice chance when chalk_gaon/cpu_sneak_notice_chance == -1.0.
const DIFFICULTY_NOTICE := {
	0: 0.15,
	1: 0.35,
	2: 0.60,
	3: 0.85,
}
## These tune only search decisions, never cover physics, detection radius
## or knowledge of a line's unvisited coordinates.
const SEARCH_PROFILES := {
	0: {"speed": 310.0, "lane": 260.0, "cover_stops": 2, "inspect": 0.25, "strike_pause": 1.3},
	1: {"speed": 420.0, "lane": 210.0, "cover_stops": 3, "inspect": 0.55, "strike_pause": 0.8},
	2: {"speed": 470.0, "lane": 175.0, "cover_stops": 4, "inspect": 0.80, "strike_pause": 0.55},
	3: {"speed": 510.0, "lane": 145.0, "cover_stops": 6, "inspect": 0.95, "strike_pause": 0.35},
}

var _active: bool = false
var _npc: CharacterBody2D = null
var _draw_sys: DrawSystem = null
var _cover_sys: CoverSystem = null
var _search_profile: Dictionary = SEARCH_PROFILES[1]
var _sweep_lane_spacing: float = 210.0
var _search_waypoints: Array[Vector2] = []
var _local_investigation: Array[Vector2] = []
var _search_rng := RandomNumberGenerator.new()
var _round_scan_flip: bool = false
var _waypoint_index: int = 0
var _pause_timer: float = 0.0
var _sweep_speed: float = DEFAULT_SWEEP_SPEED
## Sneak line ids still waiting for a notice roll this CPU phase.
var _unresolved_sneaks: Dictionary = {}
## Per-difficulty notice chance cached at phase start (live override wins).
var _sneak_notice_chance: float = -1.0

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	var world := get_tree().current_scene as Node2D
	if world:
		_cover_sys = world.get_node_or_null("CoverSystem") as CoverSystem
		var systems: Node = world.get_node_or_null("Systems")
		if systems:
			_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
		if _draw_sys and world.has_method("get_entity"):
			_npc = world.get_entity(GHOST_ENTITY_ID) as CharacterBody2D
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.on(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)
	EventBus.on(EventBus.EV_GAME_SNEAK_LINE_DRAWN, _on_sneak_line_drawn)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.off(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)
	EventBus.off(EventBus.EV_GAME_SNEAK_LINE_DRAWN, _on_sneak_line_drawn)


## Sweep speed + notice chance are read at every CPU phase start so tests and
## a future settings screen can override them at runtime.
func _read_settings() -> void:
	_search_profile = SEARCH_PROFILES.get(GameState.cpu_difficulty, SEARCH_PROFILES[1])
	var override := float(ProjectSettings.get_setting("chalk_gaon/cpu_sweep_speed", -1.0))
	_sweep_speed = override if override > 0.0 else float(_search_profile["speed"])
	_sweep_lane_spacing = float(_search_profile["lane"])
	_sneak_notice_chance = _resolve_notice_chance()
	if _npc:
		_npc.set_meta("move_speed", _sweep_speed)


## -1.0 (default) resolves to the per-difficulty table; >= 0 uses the setting.
func _resolve_notice_chance() -> float:
	var setting := float(ProjectSettings.get_setting("chalk_gaon/cpu_sneak_notice_chance", -1.0))
	if setting >= 0.0:
		return setting
	return float(DIFFICULTY_NOTICE.get(GameState.cpu_difficulty, 0.35))


# ── Event handlers ───────────────────────────────────────────────────────────

func _on_search_phase_started(payload: Dictionary) -> void:
	_active = int(payload.get("searcher", -1)) == GHOST_ENTITY_ID
	_search_waypoints.clear()
	_waypoint_index = 0
	_pause_timer = 0.0
	_unresolved_sneaks.clear()
	_local_investigation.clear()
	_search_rng.randomize()
	_round_scan_flip = _search_rng.randf() > 0.5
	if not _active:
		return
	_read_settings()
	var start_pos := _npc.global_position if _npc else ZoneLayout.SEARCH_ENTRY_CPU
	# Search plans never depend on the hidden line registry.
	_search_waypoints = _build_search_waypoints(ZoneLayout.PLAYER_ZONE, start_pos)
	for line in _draw_sys.get_active_lines() if _draw_sys else []:
		if line.is_sneak and not line.is_struck:
			_unresolved_sneaks[line.id] = true


func _on_search_phase_ended(_payload: Dictionary) -> void:
	if _active and _npc:
		_npc.set_meta("has_target", false)
	_active = false
	_search_waypoints.clear()
	_waypoint_index = 0
	_unresolved_sneaks.clear()


## The defender argues (distract): the CPU's sweep freezes for stall_seconds.
## Only while the CPU is the active searcher and the argue targets the CPU.
func _on_defender_argue_started(payload: Dictionary) -> void:
	if not _active:
		return
	if int(payload.get("target_searcher_id", -1)) != GHOST_ENTITY_ID:
		return
	var stall: float = float(payload.get("stall_seconds", 3.0))
	_pause_timer = maxf(_pause_timer, stall)
	# Stop the old waypoint movement too while the defender distracts us.
	if _npc:
		_npc.set_meta("has_target", false)
	print("CpuSearchController: distracted by argue — sweep stalls %.1fs" % stall)

## A sneak line the defender draws mid-phase joins the unresolved set so the
## proximity roll can notice it. Without this the
## CPU can never catch a sneak drawn after the phase started.
func _on_sneak_line_drawn(payload: Dictionary) -> void:
	if not _active:
		return
	var line_id := int(payload.get("line_id", -1))
	if line_id >= 0:
		_unresolved_sneaks[line_id] = true


# ── Sweep ────────────────────────────────────────────────────────────────────

## Commit A probe: the reveal radius from the SINGLE shared HidingRules
## source - identical to the human searcher's (the smoke test asserts it
## against GhostDrawSystem).
func get_reveal_radius_for(wall_concealed: bool) -> float:
	return HidingRules.reveal_radius_for(wall_concealed)

func probe_reveal(points: Array, searcher_pos: Vector2, wall_concealed: bool) -> bool:
	return HidingRules.is_revealed(points, searcher_pos, wall_concealed)

func probe_point_at_distance(points: Array, origin: Vector2, distance: float) -> Vector2:
	var np: Vector2 = HidingRules.nearest_point_on_line(points, origin)
	var dir: Vector2 = (origin - np).normalized() if origin != np else Vector2.UP
	return np + dir * distance


func _process(delta: float) -> void:
	# Pausing must freeze line discovery, NPC search, and the argument stall
	# countdown. The UI top-level PAUSED flag may update before match state.
	if GameState.solo_vs_cpu and (GameState.current == GameState.State.PAUSED \
			or GameState.get_match_state() == GameState.MatchState.PAUSED):
		return
	if not _active or _npc == null or _draw_sys == null:
		return
	if _pause_timer > 0.0:
		_pause_timer = maxf(_pause_timer - delta, 0.0)
		return

	# Cover inspection comes FIRST and only happens after the NPC has
	# physically arrived within the same radius as a human searcher.
	if _cover_sys and _cover_sys.cpu_inspect_nearby(
			_npc.global_position, float(_search_profile["inspect"])):
		_pause_timer = 0.35
		_npc.set_meta("has_target", false)
		return
	# The line registry is consulted ONLY by the proximity sensor, not the
	# navigation planner. A faraway/covered line cannot inform our target.
	_check_sneak_notices()
	var revealed_ids := probe_revealed_line_ids(_draw_sys.get_active_lines(), _npc.global_position)
	if not revealed_ids.is_empty():
		var discovered := _find_line(revealed_ids[0])
		var found_pos := HidingRules.nearest_point_on_line(
			discovered.points, _npc.global_position) if discovered else _npc.global_position
		if _draw_sys.strike_line(revealed_ids[0]):
			# A CHILDHOOD STRIKER DOES NOT silently click a mark and leave:
			# announce the find, pause, then examine nearby public hiding
			# places. The only line coordinate used is one already found.
			_queue_local_investigation(found_pos)
			_pause_timer = float(_search_profile["strike_pause"]) + 0.35
			_npc.set_meta("has_target", false)
		return
	_follow_search_route()


## Same shared proximity predicate as the human; excludes special sneaks.
## Exposed as a pure probe so the smoke test can assert non-omniscience.
func probe_revealed_line_ids(lines: Array, searcher_pos: Vector2) -> Array[int]:
	var ids: Array[int] = []
	for candidate in lines:
		if not candidate is ChalkLine:
			continue
		var line: ChalkLine = candidate
		if line.is_sneak or line.is_struck or line.points.size() < 2:
			continue
		var detected := _cover_sys.can_reveal(line.points, searcher_pos, line.wall_concealed, line.hidden_cover_id) if _cover_sys else \
				HidingRules.can_reveal_line(line.points, searcher_pos, line.wall_concealed)
		if detected:
			ids.append(line.id)
	return ids


## Uses only publicly known zone geometry plus the character's entry point.
func _build_search_waypoints(zone: Rect2, from_pos: Vector2) -> Array[Vector2]:
	var waypoints: Array[Vector2] = []
	var left := zone.position.x + SWEEP_EDGE_MARGIN
	var right := zone.end.x - SWEEP_EDGE_MARGIN
	var top := zone.position.y + SWEEP_EDGE_MARGIN
	var bottom := zone.end.y - SWEEP_EDGE_MARGIN
	if right <= left or bottom <= top:
		waypoints.append(zone.get_center())
		return waypoints
	var lanes: Array[float] = []
	var lane_y := top
	while lane_y < bottom:
		lanes.append(lane_y)
		lane_y += _sweep_lane_spacing
	if lanes.is_empty() or lanes[-1] < bottom:
		lanes.append(bottom)
	# Prioritize a few PUBLIC cover sites, not marks. More capable opponents
	# systematically investigate more hiding places. All routes are derived
	# only from map geometry, entry point and difficulty.
	var sites: Array[Vector2] = []
	for site in HidingRules.get_cover_sites(false):
		var center: Vector2 = site["rect"].get_center()
		if zone.has_point(center):
			sites.append(center)
	var cursor := from_pos
	var stops := mini(int(_search_profile["cover_stops"]), sites.size())
	for _i in range(stops):
		var closest := 0
		var closest_d := INF
		for j in range(sites.size()):
			var dist := cursor.distance_squared_to(sites[j])
			if dist < closest_d:
				closest_d = dist
				closest = j
		cursor = sites[closest]
		waypoints.append(cursor)
		sites.remove_at(closest)
	# Start from a varied corner each round; repeated matches do not replay
	# exactly the same rows even on the same difficulty.
	var bottom_first := (_search_rng.randf() < 0.5) if _active else cursor.y >= zone.get_center().y
	var right_first := (_search_rng.randf() < 0.5) if _active else cursor.x >= zone.get_center().x
	for row in range(lanes.size()):
		var lane_index := lanes.size() - row - 1 if bottom_first else row
		var y := lanes[lane_index]
		var row_right_first := right_first if row % 2 == 0 else not right_first
		waypoints.append(Vector2(right if row_right_first else left, y))
		waypoints.append(Vector2(left if row_right_first else right, y))
	return waypoints


func _follow_search_route() -> void:
	# Local investigation is justified by an ALREADY FOUND line, never
	# remote knowledge of another mark. The CPU checks adjacent publicly
	# visible cover before resuming its varied terrain sweep.
	if not _local_investigation.is_empty():
		var nearby: Vector2 = _local_investigation[0]
		if _npc.global_position.distance_to(nearby) <= WAYPOINT_REACHED_RADIUS:
			_local_investigation.pop_front()
			if _local_investigation.is_empty():
				return
			nearby = _local_investigation[0]
		_walk_to(nearby)
		return
	if _search_waypoints.is_empty():
		return
	var target := _search_waypoints[_waypoint_index]
	if _npc.global_position.distance_to(target) <= WAYPOINT_REACHED_RADIUS:
		_waypoint_index = (_waypoint_index + 1) % _search_waypoints.size()
		target = _search_waypoints[_waypoint_index]
	_walk_to(target)


## One notice roll per unresolved sneak line, rolled the FIRST time the sweep
## passes within NOTICE_RADIUS of its center. Noticed → penalty; unnoticed →
## the line stays active and counts at scoring.
func _check_sneak_notices() -> void:
	if _unresolved_sneaks.is_empty():
		return
	var npc_pos: Vector2 = _npc.global_position
	for line_id in _unresolved_sneaks.keys():
		var line: ChalkLine = _find_line(int(line_id))
		if line == null or line.is_struck:
			_unresolved_sneaks.erase(line_id)
			continue
		# A hidden sneak is not globally detectable, even if its ID is
		# tracked. The same cover/inspection predicate gates BOTH sides.
		var detected := _cover_sys.can_notice_sneak(
			line.points, npc_pos, line.wall_concealed, line.hidden_cover_id) if _cover_sys else \
				HidingRules.can_reveal_line(line.points, npc_pos, line.wall_concealed)
		if not detected:
			continue
		_unresolved_sneaks.erase(line_id)  # resolved — rolled ONCE, pass or fail
		if randf() < _resolve_notice_chance():
			_apply_notice_penalty(line)


## NOTICED: emit the event, strike the sneak line, then auto-strike up to
## PENALTY_EXTRA_STRIKES nearest non-sneak defender lines inside
## PENALTY_RADIUS. Pause so the defender sees the wipe.
func _apply_notice_penalty(sneak_line: ChalkLine) -> void:
	var penalized: Array = [sneak_line.id]
	var center := _center_of(sneak_line.points)
	_draw_sys.strike_line(sneak_line.id)
	var near: Array = []
	for line in _draw_sys.get_active_lines():
		if line.is_sneak or line.is_struck:
			continue
		if _center_of(line.points).distance_to(center) <= PENALTY_RADIUS:
			near.append(line)
	near.sort_custom(func(a: ChalkLine, b: ChalkLine) -> bool:
		return _center_of(a.points).distance_squared_to(center) < _center_of(b.points).distance_squared_to(center))
	for i in range(mini(PENALTY_EXTRA_STRIKES, near.size())):
		if _draw_sys.strike_line(near[i].id):
			penalized.append(near[i].id)
	EventBus.emit(EventBus.EV_GAME_SNEAK_NOTICED, {
		"line_id": sneak_line.id,
		"position": center,
		"notice_chance": _resolve_notice_chance(),
		"difficulty": GameState.cpu_difficulty,
		"penalty_line_ids": penalized,
	})
	_pause_timer = NOTICE_PAUSE_SECONDS
	print("CpuSearchController: NOTICED sneak line %d — penalty lines %s" % [sneak_line.id, str(penalized)])


## Search around a genuine discovery, not at unseen chalk coordinates.
func _queue_local_investigation(found_at: Vector2) -> void:
	_local_investigation.clear()
	var zone := ZoneLayout.PLAYER_ZONE
	var nearby_sites: Array[Vector2] = []
	for site in HidingRules.get_cover_sites(false):
		var center: Vector2 = site["rect"].get_center()
		if center.distance_to(found_at) <= 380.0:
			nearby_sites.append(center)
	# Inspect probable surroundings and near walls to emulate looking for
	# additional chalk beside a discovered mark. Fewer checks on Easy.
	var desired := int(_search_profile["cover_stops"])
	nearby_sites.shuffle()
	for i in range(mini(desired, nearby_sites.size())):
		_local_investigation.append(nearby_sites[i])
	var checks := mini(3, maxi(1, desired - 1))
	for _i in range(checks):
		var offset := Vector2.RIGHT.rotated(_search_rng.randf_range(0.0, TAU)) \
				* _search_rng.randf_range(65.0, 205.0)
		_local_investigation.append(ZoneLayout.clamp_to_zone(found_at + offset, zone))


func _walk_to(target: Vector2) -> void:
	_npc.set_meta("target_position", target)
	_npc.set_meta("has_target", true)
	var sm: Node = _npc.get_node_or_null("EntityStateMachine")
	if sm and sm.has_method("current_state_name") and sm.current_state_name() != "walking":
		sm.transition_to("walking")


func _find_line(line_id: int) -> ChalkLine:
	for line in _draw_sys.get_active_lines():
		if line.id == line_id:
			return line
	return null


static func _center_of(points: Array[Vector2]) -> Vector2:
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size()) if points.size() > 0 else Vector2.ZERO
