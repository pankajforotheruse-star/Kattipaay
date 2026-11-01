extends "res://scripts/graybox/VillageGraybox.gd"
## Independent 3D Play vs CPU development match. Does not replace production 2D flow.
## 40s draw -> coin meeting -> two 30s search phases -> survivor comparison.
## Physical NPC movement and occlusion check, not access to opponent stroke locations.
const DRAW_TIME := 40.0
const MEETING_TIME := 5.0
const SEARCH_TIME := 30.0
const BOT_SPEED := 4.2
const HUMAN_ID := 1
const CPU_ID := 2

var phase := "DRAWING"
var phase_left := DRAW_TIME
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
var find_interact_requested := false

func _ready() -> void:
	super._ready()
	rng.randomize()
	drawing_mode = false
	debug_phase = "DRAWING"
	_make_cpu_body()
	# Delay ground graph sampling until the physics bodies are registered.
	call_deferred("_begin_navigation")
	draw_controller.stroke_finished.connect(_human_stroke_created)
	_update_hud()

func _begin_navigation() -> void:
	cpu_nav.build(get_world_3d().direct_space_state, Territory3D.Zone.CPU)
	human_nav.build(get_world_3d().direct_space_state, Territory3D.Zone.PLAYER)
	_choose_cpu_destination()

func _make_cpu_body() -> void:
	cpu_body = CharacterBody3D.new()
	cpu_body.name = "GhostOpponent3D"
	cpu_body.position = Vector3(27, 0.85, 0)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.7
	collision.shape = shape
	cpu_body.add_child(collision)
	var skin := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.7
	skin.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.86, 0.25, 0.20)
	skin.material_override = material
	cpu_body.add_child(skin)
	add_child(cpu_body)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G or event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F:
			if phase != "DRAWING" and not (phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3):
				return
		if event.keycode == KEY_E and phase == "SEARCHING":
			find_interact_requested = true
		if event.keycode == KEY_Q and phase == "SEARCHING" and searcher == CPU_ID and argument_uses < 1:
			argument_uses += 1
			argument_delay = 3.0
			message = "Argument: CPU search interrupted for 3 seconds"
	super._unhandled_input(event)

func _physics_process(delta: float) -> void:
	# Existing graybox controller moves one controllable human.
	# Disable original debug territory switch; enforce phase gates here.
	debug_phase = "DRAWING" if phase == "DRAWING" else "SEARCHING"
	debug_owner_id = HUMAN_ID
	super._physics_process(delta)
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
	cpu_body.move_and_slide()

func _process(delta: float) -> void:
	super._process(delta)
	# The normal graybox uses debug-phase toggling; the 3D match owns it here.
	draw_controller.enabled = drawing_mode and (phase == "DRAWING" or (phase == "SEARCHING" and searcher == CPU_ID and sneak_uses < 3))
	if phase == "RESULT":
		_update_hud()
		return
	phase_left -= delta
	cpu_idle_time -= delta
	if phase == "DRAWING":
		if cpu_idle_time <= 0.0:
			_attempt_cpu_draw()
			cpu_idle_time = 2.5
	elif phase == "SEARCHING":
		if searcher == CPU_ID:
			_cpu_inspect()
		elif find_interact_requested:
			_human_strike_visible()
		find_interact_requested = false
	if phase_left <= 0.0:
		_advance_phase()
	_update_hud()

func _human_stroke_created(stroke: ChalkStroke3D) -> void:
	stroke.owner_id = HUMAN_ID
	if phase == "SEARCHING":
		if searcher != CPU_ID or sneak_uses >= 3:
			stroke.struck = true
			return
		stroke.is_sneak = true
		sneak_uses += 1
		# A sneak can be noticed only when CPU has unobstructed sight to the action.
		var eye := cpu_body.global_position + Vector3(0, 1.45, 0)
		if stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 7.0):
			stroke.struck = true
			message = "CPU caught a visible sneak"
	saved_human_lines.append(stroke)

func _choose_cpu_destination() -> void:
	if cpu_body == null or not cpu_nav.built:
		return
	var destination_zone := Territory3D.Zone.CPU if phase == "DRAWING" or searcher == HUMAN_ID else Territory3D.Zone.PLAYER
	var nav := cpu_nav if destination_zone == Territory3D.Zone.CPU else human_nav
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
	cpu_path = nav.find_path(cpu_body.global_position, cpu_wander_target)
	cpu_route_index = 0

func _advance_bot() -> void:
	if phase == "MEETING":
		cpu_body.velocity.x = 0.0
		cpu_body.velocity.z = 0.0
		return
	if cpu_route_index >= cpu_path.size():
		_choose_cpu_destination()
	if cpu_route_index < cpu_path.size():
		var goal := cpu_path[cpu_route_index]
		var horizontal := Vector3(goal.x - cpu_body.global_position.x, 0, goal.z - cpu_body.global_position.z)
		if horizontal.length() < 0.65:
			cpu_route_index += 1
		else:
			var direction := horizontal.normalized()
			cpu_body.velocity.x = direction.x * BOT_SPEED
			cpu_body.velocity.z = direction.z * BOT_SPEED
	else:
		cpu_body.velocity.x = 0.0
		cpu_body.velocity.z = 0.0

func _attempt_cpu_draw() -> void:
	if drawn_cpu_count >= 5 or not cpu_nav.built:
		return
	var candidates := CpuSurfacePlanner3D.collect_candidates(get_world_3d(), CPU_ID, cpu_body.global_position, 4.0)
	for candidate in candidates:
		var approach: Vector3 = candidate["approach"]
		if cpu_body.global_position.distance_to(approach) > 3.0:
			continue
		var surface := candidate["surface"] as CollisionObject3D
		var point: Vector3 = candidate["position"]
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
		drawn_cpu_count += 1
		message = "CPU physically placed line %d" % drawn_cpu_count
		return

func _cpu_inspect() -> void:
	# CPU never chooses a waypoint from the player's hidden stroke coordinates.
	# It only looks for actually visible strokes at its current physical eye.
	var eye := cpu_body.global_position + Vector3(0, 1.45, 0)
	for stroke in saved_human_lines:
		if is_instance_valid(stroke) and not stroke.struck and stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 2.8):
			stroke.struck = true
			stroke.discovered = true
			stroke.visible = false
			message = "CPU discovered and struck a chalk line"
			break

func _human_strike_visible() -> void:
	var eye := walker.global_position + Vector3(0, 1.45, 0)
	for stroke in cpu_lines:
		if is_instance_valid(stroke) and not stroke.struck and stroke.visible_to_eye(eye, get_world_3d().direct_space_state, 3.5):
			stroke.struck = true
			stroke.discovered = true
			stroke.visible = false
			message = "You found a CPU chalk line"
			return
	message = "No visible CPU line close enough to strike"

func _advance_phase() -> void:
	drawing_mode = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if phase == "DRAWING":
		phase = "MEETING"
		phase_left = MEETING_TIME
		walker.global_position = Vector3(-2, 0.85, 0)
		cpu_body.global_position = Vector3(2, 0.85, 0)
		message = "Meeting: coin toss decides the first searcher"
	elif phase == "MEETING":
		first_searcher = HUMAN_ID if rng.randi_range(0, 1) == 0 else CPU_ID
		search_number = 1
		_begin_search(first_searcher)
	elif phase == "SEARCHING" and search_number == 1:
		search_number = 2
		_begin_search(CPU_ID if first_searcher == HUMAN_ID else HUMAN_ID)
	elif phase == "SEARCHING":
		_finish_match()

func _begin_search(who: int) -> void:
	phase = "SEARCHING"
	phase_left = SEARCH_TIME
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
	message = "Search %d: %s searches" % [search_number, "HUMAN" if who == HUMAN_ID else "CPU"]

func _finish_match() -> void:
	phase = "RESULT"
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

func _update_hud() -> void:
	if info == null:
		return
	info.text = "CHALK GAON | 3D VS CPU DEVELOPMENT BUILD\n%s | %.1fs | CPU marks %d | Your marks %d\nWASD move  Space jump  C crouch  F draw  E find  Q argue\n%s\n%s" % [
		phase, maxf(0.0, phase_left), drawn_cpu_count, saved_human_lines.size(),
		"Searcher: HUMAN" if searcher == HUMAN_ID else "Searcher: CPU", message]
