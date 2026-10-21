# MvpSceneAudit.gd -- instantiate EVERY committed .tscn without entering tree.
# Standalone scene-load gate: catches broken optional/tutor/multiplayer scenes even
# when the 1vCPU smoke test never visits them.
extends SceneTree

var _seen := 0
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")


func _scan(directory: String) -> void:
	for filename in DirAccess.get_files_at(directory):
		if not filename.ends_with(".tscn"):
			continue
		var path := directory.path_join(filename)
		var scene := ResourceLoader.load(path) as PackedScene
		_seen += 1
		if scene == null:
			_failures += 1
			push_error("KATTIPAAY_SCENES: FAIL load " + path)
			continue
		var instance := scene.instantiate()
		if instance == null:
			_failures += 1
			push_error("KATTIPAAY_SCENES: FAIL instantiate " + path)
		else:
			instance.free()
	for sub in DirAccess.get_directories_at(directory):
		_scan(directory.path_join(sub))


func _run() -> void:
	# Initialize project autoloads through its real entry point. Standalone
	# SceneTree --script otherwise does not register some globally named
	# autoload symbols when compiling indirectly imported scene scripts.
	if change_scene_to_file("res://scenes/main.tscn") != OK:
		push_error("KATTIPAAY_SCENES: FAIL boot main scene")
		quit(1)
		return
	await process_frame
	await process_frame
	_scan("res://scenes")
	# SceneManager and Bootstrap may schedule a deferred splash-screen swap.
	# Let Godot flush the pending message/scene queue BEFORE process exit;
	# otherwise even successfully freed PackedScene probes cause a false
	# positive 'ObjectDB instances leaked' warning at shutdown.
	# Bootstrap intentionally goes Main -> Splash -> Home asynchronously.
	# Exiting at Splash leaves its deferred transition pending and leaks
	# canvas objects. Wait for a stable HomeScene before final disposal.
	var deadline := Time.get_ticks_msec() + 9000
	while (current_scene == null or current_scene.name != "HomeScreen") \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	if current_scene == null or current_scene.name != "HomeScreen":
		_failures += 1
		push_error("KATTIPAAY_SCENES: FAIL bootstrap never reached stable home")
	await process_frame
	await process_frame
	if _seen < 12:
		_failures += 1
		push_error("KATTIPAAY_SCENES: FAIL unexpectedly few scene files: %d" % _seen)
	if _failures > 0:
		print("KATTIPAAY_SCENES: FAIL scanned=%d failures=%d" % [_seen, _failures])
		quit(1)
	else:
		print("KATTIPAAY_SCENES: PASS scanned=%d" % _seen)
		quit(0)
