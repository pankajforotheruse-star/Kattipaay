extends Node3D
## Standalone 3D village exploration graybox. Never replaces the 2D match scene.
## Controls: WASD/arrows move, mouse look, Space jump, Shift sprint, Esc unlock mouse.
const ZONE_HALF := 23.0
const ZONE_CENTERS := [-27.0, 27.0]
const GROUND_COLOR := Color(0.58, 0.45, 0.32)
var walker: CharacterBody3D
var camera: Camera3D
var yaw := 0.0
var pitch := -0.14
var velocity_y := 0.0
var spawn_index := 0
var info: Label
var crouched := false
var draw_controller: DrawController3D
var drawing_mode := false
var debug_phase := "DRAWING"
var debug_owner_id := 1
var mobile_move := Vector2.ZERO
var mobile_move_touch := -1
var mobile_start := Vector2.ZERO
var mobile_jump := false
var material_textures: Dictionary = {}
const WALK_ACCELERATION := 13.0
const WALK_DECELERATION := 19.0
const CAMERA_FOLLOW_RATE := 12.0

func _ready() -> void:
	_make_light()
	_add_box("Earth", Vector3(0, -0.6, 0), Vector3(108, 1, 51), GROUND_COLOR)
	_add_box("North boundary", Vector3(0, 2.2, -25.0), Vector3(108, 4.4, 1.0), Color(0.42, 0.32, 0.26))
	_add_box("South boundary", Vector3(0, 2.2, 25.0), Vector3(108, 4.4, 1.0), Color(0.42, 0.32, 0.26))
	_add_box("West boundary", Vector3(-54, 2.2, 0), Vector3(1, 4.4, 51), Color(0.42, 0.32, 0.26))
	_add_box("East boundary", Vector3(54, 2.2, 0), Vector3(1, 4.4, 51), Color(0.42, 0.32, 0.26))
	# Two physically adjacent territories; a clearly visible center crossing is kept open.
	_add_box("North divider", Vector3(0, 1.5, -15.0), Vector3(0.65, 3.0, 19.0), Color(0.8, 0.7, 0.49))
	_add_box("South divider", Vector3(0, 1.5, 15.0), Vector3(0.65, 3.0, 19.0), Color(0.8, 0.7, 0.49))
	for i in range(2):
		_build_zone(ZONE_CENTERS[i], i)
		_add_marker("PlayerSpawn3D" if i == 0 else "CpuSpawn3D", Vector3(ZONE_CENTERS[i], 0.85, 0))
	_make_walker()
	_make_ui()
	_make_draw_controller()
	_validate_layout()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _make_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.24, 0.42, 0.67)
	sky_material.sky_horizon_color = Color(0.79, 0.78, 0.70)
	sky_material.ground_bottom_color = Color(0.22, 0.20, 0.16)
	sky.sky_material = sky_material
	e.sky = sky
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_density = 0.003
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.83, 0.78)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)

func _add_box(label: String, pos: Vector3, size: Vector3, color: Color, tilt: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "%s_%d" % [label.validate_node_name(), get_child_count()]
	body.add_to_group("graybox_surfaces")
	if label.begins_with("MOVABLE_CANDIDATE"):
		body.add_to_group("future_movable_props")
	body.position = pos
	body.rotation = tilt
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	var mesh := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = size
	mesh.mesh = cube
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.94
	mat.metallic = 0.0
	mat.albedo_texture = _surface_texture(label)
	mesh.material_override = mat
	body.add_child(mesh)
	add_child(body)
	return body

## Reusable noise textures add visible soil, stone, wood and plaster variation.
func _surface_texture(label: String) -> Texture2D:
	var key := "soil"
	var lower := label.to_lower()
	if "roof" in lower or "wall" in lower or "house" in lower or "shed" in lower:
		key = "plaster"
	elif "crate" in lower or "cart" in lower or "log" in lower or "trunk" in lower:
		key = "wood"
	elif "stone" in lower or "ramp" in lower or "step" in lower:
		key = "stone"
	if material_textures.has(key):
		return material_textures[key]
	var noise := FastNoiseLite.new()
	noise.seed = {"soil": 125, "plaster": 84, "wood": 27, "stone": 39}[key]
	noise.frequency = 0.045 if key != "wood" else 0.09
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.noise = noise
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.72, 0.71, 0.69))
	gradient.set_color(1, Color(1.0, 0.99, 0.97))
	texture.color_ramp = gradient
	material_textures[key] = texture
	return texture

## Decorative trim does not affect collisions or CPU navigation.
func _visual_trim(label: String, at: Vector3, dimensions: Vector3, paint: Color) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = label.validate_node_name()
	mesh.position = at
	var shape := BoxMesh.new()
	shape.size = dimensions
	mesh.mesh = shape
	var mat := StandardMaterial3D.new()
	mat.albedo_color = paint
	mat.roughness = 0.91
	mat.albedo_texture = _surface_texture(label)
	mesh.material_override = mat
	add_child(mesh)

func _build_zone(cx: float, index: int) -> void:
	var wall := Color(0.72, 0.60, 0.45) if index == 0 else Color(0.70, 0.54, 0.46)
	# Courtyard houses with walkable flat roofs and physical ramp access.
	_build_house(cx - 11, -10, wall)
	_build_house(cx + 9, 9, wall)
	# Architectural hiding: short broken walls, alcove, low clearance.
	_add_box("Broken wall", Vector3(cx + 5, 1.2, -6), Vector3(7, 2.4, 0.5), wall)
	_add_box("Recess left", Vector3(cx + 3, 1.1, -17), Vector3(0.5, 2.2, 3), wall)
	_add_box("Recess back", Vector3(cx + 5, 1.1, -18.5), Vector3(4.5, 2.2, 0.5), wall)
	_add_box("Recess right", Vector3(cx + 7, 1.1, -17), Vector3(0.5, 2.2, 3), wall)
	_add_box("Low shelter roof", Vector3(cx - 1, 1.6, 15), Vector3(6, 0.35, 4), Color(0.38, 0.28, 0.19))
	for j in range(3):
		_add_box("Crate_%d" % j, Vector3(cx + 3 + j * 1.6, 0.6, 3 + j * 0.65), Vector3(1.2, 1.2, 1.2), Color(0.43, 0.30, 0.18))
	# Fallen log and adjacent rock provide simple obstructed surfaces.
	_add_box("Fallen log", Vector3(cx - 2, 0.48, -3), Vector3(5, 0.95, 1), Color(0.36, 0.24, 0.15))
	_add_box("Stone", Vector3(cx - 14, 0.65, 12), Vector3(2.5, 1.3, 2.5), Color(0.43, 0.42, 0.39))
	_add_box("Tree trunk", Vector3(cx + 15, 2.1, -13), Vector3(1, 4.2, 1), Color(0.33, 0.21, 0.12))
	_add_box("Tree crown", Vector3(cx + 15, 4.5, -13), Vector3(5, 2, 5), Color(0.27, 0.43, 0.23))
	_add_box("Raised platform", Vector3(cx - 15, 0.7, -2), Vector3(5, 1.4, 5), Color(0.48, 0.37, 0.27))
	_add_box("Ruined shed rear", Vector3(cx + 20, 1.3, 17), Vector3(6, 2.6, 0.45), wall)
	_add_box("Ruined shed left", Vector3(cx + 17, 1.0, 15), Vector3(0.45, 2.0, 4), wall)
	_add_box("Ruined shed lintel", Vector3(cx + 20, 2.6, 13), Vector3(6, 0.5, 0.45), wall)
	_add_box("Bush cover", Vector3(cx - 15, 0.45, -17), Vector3(3.4, 0.9, 2.7), Color(0.29, 0.45, 0.22))
	_add_movable_crate(Vector3(cx - 8, 0.6, 6))
	_add_box("Stone steps lower", Vector3(cx - 16, 0.24, -6), Vector3(2.5, 0.48, 1.5), Color(0.47, 0.42, 0.35))
	_add_box("Stone steps upper", Vector3(cx - 16, 0.52, -4.5), Vector3(2.5, 1.04, 1.5), Color(0.47, 0.42, 0.35))
	_add_box("Haystack obstacle", Vector3(cx + 17, 0.8, -4), Vector3(2.5, 1.6, 2.5), Color(0.69, 0.53, 0.25))
	_add_box("Cart base", Vector3(cx - 7, 0.45, -14), Vector3(3.7, 0.9, 2.2), Color(0.42, 0.29, 0.17))
	_add_box("Cart screen", Vector3(cx - 7, 1.35, -15.1), Vector3(3.7, 1.0, 0.22), Color(0.42, 0.29, 0.17))
	# Spawn paint is visual-only: the old collision box blocked the bot path graph at spawn.
	var spawn_paint := _add_box("Territory marker", Vector3(cx, 0.05, 0), Vector3(2, 0.1, 2), Color(0.18, 0.45, 0.8) if index == 0 else Color(0.85, 0.35, 0.17))
	(spawn_paint.get_child(0) as CollisionShape3D).disabled = true

func _build_house(x: float, z: float, wall: Color) -> void:
	# U-shaped room with doorway gap; roof provides a drawing-ready overhead surface.
	_add_box("House left", Vector3(x - 3.5, 1.6, z), Vector3(0.5, 3.2, 7), wall)
	_add_box("House right", Vector3(x + 3.5, 1.6, z), Vector3(0.5, 3.2, 7), wall)
	_add_box("House back", Vector3(x, 1.6, z - 3.5), Vector3(7, 3.2, 0.5), wall)
	_add_box("Front left", Vector3(x - 2.6, 1.6, z + 3.5), Vector3(1.8, 3.2, 0.5), wall)
	_add_box("Front right", Vector3(x + 2.6, 1.6, z + 3.5), Vector3(1.8, 3.2, 0.5), wall)
	_add_marker("RoofAnchor_%d_%d" % [int(x), int(z)], Vector3(x, 3.85, z))
	_add_marker("RampBase_%d_%d" % [int(x), int(z)], Vector3(x + 5.3, 0.85, z + 7.3))
	_add_marker("RampTop_%d_%d" % [int(x), int(z)], Vector3(x + 5.3, 3.90, z - 4.1))
	_add_marker("RoofEntry_%d_%d" % [int(x), int(z)], Vector3(x + 3.5, 3.90, z - 3.9))
	_add_box("Flat roof", Vector3(x, 3.45, z), Vector3(7.7, 0.35, 7.7), Color(0.55, 0.37, 0.28))
	# Keep a physical parapet but leave the ramp landing unobstructed.
	_add_box("Roof parapet", Vector3(x - 0.9, 3.95, z - 3.7), Vector3(5.5, 0.9, 0.4), wall)
	# A bridge connects the side-mounted ramp to the roof without crossing the house wall.
	_add_box("Roof ramp landing", Vector3(x + 3.8, 3.55, z - 3.6), Vector3(2.3, 0.28, 1.0), Color(0.53, 0.46, 0.36), Vector3(0, 0, atan(0.26 / 2.3)))
	# Inclined solid ramp is actually walkable, unlike decorative stairs.
	var rise := 3.45
	var run := 10.0
	var angle := atan(rise / run)
	_add_box("Roof access ramp", Vector3(x + 5.3, rise * 0.5 - 0.08, z + 1.5), Vector3(1.9, 0.45, 12.3), Color(0.47, 0.44, 0.39), Vector3(angle, 0, 0))
	# Recessed windows, timber frames and trim add scale without blocking ramps.
	for side in [-1, 1]:
		_visual_trim("Weathered timber window frame", Vector3(x + float(side) * 3.79, 1.9, z + 0.5), Vector3(0.06, 1.15, 1.0), Color(0.25, 0.18, 0.12))
		_visual_trim("Window dark recess", Vector3(x + float(side) * 3.83, 1.9, z + 0.5), Vector3(0.07, 0.85, 0.72), Color(0.10, 0.12, 0.12))
	_visual_trim("Door lintel", Vector3(x, 2.75, z + 3.78), Vector3(2.1, 0.18, 0.18), Color(0.32, 0.22, 0.15))
	_visual_trim("Door threshold", Vector3(x, 0.12, z + 3.9), Vector3(2.1, 0.18, 0.55), Color(0.40, 0.36, 0.31))
	_visual_trim("Roof weathering band", Vector3(x, 3.58, z + 3.85), Vector3(7.5, 0.16, 0.12), Color(0.39, 0.29, 0.22))
	# Ramp upper end overlaps the rooftop edge; verify this transition in-engine.

func _make_walker() -> void:
	walker = CharacterBody3D.new()
	walker.name = "GrayboxExplorer"
	walker.position = Vector3(ZONE_CENTERS[0], 1.3, 0)
	walker.floor_snap_length = 0.35
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	var collider := CollisionShape3D.new()
	collider.shape = capsule
	walker.add_child(collider)
	var avatar := CharacterRig3D.new()
	avatar.name = "HumanAvatar"
	walker.add_child(avatar)
	add_child(walker)
	camera = Camera3D.new()
	camera.current = true
	add_child(camera)

func _make_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	info = Label.new()
	info.position = Vector2(18, 16)
	info.add_theme_font_size_override("font_size", 19)
	canvas.add_child(info)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and not drawing_mode:
		if event.pressed and event.position.x < get_viewport().get_visible_rect().size.x * 0.45 and mobile_move_touch < 0:
			mobile_move_touch = event.index
			mobile_start = event.position
		elif not event.pressed and event.index == mobile_move_touch:
			mobile_move_touch = -1
			mobile_move = Vector2.ZERO
	if event is InputEventScreenDrag and not drawing_mode:
		if event.index == mobile_move_touch:
			mobile_move = (event.position - mobile_start) / 75.0
			mobile_move = mobile_move.limit_length(1.0)
		elif event.position.x >= get_viewport().get_visible_rect().size.x * 0.45:
			yaw -= event.relative.x * 0.006
			pitch = clampf(pitch - event.relative.y * 0.006, -0.9, 0.3)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -0.9, 0.3)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			drawing_mode = not drawing_mode
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if drawing_mode else Input.MOUSE_MODE_CAPTURED
		if event.keycode == KEY_C:
			_toggle_crouch()
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if event.keycode == KEY_G:
			debug_phase = "SEARCHING" if debug_phase == "DRAWING" else "DRAWING"
		if event.keycode == KEY_TAB:
			spawn_index = 1 - spawn_index
			debug_owner_id = 1 if spawn_index == 0 else 2
			draw_controller.owner_id = debug_owner_id
			walker.global_position = Vector3(ZONE_CENTERS[spawn_index], 1.3, 0)
			walker.velocity = Vector3.ZERO
	if event is InputEventMouseButton and event.pressed and not drawing_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	var direction := Vector2.ZERO
	if drawing_mode:
		direction = Vector2.ZERO
	direction.x = float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT))
	direction.y = float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	direction = (direction + mobile_move).limit_length(1.0)
	if drawing_mode:
		direction = Vector2.ZERO
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var move := (right * direction.x - forward * direction.y)
	var speed := (8.0 if Input.is_key_pressed(KEY_SHIFT) else 5.0) * (0.5 if crouched else 1.0)
	var response := WALK_ACCELERATION if direction.length_squared() > 0.01 else WALK_DECELERATION
	var blend := 1.0 - exp(-response * delta)
	walker.velocity.x = lerpf(walker.velocity.x, move.x * speed, blend)
	walker.velocity.z = lerpf(walker.velocity.z, move.z * speed, blend)
	if walker.is_on_floor():
		if Input.is_key_pressed(KEY_SPACE) or mobile_jump:
			walker.velocity.y = 6.8
		else:
			walker.velocity.y = -0.1
	else:
		walker.velocity.y -= 17.5 * delta
	var before_move := walker.global_position
	walker.move_and_slide()
	if not Territory3D.can_enter(debug_owner_id, walker.global_position, debug_phase, debug_owner_id):
		walker.global_position = before_move
		walker.velocity = Vector3.ZERO
	var target := walker.global_position + Vector3(0, 1.1, 0)
	var offset := Vector3(sin(yaw) * 4.3 * cos(pitch), 1.35 - sin(pitch) * 3.8, cos(yaw) * 4.3 * cos(pitch))
	var desired_camera_position := target + offset
	var camera_query := PhysicsRayQueryParameters3D.create(target, desired_camera_position)
	camera_query.exclude = [walker.get_rid()]
	var camera_hit := get_world_3d().direct_space_state.intersect_ray(camera_query)
	if not camera_hit.is_empty():
		desired_camera_position = camera_hit["position"] + camera_hit["normal"] * 0.2
	# Never interpolate the camera through a building after a phase teleport.
	# Recast after smoothing so the camera cannot enter an opaque wall.
	var candidate := desired_camera_position
	if camera.global_position.distance_to(desired_camera_position) < 12.0:
		candidate = camera.global_position.lerp(desired_camera_position, 1.0 - exp(-CAMERA_FOLLOW_RATE * delta))
	var smooth_query := PhysicsRayQueryParameters3D.create(target, candidate)
	smooth_query.exclude = [walker.get_rid()]
	var smooth_hit := get_world_3d().direct_space_state.intersect_ray(smooth_query)
	if not smooth_hit.is_empty():
		candidate = smooth_hit["position"] + smooth_hit["normal"] * 0.25
	camera.global_position = candidate
	camera.look_at(target)
	info.text = "CHALK GAON | 3D GRAYBOX ONLY\nWASD move | Mouse look | Space jump | Shift run | C crouch | F draw | G phase | Tab role/zone | Esc free mouse\nZone: %s | Position: %s\nNo 2D match, drawing or CPU integration in this scene." % ["PLAYER" if walker.global_position.x < 0 else "CPU", str(walker.global_position.round())]

func _toggle_crouch() -> void:
	var collider := walker.get_node("CollisionShape3D") as CollisionShape3D
	var capsule := collider.shape as CapsuleShape3D
	if crouched:
		var query := PhysicsShapeQueryParameters3D.new()
		var standing := CapsuleShape3D.new()
		standing.radius = 0.35
		standing.height = 1.7
		query.shape = standing
		query.transform = Transform3D(Basis.IDENTITY, walker.global_position)
		query.exclude = [walker.get_rid()]
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			return
		capsule.height = 1.7
		collider.position.y = 0.0
		crouched = false
	else:
		capsule.height = 1.1
		collider.position.y = -0.3
		crouched = true

func _validate_layout() -> void:
	assert(ZONE_CENTERS.size() == 2)
	assert(walker != null and camera != null)
	print("VillageGraybox: scene ready for manual exploration; physics and rooftop tests remain pending")

## World-space waypoints for future territory and navigation adapters.
## These markers do not move the existing CPU or change gameplay rules.
func _add_marker(marker_name: String, marker_position: Vector3) -> void:
	var marker := Marker3D.new()
	marker.name = marker_name
	marker.position = marker_position
	add_child(marker)

func _make_draw_controller() -> void:
	draw_controller = DrawController3D.new()
	draw_controller.name = "DrawController3D"
	add_child(draw_controller)
	draw_controller.configure(camera, walker)
	draw_controller.enabled = false

func _process(_delta: float) -> void:
	if draw_controller != null:
		draw_controller.enabled = drawing_mode and debug_phase == "DRAWING"

## Physically movable concealment props. RigidBody3D provides real collision,
## friction and raycast occlusion; strokes parented here follow the object.
func _add_movable_crate(at: Vector3) -> void:
	var body := RigidBody3D.new()
	body.name = "MovableCrate_%d" % get_child_count()
	body.position = at
	body.mass = 12.0
	body.linear_damp = 2.5
	body.angular_damp = 3.0
	body.add_to_group("graybox_surfaces")
	body.add_to_group("future_movable_props")
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.2, 1.2, 1.2)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	var cube := BoxMesh.new()
	cube.size = shape.size
	var skin := MeshInstance3D.new()
	skin.mesh = cube
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.61, 0.42, 0.18)
	skin.material_override = paint
	body.add_child(skin)
	add_child(body)
