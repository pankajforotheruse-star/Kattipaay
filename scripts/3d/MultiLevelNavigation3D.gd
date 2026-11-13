class_name MultiLevelNavigation3D
extends RefCounted
## Hybrid multilevel route graph for the physical village. Ground obstacles
## remain in GroundNavigation3D; each roof has its own NavigationRegion3D.
## Only validated, walkable ramp transitions join the levels. No teleporting,
## wall climbing or fabricated ladder/ledge traversal.
const AGENT_HEIGHT := 1.7
const MIN_WALKABLE_NORMAL_Y := 0.68
var root: Node3D
var zone: int
var ground: GroundNavigation3D
var transitions: Array[Dictionary] = []
var rejected_transitions: Array[String] = []
var ignored_rids: Array[RID] = []

func build(world_root: Node3D, physics: PhysicsDirectSpaceState3D, target_zone: int, ground_graph: GroundNavigation3D, ignored: Array[RID] = []) -> void:
	root = world_root
	zone = target_zone
	ground = ground_graph
	ignored_rids = ignored.duplicate()
	transitions.clear()
	rejected_transitions.clear()
	for node in root.get_children():
		if not (node is Marker3D) or not node.name.begins_with("RoofAnchor_"):
			continue
		var anchor := node as Marker3D
		if Territory3D.zone_of(anchor.global_position) != zone:
			continue
		var suffix := anchor.name.trim_prefix("RoofAnchor_")
		var base := root.get_node_or_null("RampBase_" + suffix) as Marker3D
		var top := root.get_node_or_null("RampTop_" + suffix) as Marker3D
		var entry := root.get_node_or_null("RoofEntry_" + suffix) as Marker3D
		if base == null or top == null or entry == null:
			rejected_transitions.append(suffix + ": missing authored transition markers")
			continue
		if not _valid_transition(physics, base.global_position, top.global_position):
			rejected_transitions.append(suffix + ": ramp lacks continuous walkable physical support")
			continue
		if not _valid_transition(physics, top.global_position, entry.global_position):
			rejected_transitions.append(suffix + ": landing lacks walkable support")
			continue
		if not _valid_transition(physics, entry.global_position, anchor.global_position):
			rejected_transitions.append(suffix + ": roof lacks walkable support")
			continue
		var region := NavigationRegion3D.new()
		region.name = "RoofNavigationRegion_" + suffix
		region.navigation_layers = 1
		var mesh := NavigationMesh.new()
		# Mesh vertices are authored in the region's local space.
		var roof_width := 3.0
		mesh.set_vertices(PackedVector3Array([
			Vector3(-roof_width, 0, -roof_width), Vector3(roof_width, 0, -roof_width),
			Vector3(roof_width, 0, roof_width), Vector3(-roof_width, 0, roof_width)
		]))
		mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
		region.navigation_mesh = mesh
		region.position = Vector3(anchor.position.x, anchor.position.y - 0.22, anchor.position.z)
		root.add_child(region)
		var link := NavigationLink3D.new()
		link.name = "PhysicalRampLink_" + suffix
		link.bidirectional = true
		link.start_position = base.position
		link.end_position = top.position
		# The live controller follows the validated ramp samples instead of
		# teleporting to the link endpoint.
		root.add_child(link)
		transitions.append({
			"id": suffix, "base": base.global_position, "top": top.global_position,
			"entry": entry.global_position, "roof": anchor.global_position,
			"region": region, "link": link
		})

func _support(physics: PhysicsDirectSpaceState3D, point: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 2.1, point + Vector3.DOWN * 2.8)
	query.exclude = ignored_rids
	var hit := physics.intersect_ray(query)
	if hit.is_empty():
		return {}
	var surface := hit.get("collider") as CollisionObject3D
	if surface == null or not surface.is_in_group("graybox_surfaces"):
		return {}
	if (hit["normal"] as Vector3).y < MIN_WALKABLE_NORMAL_Y:
		return {}
	return hit

func _valid_transition(physics: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	if Territory3D.zone_of(from) != zone or Territory3D.zone_of(to) != zone:
		return false
	var length := from.distance_to(to)
	if length < 0.1 or length > 24.0:
		return false
	var samples := maxi(3, ceili(length / 0.55))
	var previous_y := -INF
	for i in range(samples + 1):
		var p := from.lerp(to, float(i) / float(samples))
		var hit := _support(physics, p)
		if hit.is_empty():
			return false
		var floor_y: float = (hit["position"] as Vector3).y
		# The waypoint must actually be at walking height above its support;
		# a vertical ledge must not be validated by the ground far below it.
		if absf(floor_y - (p.y - 0.85)) > 0.8:
			return false
		if i > 0 and absf(floor_y - previous_y) > 0.75:
			return false
		previous_y = floor_y
	return true

## Returns a collision-validated itinerary with ground approach and sampled
## ramp/roof legs. A missing link is *unreachable*, never a teleport fallback.
func route_to_roof(from: Vector3, prefer_nearest: bool = true) -> Dictionary:
	if ground == null or not ground.built:
		return {}
	var options := transitions.duplicate()
	if prefer_nearest:
		options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return from.distance_squared_to(a["base"]) < from.distance_squared_to(b["base"]))
	for option in options:
		var base: Vector3 = option["base"]
		var approach := base + Vector3(0, 0, 1.3)
		var path := ground.find_path_near(from, approach)
		if path.is_empty():
			continue
		path.append(base)
		_append_leg(path, base, option["top"])
		_append_leg(path, option["top"], option["entry"])
		_append_leg(path, option["entry"], option["roof"])
		_append_leg(path, option["roof"], option["entry"])
		_append_leg(path, option["entry"], option["top"])
		_append_leg(path, option["top"], base)
		return {"path": path, "roof": option["roof"], "base": base, "id": option["id"]}
	return {}

func _append_leg(path: PackedVector3Array, from: Vector3, to: Vector3) -> void:
	var count := maxi(1, ceili(from.distance_to(to) / 0.6))
	for i in range(1, count + 1):
		path.append(from.lerp(to, float(i) / float(count)))
