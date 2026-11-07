class_name CharacterStep3D
extends RefCounted
## Collision-tested 0.32m step-up for capsule walkers at small roof/ramp lips.
## Never jumps a gap, teleports through a wall or bypasses a roof collider.
static func try_step(actor: CharacterBody3D, horizontal_motion: Vector3, step_height: float = 0.32) -> bool:
	if actor == null or horizontal_motion.length_squared() < 0.00001:
		return false
	var rise := Vector3.UP * step_height
	var before := actor.global_transform
	# Reject overhead collision and any blocked forward move at elevated height.
	if actor.test_move(before, rise):
		return false
	var elevated := before.translated(rise)
	if actor.test_move(elevated, horizontal_motion):
		return false
	var target := elevated.origin + horizontal_motion
	var ground_ray := PhysicsRayQueryParameters3D.create(
		target + Vector3.UP * 0.15, target - Vector3.UP * 1.25)
	ground_ray.exclude = [actor.get_rid()]
	var ground := actor.get_world_3d().direct_space_state.intersect_ray(ground_ray)
	if ground.is_empty() or (ground["normal"] as Vector3).y < 0.65:
		return false
	# Both moves are individually collision-tested and the ground probe
	# verifies support. CharacterBody3D handles gravity/snap next tick.
	actor.global_position += rise
	actor.move_and_collide(horizontal_motion)
	return true
