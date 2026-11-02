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
	if cover != null:
		# A drawn line must be genuinely hidden UNDER the unlifted public pile.
		# ChalkLines z=10 plus stroke z=11 (relative), so cover must be >21.
		_check((cover as Node2D).z_index > 21,
			"uninspected leaf/brick cover renders over solo chalk")
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
		var live_line: ChalkLine = null
		if not marks.is_empty():
			live_line = marks[-1]
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
		var human_leaf: Dictionary = HidingRules.get_cover_sites(false)[2]
		var human_leaf_rect: Rect2 = human_leaf["rect"]
		var human_cover_line: Array[Vector2] = [
			human_leaf_rect.get_center() - Vector2(10, 0),
			human_leaf_rect.get_center() + Vector2(10, 0)]
		_check(not bool(cover.call("can_reveal", human_cover_line,
			human_leaf_rect.get_center(), false)),
			"CPU sees no hidden mark before cover inspection")
		_check(bool(cover.call("cpu_inspect_nearby",
			human_leaf_rect.get_center() + Vector2(50, 0), 1.0)),
			"CPU physically inspects reachable public cover")
		_check(bool(cover.call("can_reveal", human_cover_line,
			human_leaf_rect.get_center(), false)),
			"CPU gets same reveal result as human after inspection")
		_game_state.set("current_match", MATCH_DRAWING)
		_game_state.set("solo_active_searcher", -1)
		print(PREFIX + "FAIR_COVER_INSPECTION_OK")
		# A nearby cover across a solid wall must not be inspectable.
		var blocking_wall: Rect2 = HidingRules.get_zone_walls()[0]
		var blocked_actor := Vector2(blocking_wall.get_center().x,
			blocking_wall.position.y - 30.0)
		var blocked_cover := Rect2(Vector2(blocked_actor.x - 12.0,
			blocking_wall.end.y + 12.0), Vector2(24.0, 20.0))
		var clear_cover := Rect2(Vector2(blocked_actor.x - 12.0,
			blocked_actor.y - 36.0), Vector2(24.0, 20.0))
		_check(not bool(cover.call("can_physically_inspect",
			blocked_actor, blocked_cover)),
			"nearby cover cannot be inspected through a compound wall")
		_check(bool(cover.call("can_physically_inspect",
			blocked_actor, clear_cover)),
			"nearby cover can be inspected from an unobstructed side")
		print(PREFIX + "OBSTRUCTED_COVER_INSPECTION_OK")


	# Validate real hand reach BEFORE stress-inserting lots of human marks.
	# The legacy synthetic end-to-end harness uses a separate test override.
	var original_reach: float = float(ProjectSettings.get_setting(
		"chalk_gaon/solo_draw_reach_px", HidingRules.SOLO_HAND_REACH))
	ProjectSettings.set_setting("chalk_gaon/solo_draw_reach_px", HidingRules.SOLO_HAND_REACH)
	var remote_start := Vector2(2300, 700)
	root.get_node("EventBus").call("emit", "input.draw_start",
		{"entity_id": 1, "position": remote_start})
	root.get_node("EventBus").call("emit", "input.draw_update",
		{"entity_id": 1, "position": remote_start + Vector2(48, 0)})
	root.get_node("EventBus").call("emit", "input.draw_end", {"entity_id": 1})
	_check(draw.call("get_active_lines").is_empty(),
		"distant input cannot teleport chalk across territory")
	_check(not HidingRules.can_reach_point(Vector2(700, 450), Vector2(700, 510), 180.0),
		"walls block hand reach even inside nominal distance")
	_check(HidingRules.can_reach_point(Vector2(200, 300), Vector2(260, 300)),
		"valid nearby drawing remains allowed")
	print(PREFIX + "PHYSICAL_DRAW_REACH_OK")
	# A valid raw gesture may overshoot the hand radius when Catmull-Rom
	# smoothing runs. The *committed* geometry must be validated again.
	var original_actor_pos: Vector2 = player.global_position
	# Choose a genuinely unobstructed standing position from the live map,
	# rather than assuming decorative props leave a fixed fixture clear.
	var smooth_actor_pos := Vector2.INF
	var rel_probes: Array[Vector2] = [
		Vector2(156, 47), Vector2(162, 78),
		Vector2(172, 52), Vector2(164, 1)]
	for y in [80, 180, 330, 620]:
		if smooth_actor_pos.is_finite():
			break
		for x in [80, 240, 400, 700, 1050, 1800]:
			var candidate := Vector2(float(x), float(y))
			var works := true
			for rel in rel_probes:
				if not HidingRules.can_reach_point(candidate, candidate + rel):
					works = false
					break
			if works:
				smooth_actor_pos = candidate
				break
	_check(smooth_actor_pos.is_finite(), "smoothing fixture has an unobstructed position")
	if smooth_actor_pos.is_finite():
		player.global_position = smooth_actor_pos
	player.set_meta("has_target", false)
	var before_smoothing := int(draw.call("get_active_lines").size())
	var raw_relative: Array[Vector2] = [
		Vector2(156, 47), Vector2(162, 78),
		Vector2(172, 52), Vector2(164, 1)]
	var raw_ok := true
	for rel in raw_relative:
		raw_ok = raw_ok and HidingRules.can_reach_point(player.global_position,
			player.global_position + rel)
	_check(raw_ok, "smoothing regression uses four legal raw points")
	var smooth_pts: Array[Vector2] = []
	for rel in raw_relative:
		smooth_pts.append(player.global_position + rel)
	root.get_node("EventBus").call("emit", "input.draw_start",
		{"entity_id": 1, "position": smooth_pts[0]})
	for i in range(1, smooth_pts.size()):
		root.get_node("EventBus").call("emit", "input.draw_update",
			{"entity_id": 1, "position": smooth_pts[i]})
	root.get_node("EventBus").call("emit", "input.draw_end", {"entity_id": 1})
	_check(int(draw.call("get_active_lines").size()) == before_smoothing,
		"smoothed stroke beyond hand reach is rejected in real DrawSystem")
	player.global_position = original_actor_pos
	# A draw gesture must not also issue movement or a searcher strike.
	var bus := root.get_node("EventBus")
	var moves: Array = []
	var on_move := func(payload: Dictionary) -> void:
		moves.append(payload)
	bus.call("on", "input.move_start", on_move)
	var im := root.get_node("InputManager")
	im.set("_mouse_is_anchor", false)
	im.call("_handle_mouse_draw_start", Vector2(120, 120))
	im.call("_handle_mouse_draw_end", Vector2(120, 120))
	bus.call("off", "input.move_start", on_move)
	_check(moves.is_empty(), "desktop DRAW start cannot dispatch MOVE event")
	# Editing is only legal while hiding; a late undo must not change scores.
	var undo_probe := ChalkLine.new()
	undo_probe.id = 99111
	undo_probe.player_id = 1
	undo_probe.points = [Vector2(100, 100), Vector2(140, 100)]
	undo_probe.widths = [3.0, 3.0]
	draw.call("_add_line", undo_probe)
	draw.set("_last_drawn_line_id", undo_probe.id)
	draw.set("_last_draw_end_time", Time.get_ticks_msec() / 1000.0)
	_game_state.set("current_match", MATCH_SEARCHING)
	draw.call("_on_undo_draw")
	_check((draw.call("get_active_lines") as Array).has(undo_probe),
		"undo during SEARCHING cannot erase a surviving mark")
	_game_state.set("current_match", MATCH_DRAWING)
	draw.call("clear_all_lines")
	print(PREFIX + "DRAW_UNDO_INPUT_GEOMETRY_OK")
	# CPU uses exactly the same arm reach and obstruction test while drawing.
	_check(bot != null, "live CPU hider exists")
	if bot:
		for _attempt in range(12):
			var anchor: Vector2 = bot.call("_choose_public_hiding_anchor")
			_check(anchor.distance_to(cpu.global_position) <= HidingRules.SOLO_HAND_REACH,
				"CPU cannot select remote draw anchor")
			var packets: Array = bot.call("_build_line_dicts", anchor)
			for packet in packets:
				var generated := ChalkLine.new()
				generated.from_network_dict(packet)
				_check(generated.points.size() >= 2, "CPU generated chalk decodes")
				for point in generated.points:
					_check(HidingRules.can_reach_point(cpu.global_position, point),
						"CPU reachable mark actor=%s point=%s d=%.1f" % [
							str(cpu.global_position), str(point),
							cpu.global_position.distance_to(point)])
		print(PREFIX + "CPU_PHYSICAL_CHALK_REACH_OK")
	# Distribution must be live on the solo policy, not trapped in a
	# legacy branch that immediately returns for the current gameplay mode.
	if bot:
		var saved_cpu_strategy_pos: Vector2 = cpu.global_position
		var site_center: Vector2 = (
			HidingRules.get_cover_sites(true)[2]["rect"] as Rect2).get_center()
		cpu.global_position = site_center + Vector2(0, 45)
		var kinds := {"decoy": 0, "cover": 0, "open": 0}
		for _pick in range(160):
			bot.call("_choose_public_hiding_anchor")
			var kind := str(bot.get("_solo_anchor_last_kind"))
			if kinds.has(kind):
				kinds[kind] = int(kinds[kind]) + 1
		_check(int(kinds["decoy"]) >= 1 and int(kinds["cover"]) >= 1
			and int(kinds["open"]) >= 1,
			"solo CPU uses decoy, cover and open policy branches")
		cpu.global_position = saved_cpu_strategy_pos
		print(PREFIX + "CPU_PLACEMENT_POLICY_OK " + str(kinds))



	# Real human solo mode has NO 50-line cap: adding 65 valid marks must
	# never evict the first one to make room for a later one.
	var first_id := 3000
	for i in range(500):
		var chalk := ChalkLine.new()
		chalk.id = first_id + i
		chalk.player_id = 1
		chalk.points = [Vector2(100 + i * 12, 90),
			Vector2(130 + i * 12, 94)]
		chalk.widths = [3.0, 3.0]
		chalk.created_at = float(i)
		draw.call("_add_line", chalk)
	var all_lines: Array = draw.call("get_active_lines")
	_check(all_lines.size() >= 500,
		"500 human marks retained without an arbitrary cap or eviction")
	_check(all_lines.any(func(item: ChalkLine) -> bool: return item.id == first_id),
		"oldest human mark never auto-evicted")
	draw.call("clear_all_lines")
	print(PREFIX + "UNLIMITED_HUMAN_MARKS_OK count=500")

	# Manipulation of a physical brick while drawing: tap to flip open,
	# draw on its backside, tap to replace, then require a searcher to lift
	# it again. Drawing while closed instead must be classified exposed.
	if cover != null:
		var brick: Dictionary = HidingRules.get_cover_sites(false)[4]
		var center: Vector2 = (brick["rect"] as Rect2).get_center()
		var before_brick: Vector2 = player.global_position
		player.global_position = center + Vector2(0, 65)
		player.set_meta("has_target", false)
		# CPU may not magically claim an underside without standing at it.
		var cpu_site: Dictionary = HidingRules.get_cover_sites(true)[4]
		var cpu_center: Vector2 = (cpu_site["rect"] as Rect2).get_center()
		var saved_cpu: Vector2 = cpu.global_position
		_check(str(cover.call("cpu_open_for_hiding",
			str(cpu_site["id"]), cpu_center)).is_empty(),
			"CPU cannot remotely flip another site's brick")
		cpu.global_position = cpu_center + Vector2(0, 60)
		var flipped := str(cover.call("cpu_open_for_hiding",
			str(cpu_site["id"]), cpu.global_position))
		_check(flipped == str(cpu_site["id"]),
			"CPU can legitimately flip nearby cover")
		cover.call("cpu_close_after_hiding", flipped)
		_check(not (cover.call("opened_for_hiding") as Dictionary).has(flipped),
			"CPU replaces cover immediately after drawing")
		cpu.global_position = saved_cpu
		cover.call("_on_hider_draw_start", {"position": center})
		cover.call("_on_hider_draw_end", {})
		_check((cover.call("opened_for_hiding") as Dictionary).has(str(brick["id"])),
			"tap opens flipped brick for backside drawing")
		var stroke: Array[Vector2] = [center - Vector2(22, 0),
			center + Vector2(22, 0)]
		root.get_node("EventBus").call("emit", "input.draw_start",
			{"entity_id": 1, "position": stroke[0]})
		root.get_node("EventBus").call("emit", "input.draw_update",
			{"entity_id": 1, "position": stroke[1]})
		root.get_node("EventBus").call("emit", "input.draw_end", {"entity_id": 1})
		var under: Array = draw.call("get_active_lines")
		_check(under.size() == 1 and str(under[0].hidden_cover_id) == str(brick["id"]),
			"line drawn on flipped brick has actual underside metadata")
		cover.call("_on_hider_draw_start", {"position": center})
		cover.call("_on_hider_draw_end", {})
		_check((cover.call("opened_for_hiding") as Dictionary).is_empty(),
			"brick was replaced after hidden drawing")
		_check(not bool(cover.call("can_reveal", stroke, center, false,
			str(brick["id"]))), "replaced brick hides actual underside chalk")
		_check(bool(cover.call("can_reveal", stroke, center, false,
			"surface")), "line drawn visibly ON TOP of closed brick is exposed")
		draw.call("clear_all_lines")
		player.global_position = before_brick
		print(PREFIX + "FLIPPED_BRICK_UNDERSIDE_OK")

	var escort := world.get_node_or_null("DefenderEscort")
	_check(escort != null, "supervising defender-follow controller installed")
	if escort != null:
		_game_state.set("current_match", MATCH_SEARCHING)
		escort.call("_on_search_started", {"searcher": 2, "defender": 1})
		escort.set("_manual_override", 0.0)
		var prev_cpu: Vector2 = cpu.global_position
		var prev_player: Vector2 = player.global_position
		cpu.global_position = ZoneLayout.clamp_to_player_zone(
			prev_player + Vector2(360, 0))
		escort.call("_process", 0.1)
		_check(bool(player.get_meta("has_target", false)),
			"human defender follows CPU striker to supervise")
		var followed_target: Vector2 = player.get_meta("target_position")
		_check(followed_target.distance_to(cpu.global_position) < 200.0,
			"defender follows from nearby rather than teleporting")
		escort.call("_on_human_move", {"entity_id": 1})
		_check(float(escort.get("_manual_override")) > 2.0,
			"human tap takes control away from automatic follow")
		escort.call("_on_search_ended", {})
		cpu.global_position = prev_cpu
		player.global_position = prev_player
		player.set_meta("has_target", false)
		_game_state.set("current_match", MATCH_DRAWING)
		print(PREFIX + "DEFENDER_SUPERVISION_OK")

	# Public object hiding is only fair if a striker can physically reach
	# and inspect its nearest ground-accessible edge. No site is isolated by
	# compound wall collision, and both roles share the exact same graph.
	var navigation := world.get_node_or_null("VillageNavigation") as Node
	_check(navigation != null, "solid wall pathfinding is enabled")
	if navigation:
		for site in HidingRules.get_all_cover_sites():
			var region: Rect2 = site["rect"]
			var approach: Vector2 = navigation.call("reachable_approach", region.get_center())
			_check(bool(navigation.call("is_walkable", approach)),
				"public cover has accessible ground approach")
			var start: Vector2 = ZoneLayout.SEARCH_ENTRY_HUMAN if \
					str(site["id"]).begins_with("cpu-") else ZoneLayout.SEARCH_ENTRY_CPU
			var route: PackedVector2Array = navigation.call("find_route", start, approach)
			_check(route.size() > 0 and route[-1].distance_to(approach) < 20.0,
				"searcher can reach every team's covered hiding spot")
		for wall in HidingRules.get_all_walls():
			var center: Vector2 = (wall as Rect2).get_center()
			_check(not bool(navigation.call("is_walkable", center)),
				"compound-wall center is actually solid")
			var edge: Vector2 = navigation.call("reachable_approach", center)
			_check(bool(navigation.call("is_walkable", edge)),
				"chalk on a wall can be inspected from its reachable edge")
		var house := world.get_node_or_null("Props/PlayerZoneProps/House01") as Sprite2D
		var well := world.get_node_or_null("Props/PlayerZoneProps/Well") as Sprite2D
		_check(house != null and well != null, "visible house and well exist")
		if house and well:
			_check(not bool(navigation.call("is_walkable", house.global_position)),
				"visible house footprint blocks physical movement")
			_check(not bool(navigation.call("is_walkable", well.global_position)),
				"visible well footprint blocks physical movement")
		print(PREFIX + "ALL_HIDING_SITES_REACHABLE_OK")
		# Fuzz exact (continuous) walkability against A* endpoints.
		var nav_rng := RandomNumberGenerator.new()
		nav_rng.seed = 173818
		var route_checks := 0
		for cpu_zone in [false, true]:
			var zone := ZoneLayout.CPU_ZONE if cpu_zone else ZoneLayout.PLAYER_ZONE
			var origin: Vector2 = ZoneLayout.SEARCH_ENTRY_HUMAN if cpu_zone else ZoneLayout.SEARCH_ENTRY_CPU
			for _iteration in range(50):
				var point := Vector2(
					nav_rng.randf_range(zone.position.x + 45.0, zone.end.x - 45.0),
					nav_rng.randf_range(zone.position.y + 45.0, zone.end.y - 45.0))
				if not bool(navigation.call("is_walkable", point)):
					continue
				var goal: Vector2 = navigation.call("reachable_approach", point)
				_check(goal.is_finite(), "fuzzed walkable goal projects to finite A* cell")
				var path: PackedVector2Array = navigation.call("find_route", origin, point)
				_check(not path.is_empty(), "A* can approach a sampled legal destination")
				if not path.is_empty():
					_check(path[-1].distance_to(goal) <= 40.0,
						"navigation endpoint stays near requested safe approach")
				route_checks += 1
		print(PREFIX + "NAVIGATION_FUZZ_OK routes=" + str(route_checks))


	ProjectSettings.set_setting("chalk_gaon/solo_draw_reach_px", original_reach)
	# Regression: a real mobile tap finishes its walking route AFTER
	# finger-up. Previously the move_end event immediately cancelled it.
	player.set_meta("target_position", player.global_position + Vector2(90, 0))
	player.set_meta("has_target", true)
	player.call("_on_move_stop", {})
	_check(bool(player.get_meta("has_target", false)),
		"solo tap-to-move survives finger release")
	player.set_meta("has_target", false)
	print(PREFIX + "TAP_TO_MOVE_PERSISTS_OK")

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
	# Force a genuine missing-overlay error path after ordinary movement and
	# physics tests; it must never trap the game forever in MEETING.
	var machine := driver.get("_match_machine") as Node
	_check(machine != null, "meeting fallback has match state machine")
	if machine:
		_check(bool(machine.call("transition_to", GameState.MatchState.MEETING)),
			"component can enter the real coin meeting phase")
		driver.call("_free_coin_overlay")
		driver.set("_meeting_assembled", true)
		driver.call("_tick_meeting_phase", float(driver.get("_meeting_max_seconds"))
			+ float(driver.get("_coin_result_hold")) + 1.0)
		_check(int(_game_state.call("get_match_state")) == MATCH_SEARCHING,
			"missing coin overlay must resolve and advance to SEARCHING")
		print(PREFIX + "COIN_OVERLAY_FALLBACK_OK")
		# Real entry gating (no accelerated smoke override in component suite).
		_check(bool(driver.get("_awaiting_search_arrival")),
			"searcher must physically arrive before 30s timer starts")
		var timer := root.get_node("MatchTimer")
		_check(not bool(timer.call("is_running")),
			"search clock cannot run while walking to zone")
		var first_searcher := int(driver.get("active_searcher"))
		var arriving_actor := world.call("get_entity", first_searcher) as CharacterBody2D
		if arriving_actor:
			var entry: Vector2 = ZoneLayout.SEARCH_ENTRY_HUMAN if first_searcher == 1 \
				else ZoneLayout.SEARCH_ENTRY_CPU
			arriving_actor.global_position = entry
			arriving_actor.set_meta("has_target", false)
			driver.call("_process", 0.016)
			_check(not bool(driver.get("_awaiting_search_arrival"))
				and bool(driver.get("_search_phase_active")),
				"actual search entry activates scanning exactly once")
			_check(bool(timer.call("is_running")),
				"the 30s search clock starts at physical arrival")
			# A zero-target round may request an intentional grace early exit.
			# Isolate ordinary timeout authority by disabling that explicit
			# early-exit path before advancing the presentation counter.
			driver.set("_phase_end_pending", false)
			driver.call("_process", float(driver.get("_search_phase_seconds")) + 5.0)
			_check(int(driver.get("_search_phase_index")) == 1,
				"local display counter cannot independently expire search")
			timer.call("_process", float(driver.get("_search_phase_seconds")) + 0.5)
			_check(int(driver.get("_search_phase_index")) == 2,
				"MatchTimer expiry advances to the second search phase")
			_check(bool(driver.get("_awaiting_search_arrival"))
				and not bool(timer.call("is_running")),
				"role swap requires new arrival before phase-two clock")
			print(PREFIX + "ARRIVAL_AND_SINGLE_CLOCK_OK")
	_finish()


func _finish() -> void:
	if _errors > 0:
		print(PREFIX + "FAIL checks=%d errors=%d" % [_checks, _errors])
		quit(1)
	else:
		print(PREFIX + "PASS checks=%d" % _checks)
		quit(0)
