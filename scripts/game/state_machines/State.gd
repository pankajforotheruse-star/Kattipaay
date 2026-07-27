# State.gd — Abstract base class for all states
# Subclass this for every state in the game (game-level or entity-level).
# Uses RefCounted so states don't need to be freed manually.

class_name State
extends RefCounted

## Reference back to the StateMachine that owns this state.
## Set automatically by StateMachine.add_state().
var machine: StateMachine = null

## Called when entering this state. previous_state may be null on first entry.
func enter(_previous_state: State) -> void:
	pass

## Called when exiting this state. next_state is the state we're transitioning to.
func exit(_next_state: State) -> void:
	pass

## Called every frame (process). Override in subclasses that need per-frame logic.
func update(_delta: float) -> void:
	pass

## Called every physics frame. Override for movement/physics logic.
func physics_update(_delta: float) -> void:
	pass

## Called when an event is dispatched to the state machine.
## Return true if the state handled the event.
func handle_event(_event: String, _payload = null) -> bool:
	return false

## Returns the class name for debug output.
func get_state_name() -> String:
	return get_script().resource_path.get_file().get_basename()
