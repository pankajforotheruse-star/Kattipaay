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
var local_center := Vector3.ZERO
var local_radius := 0.0
static var chalk_material: StandardMaterial3D

func _ready() -> void:
	stroke_mesh = MeshInstance3D.new()
	stroke_mesh.name = "ChalkGeometry"
	add_child(stroke_mesh)
	rebuild_mesh()

func add_surface_point(world_position: Vector3, world_normal: Vector3, update_mesh: bool = true) -> void:
	var p := to_local(world_position)
	var n := (global_transform.basis.inverse() * world_normal).normalized()
	if not local_points.is_empty() and local_points[local_points.size() - 1].distance_to(p) < 0.015:
		return
	if local_points.is_empty():
		local_center = p
		local_radius = 0.0
	else:
		# Conservative, incremental bounding sphere. No mark is discarded.
		var delta := p.distance_to(local_center)
		if delta > local_radius:
			var enlarged := (local_radius + delta) * 0.5
			local_center += (p - local_center).normalized() * (enlarged - local_radius)
			local_radius = enlarged
	local_points.append(p)
	local_normals.append(n)
	if update_mesh:
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
	if chalk_material == null:
		chalk_material = StandardMaterial3D.new()
		chalk_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		chalk_material.albedo_color = Color(0.95, 0.92, 0.80, 1.0)
		chalk_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		chalk_material.no_depth_test = false
	stroke_mesh.material_override = chalk_material

func visible_to_eye(eye_position: Vector3, physics: PhysicsDirectSpaceState3D, max_distance: float = 12.0, viewer_rid: RID = RID()) -> bool:
	if local_points.is_empty() or struck:
		return false
	# Broad-phase before any physics raycast. Parent may be a moving cover,
	# so evaluate the cached sphere in world space each time.
	var scale := global_transform.basis.get_scale()
	var world_radius := local_radius * maxf(scale.x, maxf(scale.y, scale.z))
	if eye_position.distance_to(to_global(local_center)) > max_distance + world_radius:
		return false
	# Visibility is evaluated per visible stroke segment, not per entire mark
	# and not merely by one stored endpoint. Long strokes can be partly hidden.
	for i in range(local_points.size()):
		if _sample_point_visible(local_points[i], eye_position, physics, max_distance, viewer_rid):
			return true
		if i == 0:
			continue
		var a := local_points[i - 1]
		var b := local_points[i]
		var subdivisions := mini(64, maxi(1, ceili(a.distance_to(b) / 0.2)))
		for j in range(1, subdivisions):
			var p := a.lerp(b, float(j) / float(subdivisions))
			if _sample_point_visible(p, eye_position, physics, max_distance, viewer_rid):
				return true
	return false

func _sample_point_visible(p: Vector3, eye: Vector3, physics: PhysicsDirectSpaceState3D, max_distance: float, viewer_rid: RID) -> bool:
	var target := to_global(p)
	var dist := eye.distance_to(target)
	if dist > max_distance or dist < 0.02:
		return false
	var direction := (eye - target) / dist
	var query := PhysicsRayQueryParameters3D.create(eye, target + direction * 0.025)
	if viewer_rid.is_valid():
		query.exclude = [viewer_rid]
	var hit := physics.intersect_ray(query)
	if hit.is_empty():
		return true
	# A hit against the same surface only counts when it is at the actual chalk
	# sample, not when the wall itself hides a stroke on the far face.
	if get_parent() is CollisionObject3D and hit.get("collider") == get_parent():
		return (hit["position"] as Vector3).distance_to(target) < 0.12
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
	local_center = Vector3.ZERO
	local_radius = 0.0
	var raw_points: Array = data.get("points", [])
	var raw_normals: Array = data.get("normals", [])
	if raw_points.size() != raw_normals.size() or raw_points.size() > 10000:
		return false
	for i in range(raw_points.size()):
		var p: Array = raw_points[i]
		var n: Array = raw_normals[i]
		if p.size() != 3 or n.size() != 3:
			return false
		var point := Vector3(float(p[0]), float(p[1]), float(p[2]))
		var normal := Vector3(float(n[0]), float(n[1]), float(n[2])).normalized()
		add_surface_point(to_global(point), (global_transform.basis * normal).normalized(), false)
	rebuild_mesh()
	return true
