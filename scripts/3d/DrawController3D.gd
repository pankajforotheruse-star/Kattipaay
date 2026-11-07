class_name DrawController3D
extends Node3D
## Camera-targeted world-space freehand drawing; no preset drawing locations.
signal stroke_finished(stroke: ChalkStroke3D)
@export var draw_range := 9.0
@export var point_spacing := 0.065
@export var max_connected_gap := 2.0
@export var camera_ray_length := 50.0
var camera: Camera3D
var player: CharacterBody3D
var strokes: Array[ChalkStroke3D] = []
var owner_id := 1
var enabled := true
var current: ChalkStroke3D
var next_stroke_id := 1
var active_touch_id := -1

func configure(view: Camera3D, actor: CharacterBody3D) -> void:
	camera = view
	player = actor

func _unhandled_input(event: InputEvent) -> void:
	if not enabled or camera == null or player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed and active_touch_id == -1:
			active_touch_id = event.index
			_begin_stroke(event.position)
		elif not event.pressed and event.index == active_touch_id:
			_end_stroke()
			active_touch_id = -1
	if event is InputEventScreenDrag and event.index == active_touch_id and current != null:
		_append_stroke(event.position)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and active_touch_id < 0:
		if event.pressed:
			_begin_stroke(event.position)
		else:
			_end_stroke()
	if event is InputEventMouseMotion and current != null and active_touch_id < 0 and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_append_stroke(event.position)

func _trace(screen_point: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_point)
	var end := origin + camera.project_ray_normal(screen_point) * camera_ray_length
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var surface: Object = hit.get("collider")
	if not (surface is CollisionObject3D) or not surface.is_in_group("graybox_surfaces"):
		return {}
	if not Territory3D.can_draw(owner_id, hit["position"]):
		return {}
	if player.global_position.distance_to(hit["position"]) > draw_range:
		return {}
	return hit

func _begin_stroke(screen_point: Vector2) -> void:
	if current != null:
		return
	var hit := _trace(screen_point)
	if hit.is_empty():
		return
	var surface := hit["collider"] as CollisionObject3D
	var stroke := ChalkStroke3D.new()
	stroke.name = "Stroke_%d" % next_stroke_id
	stroke.stroke_id = next_stroke_id
	stroke.owner_id = owner_id
	stroke.surface_id = str(surface.get_path())
	surface.add_child(stroke)
	current = stroke
	next_stroke_id += 1
	stroke.add_surface_point(hit["position"], hit["normal"])

## Interpolate fast drags on the *actual collider*, rather than drawing long
## straight chords between sparse screen input events.
func _append_stroke(screen_point: Vector2) -> void:
	if current == null:
		return
	var hit := _trace(screen_point)
	if hit.is_empty():
		return
	if hit["collider"] != current.get_parent():
		_end_stroke()
		_begin_stroke(screen_point)
		return
	var last: Vector3 = current.to_global(current.local_points[current.local_points.size() - 1])
	var target: Vector3 = hit["position"]
	var length := last.distance_to(target)
	if length > max_connected_gap:
		_end_stroke()
		_begin_stroke(screen_point)
		return
	if length < point_spacing:
		return
	var surface := current.get_parent() as CollisionObject3D
	var last_normal: Vector3 = (current.global_transform.basis * current.local_normals[current.local_normals.size() - 1]).normalized()
	var target_normal: Vector3 = hit["normal"]
	var count := mini(64, maxi(1, ceili(length / point_spacing)))
	for i in range(1, count + 1):
		var t := float(i) / float(count)
		var normal := last_normal.slerp(target_normal, t).normalized()
		var proposed := last.lerp(target, t)
		var ray := PhysicsRayQueryParameters3D.create(proposed + normal * 0.22, proposed - normal * 0.22)
		var sample := get_world_3d().direct_space_state.intersect_ray(ray)
		if sample.is_empty() or sample.get("collider") != surface:
			continue
		current.add_surface_point(sample["position"], sample["normal"], false)
	current.rebuild_mesh()

func _end_stroke() -> void:
	if current == null:
		return
	if current.local_points.size() < 2:
		current.queue_free()
	else:
		strokes.append(current)
		stroke_finished.emit(current)
	current = null

func find_visible_strokes(eye_position: Vector3, max_distance: float = 8.0) -> Array[ChalkStroke3D]:
	var visible_strokes: Array[ChalkStroke3D] = []
	for stroke in strokes:
		if is_instance_valid(stroke) and stroke.visible_to_eye(eye_position, get_world_3d().direct_space_state, max_distance):
			visible_strokes.append(stroke)
	return visible_strokes

func save_strokes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for stroke in strokes:
		if is_instance_valid(stroke):
			result.append(stroke.to_save_dict())
	return result

## Resolve stable scene paths; reject unknown/unavailable surfaces, never spawn strokes in midair.
func load_strokes(records: Array[Dictionary], world_root: Node) -> int:
	var restored := 0
	for data in records:
		if int(data.get("version", 0)) != 1:
			continue
		var path := NodePath(str(data.get("surface", "")))
		var surface := world_root.get_node_or_null(path) as CollisionObject3D
		if surface == null or not surface.is_in_group("graybox_surfaces"):
			continue
		var stroke := ChalkStroke3D.new()
		stroke.name = "LoadedStroke_%d" % restored
		surface.add_child(stroke)
		if not stroke.from_save_dict(data):
			stroke.queue_free()
			continue
		strokes.append(stroke)
		restored += 1
	return restored
