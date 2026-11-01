extends SceneTree
## Real CharacterBody3D + move_and_slide physics traversal over every rooftop ramp.
## Godot 4.4 headless; does not claim visual or Android verification.
var failed: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/graybox/village_graybox.tscn") as PackedScene
	if packed == null:
		push_error("Roof test cannot load village")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	await physics_frame
	var checked := 0
	for anchor in world.get_children():
		if not (anchor is Marker3D) or not anchor.name.begins_with("RoofAnchor_"):
			continue
		var suffix: String = anchor.name.trim_prefix("RoofAnchor_")
		var foot := world.get_node_or_null("RampBase_" + suffix) as Marker3D
		var crest := world.get_node_or_null("RampTop_" + suffix) as Marker3D
		var entry := world.get_node_or_null("RoofEntry_" + suffix) as Marker3D
		if foot == null or crest == null or entry == null:
			failed.append("Missing ramp waypoints " + suffix)
			continue
		var actor := CharacterBody3D.new()
		actor.name = "RoofPhysicsTester"
		actor.floor_snap_length = 0.35
		actor.position = foot.global_position
		var shape := CapsuleShape3D.new()
		shape.height = 1.7
		shape.radius = 0.35
		var collision := CollisionShape3D.new()
		collision.shape = shape
		actor.add_child(collision)
		world.add_child(actor)
		await physics_frame
		var rose := false
		var on_roof := false
		for target in [crest.global_position, entry.global_position, anchor.global_position]:
			var last_progress: Vector3 = actor.global_position
			for frame in range(430):
				var planar: Vector3 = target - actor.global_position
				planar.y = 0.0
				if planar.length() < 0.65 and actor.global_position.y > (target.y - 1.2):
					break
				var direction: Vector3 = planar.normalized()
				actor.velocity.x = direction.x * 4.3
				actor.velocity.z = direction.z * 4.3
				if actor.is_on_floor():
					actor.velocity.y = -0.1
				else:
					actor.velocity.y -= 17.5 * 1.0 / float(Engine.physics_ticks_per_second)
				actor.move_and_slide()
				if actor.global_position.y > 3.0:
					rose = true
				await physics_frame
				if frame > 0 and frame % 90 == 0:
					if actor.global_position.distance_to(last_progress) < 0.4:
						break
					last_progress = actor.global_position
		on_roof = actor.global_position.y > 3.1 and actor.global_position.distance_to(anchor.global_position) < 1.7
		if not rose or not on_roof:
			failed.append("%s unable to reach roof: %s" % [suffix, str(actor.global_position)])
		else:
			checked += 1
		actor.queue_free()
		await physics_frame
	if checked != 4:
		failed.append("Expected 4 verified roofs; reached %d" % checked)
	if failed.is_empty():
		print("CHALK_GAON_3D_ROOFS: PASS 4/4 physical traversals")
		quit(0)
	else:
		for issue in failed:
			push_error("ROOF_PHYSICS: " + issue)
		quit(1)
