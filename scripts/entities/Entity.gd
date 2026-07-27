# Entity.gd — Base class for all game entities
# NOT used directly; subclass for Player, NPC, etc.
# Provides common metadata and registration with EntityRegistry.

class_name Entity
extends CharacterBody2D

## Unique entity ID (assigned by GameWorld on spawn).
@export var entity_id: int = 0

## Entity type for filtering: "player", "npc", "projectile", etc.
@export var entity_type: String = "unknown"

## Movement speed (overridden by subclasses).
@export var move_speed: float = 200.0

func _ready() -> void:
	# Store speed in meta so states can read it without referencing the script
	set_meta("move_speed", move_speed)
	set_meta("entity_id", entity_id)
	set_meta("entity_type", entity_type)

func get_entity_id() -> int:
	return entity_id
