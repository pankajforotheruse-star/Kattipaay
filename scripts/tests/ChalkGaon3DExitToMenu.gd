extends SceneTree
## Regression: leaving a 3D match must land on the village menu.
##
## The owner's gray screen came from GameWorld3D calling
## change_scene_to_file("res://scenes/main.tscn") while GameState was still
## MAIN_MENU: Bootstrap only routed on SPLASH, so the tree was left holding a
## bare Node with no UI. This drives both exits a player can take — the RESULT
## hold expiring and PAUSE -> "EXIT TO MAIN MENU" — and asserts each one ends on
## a HomeScreen with visible Controls.
##
## Run: godot --headless --path . --script res://scripts/tests/ChalkGaon3DExitToMenu.gd
const HOME_SCENE := "res://scenes/menu/home.tscn"
const WORLD_3D_SCENE := "res://scenes/3d/game_world_3d.tscn"

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	await _case_result_hold_exit()
	await _case_pause_exit()
	if failures.is_empty():
		print("CHALK_GAON_3D_EXIT: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("3D exit: " + failure)
		print("CHALK_GAON_3D_EXIT: FAIL")
		quit(1)

func _case_result_hold_exit() -> void:
	await _ensure_village_menu()
	_check(_is_home(current_scene), "village menu is the current scene before launching 3D")
	await _launch_3d()
	var game := current_scene
	_check(_is_3d_world(game), "3D match scene is current after launching from the village menu")
	if not _is_3d_world(game):
		return
	# Drive the round to its result panel exactly as the smoke test does.
	for _step in 4:
		game._advance_phase()
	_check(game.phase == "RESULT", "3D match reaches RESULT")
	game.result_hold_left = 0.01
	await _await_village_menu()
	_check(_is_home(current_scene), "result hold exit lands on the village menu")
	_check(_gs().current == _gs().State.MAIN_MENU, "top-level state returns to MAIN_MENU after the match")
	_check(_visible_control_count(current_scene) > 0, "village menu draws visible Controls (no bare gray node)")

func _case_pause_exit() -> void:
	await _ensure_village_menu()
	await _launch_3d()
	var game := current_scene
	_check(_is_3d_world(game), "3D match scene is current after the second launch")
	if not _is_3d_world(game):
		return
	var exit_button := _find_button(game, "EXIT TO MAIN MENU")
	_check(exit_button != null, "pause menu exposes EXIT TO MAIN MENU")
	if exit_button == null:
		return
	exit_button.pressed.emit()
	await _await_village_menu()
	_check(_is_home(current_scene), "EXIT TO MAIN MENU lands on the village menu")
	_check(_visible_control_count(current_scene) > 0, "village menu draws visible Controls after EXIT")

# ── Helpers ─────────────────────────────────────────────────────────────────

## Autoload singletons cannot be resolved by name inside a --script main
## loop, so fetch GameState from the tree at runtime.
func _gs():
	return root.get_node("/root/GameState")

## Put a village menu on screen with GameState in MAIN_MENU, the way the player
## arrives there from the splash screen.
func _ensure_village_menu() -> void:
	if _is_home(current_scene):
		return
	_gs().current = _gs().State.MAIN_MENU
	var packed := load(HOME_SCENE) as PackedScene
	if packed == null:
		_check(false, "village menu scene resource loads")
		return
	var home := packed.instantiate()
	root.add_child(home)
	current_scene = home
	await process_frame

## Press the home screen's 3D launch path and wait for the scene swap.
func _launch_3d() -> void:
	var home := current_scene
	if home == null or not home.has_method("_start_3d_with_difficulty"):
		_check(false, "village menu exposes the 3D launch path")
		return
	home._start_3d_with_difficulty(1)
	for _frame in 6:
		await process_frame

## Wait for the exit path to finish (Bootstrap routes one frame after load).
func _await_village_menu() -> void:
	for _frame in 60:
		await process_frame
		if _is_home(current_scene):
			return

func _is_home(node: Node) -> bool:
	return node != null and node.scene_file_path == HOME_SCENE

func _is_3d_world(node: Node) -> bool:
	return node != null and node.scene_file_path == WORLD_3D_SCENE

func _find_button(node: Node, label: String) -> Button:
	if node is Button and node.text == label:
		return node
	for child in node.get_children():
		var found := _find_button(child, label)
		if found != null:
			return found
	return null

func _visible_control_count(node: Node) -> int:
	var count := 0
	if node is Control and node.is_visible_in_tree():
		count += 1
	for child in node.get_children():
		count += _visible_control_count(child)
	return count

func _check(ok: bool, description: String) -> void:
	if not ok:
		failures.append(description)
