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
	# Discoverability: the on-screen hint must name the verb that works in this phase.
	game.phase = "RESULT"
	game._update_hud()
	_check(game.interaction_hint.text.contains("R: PLAY AGAIN"), "RESULT hint offers replay")
	_check(not game.interaction_hint.text.contains("DRAW"), "RESULT hint never offers drawing")
	game.phase = "DRAWING"
	game.drawing_mode = false
	game._update_hud()
	_check(game.interaction_hint.text.contains("F: CHALK MODE"), "DRAWING hint offers chalk mode")
	game.drawing_mode = true
	game._update_hud()
	_check(game.interaction_hint.text.contains("LEFT DRAG"), "Chalk mode hint explains left-drag drawing")
	game.drawing_mode = false
	game.phase = "MEETING"
	game._update_hud()
	_check(game.interaction_hint.text.contains("HEADS") and game.interaction_hint.text.contains("TAILS"), "MEETING hint names the coin call")
	game.phase = "SEARCHING"
	game.searcher = game.HUMAN_ID
	game._update_hud()
	_check(game.interaction_hint.text.contains("E: STRIKE"), "Searcher hint names the strike key")
	game.searcher = game.CPU_ID
	game._update_hud()
	_check(not game.interaction_hint.text.contains("STRIKE"), "Defender hint hides the inert strike key")
	# A refused draw must say which of the three rules stopped it.
	var chalk_surface := game.get_node_or_null("AuthoredVillageDressing/WellPhysicalCollision") as CollisionObject3D
	_check(chalk_surface != null, "Chalk-receiving surface available for rejection checks")
	if chalk_surface != null:
		var off_surface := DrawController3D.reject_reason({}, game.HUMAN_ID, Vector3.ZERO, 9.0)
		var wrong_side := DrawController3D.reject_reason({"collider": chalk_surface, "position": Vector3(27, 0.5, 0)}, game.HUMAN_ID, Vector3(-27, 1.3, 0), 9.0)
		var too_far := DrawController3D.reject_reason({"collider": chalk_surface, "position": Vector3(-50, 0.5, 0)}, game.HUMAN_ID, Vector3(-27, 1.3, 0), 9.0)
		_check(off_surface == DrawController3D.REJECT_OFF_SURFACE, "Off-surface press explains itself")
		_check(wrong_side == DrawController3D.REJECT_WRONG_SIDE, "Opponent-half press explains itself")
		_check(too_far == DrawController3D.REJECT_TOO_FAR, "Out-of-reach press explains itself")
		var reasons: Array[String] = []
		game.draw_controller.draw_rejected.connect(func(reason: String) -> void: reasons.append(reason))
		game.draw_controller.draw_range = 0.001
		game.draw_controller._begin_stroke(Vector2(640, 360))
		_check(reasons.size() == 1 and not reasons[0].is_empty(), "Refused press reports why")
		game._update_hud()
		_check(reasons.size() == 1 and game.interaction_hint.text == reasons[0], "HUD shows the rejection instead of a generic hint")
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
