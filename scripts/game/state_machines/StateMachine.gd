# StateMachine.gd — Generic hierarchical state machine
# Add states with add_state(), then transition_to() to run them.
# Attach as a child of the entity/scene that owns it.

class_name StateMachine
extends Node

## The currently active state.
var current_state: State = null

## All registered states: { "state_name": State instance }
var states: Dictionary = {}

## The previous state (for re-entry logic).
var previous_state: State = null

## Register a state by name. The state's .machine is set to this.
func add_state(name: String, state_obj: State) -> void:
	state_obj.machine = self
	states[name] = state_obj

## Transition to a named state. No-op if already in that state.
func transition_to(state_name: String, event_data = null) -> void:
	if not states.has(state_name):
		push_error("StateMachine: unknown state '%s'. Available: %s" % [state_name, states.keys()])
		return

	var next_state: State = states[state_name]
	if current_state == next_state:
		return

	if current_state:
		current_state.exit(next_state)

	previous_state = current_state
	current_state = next_state
	current_state.enter(previous_state)

	# Notify via EventBus so other systems (UI, network, etc.) can react
	EventBus.emit("entity.state_changed", {
		"node": owner,
		"previous": previous_state.get_state_name() if previous_state else "none",
		"current": current_state.get_state_name(),
	})

## Dispatch an event to the current state.
func handle_event(event: String, payload = null) -> void:
	if current_state:
		current_state.handle_event(event, payload)

func _process(delta: float) -> void:
	if current_state:
		current_state.update(delta)

func _physics_process(delta: float) -> void:
	if current_state:
		current_state.physics_update(delta)

## Get the name of the current state (or "none").
func current_state_name() -> String:
	if current_state:
		return current_state.get_state_name()
	return "none"
