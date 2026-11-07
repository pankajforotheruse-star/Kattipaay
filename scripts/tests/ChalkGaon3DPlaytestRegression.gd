extends SceneTree
## Regression for the actual user-reported 3D playtest failures.
var problems: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if scene == null:
		push_error("3D interaction scene missing")
		quit(1)
		return
	var game := scene.instantiate()
	root.add_child(game)
	await physics_frame
	_check(game.draw_controller.draw_range >= 8.0, "Freehand draw reach supports nearby walls and rooftops")
	_check(game.draw_controller.point_spacing <= 0.1, "Freehand drag uses dense samples")
	_check(game.coin_panel != null and not game.coin_panel.visible, "Coin overlay starts hidden")
	_check(game.walker.get_node_or_null("HumanAvatar") != null, "Player uses humanoid rig")
	_check(game.cpu_body.get_node_or_null("CpuAvatar") != null, "CPU uses humanoid rig")
	var earth: CollisionObject3D
	for surface in game.get_tree().get_nodes_in_group("graybox_surfaces"):
		if surface is CollisionObject3D and surface.name.begins_with("Earth"):
			earth = surface
			break
	_check(earth != null, "Village ground is a physical drawing surface")
	if earth != null:
		var chalk := ChalkStroke3D.new()
		chalk.owner_id = 1
		earth.add_child(chalk)
		chalk.add_surface_point(Vector3(-3.5, -0.09, -1.0), Vector3.UP)
		chalk.add_surface_point(Vector3(-3.2, -0.09, -1.0), Vector3.UP)
		game.saved_human_lines.append(chalk)
		game.phase = "SEARCHING"
		game.searcher = 2
		game.cpu_body.global_position = Vector3(-3.5, 0.85, 0)
		game.cpu_inspection_radius = 4.0
		game.cpu_strike_cooldown = 0.0
		await physics_frame
		game._cpu_inspect()
		_check(chalk.struck, "CPU physically detects and strikes nearby visible human chalk")
	game._finish_match()
	var locked_result: String = game.result
	var saved_once: bool = game.last_result_saved
	game._finish_match()
	_check(game.result == locked_result and game.last_result_saved == saved_once, "Repeated result finalization is idempotent")
	game._advance_phase()
	_check(game.phase == "RESULT", "No phase transition after terminal result")
	var forbidden := ChalkStroke3D.new()
	game.add_child(forbidden)
	game._human_stroke_created(forbidden)
	_check(forbidden.struck and not game.saved_human_lines.has(forbidden), "No human drawing accepted after result")
	_check(game.phase == "RESULT", "Winner transition reaches result state")
	_check(game.result_panel != null and game.result_panel.visible, "Visible non-dimming winner banner is shown")
	_check(game.result_hold_left >= 3.0, "Result holds visibly before returning to menu")
	var initial: Vector3 = game.walker.global_position
	game._physics_process(0.1)
	_check(game.walker.global_position.distance_to(initial) < 0.001, "No player movement after match is finished")
	if problems.is_empty():
		print("CHALK_GAON_3D_PLAYTEST_REGRESSION: PASS")
		quit(0)
	else:
		for problem in problems:
			push_error("3D_PLAYTEST: " + problem)
		quit(1)
func _check(ok: bool, description: String) -> void:
	if not ok:
		problems.append(description)
