# Cow.gd — Meta-drawn cow entity for CHALK GAON: Ghost Lines
# World-space Node2D, entirely _draw() — zero texture assets.
# Used by SilentSneakSystem as the distraction animal.
class_name Cow
extends Node2D

# ── Constants ──────────────────────────────────────────────────────────────
const BODY_COLOR := Color(0.96, 0.94, 0.91, 1.0)  # #F5F0E8 off-white
const HORN_COLOR := Color(0.55, 0.45, 0.33, 1.0)  # #8B7355 brown
const MUD_COLOR := Color(0.42, 0.26, 0.15, 1.0)   # #6B4226 mud brown
const SPOT_COLOR := Color(0.55, 0.45, 0.33, 0.6)   # semi-transparent brown
const UDDER_COLOR := Color(0.95, 0.7, 0.75, 1.0)   # pink
const WANDER_SPEED := 30.0
const BOB_AMPLITUDE := 2.0
const WALK_AMPLITUDE := 4.0
const MUD_SPLASH_DURATION := 0.6
const FADE_DURATION := 0.5
const MOO_DURATION := 0.3

# ── State ──────────────────────────────────────────────────────────────────
var _wander_center: Vector2 = Vector2.ZERO
var _wander_range: float = 150.0
var _wander_direction: Vector2 = Vector2.RIGHT
var _wander_timer: float = 0.0
var _wander_next_change: float = 1.5
var _time_alive: float = 0.0
var _is_walking: bool = false
var _moo_timer: float = 0.0
var _is_mooing: bool = false
var _mud_splash_timer: float = 0.0
var _mud_splash_active: bool = true
var _fading: bool = false
var _fade_timer: float = 0.0

# Random spot positions — generated once on init
var _spot_positions: Array[Vector2] = []
var _spot_sizes: Array[float] = []

func _ready() -> void:
	_generate_spots()
	_mud_splash_timer = MUD_SPLASH_DURATION
	# Start with a moo
	moo()

func _generate_spots() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var count := rng.randi_range(3, 5)
	for i in count:
		var x := rng.randf_range(-18.0, 12.0)
		var y := rng.randf_range(-10.0, 10.0)
		_spot_positions.append(Vector2(x, y))
		_spot_sizes.append(rng.randf_range(4.0, 10.0))

func _process(delta: float) -> void:
	_time_alive += delta
	
	# Mud splash timer
	if _mud_splash_active:
		_mud_splash_timer -= delta
		if _mud_splash_timer <= 0.0:
			_mud_splash_active = false
	
	# Moo timer
	if _is_mooing:
		_moo_timer -= delta
		if _moo_timer <= 0.0:
			_is_mooing = false
	
	# Fade timer
	if _fading:
		_fade_timer += delta
		modulate.a = 1.0 - (_fade_timer / FADE_DURATION)
		if _fade_timer >= FADE_DURATION:
			queue_free()
			return
	
	# Wander behavior
	if not _fading:
		_wander_timer += delta
		if _wander_timer >= _wander_next_change:
			_wander_timer = 0.0
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			_wander_next_change = rng.randf_range(1.0, 2.0)
			_wander_direction = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
			_is_walking = true
		
		if _is_walking:
			var move := _wander_direction * WANDER_SPEED * delta
			position += move
			# Stay within range of center
			var dist := position.distance_to(_wander_center)
			if dist > _wander_range:
				# Turn back toward center
				_wander_direction = (_wander_center - position).normalized()
			# Small chance to stop walking
			if _wander_timer > _wander_next_change * 0.7:
				_is_walking = false
	
	queue_redraw()

func _draw() -> void:
	var bob_offset := 0.0
	if _is_walking:
		bob_offset = sin(_time_alive * 8.0) * WALK_AMPLITUDE
	else:
		bob_offset = sin(_time_alive * 5.0) * BOB_AMPLITUDE
	
	var body_y := bob_offset
	var head_tilt := 0.0
	if _is_mooing:
		var moo_progress := 1.0 - (_moo_timer / MOO_DURATION)
		head_tilt = sin(moo_progress * PI) * 15.0
	
	# ── Legs ──────────────────────────────────────────────────────────
	var leg_offset := 0.0
	if _is_walking:
		leg_offset = sin(_time_alive * 10.0) * 4.0
	
	_draw_leg(Vector2(-14.0, 14.0) + Vector2(0, body_y), leg_offset)
	_draw_leg(Vector2(-6.0, 14.0) + Vector2(0, body_y), -leg_offset)
	_draw_leg(Vector2(6.0, 14.0) + Vector2(0, body_y), -leg_offset)
	_draw_leg(Vector2(14.0, 14.0) + Vector2(0, body_y), leg_offset)
	
	# ── Tail ──────────────────────────────────────────────────────────
	var tail_points := PackedVector2Array([
		Vector2(-24.0, body_y - 4.0),
		Vector2(-30.0, body_y - 12.0),
		Vector2(-28.0, body_y - 20.0)
	])
	draw_polyline(tail_points, HORN_COLOR, 2.0)
	draw_circle(Vector2(-28.0, body_y - 20.0), 3.0, HORN_COLOR)
	
	# ── Body ──────────────────────────────────────────────────────────
	draw_ellipse_filled(Vector2(0, body_y), 24.0, 16.0, BODY_COLOR)
	
	# ── Spots ─────────────────────────────────────────────────────────
	for i in _spot_positions.size():
		draw_ellipse_filled(_spot_positions[i] + Vector2(0, body_y), _spot_sizes[i] * 0.7, _spot_sizes[i] * 0.5, SPOT_COLOR)
	
	# ── Udder ─────────────────────────────────────────────────────────
	draw_ellipse_filled(Vector2(4.0, body_y + 14.0), 6.0, 4.0, UDDER_COLOR)
	
	# ── Head ──────────────────────────────────────────────────────────
	var head_center := Vector2(20.0, body_y - 6.0)
	# Rotate head for moo
	var head_offset := Vector2(0.0, -sin(deg_to_rad(head_tilt)) * 8.0)
	draw_ellipse_filled(head_center + head_offset, 10.0, 9.0, BODY_COLOR)
	
	# ── Horns ─────────────────────────────────────────────────────────
	draw_arc(head_center + head_offset + Vector2(-4.0, -8.0), 6.0, deg_to_rad(200.0), deg_to_rad(310.0), 8, HORN_COLOR, 2.0)
	draw_arc(head_center + head_offset + Vector2(4.0, -8.0), 6.0, deg_to_rad(230.0), deg_to_rad(340.0), 8, HORN_COLOR, 2.0)
	
	# ── Eyes ──────────────────────────────────────────────────────────
	draw_circle(head_center + head_offset + Vector2(3.0, -3.0), 2.0, Color.BLACK)
	draw_circle(head_center + head_offset + Vector2(9.0, -3.0), 2.0, Color.BLACK)
	
	# ── Mouth (visible during moo) ──────────────────────────────────
	if _is_mooing:
		var moo_progress := 1.0 - (_moo_timer / MOO_DURATION)
		var mouth_open := sin(moo_progress * PI) * 4.0
		draw_arc(head_center + head_offset + Vector2(10.0, 0.0), mouth_open, deg_to_rad(20.0), deg_to_rad(160.0), 6, Color.BLACK, 1.5)
	
	# ── Mud splash ────────────────────────────────────────────────────
	if _mud_splash_active:
		var progress := 1.0 - (_mud_splash_timer / MUD_SPLASH_DURATION)
		var base_radius := lerpf(4.0, 24.0, progress)
		var alpha := lerpf(0.7, 0.0, progress)
		var mud_color := Color(MUD_COLOR.r, MUD_COLOR.g, MUD_COLOR.b, alpha)
		
		var rng := RandomNumberGenerator.new()
		rng.seed = 42  # fixed seed for consistency within frame
		var offsets := [
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
			Vector2(rng.randf_range(-10.0, 10.0), 18.0 + rng.randf_range(-6.0, 6.0)),
		]
		for off in offsets:
			draw_circle(off + Vector2(0, body_y), base_radius + rng.randf_range(-4.0, 4.0), mud_color)

# ── Helpers ─────────────────────────────────────────────────────────────────

func _draw_leg(pos: Vector2, phase_offset: float) -> void:
	var top := pos
	var bottom := pos + Vector2(0, 14.0)
	# Simple leg swing
	bottom.y += phase_offset * 3.0
	draw_line(top, bottom, HORN_COLOR, 6.0)

func draw_ellipse_filled(center: Vector2, rx: float, ry: float, color: Color) -> void:
	# Approximate ellipse with a scaled circle
	# Godot's draw_circle doesn't support ellipse, so we use draw_polygon
	var points := PackedVector2Array()
	var segments := 24
	for i in segments:
		var angle := float(i) / segments * TAU
		var x := center.x + cos(angle) * rx
		var y := center.y + sin(angle) * ry
		points.append(Vector2(x, y))
	draw_colored_polygon(points, color)

# ── Public API ──────────────────────────────────────────────────────────────

func moo() -> void:
	_is_mooing = true
	_moo_timer = MOO_DURATION

func start_wandering(center: Vector2, range_val: float) -> void:
	_wander_center = center
	_wander_range = range_val
	# Start moving immediately
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_wander_direction = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
	_is_walking = true

func despawn() -> void:
	if _fading:
		return
	_fading = true
	_fade_timer = 0.0
