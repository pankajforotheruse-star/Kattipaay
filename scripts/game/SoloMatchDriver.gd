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

const SOLO_DRAWING_SECONDS := 20.0
const SOLO_TIMER_KEY := "quick"         # 180s match timer (auto-start is "standard")
const GHOST_ENTITY_ID := 2
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
		if _drawing_elapsed >= SOLO_DRAWING_SECONDS:
			_drawing_elapsed = 0.0
			_match_machine.transition_to(GameState.MatchState.SEARCHING)
			return
	if _end_pending:
		_end_round()


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_TIMER_EXPIRED, _on_timer_expired)
	EventBus.off(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, _on_ghost_line_discovered)
	EventBus.off(EventBus.EV_GAME_ARGUMENT_STARTED, _on_argument_started)
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
	elif to_state == GameState.MatchState.SEARCHING:
		_in_searching = true
		_argument_started_count = 0
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
