extends "res://scripts/graybox/VillageGraybox.gd"
## Independent 3D Play vs CPU development match. Does not replace production 2D flow.
## 40s draw -> coin meeting -> two 30s search phases -> survivor comparison.
## Physical NPC movement and occlusion check, not access to opponent stroke locations.
const DRAW_TIME := 40.0
const MEETING_TIME := 5.0
const SEARCH_TIME := 30.0
const BOT_SPEED := 4.2
const CPU_SEARCH_SPEEDS := [3.0, 3.6, 4.2, 4.7]
const CPU_INSPECTION_RADII := [4.0, 5.0, 6.0, 7.0]
const CPU_STRIKE_DELAYS := [1.3, 0.9, 0.65, 0.45]
const HUMAN_ID := 1
const CPU_ID := 2

var phase := "DRAWING"
var phase_left := DRAW_TIME
var configured_draw_seconds := DRAW_TIME
var configured_search_seconds := SEARCH_TIME
var configured_meeting_seconds := MEETING_TIME
var searcher := HUMAN_ID
var first_searcher := HUMAN_ID
var search_number := 0
var cpu_body: CharacterBody3D
var cpu_path := PackedVector3Array()
var cpu_route_index := 0
var cpu_wander_target := Vector3.ZERO
var cpu_idle_time := 0.0
var cpu_nav := GroundNavigation3D.new()
var human_nav := GroundNavigation3D.new()
var cpu_lines: Array[ChalkStroke3D] = []
var saved_human_lines: Array[ChalkStroke3D] = []
var rng := RandomNumberGenerator.new()
var message := ""
var argument_uses := 0
var argument_delay := 0.0
var sneak_uses := 0
var result := ""
var drawn_cpu_count := 0
var cpu_target := 0
var cpu_draw_interval := 0.5
var cpu_recent_positions := PackedVector3Array()
var cheating_enabled := false
var bot_follow_refresh := 0.0
var human_idle_seconds := 0.0
var checked_public_covers: Dictionary = {}
var last_result_saved := false
var cpu_roof_attempted := false
var cpu_speed := BOT_SPEED
var cpu_inspection_radius := 2.8
var cpu_strike_delay := 0.9
var cpu_strike_cooldown := 0.0
var find_interact_requested := false
var coin_call := -1
var coin_face := -1
var cpu_sneak_uses := 0
var cpu_argue_uses := 0
var human_strike_delay := 0.0
var match_paused := false
var five_second_warned := false
var clock_warning_count := 0
var result_hold_left := 0.0
var result_scene_exit_enabled := true
var cpu_patrol_step := 0
var cpu_inspection_count := 0
var cpu_scan_cooldown := 0.0
var cpu_stuck_seconds := 0.0
var cpu_repath_count := 0
var coin_panel: Panel
var coin_face_label: Label
var coin_tween: Tween
var result_panel: Panel
var result_label: Label
var phase_hud: Panel
var phase_hud_label: Label
var human_reveal_scan_cooldown := 0.0
var human_follow_path := PackedVector3Array()
var human_follow_index := 0
var human_follow_refresh := 0.0
var cpu_open_cover: RigidBody3D
var cpu_cover_hold_seconds := 0.0
var cpu_roof_visits := 0
var cpu_roof_return_count := 0
var cpu_roof_anchor: Vector3 = Vector3.INF
var cpu_roof_base: Vector3 = Vector3.INF

func _ready() -> void:
	super._ready()
	rng.randomize()
	configured_draw_seconds = maxf(0.1, float(ProjectSettings.get_setting("chalk_gaon/solo_drawing_seconds", DRAW_TIME)))
	configured_search_seconds = maxf(0.1, float(ProjectSettings.get_setting("chalk_gaon/solo_search_phase_seconds", SEARCH_TIME)))
	configured_meeting_seconds = maxf(0.1, float(ProjectSettings.get_setting("chalk_gaon/solo_meeting_max_seconds", MEETING_TIME)))
	phase_left = configured_draw_seconds
	cheating_enabled = bool(ProjectSettings.get_setting("chalk_gaon/solo_cheating_enabled", false))
	var difficulty := clampi(GameState.cpu_difficulty, 0, 3)
	cpu_speed = float(CPU_SEARCH_SPEEDS[difficulty])
	cpu_inspection_radius = float(CPU_INSPECTION_RADII[difficulty])
	cpu_strike_delay = float(CPU_STRIKE_DELAYS[difficulty])
	var ranges := [Vector2i(50, 100), Vector2i(65, 120), Vector2i(85, 150), Vector2i(110, 180)]
	var count_range: Vector2i = ranges[difficulty]
	cpu_target = rng.randi_range(count_range.x, count_range.y)
	cpu_draw_interval = configured_draw_seconds / float(cpu_target)
	drawing_mode = false
	debug_phase = "DRAWING"
	_make_cpu_body()
	_make_touch_controls()
	_make_coin_visual()
	_make_result_visual()
	_make_phase_hud()
	# Delay ground graph sampling until the physics bodies are registered.
	call_deferred("_begin_navigation")
	draw_controller.stroke_finished.connect(_human_stroke_created)
	_update_hud()

func _begin_navigation() -> void:
	cpu_nav.build(get_world_3d().direct_space_state, Territory3D.Zone.CPU, [walker.get_rid(), cpu_body.get_rid()])
	human_nav.build(get_world_3d().direct_space_state, Territory3D.Zone.PLAYER, [walker.get_rid(), cpu_body.get_rid()])
	_choose_cpu_destination()

func _make_cpu_body() -> void:
	cpu_body = CharacterBody3D.new()
	cpu_body.name = "GhostOpponent3D"
	cpu_body.position = Vector3(27, 0.85, 0)
	cpu_body.collision_layer = 2
	cpu_body.collision_mask = 1
	cpu_body.floor_snap_length = 0.35
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.7
	collision.shape = shape
	cpu_body.add_child(collision)
	var avatar := CharacterRig3D.new()
	avatar.name = "CpuAvatar"
	avatar.opponent = true
	cpu_body.add_child(avatar)
	add_child(cpu_body)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P:
			match_paused = not match_paused
			message = "PAUSED" if match_paused else "RESUMED"
			return
		if match_paused:
			return
		if event.keycode == KEY_R and phase == "RESULT":
			get_tree().reload_current_scene()
			return
		if phase == "MEETING" and event.keycode == KEY_H:
			coin_call = 0
			message = "You called HEADS"
			return
		if phase == "MEETING" and event.keycode == KEY_T:
			coin_call = 1
			message = "You called TAILS"
			return
		if event.keycode == KEY_G or event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F:
			if phase != "DRAWING" and not (cheating_enabled and phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3):
				return
		if event.keycode == KEY_E:
			if not _toggle_aimed_cover():
				if phase == "SEARCHING" and searcher == HUMAN_ID:
					find_interact_requested = true
				else:
					_push_nearby_crate()
		if event.keycode == KEY_Q and phase == "SEARCHING" and searcher == CPU_ID and argument_uses < 1:
			argument_uses += 1
			argument_delay = 3.0
			message = "Argument: CPU search interrupted for 3 seconds"
	super._unhandled_input(event)

func _physics_process(delta: float) -> void:
	if match_paused or phase == "RESULT":
		return
	# Existing graybox controller moves one controllable human.
	# Disable original debug territory switch; enforce phase gates here.
	debug_phase = "DRAWING" if phase == "DRAWING" else "SEARCHING"
	debug_owner_id = HUMAN_ID
	var before_human_move := walker.global_position
	super._physics_process(delta)
	# The graybox controller permits switching territories for debug play.
	# The match must instead enforce the real searcher/defender permissions.
	if not Territory3D.can_enter(HUMAN_ID, walker.global_position, phase, searcher):
		walker.global_position = before_human_move
		walker.velocity = Vector3.ZERO
	if phase == "SEARCHING" and searcher == CPU_ID:
		var manual_move := Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_D) or mobile_move.length_squared() > 0.05
		human_idle_seconds = 0.0 if manual_move else human_idle_seconds + delta
		if manual_move:
			human_follow_path.clear()
			human_follow_index = 0
		elif human_idle_seconds > 3.0:
			_follow_cpu_as_defender(delta)
	if cpu_body == null or phase == "RESULT":
		return
	if cpu_body.is_on_floor():
		cpu_body.velocity.y = -0.1
	else:
		cpu_body.velocity.y -= 17.5 * delta
	if argument_delay > 0.0 and phase == "SEARCHING" and searcher == CPU_ID:
		argument_delay = maxf(0.0, argument_delay - delta)
		cpu_body.velocity.x = 0.0
		cpu_body.velocity.z = 0.0
	else:
		_advance_bot()
	var old_bot_position := cpu_body.global_position
	cpu_body.move_and_slide()
	if cpu_roof_anchor != Vector3.INF and cpu_body.global_position.distance_to(cpu_roof_anchor) < 1.8 and cpu_body.global_position.y > 3.0:
		cpu_roof_visits += 1
		cpu_roof_anchor = Vector3.INF
	if cpu_roof_base != Vector3.INF and cpu_roof_visits > cpu_roof_return_count and cpu_body.global_position.distance_to(cpu_roof_base) < 1.8 and cpu_body.global_position.y < 1.8:
		cpu_roof_return_count += 1
		cpu_roof_base = Vector3.INF
	var commanded := Vector2(cpu_body.velocity.x, cpu_body.velocity.z).length()
	if commanded > 1.5 and cpu_body.global_position.distance_to(old_bot_position) < 0.012:
		cpu_stuck_seconds += delta
	else:
		cpu_stuck_seconds = 0.0
	if cpu_stuck_seconds > 1.25:
		cpu_stuck_seconds = 0.0
		cpu_repath_count += 1
		cpu_path.clear()
		cpu_route_index = 0
		_choose_cpu_destination()

func _process(delta: float) -> void:
	super._process(delta)
	if match_paused:
		draw_controller.enabled = false
		_update_hud()
		return
	# The normal graybox uses debug-phase toggling; the 3D match owns it here.
	draw_controller.enabled = drawing_mode and (phase == "DRAWING" or (cheating_enabled and phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3))
	if phase == "RESULT":
		result_hold_left -= delta
		_update_hud()
		if result_hold_left <= 0.0 and result_scene_exit_enabled and get_tree().current_scene == self:
			get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	phase_left -= delta
	if phase != "MEETING" and phase_left <= 5.0 and not five_second_warned:
		five_second_warned = true
		clock_warning_count += 1
		message = "LAST 5 SECONDS!"
		_play_cue("play_draw_warning")
	if cpu_open_cover != null and is_instance_valid(cpu_open_cover):
		cpu_cover_hold_seconds -= delta
		if cpu_cover_hold_seconds <= 0.0:
			if _can_restore_cover(cpu_open_cover):
				_toggle_cover_body(cpu_open_cover)
				cpu_open_cover = null
			else:
				cpu_cover_hold_seconds = 0.25
	human_strike_delay = maxf(0.0, human_strike_delay - delta)
	cpu_strike_cooldown = maxf(0.0, cpu_strike_cooldown - delta)
	cpu_scan_cooldown = maxf(0.0, cpu_scan_cooldown - delta)
	human_reveal_scan_cooldown = maxf(0.0, human_reveal_scan_cooldown - delta)
	cpu_idle_time -= delta
	if phase == "DRAWING":
		if cpu_idle_time <= 0.0:
			_attempt_cpu_draw()
			cpu_idle_time = cpu_draw_interval
	elif phase == "SEARCHING":
		if cheating_enabled and searcher == HUMAN_ID and cpu_idle_time <= 0.0:
			_cpu_defender_action()
			cpu_idle_time = 3.5
		if searcher == CPU_ID:
			_cpu_inspect()
		else:
			if human_reveal_scan_cooldown <= 0.0:
				human_reveal_scan_cooldown = 0.12
				_reveal_nearby_cpu_strokes()
			if find_interact_requested:
				_human_strike_visible()
		find_interact_requested = false
	if phase_left <= 0.0:
		_advance_phase()
	_update_hud()

func _human_stroke_created(stroke: ChalkStroke3D) -> void:
	if phase != "DRAWING" and not (cheating_enabled and phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3):
		stroke.struck = true
		stroke.visible = false
		return
	stroke.owner_id = HUMAN_ID
	if phase == "SEARCHING":
		if not cheating_enabled or searcher != CPU_ID or sneak_uses >= 3:
			stroke.struck = true
			return
		stroke.is_sneak = true
		sneak_uses += 1
		# A sneak can be noticed only when CPU has unobstructed sight to the action.
		var eye := cpu_body.global_position + Vector3(0, 1.45, 0)
		if stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 7.0, cpu_body.get_rid()):
			stroke.struck = true
			stroke.visible = false
			_penalize_nearby(stroke, saved_human_lines)
			message = "CPU caught sneak: mark plus nearby lines removed"
	saved_human_lines.append(stroke)

func _choose_cpu_destination() -> void:
	if cpu_body == null or not cpu_nav.built:
		return
	var destination_zone := Territory3D.Zone.CPU if phase == "DRAWING" or searcher == HUMAN_ID else Territory3D.Zone.PLAYER
	var nav := cpu_nav if destination_zone == Territory3D.Zone.CPU else human_nav
	if phase == "SEARCHING" and searcher == CPU_ID:
		# Public-map patrol sweeps the courtyard before attempting a roof.
		# This avoids spending the whole 30-second search on a distant ramp.
		if not cpu_roof_attempted:
			cpu_roof_attempted = true
			if _assign_physical_roof_route(nav):
				return
		if cpu_patrol_step < 3:
			var patrol_points := [
				Vector3(-14, 0.85, 0), Vector3(-27, 0.85, -9),
				Vector3(-40, 0.85, 10)]
			var waypoint: Vector3 = patrol_points[cpu_patrol_step]
			cpu_patrol_step += 1
			var patrol_path := nav.find_path_near(cpu_body.global_position, waypoint)
			if not patrol_path.is_empty():
				cpu_path = patrol_path
				cpu_route_index = 0
				return
	var candidates := PackedVector3Array()
	for i in range(24):
		var x := rng.randf_range(5, 48) * (-1.0 if destination_zone == Territory3D.Zone.PLAYER else 1.0)
		var z := rng.randf_range(-21, 21)
		var point := Vector3(x, 0, z)
		if nav.find_path(point, point).size() > 0:
			candidates.append(point)
	if candidates.is_empty():
		return
	cpu_wander_target = candidates[rng.randi_range(0, candidates.size() - 1)]
	cpu_path = nav.find_path_near(cpu_body.global_position, cpu_wander_target)
	cpu_route_index = 0

func _advance_bot() -> void:
	if phase == "MEETING":
		cpu_body.velocity.x = 0.0
		cpu_body.velocity.z = 0.0
		return
	if phase == "SEARCHING" and searcher == HUMAN_ID and cpu_nav.built:
		bot_follow_refresh -= get_physics_process_delta_time()
		if bot_follow_refresh <= 0.0:
			bot_follow_refresh = 1.0
			cpu_path = cpu_nav.find_path_near(cpu_body.global_position, walker.global_position)
			cpu_route_index = 0
	elif cpu_route_index >= cpu_path.size():
		_choose_cpu_destination()
	if cpu_route_index < cpu_path.size():
		var goal := cpu_path[cpu_route_index]
		var horizontal := Vector3(goal.x - cpu_body.global_position.x, 0, goal.z - cpu_body.global_position.z)
		if horizontal.length() < 0.65 and absf(cpu_body.global_position.y - goal.y) < 1.3:
			cpu_route_index += 1
		else:
			var direction := horizontal.normalized()
			cpu_body.velocity.x = move_toward(cpu_body.velocity.x, direction.x * cpu_speed, 15.0 * get_physics_process_delta_time())
			cpu_body.velocity.z = move_toward(cpu_body.velocity.z, direction.z * cpu_speed, 15.0 * get_physics_process_delta_time())
	else:
		cpu_body.velocity.x = 0.0
		cpu_body.velocity.z = 0.0

func _attempt_cpu_draw() -> void:
	if drawn_cpu_count >= cpu_target or not cpu_nav.built:
		return
	var candidates := CpuSurfacePlanner3D.collect_candidates(get_world_3d(), CPU_ID, cpu_body.global_position, 2.7)
	candidates.shuffle()
	for candidate in candidates:
		var approach: Vector3 = candidate["approach"]
		if cpu_body.global_position.distance_to(approach) > 3.0:
			continue
		var surface := candidate["surface"] as CollisionObject3D
		var point: Vector3 = candidate["position"]
		var too_close := false
		for prior in cpu_recent_positions:
			if prior.distance_to(point) < 0.18:
				too_close = true
				break
		if too_close:
			continue
		var normal: Vector3 = candidate["normal"]
		var offset := normal.cross(Vector3.UP).normalized()
		if offset.length_squared() < 0.01:
			offset = normal.cross(Vector3.RIGHT).normalized()
		var next_point := point + offset * 0.4
		# Check the second stroke endpoint remains on the same physical surface.
		var query := PhysicsRayQueryParameters3D.create(next_point + normal * 0.35, next_point - normal * 0.35)
		var second := get_world_3d().direct_space_state.intersect_ray(query)
		if second.is_empty() or second.get("collider") != surface:
			continue
		var stroke := ChalkStroke3D.new()
		stroke.stroke_id = 10000 + drawn_cpu_count
		stroke.owner_id = CPU_ID
		stroke.surface_id = str(surface.get_path())
		surface.add_child(stroke)
		stroke.add_surface_point(point, normal)
		stroke.add_surface_point(second["position"], second["normal"])
		cpu_lines.append(stroke)
		stroke.visible = false
		drawn_cpu_count += 1
		cpu_recent_positions.append(point)
		message = "CPU physically placed line %d" % drawn_cpu_count
		return

func _cpu_inspect() -> void:
	if phase != "SEARCHING" or searcher != CPU_ID:
		return
	if cpu_strike_cooldown > 0.0 or cpu_scan_cooldown > 0.0:
		return
	cpu_scan_cooldown = 0.15
	_inspect_nearby_public_cover()
	# CPU never chooses a waypoint from the player's hidden stroke coordinates.
	# It only looks for actually visible strokes at its current physical eye.
	var eye := cpu_body.global_position + Vector3(0, 1.45, 0)
	for stroke in saved_human_lines:
		if is_instance_valid(stroke) and not stroke.struck and stroke.visible_to_eye(eye, get_world_3d().direct_space_state, cpu_inspection_radius, cpu_body.get_rid()):
			stroke.struck = true
			stroke.discovered = true
			stroke.visible = false
			message = "CPU discovered and struck a chalk line"
			cpu_inspection_count += 1
			_play_cue("play_line_strike")
			cpu_strike_cooldown = cpu_strike_delay
			break

func _human_strike_visible() -> void:
	if phase != "SEARCHING" or searcher != HUMAN_ID:
		return
	if human_strike_delay > 0.0:
		message = "CPU distracted you: wait before striking"
		return
	var eye := walker.global_position + Vector3(0, 1.45, 0)
	for stroke in cpu_lines:
		if is_instance_valid(stroke) and not stroke.struck and stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 3.5, walker.get_rid()):
			stroke.struck = true
			stroke.discovered = true
			stroke.visible = false
			message = "You found a CPU chalk line"
			_play_cue("play_line_strike")
			return
	message = "No visible CPU line close enough to strike"

func _advance_phase() -> void:
	if phase == "RESULT":
		return
	if draw_controller != null and draw_controller.current != null:
		draw_controller._end_stroke()
	five_second_warned = false
	drawing_mode = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if phase == "DRAWING":
		phase = "MEETING"
		phase_left = configured_meeting_seconds
		walker.global_position = Vector3(-2, 0.85, 0)
		cpu_body.global_position = Vector3(2, 0.85, 0)
		_restore_open_cover()
		message = "Meeting: coin toss decides the first searcher"
		_play_cue("play_coin_flip")
	elif phase == "MEETING":
		coin_face = rng.randi_range(0, 1)
		_play_cue("play_coin_clink")
		_animate_coin_flip()
		if coin_call < 0:
			coin_call = rng.randi_range(0, 1)
		first_searcher = HUMAN_ID if coin_face == coin_call else CPU_ID
		message = "Coin %s; %s searches first" % ["HEADS" if coin_face == 0 else "TAILS", "HUMAN" if first_searcher == HUMAN_ID else "CPU"]
		search_number = 1
		_begin_search(first_searcher)
	elif phase == "SEARCHING" and search_number == 1:
		search_number = 2
		_begin_search(CPU_ID if first_searcher == HUMAN_ID else HUMAN_ID)
	elif phase == "SEARCHING":
		_finish_match()

func _begin_search(who: int) -> void:
	five_second_warned = false
	phase = "SEARCHING"
	_restore_open_cover()
	checked_public_covers.clear()
	cpu_open_cover = null
	cpu_cover_hold_seconds = 0.0
	cpu_roof_attempted = false
	cpu_roof_anchor = Vector3.INF
	cpu_roof_base = Vector3.INF
	cpu_roof_visits = 0
	cpu_roof_return_count = 0
	human_follow_path.clear()
	human_follow_index = 0
	human_follow_refresh = 0.0
	cpu_patrol_step = 0
	cpu_inspection_count = 0
	cpu_strike_cooldown = 0.0
	cpu_scan_cooldown = 0.0
	cpu_stuck_seconds = 0.0
	phase_left = configured_search_seconds
	human_idle_seconds = 0.0
	bot_follow_refresh = 0.0
	searcher = who
	cpu_path.clear()
	cpu_route_index = 0
	if who == HUMAN_ID:
		walker.global_position = Vector3(3.5, 0.85, 0)
		cpu_body.global_position = Vector3(27, 0.85, 0)
	else:
		walker.global_position = Vector3(-27, 0.85, 0)
		cpu_body.global_position = Vector3(-3.5, 0.85, 0)
	_choose_cpu_destination()
	cpu_idle_time = 2.0
	message = "Search %d: %s searches" % [search_number, "HUMAN" if who == HUMAN_ID else "CPU"]

func _finish_match() -> void:
	if phase == "RESULT":
		return
	phase = "RESULT"
	result_hold_left = maxf(3.0, float(ProjectSettings.get_setting("chalk_gaon/solo_winner_hold_seconds", 3.0)))
	drawing_mode = false
	if draw_controller != null:
		draw_controller.enabled = false
	if cpu_body != null:
		cpu_body.velocity = Vector3.ZERO
	if walker != null:
		walker.velocity = Vector3.ZERO
	phase_left = 0.0
	var player_survivors := 0
	var bot_survivors := 0
	for stroke in saved_human_lines:
		if is_instance_valid(stroke) and not stroke.struck:
			player_survivors += 1
	for stroke in cpu_lines:
		if is_instance_valid(stroke) and not stroke.struck:
			bot_survivors += 1
	var winner := "DRAW"
	if player_survivors > bot_survivors:
		winner = "HUMAN WINS"
	elif player_survivors < bot_survivors:
		winner = "CPU WINS"
	result = "%s | Human %d : CPU %d" % [winner, player_survivors, bot_survivors]
	message = result
	_show_result_visual()
	_save_round_result()

func _update_hud() -> void:
	if info == null:
		return
	var status := phase + (" • PAUSED" if match_paused else "")
	var clock := "%02d:%02d" % [int(maxf(0.0, phase_left)) / 60, int(maxf(0.0, phase_left)) % 60]
	if phase_hud_label != null:
		phase_hud_label.text = "%s  |  %s  |  YOU %d  CPU %d" % [status, clock, saved_human_lines.size(), cpu_lines.size()]
	info.add_theme_font_size_override("font_size", 16)
	info.text = "%s\nWASD move • Mouse look • F draw • E inspect/strike • H/T toss • P pause\n%s" % [
		"YOU SEARCH" if phase == "SEARCHING" and searcher == HUMAN_ID else "CPU SEARCHES" if phase == "SEARCHING" else "DRAW / MEET",
		message]

func _push_nearby_crate() -> void:
	var origin := walker.global_position + Vector3(0, 1.0, 0)
	var direction := -camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 3.0)
	query.exclude = [walker.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var body := hit.get("collider") as RigidBody3D
	if body == null or not body.is_in_group("future_movable_props"):
		return
	if body.global_position.distance_to(walker.global_position) > 3.2:
		return
	body.apply_central_impulse(Vector3(direction.x, 0, direction.z).normalized() * 22.0)
	message = "Moved wooden crate"

func _cpu_defender_action() -> void:
	# A limited defensive action occurs only while the human searches CPU territory.
	if searcher != HUMAN_ID or phase != "SEARCHING":
		return
	if cpu_argue_uses < 1 and cpu_sneak_uses > 0:
		cpu_argue_uses += 1
		human_strike_delay = 3.0
		message = "CPU argues: your strike action is delayed"
		return
	if cpu_sneak_uses >= 3:
		return
	var eye := walker.global_position + Vector3(0, 1.45, 0)
	var candidates := CpuSurfacePlanner3D.collect_candidates(get_world_3d(), CPU_ID, cpu_body.global_position, 2.5)
	for candidate in candidates:
		var surface := candidate["surface"] as CollisionObject3D
		var point: Vector3 = candidate["position"]
		if cpu_body.global_position.distance_to(point) > 2.7:
			continue
		var normal: Vector3 = candidate["normal"]
		var lateral := normal.cross(Vector3.UP).normalized()
		if lateral.length_squared() < 0.01:
			lateral = normal.cross(Vector3.RIGHT).normalized()
		var second := point + lateral * 0.35
		var query := PhysicsRayQueryParameters3D.create(second + normal * 0.3, second - normal * 0.3)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.get("collider") != surface:
			continue
		var stroke := ChalkStroke3D.new()
		stroke.owner_id = CPU_ID
		stroke.stroke_id = 20000 + cpu_sneak_uses
		stroke.is_sneak = true
		stroke.surface_id = str(surface.get_path())
		surface.add_child(stroke)
		stroke.add_surface_point(point, normal)
		stroke.add_surface_point(hit["position"], hit["normal"])
		cpu_lines.append(stroke)
		stroke.visible = false
		cpu_sneak_uses += 1
		if stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 7.0, walker.get_rid()):
			stroke.struck = true
			stroke.visible = false
			_penalize_nearby(stroke, cpu_lines)
			message = "You spotted CPU sneaking; nearby marks penalized"
		else:
			message = "CPU attempted a hidden defensive mark"
		return

func _penalize_nearby(caught: ChalkStroke3D, owned_lines: Array[ChalkStroke3D]) -> void:
	if caught.local_points.is_empty():
		return
	var location := caught.to_global(caught.local_points[0])
	var penalties := 0
	for candidate in owned_lines:
		if candidate == caught or not is_instance_valid(candidate) or candidate.struck or candidate.local_points.is_empty():
			continue
		if candidate.to_global(candidate.local_points[0]).distance_to(location) < 5.0:
			candidate.struck = true
			candidate.visible = false
			penalties += 1
			if penalties >= 2:
				break

func _reveal_nearby_cpu_strokes() -> void:
	if phase != "SEARCHING" or searcher != HUMAN_ID:
		return
	var eye := walker.global_position + Vector3(0, 1.45, 0)
	for stroke in cpu_lines:
		if not is_instance_valid(stroke) or stroke.struck or stroke.discovered:
			continue
		if stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 3.5, walker.get_rid()):
			stroke.discovered = true
			stroke.visible = true
			message = "Chalk spotted nearby — press E to strike"

func _make_touch_controls() -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	var overlay := CanvasLayer.new()
	overlay.name = "Mobile3DControls"
	add_child(overlay)
	var field := Control.new()
	field.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(field)
	_mobile_button(field, "JUMP", -105, -245, func() -> void:
		mobile_jump = true
		await get_tree().create_timer(0.22).timeout
		mobile_jump = false)
	_mobile_button(field, "CROUCH", -215, -245, func() -> void: _toggle_crouch())
	_mobile_button(field, "DRAW", -105, -165, func() -> void:
		if phase == "DRAWING" or (cheating_enabled and phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3):
			drawing_mode = not drawing_mode)
	_mobile_button(field, "FIND", -215, -165, func() -> void:
		if phase == "SEARCHING" and searcher == HUMAN_ID:
			_human_strike_visible()
		else:
			_push_nearby_crate())
	_mobile_button(field, "ARGUE", -105, -85, func() -> void:
		if phase == "SEARCHING" and searcher == CPU_ID and argument_uses < 1:
			argument_uses += 1
			argument_delay = 3.0)
	_mobile_button(field, "HEADS", -325, -85, func() -> void:
		if phase == "MEETING":
			coin_call = 0)
	_mobile_button(field, "TAILS", -215, -85, func() -> void:
		if phase == "MEETING":
			coin_call = 1)
	var hint := Label.new()
	hint.text = "Left drag: move | Right drag: look"
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(15, -45)
	field.add_child(hint)

func _mobile_button(root: Control, caption: String, right_offset: float, bottom_offset: float, action: Callable) -> void:
	var control := Button.new()
	control.text = caption
	control.custom_minimum_size = Vector2(94, 58)
	control.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	control.offset_left = right_offset
	control.offset_right = right_offset + 94.0
	control.offset_top = bottom_offset
	control.offset_bottom = bottom_offset + 58.0
	control.pressed.connect(action)
	root.add_child(control)

## Brick/crate cover is physically lifted and replaced. This is not a disguised
## visibility flag: the rigid body actually moves, changing physics raycasts.
func _toggle_cover_body(body: RigidBody3D) -> void:
	if body == null or not body.is_in_group("future_movable_props"):
		return
	var opened := bool(body.get_meta("cover_lifted", false))
	if opened:
		if not _can_restore_cover(body):
			message = "Cover cannot close while an actor is underneath"
			return
		var base: Vector3 = body.get_meta("cover_base_position", body.global_position)
		body.global_position = base
		body.freeze = false
		body.set_meta("cover_lifted", false)
	else:
		body.set_meta("cover_base_position", body.global_position)
		body.freeze = true
		body.global_position += Vector3.UP * 1.8
		body.set_meta("cover_lifted", true)

func _toggle_aimed_cover() -> bool:
	if phase != "DRAWING" and not (phase == "SEARCHING" and searcher == HUMAN_ID):
		return false
	var origin := walker.global_position + Vector3(0, 1.0, 0)
	var direction := -camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 3.0)
	query.exclude = [walker.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var body := hit.get("collider") as RigidBody3D
	if body == null or not body.is_in_group("future_movable_props"):
		return false
	if body.global_position.distance_to(walker.global_position) > 3.5:
		return false
	_toggle_cover_body(body)
	message = "Lifted cover" if body.get_meta("cover_lifted", false) else "Replaced cover"
	return true

func _inspect_nearby_public_cover() -> void:
	if phase != "SEARCHING" or searcher != CPU_ID or cpu_open_cover != null:
		return
	for node in get_tree().get_nodes_in_group("future_movable_props"):
		var body := node as RigidBody3D
		if body == null or checked_public_covers.has(body.get_instance_id()):
			continue
		if Territory3D.zone_of(body.global_position) != Territory3D.Zone.PLAYER:
			continue
		if cpu_body.global_position.distance_to(body.global_position) >= 2.6:
			continue
		var eye := cpu_body.global_position + Vector3(0, 1.4, 0)
		var query := PhysicsRayQueryParameters3D.create(eye, body.global_position + Vector3.UP * 0.35)
		query.exclude = [cpu_body.get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.get("collider") != body:
			continue
		checked_public_covers[body.get_instance_id()] = true
		_toggle_cover_body(body)
		cpu_open_cover = body
		cpu_cover_hold_seconds = 1.2
		message = "CPU physically inspected a visible public cover"
		cpu_inspection_count += 1
		return

## Roof access is a physical itinerary: walk to the ramp base, ascend the
## colliding slope, then explore the roof. Never teleport an AI onto it.
func _assign_physical_roof_route(nav: GroundNavigation3D) -> bool:
	var targets: Array[Dictionary] = []
	for marker in get_children():
		if not (marker is Marker3D) or not marker.name.begins_with("RoofAnchor_"):
			continue
		if Territory3D.zone_of(marker.global_position) != Territory3D.Zone.PLAYER:
			continue
		var suffix := marker.name.trim_prefix("RoofAnchor_")
		var base := get_node_or_null("RampBase_" + suffix) as Marker3D
		var top := get_node_or_null("RampTop_" + suffix) as Marker3D
		var entry := get_node_or_null("RoofEntry_" + suffix) as Marker3D
		if base == null or top == null or entry == null:
			continue
		targets.append({"roof": marker, "base": base, "top": top, "entry": entry})
	targets.shuffle()
	for route in targets:
		var start: Vector3 = (route["base"] as Marker3D).global_position
		var entrance := start + Vector3(0, 0, 1.3)
		var ground_path := nav.find_path_near(cpu_body.global_position, entrance)
		if ground_path.is_empty():
			continue
		cpu_path = ground_path
		cpu_path.append(start)
		cpu_path.append((route["top"] as Marker3D).global_position)
		cpu_path.append((route["entry"] as Marker3D).global_position)
		cpu_path.append((route["roof"] as Marker3D).global_position)
		# Return physically down the same ramp; no roof teleport.
		cpu_path.append((route["entry"] as Marker3D).global_position)
		cpu_path.append((route["top"] as Marker3D).global_position)
		cpu_path.append(start)
		cpu_roof_anchor = (route["roof"] as Marker3D).global_position
		cpu_roof_base = start
		cpu_route_index = 0
		message = "CPU exploring a public rooftop route"
		return true
	return false

## Reuse the shared procedural sounds. AudioManager skips playback headlessly.
func _play_cue(method: String, argument: Variant = null) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method(method):
		return
	if method == "play_argument_result":
		audio.call(method, bool(argument))
	else:
		audio.call(method)

## Result persistence, not save/resume: the original SaveManager remains
## the owner of local storage and never overwrites legacy match saves.
func _save_round_result() -> void:
	if last_result_saved:
		return
	last_result_saved = true
	var store := get_node_or_null("/root/SaveManager")
	if store == null or not store.has_method("save_local"):
		return
	var summary := {
		"schema": "chalk_gaon_3d_result_v1",
		"result": result,
		"human_strokes": saved_human_lines.size(),
		"cpu_strokes": cpu_lines.size(),
		"cpu_difficulty": clampi(GameState.cpu_difficulty, 0, 3),
		"first_searcher": first_searcher,
		"human_survivors": _count_survivors(saved_human_lines),
		"cpu_survivors": _count_survivors(cpu_lines),
		"metrics": acceptance_metrics()
	}
	store.call("save_local", "chalk_gaon_3d_latest_result", summary)

func _count_survivors(lines: Array[ChalkStroke3D]) -> int:
	var count := 0
	for stroke in lines:
		if is_instance_valid(stroke) and not stroke.struck:
			count += 1
	return count

## The original childhood-cover rule returns opened cover to place before search.
func _restore_open_cover() -> void:
	for node in get_tree().get_nodes_in_group("future_movable_props"):
		var body := node as RigidBody3D
		if body != null and is_instance_valid(body) and bool(body.get_meta("cover_lifted", false)):
			_toggle_cover_body(body)

## A real animated coin UI rather than an instant text-only result. The
## panel has no full-screen dimming layer and never intercepts input.
func _make_coin_visual() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CoinTossPresentation"
	add_child(layer)
	coin_panel = Panel.new()
	coin_panel.name = "Coin"
	coin_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	coin_panel.offset_left = -66.0
	coin_panel.offset_right = 66.0
	coin_panel.offset_top = 64.0
	coin_panel.offset_bottom = 196.0
	coin_panel.pivot_offset = Vector2(66, 66)
	coin_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.85, 0.63, 0.19)
	style.border_color = Color(0.98, 0.88, 0.54)
	style.set_border_width_all(6)
	style.set_corner_radius_all(66)
	coin_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(coin_panel)
	coin_face_label = Label.new()
	coin_face_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	coin_face_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coin_face_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coin_face_label.add_theme_font_size_override("font_size", 56)
	coin_face_label.add_theme_color_override("font_color", Color(0.23, 0.17, 0.08))
	coin_face_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin_panel.add_child(coin_face_label)
	coin_panel.hide()

func _animate_coin_flip() -> void:
	if coin_panel == null:
		return
	coin_panel.show()
	coin_panel.scale = Vector2.ONE
	coin_face_label.text = "?"
	if coin_tween != null and coin_tween.is_running():
		coin_tween.kill()
	coin_tween = create_tween()
	var tween := coin_tween
	for flip in range(4):
		tween.tween_property(coin_panel, "scale:x", 0.07, 0.10).set_trans(Tween.TRANS_SINE)
		tween.tween_callback(func() -> void:
			if is_instance_valid(coin_face_label):
				coin_face_label.text = "H" if coin_face == 0 else "T")
		tween.tween_property(coin_panel, "scale:x", 1.0, 0.10).set_trans(Tween.TRANS_SINE)
	tween.tween_interval(0.85)
	tween.tween_callback(func() -> void:
		if is_instance_valid(coin_panel):
			coin_panel.hide())

## A compact results banner instead of a gray full-screen fade.
func _make_result_visual() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RoundResultPresentation"
	add_child(layer)
	result_panel = Panel.new()
	result_panel.name = "ResultBanner"
	result_panel.set_anchors_preset(Control.PRESET_CENTER)
	result_panel.offset_left = -260.0
	result_panel.offset_right = 260.0
	result_panel.offset_top = -90.0
	result_panel.offset_bottom = 90.0
	result_panel.pivot_offset = Vector2(260, 90)
	result_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.13, 0.16, 0.95)
	style.border_color = Color(0.80, 0.67, 0.40)
	style.set_border_width_all(3)
	style.set_corner_radius_all(16)
	result_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(result_panel)
	result_label = Label.new()
	result_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 26)
	result_label.add_theme_color_override("font_color", Color(0.97, 0.94, 0.86))
	result_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_panel.add_child(result_label)
	result_panel.hide()

func _show_result_visual() -> void:
	if result_panel == null:
		return
	result_label.text = result + "\nReturning to the village menu..."
	result_panel.show()
	result_panel.scale = Vector2(0.86, 0.86)
	create_tween().tween_property(result_panel, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Idle human defender follows via public obstacle-aware navigation, not a
## straight-line slide through walls. Manual movement always overrides it.
func _follow_cpu_as_defender(delta: float) -> void:
	if not human_nav.built or cpu_body == null:
		return
	if walker.global_position.distance_to(cpu_body.global_position) <= 3.2:
		human_follow_path.clear()
		walker.velocity.x = move_toward(walker.velocity.x, 0.0, 12.0 * delta)
		walker.velocity.z = move_toward(walker.velocity.z, 0.0, 12.0 * delta)
		return
	human_follow_refresh -= delta
	if human_follow_refresh <= 0.0 or human_follow_index >= human_follow_path.size():
		human_follow_refresh = 0.65
		human_follow_path = human_nav.find_path_near(walker.global_position, cpu_body.global_position)
		human_follow_index = 0
	if human_follow_index >= human_follow_path.size():
		return
	var target := human_follow_path[human_follow_index]
	var planar := target - walker.global_position
	planar.y = 0.0
	if planar.length() < 0.6:
		human_follow_index += 1
		return
	var intended := planar.normalized() * 2.5
	walker.velocity.x = move_toward(walker.velocity.x, intended.x, 12.0 * delta)
	walker.velocity.z = move_toward(walker.velocity.z, intended.z, 12.0 * delta)
	var previous := walker.global_position
	walker.move_and_slide()
	if not Territory3D.can_enter(HUMAN_ID, walker.global_position, phase, searcher):
		walker.global_position = previous
		walker.velocity = Vector3.ZERO

## Do not replace a lifted physical crate into a player's capsule.
func _can_restore_cover(body: RigidBody3D) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	var base: Vector3 = body.get_meta("cover_base_position", body.global_position)
	for actor in [walker, cpu_body]:
		if actor != null and actor.global_position.distance_to(base) < 1.1:
			return false
	return true

## Compact, contrast-safe round HUD. The original graybox debug text remains
## only as contextual instructions; phase and clock are always legible.
func _make_phase_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MatchHUD3D"
	add_child(layer)
	phase_hud = Panel.new()
	phase_hud.name = "PhaseBar"
	phase_hud.set_anchors_preset(Control.PRESET_CENTER_TOP)
	phase_hud.offset_left = -235.0
	phase_hud.offset_right = 235.0
	phase_hud.offset_top = 12.0
	phase_hud.offset_bottom = 64.0
	phase_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.11, 0.13, 0.92)
	style.border_color = Color(0.65, 0.54, 0.34)
	style.set_border_width_all(2)
	style.set_corner_radius_all(9)
	phase_hud.add_theme_stylebox_override("panel", style)
	layer.add_child(phase_hud)
	phase_hud_label = Label.new()
	phase_hud_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	phase_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_hud_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	phase_hud_label.add_theme_font_size_override("font_size", 19)
	phase_hud_label.add_theme_color_override("font_color", Color(0.96, 0.94, 0.86))
	phase_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	phase_hud.add_child(phase_hud_label)

## Match-local diagnostics used for actual 40/30/30 gameplay observation.
## Values are public outcomes and movement counters, not hidden mark locations.
func acceptance_metrics() -> Dictionary:
	return {
		"phase": phase,
		"difficulty": clampi(GameState.cpu_difficulty, 0, 3),
		"human_marks": saved_human_lines.size(),
		"cpu_marks": cpu_lines.size(),
		"cpu_strikes_and_inspections": cpu_inspection_count,
		"cpu_roof_visits": cpu_roof_visits,
		"cpu_roof_returns": cpu_roof_return_count,
		"cpu_repaths": cpu_repath_count,
		"human_survivors": _count_survivors(saved_human_lines),
		"cpu_survivors": _count_survivors(cpu_lines)
	}
