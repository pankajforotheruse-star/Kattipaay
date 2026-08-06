# HintMarker.gd — World-space hint icon for CHALK GAON: Ghost Lines
#
# Drawn entirely via _draw() — zero texture assets.
# Represents either a real (spectator-revealed) or fake (ghost-placed trap) hint.
# Visually identical for searchers — the deception core. Only spectators see
# the difference (real=green tint, fake=red tint).
#
# Exists as a Node2D child of GameWorld, managed by HintSystem.

class_name HintMarker
extends Node2D

# ── Enums ─────────────────────────────────────────────────────────────────────

enum Type {
	REAL,   # Spectator-revealed — corresponds to a real ghost line
	FAKE,   # Ghost-placed trap — decoy with no real line behind it
}

# ── Properties ────────────────────────────────────────────────────────────────

## Whether this is a REAL or FAKE hint.
var type: int = Type.REAL

## World position (redundant with Node2D.position, but explicit for clarity).
## Set during initialization; Node2D.position is the source of truth.
var world_position: Vector2 = Vector2.ZERO:
	set(v):
		world_position = v
		position = v

## The ghost line ID this hint corresponds to (only for REAL hints, -1 for FAKE).
var associated_line_id: int = -1

## Unique hint ID assigned by HintSystem.
var hint_id: int = -1

## Whether this hint is active (hasn't been investigated yet).
var is_active: bool = true

## The peer/entity ID of the spectator who revealed this (REAL only).
var spectator_id: int = -1

## The peer/entity ID of the ghost who placed this (FAKE only).
var drawer_id: int = -1

# ── Visual Constants ──────────────────────────────────────────────────────────

const BASE_RADIUS := 24.0
const GLOW_COLOR := Color(0.831, 0.627, 0.09, 1.0)   # #D4A017 mustard/gold
const PULSE_ALPHA_MIN := 0.4
const PULSE_ALPHA_MAX := 0.7
const PULSE_PERIOD := 1.5   # seconds for full pulse cycle
const ORBIT_COUNT := 3
const ORBIT_RADIUS := 32.0
const QUESTION_COLOR := Color(1.0, 1.0, 0.95, 0.9)
const REAL_TINT := Color(0.3, 1.0, 0.3, 0.4)    # Green tint for spectator view
const FAKE_TINT := Color(1.0, 0.3, 0.3, 0.4)    # Red tint for spectator view
const PROXIMITY_SCALE := 1.2
const PROXIMITY_RANGE := 80.0

# ── Runtime State ─────────────────────────────────────────────────────────────

var _pulse_time: float = 0.0
var _orbit_angles: Array[float] = []
var _proximity_scale_target: float = 1.0
var _current_scale: float = 1.0
var _is_nearby: bool = false
var _fade_alpha: float = 1.0
var _dying: bool = false
var _death_tween: Tween = null

# Spectator-only tint
var _spectator_mode: bool = false
var _tint_color: Color = Color.TRANSPARENT


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Randomize orbit angles
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(ORBIT_COUNT):
		_orbit_angles.append(rng.randf_range(0.0, TAU))


func _process(delta: float) -> void:
	if _dying:
		return

	# Pulse
	_pulse_time += delta

	# Animate orbit dots
	for i in range(_orbit_angles.size()):
		_orbit_angles[i] += delta * 1.8
		if _orbit_angles[i] > TAU:
			_orbit_angles[i] -= TAU

	# Proximity scale smoothing
	var target := PROXIMITY_SCALE if _is_nearby else 1.0
	_current_scale = lerpf(_current_scale, target, delta * 8.0)

	queue_redraw()


func _draw() -> void:
	if not is_active and not _dying:
		return

	var alpha_mult := _fade_alpha
	var pulse_alpha := PULSE_ALPHA_MIN + (PULSE_ALPHA_MAX - PULSE_ALPHA_MIN) * \
		(sin(_pulse_time * TAU / PULSE_PERIOD) * 0.5 + 0.5)
	var effective_alpha := pulse_alpha * alpha_mult
	var effective_radius := BASE_RADIUS * _current_scale

	# Outer glow (soft circle)
	var glow_inner := GLOW_COLOR
	glow_inner.a = effective_alpha * 0.3
	var glow_outer := GLOW_COLOR
	glow_outer.a = 0.0
	draw_circle(Vector2.ZERO, effective_radius * 1.3, glow_inner)
	draw_circle(Vector2.ZERO, effective_radius * 0.95, Color(glow_inner, effective_alpha * 0.6))

	# Main circle border
	var border_color := GLOW_COLOR
	border_color.a = effective_alpha
	draw_arc(Vector2.ZERO, effective_radius, 0.0, TAU, 32, border_color, 2.5)

	# Fill
	var fill_color := GLOW_COLOR
	fill_color.a = effective_alpha * 0.25
	draw_circle(Vector2.ZERO, effective_radius - 2.0, fill_color)

	# Spectator tint overlay
	if _spectator_mode:
		var tint := _tint_color
		tint.a *= effective_alpha
		draw_circle(Vector2.ZERO, effective_radius * 1.2, tint)

	# Question mark "?" — drawn with simple line-art
	var q_color := QUESTION_COLOR
	q_color.a = effective_alpha
	var q_size := effective_radius * 0.7
	# Top curve of "?" — an arc
	draw_arc(Vector2(0, -q_size * 0.25), q_size * 0.4, PI * 0.2, PI * 0.95, 8, q_color, 2.0)
	# Vertical stem
	draw_line(Vector2(0, -q_size * 0.25 + q_size * 0.35), Vector2(0, q_size * 0.4), q_color, 2.0)
	# Dot at bottom
	draw_circle(Vector2(0, q_size * 0.65), 2.5, q_color)

	# Orbiting dots
	var dot_color := GLOW_COLOR
	dot_color.a = effective_alpha * 0.7
	for angle in _orbit_angles:
		var dot_pos := Vector2.RIGHT.rotated(angle) * ORBIT_RADIUS * _current_scale
		draw_circle(dot_pos, 3.0, dot_color)
		# Tiny trail
		var trail_pos := Vector2.RIGHT.rotated(angle - 0.3) * ORBIT_RADIUS * _current_scale
		dot_color.a = effective_alpha * 0.3
		draw_circle(trail_pos, 1.5, dot_color)


# ── Public Methods ────────────────────────────────────────────────────────────

## Called by HintSystem when a searcher enters/leaves proximity range.
func set_nearby(nearby: bool) -> void:
	_is_nearby = nearby


## Called by HintSystem for spectator view — shows tint to distinguish real/fake.
func set_spectator_view(enabled: bool) -> void:
	_spectator_mode = enabled
	if enabled:
		_tint_color = REAL_TINT if type == Type.REAL else FAKE_TINT
	else:
		_tint_color = Color.TRANSPARENT
	queue_redraw()


## Play REAL investigation result: green flash, fade out over 0.5s.
func play_real_result() -> void:
	_dying = true
	is_active = false

	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()

	_death_tween = create_tween()
	_death_tween.set_parallel(false)
	# Flash green
	_death_tween.tween_callback(func():
		_fade_alpha = 1.0
		# Override pulse to show green
		var prev_pulse := _pulse_time
		_pulse_time = 0.0
	)
	_death_tween.tween_method(
		func(a: float): _fade_alpha = a,
		1.0, 0.0, 0.5
	)
	_death_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_death_tween.tween_callback(func():
		queue_free()
	)


## Play FAKE investigation result: red flash, scale-down burst over 0.3s.
func play_fake_result() -> void:
	_dying = true
	is_active = false

	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()

	_death_tween = create_tween()
	_death_tween.set_parallel(false)
	# Flash red + burst scale
	_death_tween.tween_callback(func():
		_current_scale = PROXIMITY_SCALE + 0.3
	)
	_death_tween.tween_property(self, "scale", Vector2(0.05, 0.05), 0.3)
	_death_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	# Simultaneously fade alpha
	var fade_tween := create_tween()
	fade_tween.tween_method(
		func(a: float): _fade_alpha = a,
		1.0, 0.0, 0.3
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	_death_tween.tween_callback(func():
		queue_free()
	)


## Get the world position of this marker (convenience).
func get_world_position() -> Vector2:
	return global_position
