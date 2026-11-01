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
var _prop_obstacles: Array[Rect2] = []

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
	# Use the actual relocated Sprite2D positions and scaled texture bounds.
	# Every blocking prop therefore uses the SAME world-space geometry for
	# collision, pathfinding and line-of-sight. Decorative-only canopies
	# remain non-solid; their visible trunks are the physical obstructions.
	var props := get_parent().get_node_or_null("Props")
	if props:
		for zone in props.get_children():
			for visual in zone.get_children():
				if not visual is Sprite2D:
					continue
				var sprite := visual as Sprite2D
				var label := String(sprite.name)
				var solid := label.begins_with("House") or label.begins_with("Well") \
						or label.begins_with("Temple") or label.begins_with("BanyanTrunk") \
						or label.begins_with("Charpai") or label.begins_with("ClayPot") \
						or label.begins_with("Scarecrow")
				if not solid or sprite.texture == null:
					continue
				var visual_size := sprite.texture.get_size() * sprite.scale.abs()
				var collision_size := Vector2(
					clampf(visual_size.x * 0.76, 22.0, 180.0),
					clampf(visual_size.y * 0.60, 20.0, 135.0))
				var rect := Rect2(sprite.global_position - collision_size * 0.5,
					collision_size)
				_prop_obstacles.append(rect)
				_obstacles.append(rect.grow(ACTOR_MARGIN))
				var obstacle := StaticBody2D.new()
				obstacle.name = "Solid" + label
				obstacle.collision_layer = 2
				obstacle.collision_mask = 0
				obstacle.position = sprite.global_position
				var collider := CollisionShape2D.new()
				var shape := RectangleShape2D.new()
				shape.size = collision_size
				collider.shape = shape
				obstacle.add_child(collider)
				add_child(obstacle)
	for cell_y in range(WORLD_CELLS.y):
		for cell_x in range(WORLD_CELLS.x):
			var cell_id := Vector2i(cell_x, cell_y)
			var sample: Vector2 = _grid.get_point_position(cell_id)
			for obstacle in _obstacles:
				if obstacle.has_point(sample):
					_grid.set_point_solid(cell_id, true)
					break

## Prop occlusion respects raised roof surfaces; roof marks are visible
## from adjacent walkable ground, but a HOUSE between two ground marks
## blocks sight just as a solid wall does.
func has_clear_prop_sight(observer: Vector2, target: Vector2) -> bool:
	for rect in _prop_obstacles:
		var hit: Variant = HidingRules.first_rect_edge_hit(observer, target, rect)
		if hit == null:
			continue
		if rect.has_point(target):
			# Chalk on a visible facade/roof can be inspected from nearby;
			# chalk on open ground behind the house cannot.
			var site := HidingRules.cover_site_at(target)
			if not site.is_empty() and int(site["kind"]) == HidingRules.COVER_ROOF:
				continue
		var first: Vector2 = hit
		if first.distance_to(target) > 9.0:
			return false
	return true


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
