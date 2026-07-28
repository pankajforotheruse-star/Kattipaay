# FogSystem.gd — Fog of war / searching mechanic for CHALK GAON: Ghost Lines
#
# Pluggable system: node under GameWorld/Systems. ZERO coupling to other systems —
# communicates exclusively through EventBus.
#
# Architecture:
#   - CanvasLayer (layer 3) with full-screen ColorRect using fog_of_war.gdshader
#   - SubViewport (360×640) that renders a low-res "reveal map" via RevealDrawer
#   - RevealDrawer draws world-space circles: white for active vision, gray for explored
#   - The shader converts screen UV → world position → texture UV → fog level
#
# Responsibilities:
#   - Full fog cover on entering SEARCHING match state
#   - Circular vision reveal around player touch (single-finger, touches the map)
#   - Two-layer fog: explored (persistent dim) + active vision (clear)
#   - Chalk line visibility modulation through fog
#   - Ghost pulse effects on ghost-line crossings
#   - Smooth fog transitions on state changes (roll-in, dramatic clear, fade-out)
#
# Performance:
#   - Viewport at quarter-resolution (360×640 vs 720×1280)
#   - Redraw throttled to 30fps + 10px minimum movement threshold
#   - UPDATE_DISABLED render mode with manual UPDATE_ONCE triggers
#   - Single texture sample per fragment, no loops in shader

class_name FogSystem
extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

## Fog color — deep purple from the village night palette (#1A1030).
const FOG_COLOR := Color(0.102, 0.063, 0.188, 1.0)

## Fog opacity when fully active (85%).
const FOG_OPACITY := 0.85

## Opacity for explored-but-not-currently-visible areas (60% fog).
const EXPLORED_OPACITY := 0.6

## Vision circle total effect radius (world pixels).
const VISION_RADIUS := 200.0

## Clear zone radius inside the vision circle (inner 150px, outer 50px falloff).
const CLEAR_RADIUS := 150.0

## Max redraw rate for the reveal texture (Hz).
const REDRAW_MAX_FPS := 30.0

## Minimum distance vision circle must move before triggering a redraw (pixels).
const MIN_REDRAW_DISTANCE := 10.0

## Lerp factor for vision circle position smoothing (trails slightly behind finger).
const VISION_LERP_FACTOR := 0.15

## Reveal texture resolution (scaled from reference 720×1280).
const VIEWPORT_WIDTH := 360
const VIEWPORT_HEIGHT := 640

## Ghost-line crossing pulse radius (world pixels).
const GHOST_PULSE_RADIUS := 300.0

## Ghost-line crossing pulse duration (seconds).
const GHOST_PULSE_DURATION := 1.5

## Fog roll-in animation duration (seconds, ease-in-out).
const FOG_ROLL_IN_DURATION := 1.5

## Dramatic fog clear duration (seconds, SEARCHING → REVEAL).
const FOG_DRAMATIC_CLEAR_DURATION := 0.8

## Smooth fog fade-out duration (seconds, SEARCHING → DRAWING).
const FOG_SMOOTH_FADE_DURATION := 1.0

## Opacity for chalk lines that have never been revealed (15%).
const LINE_FOG_OPACITY := 0.15

## Opacity for chalk lines that were revealed but are no longer visible (40%).
const LINE_DISCOVERY_OPACITY := 0.40

## Duration newly-drawn lines stay at full opacity (seconds).
const NEW_LINE_HIGHLIGHT_DURATION := 2.0

## Maximum explored area entries before FIFO eviction starts.
const MAX_EXPLORED_AREAS := 800

## Maximum active pulses tracked simultaneously.
const MAX_PULSES := 8

# ── Nodes ──────────────────────────────────────────────────────────────────────

var _fog_layer: CanvasLayer = null
var _fog_rect: ColorRect = null
var _fog_material: ShaderMaterial = null
var _reveal_viewport: SubViewport = null
var _reveal_drawer: RevealDrawer = null

# ── State ──────────────────────────────────────────────────────────────────────

var _is_active: bool = false
var _is_paused: bool = false
var _redraw_timer: float = 0.0
var _redraw_needed: bool = false

## Vision circles: { player_id : { target_pos, current_pos, last_draw_pos, radius } }
var _vision_circles: Dictionary = {}

## Explored areas: persisted across redraws, drawn as gray circles.
## [{ position: Vector2, radius: float }]
var _explored_areas: Array[Dictionary] = []

## Active ghost pulses: [{ center, radius, strength, initial_strength, start_time, duration }]
var _pulses: Array[Dictionary] = []

## Line reveal timestamps: { line_id : reveal_time }
var _revealed_line_ids: Dictionary = {}

## World bounds (populated from Map or defaults).
var _world_bounds_min := Vector2.ZERO
var _world_bounds_size := Vector2(2400.0, 1800.0)

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_setup_fog_layer()
	_setup_reveal_viewport()
	_setup_shader()

	# Subscribe to game events
	EventBus.on("match.state_changed", _on_match_state_changed)
	EventBus.on("game.line_drawn", _on_line_drawn)
	EventBus.on("game.ghost_touches_line", _on_ghost_touches_line)
	EventBus.on("input.move_start", _on_input_move_start)
	EventBus.on("game.world_ready", _on_world_ready)

	print("FogSystem: ready — viewport %dx%d" % [VIEWPORT_WIDTH, VIEWPORT_HEIGHT])


func _process(delta: float) -> void:
	if not _is_active or _is_paused:
		return

	# Smooth vision circle lerp toward target touch positions
	_update_vision_circles(delta)

	# Decay pulse strengths
	_update_pulses(delta)

	# Throttled redraw
	_redraw_timer += delta
	if _redraw_needed and _redraw_timer >= (1.0 / REDRAW_MAX_FPS):
		_redraw_timer = 0.0
		_do_redraw()
		_redraw_needed = false
		# Trigger SubViewport render
		_reveal_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Push camera/world transform uniforms to shader each frame
	_update_shader_uniforms()


func _exit_tree() -> void:
	EventBus.off("match.state_changed", _on_match_state_changed)
	EventBus.off("game.line_drawn", _on_line_drawn)
	EventBus.off("game.ghost_touches_line", _on_ghost_touches_line)
	EventBus.off("input.move_start", _on_input_move_start)
	EventBus.off("game.world_ready", _on_world_ready)


# ── Setup ──────────────────────────────────────────────────────────────────────

func _setup_fog_layer() -> void:
	_fog_layer = CanvasLayer.new()
	_fog_layer.name = "FogLayer"
	_fog_layer.layer = 3  # Above game world (0), below HUD (layer 2+)
	add_child(_fog_layer)

	_fog_rect = ColorRect.new()
	_fog_rect.name = "FogRect"
	_fog_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fog_rect.color = Color.WHITE  # Base is white; shader applies fog tint
	_fog_rect.visible = false
	_fog_layer.add_child(_fog_rect)


func _setup_reveal_viewport() -> void:
	_reveal_viewport = SubViewport.new()
	_reveal_viewport.name = "RevealViewport"
	_reveal_viewport.size = Vector2i(VIEWPORT_WIDTH, VIEWPORT_HEIGHT)
	_reveal_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_reveal_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_reveal_viewport.transparent_bg = false
	# Clear color is black (unrevealed)
	_reveal_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_TEXTURE_FILTER_LINEAR
	add_child(_reveal_viewport)

	# Camera2D for world-space → texture coordinate mapping.
	# Positioned at world center, zoomed to fit the entire map bounds.
	var camera := Camera2D.new()
	camera.name = "RevealCamera"
	camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	var zoom_x := _world_bounds_size.x / float(VIEWPORT_WIDTH)
	var zoom_y := _world_bounds_size.y / float(VIEWPORT_HEIGHT)
	camera.zoom = Vector2(zoom_x, zoom_y)
	camera.position = _world_bounds_min
	camera.enabled = true
	_reveal_viewport.add_child(camera)

	# Reveal drawer node (world-space drawing)
	_reveal_drawer = RevealDrawer.new()
	_reveal_drawer.name = "RevealDrawer"
	_reveal_viewport.add_child(_reveal_drawer)

	# Initial clear: render black texture
	_reveal_drawer.queue_redraw()
	await get_tree().process_frame
	_reveal_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	_reveal_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _setup_shader() -> void:
	var shader := load("res://assets/shaders/fog_of_war.gdshader") as Shader
	if not shader:
		push_error("FogSystem: fog_of_war.gdshader not found — fog disabled")
		return

	_fog_material = ShaderMaterial.new()
	_fog_material.shader = shader

	# Static uniforms
	_fog_material.set_shader_parameter("reveal_texture", _reveal_viewport.get_texture())
	_fog_material.set_shader_parameter("fog_color", FOG_COLOR)
	_fog_material.set_shader_parameter("fog_opacity", FOG_OPACITY)
	_fog_material.set_shader_parameter("explored_opacity", EXPLORED_OPACITY)
	_fog_material.set_shader_parameter("world_bounds_min", _world_bounds_min)
	_fog_material.set_shader_parameter("world_bounds_size", _world_bounds_size)
	_fog_material.set_shader_parameter("line_fog_opacity", LINE_FOG_OPACITY)

	# Dynamic uniforms (updated each frame)
	_fog_material.set_shader_parameter("pulse_strength", 0.0)
	_fog_material.set_shader_parameter("pulse_center", Vector2(-10000, -10000))
	_fog_material.set_shader_parameter("pulse_radius", GHOST_PULSE_RADIUS)

	_fog_rect.material = _fog_material


# ── Per-Frame Updates ──────────────────────────────────────────────────────────

func _update_vision_circles(delta: float) -> void:
	for player_id in _vision_circles:
		var circle: Dictionary = _vision_circles[player_id]
		var target: Vector2 = circle["target_pos"]
		var current: Vector2 = circle["current_pos"]

		# Lerp toward target (trails slightly behind fast finger movement)
		var new_pos := current.lerp(target, VISION_LERP_FACTOR)

		# Snap if very close (prevents eternal micro-lerping)
		if new_pos.distance_to(target) < 1.0:
			new_pos = target

		circle["current_pos"] = new_pos

		# Trigger redraw if moved enough
		if new_pos.distance_to(circle.get("last_draw_pos", new_pos)) > MIN_REDRAW_DISTANCE:
			_redraw_needed = true


func _update_pulses(_delta: float) -> void:
	if _pulses.is_empty():
		return

	var now := Time.get_ticks_msec() / 1000.0
	var i := _pulses.size() - 1
	while i >= 0:
		var p: Dictionary = _pulses[i]
		var elapsed := now - p["start_time"]
		if elapsed > p["duration"]:
			_pulses.remove_at(i)
		else:
			# Exponential decay: strength decays by factor of e every ~0.33s (aggressive fade)
			p["strength"] = p["initial_strength"] * exp(-elapsed * 3.0)
		i -= 1


func _update_shader_uniforms() -> void:
	if not _fog_material:
		return

	var camera := get_viewport().get_camera_2d()
	if camera:
		_fog_material.set_shader_parameter("camera_position", camera.global_position)
		var viewport_size := get_viewport().get_visible_rect().size
		var half := viewport_size / (2.0 * camera.zoom)
		_fog_material.set_shader_parameter("viewport_world_half", half)

	# Set strongest active pulse
	if _pulses.size() > 0:
		var strongest: Dictionary = _pulses[0]
		for p in _pulses:
			if p["strength"] > strongest["strength"]:
				strongest = p
		_fog_material.set_shader_parameter("pulse_center", strongest["center"])
		_fog_material.set_shader_parameter("pulse_strength", strongest["strength"])
	else:
		_fog_material.set_shader_parameter("pulse_strength", 0.0)


func _do_redraw() -> void:
	# Clear only active entries each frame; explored areas persist
	_reveal_drawer.clear_entries(true)

	# Draw explored areas as gray (persistent dim overlay)
	for area in _explored_areas:
		_reveal_drawer.add_reveal(area["position"], area["radius"], false)

	# Draw active vision circles as white
	for player_id in _vision_circles:
		var circle: Dictionary = _vision_circles[player_id]
		var pos: Vector2 = circle["current_pos"]
		var radius: float = circle.get("radius", VISION_RADIUS)

		circle["last_draw_pos"] = pos
		_reveal_drawer.add_reveal(pos, radius, true)

		# Accumulate into explored areas (with position quantization to reduce duplicates)
		_add_explored_area(pos, radius)

	_reveal_drawer.queue_redraw()


func _add_explored_area(pos: Vector2, radius: float) -> void:
	# Avoid duplicate entries: skip if this position is very close to an existing one
	for area in _explored_areas:
		if pos.distance_squared_to(area["position"]) < (radius * radius * 0.25):
			return

	_explored_areas.append({"position": pos, "radius": radius})

	# FIFO eviction when exceeding max
	while _explored_areas.size() > MAX_EXPLORED_AREAS:
		_explored_areas.pop_front()


# ── Event Handlers ─────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)

	# Enter SEARCHING
	if to_state == GameState.MatchState.SEARCHING:
		activate()

	# Exit SEARCHING
	elif from_state == GameState.MatchState.SEARCHING:
		if to_state == GameState.MatchState.REVEAL:
			_dramatic_clear()
		elif to_state == GameState.MatchState.DRAWING:
			_smooth_fade_out(FOG_SMOOTH_FADE_DURATION)
		else:
			deactivate()

	# PAUSED → any (resume)
	elif from_state == GameState.MatchState.PAUSED:
		if _is_paused:
			_is_paused = false

	# Any → PAUSED
	elif to_state == GameState.MatchState.PAUSED:
		_is_paused = true


func _on_world_ready(_payload = null) -> void:
	# When the game world is ready, we could read map bounds from the Map node.
	# For now, use defaults. Future: query Map.gd → get_world_bounds().
	pass


func _on_input_move_start(payload: Dictionary) -> void:
	# Only process during SEARCHING state
	if not _is_active or _is_paused:
		return
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		return

	var screen_pos: Vector2 = payload.get("screen_position", Vector2.ZERO)
	var world_pos := InputManager.screen_to_world(screen_pos)
	var player_id: int = payload.get("entity_id", 1)

	add_vision_circle(player_id, world_pos, VISION_RADIUS)

	EventBus.emit("game.fog_revealed", {
		"player_id": player_id,
		"position": world_pos,
		"radius": VISION_RADIUS,
	})


func _on_line_drawn(payload: Dictionary) -> void:
	var line_id: int = payload.get("line_id", -1)
	if line_id < 0:
		return
	# Newly drawn lines are auto-revealed (full opacity for 2 seconds)
	_revealed_line_ids[line_id] = Time.get_ticks_msec() / 1000.0


func _on_ghost_touches_line(payload: Dictionary) -> void:
	# Ghost crossed a chalk line — trigger a vision pulse.
	# The GhostSystem is responsible for providing the ghost's world position.
	# For now we accept an optional position in the payload.
	var ghost_pos: Vector2 = payload.get("position", Vector2.ZERO)
	if ghost_pos != Vector2.ZERO:
		trigger_ghost_pulse(ghost_pos)
	EventBus.emit("game.fog_ghost_pulse", {
		"position": ghost_pos,
		"radius": GHOST_PULSE_RADIUS,
		"duration": GHOST_PULSE_DURATION,
	})


# ── Public API ─────────────────────────────────────────────────────────────────

## Activate fog of war. Rolls fog in from edges over FOG_ROLL_IN_DURATION seconds.
func activate() -> void:
	if _is_active:
		return

	_is_active = true
	_is_paused = false

	_fog_rect.visible = true
	_fog_rect.modulate.a = 0.0

	var tween := create_tween()
	tween.tween_property(_fog_rect, "modulate:a", 1.0, FOG_ROLL_IN_DURATION)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)

	EventBus.emit("game.fog_activated", {})
	print("FogSystem: fog rolling in over %.1fs" % FOG_ROLL_IN_DURATION)


## Deactivate fog of war. Hides fog immediately (no animation).
func deactivate() -> void:
	if not _is_active:
		return

	_is_active = false
	_is_paused = false

	if is_instance_valid(_fog_rect):
		_fog_rect.visible = false

	EventBus.emit("game.fog_deactivated", {})
	print("FogSystem: deactivated")


## Dramatic fog clear — bright flash then clear (SEARCHING → REVEAL).
func _dramatic_clear() -> void:
	if not _is_active:
		return

	# Flash white briefly, then clear
	var tween := create_tween()
	tween.set_parallel(false)

	# Flash: briefly make the fog_rect fully opaque white
	tween.tween_property(_fog_rect, "modulate", Color.WHITE, 0.15)
	tween.tween_property(_fog_rect, "modulate:a", 0.0, FOG_DRAMATIC_CLEAR_DURATION - 0.15)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN)

	tween.tween_callback(func():
		_is_active = false
		if is_instance_valid(_fog_rect):
			_fog_rect.visible = false
		EventBus.emit("game.fog_deactivated", {})
	)

	print("FogSystem: dramatic clear (%.1fs)" % FOG_DRAMATIC_CLEAR_DURATION)


## Smooth fade-out (SEARCHING → DRAWING). Explored areas persist.
func _smooth_fade_out(duration: float) -> void:
	if not _is_active:
		return

	var tween := create_tween()
	tween.tween_property(_fog_rect, "modulate:a", 0.0, duration)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN)

	tween.tween_callback(func():
		_is_active = false
		if is_instance_valid(_fog_rect):
			_fog_rect.visible = false
		EventBus.emit("game.fog_deactivated", {})
	)

	print("FogSystem: smooth fade out (%.1fs)" % duration)


## Clear all fog state — explored areas, vision circles, pulses, line reveals.
func clear_all_fog() -> void:
	_vision_circles.clear()
	_explored_areas.clear()
	_pulses.clear()
	_revealed_line_ids.clear()
	_redraw_needed = false
	_redraw_timer = 0.0

	if is_instance_valid(_reveal_drawer):
		_reveal_drawer.clear_entries(false)
		_reveal_drawer.queue_redraw()

	if is_instance_valid(_reveal_viewport):
		_reveal_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	print("FogSystem: all fog state cleared")


## Set the global fog opacity (0.0 = fully clear, 1.0 = fully opaque).
func set_opacity(opacity: float) -> void:
	var clamped := clampf(opacity, 0.0, 1.0)
	if _fog_material:
		_fog_material.set_shader_parameter("fog_opacity", clamped)


## Add or update a vision circle for a player.
## Called from touch input during SEARCHING, or from network for remote players.
func add_vision_circle(player_id: int, world_pos: Vector2, radius: float = VISION_RADIUS) -> void:
	if not _vision_circles.has(player_id):
		_vision_circles[player_id] = {
			"target_pos": world_pos,
			"current_pos": world_pos,  # Start at target (no lerp on first appearance)
			"last_draw_pos": world_pos,
			"radius": radius,
		}
	else:
		_vision_circles[player_id]["target_pos"] = world_pos

	_redraw_needed = true


## Trigger a ghost pulse — a flash of visibility at the crossing point.
func trigger_ghost_pulse(world_pos: Vector2, radius: float = GHOST_PULSE_RADIUS, duration: float = GHOST_PULSE_DURATION) -> void:
	# Limit number of simultaneous pulses
	while _pulses.size() >= MAX_PULSES:
		_pulses.pop_front()

	_pulses.append({
		"center": world_pos,
		"radius": radius,
		"strength": 1.0,
		"initial_strength": 1.0,
		"start_time": Time.get_ticks_msec() / 1000.0,
		"duration": duration,
	})


## Query whether fog is currently active.
func is_active() -> bool:
	return _is_active


## Query whether fog is currently paused.
func is_paused() -> bool:
	return _is_paused


## Get the visibility opacity for a chalk line.
## Returns 1.0 (fully visible), LINE_DISCOVERY_OPACITY (dim), or LINE_FOG_OPACITY (barely visible).
func get_line_visibility(line_id: int) -> float:
	if not _revealed_line_ids.has(line_id):
		return LINE_FOG_OPACITY

	var reveal_time: float = _revealed_line_ids[line_id]
	var now := Time.get_ticks_msec() / 1000.0
	var age := now - reveal_time

	# Newly drawn lines are fully visible for a brief window
	if age < NEW_LINE_HIGHLIGHT_DURATION and _is_active:
		return 1.0

	# Check if the line is currently inside any active vision circle.
	# Requires querying DrawSystem for line positions, then checking against
	# _vision_circles. For the MVP, we return the discovered opacity.
	# (Full implementation: iterate DrawSystem.get_active_lines(), check segment-circle overlap)
	return LINE_DISCOVERY_OPACITY


## Set world bounds (called by Map when ready).
func set_world_bounds(min_bounds: Vector2, size: Vector2) -> void:
	_world_bounds_min = min_bounds
	_world_bounds_size = size
	if _fog_material:
		_fog_material.set_shader_parameter("world_bounds_min", _world_bounds_min)
		_fog_material.set_shader_parameter("world_bounds_size", _world_bounds_size)
