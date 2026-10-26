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

	# Commit A (hiding): static scenery (ground-tint surfaces + compound walls)
	# drawn below entities. Geometry lives in HidingRules; this node only
	# renders it, so both zones show the same village layout to both sides.
	var scenery := SceneryLayer.new()
	scenery.name = "Scenery"
	add_child(scenery)
	move_child(scenery, 0)
	_align_wall_art_with_concealment_geometry()
	if GameState.solo_vs_cpu:
		# Shared, discoverable public cover. Creation precedes solo controllers
		# so both human and CPU search systems see the same inspection state.
		var covers := CoverSystem.new()
		covers.name = "CoverSystem"
		add_child(covers)
		# Defender physically shadows the striker instead of standing
		# magically in the middle of the zone throughout the search.
		var escort := DefenderEscort.new()
		escort.name = "DefenderEscort"
		add_child(escort)

	# The scene presets entity ids (Player=1, NPC1=2). Seed the allocator above
	# the highest registered id so later-spawned entities never collide with
	# preset scene entities (audit m12).
	_next_entity_id = _max_registered_entity_id() + 1

	# Listen for future entity spawn/despawn events
	EventBus.on(EventBus.EV_GAME_ENTITY_REGISTER, _on_entity_register)
	EventBus.on(EventBus.EV_GAME_ENTITY_UNREGISTER, _on_entity_unregister)

	# Emit that the world is ready
	EventBus.emit(EventBus.EV_GAME_WORLD_READY, {"entity_count": entity_registry.size()})

	# Solo "Play vs CPU": spawn the in-process ghost bot + match driver.
	# The home screen sets the flag; normal/online play never does.
	if GameState.solo_vs_cpu:
		_spawn_solo_match()

## Older WallA/B/C sprites were placed at unrelated coordinates while
## HidingRules used different concealment rectangles. Align the artwork with
## the very same authoritative wall geometry in both halves of the map.
## Collision/pathfinding is NOT introduced here: the CPU route needs its own
## obstacle-aware navigation before making these walls physically solid.
func _align_wall_art_with_concealment_geometry() -> void:
	var names := ["WallA", "WallB", "WallC"]
	var player_walls := HidingRules.get_zone_walls()
	var cpu_walls := HidingRules.get_cpu_walls()
	for i in range(mini(names.size(), player_walls.size())):
		_fit_wall_sprite("Props/PlayerZoneProps/" + names[i], player_walls[i])
	for i in range(mini(names.size(), cpu_walls.size())):
		_fit_wall_sprite("Props/CpuZoneProps/" + names[i], cpu_walls[i])


func _fit_wall_sprite(path: String, rect: Rect2) -> void:
	var sprite := get_node_or_null(path) as Sprite2D
	if sprite == null or sprite.texture == null:
		return
	var texture_size := Vector2(sprite.texture.get_size())
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return
	sprite.position = rect.get_center()
	sprite.scale = rect.size / texture_size


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_ENTITY_REGISTER, _on_entity_register)
	EventBus.off(EventBus.EV_GAME_ENTITY_UNREGISTER, _on_entity_unregister)

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

## Highest entity id currently registered (0 when the registry is empty).
func _max_registered_entity_id() -> int:
	var max_id := 0
	for id in entity_registry:
		if id > max_id:
			max_id = id
	return max_id

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

## Spawn the solo-match stack: the driver owns the round flow and creates the
## GhostBotController mock peer. Both free with the scene on exit.
func _spawn_solo_match() -> void:
	var driver := SoloMatchDriver.new()
	driver.name = "SoloMatchDriver"
	add_child(driver)
