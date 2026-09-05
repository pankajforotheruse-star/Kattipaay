extends SceneTree

enum TopState { SPLASH, MAIN_MENU, LOBBY, PLAYING, PAUSED, GAME_OVER }
enum MatchState { NONE, WAITING, LOBBY, TEAM_SELECTION, DRAWING, SEARCHING, REVEAL, SCORING, WINNER, SWAP_TEAMS, RETURN_TO_LOBBY, PAUSED }

const MAIN_SCENE := "res://scenes/main.tscn"
const MAX_STARTUP_SECONDS := 10.0
const MAX_PLAYING_SECONDS := 8.0
const MAX_DRAWING_SECONDS := 25.0
const MAX_ROUND_END_SECONDS := 25.0
const FRAME_SETTLE_COUNT := 2

var _failed := false
var _game_state: Node = null
var _event_bus: Node = null
var _seen_match_states: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run_test")

func _run_test() -> void:
	print("KATTIPAAY_SMOKE: START")
	if change_scene_to_file(MAIN_SCENE) != OK:
		_fail("Unable to load main scene")
		quit(1)
		return
	_game_state = root.get_node_or_null("GameState")
	_event_bus = root.get_node_or_null("EventBus")
	if _game_state == null:
		_fail("GameState autoload was not initialized")
		quit(1)
		return
	if _event_bus == null:
		_fail("EventBus autoload was not initialized")
		quit(1)
		return
	_event_bus.call("on", "match.state_changed", Callable(self, "_on_match_state_changed"))
	await _wait_for_top_state(TopState.MAIN_MENU, MAX_STARTUP_SECONDS, "MAIN_MENU")
	if _failed: quit(1); return
	await _wait_for_scene("HomeScreen", 3.0)
	if _failed: quit(1); return
	var home: Node = current_scene
	print("KATTIPAAY_SMOKE: HOME_READY")
	var play_cpu := home.get_node_or_null("%PlayVsCPUButton") as Button
	if play_cpu == null:
		_fail("PlayVsCPUButton not found on HomeScreen")
		quit(1)
		return
	play_cpu.pressed.emit()
	await _settle_frames()
	var picker := home.get_node_or_null("DifficultyPicker")
	if picker == null:
		_fail("DifficultyPicker was not created by Play vs CPU")
		quit(1)
		return
	var easy_button := _find_button_with_text(picker, "EASY")
	if easy_button == null:
		_fail("EASY difficulty button not found")
		quit(1)
		return
	easy_button.pressed.emit()
	print("KATTIPAAY_SMOKE: PLAY_VS_CPU_SELECTED difficulty=EASY")
	await _wait_for_top_state(TopState.PLAYING, MAX_PLAYING_SECONDS, "PLAYING")
	if _failed: quit(1); return
	await _wait_for_scene("GameWorld", 5.0)
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: GAME_WORLD_ENTERED")
	var world: Node = current_scene
	var entity_registry: Dictionary = world.get("entity_registry")
	if entity_registry.size() < 2:
		_fail("Playable world has fewer than 2 registered entities")
		quit(1)
		return
	if world.get_node_or_null("SoloMatchDriver") == null:
		_fail("SoloMatchDriver was not spawned")
		quit(1)
		return
	var ghost_bot := world.get_node_or_null("SoloMatchDriver/GhostBot")
	if ghost_bot == null:
		_fail("GhostBot was not spawned by SoloMatchDriver")
		quit(1)
		return
	ghost_bot.set_process(false)
	await _wait_for_match_state(MatchState.DRAWING, MAX_DRAWING_SECONDS, "DRAWING")
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: DRAWING_REACHED")
	await _wait_for_match_state(MatchState.SEARCHING, MAX_DRAWING_SECONDS, "SEARCHING")
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: SEARCHING_REACHED")
	var hud: Node = world.get_node_or_null("HUD")
	if hud == null:
		_fail("HUD not found in GameWorld")
		quit(1)
		return
	hud.call("set_selected_target", 2)
	var accuse_button := hud.get_node_or_null("ArgumentButton") as Button
	if accuse_button == null:
		_fail("HUD ACCUSE button was not created")
		quit(1)
		return
	await _settle_frames()
	if _get_match_state() != MatchState.SEARCHING:
		_fail("Match left SEARCHING before ACCUSE action could be exercised")
		quit(1)
		return
	if not accuse_button.visible:
		_fail("HUD ACCUSE button is not visible during SEARCHING")
		quit(1)
		return
	accuse_button.pressed.emit()
	print("KATTIPAAY_SMOKE: HUMAN_TARGET_SELECTED target=2")
	print("KATTIPAAY_SMOKE: HUMAN_ACCUSE_PRESSED")
	ghost_bot.set_process(true)
	await _wait_for_seen_match_state(MatchState.REVEAL, MAX_ROUND_END_SECONDS, "REVEAL")
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: REVEAL_REACHED")
	await _wait_for_seen_match_state(MatchState.SCORING, 5.0, "SCORING")
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: SCORING_REACHED")
	await _wait_for_seen_match_state(MatchState.RETURN_TO_LOBBY, 5.0, "RETURN_TO_LOBBY")
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: RETURN_TO_LOBBY_REACHED")
	await _wait_for_top_state(TopState.MAIN_MENU, 8.0, "MAIN_MENU_AFTER_MATCH")
	if _failed: quit(1); return
	await _wait_for_scene("HomeScreen", 3.0)
	if _failed: quit(1); return
	print("KATTIPAAY_SMOKE: PASS")
	quit(0)

func _get_top_state() -> int:
	return int(_game_state.get("current"))

func _get_match_state() -> int:
	return int(_game_state.call("get_match_state"))

func _wait_for_top_state(expected: int, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while _get_top_state() != expected and Time.get_ticks_msec() < deadline:
		await process_frame
	if _get_top_state() != expected:
		_fail("Timed out waiting for top-level state %s (current=%d)" % [label, _get_top_state()])

func _wait_for_match_state(expected: int, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while _get_match_state() != expected and Time.get_ticks_msec() < deadline:
		await process_frame
	if _get_match_state() != expected:
		_fail("Timed out waiting for match state %s (current=%d)" % [label, _get_match_state()])

func _wait_for_seen_match_state(expected: int, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not _seen_match_states.has(expected) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _seen_match_states.has(expected):
		_fail("Timed out waiting to observe match state %s" % label)

func _wait_for_scene(expected_name: String, timeout_seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while (current_scene == null or current_scene.name != expected_name) and Time.get_ticks_msec() < deadline:
		await process_frame
	if current_scene == null or current_scene.name != expected_name:
		_fail("Timed out waiting for scene %s (current=%s)" % [expected_name, current_scene.name if current_scene else "null"])

func _on_match_state_changed(payload) -> void:
	var to_state: int = int(payload.get("to", -1))
	if to_state >= 0:
		_seen_match_states[to_state] = true

func _settle_frames() -> void:
	for _i in range(FRAME_SETTLE_COUNT):
		await process_frame

func _find_button_with_text(root: Node, wanted: String) -> Button:
	if root is Button and (root as Button).text == wanted:
		return root as Button
	for child in root.get_children():
		var found := _find_button_with_text(child, wanted)
		if found != null:
			return found
	return null

func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("KATTIPAAY_SMOKE: FAIL — %s" % message)
	print("KATTIPAAY_SMOKE: FAIL — %s" % message)
