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
	_test_fair_cover_rules()
	_test_chalk_roundtrip()
	# CPU path + perception are tested with real controllers in the smoke test.
	_test_scoring_decisions()
	_test_phase_timer()
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


## Property tests for mirrored sites, shadow radius and active inspection.
## Both searchers use this SAME pure predicate regardless of CPU difficulty.
func _test_fair_cover_rules() -> void:
	var player_sites := HidingRules.get_cover_sites(false)
	var cpu_sites := HidingRules.get_cover_sites(true)
	_check(player_sites.size() == 6 and cpu_sites.size() == 6,
		"equal public cover objects in each territory")
	for i in range(player_sites.size()):
		var h: Dictionary = player_sites[i]
		var c: Dictionary = cpu_sites[i]
		var hr: Rect2 = h["rect"]
		var cr: Rect2 = c["rect"]
		_check(int(h["kind"]) == int(c["kind"]) and hr.size == cr.size,
			"cover kind and dimensions identical on both sides")
		_check(cr.position == hr.position + Vector2(0, ZoneLayout.CPU_ZONE.position.y),
			"CPU cover exactly mirrors human cover")
	for cpu_zone in [false, true]:
		for site in HidingRules.get_cover_sites(cpu_zone):
			var kind := int(site["kind"])
			var region: Rect2 = site["rect"]
			var inside: Array[Vector2] = [
				region.get_center() - Vector2(12, 0),
				region.get_center() + Vector2(12, 0)]
			var at: Vector2 = region.get_center()
			if HidingRules.is_inspectable_cover(kind):
				_check(not HidingRules.can_reveal_line(inside, at, false),
					"covered mark invisible to uninspected searcher")
				var inspected := {str(site["id"]): true}
				_check(HidingRules.can_reveal_line(inside, at, false, inspected),
					"inspection reveals nearby covered mark")
				_check(not HidingRules.can_reveal_line(inside,
					at + Vector2(0, 300), false, inspected),
					"inspection never reveals faraway mark")
			elif kind == HidingRules.COVER_TREE:
				_check(HidingRules.can_reveal_line(inside, at + Vector2(0, 80), false),
					"tree shade discoverable at close range")
				_check(not HidingRules.can_reveal_line(inside, at + Vector2(0, 240), false),
					"tree shadow genuinely reduces long-distance visibility")
	var first_leaf: Dictionary = player_sites[2]
	var leaf_rect: Rect2 = first_leaf["rect"]
	var leaf_line: Array[Vector2] = [leaf_rect.get_center() - Vector2(10, 0),
		leaf_rect.get_center() + Vector2(10, 0)]
	var inspected := {str(first_leaf["id"]): true}
	for level in range(4):
		_game_state.set("cpu_difficulty", level)
		_check(not HidingRules.can_reveal_line(leaf_line, leaf_rect.get_center(), false),
			"difficulty cannot bypass inspection")
		_check(HidingRules.can_reveal_line(
			leaf_line, leaf_rect.get_center(), false, inspected),
			"difficulty cannot change inspected reveal radius")
	print(PREFIX + "FAIR_COVER_SYMMETRY_OK")


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
	_check(ChalkLine.is_valid_network_payload(packet), "valid encoded chalk packet passes bounded parser")
	var malformed: Array[Dictionary] = [
		{},
		{"pc": 1000000000, "pd": PackedByteArray(), "wd": PackedByteArray()},
		{"pc": -1, "pd": PackedByteArray(), "wd": PackedByteArray()},
		{"pc": 2, "pd": PackedByteArray([1, 2]), "wd": PackedByteArray()},
		{"pc": 2, "pd": PackedByteArray([0,0,0,0,0,0,0,0]), "wd": "not bytes"},
	]
	for sample in malformed:
		_check(not ChalkLine.is_valid_network_payload(sample),
			"malformed/unbounded network packet fails closed")
		var rejected := ChalkLine.new()
		rejected.from_network_dict(sample)
		_check(rejected.points.is_empty() and rejected.id == -1,
			"malformed packet cannot construct a live mark")
	var bad_type: Dictionary = packet.duplicate(true)
	bad_type["ct"] = 999
	_check(not ChalkLine.is_valid_network_payload(bad_type),
		"invalid chalk enum cannot index decay table")
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
	timer._process(0.12)
	timer.pause()
	var before: float = timer.get("_remaining_seconds")
	timer._process(0.16)
	var during: float = timer.get("_remaining_seconds")
	_check(absf(during - before) < 0.025, "paused timer cannot count down")
	timer.resume()
	timer._process(1.2) # raw durations are clamped to >= 1s
	_check(not timer.is_running(), "timer stops at zero rather than running negative")
	timer.stop()
	print(PREFIX + "PHASE_TIMER_OK")
