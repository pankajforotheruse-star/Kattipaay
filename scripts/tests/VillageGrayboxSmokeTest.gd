extends SceneTree
## Run with Godot 4.4: godot --headless --path . --script res://scripts/tests/VillageGrayboxSmokeTest.gd
## Only automated structural checks; this does NOT substitute for a human walkthrough.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/graybox/village_graybox.tscn") as PackedScene
	if packed == null:
		push_error("Graybox scene could not be loaded")
		quit(1)
		return
	var level := packed.instantiate()
	root.add_child(level)
	await process_frame
	var walker := level.get_node_or_null("GrayboxExplorer") as CharacterBody3D
	var camera: Camera3D = null
	var box_count := 0
	var house_count := 0
	var ramp_count := 0
	var blockers := 0
	for child in level.get_children():
		if child is Camera3D:
			camera = child as Camera3D
		if child is StaticBody3D:
			box_count += 1
			if child.name.begins_with("House left"):
				house_count += 1
			if child.name.begins_with("Roof access ramp"):
				ramp_count += 1
			if child.name.begins_with("MOVABLE_CANDIDATE"):
				blockers += 1
	_check(walker != null, "CharacterBody3D exists")
	_check(camera != null, "Camera3D exists")
	_check(box_count >= 65, "Village geometry populated")
	_check(house_count >= 4, "Four village houses")
	_check(ramp_count >= 4, "Four potential roof routes")
	_check(blockers >= 2, "Movable candidate geometry present in both zones")
	if walker != null:
		_check(walker.global_position.x < 0.0, "Initial human spawn in left territory")
	if failures.is_empty():
		print("GRAYBOX AUTOMATED STRUCTURE CHECK PASS; VISUAL/MANUAL TESTS NOT RUN")
		quit(0)
	else:
		for issue in failures:
			push_error(issue)
		quit(1)

func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
