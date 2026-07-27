# MovementSystem.gd — Reactive system that translates input events into entity movement
# Subscribes to EventBus for "input.move_command_world" and applies targets to entities.
# In the full game, this also handles network forwarding and validation.

class_name MovementSystem
extends Node

## Reference to the GameWorld (found in _ready).
var _game_world: GameWorld = null

func _ready() -> void:
	EventBus.on("input.move_command_world", _on_move_command)
	# Find GameWorld directly from the scene tree (reliable, no race condition)
	_game_world = get_tree().current_scene as GameWorld
	if not _game_world:
		push_warning("MovementSystem: GameWorld not found in current scene")

func _on_move_command(payload: Dictionary) -> void:
	var entity_id: int = payload.get("entity_id", 0)
	var target: Vector2 = payload.get("target", Vector2.ZERO)

	if not _game_world:
		return

	var entity := _game_world.get_entity(entity_id)
	if not entity:
		return

	# Set target on entity (picked up by its state machine)
	entity.set_meta("target_position", target)
	entity.set_meta("has_target", true)

	# If online and we are a client, forward to server
	if NetworkManager.is_online() and not NetworkManager.has_authority():
		NetworkManager.send_rpc("player.move", {
			"entity_id": entity_id,
			"target": {"x": target.x, "y": target.y},
		})
