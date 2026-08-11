# MatchStateMachine.gd — Match-level sub-state machine
#
# Manages the 10 match sub-states (WAITING through RETURN_TO_LOBBY)
# independently from the top-level GameState machine.
#
# This machine lives inside game_world.tscn as a child node.
# It validates every transition using GameState's validation table,
# emits events through EventBus, and provides entry/exit hooks
# that can be overridden for state-specific behaviour.
#
# DESIGN:
#   - Uses GameState.VALID_MATCH_TRANSITIONS for validation
#   - Delegates to GameState.enter_match_state() for state tracking
#   - Entry callbacks fire AFTER the transition commits
#   - Exit callbacks fire BEFORE the transition commits
#   - Disconnection from any state routes to RETURN_TO_LOBBY → MAIN_MENU

class_name MatchStateMachine
extends Node

## Maps MatchState enum values to entry callbacks: { MatchState.XXX: Callable }
var _entry_callbacks: Dictionary = {}

## Maps MatchState enum values to exit callbacks: { MatchState.XXX: Callable }
var _exit_callbacks: Dictionary = {}

## The current match state (cached from GameState for quick access).
var current_state: int = GameState.MatchState.NONE

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Listen for disconnection — route to RETURN_TO_LOBBY
	EventBus.on(EventBus.EV_NETWORK_DISCONNECTED, _on_disconnected)
	# Listen for match state changes (from ourselves or external sources)
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed_internal)

func _exit_tree() -> void:
	EventBus.off(EventBus.EV_NETWORK_DISCONNECTED, _on_disconnected)
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed_internal)

# ── Public API ───────────────────────────────────────────────────────────────

## Transition to a new match sub-state.
## Returns true if the transition was valid and executed.
func transition_to(to: int, event_data = null) -> bool:
	var from := current_state

	# Guard: no-op if already in that state
	if from == to:
		return true

	# Fire exit callback for the current state
	_fire_exit(from, to, event_data)

	# Attempt the transition through GameState (validation lives there)
	if not GameState.enter_match_state(to):
		push_warning("MatchStateMachine: transition %s → %s rejected" % [
			_match_name(from), _match_name(to)
		])
		return false

	# GameState.enter_match_state will emit match.state_changed,
	# which _on_match_state_changed_internal handles to fire entry callbacks.
	return true

## Register an entry callback for a match state.
## callback signature: func(state: int, previous_state: int, event_data)
func on_enter(state: int, callback: Callable) -> void:
	_entry_callbacks[state] = callback

## Register an exit callback for a match state.
## callback signature: func(state: int, next_state: int, event_data)
func on_exit(state: int, callback: Callable) -> void:
	_exit_callbacks[state] = callback

## Force transition to RETURN_TO_LOBBY (called on disconnect, match abort, etc.)
func abort_to_lobby(reason: String = "") -> void:
	print("MatchStateMachine: aborting to lobby. Reason: %s" % reason)
	# Force the transition — RETURN_TO_LOBBY is always valid from any state
	GameState.enter_match_state(GameState.MatchState.RETURN_TO_LOBBY)

## Force transition back to MAIN_MENU (full quit from match).
func quit_to_menu() -> void:
	print("MatchStateMachine: quitting to main menu")
	GameState.enter_match_state(GameState.MatchState.RETURN_TO_LOBBY)
	# After cleanup, transition top-level to MAIN_MENU
	# This is typically handled by the RETURN_TO_LOBBY entry logic,
	# but we also trigger the top-level transition here.
	await get_tree().create_timer(0.1).timeout  # let the match state change process
	GameState.transition(GameState.State.MAIN_MENU)

## Convenience: start the match flow from the beginning (WAITING state).
func start_match_flow() -> void:
	transition_to(GameState.MatchState.WAITING)

# ── Internal ─────────────────────────────────────────────────────────────────

## React to match.state_changed events (fired by GameState.enter_match_state).
## We use this to decouple the entry callback from the transition call site.
func _on_match_state_changed_internal(payload: Dictionary) -> void:
	var to: int = payload.get("to", -1)
	var from: int = payload.get("from", -1)

	# Update cached state
	current_state = to

	# Fire entry callback for the new state
	_fire_entry(to, from, payload)

## Fire the entry callback registered for a state.
func _fire_entry(state: int, previous: int, event_data) -> void:
	if _entry_callbacks.has(state):
		var cb: Callable = _entry_callbacks[state]
		cb.call(state, previous, event_data)

## Fire the exit callback registered for a state.
func _fire_exit(state: int, next_state: int, event_data) -> void:
	if _exit_callbacks.has(state):
		var cb: Callable = _exit_callbacks[state]
		cb.call(state, next_state, event_data)

# ── Event Handlers ───────────────────────────────────────────────────────────

## Called when the network disconnects mid-match.
func _on_disconnected(payload: Dictionary) -> void:
	# Only act if we're in a match
	if not GameState.is_in_match() and not GameState.is_match_paused():
		return

	var reason := payload.get("reason", "unknown") as String
	print("MatchStateMachine: disconnected during match (%s)" % reason)
	abort_to_lobby(reason)

# ── Debug Helpers ────────────────────────────────────────────────────────────

func _match_name(state: int) -> String:
	return GameState.MatchState.keys()[state] if state >= 0 and state < GameState.MatchState.size() else "UNKNOWN"
