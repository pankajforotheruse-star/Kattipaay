extends SceneTree
## Physical visibility / 300-mark retention regression. No device FPS claims.
var problems: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var world := Node3D.new()
	world.name = "ChalkOcclusionAcceptance"
	root.add_child(world)
	var floor := StaticBody3D.new()
	floor.name = "DrawingFloor"
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(30, 1, 30)
	floor_collision.shape = floor_shape
	floor.position = Vector3(0, -0.6, 0)
	floor.add_child(floor_collision)
	world.add_child(floor)
	var barrier := StaticBody3D.new()
	barrier.name = "SightBarrier"
	barrier.position = Vector3(0, 0.9, 0)
	var wall_collision := CollisionShape3D.new()
	var wall_shape := BoxShape3D.new()
	wall_shape.size = Vector3(0.5, 2.0, 3.5)
	wall_collision.shape = wall_shape
	barrier.add_child(wall_collision)
	world.add_child(barrier)
	var cover := StaticBody3D.new()
	cover.position = Vector3(3, 0.6, 0)
	var cover_collision := CollisionShape3D.new()
	var cover_shape := BoxShape3D.new()
	cover_shape.size = Vector3(1.2, 1.2, 1.2)
	cover_collision.shape = cover_shape
	cover.add_child(cover_collision)
	world.add_child(cover)
	var partial := ChalkStroke3D.new()
	floor.add_child(partial)
	partial.add_surface_point(Vector3(-2.0, -0.09, 0), Vector3.UP)
	partial.add_surface_point(Vector3(2.0, -0.09, 0), Vector3.UP)
	var hidden := ChalkStroke3D.new()
	floor.add_child(hidden)
	hidden.add_surface_point(Vector3(2.0, -0.09, 0.3), Vector3.UP)
	hidden.add_surface_point(Vector3(2.3, -0.09, 0.3), Vector3.UP)
	var under_cover := ChalkStroke3D.new()
	floor.add_child(under_cover)
	under_cover.add_surface_point(Vector3(2.9, -0.09, 0), Vector3.UP)
	under_cover.add_surface_point(Vector3(3.1, -0.09, 0), Vector3.UP)
	await physics_frame
	var physics := world.get_world_3d().direct_space_state
	_check(partial.visible_to_eye(Vector3(-3.0, 1.5, 0), physics, 8.0), "Partly exposed long stroke is visible")
	_check(not hidden.visible_to_eye(Vector3(-3.0, 1.5, 0), physics, 8.0), "Occluded segment stays hidden")
	_check(not under_cover.visible_to_eye(Vector3(3.0, 1.6, 2.0), physics, 8.0), "Physical cover hides chalk beneath")
	cover.position = Vector3(6, 0.6, 0)
	await physics_frame
	_check(under_cover.visible_to_eye(Vector3(3.0, 1.6, 2.0), physics, 8.0), "Moving physical cover exposes hidden chalk")
	var many: Array[ChalkStroke3D] = []
	for i in range(300):
		var stroke := ChalkStroke3D.new()
		stroke.owner_id = 1
		stroke.stroke_id = i + 1
		floor.add_child(stroke)
		var x := -12.0 + float(i % 30) * 0.75
		var z := -12.0 + float(i / 30) * 0.75
		stroke.add_surface_point(Vector3(x, -0.09, z), Vector3.UP)
		stroke.add_surface_point(Vector3(x + 0.24, -0.09, z), Vector3.UP)
		many.append(stroke)
	_check(many.size() == 300, "300 chalk marks remain in registry")
	_check(many[299].local_points.size() == 2, "300th chalk mark retains full geometry")
	_check(ChalkStroke3D.chalk_material != null, "Chalk uses shared material instead of per-update allocation")
	var saved := many[0].to_save_dict()
	var restored := ChalkStroke3D.new()
	floor.add_child(restored)
	_check(restored.from_save_dict(saved), "Versioned chalk data restores")
	_check(restored.local_points.size() == 2, "Restored chalk retains geometry and bounding cache")
	_check(not restored.visible_to_eye(Vector3(70, 2, 70), physics, 8.0), "Distant chalk culled without revealing")
	if problems.is_empty():
		print("CHALK_GAON_3D_VISIBILITY_STRESS: PASS (occlusion/cover/300 retained marks)")
		quit(0)
	else:
		for issue in problems:
			push_error("3D_VISIBILITY_STRESS: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		problems.append(label)
