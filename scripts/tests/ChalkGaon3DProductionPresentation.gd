extends SceneTree
## Headless structural QA for original 3D art, procedural audio and action poses.
## Not a substitute for a real visual/audio playtest on Android.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if scene == null:
		push_error("3D production presentation scene missing")
		quit(1)
		return
	var game := scene.instantiate()
	root.add_child(game)
	await process_frame
	var art := game.get_node_or_null("AuthoredVillageDressing") as VillageArt3D
	_check(art != null, "Original modular village dressing loaded")
	if art != null:
		_check(art.get_child_count() > 90, "Village includes authored modular details")
		_check(art.get_node_or_null("BatchedGrass_leaf") is MultiMeshInstance3D, "Vegetation batched into MultiMesh")
		_check(art.get_node_or_null("BatchedGrass_leaf_light") is MultiMeshInstance3D, "Second vegetation color batched")
		var colliders := 0
		for child in art.get_children():
			if child is CollisionObject3D:
				colliders += 1
		_check(colliders == 4, "Two wells and two charpais have physical colliders")
		var well := art.get_node_or_null("WellPhysicalCollision")
		_check(well is StaticBody3D and well.is_in_group("graybox_surfaces"), "Well can physically block searcher and receive chalk")
	var sound := game.get_node_or_null("SpatialVillageSoundscape") as VillageSoundscape3D
	_check(sound != null, "Spatial village soundscape loaded")
	if sound != null:
		var wind := sound._wave("wind", 1.0, true)
		var bird := sound._wave("bird", 0.5, false)
		var steps := sound._wave("step_earth", 0.2, false)
		_check(wind.data.size() == VillageSoundscape3D.RATE * 2, "Original wind PCM generated")
		_check(wind.loop_mode == AudioStreamWAV.LOOP_FORWARD, "Ambient loop is seamless at stream level")
		_check(bird.data.size() > 1000 and steps.data.size() > 1000, "Bird and footstep samples generated")
	var avatar := game.cpu_body.get_node_or_null("CpuAvatar") as CharacterRig3D
	_check(avatar != null, "CPU has animated articulated rig")
	if avatar != null:
		avatar.set_pose("inspect", 1.0)
		avatar._process(0.2)
		_check(avatar.right_arm.rotation.x < -0.1, "Search inspection pose animates arm")
		avatar.set_pose("strike", 1.0)
		avatar._process(0.2)
		_check(avatar.pose == "strike", "Strike pose available")
	_check(game.phase_progress is ProgressBar, "Polished clock progress bar exists")
	_check(game.aiming_reticle is Label, "Drawing/search reticle exists")
	_check(game.interaction_hint is Label, "Context-sensitive action prompt exists")
	_check(game.performance_qa is AndroidPerformance3D, "Opt-in Android QA sampler attached")
	_check(game.pause_menu is PanelContainer, "Accessible pause and audio settings overlay exists")
	game._set_match_paused(true)
	_check(game.match_paused and game.pause_menu.visible, "Pause shows usable settings overlay")
	game._set_match_paused(false)
	_check(not game.match_paused and not game.pause_menu.visible, "Resume hides settings and returns control")
	if failures.is_empty():
		print("CHALK_GAON_3D_PRODUCTION_PRESENTATION: PASS (structure/audio synthesis/poses/UI)")
		quit(0)
	else:
		for issue in failures:
			push_error("3D_PRODUCTION_PRESENTATION: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
