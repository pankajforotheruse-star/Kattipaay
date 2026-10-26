# VillageNavigation.gd — reachable paths around the actual solid compounds.
# AStarGrid2D uses only PUBLIC wall geometry. It never reads secret marks.
# Searching a mark on/behind a wall requires approaching a reachable EDGE.
class_name VillageNavigation
extends Node2D

const CELL := 40
const ACTOR_MARGIN := 14.0
const WORLD_CELLS := Vector2i(60, 45)

var _grid: AStarGrid2D
var _obstacles: Array[Rect2] = []

func _ready() -> void:
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(Vector2i.ZERO, WORLD_CELLS)
	_grid.cell_size = Vector2(CELL, CELL)
	_grid.offset = Vector2(CELL * 0.5, CELL * 0.5)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_grid.update()
	for rect in HidingRules.get_all_walls():
		var wall: Rect2 = rect
		_obstacles.append(wall.grow(ACTOR_MARGIN))
		# Real collision: both roles now need to walk around this wall.
		var body := StaticBody2D.new()
		body.name = "SolidCompoundWall"
		body.collision_layer = 2
		body.collision_mask = 0
		body.position = wall.get_center()
		var hitbox := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = wall.size
		hitbox.shape = shape
		body.add_child(hitbox)
		add_child(body)
	for cell_y in range(WORLD_CELLS.y):
		for cell_x in range(WORLD_CELLS.x):
			var cell_id := Vector2i(cell_x, cell_y)
			var sample: Vector2 = _grid.get_point_position(cell_id)
			for obstacle in _obstacles:
				if obstacle.has_point(sample):
					_grid.set_point_solid(cell_id, true)
					break

func is_walkable(point: Vector2) -> bool:
	if not Rect2(Vector2.ZERO, ZoneLayout.WORLD_SIZE).has_point(point):
		return false
	for rect in _obstacles:
		if rect.has_point(point):
			return false
	return true

func reachable_approach(point: Vector2) -> Vector2:
	# Every public cover/object can be approached from outside its rim.
	# Inaccessible center targets are projected onto walkable grid points.
	if is_walkable(point):
		return point
	var center := Vector2i(
		clampi(int(floor(point.x / CELL)), 0, WORLD_CELLS.x - 1),
		clampi(int(floor(point.y / CELL)), 0, WORLD_CELLS.y - 1))
	for ring in range(1, 11):
		var best := Vector2.ZERO
		var best_d := INF
		for y in range(maxi(0, center.y - ring),
				mini(WORLD_CELLS.y - 1, center.y + ring) + 1):
			for x in range(maxi(0, center.x - ring),
					mini(WORLD_CELLS.x - 1, center.x + ring) + 1):
				if absi(x - center.x) != ring and absi(y - center.y) != ring:
					continue
				var id := Vector2i(x, y)
				if _grid.is_point_solid(id):
					continue
				var pos: Vector2 = _grid.get_point_position(id)
				var d := point.distance_squared_to(pos)
				if d < best_d:
					best = pos
					best_d = d
		if best_d < INF:
			return best
	return point

func find_route(from: Vector2, to: Vector2) -> PackedVector2Array:
	var goal := reachable_approach(to)
	var start := reachable_approach(from)
	var a := Vector2i(
		clampi(int(floor(start.x / CELL)), 0, WORLD_CELLS.x - 1),
		clampi(int(floor(start.y / CELL)), 0, WORLD_CELLS.y - 1))
	var b := Vector2i(
		clampi(int(floor(goal.x / CELL)), 0, WORLD_CELLS.x - 1),
		clampi(int(floor(goal.y / CELL)), 0, WORLD_CELLS.y - 1))
	var ids: Array[Vector2i] = _grid.get_id_path(a, b)
	var result := PackedVector2Array()
	for id in ids:
		result.append(_grid.get_point_position(id))
	if result.is_empty():
		return result
	if result[-1].distance_to(goal) > 4.0:
		result.append(goal)
	return result
