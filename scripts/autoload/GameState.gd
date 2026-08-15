# GameState.gd — Top-level game state machine singleton
# Tracks the current game state and validates transitions.
# All state changes flow through EventBus as EventBus.EV_GAME_STATE_CHANGED.
#
# Match sub-states (§MatchState) are active only when the top-level state is PLAYING.
# They are managed by MatchStateMachine, but the enum and validation table live here
# so all systems can reference them without coupling to the machine.

extends Node

# ── Top-Level States ────────────────────────────────────────────────────────

enum State {
    SPLASH,
    MAIN_MENU,
    LOBBY,
    PLAYING,
    PAUSED,
    GAME_OVER,
}

# ── Match Sub-States (only valid when top-level state == PLAYING) ───────────

enum MatchState {
    NONE,              # not in a match (default when not PLAYING)
    WAITING,           # players connected, loading, clock sync
    LOBBY,             # match lobby: loadout, ready-up, chat (distinct from top-level LOBBY)
    TEAM_SELECTION,    # competitive: pick Red/Blue teams
    DRAWING,           # active gameplay — draw chalk, trap ghosts
    SEARCHING,         # between-wave: find hidden shades, low visibility
    REVEAL,            # high-intensity climax: all ghosts visible, boss exposed
    SCORING,           # post-wave / post-match score tally
    WINNER,            # match concluded, declare winner, celebration
    SWAP_TEAMS,        # competitive rematch: swap sides
    RETURN_TO_LOBBY,   # cleanup, return to match lobby (or MAIN_MENU on quit)
    PAUSED,            # match-level pause (overlay, game world frozen)
}

# ── Top-Level Valid Transitions ─────────────────────────────────────────────

const VALID_TRANSITIONS: Dictionary = {
    State.SPLASH:    [State.MAIN_MENU, State.PLAYING],  # PLAYING allowed for prototype bootstrap
    State.MAIN_MENU: [State.LOBBY, State.MAIN_MENU, State.PLAYING],  # PLAYING for solo "Play vs CPU" (SPLASH->PLAYING prototype precedent)
    State.LOBBY:     [State.PLAYING, State.MAIN_MENU],
    State.PLAYING:   [State.PAUSED, State.GAME_OVER, State.MAIN_MENU],
    State.PAUSED:    [State.PLAYING, State.MAIN_MENU],
    State.GAME_OVER: [State.MAIN_MENU, State.LOBBY],
}

# ── Match Sub-State Valid Transitions ───────────────────────────────────────

const VALID_MATCH_TRANSITIONS: Dictionary = {
    MatchState.NONE:            [MatchState.WAITING, MatchState.LOBBY],  # LOBBY for prototype bootstrap
    MatchState.WAITING:         [MatchState.LOBBY, MatchState.RETURN_TO_LOBBY],
    MatchState.LOBBY:           [MatchState.TEAM_SELECTION, MatchState.DRAWING, MatchState.RETURN_TO_LOBBY],
    MatchState.TEAM_SELECTION:  [MatchState.DRAWING, MatchState.RETURN_TO_LOBBY],
    MatchState.DRAWING:         [MatchState.SEARCHING, MatchState.SCORING, MatchState.PAUSED, MatchState.RETURN_TO_LOBBY],
    MatchState.SEARCHING:       [MatchState.REVEAL, MatchState.DRAWING, MatchState.PAUSED, MatchState.RETURN_TO_LOBBY],
    MatchState.REVEAL:          [MatchState.DRAWING, MatchState.SCORING, MatchState.PAUSED, MatchState.RETURN_TO_LOBBY],
    MatchState.SCORING:         [MatchState.DRAWING, MatchState.WINNER, MatchState.RETURN_TO_LOBBY],
    MatchState.WINNER:          [MatchState.SWAP_TEAMS, MatchState.RETURN_TO_LOBBY],
    MatchState.SWAP_TEAMS:      [MatchState.LOBBY, MatchState.RETURN_TO_LOBBY],
    MatchState.RETURN_TO_LOBBY: [MatchState.WAITING],
    MatchState.PAUSED:          [MatchState.DRAWING, MatchState.SEARCHING, MatchState.REVEAL, MatchState.RETURN_TO_LOBBY],
}

# Shortcut: every match state can transition to RETURN_TO_LOBBY on disconnect.
# This is enforced in _is_match_transition_valid() rather than listed per-state above,
# but we list it explicitly for clarity and allow the validation logic to handle it.

# ── State Variables ──────────────────────────────────────────────────────────

var current: int = State.SPLASH
var previous: int = State.SPLASH

## Match sub-state (only meaningful when current == State.PLAYING).
var current_match: int = MatchState.NONE
var previous_match: int = MatchState.NONE

## Remembers which match state we were in before PAUSED.
var pre_pause_match: int = MatchState.NONE

## Solo "Play vs CPU" mode flag. Set by the home screen before entering
## PLAYING; when true, GameWorld spawns the GhostBotController mock peer and
## the SoloMatchDriver. Cleared when the solo match ends (driver _exit_tree).
var solo_vs_cpu: bool = false

## CPU difficulty for solo mode (GhostBotController.Difficulty enum value).
var cpu_difficulty: int = GhostBotController.Difficulty.NORMAL

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
    current = State.SPLASH
    current_match = MatchState.NONE

# ── Top-Level State Transitions ──────────────────────────────────────────────

## Attempt a state transition. Returns true if valid and executed.
func transition(to: int) -> bool:
    if not _is_valid(current, to):
        push_warning("GameState: invalid transition %s → %s" % [_state_name(current), _state_name(to)])
        return false

    var from := current
    previous = from
    current = to

    # Reset match state when leaving the match context entirely
    if to == State.MAIN_MENU or to == State.GAME_OVER:
        _reset_match_state()

    EventBus.emit(EventBus.EV_GAME_STATE_CHANGED, {
        "from": from,
        "to": to,
    })

    print("GameState: %s → %s" % [_state_name(from), _state_name(to)])
    return true

## Force a state (bypasses validation — use only for reset/debug).
func force_state(to: int) -> void:
    previous = current
    current = to
    if to != State.PLAYING and to != State.PAUSED:
        _reset_match_state()
    EventBus.emit(EventBus.EV_GAME_STATE_CHANGED, {"from": previous, "to": to})

# ── Match Sub-State Transitions ──────────────────────────────────────────────

## Transition to a new match sub-state. Validates and emits events.
## Only valid when top-level state is PLAYING (or PAUSED for the PAUSED match state).
func enter_match_state(to: int) -> bool:
    if current != State.PLAYING and to != MatchState.NONE:
        push_warning("GameState: enter_match_state(%s) called when top-level state is %s" % [_match_state_name(to), _state_name(current)])
        return false

    if not _is_match_transition_valid(current_match, to):
        push_warning("GameState: invalid match transition %s → %s" % [_match_state_name(current_match), _match_state_name(to)])
        return false

    var from := current_match
    previous_match = from

    # Handle PAUSED entry/exit
    if to == MatchState.PAUSED:
        pre_pause_match = from
    elif from == MatchState.PAUSED:
        # Exiting PAUSED — pre_pause_match is cleared after transition
        pass

    current_match = to

    EventBus.emit(EventBus.EV_MATCH_STATE_CHANGED, {
        "from": from,
        "to": to,
        "from_name": _match_state_name(from),
        "to_name": _match_state_name(to),
    })

    print("GameState: match %s → %s" % [_match_state_name(from), _match_state_name(to)])
    return true

## Return the current match sub-state.
func get_match_state() -> int:
    return current_match

## Return the match state we were in before PAUSED (NONE if not paused).
func get_pre_pause_match_state() -> int:
    return pre_pause_match

# ── Convenience Queries ──────────────────────────────────────────────────────

func is_playing() -> bool:
    return current == State.PLAYING

func is_paused() -> bool:
    return current == State.PAUSED

func is_match_paused() -> bool:
    return current_match == MatchState.PAUSED

func is_in_match() -> bool:
    return current == State.PLAYING and current_match != MatchState.NONE

# ── Validation ───────────────────────────────────────────────────────────────

func _is_valid(from: int, to: int) -> bool:
    if not VALID_TRANSITIONS.has(from):
        return false
    return to in VALID_TRANSITIONS[from]

func _is_match_transition_valid(from: int, to: int) -> bool:
    # Special case: from NONE, only allow WAITING
    if from == MatchState.NONE:
        return to in [MatchState.WAITING, MatchState.LOBBY]  # LOBBY for prototype bootstrap

    # Global escape: any match state can transition to RETURN_TO_LOBBY (disconnect, quit)
    if to == MatchState.RETURN_TO_LOBBY:
        return true

    if not VALID_MATCH_TRANSITIONS.has(from):
        return false
    return to in VALID_MATCH_TRANSITIONS[from]

# ── Helpers ──────────────────────────────────────────────────────────────────

func _state_name(s: int) -> String:
    return State.keys()[s]

func _match_state_name(s: int) -> String:
    return MatchState.keys()[s]

func _reset_match_state() -> void:
    previous_match = current_match
    current_match = MatchState.NONE
    pre_pause_match = MatchState.NONE
    # Broadcast the reset so EV_MATCH_STATE_CHANGED listeners see it.
    # MatchStateMachine caches current_state, and without this event the
    # cache goes stale after returning to MAIN_MENU, so the next match's
    # exit callbacks fire for the wrong old state (audit m9). Payload shape
    # matches enter_match_state() (from/to plus names).
    EventBus.emit(EventBus.EV_MATCH_STATE_CHANGED, {
        "from": previous_match,
        "to": current_match,
        "from_name": _match_state_name(previous_match),
        "to_name": _match_state_name(current_match),
    })
