# Camera.gd — Smooth-follow Camera2D for the game world
# Follows the local player entity with configurable smoothing.

class_name GameCamera
extends Camera2D

## The entity this camera follows (set in _ready via auto-find).
@export var follow_target: Node2D = null

## Smoothing speed (higher = snappier).
@export var follow_speed: float = 5.0

## If true, camera automatically finds the local player.
@export var auto_find_player: bool = true

func _ready() -> void:
	enabled = true
	make_current()

	if auto_find_player:
		_find_and_follow_local_player()

func _physics_process(delta: float) -> void:
	if not follow_target or not is_instance_valid(follow_target):
		return

	var target_pos := follow_target.position
	position = position.lerp(target_pos, follow_speed * delta)

func _find_and_follow_local_player() -> void:
	# Walk the scene tree to find the local player
	var root := get_tree().current_scene
	if not root:
		return

	_find_player_recursive(root)

func _find_player_recursive(node: Node) -> void:
	if follow_target:
		return
	for child in node.get_children():
		if child is Player and child.is_local:
			follow_target = child
			print("Camera: following player %d" % child.entity_id)
			return
		_find_player_recursive(child)
