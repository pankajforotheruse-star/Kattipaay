extends SceneTree
## Automated clock-driven end-to-end 3D development round. Godot 4.4 only.
## This is NOT a manual playtest or proof of CPU competitiveness.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	ProjectSettings.set_setting("chalk_gaon/solo_drawing_seconds", 0.25)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_max_seconds", 0.25)
	ProjectSettings.set_setting("chalk_gaon/solo_search_phase_seconds", 0.25)
	ProjectSettings.set_setting("chalk_gaon/solo_cheating_enabled", false)
	var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if scene == null:
		push_error("3D round scene missing")
		quit(1)
		return
	var game := scene.instantiate()
	root.add_child(game)
	await process_frame
	_check(game.phase == "DRAWING", "Draw phase started")
	_check(game.cpu_target >= 50 and game.cpu_target <= 180, "Random CPU mark target uses owner range")
	_check(not game.cheating_enabled, "Cheating disabled by default")
	await create_timer(1.8).timeout
	_check(game.phase == "RESULT", "Clock-driven draw, meeting and dual search reached result")
	_check(not game.result.is_empty(), "Survivor winner or draw resolved")
	_check(game.search_number == 2, "Both search phases executed")
	_check(game.get_node_or_null("GhostOpponent3D") is CharacterBody3D, "Physical CPU exists in actual round")
	if failures.is_empty():
		print("CHALK_GAON_3D_E2E: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("3D E2E: " + failure)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
