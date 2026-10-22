extends Node3D
## Standalone 3D village exploration graybox. Never replaces the 2D match scene.
## Controls: WASD/arrows move, mouse look, Space jump, Shift sprint, Esc unlock mouse.
const ZONE_HALF := 23.0
const ZONE_CENTERS := [-27.0, 27.0]
const GROUND_COLOR := Color(0.58, 0.45, 0.32)
var walker: CharacterBody3D
var camera: Camera3D
var yaw := 0.0
var pitch := -0.25
var velocity_y := 0.0
var spawn_index := 0
var info: Label

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
	_make_walker()
	_make_ui()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _make_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.25
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.76, 0.86)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.83, 0.78)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)

func _add_box(label: String, pos: Vector3, size: Vector3, color: Color, tilt: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label.validate_node_name()
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
	mesh.material_override = mat
	body.add_child(mesh)
	add_child(body)
	return body

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
	_add_box("Low shelter roof", Vector3(cx - 1, 1.05, 15), Vector3(6, 0.35, 4), Color(0.38, 0.28, 0.19))
	for j in range(3):
		_add_box("Crate_%d" % j, Vector3(cx + 3 + j * 1.6, 0.6, 3 + j * 0.65), Vector3(1.2, 1.2, 1.2), Color(0.43, 0.30, 0.18))
	# Fallen log and adjacent rock provide simple obstructed surfaces.
	_add_box("Fallen log", Vector3(cx - 2, 0.48, -3), Vector3(5, 0.95, 1), Color(0.36, 0.24, 0.15))
	_add_box("Stone", Vector3(cx - 14, 0.65, 12), Vector3(2.5, 1.3, 2.5), Color(0.43, 0.42, 0.39))
	_add_box("Tree trunk", Vector3(cx + 15, 2.1, -13), Vector3(1, 4.2, 1), Color(0.33, 0.21, 0.12))
	_add_box("Tree crown", Vector3(cx + 15, 4.5, -13), Vector3(5, 2, 5), Color(0.27, 0.43, 0.23))
	_add_box("Territory marker", Vector3(cx, 0.05, 0), Vector3(2, 0.1, 2), Color(0.18, 0.45, 0.8) if index == 0 else Color(0.85, 0.35, 0.17))

func _build_house(x: float, z: float, wall: Color) -> void:
	# U-shaped room with doorway gap; roof provides a drawing-ready overhead surface.
	_add_box("House left", Vector3(x - 3.5, 1.6, z), Vector3(0.5, 3.2, 7), wall)
	_add_box("House right", Vector3(x + 3.5, 1.6, z), Vector3(0.5, 3.2, 7), wall)
	_add_box("House back", Vector3(x, 1.6, z - 3.5), Vector3(7, 3.2, 0.5), wall)
	_add_box("Front left", Vector3(x - 2.6, 1.6, z + 3.5), Vector3(1.8, 3.2, 0.5), wall)
	_add_box("Front right", Vector3(x + 2.6, 1.6, z + 3.5), Vector3(1.8, 3.2, 0.5), wall)
	_add_box("Flat roof", Vector3(x, 3.45, z), Vector3(7.7, 0.35, 7.7), Color(0.55, 0.37, 0.28))
	_add_box("Roof parapet", Vector3(x, 3.95, z - 3.7), Vector3(7.7, 0.9, 0.4), wall)
	# Inclined solid ramp is actually walkable, unlike decorative stairs.
	var rise := 3.45
	var run := 10.0
	var angle := atan(rise / run)
	_add_box("Roof access ramp", Vector3(x + 5.5, rise * 0.5, z + 1.5), Vector3(1.9, 0.45, sqrt(run * run + rise * rise)), Color(0.47, 0.44, 0.39), Vector3(angle, 0, 0))
	# Ramp reaches high end at negative z; house roof adjacent to upper end.

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
	var visible := MeshInstance3D.new()
	var cylinder := CapsuleMesh.new()
	cylinder.radius = 0.35
	cylinder.height = 1.7
	visible.mesh = cylinder
	walker.add_child(visible)
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
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -0.9, 0.3)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if event.keycode == KEY_TAB:
			spawn_index = 1 - spawn_index
			walker.global_position = Vector3(ZONE_CENTERS[spawn_index], 1.3, 0)
			walker.velocity = Vector3.ZERO
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	var direction := Vector2.ZERO
	direction.x = float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT))
	direction.y = float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	direction = direction.normalized()
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var move := (right * direction.x - forward * direction.y)
	var speed := 8.0 if Input.is_key_pressed(KEY_SHIFT) else 5.0
	walker.velocity.x = move.x * speed
	walker.velocity.z = move.z * speed
	if walker.is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			walker.velocity.y = 6.8
		else:
			walker.velocity.y = -0.1
	else:
		walker.velocity.y -= 17.5 * delta
	walker.move_and_slide()
	var target := walker.global_position + Vector3(0, 1.1, 0)
	var offset := Vector3(sin(yaw) * 6.5 * cos(pitch), 2.3 - sin(pitch) * 6.5, cos(yaw) * 6.5 * cos(pitch))
	camera.global_position = target + offset
	camera.look_at(target)
	info.text = "CHALK GAON | 3D GRAYBOX ONLY\nWASD move | Mouse look | Space jump | Shift run | Tab swap zone | Esc release mouse\nZone: %s | Position: %s\nNo 2D match, drawing or CPU integration in this scene." % ["PLAYER" if walker.global_position.x < 0 else "CPU", str(walker.global_position.round())]
