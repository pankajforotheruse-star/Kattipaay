class_name CharacterRig3D
extends Node3D
## Lightweight animated human silhouette for the 3D vertical slice.
## Replace with licensed skeletal GLB + AnimationTree for final art.
var left_arm: Node3D
var right_arm: Node3D
var left_leg: Node3D
var right_leg: Node3D
var stride := 0.0
var breathing := 0.0
var animation_blend := 0.0
var pose := "idle"
var pose_timer := 0.0
var torso: Node3D
var head: Node3D
var visual_root: Node3D
@export var opponent := false

func _ready() -> void:
	visual_root = Node3D.new()
	visual_root.name = "AnimatedBody"
	add_child(visual_root)
	torso = Node3D.new()
	torso.name = "UpperBody"
	visual_root.add_child(torso)
	head = Node3D.new()
	head.name = "HeadLook"
	torso.add_child(head)
	var cloth := _material(Color(0.20, 0.31, 0.37) if not opponent else Color(0.47, 0.21, 0.16))
	var skin := _material(Color(0.58, 0.40, 0.28))
	var trousers := _material(Color(0.24, 0.25, 0.23))
	var shoes := _material(Color(0.12, 0.11, 0.10))
	var hair := _material(Color(0.09, 0.08, 0.07))
	_part("Torso", _capsule(0.27, 0.78), Vector3(0, 0.08, 0), cloth, torso)
	_part("Neck", _capsule(0.09, 0.19), Vector3(0, 0.51, 0), skin, torso)
	_part("Head", _sphere(0.20), Vector3(0, 0.70, 0), skin, head)
	_part("Hair", _sphere(0.20), Vector3(0, 0.81, 0.025), hair, head)
	for side in [-1, 1]:
		var sign_side := float(side)
		_part("Eye", _sphere(0.023), Vector3(sign_side * 0.079, 0.72, -0.184), hair, head)
		var arm := Node3D.new()
		arm.position = Vector3(sign_side * 0.34, 0.34, 0)
		torso.add_child(arm)
		_part("Sleeve", _capsule(0.105, 0.42), Vector3(0, -0.18, 0), cloth, arm)
		_part("Hand", _sphere(0.085), Vector3(0, -0.44, 0), skin, arm)
		var leg := Node3D.new()
		leg.position = Vector3(sign_side * 0.15, -0.28, 0)
		visual_root.add_child(leg)
		_part("Trouser", _capsule(0.12, 0.50), Vector3(0, -0.25, 0), trousers, leg)
		_part("Shoe", _capsule(0.12, 0.22), Vector3(0, -0.54, -0.07), shoes, leg)
		if side < 0:
			left_arm = arm
			left_leg = leg
		else:
			right_arm = arm
			right_leg = leg

## Stateful procedural animation blends locomotion, crouch, search, chalk
## drawing, strike and argument gestures without per-frame mesh allocations.
## A licensed skeletal character can replace this visual-only rig later.
func set_pose(action: String, seconds: float = 0.35) -> void:
	pose = action
	pose_timer = maxf(seconds, 0.0)

func _process(delta: float) -> void:
	var actor := get_parent() as CharacterBody3D
	if actor == null:
		return
	var horizontal := Vector3(actor.velocity.x, 0, actor.velocity.z)
	var speed := horizontal.length()
	var pace := clampf(speed / 5.0, 0.0, 1.5)
	animation_blend = lerpf(animation_blend, pace, 1.0 - exp(-8.0 * delta))
	if speed > 0.15:
		var desired := atan2(-horizontal.x, -horizontal.z)
		rotation.y = lerp_angle(rotation.y, desired, 1.0 - exp(-10.0 * delta))
	stride += speed * delta * 1.8
	breathing += delta * 1.65
	var swing := sin(stride * 3.1) * 0.54 * minf(animation_blend, 1.0)
	var crouching := Input.is_key_pressed(KEY_C) and not opponent
	var crouch_amount := 1.0 if crouching else 0.0
	visual_root.position.y = lerpf(visual_root.position.y,
		-0.36 * crouch_amount + 0.035 * sin(stride * 6.2) * minf(animation_blend, 1.0),
		1.0 - exp(-12.0 * delta))
	torso.rotation.x = lerpf(torso.rotation.x, 0.19 * crouch_amount, 1.0 - exp(-8.0 * delta))
	torso.scale.y = 1.0 + sin(breathing) * 0.008
	head.rotation.y = lerpf(head.rotation.y, sin(breathing * 0.5) * 0.08, 1.0 - exp(-3.0 * delta))
	left_leg.rotation.x = lerpf(left_leg.rotation.x, swing + crouch_amount * 0.24, 1.0 - exp(-12.0 * delta))
	right_leg.rotation.x = lerpf(right_leg.rotation.x, -swing + crouch_amount * 0.24, 1.0 - exp(-12.0 * delta))
	var left_target := -swing * 0.78
	var right_target := swing * 0.78
	if pose_timer > 0.0:
		pose_timer -= delta
		match pose:
			"draw":
				right_target = -1.15 + sin(breathing * 9.0) * 0.12
				left_target = -0.25
			"inspect":
				right_target = -0.9
				left_target = -0.5
			"strike":
				right_target = -1.6 + sin((0.35 - pose_timer) * 15.0) * 0.5
			"argue":
				right_target = -1.2 + sin(breathing * 7.0) * 0.4
				left_target = -0.9
			"coin":
				right_target = -0.9
	else:
		pose = "idle"
	left_arm.rotation.x = lerpf(left_arm.rotation.x, left_target, 1.0 - exp(-12.0 * delta))
	right_arm.rotation.x = lerpf(right_arm.rotation.x, right_target, 1.0 - exp(-12.0 * delta))

func _part(label: String, shape: Mesh, at: Vector3, paint: Material, parent_node: Node3D) -> void:
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = shape
	instance.position = at
	instance.material_override = paint
	parent_node.add_child(instance)

func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.0)
	return mesh

func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	return mesh

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.91
	return mat
