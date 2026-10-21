# MvpComponentSuite.gd -- actual scene/system integration and pause-physics gate.
# Small, independent component suite; full games are covered by playable smoke.
extends SceneTree

const PREFIX := "KATTIPAAY_COMPONENT: "
var _checks: int = 0
var _errors: int = 0
var _game_state: Node = null
const TOP_PLAYING := 3
const TOP_PAUSED := 4
const MATCH_DRAWING := 4
const MATCH_SEARCHING := 6
const MATCH_PAUSED := 12

func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_errors += 1
		push_error(PREFIX + "FAIL " + description)


func _run() -> void:
	_game_state = root.get_node_or_null("GameState")
	_check(_game_state != null, "GameState autoload")
	if _game_state == null:
		_finish()
		return
	_game_state.set("solo_vs_cpu", true)
	_game_state.set("cpu_difficulty", 1)
	_check(bool(_game_state.call("transition", TOP_PLAYING)),
		"transition from SPLASH to PLAYING")
	for _i in range(5):
		await process_frame
	var world := current_scene
	_check(world != null and world.name == "GameWorld", "game world instantiated")
	if world == null or world.name != "GameWorld":
		_finish()
		return
	var player := world.call("get_entity", 1) as CharacterBody2D
	var cpu := world.call("get_entity", 2) as CharacterBody2D
	var draw := world.get_node_or_null("Systems/DrawSystem") as Node
	var ghost := world.get_node_or_null("Systems/GhostDrawSystem") as Node
	var fog := world.get_node_or_null("Systems/FogSystem") as Node
	var driver := world.get_node_or_null("SoloMatchDriver")
	var sweep := world.get_node_or_null("SoloMatchDriver/CpuSearchController") as Node
	var strike := world.get_node_or_null("SoloMatchDriver/StrikeSystem") as Node
	var bot := world.get_node_or_null("SoloMatchDriver/GhostBot") as Node
	var hud := world.get_node_or_null("HUD") as Node
	_check(player != null and cpu != null, "human and CPU entities spawned")
	_check(draw != null and ghost != null and fog != null, "drawing/fog systems ready")
	_check(driver != null and sweep != null and strike != null and bot != null,
		"solo match systems ready")
	_check(hud != null, "live HUD ready")
	var cover := world.get_node_or_null("CoverSystem") as Node
	_check(cover != null, "fair mirrored cover inspector present")
	if player == null or cpu == null or draw == null or ghost == null \
			or sweep == null or strike == null or driver == null:
		_finish()
		return
	_check(int(_game_state.call("get_match_state")) == MATCH_DRAWING,
		"driver enters DRAWING for solo match")
	var engine_start: int = draw.call("get_active_lines").size()
	# A forged SEARCH draw input must not insert marks. This is separate from
	# the smoke test's long-press/meeting checks.
	var points: Array[Vector2] = [Vector2(250, 210), Vector2(400, 210)]
	draw.set("sneak_mode", false)
	_game_state.set("current_match", MATCH_SEARCHING)
	root.get_node("EventBus").call("emit", "input.draw_start", {"entity_id": 1, "position": points[0]})
	root.get_node("EventBus").call("emit", "input.draw_update", {"entity_id": 1, "position": points[1]})
	root.get_node("EventBus").call("emit", "input.draw_end", {"entity_id": 1})
	_check(draw.call("get_active_lines").size() == engine_start,
		"search-phase fake drawing input rejected")
	_game_state.set("current_match", MATCH_DRAWING)

	# Physical inspection: faraway taps cannot X-ray a covered line.
	if cover != null:
		var site: Dictionary = HidingRules.get_cover_sites(true)[2]
		var rect: Rect2 = site["rect"]
		var covered: Array[Vector2] = [
			rect.get_center() - Vector2(10, 0),
			rect.get_center() + Vector2(10, 0)]
		var distant := rect.get_center() + Vector2(500, 0)
		_game_state.set("current_match", MATCH_SEARCHING)
		_game_state.set("solo_active_searcher", 1)
		_check(not bool(cover.call("inspect_at", 1, rect.get_center(), distant)),
			"remote human tap cannot inspect cover")
		_check(not bool(cover.call("can_reveal", covered, rect.get_center(), false)),
			"uninspected leaf line invisible")
		# Integration: actual GhostDrawSystem must not discover or strike a
		# covered line at zero distance before the human lifts the leaves.
		var original_pos := player.global_position
		player.global_position = rect.get_center()
		player.set_meta("has_target", false)
		var test_line := ChalkLine.new()
		test_line.id = -1
		test_line.points = covered
		test_line.widths = [3.0, 3.0]
		test_line.player_id = 2
		test_line.is_ghost = true
		test_line.ghost_owner_id = 2
		ghost.call("_on_network_ghost_lines_placed", {
			"lines": [test_line.to_network_dict()], "owner_id": 2})
		var marks: Array = ghost.call("get_active_ghost_lines")
		_check(not marks.is_empty(), "covered CPU line added to live game store")
		if not marks.is_empty():
			var live_line: ChalkLine = marks[-1]
			ghost.call("_on_fog_revealed", {
				"player_id": 1, "position": player.global_position, "radius": 200.0})
			ghost.call("_check_discovery")
			_check(not live_line.is_discovered,
				"actual human GhostDrawSystem cannot passively X-ray covered mark")
			strike.call("_on_search_phase_started", {"searcher": 1})
			_check(not bool(strike.call("strike_ghost_line", live_line.id)),
				"direct strike ID cannot bypass unopened cover")
		_check(bool(cover.call("inspect_at", 1, rect.get_center(),
			rect.get_center() + Vector2(60, 0))), "human can inspect nearby leaf")
		_check(bool(cover.call("can_reveal", covered, rect.get_center(), false)),
			"inspected nearby mark discovered")
		if not marks.is_empty():
			ghost.call("_check_discovery")
			_check(live_line.is_discovered,
				"real GhostDrawSystem reveals stroke after nearby inspection")
			_check(bool(strike.call("strike_ghost_line", live_line.id)),
				"real StrikeSystem strikes physically discovered inspected stroke")
			strike.call("_on_search_phase_ended", {})
		player.global_position = original_pos
		_check(not bool(cover.call("can_reveal", covered, distant, false)),
			"inspection never remotely reveals mark")
		cover.call("_on_search_started", {"searcher": 2})
		_game_state.set("solo_active_searcher", 2)
		_check(not bool(cover.call("cpu_inspect_nearby", distant, 1.0)),
			"CPU cannot inspect cover from another zone")
		_game_state.set("current_match", MATCH_DRAWING)
		_game_state.set("solo_active_searcher", -1)
		print(PREFIX + "FAIR_COVER_INSPECTION_OK")

	# Real EntityStateMachine movement, not just a manually incremented clock.
	# Both avatars must remain frozen while the pause overlay is active.
	var player_sm := player.get_node_or_null("EntityStateMachine") as Node
	var cpu_sm := cpu.get_node_or_null("EntityStateMachine") as Node
	_check(player_sm != null and cpu_sm != null, "entity movement state machines exist")
	if player_sm == null or cpu_sm == null:
		_finish()
		return
	cpu.set("patrolling", false)
	player.set_meta("move_speed", 220.0)
	cpu.set_meta("move_speed", 220.0)
	player.set_meta("target_position", player.global_position + Vector2(300, 0))
	player.set_meta("has_target", true)
	cpu.set_meta("target_position", cpu.global_position + Vector2(300, 0))
	cpu.set_meta("has_target", true)
	player_sm.call("transition_to", "walking")
	cpu_sm.call("transition_to", "walking")
	await create_timer(0.12).timeout
	_check(bool(_game_state.call("transition", TOP_PAUSED)), "pause accepted")
	var human_frozen: Vector2 = player.global_position
	var cpu_frozen: Vector2 = cpu.global_position
	await create_timer(0.22).timeout
	_check(player.global_position.distance_to(human_frozen) < 0.2,
		"human physics frozen while paused")
	_check(cpu.global_position.distance_to(cpu_frozen) < 0.2,
		"CPU physics frozen while paused")
	_check(int(_game_state.call("get_match_state")) == MATCH_PAUSED,
		"match-level state actually paused")
	_check(bool(_game_state.call("transition", TOP_PLAYING)), "resume accepted")
	_check(int(_game_state.call("get_match_state")) == MATCH_DRAWING,
		"resume returns to drawing without resetting phase")
	await create_timer(0.18).timeout
	_check(player.global_position.distance_to(human_frozen) > 2.0,
		"human movement resumes to original target")
	_check(cpu.global_position.distance_to(cpu_frozen) > 2.0,
		"CPU movement resumes to original target")
	player.set_meta("has_target", false)
	cpu.set_meta("has_target", false)
	print(PREFIX + "PAUSED_MOVEMENT_OK")
	_finish()


func _finish() -> void:
	if _errors > 0:
		print(PREFIX + "FAIL checks=%d errors=%d" % [_checks, _errors])
		quit(1)
	else:
		print(PREFIX + "PASS checks=%d" % _checks)
		quit(0)
