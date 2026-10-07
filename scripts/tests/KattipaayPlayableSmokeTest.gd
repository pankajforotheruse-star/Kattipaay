# KattipaayPlayableSmokeTest.gd
#
# End-to-end headless smoke test for the real prototype path (slice 3, R6 +
# audit-major fixes):
#   Splash -> Home -> Play vs CPU -> difficulty -> GameWorld
#   -> DRAWING -> MEETING (coin auto-resolves; no human call headless)
#   -> SEARCH #1 -> zone+role swap -> SEARCH #2 -> REVEAL/SCORING/WINNER
#   -> RETURN_TO_LOBBY -> MAIN_MENU/Home.
#
# TWO passes in one script (each short-paced via [chalk_gaon] overrides):
#   Pass 1 — NORMAL (existing chain) + audit regressions:
#     (a) a human-drawn line survives BOTH searches to the winner count
#         (audit MAJOR-1: line decay used to run unconditionally through
#         MEETING + both searches; a decay probe with a shortened lifetime
#         would expire mid-MEETING under the old tick and must now survive),
#     (b) the CPU sweep is wired: force one strike through the exact path
#         CpuSearchController uses (DrawSystem.strike_line) during the CPU
#         phase and prove EV_GAME_LINE_STRUCK (is_ghost=false) fires and its
#         "remaining" payload (which feeds the HUD counter) matches the live
#         active-line count.
#   Pass 2 — EASY: the ghost lines must exist BEFORE the MEETING phase ends
#     (audit MAJOR-2: EASY used to schedule placement 5-15s into SEARCHING,
#     so a human that won the toss searched an empty zone ~50% of rounds).
#
# R6 flow notes: search runs as TWO phases inside the SEARCHING match state
# (only who visits whose zone changes - owner decision #3), each capped by
# chalk_gaon/solo_search_phase_seconds (default 30s), then surviving hidden
# lines are counted for the winner. There is no ACCUSE button anymore: the
# searcher STRIKES ghost lines (tap -> StrikeSystem wipe), and the CPU side
# of the search is driven by CpuSearchController.
#
# Pacing: the test overrides the [chalk_gaon] ProjectSettings keys to short
# values BEFORE the match launches (SoloMatchDriver and CoinDeciderOverlay
# both read them via ProjectSettings.get_setting(..., default) in _ready), so
# the whole round runs headless in ~15-20s instead of 40s draw + 15s meeting +
# 2x30s search. solo_drawing_seconds is kept at 8.0 on purpose: the NORMAL
# and EASY GhostBot 6s observation fallback then fires during DRAWING, so
# SEARCH #1 has real ghost lines to count (target_lines >= 1).
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
# Short-paced round: draw 8s + meeting ~3.5s + 2x search (<=2s each) + winner
# hold 1s. EASY pass may add ~3s for a random bot argument (auto-resolves).
const MAX_DRAWING_SECONDS := 15.0
const MAX_MEETING_SECONDS := 10.0
const MAX_SEARCH_SECONDS := 14.0
const MAX_ROUND_END_SECONDS := 10.0
const FRAME_SETTLE_COUNT := 2

const HUMAN_ID := 1
const GHOST_ID := 2

# Pass 1 draws 6 human lines through the REAL input path:
#   5 "cluster" lines in the far top-left of the player zone (the CPU sweep
#   cannot physically reach them within a 2s search phase), plus 1 "decay
#   probe" line far away top-right.
# The probe's decay_duration is shortened to ~8.6s right after drawing (~0.3s
# into an 8s DRAWING). Under the OLD unconditional decay tick the probe expires
# at t~8.9s - mid MEETING - and would be faded+removed before the searches, so
# human_surviving at the winner would be 0 (the MAJOR-1 regression). With decay
# frozen outside DRAWING it survives to the winner count.
const CLUSTER_START := Vector2(120.0, 90.0)
const CLUSTER_STRIDE := 70.0
const DECAY_PROBE_START := Vector2(2330.0, 60.0)
const DECAY_PROBE_DURATION := 8.6
# Pass 3 (slice 4): the defender's anchor cluster + sneak strokes. The 3
# anchor lines sit ~70-160px apart so the CPU's nearest-first sweep always
# passes within NOTICE_RADIUS (170px) of a sneak line drawn on the cluster
# whatever side of the zone the CPU starts from.
const SNEAK_ANCHOR := Vector2(160.0, 130.0)

var _failed := false
var _game_state: Node = null
var _event_bus: Node = null
var _seen_match_states: Dictionary = {}
var _coin_searcher: int = -1
var _coin_human_first: bool = false
var _seen_phases: Array = []  # {phase:int, searcher:int, target_lines:int}
var _human_line_ids: Array = []  # ids of lines the test drew as the human
var _saw_human_line_drawn := false
var _saw_line_struck_human := false  # EV_GAME_LINE_STRUCK with is_ghost=false
var _last_struck_remaining := -1
var _last_struck_line_id := -1
var _saw_argue_started := false
var _saw_sneak_noticed := false
var _sneak_noticed_payload: Dictionary = {}
var _sneak_line_ids: Array = []
var _saw_sneak_meter := false

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
	ProjectSettings.set_setting("chalk_gaon/solo_search_phase_seconds", 5.0)
	ProjectSettings.set_setting("chalk_gaon/solo_early_exit_grace_seconds", 0.5)
	ProjectSettings.set_setting("chalk_gaon/solo_empty_phase_grace_seconds", 0.5)
	ProjectSettings.set_setting("chalk_gaon/cpu_sweep_speed", 420.0)  # restored per-pass for the sneak pass
	ProjectSettings.set_setting("chalk_gaon/solo_winner_hold_seconds", 1.0)
	ProjectSettings.set_setting("chalk_gaon/solo_argue_stall_seconds", 1.0)
	print("KATTIPAAY_SMOKE: PACING_OVERRIDES_SET drawing=8 meeting_call=1 search=5 winner_hold=1 argue_stall=1")

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
	_event_bus.call("on", "game.line_drawn", Callable(self, "_on_line_drawn"))
	_event_bus.call("on", "game.line_struck", Callable(self, "_on_line_struck"))
	_event_bus.call("on", "game.defender_argue_started", Callable(self, "_on_defender_argue_started"))
	_event_bus.call("on", "game.sneak_line_drawn", Callable(self, "_on_sneak_line_drawn"))
	_event_bus.call("on", "game.sneak_meter_changed", Callable(self, "_on_sneak_meter_changed"))
	_event_bus.call("on", "game.sneak_noticed", Callable(self, "_on_sneak_noticed"))

	await _wait_for_top_state(TopState.MAIN_MENU, MAX_STARTUP_SECONDS, "MAIN_MENU")
	if _failed:
		quit(1)
		return

	await _wait_for_scene("HomeScreen", 3.0)
	if _failed:
		quit(1)
		return
	print("KATTIPAAY_SMOKE: HOME_READY")

	# ── Pass 1: NORMAL — full R6 chain + audit MAJOR-1 (human lines survive)
	# ── and MAJOR-2's counterpart (CPU sweep strike wiring).
	await _run_match_pass("NORMAL", true)
	if _failed:
		quit(1)
		return

	# ── Pass 2: EASY — ghost lines must exist before the search (MAJOR-2).
	await _run_match_pass("EASY", false)
	if _failed:
		quit(1)
		return

	# ── Pass 3: NORMAL — defender argue + sneak (slice 4): argue stalls the
	# ── CPU sweep; sneak noticed (chance forced 1.0) → NOTICED + penalty
	# ── strikes of the sneak AND 2 nearby defender lines; sneak unnoticed
	# ── (chance forced 0.0) survives into the winner's surviving count.
	await _run_sneak_defender_pass("NORMAL")
	if _failed:
		quit(1)
		return

	# Pass 3: NORMAL — defender argue + sneak (slice 4): argue stalls the
	# CPU sweep; sneak noticed (chance forced 1.0) → NOTICED + penalty
	# strikes of the sneak AND 2 nearby defender lines; sneak unnoticed
	# (chance forced 0.0) survives into the winner's surviving count.
	await _run_sneak_defender_pass("NORMAL")
	if _failed:
		quit(1)
		return

	print("KATTIPAAY_SMOKE: PASS")
	quit(0)


## Launch one full short-paced VS CPU match at the given difficulty and run
## the shared round assertions. When draw_human_lines is true, additionally
## draw human lines during DRAWING through the real input event path and
## assert survival + CPU-sweep strike wiring.
func _run_match_pass(diff_label: String, draw_human_lines: bool) -> void:
	# Fresh per-pass observation state (bus subscriptions are one-time).
	_seen_match_states.clear()
	_coin_searcher = -1
	_coin_human_first = false
	_seen_phases.clear()
	_human_line_ids.clear()
	_saw_human_line_drawn = false
	_saw_line_struck_human = false
	_last_struck_remaining = -1
	_last_struck_line_id = -1

	print("KATTIPAAY_SMOKE: PASS_START difficulty=%s draw_human_lines=%s" % [diff_label, str(draw_human_lines)])

	var home: Node = current_scene
	if home == null or home.name != "HomeScreen":
		_fail("Expected HomeScreen at pass start, got %s" % (home.name if home else "null"))
		return
	var play_cpu := home.get_node_or_null("%PlayVsCPUButton") as Button
	if play_cpu == null:
		_fail("PlayVsCPUButton not found on HomeScreen")
		return
	play_cpu.pressed.emit()
	await _settle_frames()

	var picker := home.get_node_or_null("DifficultyPicker")
	if picker == null:
		_fail("DifficultyPicker was not created by Play vs CPU")
		return

	var diff_button := _find_button_with_text(picker, diff_label)
	if diff_button == null:
		_fail("%s difficulty button not found" % diff_label)
		return
	diff_button.pressed.emit()
	print("KATTIPAAY_SMOKE: PLAY_VS_CPU_SELECTED difficulty=%s" % diff_label)

	await _wait_for_top_state(TopState.PLAYING, MAX_PLAYING_SECONDS, "PLAYING")
	if _failed:
		return

	await _wait_for_scene("GameWorld", 5.0)
	if _failed:
		return
	print("KATTIPAAY_SMOKE: GAME_WORLD_ENTERED difficulty=%s" % diff_label)

	var world: Node = current_scene
	var entity_registry: Dictionary = world.get("entity_registry")
	if entity_registry.size() < 2:
		_fail("Playable world has fewer than 2 registered entities")
		return
	if world.get_node_or_null("SoloMatchDriver") == null:
		_fail("SoloMatchDriver was not spawned")
		return
	var draw_sys: Node = world.get_node_or_null("Systems/DrawSystem")
	var ghost_sys: Node = world.get_node_or_null("Systems/GhostDrawSystem")
	var cpu_sweep: Node = world.get_node_or_null("SoloMatchDriver/CpuSearchController")
	if draw_sys == null:
		_fail("Systems/DrawSystem not found in GameWorld")
		return
	if ghost_sys == null:
		_fail("Systems/GhostDrawSystem not found in GameWorld")
		return
	print("KATTIPAAY_SMOKE: SYSTEMS_FOUND difficulty=%s cpu_sweep=%s" % [diff_label, "yes" if cpu_sweep != null else "no"])

	await _wait_for_match_state(MatchState.DRAWING, MAX_DRAWING_SECONDS, "DRAWING")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: DRAWING_REACHED difficulty=%s" % diff_label)

	if draw_human_lines:
		# Draw through the SAME input events a real finger draw produces
		# (EV_INPUT_DRAW_START/UPDATE/END -> DrawSystem._on_draw_*).
		await _draw_cluster_lines()
		if _failed:
			return
		await _draw_decay_probe(draw_sys)
		if _failed:
			return
		if _human_line_ids.size() != 6:
			_fail("Expected 6 human-drawn lines, got %d" % _human_line_ids.size())
			return
		print("KATTIPAAY_SMOKE: HUMAN_LINES_DRAWN count=%d ids=%s" % [_human_line_ids.size(), str(_human_line_ids)])

	await _wait_for_match_state(MatchState.MEETING, MAX_DRAWING_SECONDS, "MEETING")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: MEETING_REACHED difficulty=%s" % diff_label)

	if diff_label == "EASY":
		# Audit MAJOR-2: EASY must place its ghost lines during DRAWING so the
		# human's search has real targets even when the human wins the toss.
		# At MEETING (before SEARCHING) the lines must already exist.
		await _wait_until(func() -> bool: return ghost_sys.call("get_active_ghost_lines").size() >= 1, 2.5, "EASY_GHOST_LINES_AT_MEETING")
		if _failed:
			return
		print("KATTIPAAY_SMOKE: EASY_GHOST_LINES_BEFORE_SEARCH count=%d" % int(ghost_sys.call("get_active_ghost_lines").size()))

	# No human input headless: the driver auto-randomizes the coin after
	# solo_meeting_call_timeout_seconds and starts SEARCHING after the result
	# hold. Assert the coin actually landed before we leave MEETING.
	await _wait_until(func() -> bool: return _coin_searcher >= 1, MAX_MEETING_SECONDS, "COIN_DECIDED")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: COIN_DECIDED active_searcher=%d human_first=%s" % [_coin_searcher, str(_coin_human_first)])

	await _wait_for_match_state(MatchState.SEARCHING, MAX_MEETING_SECONDS, "SEARCHING")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: SEARCHING_REACHED difficulty=%s" % diff_label)

	# Both search phases run inside SEARCHING; observe them via the phase events
	# the driver emits (EV_GAME_SEARCH_PHASE_STARTED with phase/searcher/
	# defender/target_lines). EASY may pause the match once for a random bot
	# argument (auto-resolves via ArgumentSystem ~3s) - the waits absorb it.
	if draw_human_lines:
		# (b) CPU sweep strike wiring: wait for the CPU's search phase and force
		# one strike through the CPU's own path (DrawSystem.strike_line), then
		# prove the EV_GAME_LINE_STRUCK is_ghost=false event and its remaining
		# counter (the value the HUD label is fed from).
		await _exercise_cpu_strike(draw_sys)
		if _failed:
			return

	await _wait_until(func() -> bool: return _seen_phases.size() >= 2, MAX_SEARCH_SECONDS, "SEARCH_PHASE_2")
	if _failed:
		return

	if _seen_phases.size() != 2:
		_fail("Expected exactly 2 search phases, saw %d" % _seen_phases.size())
		return

	var p1: Dictionary = _seen_phases[0]
	var p2: Dictionary = _seen_phases[1]
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_1 phase=%d searcher=%d targets=%d" % [p1["phase"], p1["searcher"], p1["target_lines"]])
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_2 phase=%d searcher=%d targets=%d" % [p2["phase"], p2["searcher"], p2["target_lines"]])

	if int(p1["phase"]) != 1 or int(p2["phase"]) != 2:
		_fail("Search phases out of order: %s -> %s" % [str(p1["phase"]), str(p2["phase"])])
		return
	if int(p1["searcher"]) != _coin_searcher:
		_fail("Phase-1 searcher %d does not match coin decision %d" % [int(p1["searcher"]), _coin_searcher])
		return
	if int(p2["searcher"]) == int(p1["searcher"]):
		_fail("Zone+role swap did not occur: both phases have searcher %d" % int(p1["searcher"]))
		return
	if int(p1["searcher"]) != HUMAN_ID and int(p2["searcher"]) != HUMAN_ID:
		_fail("Neither phase had the human as searcher")
		return
	if int(p1["searcher"]) != GHOST_ID and int(p2["searcher"]) != GHOST_ID:
		_fail("Neither phase had the CPU (ghost) as searcher - CPU-first branch unreachable")
		return

	# GameState.solo_active_searcher/defender mirror the active phase; after
	# phase 2 starts it must hold phase-2's values (the swap is visible).
	if int(_game_state.get("solo_active_searcher")) != int(p2["searcher"]):
		_fail("GameState.solo_active_searcher=%d does not match phase-2 searcher %d" % [
			int(_game_state.get("solo_active_searcher")), int(p2["searcher"])])
		return
	if int(_game_state.get("solo_defender")) != _opponent_of(int(p2["searcher"])):
		_fail("GameState.solo_defender=%d does not match phase-2 defender %d" % [
			int(_game_state.get("solo_defender")), _opponent_of(int(p2["searcher"]))])
		return
	print("KATTIPAAY_SMOKE: SEARCH_PHASE_SWAP_OK searchers=%d->%d (CPU-first branch reachable)" % [int(p1["searcher"]), int(p2["searcher"])])

	# The human's search phase must have real ghost lines to strike: the bot
	# (NORMAL via its observation fallback, EASY via the audit MAJOR-2 fix)
	# places them during DRAWING. Whichever phase the human searches, its
	# target count is read from GhostDrawSystem by the driver.
	var human_phase := p1 if int(p1["searcher"]) == HUMAN_ID else p2
	if int(human_phase["target_lines"]) < 1:
		_fail("Human search phase had %d target ghost lines - expected >= 1 (difficulty=%s)" % [int(human_phase["target_lines"]), diff_label])
		return
	print("KATTIPAAY_SMOKE: SEARCH_TARGETS_OK difficulty=%s human search targets=%d" % [diff_label, int(human_phase["target_lines"])])

	# REVEAL/SCORING/WINNER/RETURN_TO_LOBBY are short-lived states, so record
	# the actual GameState match.state_changed events instead of waiting for the
	# current state to still equal each transient value.
	await _wait_for_seen_match_state(MatchState.REVEAL, MAX_ROUND_END_SECONDS, "REVEAL")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: REVEAL_REACHED difficulty=%s" % diff_label)

	await _wait_for_seen_match_state(MatchState.SCORING, 6.0, "SCORING")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: SCORING_REACHED difficulty=%s" % diff_label)

	await _wait_for_seen_match_state(MatchState.WINNER, 6.0, "WINNER")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: WINNER_REACHED difficulty=%s" % diff_label)

	if draw_human_lines:
		# (a) Audit MAJOR-1: at _finish_round the driver counts DrawSystem's
		# active lines as the human's survivors. The decay probe must still be
		# active here (it would have expired mid-MEETING under the old
		# unconditional decay tick), so human_surviving >= 1 in real pacing.
		var survivors := int(draw_sys.call("get_active_lines").size())
		print("KATTIPAAY_SMOKE: HUMAN_SURVIVING_AT_WINNER count=%d difficulty=%s" % [survivors, diff_label])
		if survivors < 1:
			_fail("Human surviving lines at winner is 0 - decay is not frozen through MEETING/SEARCH (audit MAJOR-1)")
			return

	await _wait_for_seen_match_state(MatchState.RETURN_TO_LOBBY, 6.0, "RETURN_TO_LOBBY")
	if _failed:
		return
	print("KATTIPAAY_SMOKE: RETURN_TO_LOBBY_REACHED difficulty=%s" % diff_label)

	await _wait_for_top_state(TopState.MAIN_MENU, 8.0, "MAIN_MENU_AFTER_MATCH")
	if _failed:
		return

	await _wait_for_scene("HomeScreen", 3.0)
	if _failed:
		return

	print("KATTIPAAY_SMOKE: PASS_DONE difficulty=%s" % diff_label)


## Draw 5 short strokes in the player zone's far top-left corner (the CPU
## sweep never reaches them in the 2s search phase; they exist so the sweep
## has something to miss and the survivor count has margin).
func _draw_cluster_lines() -> void:
	for i in range(5):
		var base := Vector2(CLUSTER_START.x, CLUSTER_START.y + CLUSTER_STRIDE * float(i))
		await _draw_human_stroke(base, base + Vector2(120.0, 40.0))
		await _settle_frames()
	if _failed:
		return
	if not _saw_human_line_drawn:
		_fail("No EV_GAME_LINE_DRAWN observed for the drawn cluster lines")
		quit(1)


## Draw the decay probe line (far top-right) and shrink its decay_duration to
## DECAY_PROBE_DURATION. Under the old unconditional decay tick it expires
## mid-MEETING (~8.9s: 8s draw + 1s into the 4s meeting); with the MAJOR-1 fix
## decay freezes at the DRAWING/MEETING boundary and the line survives.
func _draw_decay_probe(draw_sys: Node) -> void:
	await _draw_human_stroke(DECAY_PROBE_START, DECAY_PROBE_START + Vector2(40.0, 90.0))
	await _settle_frames()
	if _human_line_ids.is_empty():
		_fail("Decay probe line was not registered by DrawSystem")
		quit(1)
		return
	var probe_id := int(_human_line_ids[-1])
	var lines: Array = draw_sys.call("get_active_lines")
	for line in lines:
		if int(line.get("id")) == probe_id:
			line.set("decay_duration", DECAY_PROBE_DURATION)
			print("KATTIPAAY_SMOKE: DECAY_PROBE_ARMED id=%d decay_duration=%.1f" % [probe_id, DECAY_PROBE_DURATION])
			return
	_fail("Decay probe line %d not found in active set" % probe_id)
	quit(1)


## One human stroke through the real input path: EV_INPUT_DRAW_START/UPDATE/END
## with HUMAN_ID, white chalk, emitted on the live EventBus. A real draw
## (InputManager -> bus -> DrawSystem) takes exactly this same path.
func _draw_human_stroke(start_pos: Vector2, end_pos: Vector2) -> void:
	_event_bus.call("emit", "input.draw_start", {
		"entity_id": HUMAN_ID,
		"position": start_pos,
		"chalk_type": 0,
	})
	await process_frame
	var steps := 8
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		_event_bus.call("emit", "input.draw_update", {
			"entity_id": HUMAN_ID,
			"position": start_pos.lerp(end_pos, t),
		})
		await process_frame
	_event_bus.call("emit", "input.draw_end", {"entity_id": HUMAN_ID})
	await process_frame
	await process_frame


## (b) CPU sweep wiring. Waits until the CPU's search phase is active, then
## strikes ONE human line through DrawSystem.strike_line - the exact call
## CpuSearchController makes when it reaches a line - and proves:
##   - the sweep controller exists and is active,
##   - EV_GAME_LINE_STRUCK (is_ghost=false) fires (the HUD counter is fed
##     straight from its "remaining" payload),
##   - the payload's remaining equals the live active-line count after the
##     strike (counter decremented consistently).
func _exercise_cpu_strike(draw_sys: Node) -> void:
	await _wait_until(Callable(self, "_cpu_phase_started"), MAX_SEARCH_SECONDS, "CPU_SEARCH_PHASE_STARTED")
	if _failed:
		return
	var cpu_sweep: Node = current_scene.get_node_or_null("SoloMatchDriver/CpuSearchController")
	if cpu_sweep != null and not bool(cpu_sweep.get("_active")):
		_fail("CpuSearchController exists but is not active during the CPU phase")
		quit(1)
		return
	var lines: Array = draw_sys.call("get_active_lines")
	var target_id := -1
	for line in lines:
		if not bool(line.get("is_struck")):
			target_id = int(line.get("id"))
			break
	if target_id < 0:
		_fail("No unstruck human line to strike (CPU sweep has nothing to hit)")
		quit(1)
		return
	var before := int(draw_sys.call("get_active_lines").size())
	var struck: bool = draw_sys.call("strike_line", target_id)
	if not struck:
		_fail("DrawSystem.strike_line returned false for human line %d (CPU sweep path broken)" % target_id)
		quit(1)
		return
	await _wait_until(func() -> bool: return _saw_line_struck_human, 2.0, "EV_GAME_LINE_STRUCK_HUMAN")
	if _failed:
		return
	var after := int(draw_sys.call("get_active_lines").size())
	if after != before - 1:
		_fail("Strike removed the wrong number of lines: before=%d after=%d" % [before, after])
		quit(1)
		return
	if _last_struck_line_id != target_id:
		_fail("EV_GAME_LINE_STRUCK reported line %d, expected %d" % [_last_struck_line_id, target_id])
		quit(1)
		return
	if _last_struck_remaining != after:
		# The HUD purely renders payload.remaining - it must match actuals.
		_fail("EV_GAME_LINE_STRUCK remaining=%d != active lines %d (HUD counter wiring)" % [_last_struck_remaining, after])
		quit(1)
		return
	print("KATTIPAAY_SMOKE: CPU_SWEEP_STRIKE_OK target=%d active %d -> %d remaining_payload=%d" % [target_id, before, after, _last_struck_remaining])


## True once the CPU's search phase has started (phase 1 searcher=2 while it
## is still the active phase, or phase 2 searcher=2 the moment its event
## fires). Used by _exercise_cpu_strike so the forced strike always lands
## during the CPU phase regardless of how the coin lands.
func _cpu_phase_started() -> bool:
	if _seen_phases.is_empty():
		return false
	if int(_seen_phases[0].get("searcher", -1)) == GHOST_ID:
		return _seen_phases.size() == 1
	if _seen_phases.size() >= 2 and int(_seen_phases[1].get("searcher", -1)) == GHOST_ID:
		return true
	return false


func _on_defender_argue_started(payload) -> void:
	_saw_argue_started = true
	if payload != null:
		print("KATTIPAAY_SMOKE: ARGUE_EVENT arguer=%d target=%d stall=%.1f" % [
			int(payload.get("arguer_id", -1)), int(payload.get("target_searcher_id", -1)),
			float(payload.get("stall_seconds", 0.0))])


func _on_sneak_line_drawn(payload) -> void:
	if payload == null:
		return
	_sneak_line_ids.append(int(payload.get("line_id", -1)))


func _on_sneak_meter_changed(_payload) -> void:
	_saw_sneak_meter = true


func _on_sneak_noticed(payload) -> void:
	_saw_sneak_noticed = true
	_sneak_noticed_payload = payload if payload is Dictionary else {}


func _wait_seconds(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame

## Pass 3 (slice 4) — defender argue + sneak, one full match:
##   (1) while the CPU searches the human's zone, the human argues → argue
##       event + the CPU sweep stalls (_pause_timer >= stall, no strikes
##       during the stall) + the one-use-per-phase cap holds;
##   (2) sneak A drawn next to the anchor lines with the notice chance FORCED
##       to 1.0 → EV_GAME_SNEAK_NOTICED fires and the penalty strikes the
##       sneak AND the 2 nearest defender lines (active drops by 3);
##   (3) sneak B drawn with the chance FORCED to 0.0 → the CPU's sweep and
##       its end-of-sweep scan pass it → it stays active and appears in the
##       winner's surviving-lines total (unstruck, is_sneak=true).
func _run_sneak_defender_pass(diff_label: String) -> void:
	# Fresh per-pass observation state.
	_seen_match_states.clear()
	_coin_searcher = -1
	_coin_human_first = false
	_seen_phases.clear()
	_human_line_ids.clear()
	_saw_human_line_drawn = false
	_saw_line_struck_human = false
	_last_struck_remaining = -1
	_last_struck_line_id = -1
	_saw_argue_started = false
	_saw_sneak_noticed = false
	_sneak_noticed_payload = {}
	_sneak_line_ids.clear()
	_saw_sneak_meter = false

	# THIS pass only: fast sweep + guaranteed notice (the per-line chance is
	# read live from ProjectSettings at each roll; 0.0 is forced later).
	ProjectSettings.set_setting("chalk_gaon/cpu_sweep_speed", 700.0)
	ProjectSettings.set_setting("chalk_gaon/cpu_sneak_notice_chance", 1.0)

	print("KATTIPAAY_SMOKE: PASS_START difficulty=%s slice4-defender(SNEAK)" % diff_label)

	var home: Node = current_scene
	if home == null or home.name != "HomeScreen":
		_fail("Expected HomeScreen at pass start, got %s" % (home.name if home else "null"))
		return
	var play_cpu := home.get_node_or_null("%PlayVsCPUButton") as Button
	if play_cpu == null:
		_fail("PlayVsCPUButton not found on HomeScreen")
		return
	play_cpu.pressed.emit()
	await _settle_frames()
	var picker := home.get_node_or_null("DifficultyPicker")
	if picker == null:
		_fail("DifficultyPicker was not created by Play vs CPU")
		return
	var diff_button := _find_button_with_text(picker, diff_label)
	if diff_button == null:
		_fail("%s difficulty button not found" % diff_label)
		return
	diff_button.pressed.emit()
	await _wait_for_top_state(TopState.PLAYING, MAX_PLAYING_SECONDS, "PLAYING")
	if _failed:
		return
	await _wait_for_scene("GameWorld", 5.0)
	if _failed:
		return
	var world: Node = current_scene
	var draw_sys: Node = world.get_node_or_null("Systems/DrawSystem")
	var arg_sys: Node = world.get_node_or_null("Systems/ArgumentSystem")
	if draw_sys == null:
		_fail("Systems/DrawSystem not found in GameWorld")
		return
	if arg_sys == null:
		_fail("Systems/ArgumentSystem not found in GameWorld")
		return

	await _wait_for_match_state(MatchState.DRAWING, MAX_DRAWING_SECONDS, "DRAWING")
	if _failed:
		return
	# 3 close anchor lines: the CPU's nearest-first sweep targets this cluster
	# from anywhere in its zone, and the 240px penalty radius turns 2 of them
	# into penalty fodder when sneak A is noticed.
	for i in range(3):
		var base := SNEAK_ANCHOR + Vector2(60.0 * float(i), 30.0 * float(i))
		await _draw_human_stroke(base, base + Vector2(40.0, 70.0))
		await _settle_frames()
	if _human_line_ids.size() != 3:
		_fail("Expected 3 human-drawn anchor lines in the sneak pass, got %d" % _human_line_ids.size())
		return
	print("KATTIPAAY_SMOKE: SLICE4_ANCHOR_LINES_DRAWN ids=%s" % str(_human_line_ids))

	await _wait_for_match_state(MatchState.MEETING, MAX_DRAWING_SECONDS, "MEETING")
	if _failed:
		return
	await _wait_until(func() -> bool: return _coin_searcher >= 1, MAX_MEETING_SECONDS, "COIN_DECIDED")
	if _failed:
		return
	await _wait_for_match_state(MatchState.SEARCHING, MAX_MEETING_SECONDS, "SEARCHING")
	if _failed:
		return

	# Wait for the CPU's search phase (phase 1 or 2 — the coin decides) and
	# run the argue + sneak choreography inside it.
	await _wait_until(Callable(self, "_cpu_phase_started"), MAX_SEARCH_SECONDS, "CPU_SEARCH_PHASE")
	if _failed:
		return
	var cpu_sweep: Node = world.get_node_or_null("SoloMatchDriver/CpuSearchController")
	if cpu_sweep == null:
		_fail("CpuSearchController not found")
		return

	# ── (1) argue: valid only for the defender once per phase ──
	var argued_ok: bool = bool(arg_sys.call("request_defender_argue", 1))
	if not argued_ok:
		_fail("request_defender_argue(1) returned false during the CPU search phase")
		return
	await _wait_until(func() -> bool: return _saw_argue_started, 2.0, "EV_GAME_DEFENDER_ARGUE_STARTED")
	if _failed:
		return
	var stall_left: float = float(cpu_sweep.get("_pause_timer"))
	if stall_left < 0.8:
		_fail("Argue did not stall the CPU sweep (_pause_timer=%.2f < 0.8)" % stall_left)
		return
	var c0 := int(draw_sys.call("get_active_lines").size())
	await _wait_seconds(0.6)
	if int(draw_sys.call("get_active_lines").size()) != c0:
		_fail("CPU swept during the argue stall (active %d -> %d)" % [c0, int(draw_sys.call("get_active_lines").size())])
		return
	if bool(arg_sys.call("request_defender_argue", 1)):
		_fail("Arguing twice in one defender phase was allowed (use-cap broken)")
		return
	print("KATTIPAAY_SMOKE: SLICE4_ARGUE_STALL_OK stall=%.1f active_held=%d" % [stall_left, c0])

	# ── (2a) sneak A, chance forced 1.0 → NOTICED + penalty ──
	var before_notice := int(draw_sys.call("get_active_lines").size())
	await _draw_human_stroke(SNEAK_ANCHOR + Vector2(18.0, 6.0), SNEAK_ANCHOR + Vector2(44.0, 26.0))
	await _settle_frames()
	var sneak_a_id := int(_sneak_line_ids[-1]) if _sneak_line_ids.size() > 0 else -1
	if sneak_a_id < 0:
		_fail("Sneak line A was not registered (EV_GAME_SNEAK_LINE_DRAWN)")
		return
	if not _saw_sneak_meter:
		_fail("No EV_GAME_SNEAK_METER_CHANGED observed after the sneak draw")
		return
	await _wait_until(func() -> bool: return _saw_sneak_noticed, 8.0, "EV_GAME_SNEAK_NOTICED")
	if _failed:
		return
	var penalty_ids: Array = _sneak_noticed_payload.get("penalty_line_ids", [])
	if not penalty_ids.has(sneak_a_id):
		_fail("NOTICED penalty payload missing the sneak line %d: %s" % [sneak_a_id, str(penalty_ids)])
		return
	if penalty_ids.size() < 3:
		_fail("NOTICED penalty struck %d line(s), expected sneak + 2 defender lines: %s" % [penalty_ids.size(), str(penalty_ids)])
		return
	var active_after_notice := int(draw_sys.call("get_active_lines").size())
	if active_after_notice != before_notice - 3:
		_fail("After NOTICED penalty active went %d -> %d (expected %d)" % [before_notice, active_after_notice, before_notice - 3])
		return
	print("KATTIPAAY_SMOKE: SLICE4_SNEAK_NOTICED_OK sneak=%d penalty=%d active=%d->%d" % [sneak_a_id, penalty_ids.size(), before_notice, active_after_notice])

	# ── (2b) sneak B, chance forced 0.0 → passes unseen, survives ──
	ProjectSettings.set_setting("chalk_gaon/cpu_sneak_notice_chance", 0.0)
	await _draw_human_stroke(SNEAK_ANCHOR + Vector2(238.0, 76.0), SNEAK_ANCHOR + Vector2(264.0, 96.0))
	await _settle_frames()
	var sneak_b_id := int(_sneak_line_ids[-1]) if _sneak_line_ids.size() > 0 else -1
	print("KATTIPAAY_SMOKE: SLICE4_SNEAK_B_DRAWN id=%d (chance forced 0.0)" % sneak_b_id)

	# The round finishes on its own clocks; B must be in the surviving count.
	await _wait_for_seen_match_state(MatchState.WINNER, 20.0, "WINNER")
	if _failed:
		return
	var active_lines: Array = draw_sys.call("get_active_lines")
	var b_alive := false
	var b_sneak := false
	for line in active_lines:
		if int(line.get("id")) == sneak_b_id:
			b_alive = not bool(line.get("is_struck"))
			b_sneak = bool(line.get("is_sneak"))
			break
	if not b_alive or not b_sneak:
		_fail("Sneak line B (%d) did not survive to scoring unstruck+is_sneak (noticed at chance 0.0?)" % sneak_b_id)
		return
	var survivors := int(draw_sys.call("get_active_lines").size())
	var scoring_mgr: Node = root.get_node_or_null("ScoringManager")
	var manager_survivors := int(scoring_mgr.call("get_human_surviving_lines")) if scoring_mgr else -1
	if survivors < 1 or manager_survivors < 1:
		_fail("Human surviving lines at winner is 0 — sneaks did not count (active=%d scored=%d)" % [survivors, manager_survivors])
		return
	print("KATTIPAAY_SMOKE: SLICE4_SNEAK_SURVIVED_OK sneak=%d survivors=%d scored=%d" % [sneak_b_id, survivors, manager_survivors])

	await _wait_for_seen_match_state(MatchState.RETURN_TO_LOBBY, 6.0, "RETURN_TO_LOBBY")
	if _failed:
		return
	await _wait_for_top_state(TopState.MAIN_MENU, 8.0, "MAIN_MENU_AFTER_MATCH")
	if _failed:
		return
	await _wait_for_scene("HomeScreen", 3.0)
	if _failed:
		return
	print("KATTIPAAY_SMOKE: PASS_DONE difficulty=%s slice4" % diff_label)


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


func _on_line_drawn(payload) -> void:
	if payload == null:
		return
	if int(payload.get("player_id", -1)) == HUMAN_ID:
		_saw_human_line_drawn = true
		_human_line_ids.append(int(payload.get("line_id", -1)))


func _on_line_struck(payload) -> void:
	if payload == null:
		return
	if not bool(payload.get("is_ghost", false)):
		_saw_line_struck_human = true
		_last_struck_remaining = int(payload.get("remaining", -1))
		_last_struck_line_id = int(payload.get("line_id", -1))


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