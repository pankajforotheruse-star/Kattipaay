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

## When set (non-empty), the camera frames this world rect instead of
## following the player. Used while the CPU searches the player zone so the
## defending player AND the CPU's strike targets stay in view (R6).
var overview_rect := Rect2()
var _target_zoom: float = 1.0

## Frame a world rect (overview mode). Pass an empty rect to clear.
func set_overview(rect: Rect2) -> void:
	overview_rect = rect

func clear_overview() -> void:
	overview_rect = Rect2()

func _ready() -> void:
	enabled = true
	make_current()

	if auto_find_player:
		_find_and_follow_local_player()

func _physics_process(delta: float) -> void:
	var target_pos: Vector2
	if overview_rect.size.x > 0.0 and overview_rect.size.y > 0.0:
		# Overview mode (CPU search): frame the whole rect + fit zoom so the
		# defending player and the CPU's strike targets stay in view.
		target_pos = overview_rect.get_center()
		var viewport_size := get_viewport().get_visible_rect().size
		var fit := minf(viewport_size.x / overview_rect.size.x, viewport_size.y / overview_rect.size.y)
		_target_zoom = clampf(fit * 0.92, 0.25, 1.0)
	else:
		if not follow_target or not is_instance_valid(follow_target):
			return
		target_pos = follow_target.position
		_target_zoom = 1.0

	position = position.lerp(target_pos, follow_speed * delta)
	zoom = zoom.lerp(Vector2(_target_zoom, _target_zoom), follow_speed * delta)

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
