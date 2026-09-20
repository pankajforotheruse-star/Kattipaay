# SoloMatchDriver.gd — Minimal single-player match driver for "Play vs CPU"
#
# Closes the round-flow gap on main: MatchStateMachine existed but was never
# instantiated, and nothing ever entered DRAWING/SEARCHING in game_world.tscn.
# This driver (spawned by GameWorld only when GameState.solo_vs_cpu is set):
#
#   1. Instantiates the real MatchStateMachine and drives it through
#      NONE → LOBBY (prototype bootstrap) → DRAWING → SEARCHING via
#      GameState.enter_match_state(), so every EV_MATCH_STATE_CHANGED consumer
#      reacts exactly as designed: MatchTimer starts on DRAWING, FogSystem
#      rolls in + reveals vision circles on EV_INPUT_MOVE_START during
#      SEARCHING, GhostDrawSystem runs discovery, ArgumentSystem resets
#      per-round accusation state, HUD shows the ACCUSE / Sneak buttons,
#      SilentSneakSystem resets its uses, ScoringManager resets accumulators.
#   2. Runs a fixed DRAWING phase (SOLO_DRAWING_SECONDS), then SEARCHING.
#   3. Ends the round on: match-timer expiry, all ghost lines discovered, or
#      the accusation pool exhausted (MAX_ACCUSATIONS_PER_ROUND — one per
#      player in the 2-player solo match).
#   4. Routes the end through REVEAL → SCORING → RETURN_TO_LOBBY → MAIN_MENU
#      so ScoringManager finalizes the round score + saves statistics, then
#      returns cleanly to the home screen (no scoreboard/winner overlays —
#      out of scope).
#   5. Instantiates the GhostBotController mock peer (ghost, id 2) with
#      GameState.cpu_difficulty, and pre-selects the ghost as the human's
#      accusation target on SEARCHING entry so the existing HUD ACCUSE button
#      works out of the box (the HUD resets its selection on SEARCHING entry;
#      the driver runs after the HUD's handler and re-sets it).
#
# SceneManager overlay handling: every overlay routed by EV_MATCH_STATE_CHANGED
# that does not exist on main (match_lobby, searching, reveal, scoreboard,
# winner, returning, ...) is already guarded inside SceneManager.show_overlay()
# — `load()` returns null and the method returns with push_error. No overlay
# change was needed; the missing overlays are out of scope.
#
# Design choice (driver option (a) from the brief, vs. the Tutorial's "set
# GameState.current_match directly, no event"): the timer, fog, ghost-line
# discovery and accusation systems all react to EV_MATCH_STATE_CHANGED, so the
# solo flow emits real state transitions through the real MatchStateMachine.

class_name SoloMatchDriver
extends Node

const SOLO_DRAWING_SECONDS := 40.0
## Final N seconds of the draw phase that trigger the end-of-draw warning
## (visible + audible) - owner spec: warn during the LAST 5 seconds of DRAWING.
const DRAW_PHASE_WARNING_SECONDS := 5.0
const SOLO_TIMER_KEY := "quick"         # 180s match timer (auto-start is "standard")
const GHOST_ENTITY_ID := 2
const HUMAN_ENTITY_ID := 1

## MEETING phase clocks (owner spec): the player must call the coin within
## MEETING_CALL_TIMEOUT_SECONDS; the whole meeting owns ~MEETING_MAX_SECONDS
## (incl. flip animation + result hold) so the round never stalls.
const MEETING_CALL_TIMEOUT_SECONDS := 8.0
const MEETING_MAX_SECONDS := 15.0
const COIN_RESULT_HOLD_SECONDS := 2.0
## Face-off spots at the alley: a few px apart so BOTH characters are
## visible facing each other (owner decision #4), centered on the alley.
const MEETING_PLAYER_POS := Vector2(1150.0, 885.0)
const MEETING_CPU_POS := Vector2(1250.0, 915.0)
const MAX_ACCUSATIONS_PER_ROUND := 2    # one per player (2 players)

var _match_machine: MatchStateMachine = null
var _bot: GhostBotController = null
var _hud: HUD = null
var _game_world: Node2D = null
var _ghost_sys: GhostDrawSystem = null

var _drawing_elapsed: float = 0.0
var _argument_started_count: int = 0
var _ending: bool = false
var _end_pending: bool = false
var _in_searching: bool = false

## MEETING/coin phase state.
var _meeting_elapsed: float = 0.0
var _meeting_call_made: bool = false
var _meeting_resolved: bool = false
var _meeting_result_hold: float = 0.0
var _coin_overlay: CoinDeciderOverlay = null

## Who searches first this round (1 = human, 2 = ghost) and who defends.
## Set when the coin resolves; consumed by SEARCHING (and the later
## zone+role swap slice).
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

	# Ensure the top-level PLAYING state (GameWorld normally does this first;
	# this guards direct scene loads).
	if GameState.current != GameState.State.PLAYING:
		GameState.transition(GameState.State.PLAYING)

	_game_world = get_node_or_null("..") as Node2D
	_hud = get_node_or_null("../HUD") as HUD
	if _game_world:
		var systems := _game_world.get_node_or_null("Systems")
		if systems:
			_ghost_sys = systems.get_node_or_null("GhostDrawSystem") as GhostDrawSystem

	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_GAME_TIMER_EXPIRED, _on_timer_expired)
	EventBus.on(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, _on_ghost_line_discovered)
	EventBus.on(EventBus.EV_GAME_ARGUMENT_STARTED, _on_argument_started)
	EventBus.on(EventBus.EV_GAME_COIN_DECIDED, _on_coin_decided)

	# The real match sub-state machine, driven like the multiplayer flow.
	_match_machine = MatchStateMachine.new()
	_match_machine.name = "MatchStateMachine"
	add_child(_match_machine)

	# The in-process mock ghost peer (id 2), configured from the home screen.
	_bot = GhostBotController.new()
	_bot.name = "GhostBot"
	_bot.difficulty = GameState.cpu_difficulty
	add_child(_bot)

	# Fresh match: clear totals/rounds carried over from the previous match
	# (audit m3) so score and statistics don't leak between matches.
	ScoringManager.reset_match()

	# Kick off the flow: NONE → LOBBY (prototype bootstrap) → DRAWING.
	_match_machine.transition_to(GameState.MatchState.LOBBY)
	_match_machine.transition_to(GameState.MatchState.DRAWING)
	# Shorten the auto-started "standard" timer to the solo "quick" duration.
	MatchTimer.start(SOLO_TIMER_KEY)
	print("SoloMatchDriver: round started — drawing %ds, timer %s, difficulty %d" % [
		SOLO_DRAWING_SECONDS, SOLO_TIMER_KEY, GameState.cpu_difficulty
	])


func _process(delta: float) -> void:
	if _ending:
		return
	var ms := GameState.get_match_state()
	if ms == GameState.MatchState.PAUSED:
		return
	if ms == GameState.MatchState.DRAWING:
		_drawing_elapsed += delta
		_tick_draw_phase()
		if _drawing_elapsed >= SOLO_DRAWING_SECONDS:
			_drawing_elapsed = 0.0
			_match_machine.transition_to(GameState.MatchState.MEETING)
			return
	if ms == GameState.MatchState.MEETING:
		_tick_meeting_phase(delta)
		return
	if _end_pending:
		_end_round()


## Emit per-second draw-phase ticks, plus the one-shot end-of-draw warning
## (visible + audible) when the phase enters its LAST 5 seconds. The shared
## MatchTimer warning (<=10s) is against the whole-match clock and never
## covers the DRAWING phase, so the driver owns the draw-phase clock itself.
func _tick_draw_phase() -> void:
	var remaining_abs := SOLO_DRAWING_SECONDS - _drawing_elapsed
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


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_TIMER_EXPIRED, _on_timer_expired)
	EventBus.off(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, _on_ghost_line_discovered)
	EventBus.off(EventBus.EV_GAME_ARGUMENT_STARTED, _on_argument_started)
	EventBus.off(EventBus.EV_GAME_COIN_DECIDED, _on_coin_decided)
	# The solo session owns the flag: leaving the game world ends solo mode so
	# a later normal/online match never spawns the bot.
	GameState.solo_vs_cpu = false


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)

	if to_state == GameState.MatchState.DRAWING:
		_in_searching = false
		_argument_started_count = 0
		_drawing_elapsed = 0.0
		_draw_warning_played = false
		_draw_phase_last_tick = -1
	elif to_state == GameState.MatchState.MEETING:
		_in_searching = false
		_argument_started_count = 0
		_meeting_elapsed = 0.0
		_meeting_call_made = false
		_meeting_resolved = false
		_meeting_result_hold = 0.0
		_assemble_at_alley()
		_show_coin_decider()
	elif to_state == GameState.MatchState.SEARCHING:
		_in_searching = true
		_argument_started_count = 0
		_free_coin_overlay()
		_spawn_search_entry()
		# Make the existing HUD ACCUSE flow work against the ghost: pre-select
		# the ghost entity as the target (HUD resets selection on SEARCHING
		# entry, so this must run after the HUD's own handler).
		if _hud:
			_hud.set_selected_target(GHOST_ENTITY_ID)
	elif from_state == GameState.MatchState.PAUSED:
		# An argument just resolved and resumed the match — fire any deferred
		# round end (the end conditions were met while the game was paused).
		if _end_pending:
			_end_round()


func _on_timer_expired(_payload: Dictionary) -> void:
	_end_round()


func _on_ghost_line_discovered(_payload: Dictionary) -> void:
	_maybe_end_round()


func _on_argument_started(_payload: Dictionary) -> void:
	_argument_started_count += 1
	_maybe_end_round()


# -- MEETING / coin phase ----------------------------------------------------------

## Meeting clock: the player gets MEETING_CALL_TIMEOUT_SECONDS to call the
## coin; after that the overlay auto-randomizes (round never hangs). Once the
## coin resolves, the big result banner holds COIN_RESULT_HOLD_SECONDS, then
## SEARCHING starts with the recorded roles.
func _tick_meeting_phase(delta: float) -> void:
	_meeting_elapsed += delta
	if _coin_overlay == null or not is_instance_valid(_coin_overlay):
		# Overlay missing (scene failed to load): never hang the round - decide
		# randomly at the hard cap and move on to SEARCHING.
		if _meeting_elapsed >= MEETING_MAX_SECONDS:
			_force_coin_decision()
		return
	if not _meeting_call_made and _meeting_elapsed >= MEETING_CALL_TIMEOUT_SECONDS:
		_meeting_call_made = true
		print("SoloMatchDriver: no call within %ds - coin auto-randomizes" % MEETING_CALL_TIMEOUT_SECONDS)
		_coin_overlay.auto_randomize()
	if _meeting_resolved:
		_meeting_result_hold += delta
		if _meeting_result_hold >= COIN_RESULT_HOLD_SECONDS:
			_begin_searching()
	elif _meeting_elapsed >= MEETING_MAX_SECONDS:
		# Absolute safety net: never stall the round.
		print("SoloMatchDriver: meeting exceeded %ds - forcing resolution" % MEETING_MAX_SECONDS)
		if not _meeting_call_made:
			_meeting_call_made = true
			_coin_overlay.auto_randomize()
		else:
			_coin_overlay.force_resolve()


## Walk both characters to their face-off spots at the alley (the player and
## the ghost's visible body, NPC entity 2). Camera follows the player, so it
## pans to the alley with them.
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


## Create the coin decider overlay (driver-owned, like the argument overlay).
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


## EV_GAME_COIN_DECIDED: record the roles decided by the coin toss.
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


## Last-resort decision when the decider overlay is missing: a FAIR 50/50
## toss (owner decision #2 - difficulty never influences who searches first).
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


## SEARCHING entry: point the searcher at the alley exit leading to the
## opponent's zone. MVP slice 2 keeps the playable human-search flow; when
## the CPU won the toss the roles are already recorded (active_searcher == 2)
## and the CPU-search half (CPU walking into the player zone + live
## strike-out) is the later zone+role swap slice (R6).
func _spawn_search_entry() -> void:
	var player: Node2D = _game_world.get_entity(HUMAN_ENTITY_ID) as Node2D if _game_world else null
	if player:
		_walk_entity_to(player, ZoneLayout.SEARCH_ENTRY_HUMAN)
	var npc: Node2D = _game_world.get_entity(GHOST_ENTITY_ID) as Node2D if _game_world else null
	if npc is NPC:
		npc.patrolling = true  # resume patrol (ghost returns toward its zone)


# ── Round end ────────────────────────────────────────────────────────────────

## Defer to _end_round unless the match is paused mid-argument or we are not
## in the active round states.
func _maybe_end_round() -> void:
	if _ending:
		return
	var ms := GameState.get_match_state()
	if ms == GameState.MatchState.PAUSED:
		_end_pending = true
		return
	if not _in_searching:
		return
	if _argument_started_count >= MAX_ACCUSATIONS_PER_ROUND or _all_ghost_lines_discovered():
		_end_round()


func _all_ghost_lines_discovered() -> bool:
	if not _ghost_sys:
		return false
	var lines := _ghost_sys.get_active_ghost_lines()
	if lines.is_empty():
		return false
	for line in lines:
		if not line.is_discovered:
			return false
	return true


func _end_round() -> void:
	if _ending:
		return
	if GameState.get_match_state() == GameState.MatchState.PAUSED:
		_end_pending = true
		return
	_ending = true
	_end_pending = false
	MatchTimer.stop()
	_free_coin_overlay()  # the round may end during MEETING (match timer)
	print("SoloMatchDriver: round ended")

	# SEARCHING → REVEAL (dramatic fog clear) → SCORING (round score +
	# statistics) → RETURN_TO_LOBBY (save) → MAIN_MENU (home screen).
	# DRAWING → SCORING is used instead when the round somehow ended early.
	var ms := GameState.get_match_state()
	if ms == GameState.MatchState.SEARCHING:
		_match_machine.transition_to(GameState.MatchState.REVEAL)
	_match_machine.transition_to(GameState.MatchState.SCORING)
	_match_machine.transition_to(GameState.MatchState.RETURN_TO_LOBBY)
	GameState.transition(GameState.State.MAIN_MENU)
