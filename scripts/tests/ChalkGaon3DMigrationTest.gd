extends SceneTree
## Godot 4.4 headless structural and logic regression for new 3D adapters.
var errors: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	_check(Territory3D.zone_of(Vector3(-27, 1, 0)) == Territory3D.Zone.PLAYER, "Human territory")
	_check(Territory3D.zone_of(Vector3(27, 1, 0)) == Territory3D.Zone.CPU, "CPU territory")
	_check(Territory3D.zone_of(Vector3(60, 1, 0)) == Territory3D.Zone.OUTSIDE, "Out of map")
	_check(Territory3D.can_draw(1, Vector3(-27, 1, 0)), "Human can draw on own zone")
	_check(not Territory3D.can_draw(1, Vector3(27, 1, 0)), "Human cannot draw on CPU zone")
	_check(Territory3D.can_draw(2, Vector3(27, 1, 0)), "CPU can draw on own zone")
	_check(not Territory3D.can_draw(2, Vector3(-27, 1, 0)), "CPU cannot draw on human zone")
	_check(Territory3D.can_enter(1, Vector3(27, 1, 0), "SEARCHING", 1), "Human search enters CPU zone")
	_check(not Territory3D.can_enter(1, Vector3(27, 1, 0), "DRAWING"), "No cross-zone drawing movement")
	var stroke := ChalkStroke3D.new()
	root.add_child(stroke)
	stroke.owner_id = 1
	stroke.stroke_id = 77
	stroke.surface_id = "/root/Wall1"
	stroke.add_surface_point(Vector3(1, 1, 1), Vector3(0, 0, 1))
	stroke.add_surface_point(Vector3(1.5, 1, 1), Vector3(0, 0, 1))
	_check(stroke.local_points.size() == 2, "3D points attached")
	_check(stroke.stroke_mesh != null and stroke.stroke_mesh.mesh != null, "3D mesh generated")
	var saved := stroke.to_save_dict()
	var loaded := ChalkStroke3D.new()
	root.add_child(loaded)
	_check(loaded.from_save_dict(saved), "Versioned 3D deserialization")
	_check(loaded.local_points.size() == 2 and loaded.owner_id == 1 and loaded.stroke_id == 77, "Stroke roundtrip invariants")
	var nav_root := Node3D.new()
	root.add_child(nav_root)
	var ground_nav := GroundNavigation3D.new()
	ground_nav.build(nav_root.get_world_3d().direct_space_state, Territory3D.Zone.PLAYER)
	var ground_route := ground_nav.find_path(Vector3(-25, 0, -5), Vector3(-20, 0, 5))
	_check(ground_route.size() > 0, "Obstacle-free ground navigation yields path")
	_check(ground_nav.find_path(Vector3(-25, 0, -5), Vector3(25, 0, 5)).is_empty(), "Ground navigation does not cross territory")
	if errors.is_empty():
		print("CHALK_GAON_3D: PASS")
		quit(0)
	else:
		for err in errors:
			push_error(err)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		errors.append(label)
