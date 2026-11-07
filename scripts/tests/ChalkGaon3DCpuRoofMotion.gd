extends SceneTree
## The actual GameWorld3D CPU controller must climb and descend a real roof.
## This does not merely walk a test capsule along hand-supplied waypoints.
var faults: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if packed == null:
		push_error("CPU roof scene missing")
		quit(1)
		return
	var game := packed.instantiate()
	root.add_child(game)
	await physics_frame
	await process_frame
	game.set_process(false)
	game.set_physics_process(false)
	game.phase = "SEARCHING"
	game.searcher = 2
	game.cpu_speed = 4.7
	game.cpu_roof_attempted = true
	var base: Marker3D
	for marker in game.get_children():
		if marker is Marker3D and marker.name.begins_with("RampBase_") and marker.global_position.x < 0:
			base = marker
			break
	if base == null:
		faults.append("Player-side ramp base is missing")
	else:
		game.cpu_body.global_position = base.global_position + Vector3(0, 0, 1.3)
		game.cpu_body.velocity = Vector3.ZERO
		var route_ok: bool = game._assign_physical_roof_route(game.human_nav)
		_check(route_ok, "CPU obtains real rooftop route from nearby ground")
		if route_ok:
			var max_height: float = game.cpu_body.global_position.y
			for frame in range(1600):
				game._physics_process(1.0 / 60.0)
				max_height = maxf(max_height, game.cpu_body.global_position.y)
				await physics_frame
				if game.cpu_roof_visits >= 1 and game.cpu_roof_return_count >= 1:
					break
			_check(max_height > 3.1, "Actual CPU body physically ascends rooftop")
			_check(game.cpu_roof_visits >= 1, "CPU physically reaches rooftop anchor")
			_check(game.cpu_roof_return_count >= 1, "CPU physically descends via ramp")
			print("CPU_ROOF_MOTION height=%.2f visits=%d returns=%d repaths=%d route=%d/%d goal=%s pos=%s" % [
				max_height, game.cpu_roof_visits, game.cpu_roof_return_count,
				game.cpu_repath_count, game.cpu_route_index, game.cpu_path.size(),
				str(game.cpu_path[mini(game.cpu_route_index, game.cpu_path.size() - 1)]), str(game.cpu_body.global_position)])
	if faults.is_empty():
		print("CHALK_GAON_3D_CPU_ROOF_MOTION: PASS")
		quit(0)
	else:
		for issue in faults:
			push_error("CPU_ROOF_MOTION: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		faults.append(label)
