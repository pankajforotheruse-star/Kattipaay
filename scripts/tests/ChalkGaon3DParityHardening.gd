extends SceneTree
## Regression of shared 2D/3D rules, fair sight, multilevel physical
## transition validation, CPU target accounting and cover overlap.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	_check(ChalkMatchRules.winner_from_survivors(5, 5) == 0, "Tie resolves as draw")
	_check(ChalkMatchRules.winner_from_survivors(6, 5) == 1, "Human survivor majority")
	_check(ChalkMatchRules.winner_from_survivors(5, 6) == 2, "CPU survivor majority")
	_check(ChalkMatchRules.first_searcher(1, 1) == 1, "Correct coin call makes human search first")
	_check(ChalkMatchRules.first_searcher(0, 1) == 2, "Wrong coin call makes CPU search first")
	_check(ChalkMatchRules.searcher_for_phase(2, 2) == 1, "Second search swaps roles")
	_check(not ChalkMatchRules.can_strike(1, 1, "SEARCHING", false), "Cannot strike own mark")
	_check(not ChalkMatchRules.can_strike(2, 1, "DRAWING", false), "No strike during drawing")
	_check(not ChalkMatchRules.can_strike(2, 1, "SEARCHING", true), "No double strike")
	_check(ChalkMatchRules.can_strike(2, 1, "SEARCHING", false), "Valid opposing strike")
	_check(ChalkMatchRules.cpu_target_range(3) == Vector2i(110, 180), "Nightmare target range")
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if packed == null:
		push_error("PARITY_HARDENING: missing 3D scene")
		quit(1)
		return
	var game := packed.instantiate()
	root.add_child(game)
	await physics_frame
	await process_frame
	await physics_frame
	_check(is_equal_approx(game.cpu_inspection_radius, ChalkMatchRules.DISCOVERY_DISTANCE_METRES), "CPU and human use identical physical sight distance")
	_check(game.cpu_multilevel.transitions.size() == 2, "CPU territory has two validated roof regions and links")
	_check(game.human_multilevel.transitions.size() == 2, "Human territory has two validated roof regions and links")
	_check(game.cpu_multilevel.rejected_transitions.is_empty(), "No CPU-side invalid transitions")
	_check(game.human_multilevel.rejected_transitions.is_empty(), "No human-side invalid transitions")
	for item in game.human_multilevel.transitions:
		_check(item["region"] is NavigationRegion3D, "Elevated region is NavigationRegion3D")
		_check(item["link"] is NavigationLink3D, "Physical ramp link is NavigationLink3D")
	var invalid: bool = game.human_multilevel._valid_transition(
		game.get_world_3d().direct_space_state,
		Vector3(-27, 0.85, 0), Vector3(-27, 14, 0))
	_check(not invalid, "Vertical inaccessible ledge cannot become a valid ramp")
	var crate: RigidBody3D
	for node in get_nodes_in_group("future_movable_props"):
		var candidate := node as RigidBody3D
		if candidate != null:
			crate = candidate
			break
	_check(crate != null, "A physical movable cover exists")
	if crate != null:
		var original := crate.global_transform
		game._toggle_cover_body(crate)
		_check(bool(crate.get_meta("cover_lifted", false)), "Cover can be lifted")
		game.walker.global_position = original.origin
		await physics_frame
		_check(not game._can_restore_cover(crate), "Full shape overlap rejects actor inside cover")
		game.walker.global_position = Vector3(-1, 0.85, 0)
		await physics_frame
		_check(game._can_restore_cover(crate), "Full shape accepts clear original position")
		game._toggle_cover_body(crate)
		_check(not bool(crate.get_meta("cover_lifted", false)), "Cover restores after clearing space")
	var metrics: Dictionary = game.acceptance_metrics()
	_check(metrics.has("cpu_draw_shortfall") and metrics.has("cpu_draw_target"), "CPU target shortfall measured")
	_check(game.cpu_target >= 50 and game.cpu_target <= 180, "CPU target respects difficulty contract")
	if failures.is_empty():
		print("CHALK_GAON_3D_PARITY_HARDENING: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("PARITY_HARDENING: " + failure)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
