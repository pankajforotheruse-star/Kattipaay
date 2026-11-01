extends SceneTree
## Instrumented 3D CPU generation benchmark. Never fake placements to satisfy quotas.
## Godot 4.4 headless; metrics are diagnostic, balance is not asserted as proven.
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var ok := true
	ProjectSettings.set_setting("chalk_gaon/solo_drawing_seconds", 6.0)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_max_seconds", 0.2)
	ProjectSettings.set_setting("chalk_gaon/solo_search_phase_seconds", 0.2)
	for difficulty in range(4):
		var state := root.get_node_or_null("GameState")
		if state != null:
			state.set("cpu_difficulty", difficulty)
		var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
		if scene == null:
			push_error("Balance benchmark scene load failed")
			quit(1)
			return
		var game := scene.instantiate()
		root.add_child(game)
		await process_frame
		var target: int = game.cpu_target
		var range_min: int = [50, 65, 85, 110][difficulty]
		var range_max: int = [100, 120, 150, 180][difficulty]
		if target < range_min or target > range_max:
			push_error("Difficulty %d target %d out of range" % [difficulty, target])
			ok = false
		var start_pos: Vector3 = game.cpu_body.global_position
		if not (game.cpu_speed > 0.0 and game.cpu_inspection_radius > 0.0 and game.cpu_strike_delay > 0.0):
			push_error("Difficulty %d has invalid physical search profile" % difficulty)
			ok = false
		await create_timer(5.0).timeout
		var travelled: float = game.cpu_body.global_position.distance_to(start_pos)
		var made: int = game.drawn_cpu_count
		var expected_by_elapsed := float(target) * 5.0 / 6.0
		print("CPU_BALANCE_3D difficulty=%d target=%d actual=%d expected_by_elapsed=%.1f reach_rate=%.3f displacement_m=%.2f" % [difficulty, target, made, expected_by_elapsed, float(made) / float(maxi(target, 1)), travelled])
		if travelled < 1.0:
			push_error("Difficulty %d: physical CPU did not meaningfully move" % difficulty)
			ok = false
		if made <= 0:
			push_error("Difficulty %d: CPU drew no physical lines" % difficulty)
			ok = false
		game.queue_free()
		await process_frame
	if ok:
		print("CHALK_GAON_3D_BALANCE_DIAGNOSTIC: PASS (not a win-rate certification)")
		quit(0)
	else:
		quit(1)
