# KattipaayPlayableSmokeTest.gd
#
# End-to-end headless smoke test for the real prototype path:
#   Splash -> Home -> Play vs CPU -> Easy -> GameWorld
#   -> DRAWING -> SEARCHING -> human ACCUSE -> REVEAL -> SCORING
#   -> RETURN_TO_LOBBY -> MAIN_MENU/Home.
#
# The test deliberately uses the game's public UI signals and public system
# APIs rather than directly forcing GameState enum values. This keeps the
# test useful as a regression check for the playable wiring.

extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const MAX_STARTUP_SECONDS := 10.0
const MAX_PLAYING_SECONDS := 8.0
const MAX_DRAWING_SECONDS := 25.0
const MAX_SEARCHING_SECONDS := 25.0
const MAX_ROUND_END_SECONDS := 25.0
const FRAME_SETTLE_COUNT := 2

var _failed := false

func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	print("KATTIPAAY_SMOKE: START")

	if change_scene_to_file(MAIN_SCENE) != OK:
		_fail("Unable to load main scene")
		quit(1)
		return

	await _wait_for_top_state(GameState.State.MAIN_MENU, MAX_STARTUP_SECONDS, "MAIN_MENU")
	if _failed:
		quit(1)
		return

	var home := current_scene as HomeScreen
	if home == null:
		_fail("Expected HomeScreen, got %s" % [current_scene.get_class() if current_scene else "null"])
		quit(1)
		return
	print("KATTIPAAY_SMOKE: HOME_READY")

	# Exercise the actual Play vs CPU button and generated difficulty picker.
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

	await _wait_for_top_state(GameState.State.PLAYING, MAX_PLAYING_SECONDS, "PLAYING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: GAME_WORLD_ENTERED")

	var world := current_scene as GameWorld
	if world == null:
		_fail("Expected GameWorld in PLAYING state")
		quit(1)
		return

	if world.entity_registry.size() < 2:
		_fail("Playable world has fewer than 2 registered entities")
		quit(1)
		return
	if world.get_node_or_null("SoloMatchDriver") == null:
		_fail("SoloMatchDriver was not spawned")
		quit(1)
		return
	if world.get_node_or_null("SoloMatchDriver/GhostBot") == null:
		_fail("GhostBot was not spawned by SoloMatchDriver")
		quit(1)
		return

	await _wait_for_match_state(GameState.MatchState.DRAWING, MAX_DRAWING_SECONDS, "DRAWING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: DRAWING_REACHED")

	await _wait_for_match_state(GameState.MatchState.SEARCHING, MAX_DRAWING_SECONDS, "SEARCHING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SEARCHING_REACHED")

	# The SoloMatchDriver selects ghost entity 2 after HUD resets its target on
	# SEARCHING entry. Press the real HUD ACCUSE button to exercise the public
	# gameplay action, not a direct state transition.
	var hud := world.get_node_or_null("HUD") as HUD
	if hud == null:
		_fail("HUD not found in GameWorld")
		quit(1)
		return

	var accuse_button := hud.get_node_or_null("ArgumentButton") as Button
	if accuse_button == null:
		_fail("HUD ACCUSE button was not created")
		quit(1)
		return

	await _settle_frames()
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		_fail("Match left SEARCHING before ACCUSE action could be exercised")
		quit(1)
		return
	if not accuse_button.visible:
		_fail("HUD ACCUSE button is not visible during SEARCHING")
		quit(1)
		return

	accuse_button.pressed.emit()
	print("KATTIPAAY_SMOKE: HUMAN_ACCUSE_PRESSED")

	# A real accusation pauses the match for the ArgumentSystem's resolution.
	# The bot supplies the second accusation needed by SoloMatchDriver's round
	# end condition; we therefore wait for the actual end-state sequence rather
	# than forcing it.
	await _wait_for_match_state(GameState.MatchState.REVEAL, MAX_ROUND_END_SECONDS, "REVEAL")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: REVEAL_REACHED")

	await _wait_for_match_state(GameState.MatchState.SCORING, 5.0, "SCORING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SCORING_REACHED")

	await _wait_for_match_state(GameState.MatchState.RETURN_TO_LOBBY, 5.0, "RETURN_TO_LOBBY")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: RETURN_TO_LOBBY_REACHED")

	await _wait_for_top_state(GameState.State.MAIN_MENU, 8.0, "MAIN_MENU_AFTER_MATCH")
	if _failed:
		quit(1)
		return

	if not (current_scene is HomeScreen):
		_fail("Expected HomeScreen after completed solo match")
		quit(1)
		return

	print("KATTIPAAY_SMOKE: PASS")
	quit(0)


func _wait_for_top_state(expected: int, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while GameState.current != expected and Time.get_ticks_msec() < deadline:
		await process_frame
	if GameState.current != expected:
		_fail("Timed out waiting for top-level state %s (current=%s)" % [label, GameState.State.keys()[GameState.current]])


func _wait_for_match_state(expected: int, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while GameState.get_match_state() != expected and Time.get_ticks_msec() < deadline:
		await process_frame
	if GameState.get_match_state() != expected:
		var current_name := GameState.MatchState.keys()[GameState.get_match_state()]
		_fail("Timed out waiting for match state %s (current=%s)" % [label, current_name])


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
