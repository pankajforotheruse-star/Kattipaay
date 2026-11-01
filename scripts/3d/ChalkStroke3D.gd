class_name ChalkStroke3D
extends Node3D
## Versioned 3D chalk stroke attached to a physical drawing surface.
## This model deliberately does not modify the original 2D ChalkLine resource.
signal created(stroke: ChalkStroke3D)

var owner_id: int = -1
var stroke_id: int = -1
var surface_id: String = ""
var local_points: PackedVector3Array = PackedVector3Array()
var local_normals: PackedVector3Array = PackedVector3Array()
var width_m: float = 0.06
var discovered: bool = false
var struck: bool = false
var is_sneak: bool = false
var stroke_mesh: MeshInstance3D

func _ready() -> void:
	stroke_mesh = MeshInstance3D.new()
	stroke_mesh.name = "ChalkGeometry"
	add_child(stroke_mesh)
	rebuild_mesh()

func add_surface_point(world_position: Vector3, world_normal: Vector3) -> void:
	var p := to_local(world_position)
	var n := (global_transform.basis.inverse() * world_normal).normalized()
	if not local_points.is_empty() and local_points[local_points.size() - 1].distance_to(p) < 0.015:
		return
	local_points.append(p)
	local_normals.append(n)
	rebuild_mesh()

func rebuild_mesh() -> void:
	if stroke_mesh == null or local_points.size() < 2:
		return
	var output := ImmediateMesh.new()
	output.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, local_points.size()):
		var a := local_points[i - 1]
		var b := local_points[i]
		var n := local_normals[i].normalized()
		var tangent := (b - a).normalized()
		var lateral := tangent.cross(n).normalized()
		if lateral.length_squared() < 0.01:
			continue
		var half := width_m * 0.5
		var offset := n * 0.012
		var v0 := a - lateral * half + offset
		var v1 := a + lateral * half + offset
		var v2 := b - lateral * half + offset
		var v3 := b + lateral * half + offset
		for point in [v0, v1, v2, v2, v1, v3]:
			output.surface_set_normal(n)
			output.surface_add_vertex(point)
	output.surface_end()
	stroke_mesh.mesh = output
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.95, 0.92, 0.80, 1.0)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	stroke_mesh.material_override = material

func visible_to_eye(eye_position: Vector3, physics: PhysicsDirectSpaceState3D, max_distance: float = 12.0) -> bool:
	if local_points.is_empty() or struck:
		return false
	for local_point in local_points:
		var world_point := to_global(local_point)
		if eye_position.distance_to(world_point) > max_distance:
			continue
		var query := PhysicsRayQueryParameters3D.create(eye_position, world_point + (eye_position - world_point).normalized() * 0.025)
		var hit := physics.intersect_ray(query)
		if hit.is_empty():
			return true
		# A collider on the stroke's own parent surface is expected at the endpoint.
		if get_parent() is CollisionObject3D and hit.get("collider") == get_parent():
			return true
	return false

func to_save_dict() -> Dictionary:
	var packed_points: Array[Array] = []
	var packed_normals: Array[Array] = []
	for p in local_points:
		packed_points.append([p.x, p.y, p.z])
	for n in local_normals:
		packed_normals.append([n.x, n.y, n.z])
	return {"version": 1, "owner": owner_id, "id": stroke_id, "surface": surface_id,
		"points": packed_points, "normals": packed_normals, "width": width_m,
		"discovered": discovered, "struck": struck, "sneak": is_sneak}

func from_save_dict(data: Dictionary) -> bool:
	if int(data.get("version", 0)) != 1:
		return false
	owner_id = int(data.get("owner", -1))
	stroke_id = int(data.get("id", -1))
	surface_id = str(data.get("surface", ""))
	width_m = clampf(float(data.get("width", 0.06)), 0.01, 0.25)
	discovered = bool(data.get("discovered", false))
	struck = bool(data.get("struck", false))
	is_sneak = bool(data.get("sneak", false))
	local_points.clear()
	local_normals.clear()
	var raw_points: Array = data.get("points", [])
	var raw_normals: Array = data.get("normals", [])
	if raw_points.size() != raw_normals.size() or raw_points.size() > 10000:
		return false
	for i in range(raw_points.size()):
		var p: Array = raw_points[i]
		var n: Array = raw_normals[i]
		if p.size() != 3 or n.size() != 3:
			return false
		local_points.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		local_normals.append(Vector3(float(n[0]), float(n[1]), float(n[2])).normalized())
	rebuild_mesh()
	return true
