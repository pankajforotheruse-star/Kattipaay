class_name VillageArt3D
extends Node3D
## Hand-authored modular village dressing, with shared materials and batched
## low-poly geometry. Major props have matching physical collisions; small
## decorative details never obstruct the player's path.
## All art is original and generated from primitives (no unlicensed assets).
const HOUSE_LOCATIONS := [
	Vector3(-38.0, 0, -10.0), Vector3(-18.0, 0, 9.0),
	Vector3(16.0, 0, -10.0), Vector3(36.0, 0, 9.0)
]
var rng := RandomNumberGenerator.new()
var paint: Dictionary = {}
var detail_level := 1

func _ready() -> void:
	rng.seed = 27051998
	detail_level = clampi(int(ProjectSettings.get_setting("chalk_gaon/3d_art_quality", 1)), 0, 2)
	_make_palette()
	for house in HOUSE_LOCATIONS:
		_dress_house(house)
	for cx in [-27.0, 27.0]:
		_dress_courtyard(cx)
	_make_batched_vegetation()

func _make_palette() -> void:
	var colors := {
		"brick": Color(0.49, 0.28, 0.20), "mortar": Color(0.68, 0.55, 0.40),
		"wood": Color(0.28, 0.17, 0.105), "wood_light": Color(0.44, 0.27, 0.15),
		"terracotta": Color(0.60, 0.32, 0.21), "clay_dark": Color(0.37, 0.19, 0.12),
		"straw": Color(0.72, 0.57, 0.30), "fabric": Color(0.57, 0.17, 0.15),
		"fabric_blue": Color(0.16, 0.31, 0.37), "leaf": Color(0.24, 0.36, 0.18),
		"leaf_light": Color(0.34, 0.44, 0.21), "iron": Color(0.20, 0.21, 0.20),
		"gold": Color(0.72, 0.54, 0.22)
	}
	for key in colors:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[key]
		mat.roughness = 0.92
		mat.metallic = 0.15 if key == "iron" else 0.0
		paint[key] = mat

func _box(label: String, at: Vector3, size: Vector3, material: String, tilt: Vector3 = Vector3.ZERO) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = label
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = paint[material]
	mesh.position = at
	mesh.rotation = tilt
	add_child(mesh)

## Major landmarks use solid colliders and participate in chalk raycasts.
## Ground navigation is built after these bodies enter the scene tree.
func _solid_landmark(label: String, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.position = at
	body.add_to_group("graybox_surfaces")
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	add_child(body)

func _pot(at: Vector3, radius: float) -> void:
	var pot := MeshInstance3D.new()
	pot.name = "HandThrownClayPot"
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.70
	mesh.bottom_radius = radius * 0.53
	mesh.height = radius * 1.7
	mesh.radial_segments = 10 if detail_level == 0 else 16
	pot.mesh = mesh
	pot.material_override = paint["terracotta"]
	pot.position = at + Vector3(0, radius * 0.85, 0)
	add_child(pot)
	# Lip gives the silhouette a recognizable hand-thrown rim.
	if detail_level > 0:
		var lip := MeshInstance3D.new()
		var ring := CylinderMesh.new()
		ring.top_radius = radius * 0.83
		ring.bottom_radius = radius * 0.76
		ring.height = 0.085
		ring.radial_segments = 16
		lip.mesh = ring
		lip.material_override = paint["clay_dark"]
		lip.position = at + Vector3(0, radius * 1.7, 0)
		add_child(lip)

func _dress_house(p: Vector3) -> void:
	# Noncolliding dressing: wooden shutters, brick plinth, door and rafters.
	_box("FrontDoorWoodAjar", p + Vector3(-1.20, 1.2, 4.32), Vector3(1.62, 2.4, 0.10), "wood", Vector3(0, 1.1, 0))
	_box("DoorCrossbeam", p + Vector3(0, 2.48, 3.94), Vector3(2.0, 0.16, 0.15), "wood_light")
	_box("DoorIronLatch", p + Vector3(0.56, 1.2, 3.95), Vector3(0.12, 0.26, 0.07), "iron")
	for side in [-1.0, 1.0]:
		var x: float = float(side) * 2.1
		_box("Shutter", p + Vector3(x, 1.83, 3.81), Vector3(0.83, 1.18, 0.09), "wood_light")
		_box("ShutterBrace", p + Vector3(x, 1.83, 3.89), Vector3(0.12, 1.08, 0.08), "wood")
		_box("RoofRafter", p + Vector3(side * 2.75, 3.72, 3.65), Vector3(0.17, 0.19, 1.2), "wood")
		_pot(p + Vector3(side * 2.65, 0.02, 4.75), 0.38)
	# A short broken brick base avoids making every house look like a box.
	for i in range(8 if detail_level > 0 else 4):
		var x := -3.3 + float(i) * (0.9 if detail_level > 0 else 1.8)
		_box("MudBrickPlinth", p + Vector3(x, 0.24, 3.95), Vector3(0.75, 0.30, 0.18), "brick")
	# Hanging bunting, spaced to avoid excessive draw calls on entry phones.
	if detail_level > 0:
		for i in range(5):
			_box("CourtyardFabricPennant", p + Vector3(-2.4 + float(i) * 1.2, 3.1, 4.7),
				Vector3(0.72, 0.38, 0.035), "fabric" if i % 2 == 0 else "fabric_blue",
				Vector3(0, 0, 0.14 if i % 2 == 0 else -0.14))

func _dress_courtyard(cx: float) -> void:
	# Recognizable village objects: a handpump/well, charpai and pottery.
	var well := Vector3(cx - 4.8, 0, 10.5)
	_solid_landmark("WellPhysicalCollision", well + Vector3(0, 0.55, 0), Vector3(2.25, 1.1, 2.25))
	_box("WellWoodenCover", well + Vector3(0, 1.10, 0), Vector3(2.26, 0.09, 2.26), "wood")
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		_box("WellBrick", well + Vector3(cos(angle) * 1.0, 0.52, sin(angle) * 1.0),
			Vector3(0.82, 1.0, 0.34), "brick", Vector3(0, -angle, 0))
	_box("WellCrossbar", well + Vector3(0, 2.05, 0), Vector3(2.5, 0.18, 0.18), "wood")
	for sign_side in [-1.0, 1.0]:
		_box("WellSupport", well + Vector3(sign_side * 1.15, 1.52, 0),
			Vector3(0.15, 1.25, 0.15), "wood")
	var bed := Vector3(cx + 9.5, 0.0, -12.0)
	_solid_landmark("CharpaiPhysicalCollision", bed + Vector3(0, 0.33, 0), Vector3(2.6, 0.66, 1.35))
	_box("CharpaiWovenBed", bed + Vector3(0, 0.58, 0), Vector3(2.6, 0.15, 1.35), "straw")
	for dx in [-1.15, 1.15]:
		for dz in [-0.52, 0.52]:
			_box("CharpaiLeg", bed + Vector3(dx, 0.34, dz), Vector3(0.17, 0.68, 0.17), "wood")
	for offset in [Vector3(-12, 0, 13), Vector3(11, 0, 13), Vector3(16, 0, -8)]:
		_pot(Vector3(cx, 0, 0) + offset, rng.randf_range(0.28, 0.49))
	# Straw bundles are grouped near the shed, not scattered into walk routes.
	for i in range(4):
		var at := Vector3(cx + 16.5 + float(i % 2) * 0.65, 0.45, 18.2 + float(i / 2) * 0.65)
		var bale := MeshInstance3D.new()
		bale.name = "HayBundle"
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.45
		mesh.bottom_radius = 0.47
		mesh.height = 1.1
		mesh.radial_segments = 8
		bale.mesh = mesh
		bale.material_override = paint["straw"]
		bale.position = at
		bale.rotation.z = PI * 0.5
		add_child(bale)

func _make_batched_vegetation() -> void:
	# Hundreds of tiny low-poly grass clumps become only two MultiMesh draw calls.
	var amount := 120 if detail_level == 0 else 320 if detail_level == 1 else 560
	for color_key in ["leaf", "leaf_light"]:
		var mesh := PrismMesh.new()
		mesh.size = Vector3(0.23, 0.36, 0.12)
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = mesh
		batch.instance_count = amount
		for i in range(amount):
			var x := rng.randf_range(-50.0, 50.0)
			var z := rng.randf_range(-22.0, 22.0)
			# Keep the central meeting and spawn corridors readable.
			if absf(x) < 5.0 or (absf(z) < 4.0 and absf(x + 27.0) < 5.0) or (absf(z) < 4.0 and absf(x - 27.0) < 5.0):
				z = 18.0 + rng.randf_range(-2.0, 2.0)
			var transform := Transform3D(Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
				Vector3(rng.randf_range(0.7, 1.35), rng.randf_range(0.65, 1.2), 1.0)), Vector3(x, 0.17, z))
			batch.set_instance_transform(i, transform)
		var inst := MultiMeshInstance3D.new()
		inst.name = "BatchedGrass_" + color_key
		inst.multimesh = batch
		inst.material_override = paint[color_key]
		add_child(inst)
