extends SceneTree
## Godot 4.4 development 3D round state smoke. No graphical claims.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var p := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	_check(p != null, "3D match scene resource")
	if p == null:
		quit(1)
		return
	var game := p.instantiate()
	root.add_child(game)
	await process_frame
	_check(game.get_node_or_null("GrayboxExplorer") is CharacterBody3D, "Human physical controller")
	_check(game.get_node_or_null("GhostOpponent3D") is CharacterBody3D, "Physical CPU character")
	_check(game.get_node_or_null("DrawController3D") is DrawController3D, "3D raycasting drawer")
	_check(game.phase == "DRAWING", "Drawing phase starts")
	await process_frame
	_check(game.cpu_nav.built, "CPU ground navigation built")
	game._attempt_cpu_draw()
	_check(game.drawn_cpu_count > 0, "CPU physically places 3D chalk on a village surface")
	game._advance_phase()
	_check(game.phase == "MEETING", "Meeting after drawing")
	game._advance_phase()
	_check(game.phase == "SEARCHING" and game.search_number == 1, "First search")
	var first: int = game.searcher
	game._advance_phase()
	_check(game.phase == "SEARCHING" and game.search_number == 2 and game.searcher != first, "Opposite searcher")
	game._advance_phase()
	_check(game.phase == "RESULT", "Match reaches results")
	_check(not game.result.is_empty(), "Survivor scoring resolves")
	if failures.is_empty():
		print("CHALK_GAON_3D_ROUND: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("3D round: " + failure)
		quit(1)
func _check(ok: bool, description: String) -> void:
	if not ok:
		failures.append(description)
