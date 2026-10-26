# DefenderEscort.gd — childhood "walk beside the striker and supervise" loop.
# The defender follows the active striker, never teleports to hidden marks.
# Human defender may tap to override assisted follow; assistant resumes after
# a short idle period. This is not a sneaking/cheating mechanic.
class_name DefenderEscort
extends Node

const HUMAN := 1
const CPU := 2
const WATCH_DISTANCE := 115.0
const FOLLOW_START_DISTANCE := 165.0
const MANUAL_CONTROL_SECONDS := 3.0

var _world: GameWorld = null
var _defender_id: int = -1
var _searcher_id: int = -1
var _manual_override: float = 0.0

func _ready() -> void:
	_world = get_parent() as GameWorld
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_started)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_ended)
	EventBus.on(EventBus.EV_INPUT_MOVE_START, _on_human_move)

func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_started)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_ended)
	EventBus.off(EventBus.EV_INPUT_MOVE_START, _on_human_move)

func _on_search_started(payload: Dictionary) -> void:
	_searcher_id = int(payload.get("searcher", -1))
	_defender_id = int(payload.get("defender", -1))
	_manual_override = 2.0

func _on_search_ended(_payload: Dictionary) -> void:
	_defender_id = -1
	_searcher_id = -1

func _on_human_move(payload: Dictionary) -> void:
	if _defender_id == HUMAN and int(payload.get("entity_id", -1)) == HUMAN:
		_manual_override = MANUAL_CONTROL_SECONDS

func _process(delta: float) -> void:
	if not GameState.solo_vs_cpu or _defender_id < 0 or _searcher_id < 0:
		return
	if GameState.current == GameState.State.PAUSED \
			or GameState.get_match_state() != GameState.MatchState.SEARCHING:
		return
	_manual_override = maxf(0.0, _manual_override - delta)
	if _defender_id == HUMAN and _manual_override > 0.0:
		return
	var defender := _world.get_entity(_defender_id) as CharacterBody2D
	var searcher := _world.get_entity(_searcher_id) as CharacterBody2D
	if defender == null or searcher == null:
		return
	if defender.global_position.distance_to(searcher.global_position) < FOLLOW_START_DISTANCE:
		return
	# Follow from where we actually stand, without consulting any hidden
	# line coordinates. The searcher's previous motion dictates the offset.
	var behind := defender.global_position - searcher.global_position
	if behind.length_squared() < 1.0:
		behind = Vector2(-1, 0)
	var goal := searcher.global_position + behind.normalized() * WATCH_DISTANCE
	var zone := ZoneLayout.PLAYER_ZONE if _defender_id == HUMAN else ZoneLayout.CPU_ZONE
	goal = ZoneLayout.clamp_to_zone(goal, zone)
	defender.set_meta("target_position", goal)
	defender.set_meta("has_target", true)
	var state: EntityStateMachine = defender.get_node_or_null("EntityStateMachine") as EntityStateMachine
	if state and state.current_state_name() != "walking":
		state.transition_to("walking")
