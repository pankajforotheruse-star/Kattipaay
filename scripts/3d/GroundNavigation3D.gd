class_name GroundNavigation3D
extends RefCounted
## Obstacle-aware *ground-only* path graph. Roof, ladder and jump links require
## separate action transitions; never pretend this graph can reach elevated surfaces.
const CELL_SIZE := 1.25
var graph := AStarGrid2D.new()
var built := false

func build(physics: PhysicsDirectSpaceState3D, zone: int, ignored_bodies: Array[RID] = []) -> void:
	graph.region = Rect2i(-43, -19, 86, 38)
	graph.cell_size = Vector2.ONE * CELL_SIZE
	graph.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	graph.update()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.7
	capsule.radius = 0.4
	for x in range(graph.region.position.x, graph.region.end.x):
		for z in range(graph.region.position.y, graph.region.end.y):
			var cell := Vector2i(x, z)
			var world_point := cell_to_world(cell)
			if Territory3D.zone_of(world_point) != zone:
				graph.set_point_solid(cell, true)
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = capsule
			query.exclude = ignored_bodies
			query.transform = Transform3D(Basis.IDENTITY, world_point + Vector3(0, 0.85, 0))
			if not physics.intersect_shape(query, 1).is_empty():
				graph.set_point_solid(cell, true)
	built = true

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL_SIZE, 0.0, (float(cell.y) + 0.5) * CELL_SIZE)

func world_to_cell(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CELL_SIZE), floori(pos.z / CELL_SIZE))

func find_path(start: Vector3, destination: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	if not built:
		return result
	var start_cell := world_to_cell(start)
	var end_cell := world_to_cell(destination)
	if not graph.is_in_boundsv(start_cell) or not graph.is_in_boundsv(end_cell):
		return result
	if graph.is_point_solid(start_cell) or graph.is_point_solid(end_cell):
		return result
	for point in graph.get_id_path(start_cell, end_cell):
		result.append(cell_to_world(point))
	return result

## Use the nearest collision-free grid cell when a requested marker lies just
## inside a ramp lip or a moving cover. No teleportation: only path endpoints
## are snapped to publicly traversable ground.
func find_path_near(start: Vector3, destination: Vector3, radius_cells: int = 3) -> PackedVector3Array:
	var result := PackedVector3Array()
	if not built:
		return result
	var from_cell := _nearest_open_cell(world_to_cell(start), radius_cells)
	var to_cell := _nearest_open_cell(world_to_cell(destination), radius_cells)
	if not graph.is_in_boundsv(from_cell) or not graph.is_in_boundsv(to_cell):
		return result
	for point in graph.get_id_path(from_cell, to_cell):
		result.append(cell_to_world(point))
	return result

func _nearest_open_cell(cell: Vector2i, radius_cells: int) -> Vector2i:
	if graph.is_in_boundsv(cell) and not graph.is_point_solid(cell):
		return cell
	var best := Vector2i(-9999, -9999)
	var distance := 999999
	for radius in range(1, maxi(1, radius_cells) + 1):
		for x in range(-radius, radius + 1):
			for y in range(-radius, radius + 1):
				var candidate := cell + Vector2i(x, y)
				if not graph.is_in_boundsv(candidate) or graph.is_point_solid(candidate):
					continue
				var d := x * x + y * y
				if d < distance:
					best = candidate
					distance = d
		if distance < 999999:
			break
	return best
