class_name CharacterRig3D
extends Node3D
## Lightweight animated human silhouette for the 3D vertical slice.
## Replace with licensed skeletal GLB + AnimationTree for final art.
var left_arm: Node3D
var right_arm: Node3D
var left_leg: Node3D
var right_leg: Node3D
var stride := 0.0
@export var opponent := false

func _ready() -> void:
	var cloth := _material(Color(0.20, 0.31, 0.37) if not opponent else Color(0.47, 0.21, 0.16))
	var skin := _material(Color(0.58, 0.40, 0.28))
	var trousers := _material(Color(0.24, 0.25, 0.23))
	var shoes := _material(Color(0.12, 0.11, 0.10))
	var hair := _material(Color(0.09, 0.08, 0.07))
	_part("Torso", _capsule(0.27, 0.78), Vector3(0, 0.08, 0), cloth, self)
	_part("Neck", _capsule(0.09, 0.19), Vector3(0, 0.51, 0), skin, self)
	_part("Head", _sphere(0.20), Vector3(0, 0.70, 0), skin, self)
	_part("Hair", _sphere(0.20), Vector3(0, 0.81, 0.025), hair, self)
	for side in [-1, 1]:
		var sign_side := float(side)
		_part("Eye", _sphere(0.023), Vector3(sign_side * 0.079, 0.72, -0.184), hair, self)
		var arm := Node3D.new()
		arm.position = Vector3(sign_side * 0.34, 0.34, 0)
		add_child(arm)
		_part("Sleeve", _capsule(0.105, 0.42), Vector3(0, -0.18, 0), cloth, arm)
		_part("Hand", _sphere(0.085), Vector3(0, -0.44, 0), skin, arm)
		var leg := Node3D.new()
		leg.position = Vector3(sign_side * 0.15, -0.28, 0)
		add_child(leg)
		_part("Trouser", _capsule(0.12, 0.50), Vector3(0, -0.25, 0), trousers, leg)
		_part("Shoe", _capsule(0.12, 0.22), Vector3(0, -0.54, -0.07), shoes, leg)
		if side < 0:
			left_arm = arm
			left_leg = leg
		else:
			right_arm = arm
			right_leg = leg

func _process(delta: float) -> void:
	var actor := get_parent() as CharacterBody3D
	if actor == null:
		return
	var horizontal := Vector3(actor.velocity.x, 0, actor.velocity.z)
	var pace := clampf(horizontal.length() / 5.0, 0.0, 1.5)
	if horizontal.length() > 0.15:
		var desired := atan2(-horizontal.x, -horizontal.z)
		rotation.y = lerp_angle(rotation.y, desired, 1.0 - exp(-10.0 * delta))
	stride += horizontal.length() * delta * 1.8
	var swing := sin(stride * 3.1) * 0.55 * minf(pace, 1.0)
	left_leg.rotation.x = swing
	right_leg.rotation.x = -swing
	left_arm.rotation.x = -swing * 0.8
	right_arm.rotation.x = swing * 0.8

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
