extends SceneTree
## Complete clock-driven 3D match batch with a deterministic *scripted*
## human opponent. Actual CPU drawing, navigation, perception and scoring run.
## NOT a human playtest; full mode uses 40s draw + 15s meet + 2x30s search.
## Godot --fixed-fps 60 runs fixed-delta simulations without realtime pacing.
var failures: Array[String] = []
var match_records: Array[Dictionary] = []
var match_count := 1
var selected_difficulty := 0
var fast_smoke := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--rounds="):
			match_count = clampi(int(argument.trim_prefix("--rounds=")), 1, 500)
		elif argument.begins_with("--difficulty="):
			selected_difficulty = clampi(int(argument.trim_prefix("--difficulty=")), 0, 3)
		elif argument == "--fast":
			fast_smoke = true
	var draw_seconds := 3.0 if fast_smoke else 40.0
	var meeting_seconds := 0.4 if fast_smoke else 15.0
	var search_seconds := 2.0 if fast_smoke else 30.0
	ProjectSettings.set_setting("chalk_gaon/solo_drawing_seconds", draw_seconds)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_max_seconds", meeting_seconds)
	ProjectSettings.set_setting("chalk_gaon/solo_search_phase_seconds", search_seconds)
	ProjectSettings.set_setting("chalk_gaon/solo_winner_hold_seconds", 0.5)
	ProjectSettings.set_setting("chalk_gaon/solo_cheating_enabled", false)
	ProjectSettings.set_setting("chalk_gaon/3d_benchmark_no_decor", true)
	ProjectSettings.set_setting("chalk_gaon/3d_session_kind", "scripted_benchmark")
	var state := root.get_node_or_null("GameState")
	if state == null:
		push_error("Scripted benchmark missing GameState autoload")
		quit(1)
		return
	for match_index in range(match_count):
		state.set("cpu_difficulty", selected_difficulty)
		var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
		var game := scene.instantiate()
		root.add_child(game)
		game.result_scene_exit_enabled = false
		await physics_frame
		await process_frame
		var seed := 290001 + selected_difficulty * 10000 + match_index
		game.rng.seed = seed
		game.match_seed = seed
		var range_min: int = [50, 65, 85, 110][selected_difficulty]
		var range_max: int = [100, 120, 150, 180][selected_difficulty]
		game.cpu_target = game.rng.randi_range(range_min, range_max)
		game.cpu_draw_interval = draw_seconds / float(game.cpu_target)
		var frame := 0
		var last_mark_frame := -100
		var last_strike_frame := -100
		var scripted_marks := 0
		var profile := match_index % 3
		var mark_interval: int = int([72, 52, 36][profile]) if not fast_smoke else 24
		var frame_limit := int((draw_seconds + meeting_seconds + search_seconds * 2.0 + 5.0) * 60.0)
		while game.phase != "RESULT" and frame < frame_limit:
			frame += 1
			if game.phase == "DRAWING":
				game.mobile_move = _movement(frame, profile)
				if frame - last_mark_frame >= mark_interval:
					last_mark_frame = frame
					if _scripted_surface_mark(game, scripted_marks):
						scripted_marks += 1
			elif game.phase == "MEETING":
				game.mobile_move = Vector2.ZERO
				game.coin_call = 0
			elif game.phase == "SEARCHING":
				if game.searcher == 1:
					game.mobile_move = _movement(frame + 120, profile)
					if frame - last_strike_frame >= 15:
						game.find_interact_requested = true
						last_strike_frame = frame
				else:
					game.mobile_move = Vector2.ZERO
			await process_frame
		game.mobile_move = Vector2.ZERO
		if game.phase != "RESULT":
			failures.append("Difficulty %d match %d timed out in phase %s" % [selected_difficulty, match_index, game.phase])
		else:
			var metrics: Dictionary = game.acceptance_metrics()
			match_records.append({
				"schema": "chalk_gaon_3d_match_v1",
				"session_kind": "scripted_benchmark",
				"difficulty": selected_difficulty,
				"result": game.result,
				"cpu_inspections": metrics["cpu_strikes_and_inspections"],
				"cpu_search_cells": metrics["cpu_search_cells"],
				"human_marks": metrics["human_marks"],
				"cpu_marks": metrics["cpu_marks"],
				"cpu_roof_visits": metrics["cpu_roof_visits"],
				"human_survivors": metrics["human_survivors"],
				"cpu_survivors": metrics["cpu_survivors"],
				"seed": seed,
				"profile": profile
			})
		game.queue_free()
		await process_frame
		if (match_index + 1) % 10 == 0 or match_index + 1 == match_count:
			print("SCRIPTED_3D_PROGRESS difficulty=%d completed=%d/%d" % [selected_difficulty, match_index + 1, match_count])
	var summary := MatchAnalytics3D.analyze(match_records, selected_difficulty, "scripted_benchmark")
	var report := FileAccess.open("user://chalk_gaon_3d_scripted_balance_%d.json" % selected_difficulty, FileAccess.WRITE)
	if report != null:
		report.store_string(JSON.stringify({
			"study": "scripted_physical_3d_matches_not_human_playtests",
			"full_clock": not fast_smoke, "summary": summary, "matches": match_records
		}, "  "))
		report.close()
	print("SCRIPTED_3D_BALANCE difficulty=%d matches=%d human_wins=%d cpu_wins=%d draws=%d mean_search_cells=%.2f mean_cpu_inspections=%.2f" % [
		selected_difficulty, summary["matches"], summary["human_wins"],
		summary["cpu_wins"], summary["draws"], summary["mean_cpu_search_cells"],
		summary["mean_cpu_inspections"]])
	if failures.is_empty() and int(summary["matches"]) == match_count:
		print("CHALK_GAON_3D_SCRIPTED_MATCH_BATCH: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("SCRIPTED_3D_MATCH: " + failure)
		quit(1)

func _movement(frame: int, profile: int) -> Vector2:
	var segment: int = (frame / int([105, 75, 55][profile])) % 4
	match segment:
		0: return Vector2(0.6, 0.65)
		1: return Vector2(-0.8, 0.25)
		2: return Vector2(0.2, -0.8)
		_: return Vector2(0.9, -0.25)

func _scripted_surface_mark(game: Node3D, mark_index: int) -> bool:
	var eye: Vector3 = game.walker.global_position + Vector3(0, 1.45, 0)
	var offset := Vector3(0.35 + float(mark_index % 3) * 0.25, -2.3, -1.1)
	var query := PhysicsRayQueryParameters3D.create(eye, eye + offset)
	query.exclude = [game.walker.get_rid()]
	var hit := game.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var surface := hit.get("collider") as CollisionObject3D
	if surface == null or not surface.is_in_group("graybox_surfaces"):
		return false
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	if not Territory3D.can_draw(1, point) or eye.distance_to(point) > 8.5:
		return false
	var second_origin := point + Vector3(0.34, 0.0, 0.0) + normal * 0.35
	var second_query := PhysicsRayQueryParameters3D.create(second_origin, second_origin - normal * 0.7)
	var second_hit := game.get_world_3d().direct_space_state.intersect_ray(second_query)
	if second_hit.is_empty() or second_hit.get("collider") != surface:
		return false
	var stroke := ChalkStroke3D.new()
	stroke.stroke_id = 500000 + mark_index
	stroke.surface_id = str(surface.get_path())
	surface.add_child(stroke)
	stroke.add_surface_point(point, normal)
	stroke.add_surface_point(second_hit["position"], second_hit["normal"])
	game._human_stroke_created(stroke)
	return true
