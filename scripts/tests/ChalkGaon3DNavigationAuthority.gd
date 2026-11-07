extends SceneTree
## Public-map route planning, territory authority and defender path checks.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if packed == null:
		push_error("3D navigation scene missing")
		quit(1)
		return
	var game := packed.instantiate()
	root.add_child(game)
	await physics_frame
	await process_frame
	_check(game.human_nav.built and game.cpu_nav.built, "Both physical ground graphs initialized")
	_check(not Territory3D.can_enter(1, Vector3(27, 0, 0), "DRAWING", 1), "Human cannot draw or roam in CPU territory")
	_check(not Territory3D.can_enter(1, Vector3(27, 0, 0), "SEARCHING", 2), "Defender cannot roam in CPU territory")
	_check(Territory3D.can_enter(1, Vector3(-27, 0, 0), "SEARCHING", 2), "Human defender can remain in own territory")
	var follow_path: PackedVector3Array = game.human_nav.find_path_near(Vector3(-27, 0.85, 0), Vector3(-3.5, 0.85, 0))
	_check(follow_path.size() > 3, "Human defender has an obstacle-aware route toward searching CPU")
	game.phase = "SEARCHING"
	game.searcher = 2
	game.cpu_body.global_position = Vector3(-3.5, 0.85, 0)
	game.cpu_roof_attempted = false
	game.cpu_patrol_step = 0
	game._choose_cpu_destination()
	var route: PackedVector3Array = game.cpu_path
	var has_roof := false
	for waypoint in route:
		if waypoint.y > 3.0:
			has_roof = true
	_check(has_roof, "CPU search includes a real elevated roof waypoint")
	_check(route.size() > 7, "CPU roof itinerary includes a ground approach and return")
	_check(game.cpu_roof_anchor != Vector3.INF, "CPU roof visit is instrumented")
	_check(game.cpu_roof_base != Vector3.INF, "CPU route has a physical return base")
	if route.size() > 0:
		_check(route[route.size() - 1].distance_to(game.cpu_roof_base) < 0.1, "CPU descends to ramp base without teleporting")
	game.phase = "MEETING"
	_check(not game._toggle_aimed_cover(), "Human cannot lift cover during meeting")
	if failures.is_empty():
		print("CHALK_GAON_3D_NAV_AUTHORITY: PASS (roof route/return/defender/territory)")
		quit(0)
	else:
		for issue in failures:
			push_error("3D_NAV_AUTHORITY: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
