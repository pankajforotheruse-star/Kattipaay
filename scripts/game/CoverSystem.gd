# CoverSystem.gd — shared physical inspection for human and CPU searchers.
# PUBLIC cover geometry comes exclusively from HidingRules, in both zones.
# A human must approach leaves/bricks and tap their visible cover sprite.
# The CPU can only inspect after its actual character reaches the same range.
# Inspection persists only for this search phase, not across future rounds.
class_name CoverSystem
extends Node2D

var _inspected: Dictionary = {}
var _opened_for_hiding: Dictionary = {}
var _draw_tap_start := Vector2.ZERO
var _draw_tap_moved: float = 0.0
var _draw_tap_active := false
var _cpu_attempted: Dictionary = {}
var _cpu_rng := RandomNumberGenerator.new()
var _feedback: String = ""
var _feedback_time := 0.0

func _ready() -> void:
	_cpu_rng.randomize()
	# Chalk containers draw at z=10 and their Line2D strokes at z=10/11
	# relative to the container (effective 20/21). Public piles need to
	# cover the chalk visually until inspected, not sit beneath it.
	z_index = 22
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_started)
	EventBus.on(EventBus.EV_INPUT_MOVE_START, _on_human_tap)
	EventBus.on(EventBus.EV_INPUT_DRAW_START, _on_hider_draw_start)
	EventBus.on(EventBus.EV_INPUT_DRAW_UPDATE, _on_hider_draw_update)
	EventBus.on(EventBus.EV_INPUT_DRAW_END, _on_hider_draw_end)

func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_started)
	EventBus.off(EventBus.EV_INPUT_MOVE_START, _on_human_tap)
	EventBus.off(EventBus.EV_INPUT_DRAW_START, _on_hider_draw_start)
	EventBus.off(EventBus.EV_INPUT_DRAW_UPDATE, _on_hider_draw_update)
	EventBus.off(EventBus.EV_INPUT_DRAW_END, _on_hider_draw_end)

func _on_search_started(_payload: Dictionary) -> void:
	# Hiding finishes when the clock expires; remaining open surfaces are
	# put back into place so searchers see ordinary-looking public objects.
	_opened_for_hiding.clear()
	_inspected.clear()
	_cpu_attempted.clear()
	_feedback = ""
	queue_redraw()

## During the human's own DRAW phase, a short tap on a visible brick/leaf
## flips/lifts it. Draw under/behind it with the next drag; tap again to
## replace it. This is an explicit manipulation, not an invisible power-up.
func _on_hider_draw_start(payload: Dictionary) -> void:
	if not GameState.solo_vs_cpu or GameState.get_match_state() != GameState.MatchState.DRAWING:
		return
	_draw_tap_active = true
	_draw_tap_start = payload.get("position", Vector2.ZERO)
	_draw_tap_moved = 0.0

func _on_hider_draw_update(payload: Dictionary) -> void:
	if _draw_tap_active:
		_draw_tap_moved = maxf(_draw_tap_moved,
			_draw_tap_start.distance_to(payload.get("position", _draw_tap_start)))

func _on_hider_draw_end(_payload: Dictionary) -> void:
	if not _draw_tap_active:
		return
	_draw_tap_active = false
	if _draw_tap_moved > 12.0 or GameState.get_match_state() != GameState.MatchState.DRAWING:
		return
	for site in HidingRules.get_cover_sites(false):
		if not HidingRules.is_inspectable_cover(int(site["kind"])):
			continue
		if (site["rect"] as Rect2).has_point(_draw_tap_start):
			var id := str(site["id"])
			if _opened_for_hiding.has(id):
				_opened_for_hiding.erase(id)
			else:
				_opened_for_hiding[id] = true
			queue_redraw()
			print("CoverSystem: human flipped %s; opened=%s" % [
				id, str(_opened_for_hiding.has(id))])
			return

func opened_for_hiding() -> Dictionary:
	return _opened_for_hiding.duplicate()


func inspected_sites() -> Dictionary:
	return _inspected.duplicate()

func can_reveal(points: Array, searcher_pos: Vector2,
		wall_concealed: bool, hidden_cover_id: String = "") -> bool:
	return HidingRules.can_reveal_line(points, searcher_pos, wall_concealed,
		_inspected, hidden_cover_id)

func can_notice_sneak(points: Array, searcher_pos: Vector2,
		wall_concealed: bool, hidden_cover_id: String = "") -> bool:
	return can_reveal(points, searcher_pos, wall_concealed, hidden_cover_id)

## Searcher must actually be within INSPECTION_RADIUS of the public cover.
## Tapping a faraway cover while en route cannot inspect it.
func inspect_at(searcher_id: int, tap_world_pos: Vector2, actor_pos: Vector2) -> bool:
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		return false
	if GameState.solo_active_searcher != searcher_id:
		return false
	var zone_cpu := searcher_id == 1
	for site in HidingRules.get_cover_sites(zone_cpu):
		if not HidingRules.is_inspectable_cover(int(site["kind"])):
			continue
		var region: Rect2 = site["rect"]
		if not region.has_point(tap_world_pos):
			continue
		if _distance_to_rect(actor_pos, region) > HidingRules.INSPECTION_RADIUS:
			return false
		_inspected[str(site["id"])] = true
		_feedback = ("LEAVES CHECKED" if int(site["kind"]) == HidingRules.COVER_LEAVES else "BRICKS CHECKED")
		_feedback_time = 1.5
		queue_redraw()
		print("CoverSystem: searcher %d inspected %s" % [searcher_id, str(site["id"])])
		return true
	return false

## CPU can try one physical inspection per cover site per phase.
## Probability is a decision skill, not extra vision. The eligible positions
## and consequences are identical for both participants.
func cpu_inspect_nearby(actor_pos: Vector2, chance: float) -> bool:
	if GameState.get_match_state() != GameState.MatchState.SEARCHING \
			or GameState.solo_active_searcher != 2:
		return false
	for site in HidingRules.get_cover_sites(false):
		if not HidingRules.is_inspectable_cover(int(site["kind"])):
			continue
		var id := str(site["id"])
		if _cpu_attempted.has(id):
			continue
		var rect: Rect2 = site["rect"]
		if _distance_to_rect(actor_pos, rect) > HidingRules.INSPECTION_RADIUS:
			continue
		_cpu_attempted[id] = true
		if _cpu_rng.randf() <= clampf(chance, 0.0, 1.0):
			return inspect_at(2, rect.get_center(), actor_pos)
	return false

static func _distance_to_rect(point: Vector2, rect: Rect2) -> float:
	var nearest := Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y))
	return point.distance_to(nearest)

func _on_human_tap(payload: Dictionary) -> void:
	if not GameState.solo_vs_cpu or GameState.solo_active_searcher != 1:
		return
	if GameState.get_match_state() != GameState.MatchState.SEARCHING \
			or GameState.current == GameState.State.PAUSED:
		return
	var world := get_parent()
	if world == null or not world.has_method("get_entity"):
		return
	var human := world.get_entity(1) as Node2D
	if human:
		var tap := InputManager.screen_to_world(payload.get("screen_position", Vector2.ZERO))
		inspect_at(1, tap, human.global_position)

func _process(delta: float) -> void:
	if _feedback_time > 0.0:
		_feedback_time -= delta
		if _feedback_time <= 0.0:
			_feedback = ""
			queue_redraw()

func _draw() -> void:
	for site in HidingRules.get_all_cover_sites():
		var region: Rect2 = site["rect"]
		var kind := int(site["kind"])
		if kind == HidingRules.COVER_TREE:
			draw_ellipse(region.get_center(), region.size * 0.5, Color(0.08, 0.18, 0.10, 0.30))
			continue
		if kind == HidingRules.COVER_ROOF:
			draw_rect(region, Color(0.39, 0.29, 0.22, 0.57), true)
			draw_rect(region, Color(0.19, 0.17, 0.15, 0.75), false, 3.0)
			for dx in range(14, int(region.size.x), 28):
				draw_line(region.position + Vector2(dx, 5),
					region.position + Vector2(dx, region.size.y - 5),
					Color(0.20, 0.15, 0.13, 0.31), 1.0)
			continue
		var checked := _inspected.has(str(site["id"])) or \
				_opened_for_hiding.has(str(site["id"]))
		var color := Color(0.29, 0.42, 0.18, 0.85) if kind == HidingRules.COVER_LEAVES else Color(0.58, 0.40, 0.28, 0.95)
		if checked:
			color.a = 0.24
		draw_rect(region, color, true)
		draw_rect(region, Color(0.95, 0.85, 0.48, 0.90) if checked else Color(0.2, 0.18, 0.12, 0.6), false, 3.0)
		if kind == HidingRules.COVER_BRICKS and not checked:
			for dx in range(16, int(region.size.x), 32):
				draw_line(region.position + Vector2(dx, 5), region.position + Vector2(dx, region.size.y - 5), Color(0.29, 0.23, 0.17, 0.50), 2.0)

## Godot 4.4 CanvasItem has no draw_ellipse primitive; draw a filled, smooth
## polygon so tree shade renders without introducing texture dependencies.
func draw_ellipse(center: Vector2, radius: Vector2, color: Color) -> void:
	var vertices := PackedVector2Array()
	for i in range(33):
		var angle := TAU * float(i) / 32.0
		vertices.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	draw_colored_polygon(vertices, color)
