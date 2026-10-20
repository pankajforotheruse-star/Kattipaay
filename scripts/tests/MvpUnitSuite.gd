# MvpUnitSuite.gd -- deterministic Godot 4.4 unit/property test gate.
# Run: godot --headless --path . --script res://scripts/tests/MvpUnitSuite.gd
# Intentionally has no dependency on an external test add-on.
extends SceneTree

const PREFIX := "KATTIPAAY_UNIT: "
var _checks: int = 0
var _failures: int = 0
var _game_state: Node = null

func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(PREFIX + "FAIL " + label)


func _run() -> void:
	_game_state = root.get_node_or_null("GameState")
	_check(_game_state != null, "GameState autoload present")
	if _game_state == null:
		quit(1)
		return
	_test_zone_invariants()
	_test_visibility_boundaries()
	_test_chalk_roundtrip()
	_test_search_policy()
	_test_scoring_decisions()
	await _test_phase_timer()
	if _failures > 0:
		print(PREFIX + "FAIL checks=%d failures=%d" % [_checks, _failures])
		quit(1)
	else:
		print(PREFIX + "PASS checks=%d" % _checks)
		quit(0)


func _test_zone_invariants() -> void:
	_check(ZoneLayout.PLAYER_ZONE.end.y == ZoneLayout.ALLEY.position.y, "human zone meets alley")
	_check(ZoneLayout.ALLEY.end.y == ZoneLayout.CPU_ZONE.position.y, "CPU zone meets alley")
	_check(ZoneLayout.CPU_ZONE.end == ZoneLayout.WORLD_SIZE, "CPU zone matches world size")
	_check(ZoneLayout.ALLEY.has_point(ZoneLayout.MEETING_POINT), "meeting point inside alley")
	_check(ZoneLayout.CPU_ZONE.has_point(ZoneLayout.SEARCH_ENTRY_HUMAN), "human search entry in CPU zone")
	_check(ZoneLayout.PLAYER_ZONE.has_point(ZoneLayout.SEARCH_ENTRY_CPU), "CPU search entry in human zone")
	for p in [Vector2(-10, -30), Vector2(9000, 9000), Vector2(2400, 780),
			Vector2(0, 0), Vector2(950, 500), Vector2(-INF, -INF)]:
		if not is_finite(p.x) or not is_finite(p.y):
			continue
		_check(ZoneLayout.PLAYER_ZONE.has_point(ZoneLayout.clamp_to_player_zone(p)),
			"human clamp stays inside Rect2 incl far edge")
		_check(ZoneLayout.CPU_ZONE.has_point(ZoneLayout.clamp_to_cpu_zone(p)),
			"CPU clamp stays inside Rect2 incl far edge")
	var hwalls := HidingRules.get_zone_walls()
	var cwalls := HidingRules.get_cpu_walls()
	_check(hwalls.size() == 3 and cwalls.size() == hwalls.size(), "wall geometry mirrors")
	for i in range(hwalls.size()):
		var h: Rect2 = hwalls[i]
		var c: Rect2 = cwalls[i]
		_check(h.size == c.size and is_equal_approx(c.position.y - h.position.y,
			ZoneLayout.CPU_ZONE.position.y), "wall dimensions mirrored into CPU zone")
		_check(ZoneLayout.PLAYER_ZONE.encloses(h), "human wall inside zone")
		_check(ZoneLayout.CPU_ZONE.encloses(c), "CPU wall inside zone")
	print(PREFIX + "ZONE_GEOMETRY_OK")


func _test_visibility_boundaries() -> void:
	_check(HidingRules.REVEAL_RADIUS_OPEN > HidingRules.REVEAL_RADIUS_OCCLUDED,
		"wall concealment strictly harder than ground")
	var line: Array[Vector2] = [Vector2(100, 100), Vector2(220, 100)]
	for occluded in [false, true]:
		var radius := HidingRules.reveal_radius_for(occluded)
		_check(HidingRules.is_revealed(line, Vector2(160, 100 + radius - 1), occluded),
			"inside reveal radius")
		_check(HidingRules.is_revealed(line, Vector2(160, 100 + radius), occluded),
			"exact reveal boundary")
		_check(not HidingRules.is_revealed(line, Vector2(160, 101 + radius), occluded),
			"outside reveal radius")
	_check(not HidingRules.is_revealed([], Vector2.ZERO, false), "no phantom empty reveal")
	_check(not HidingRules.is_revealed([Vector2.ZERO], Vector2.ZERO, false),
		"single-point mark not a discoverable line")
	_check(HidingRules.nearest_point_on_line(line, Vector2(160, 300)).distance_to(Vector2(160, 100)) < 0.001,
		"nearest point chooses segment, not midpoint")
	var wall: Rect2 = HidingRules.get_zone_walls()[0]
	var crossed: Array[Vector2] = [Vector2(wall.position.x - 50, wall.get_center().y),
		Vector2(wall.end.x + 50, wall.get_center().y)]
	_check(HidingRules.is_wall_concealed(crossed), "segment crossing wall is concealed")
	_check(not HidingRules.is_wall_concealed(line), "open-ground segment not concealed")
	_check(HidingRules.is_wall_concealed([wall.get_center(), wall.get_center() + Vector2(30, 0)]),
		"line starting inside wall is concealed")
	print(PREFIX + "VISIBILITY_GEOMETRY_OK")


func _test_chalk_roundtrip() -> void:
	var line := ChalkLine.new()
	line.id = 222
	line.player_id = 2
	line.points = [Vector2(1050.5, 1170.5), Vector2(1150.0, 1185.0),
		Vector2(1200.0, 1200.0)]
	line.widths = [3.0, 4.0, 3.0]
	line.is_ghost = true
	line.is_sneak = true
	line.wall_concealed = true
	line.ghost_owner_id = 2
	line.ghost_placed_at = 1842.0
	line.is_discovered = false
	var packet := line.to_network_dict()
	var clone := ChalkLine.new()
	clone.from_network_dict(packet)
	_check(clone.id == line.id and clone.player_id == line.player_id,
		"chalk IDs/owner round-trip")
	_check(clone.is_ghost and clone.is_sneak and clone.wall_concealed,
		"hidden/sneak/concealment flags round-trip")
	_check(clone.points.size() >= 2 and clone.get_total_length() > 90.0,
		"compressed line still valid")
	_check(clone.ghost_owner_id == 2, "ghost owner round-trip")
	_check(not clone.is_discovered, "new mark remains hidden")
	_check(ChalkLine.compute_center([]) == Vector2.ZERO, "empty-line center safe")
	_check(ChalkLine.compute_size([]) == Vector2(20, 20), "empty-line rendering bounds safe")
	line.is_ghost = true
	line.created_at = 1
	_check(not line.is_expired(), "ghost chalk never expires")
	print(PREFIX + "CHALK_SERIALIZATION_OK")


func _test_search_policy() -> void:
	var cpu := CpuSearchController.new()
	var zone := ZoneLayout.PLAYER_ZONE
	var entry := ZoneLayout.SEARCH_ENTRY_CPU
	var base: Array[Vector2] = cpu._build_search_waypoints(zone, entry)
	_check(base.size() >= 8, "zone sweep has multiple waypoints")
	for wp in base:
		_check(zone.has_point(wp), "public CPU sweep stays inside human zone")
	var second: Array[Vector2] = cpu._build_search_waypoints(zone, entry)
	_check(base == second, "CPU route deterministic from public geometry")
	var line := ChalkLine.new()
	line.id = 42
	line.points = [Vector2(100, 80), Vector2(180, 80)]
	var typed: Array = [line]
	_check(cpu.probe_revealed_line_ids(typed, Vector2(2200, 700)).is_empty(),
		"CPU cannot inspect remote hidden marks")
	_check(cpu.probe_revealed_line_ids(typed, Vector2(150, 140)).has(42),
		"CPU can inspect encountered marks")
	line.wall_concealed = true
	_check(cpu.probe_revealed_line_ids(typed, Vector2(150, 200)).is_empty(),
		"CPU respects smaller occluded distance")
	line.is_sneak = true
	_check(cpu.probe_revealed_line_ids(typed, Vector2(150, 80)).is_empty(),
		"special sneaks are not ordinary search targets")
	line.is_sneak = false
	line.is_struck = true
	_check(cpu.probe_revealed_line_ids(typed, Vector2(150, 80)).is_empty(),
		"struck marks cannot be targeted twice")
	var settings_before = ProjectSettings.get_setting("chalk_gaon/cpu_sneak_notice_chance", -1.0)
	ProjectSettings.set_setting("chalk_gaon/cpu_sneak_notice_chance", -1.0)
	var prev_difficulty := int(_game_state.get("cpu_difficulty"))
	_game_state.set("cpu_difficulty", 0)
	var easy_chance: float = cpu._resolve_notice_chance()
	_game_state.set("cpu_difficulty", 3)
	var hard_chance: float = cpu._resolve_notice_chance()
	_check(easy_chance < hard_chance, "higher difficulty increases legitimate sneak notice")
	_game_state.set("cpu_difficulty", prev_difficulty)
	ProjectSettings.set_setting("chalk_gaon/cpu_sneak_notice_chance", settings_before)
	cpu.free()
	print(PREFIX + "CPU_SEARCH_POLICY_OK")


func _test_scoring_decisions() -> void:
	var score := root.get_node_or_null("ScoringManager")
	if score == null:
		_check(false, "scoring autoload exists")
		return
	var prev_solo := bool(_game_state.get("solo_vs_cpu"))
	_game_state.set("solo_vs_cpu", true)
	for case in [{"human": 7, "cpu": 3, "winner": 1}, {"human": 2, "cpu": 8, "winner": 2},
			{"human": 0, "cpu": 0, "winner": 0}, {"human": 4, "cpu": 4, "winner": 0}]:
		score.reset_match()
		score.set_survivors(case["human"], case["cpu"])
		score._determine_winner()
		_check(score.get_winner_id() == case["winner"],
			"survivor-count winner/tie decision")
	score.reset_match()
	score.set_survivors(5, 9)
	score._calculate_round_score()
	_check(score.get_round_score(0) == 5, "solo score excludes legacy draw/hint bonuses")
	score.reset_match()
	_game_state.set("solo_vs_cpu", prev_solo)
	print(PREFIX + "SURVIVOR_SCORING_OK")


func _test_phase_timer() -> void:
	var timer := root.get_node_or_null("MatchTimer")
	if timer == null:
		_check(false, "match timer autoload exists")
		return
	timer.stop()
	timer.start_seconds(0.7)
	_check(timer.is_running(), "raw second timer started")
	await create_timer(0.12).timeout
	timer.pause()
	var before: float = timer.get("_remaining_seconds")
	await create_timer(0.16).timeout
	var during: float = timer.get("_remaining_seconds")
	_check(absf(during - before) < 0.025, "paused timer cannot count down")
	timer.resume()
	await create_timer(0.75).timeout
	_check(not timer.is_running(), "timer stops at zero rather than running negative")
	timer.stop()
	print(PREFIX + "PHASE_TIMER_OK")
