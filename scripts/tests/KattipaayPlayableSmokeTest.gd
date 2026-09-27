# KattipaayPlayableSmokeTest.gd
#
# End-to-end headless smoke test for the real prototype path (slice 3, R6):
#   Splash -> Home -> Play vs CPU -> NORMAL -> GameWorld
#   -> DRAWING -> MEETING (coin auto-resolves; no human call headless)
#   -> SEARCH #1 -> zone+role swap -> SEARCH #2 -> REVEAL/SCORING/WINNER
#   -> RETURN_TO_LOBBY -> MAIN_MENU/Home.
#
# R6 change vs the pre-R6 test: the old DRAWING->MEETING->SEARCHING->ACCUSE
# flow is gone. Search now runs as TWO phases inside the SEARCHING match state
# (only who visits whose zone changes - owner decision #3), each capped by
# chalk_gaon/solo_search_phase_seconds (default 30s), then surviving hidden
# lines are counted for the winner. There is no ACCUSE button anymore: the
# searcher STRIKES ghost lines (tap -> StrikeSystem wipe), and the CPU side of
# the search is driven by CpuSearchController.
#
# Pacing: the test overrides the [chalk_gaon] ProjectSettings keys to short
# values BEFORE the match launches (SoloMatchDriver and CoinDeciderOverlay
# both read them via ProjectSettings.get_setting(..., default) in _ready), so
# the whole round runs headless in ~15-20s instead of 40s draw + 15s meeting +
# 2x30s search. solo_drawing_seconds is kept at 8.0 on purpose: the NORMAL
# GhostBot's 6s observation fallback then fires DURING DRAWING, so SEARCH #1
# has real ghost lines to count (target_lines >= 1) - the search phases are
# not empty-stubbed.
#
# Determinism: the coin toss is a real 50/50 (owner decision #2). The test
# does not need a fixed outcome - it records EV_GAME_COIN_DECIDED, then asserts
# that phase 1's searcher matches the coin, phase 2's searcher is the other
# side (zone+role swap), and that BOTH searcher values {1, 2} are exercised
# across the two phases. That is an explicit, hard proof that the CPU-first
# (active_searcher=2) branch is reachable regardless of which way the coin
# lands.
#
# The test uses the game's real UI signals and public gameplay API instead of
# directly forcing GameState enum values. GameState is fetched as the real
# autoload instance because a standalone --script is compiled before autoload
# singleton identifiers are available to the parser. It intentionally avoids
# typed references to project classes so the test script does not compile
# scene scripts before the project's autoloads exist.

extends SceneTree

enum TopState { SPLASH, MAIN_MENU, LOBBY, PLAYING, PAUSED, GAME_OVER }
enum MatchState { NONE, WAITING, LOBBY, TEAM_SELECTION, DRAWING, MEETING, SEARCHING, REVEAL, SCORING, WINNER, SWAP_TEAMS, RETURN_TO_LOBBY, PAUSED }

const MAIN_SCENE := "res://scenes/main.tscn"
const MAX_STARTUP_SECONDS := 10.0
const MAX_PLAYING_SECONDS := 6.0
# Short-paced round: draw 8s + meeting ~3.5s + 2x search (<=2s each, one may
# early-exit on empty grace 0.5s) + winner hold 1s. Generous envelopes below.
const MAX_DRAWING_SECONDS := 15.0
const MAX_MEETING_SECONDS := 10.0
const MAX_SEARCH_SECONDS := 12.0
const MAX_ROUND_END_SECONDS := 8.0
const FRAME_SETTLE_COUNT := 2

const HUMAN_ID := 1
const GHOST_ID := 2

var _failed := false
var _game_state: Node = null
var _event_bus: Node = null
var _seen_match_states: Dictionary = {}
var _coin_searcher: int = -1
var _coin_human_first: bool = false
var _seen_phases: Array = []  # {phase:int, searcher:int, target_lines:int}

func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	print("KATTIPAAY_SMOKE: START")

	# Override [chalk_gaon] pacing BEFORE the match launches. SoloMatchDriver
	# reads these in _ready (get_setting with defaults) and CoinDeciderOverlay
	# reads solo_meeting_flip_duration; the engine instance (or CI job) keeps
	# its project.godot defaults for everything else.
	ProjectSettings.set_setting("chalk_gaon/solo_drawing_seconds", 8.0)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_call_timeout_seconds", 1.0)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_max_seconds", 4.0)
	ProjectSettings.set_setting("chalk_gaon/solo_coin_result_hold_seconds", 1.0)
	ProjectSettings.set_setting("chalk_gaon/solo_meeting_flip_duration", 0.5)
	ProjectSettings.set_setting("chalk_gaon/solo_search_phase_seconds", 2.0)
	ProjectSettings.set_setting("chalk_gaon/solo_early_exit_grace_seconds", 0.5)
	ProjectSettings.set_setting("chalk_gaon/solo_empty_phase_grace_seconds", 0.5)
	ProjectSettings.set_setting("chalk_gaon/solo_winner_hold_seconds", 1.0)
	print("KATTIPAAY_SMOKE: PACING_OVERRIDES_SET drawing=8 meeting_call=1 search=2 winner_hold=1")

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
	_event_bus.call("on", "game.coin_decided", Callable(self, "_on_coin_decided"))
	_event_bus.call("on", "game.search_phase_started", Callable(self, "_on_phase_started"))

	await _wait_for_top_state(TopState.MAIN_MENU, MAX_STARTUP_SECONDS, "MAIN_MENU")
	if _failed:
		quit(1)
		return

	await _wait_for_scene("HomeScreen", 3.0)
	if _failed:
		quit(1)
		return

	var home: Node = current_scene
	print("KATTIPAAY_SMOKE: HOME_READY")

	# Exercise the actual Play vs CPU button and generated difficulty picker.
	# NORMAL is used (not EASY): EASY would randomly accuse during SEARCHING,
	# while NORMAL only accuses on guilt >= 0.75 and the headless human never
	# draws, so the bot never interrupts the two-search flow.
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

	var normal_button := _find_button_with_text(picker, "NORMAL")
	if normal_button == null:
		_fail("NORMAL difficulty button not found")
		quit(1)
		return
	normal_button.pressed.emit()
	print("KATTIPAAY_SMOKE: PLAY_VS_CPU_SELECTED difficulty=NORMAL")

	await _wait_for_top_state(TopState.PLAYING, MAX_PLAYING_SECONDS, "PLAYING")
	if _failed:
		quit(1)
		return

	await _wait_for_scene("GameWorld", 5.0)
	if _failed:
		quit(1)
		return
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

	# The GhostBot stays ENABLED: its NORMAL observation fallback places real
	# ghost lines during DRAWING (~7s into the 8s draw), which SEARCH #1 then
	# counts. Disabling it (pre-R6) would leave zero ghost lines to search.

	await _wait_for_match_state(MatchState.DRAWING, MAX_DRAWING_SECONDS, "DRAWING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: DRAWING_REACHED")

	await _wait_for_match_state(MatchState.MEETING, MAX_DRAWING_SECONDS, "MEETING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: MEETING_REACHED")

	# No human input headless: the driver auto-randomizes the coin after
	# solo_meeting_call_timeout_seconds and starts SEARCHING after the result
	# hold. Assert the coin actually landed before we leave MEETING.
	await _wait_until(func() -> bool: return _coin_searcher >= 1, MAX_MEETING_SECONDS, "COIN_DECIDED")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: COIN_DECIDED active_searcher=%d human_first=%s" % [_coin_searcher, str(_coin_human_first)])

	await _wait_for_match_state(MatchState.SEARCHING, MAX_MEETING_SECONDS, "SEARCHING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SEARCHING_REACHED")

	# Both search phases run inside SEARCHING; observe them via the phase events
	# the driver emits (EV_GAME_SEARCH_PHASE_STARTED with phase/searcher/
	# defender/target_lines).
	await _wait_until(func() -> bool: return _seen_phases.size() >= 2, MAX_SEARCH_SECONDS, "SEARCH_PHASE_2")
	if _failed:
		quit(1)
		return

	if _seen_phases.size() != 2:
		_fail("Expected exactly 2 search phases, saw %d" % _seen_phases.size())
		quit(1)
		return

	var p1: Dictionary = _seen_phases[0]
	var p2: Dictionary = _seen_phases[1]
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_1 phase=%d searcher=%d targets=%d" % [p1["phase"], p1["searcher"], p1["target_lines"]])
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_2 phase=%d searcher=%d targets=%d" % [p2["phase"], p2["searcher"], p2["target_lines"]])

	if int(p1["phase"]) != 1 or int(p2["phase"]) != 2:
		_fail("Search phases out of order: %s -> %s" % [str(p1["phase"]), str(p2["phase"])])
		quit(1)
		return
	if int(p1["searcher"]) != _coin_searcher:
		_fail("Phase-1 searcher %d does not match coin decision %d" % [int(p1["searcher"]), _coin_searcher])
		quit(1)
		return
	if int(p2["searcher"]) == int(p1["searcher"]):
		_fail("Zone+role swap did not occur: both phases have searcher %d" % int(p1["searcher"]))
		quit(1)
		return
	if int(p1["searcher"]) != HUMAN_ID and int(p2["searcher"]) != HUMAN_ID:
		_fail("Neither phase had the human as searcher")
		quit(1)
		return
	if int(p1["searcher"]) != GHOST_ID and int(p2["searcher"]) != GHOST_ID:
		_fail("Neither phase had the CPU (ghost) as searcher - CPU-first branch unreachable")
		quit(1)
		return

	# GameState.solo_active_searcher/defender mirror the active phase; after
	# phase 2 starts it must hold phase-2's values (the swap is visible).
	if int(_game_state.get("solo_active_searcher")) != int(p2["searcher"]):
		_fail("GameState.solo_active_searcher=%d does not match phase-2 searcher %d" % [
			int(_game_state.get("solo_active_searcher")), int(p2["searcher"])])
		quit(1)
		return
	if int(_game_state.get("solo_defender")) != _opponent_of(int(p2["searcher"])):
		_fail("GameState.solo_defender=%d does not match phase-2 defender %d" % [
			int(_game_state.get("solo_defender")), _opponent_of(int(p2["searcher"]))])
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_SWAP_OK searchers=%d->%d (CPU-first branch reachable)" % [int(p1["searcher"]), int(p2["searcher"])])

	# The human's search phase must have real ghost lines to strike (the bot
	# placed them during DRAWING). Whichever phase the human searches, its
	# target count is read from GhostDrawSystem by the driver.
	var human_phase := p1 if int(p1["searcher"]) == HUMAN_ID else p2
	if int(human_phase["target_lines"]) < 1:
		_fail("Human search phase had %d target ghost lines - expected >= 1" % int(human_phase["target_lines"]))
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SEARCH_TARGETS_OK human search targets=%d" % int(human_phase["target_lines"]))

	# REVEAL/SCORING/WINNER/RETURN_TO_LOBBY are short-lived states, so record
	# the actual GameState match.state_changed events instead of waiting for the
	# current state to still equal each transient value.
	await _wait_for_seen_match_state(MatchState.REVEAL, MAX_ROUND_END_SECONDS, "REVEAL")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: REVEAL_REACHED")

	await _wait_for_seen_match_state(MatchState.SCORING, 5.0, "SCORING")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: SCORING_REACHED")

	await _wait_for_seen_match_state(MatchState.WINNER, 5.0, "WINNER")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: WINNER_REACHED")

	await _wait_for_seen_match_state(MatchState.RETURN_TO_LOBBY, 5.0, "RETURN_TO_LOBBY")
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: RETURN_TO_LOBBY_REACHED")

	await _wait_for_top_state(TopState.MAIN_MENU, 8.0, "MAIN_MENU_AFTER_MATCH")
	if _failed:
		quit(1)
		return

	await _wait_for_scene("HomeScreen", 3.0)
	if _failed:
		quit(1)
		return

	print("KATTIPAAY_SMOKE: PASS")
	quit(0)


func _opponent_of(entity_id: int) -> int:
	return HUMAN_ID if entity_id == GHOST_ID else GHOST_ID


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


func _wait_until(condition: Callable, timeout_seconds: float, label: String) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not condition.call():
		_fail("Timed out waiting for %s" % label)


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


func _on_coin_decided(payload) -> void:
	_coin_searcher = int(payload.get("active_searcher", -1))
	_coin_human_first = bool(payload.get("human_first", false))


func _on_phase_started(payload) -> void:
	_seen_phases.append({
		"phase": int(payload.get("phase", -1)),
		"searcher": int(payload.get("searcher", -1)),
		"target_lines": int(payload.get("target_lines", -1)),
	})


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