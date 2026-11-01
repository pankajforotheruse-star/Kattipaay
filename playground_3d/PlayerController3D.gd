# Standalone experimental movement controller. Never replaces the current 2D player.
extends CharacterBody3D

@export var walk_speed: float = 5.0
@export var acceleration: float = 18.0
@export var friction: float = 22.0
@export var gravity_force: float = 20.0
@export var controllable: bool = true

func _physics_process(delta: float) -> void:
	var direction := Vector3.ZERO
	if controllable:
		direction.x = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
		direction.z = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	direction = direction.normalized()
	var target := direction * walk_speed
	var blend_rate := acceleration if direction.length_squared() > 0.0 else friction
	velocity.x = move_toward(velocity.x, target.x, blend_rate * delta)
	velocity.z = move_toward(velocity.z, target.z, blend_rate * delta)
	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = -0.05
	else:
		velocity.y -= gravity_force * delta
	move_and_slide()
