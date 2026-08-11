# GameWorld.gd — Root controller for the gameplay scene
# Manages the map, entities, camera, and HUD. The main entry point
# when the game transitions to PLAYING state.

class_name GameWorld
extends Node2D

# Registry of all active entities: { entity_id: Entity }
var entity_registry: Dictionary = {}
var _next_entity_id: int = 1

func _ready() -> void:
	print("GameWorld: _ready — registering entities")

	# Transition to PLAYING state (prototype: auto-start)
	if GameState.current != GameState.State.PLAYING:
		GameState.transition(GameState.State.PLAYING)

	# Find all entities in the scene and register them
	_register_existing_entities()

	# Listen for future entity spawn/despawn events
	EventBus.on(EventBus.EV_GAME_ENTITY_REGISTER, _on_entity_register)
	EventBus.on(EventBus.EV_GAME_ENTITY_UNREGISTER, _on_entity_unregister)

	# Emit that the world is ready
	EventBus.emit(EventBus.EV_GAME_WORLD_READY, {"entity_count": entity_registry.size()})

## Scan the scene tree for Entity nodes and register them.
func _register_existing_entities() -> void:
	var entities_container := get_node_or_null("Entities")
	if not entities_container:
		entities_container = self

	for child in entities_container.get_children():
		if child is Entity:
			_register_entity(child)

## Assign an ID and add to the registry.
func _register_entity(entity: Entity) -> void:
	if entity.entity_id == 0:
		entity.entity_id = _next_entity_id
		_next_entity_id += 1
	entity.set_meta("entity_id", entity.entity_id)
	entity_registry[entity.entity_id] = entity
	print("GameWorld: registered entity %d (%s)" % [entity.entity_id, entity.entity_type])

## Remove from registry.
func _unregister_entity(entity: Entity) -> void:
	entity_registry.erase(entity.entity_id)

## Get an entity by ID.
func get_entity(id: int) -> Entity:
	return entity_registry.get(id)

## Callbacks
func _on_entity_register(payload: Dictionary) -> void:
	var entity: Entity = payload.get("entity")
	if entity:
		_register_entity(entity)

func _on_entity_unregister(payload: Dictionary) -> void:
	var entity: Entity = payload.get("entity")
	if entity:
		_unregister_entity(entity)
