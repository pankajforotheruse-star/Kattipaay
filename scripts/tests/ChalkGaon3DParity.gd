extends SceneTree
## Godot 4.4 headless parity assertions for the 3D round's critical rules.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	ProjectSettings.set_setting("chalk_gaon/solo_drawing_seconds", 40.0)
	ProjectSettings.set_setting("chalk_gaon/solo_cheating_enabled", false)
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if packed == null:
		push_error("3D parity: scene missing")
		quit(1)
		return
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	_assert(game.phase == "DRAWING", "Draw phase starts")
	_assert(not game.cheating_enabled, "Cheating is disabled by default")
	for i in range(120):
		var mark := ChalkStroke3D.new()
		mark.owner_id = 1
		mark.stroke_id = i + 1
		root.add_child(mark)
		game._human_stroke_created(mark)
	_assert(game.saved_human_lines.size() == 120, "Human mark registry has no fixed 50-line quota")
	for i in range(110):
		game.saved_human_lines[i].struck = true
	for i in range(8):
		var bot_mark := ChalkStroke3D.new()
		bot_mark.owner_id = 2
		bot_mark.stroke_id = 1001 + i
		root.add_child(bot_mark)
		game.cpu_lines.append(bot_mark)
	game._finish_match()
	_assert(game.result.begins_with("HUMAN WINS"), "Survivor scoring 10 versus 8")
	_assert(game.result.contains("Human 10 : CPU 8"), "Survivor scoring counts actual unstruck marks")
	game.cpu_lines[0].struck = true
	game._finish_match()
	_assert(game.result.contains("Human 10 : CPU 7"), "Struck CPU mark no longer scores")
	game.rng.seed = 20261102
	var first_human := 0
	var first_cpu := 0
	for i in range(100):
		game.phase = "MEETING"
		game.coin_call = 0
		game._advance_phase()
		if game.coin_face == 0:
			_assert(game.first_searcher == 1, "Heads call human wins when heads")
			first_human += 1
		else:
			_assert(game.first_searcher == 2, "Heads call CPU wins when tails")
			first_cpu += 1
	_assert(first_human > 30 and first_cpu > 30, "Coin decision exercises both outcomes under fixed seed")
	if failures.is_empty():
		print("CHALK_GAON_3D_PARITY: PASS (scoring/coin/quota/cheating)")
		quit(0)
	else:
		for failure in failures:
			push_error("3D_PARITY: " + failure)
		quit(1)
func _assert(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
