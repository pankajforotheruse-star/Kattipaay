# SoloMatchDriver.gd — Minimal single-player match driver for "Play vs CPU"
#
# Closes the round-flow gap on main: MatchStateMachine existed but was never
# instantiated, and nothing ever entered DRAWING/SEARCHING in game_world.tscn.
# This driver (spawned by GameWorld only when GameState.solo_vs_cpu is set)
# drives the FULL owner-confirmed MVP round (meeting-phase-plan.md, slice 3):
#
#   DRAWING (40s) -> MEETING/COIN (call + flip + result)
#   -> SEARCH #1 (30s, live strike-out, first searcher from the coin)
#   -> zone+role swap (no second coin - owner decision #3)
#   -> SEARCH #2 (30s, the other side searches)
#   -> count surviving hidden lines -> winner -> home.
#
# Implementation notes:
#   - The driver instantiates the REAL MatchStateMachine and moves through
#     NONE -> LOBBY -> DRAWING -> MEETING -> SEARCHING exactly once; BOTH
#     search phases run inside the SEARCHING match state (the zone title never
#     changes - only who visits whose zone changes, owner-confirmed).
#   - Who searches first comes from EV_GAME_COIN_DECIDED; phase 2 always swaps
#     to the other side. GameState.solo_active_searcher/solo_defender mirror
#     that for any consumer.
#   - Each search phase is capped at chalk_gaon/solo_search_phase_seconds (30s
#     default) via MatchTimer.start_seconds(); phases early-exit when all
#     target lines are struck (EV_GAME_LINE_STRUCK with remaining == 0).
#   - Human search: tap near a ghost line -> StrikeSystem wipes it (live).
#     CPU search: CpuSearchController sweeps the player zone and strikes the
#     player's drawn lines live while the human defends (camera overview).
#   - Round end: surviving (unstruck) hidden lines per side -> set_survivors()
#     -> ScoringManager (SCORING) -> WINNER (determine winner + banner) ->
#     RETURN_TO_LOBBY -> MAIN_MENU.
#   - Pacing is overridable via ProjectSettings "chalk_gaon/*" so the smoke
#     test can run the whole round headless in seconds.

class_name SoloMatchDriver
extends Node

const SOLO_TIMER_KEY := "quick"         # whole-round safety clock (180s)
const GHOST_ENTITY_ID := 2
const HUMAN_ENTITY_ID := 1

const DRAW_PHASE_WARNING_SECONDS := 5.0
## Face-off spots at the alley: a few px apart so BOTH characters are
## visible facing each other (owner decision #4), centered on the alley.
const MEETING_PLAYER_POS := Vector2(1150.0, 885.0)
const MEETING_CPU_POS := Vector2(1250.0, 915.0)

## Phase pacing defaults (overridden by ProjectSettings chalk_gaon/* keys).
var _drawing_seconds: float = 40.0
var _meeting_call_timeout: float = 8.0
var _meeting_max_seconds: float = 15.0
var _coin_result_hold: float = 2.0
var _search_phase_seconds: float = 30.0
var _early_exit_grace: float = 1.0
var _empty_phase_grace: float = 1.0
var _winner_hold_seconds: float = 3.0

var _match_machine: MatchStateMachine = null
var _bot: GhostBotController = null
var _hud: HUD = null
var _game_world: Node2D = null
var _ghost_sys: GhostDrawSystem = null
var _draw_sys: DrawSystem = null
var _strike_sys: StrikeSystem = null
var _cpu_sweep: CpuSearchController = null
var _camera: Node = null
var _fog_sys: FogSystem = null

var _drawing_elapsed: float = 0.0
var _ending: bool = false

## MEETING/coin phase state.
var _meeting_elapsed: float = 0.0
var _meeting_call_made: bool = false
var _meeting_resolved: bool = false
var _meeting_result_hold: float = 0.0
var _coin_overlay: CoinDeciderOverlay = null

## Search phase state (R6: two 30s phases, zone+role swap between them).
var _search_phase_index: int = 0        # 1 or 2
var _search_elapsed: float = 0.0
var _search_phase_active: bool = false
var _phase_end_pending: bool = false    # an early-exit has been requested
var _phase_end_grace_left: float = 0.0  # grace before honoring the early exit
var _winner_hold: float = 0.0

## Who searches FIRST this round (coin result) and who defends. Phase 2 swaps
## these (owner decision #3 — no second coin).
var active_searcher: int = HUMAN_ENTITY_ID
var defender: int = GHOST_ENTITY_ID

## Draw-phase clock state (visible + audible end-of-draw warning, last 5s).
var _draw_warning_played: bool = false
var _draw_phase_last_tick: int = -1

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Defensive: the driver only runs in solo mode (GameWorld gates creation).
	if not GameState.solo_vs_cpu:
		set_process(false)
		return

	# Pacing overrides (the smoke test sets these to short values headless).
	_drawing_seconds = float(ProjectSettings.get_setting("chalk_gaon/solo_drawing_seconds", 40.0))
	_meeting_call_timeout = float(ProjectSettings.get_setting("chalk_gaon/solo_meeting_call_timeout_seconds", 8.0))
	_meeting_max_seconds = float(ProjectSettings.get_setting("chalk_gaon/solo_meeting_max_seconds", 15.0))
	_coin_result_hold = float(ProjectSettings.get_setting("chalk_gaon/solo_coin_result_hold_seconds", 2.0))
	_search_phase_seconds = float(ProjectSettings.get_setting("chalk_gaon/solo_search_phase_seconds", 30.0))
	_early_exit_grace = float(ProjectSettings.get_setting("chalk_gaon/solo_early_exit_grace_seconds", 1.0))
	_empty_phase_grace = float(ProjectSettings.get_setting("chalk_gaon/solo_empty_phase_grace_seconds", 1.0))
	_winner_hold_seconds = float(ProjectSettings.get_setting("chalk_gaon/solo_winner_hold_seconds", 3.0))

	# Ensure the top-level PLAYING state (GameWorld normally does this first;
	# this guards direct scene loads).
	if GameState.current != GameState.State.PLAYING:
		GameState.transition(GameState.State.PLAYING)

	_game_world = get_node_or_null("..") as Node2D
	_hud = get_node_or_null("../HUD") as HUD
	if _game_world:
		_camera = _game_world.get_node_or_null("Camera2D")
		var systems := _game_world.get_node_or_null("Systems")
		if systems:
			_ghost_sys = systems.get_node_or_null("GhostDrawSystem") as GhostDrawSystem
			_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
			_fog_sys = systems.get_node_or_null("FogSystem") as FogSystem

	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_GAME_TIMER_EXPIRED, _on_timer_expired)
	EventBus.on(EventBus.EV_GAME_COIN_DECIDED, _on_coin_decided)
	EventBus.on(EventBus.EV_GAME_LINE_STRUCK, _on_line_struck)

	# The real match sub-state machine, driven like the multiplayer flow.
	_match_machine = MatchStateMachine.new()
	_match_machine.name = "MatchStateMachine"
	add_child(_match_machine)

	# The in-process mock ghost peer (id 2), configured from the home screen.
	_bot = GhostBotController.new()
	_bot.name = "GhostBot"
	_bot.difficulty = GameState.cpu_difficulty
	add_child(_bot)

	# Slice 3 systems: live strike-out + the CPU's search sweep.
	_strike_sys = StrikeSystem.new()
	_strike_sys.name = "StrikeSystem"
	add_child(_strike_sys)
	_cpu_sweep = CpuSearchController.new()
	_cpu_sweep.name = "CpuSearchController"
	add_child(_cpu_sweep)

	# Fresh match: clear totals/rounds carried over from the previous match
	# (audit m3) so score and statistics don't leak between matches.
	ScoringManager.reset_match()

	# Kick off the flow: NONE -> LOBBY (prototype bootstrap) -> DRAWING.
	_match_machine.transition_to(GameState.MatchState.LOBBY)
	_match_machine.transition_to(GameState.MatchState.DRAWING)
	MatchTimer.start(SOLO_TIMER_KEY)
	print("SoloMatchDriver: round started — drawing %.0fs, search %.0fs, difficulty %d" % [
		_drawing_seconds, _search_phase_seconds, GameState.cpu_difficulty
	])


func _process(delta: float) -> void:
	var ms := GameState.get_match_state()

	# WINNER hold: the banner is shown for its hold time, then home. This runs
	# even after _ending so the round always resolves.
	if ms == GameState.MatchState.WINNER:
		_winner_hold += delta
		if _winner_hold >= _winner_hold_seconds:
			_leave_to_home()
		return

	if _ending:
		return
	if ms == GameState.MatchState.PAUSED:
		return

	if ms == GameState.MatchState.DRAWING:
		_drawing_elapsed += delta
		_tick_draw_phase()
		if _drawing_elapsed >= _drawing_seconds:
			_drawing_elapsed = 0.0
			_match_machine.transition_to(GameState.MatchState.MEETING)
	elif ms == GameState.MatchState.MEETING:
		_tick_meeting_phase(delta)
	elif ms == GameState.MatchState.SEARCHING:
		_search_elapsed += delta
		if _phase_end_pending:
			_phase_end_grace_left -= delta
			if _phase_end_grace_left <= 0.0:
				_end_search_phase()
		elif _search_elapsed >= _search_phase_seconds:
			_end_search_phase()


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_TIMER_EXPIRED, _on_timer_expired)
	EventBus.off(EventBus.EV_GAME_COIN_DECIDED, _on_coin_decided)
	EventBus.off(EventBus.EV_GAME_LINE_STRUCK, _on_line_struck)
	# Restore input control (the CPU-search phase locks it).
	InputManager.touch_to_move_enabled = true
	InputManager.sneak_draw_enabled = false
	# The solo session owns the flag: leaving the game world ends solo mode so
	# a later normal/online match never spawns the bot.
	GameState.solo_vs_cpu = false


## Emit per-second draw-phase ticks, plus the one-shot end-of-draw warning
## (visible + audible) when the phase enters its LAST 5 seconds.
func _tick_draw_phase() -> void:
	var remaining_abs := _drawing_seconds - _drawing_elapsed
	var remaining := int(ceil(remaining_abs))
	if remaining != _draw_phase_last_tick:
		_draw_phase_last_tick = remaining
		EventBus.emit(EventBus.EV_GAME_DRAW_PHASE_TICK, {
			"remaining_seconds": remaining,
		})
	if remaining_abs <= DRAW_PHASE_WARNING_SECONDS and not _draw_warning_played:
		_draw_warning_played = true
		EventBus.emit(EventBus.EV_GAME_DRAW_PHASE_WARNING, {
			"remaining_seconds": remaining,
		})
		AudioManager.play_draw_warning()


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)

	if to_state == GameState.MatchState.DRAWING:
		_drawing_elapsed = 0.0
		_draw_warning_played = false
		_draw_phase_last_tick = -1
		_search_phase_index = 0
		_search_phase_active = false
		_phase_end_pending = false
		_winner_hold = 0.0
	elif to_state == GameState.MatchState.MEETING:
		_meeting_elapsed = 0.0
		_meeting_call_made = false
		_meeting_resolved = false
		_meeting_result_hold = 0.0
		_assemble_at_alley()
		_show_coin_decider()
	elif to_state == GameState.MatchState.SEARCHING:
		_free_coin_overlay()
		_begin_search_phase(1)
	elif from_state == GameState.MatchState.PAUSED:
		# An argument just resolved and resumed the match. Search phases are
		# clock-driven, so nothing deferred here; the clocks simply continue.
		pass


func _on_timer_expired(_payload: Dictionary) -> void:
	# The active phase clock (MatchTimer.start_seconds) firing = phase timeout.
	if _search_phase_active and GameState.get_match_state() == GameState.MatchState.SEARCHING:
		_end_search_phase()
	else:
		_end_round()  # whole-round safety clock (e.g. during DRAWING/MEETING)


func _on_coin_decided(payload: Dictionary) -> void:
	if GameState.get_match_state() != GameState.MatchState.MEETING:
		return
	if _meeting_resolved:
		return
	_meeting_resolved = true
	active_searcher = int(payload.get("active_searcher", HUMAN_ENTITY_ID))
	defender = int(payload.get("defender", GHOST_ENTITY_ID))
	print("SoloMatchDriver: coin resolved - active_searcher=%d defender=%d (human_first=%s)" % [
		active_searcher, defender, str(payload.get("human_first", false))
	])


func _on_line_struck(payload: Dictionary) -> void:
	if not _search_phase_active:
		return
	var remaining: int = payload.get("remaining", -1)
	var side: String = payload.get("defender", "")
	print("SoloMatchDriver: line struck (defender=%s, remaining=%d)" % [side, remaining])
	if remaining <= 0:
		# All target lines struck - early-exit the phase (grace so the last
		# WipeEffect is visible).
		_request_early_exit(_early_exit_grace)


# ── MEETING / coin phase ──────────────────────────────────────────────────────

## Meeting clock: the player gets _meeting_call_timeout to call the coin; after
## that the overlay auto-randomizes (round never hangs). Once resolved, the
## result banner holds _coin_result_hold, then SEARCHING starts.
func _tick_meeting_phase(delta: float) -> void:
	_meeting_elapsed += delta
	if _coin_overlay == null or not is_instance_valid(_coin_overlay):
		# Overlay missing (scene failed to load): never hang the round - decide
		# randomly at the hard cap and move on to SEARCHING.
		if _meeting_elapsed >= _meeting_max_seconds:
			_force_coin_decision()
		return
	if not _meeting_call_made and _meeting_elapsed >= _meeting_call_timeout:
		_meeting_call_made = true
		print("SoloMatchDriver: no call within %.0fs - coin auto-randomizes" % _meeting_call_timeout)
		_coin_overlay.auto_randomize()
	if _meeting_resolved:
		_meeting_result_hold += delta
		if _meeting_result_hold >= _coin_result_hold:
			_begin_searching()
	elif _meeting_elapsed >= _meeting_max_seconds:
		# Absolute safety net: never stall the round.
		print("SoloMatchDriver: meeting exceeded %.0fs - forcing resolution" % _meeting_max_seconds)
		if not _meeting_call_made:
			_meeting_call_made = true
			_coin_overlay.auto_randomize()
		else:
			_coin_overlay.force_resolve()


## Walk both characters to their face-off spots at the alley. Camera follows
## the player, so it pans to the alley with them.
func _assemble_at_alley() -> void:
	var player: Node2D = _game_world.get_entity(HUMAN_ENTITY_ID) as Node2D if _game_world else null
	var npc: Node2D = _game_world.get_entity(GHOST_ENTITY_ID) as Node2D if _game_world else null
	if player:
		_walk_entity_to(player, MEETING_PLAYER_POS)
	if npc is NPC:
		npc.patrolling = false
		_walk_entity_to(npc, MEETING_CPU_POS)


## Standard walk-to-target via the entity metas the MovementSystem uses.
func _walk_entity_to(entity: Node2D, target: Vector2) -> void:
	entity.set_meta("target_position", target)
	entity.set_meta("has_target", true)
	var sm: Node = entity.get_node_or_null("EntityStateMachine")
	if sm and sm.current_state_name() != "walking":
		sm.transition_to("walking")


func _show_coin_decider() -> void:
	_free_coin_overlay()
	var scene := load("res://scenes/overlay/coin_decider.tscn") as PackedScene
	if scene == null:
		push_error("SoloMatchDriver: coin_decider.tscn missing")
		return
	_coin_overlay = scene.instantiate() as CoinDeciderOverlay
	get_tree().root.add_child(_coin_overlay)


func _free_coin_overlay() -> void:
	if _coin_overlay and is_instance_valid(_coin_overlay):
		_coin_overlay.queue_free()
	_coin_overlay = null


## Last-resort decision when the decider overlay is missing: a FAIR 50/50 toss
## (owner decision #2 - difficulty never influences who searches first).
func _force_coin_decision() -> void:
	if _meeting_resolved:
		return
	_meeting_resolved = true
	var human_first := randi() % 2 == 0
	active_searcher = HUMAN_ENTITY_ID if human_first else GHOST_ENTITY_ID
	defender = GHOST_ENTITY_ID if human_first else HUMAN_ENTITY_ID
	push_error("SoloMatchDriver: coin overlay missing - auto-decided searcher=%d defender=%d" % [active_searcher, defender])


## MEETING -> SEARCHING once the result banner has had its hold time.
func _begin_searching() -> void:
	if _ending:
		return
	if GameState.get_match_state() != GameState.MatchState.MEETING:
		return
	_match_machine.transition_to(GameState.MatchState.SEARCHING)


# ── Search phases (R6) ────────────────────────────────────────────────────────

## Start search phase 1 or 2. Phase 2 swaps the roles (zone+role swap, no
## second coin - owner decision #3) and runs in the SAME SEARCHING match state
## (zone title never changes - only who visits whose zone changes).
func _begin_search_phase(phase_index: int) -> void:
	if _ending:
		return
	_search_phase_index = phase_index
	_search_elapsed = 0.0
	_search_phase_active = true
	_phase_end_pending = false
	_phase_end_grace_left = 0.0

	var searcher: int = active_searcher if phase_index == 1 else _opponent(active_searcher)
	var pdef: int = _opponent(searcher)
	GameState.solo_active_searcher = searcher
	GameState.solo_defender = pdef

	_configure_search_scene(searcher)
	MatchTimer.stop()
	MatchTimer.start_seconds(_search_phase_seconds)

	# Count the current phase's target lines DIRECTLY from the line stores:
	# StrikeSystem only activates on the phase-started event below, so it is
	# not authoritative yet at this point.
	var target_lines: int = 0
	if searcher == HUMAN_ENTITY_ID:
		target_lines = _ghost_sys.get_active_ghost_lines().size() if _ghost_sys else 0
	else:
		target_lines = _draw_sys.get_active_lines().size() if _draw_sys else 0
	EventBus.emit(EventBus.EV_GAME_SEARCH_PHASE_STARTED, {
		"phase": phase_index,
		"searcher": searcher,
		"defender": pdef,
		"target_lines": target_lines,
		"zone": "cpu" if searcher == HUMAN_ENTITY_ID else "player",
	})
	print("SoloMatchDriver: search #%d started - searcher=%d defender=%d targets=%d" % [
		phase_index, searcher, pdef, target_lines
	])
	if target_lines <= 0:
		# Edge case: nothing to search. Grace, then end the phase so the round
		# never hangs and still resolves to a winner at the end.
		_request_early_exit(_empty_phase_grace)


## Zone + role setup for a phase. The human searcher is pointed at the CPU
## zone; the CPU searcher (NPC) enters the player zone while the human defends.
func _configure_search_scene(searcher: int) -> void:
	var player: Node2D = _game_world.get_entity(HUMAN_ENTITY_ID) as Node2D if _game_world else null
	var npc: Node2D = _game_world.get_entity(GHOST_ENTITY_ID) as Node2D if _game_world else null
	if searcher == HUMAN_ENTITY_ID:
		# The human walks to the CPU zone and strikes ghost lines there; the
		# ghost (NPC) defends, standing at the center of its zone.
		if player:
			_walk_entity_to(player, ZoneLayout.SEARCH_ENTRY_HUMAN)
		if npc is NPC:
			npc.patrolling = false
			_walk_entity_to(npc, ZoneLayout.DEFEND_POS_CPU)
		InputManager.touch_to_move_enabled = true  # human controls restored
		InputManager.sneak_draw_enabled = false
		if _camera:
			_camera.clear_overview()
		if _fog_sys:
			_fog_sys.activate()
		if _hud:
			_hud.set_selected_target(GHOST_ENTITY_ID)
	else:
		# The CPU searches the PLAYER zone: the human stands at the defender
		# spot and WATCHES the live strike-out. Movement input is locked
		# (defender stance), the camera frames the whole zone (defender + CPU
		# targets in view), and the search fog is off so the player sees it.
		if player:
			_walk_entity_to(player, ZoneLayout.DEFEND_POS_HUMAN)
		if npc is NPC:
			npc.patrolling = false  # the sweep controller drives the NPC now
		InputManager.touch_to_move_enabled = false
		InputManager.sneak_draw_enabled = true  # defender may sneak-extra lines while the CPU sweeps
		if _camera:
			_camera.set_overview(Rect2(
				ZoneLayout.PLAYER_ZONE.position + Vector2(0.0, -40.0),
				ZoneLayout.PLAYER_ZONE.size + Vector2(0.0, 120.0)
			))
		if _fog_sys:
			_fog_sys.deactivate()


func _opponent(entity_id: int) -> int:
	return HUMAN_ENTITY_ID if entity_id == GHOST_ENTITY_ID else GHOST_ENTITY_ID


## End the current search phase: timeout or all target lines struck.
## Phase 1 -> phase 2 immediately (zone+role swap). Phase 2 -> scoring/winner.
func _end_search_phase() -> void:
	if _ending or not _search_phase_active:
		return
	_search_phase_active = false
	_phase_end_pending = false
	MatchTimer.stop()
	var remaining := _strike_sys.get_remaining_lines() if _strike_sys else 0
	EventBus.emit(EventBus.EV_GAME_SEARCH_PHASE_ENDED, {
		"phase": _search_phase_index,
		"target_lines_remaining": remaining,
	})
	print("SoloMatchDriver: search #%d ended - %d lines remaining" % [_search_phase_index, remaining])
	if _search_phase_index == 1:
		_begin_search_phase(2)
	else:
		_finish_round()


func _request_early_exit(grace: float) -> void:
	if _ending or not _search_phase_active:
		return
	_phase_end_pending = true
	_phase_end_grace_left = grace


# ── Round end ────────────────────────────────────────────────────────────────

## Both searches done: count surviving (unstruck) hidden lines per side and
## resolve the winner (the side with MORE surviving lines wins; a tie,
## including both-empty, resolves to the human so the round always produces a
## winner). Then WINNER (banner + hold) -> RETURN_TO_LOBBY -> MAIN_MENU.
func _finish_round() -> void:
	if _ending:
		return
	_ending = true
	MatchTimer.stop()
	_free_coin_overlay()
	var human_surviving := _draw_sys.get_active_lines().size() if _draw_sys else 0
	var cpu_surviving := _ghost_sys.get_active_ghost_lines().size() if _ghost_sys else 0
	print("SoloMatchDriver: round finished - surviving lines: human=%d cpu=%d" % [human_surviving, cpu_surviving])
	ScoringManager.set_survivors(human_surviving, cpu_surviving)
	# SEARCHING -> REVEAL (fog clear) -> SCORING (survivors break down) ->
	# WINNER (winner decided + banner) -> [hold] -> RETURN_TO_LOBBY -> home.
	_match_machine.transition_to(GameState.MatchState.REVEAL)
	_match_machine.transition_to(GameState.MatchState.SCORING)
	_match_machine.transition_to(GameState.MatchState.WINNER)
	_winner_hold = 0.0


func _leave_to_home() -> void:
	if GameState.get_match_state() != GameState.MatchState.WINNER:
		return
	_winner_hold = 0.0
	_match_machine.transition_to(GameState.MatchState.RETURN_TO_LOBBY)
	GameState.transition(GameState.State.MAIN_MENU)


## Whole-round safety end (the 180s quick clock during DRAWING/MEETING, or a
## defensive path if a phase clock is somehow missed). Scores what is left and
## returns home so the round never hangs.
func _end_round() -> void:
	if _ending:
		return
	if GameState.get_match_state() == GameState.MatchState.PAUSED:
		return
	_ending = true
	MatchTimer.stop()
	_free_coin_overlay()
	print("SoloMatchDriver: safety round end")
	var ms := GameState.get_match_state()
	if ms == GameState.MatchState.SEARCHING:
		_match_machine.transition_to(GameState.MatchState.REVEAL)
	_match_machine.transition_to(GameState.MatchState.SCORING)
	_match_machine.transition_to(GameState.MatchState.RETURN_TO_LOBBY)
	GameState.transition(GameState.State.MAIN_MENU)