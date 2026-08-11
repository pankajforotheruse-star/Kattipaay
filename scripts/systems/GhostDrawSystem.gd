# GhostDrawSystem.gd — Ghost tactical ability for CHALK GAON: Ghost Lines
#
# Pluggable system: node under GameWorld/Systems. Communicates through EventBus
# and queries sibling systems (FogSystem) via get_node() for discovery checks.
#
# Design: Ghosts secretly place invisible chalk lines that penalize the drawer
# if discovered within 5 seconds. Lines are invisible to the searcher, faint
# (15% opacity) to the ghost who placed them, and exist in collision but not
# in Line2D rendering on non-ghost clients.
#
# Responsibilities:
#   - Once-per-round ghost draw activation (reset on new DRAWING state)
#   - Generate exactly 2 ghost lines near an anchor point (strategic placement)
#   - Store ghost ChalkLine resources separately from DrawSystem's visible lines
#   - Discovery check: segment-circle intersection against vision circles
#   - 5-second penalty window: discovered within window → -5 points to ghost
#   - Network synchronization: RPC flow for placement, discovery, reveal
#   - Client-side visibility: ghost's own client shows lines at 15% opacity
#
# Constraints:
#   - Ghost lines do NOT appear in DrawSystem's Line2D nodes (searcher: invisible)
#   - Ghost lines DO participate in collision (ghost-line overlap, cluster formation)
#   - No visual effect on placement (no flash, particle, sound, HUD notification)
#   - No EventBus event emitted to UI systems on placement (network + internal only)
#   - Network messages use same RDP + delta + quantization compression as regular lines

class_name GhostDrawSystem
extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

## Penalty window: discovery within this many milliseconds of placement applies penalty.
const PENALTY_WINDOW_MS := 5000

## Penalty points deducted from the ghost player on discovery within the window.
const PENALTY_AMOUNT := 5

## Number of ghost lines placed per activation (always 2).
const LINES_PER_ACTIVATION := 2

## Minimum ghost line length (world pixels).
const MIN_LINE_LENGTH := 100.0

## Maximum ghost line length (world pixels).
const MAX_LINE_LENGTH := 200.0

## Jitter radius around the anchor point for random placement (world pixels).
const ANCHOR_JITTER := 100.0

## Minimum distance between the two placed lines (world pixels).
const MIN_LINE_SEPARATION := 50.0

## Maximum distance between the two placed lines (world pixels).
const MAX_LINE_SEPARATION := 150.0

## Opacity for ghost lines on the ghost's own client (pre-discovery).
const GHOST_OWN_CLIENT_ALPHA := 0.15

## Pre-warmed Line2D nodes in the ghost visual pool (Prompt 16).
const GHOST_LINE_POOL_PREWARM := 8

## Fade-in duration when ghost lines become visible on discovery (seconds).
const REVEAL_FADE_DURATION := 0.5

## Red flash duration when penalty is applied (seconds), before normal reveal.
const PENALTY_FLASH_DURATION := 0.3

## Maximum ghost lines stored (2 per activation, so tracking is capped).
const MAX_GHOST_LINES := 4

## Base of the ghost-line ID namespace. Ghost line IDs are handed out by a
## monotonic counter starting here so they are (a) never negative — the -1
## value is the "unconfirmed ID" sentinel used in ChalkLine/network code — and
## (b) can never collide with DrawSystem's small sequential IDs (0,1,2,…),
## which share the same match.
const GHOST_LINE_ID_BASE := 100_000_000

## Upper bound (inclusive) of the ghost-line ID namespace.
const GHOST_LINE_ID_MAX := 999_999_999

# ── Instance State ─────────────────────────────────────────────────────────────

## Whether ghost draw is available this round. Reset on new DRAWING state.
var _ghost_draw_available: bool = true

## Active ghost lines for the current round (typically 2).
var _active_ghost_lines: Array[ChalkLine] = []

## Timestamp (Time.get_ticks_msec()) when ghost lines were last placed.
var _placed_at_time: float = 0.0

## Cached vision circle positions for discovery checking.
## { player_id: { "position": Vector2, "radius": float } }
var _vision_cache: Dictionary = {}

## Reference to FogSystem sibling for vision circle queries.
var _fog_system: Node = null

## Reference to GameWorld (found in _ready).
var _game_world: Node2D = null

## Container Node2D for ghost Line2D visuals (only on ghost's own client).
var _ghost_chalk_container: Node2D = null

## Map from ChalkLine id → Line2D node for ghost lines.
var _ghost_line_nodes: Dictionary = {}  # int → Line2D

## Pooled ghost Line2D visuals — reuse nodes instead of new/free per line.
var _ghost_line_pool: Pool = null

## Map from ChalkLine id → Tween for reveal fade-in animations.
var _ghost_reveal_tweens: Dictionary = {}

## Shader material for ghost line rendering (shared).
var _ghost_material: ShaderMaterial = null

## Whether the local player is the ghost who placed the current lines.
var _is_local_ghost: bool = false

## Local ghost owner entity ID (set externally when activated by this client).
var _local_ghost_owner_id: int = -1

## Monotonic counter for the ghost-line ID namespace. Never reset — IDs stay
## unique for the whole session (see GHOST_LINE_ID_BASE).
var _next_ghost_line_id: int = GHOST_LINE_ID_BASE


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Subscribe to match state changes — reset on new DRAWING
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)

	# Subscribe to fog/vision updates for discovery checks
	EventBus.on(EventBus.EV_GAME_FOG_REVEALED, _on_fog_revealed)

	# Subscribe to network events for ghost lines
	EventBus.on(EventBus.EV_NETWORK_GHOST_LINES_PLACED, _on_network_ghost_lines_placed)
	EventBus.on(EventBus.EV_NETWORK_GHOST_LINES_REVEALED, _on_network_ghost_lines_revealed)

	# Find sibling systems
	var systems_node := get_parent()
	if systems_node:
		_fog_system = systems_node.get_node_or_null("FogSystem")

	_game_world = get_tree().current_scene as Node2D

	# Create ghost chalk container (separate from DrawSystem's chalk container)
	_ghost_chalk_container = Node2D.new()
	_ghost_chalk_container.name = "GhostChalkLines"
	_ghost_chalk_container.z_index = 10  # Same level as regular chalk lines
	if _game_world:
		_game_world.add_child(_ghost_chalk_container)

	# Line2D pool for ghost visuals (Android optimization, Prompt 16).
	_ghost_line_pool = Pool.new(func() -> Line2D: return Line2D.new(), GHOST_LINE_POOL_PREWARM)

	# Load shader for ghost lines
	var shader := load("res://assets/shaders/chalk_line.gdshader") as Shader
	if shader:
		_ghost_material = ShaderMaterial.new()
		_ghost_material.shader = shader
		_ghost_material.set_shader_parameter("chalk_color", ChalkLine.CHALK_COLORS[ChalkLine.ChalkType.GHOST])
		_ghost_material.set_shader_parameter("alpha_mult", GHOST_OWN_CLIENT_ALPHA)

	print("GhostDrawSystem: ready")


func _process(_delta: float) -> void:
	# Discovery check: only if we have active ghost lines and fog/vision data
	if _active_ghost_lines.is_empty():
		return

	var match_state := GameState.get_match_state()
	if match_state != GameState.MatchState.DRAWING and match_state != GameState.MatchState.SEARCHING:
		return

	_check_discovery()


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_FOG_REVEALED, _on_fog_revealed)
	EventBus.off(EventBus.EV_NETWORK_GHOST_LINES_PLACED, _on_network_ghost_lines_placed)
	EventBus.off(EventBus.EV_NETWORK_GHOST_LINES_REVEALED, _on_network_ghost_lines_revealed)


# ── Public API ─────────────────────────────────────────────────────────────────

## Activate ghost draw: place 2 invisible ghost lines near the anchor position.
## Returns false if already used this round or if placement fails.
func activate_ghost_draw(anchor_position: Vector2, owner_id: int) -> bool:
	if not _ghost_draw_available:
		return false

	if _active_ghost_lines.size() >= MAX_GHOST_LINES:
		return false

	_ghost_draw_available = false
	_local_ghost_owner_id = owner_id
	_is_local_ghost = true
	_placed_at_time = Time.get_ticks_msec()

	# Generate 2 ghost lines
	var lines := _generate_ghost_lines(anchor_position, owner_id)

	# Store them
	for line in lines:
		_active_ghost_lines.append(line)

	# Create faint Line2D nodes on ghost's own client only
	if _is_local_ghost:
		for line in lines:
			_create_ghost_line_node(line)

	# Emit internal event (NOT to UI systems)
	EventBus.emit(EventBus.EV_GAME_GHOST_DRAW_ACTIVATED, {
		"owner_id": owner_id,
		"line_count": lines.size(),
		"line_ids": _get_line_ids(lines),
	})

	# Network: send to server/host
	if NetworkManager.is_connected:
		var compressed_lines: Array[Dictionary] = []
		for line in lines:
			var d := line.to_network_dict()
			d["id"] = line.id
			compressed_lines.append(d)
		NetworkManager.send_rpc("ghost.lines_placed", {
			"lines": compressed_lines,
			"owner_id": owner_id,
			"anchor": {"x": anchor_position.x, "y": anchor_position.y},
		})

	print("GhostDrawSystem: activated — %d ghost lines placed at %s by player %d" % [lines.size(), anchor_position, owner_id])
	return true


## Return all active ghost ChalkLine resources.
func get_active_ghost_lines() -> Array[ChalkLine]:
	return _active_ghost_lines.duplicate()


## Whether ghost draw is available this round.
func is_ghost_draw_available() -> bool:
	return _ghost_draw_available


## Reset availability for a new round (called on new DRAWING state).
func reset_for_new_round() -> void:
	_clear_all_ghost_lines()
	_ghost_draw_available = true
	_placed_at_time = 0.0
	_is_local_ghost = false
	_local_ghost_owner_id = -1
	_vision_cache.clear()
	print("GhostDrawSystem: reset for new round")


# ── Event Handlers ─────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var to_state: int = payload.get("to", -1)

	# Reset availability when entering a new DRAWING state (new wave)
	if to_state == GameState.MatchState.DRAWING:
		reset_for_new_round()


## Cache vision circle positions from FogSystem for discovery checking.
func _on_fog_revealed(payload: Dictionary) -> void:
	var player_id: int = payload.get("player_id", -1)
	var position: Vector2 = payload.get("position", Vector2.ZERO)
	var radius: float = payload.get("radius", FogSystem.VISION_RADIUS if _fog_system else 200.0)

	_vision_cache[player_id] = {
		"position": position,
		"radius": radius,
	}


## Received ghost lines placed by another client.
## payload: { lines: Array[Dictionary], owner_id: int }
func _on_network_ghost_lines_placed(payload: Dictionary) -> void:
	var lines_data: Array = payload.get("lines", [])
	var owner_id: int = payload.get("owner_id", -1)

	# Don't double-add if we're the ghost who placed them
	if _is_local_ghost and owner_id == _local_ghost_owner_id:
		return

	for line_data in lines_data:
		var line := ChalkLine.new()
		line.from_network_dict(line_data)
		line.is_ghost = true
		line.is_discovered = false
		line.ghost_owner_id = owner_id
		line.chalk_type = ChalkLine.ChalkType.GHOST
		line.decay_duration = ChalkLine.GHOST_DECAY_SENTINEL

		# Ensure line has an ID
		if line.id < 0:
			line.id = _generate_line_id()

		_active_ghost_lines.append(line)

		# Searcher client: do NOT create Line2D nodes (completely invisible)
		# Non-searcher, non-ghost clients: also do NOT create Line2D nodes
		# Only the ghost's own client renders them faintly
		if _is_local_ghost and owner_id == _local_ghost_owner_id:
			_create_ghost_line_node(line)

	print("GhostDrawSystem: received %d ghost lines from player %d" % [lines_data.size(), owner_id])


## Received ghost lines revealed (post-discovery) from server.
## payload: { line_ids: Array[int], penalty_applied: bool }
func _on_network_ghost_lines_revealed(payload: Dictionary) -> void:
	var line_ids: Array = payload.get("line_ids", [])
	var penalty_applied: bool = payload.get("penalty_applied", false)

	for line_id in line_ids:
		var line := _find_ghost_line_by_id(line_id)
		if line:
			line.is_discovered = true
			# Create or update Line2D node for full visibility
			if _ghost_line_nodes.has(line_id):
				_update_ghost_line_visibility(line, false)  # full reveal
			else:
				_create_ghost_line_node(line)  # first time seeing this line

	# If penalty was applied, flash red briefly then fade to full visibility
	if penalty_applied:
		for line_id in line_ids:
			_flash_penalty_then_reveal(line_id)

	print("GhostDrawSystem: revealed %d ghost lines (penalty: %s)" % [line_ids.size(), penalty_applied])


# ── Discovery Check ────────────────────────────────────────────────────────────

## Check all active ghost lines against cached vision circles.
## Called every frame during DRAWING and SEARCHING states.
func _check_discovery() -> void:
	if _active_ghost_lines.is_empty():
		return
	if _vision_cache.is_empty():
		return

	var now := Time.get_ticks_msec()
	var discovered_ids: Array[int] = []
	var within_penalty_window := (now - _placed_at_time) <= PENALTY_WINDOW_MS

	# Check each ghost line against each vision circle
	for line in _active_ghost_lines:
		if line.is_discovered:
			continue
		if line.points.size() < 2:
			continue

		for player_id in _vision_cache:
			var vis: Dictionary = _vision_cache[player_id]
			var center: Vector2 = vis["position"]
			var radius: float = vis.get("radius", 200.0)

			# Segment-circle intersection check
			for i in range(line.points.size() - 1):
				var a := line.points[i]
				var b := line.points[i + 1]
				if _segment_intersects_circle(a, b, center, radius):
					discovered_ids.append(line.id)
					line.is_discovered = true
					break  # One hit per line is enough
			if line.is_discovered:
				break

	if discovered_ids.is_empty():
		return

	# Discovery occurred — determine if penalty applies
	var penalty_applied := false
	if within_penalty_window:
		penalty_applied = true
		# Emit penalty event
		EventBus.emit(EventBus.EV_GAME_GHOST_DRAW_PENALTY, {
			"amount": PENALTY_AMOUNT,
			"ghost_player_id": _get_ghost_owner_id(),
			"discoverer_id": _get_discoverer_id(discovered_ids),
		})

	# Emit discovery event
	EventBus.emit(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, {
		"line_ids": discovered_ids,
		"penalty_applied": penalty_applied,
	})

	# Network: report discovery to server
	if NetworkManager.is_connected:
		NetworkManager.send_rpc("ghost.line_discovered", {
			"line_ids": discovered_ids,
		})

	# Visual reveal
	if penalty_applied:
		for line_id in discovered_ids:
			_flash_penalty_then_reveal(line_id)
	else:
		for line_id in discovered_ids:
			_reveal_line_fade_in(line_id)

	print("GhostDrawSystem: discovered lines %s (penalty: %s, within_window: %s)" % [discovered_ids, penalty_applied, within_penalty_window])


# ── Line Generation ────────────────────────────────────────────────────────────

## Generate exactly 2 ghost ChalkLine resources near the anchor position.
## Lines are 100-200px long, slightly curved (2-3 control points), and
## positioned 50-150px apart from each other.
func _generate_ghost_lines(anchor: Vector2, owner_id: int) -> Array[ChalkLine]:
	var lines: Array[ChalkLine] = []
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# Pick the actual anchor with jitter
	var anchor_jittered := anchor + Vector2(
		rng.randf_range(-ANCHOR_JITTER, ANCHOR_JITTER),
		rng.randf_range(-ANCHOR_JITTER, ANCHOR_JITTER)
	)

	# Direction for line 1 (random angle)
	var angle1 := rng.randf_range(0.0, TAU)

	# Direction for line 2 — offset from line 1 by 60–120 degrees and
	# shifted by MIN_LINE_SEPARATION to MAX_LINE_SEPARATION pixels
	var angle_offset := rng.randf_range(PI / 3.0, 2.0 * PI / 3.0)
	var angle2 := angle1 + angle_offset * (1.0 if rng.randf() > 0.5 else -1.0)
	var sep_dist := rng.randf_range(MIN_LINE_SEPARATION, MAX_LINE_SEPARATION)

	var length1 := rng.randf_range(MIN_LINE_LENGTH, MAX_LINE_LENGTH)
	var length2 := rng.randf_range(MIN_LINE_LENGTH, MAX_LINE_LENGTH)

	# Positions: line 1 at anchor, line 2 offset perpendicularly
	var start1 := anchor_jittered
	var start2 := anchor_jittered + Vector2.RIGHT.rotated(angle1) * sep_dist

	lines.append(_build_ghost_line(start1, angle1, length1, owner_id, rng))
	lines.append(_build_ghost_line(start2, angle2, length2, owner_id, rng))

	return lines


## Build a single ghost ChalkLine with slight curvature.
func _build_ghost_line(start: Vector2, angle: float, length: float, owner_id: int, rng: RandomNumberGenerator) -> ChalkLine:
	var points: Array[Vector2] = []
	var widths: Array[float] = []

	var end := start + Vector2.RIGHT.rotated(angle) * length

	# Determine control point count (2-3)
	var cp_count := rng.randi_range(2, 3)

	if cp_count == 2:
		# Straight line — just start and end
		points = [start, end]
		widths = [ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST], ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST]]
	else:
		# 3 control points: start → perturbed midpoint → end
		var mid := (start + end) * 0.5
		# Perpendicular perturbation for curvature
		var perp := Vector2.RIGHT.rotated(angle + PI / 2.0)
		var curve_amount := rng.randf_range(-length * 0.2, length * 0.2)
		mid += perp * curve_amount
		points = [start, mid, end]
		widths = [
			ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST],
			ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST],
			ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST],
		]

	var line := ChalkLine.new()
	line.id = _generate_line_id()
	line.points = points
	line.widths = widths
	line.chalk_type = ChalkLine.ChalkType.GHOST
	line.player_id = owner_id
	line.created_at = Time.get_ticks_msec()
	line.decay_duration = ChalkLine.GHOST_DECAY_SENTINEL
	line.is_ghost = true
	line.is_discovered = false
	line.ghost_owner_id = owner_id
	line.ghost_placed_at = Time.get_ticks_msec()

	return line


# ── Line2D Visual Management ──────────────────────────────────────────────────

## Create a faint Line2D node for a ghost line (ghost's own client only).
func _create_ghost_line_node(line: ChalkLine) -> void:
	if _ghost_line_nodes.has(line.id):
		return

	var ln := _acquire_ghost_line_node()
	ln.name = "GhostChalkLine_%d" % line.id
	ln.z_index = 10

	# Pre-discovery: faint opacity. Post-discovery: full visibility.
	if line.is_discovered:
		ln.width = line.get_base_width()
		ln.default_color = line.get_chalk_color()
	else:
		ln.width = line.get_base_width()
		ln.default_color = line.get_chalk_color()  # Already has 0.15 alpha from CHALK_COLORS

	ln.texture_mode = Line2D.LINE_TEXTURE_NONE
	ln.joint_mode = Line2D.LINE_JOINT_ROUND
	ln.end_cap_mode = Line2D.LINE_CAP_ROUND
	ln.begin_cap_mode = Line2D.LINE_CAP_ROUND

	# Ghost lines on searcher client: completely invisible
	if not _is_local_ghost:
		ln.visible = false

	ln.points = PackedVector2Array(line.points)  # one packed copy, no per-point calls

	# Apply shader material with appropriate alpha
	if _ghost_material:
		var mat := _ghost_material.duplicate() as ShaderMaterial
		var alpha := GHOST_OWN_CLIENT_ALPHA if not line.is_discovered else 1.0
		mat.set_shader_parameter("chalk_color", line.get_chalk_color())
		mat.set_shader_parameter("alpha_mult", alpha)
		ln.material = mat
		# Override default_color since shader handles color
		ln.default_color = Color.WHITE

	_ghost_line_nodes[line.id] = ln


## Acquire a Line2D node from the ghost pool, parented under the container.
func _acquire_ghost_line_node() -> Line2D:
	var ln := _ghost_line_pool.acquire() as Line2D
	if _ghost_chalk_container and ln.get_parent() != _ghost_chalk_container:
		_ghost_chalk_container.add_child(ln)
	return ln


## Reset a Line2D node and return it to the ghost pool for reuse.
func _release_ghost_line_node(node: Line2D) -> void:
	Pool.reset_line2d(node)
	_ghost_line_pool.release(node)


## Update existing ghost Line2D node visibility (called on discovery/reveal).
func _update_ghost_line_visibility(line: ChalkLine, use_penalty_flash: bool) -> void:
	var node: Line2D = _ghost_line_nodes.get(line.id, null)
	if not node or not is_instance_valid(node):
		return

	node.visible = true

	if use_penalty_flash:
		# Temporarily color red for the penalty flash
		node.default_color = Color(1.0, 0.2, 0.2, 1.0)
	else:
		node.default_color = line.get_chalk_color()
		node.width = line.get_base_width()

	if node.material and node.material is ShaderMaterial:
		var mat := node.material as ShaderMaterial
		if use_penalty_flash:
			mat.set_shader_parameter("chalk_color", Color(1.0, 0.2, 0.2, 1.0))
			mat.set_shader_parameter("alpha_mult", 1.0)
		else:
			mat.set_shader_parameter("chalk_color", line.get_chalk_color())
			mat.set_shader_parameter("alpha_mult", 1.0)


## Flash penalty red for 0.3s, then fade in to full visibility over 0.5s.
func _flash_penalty_then_reveal(line_id: int) -> void:
	var line := _find_ghost_line_by_id(line_id)
	if not line:
		return

	line.is_discovered = true

	var node: Line2D = _ghost_line_nodes.get(line_id, null)
	if not node or not is_instance_valid(node):
		_create_ghost_line_node(line)
		node = _ghost_line_nodes.get(line_id, null)
		if not node:
			return

	node.visible = true

	# Red flash
	if node.material and node.material is ShaderMaterial:
		var mat := node.material as ShaderMaterial
		mat.set_shader_parameter("chalk_color", Color(1.0, 0.2, 0.2, 1.0))
		mat.set_shader_parameter("alpha_mult", 1.0)
	node.default_color = Color(1.0, 0.2, 0.2, 1.0)

	# After flash, fade to ghost revealed color
	var tween := create_tween()
	tween.set_parallel(false)
	tween.tween_interval(PENALTY_FLASH_DURATION)
	if node.material and node.material is ShaderMaterial:
		var mat := node.material as ShaderMaterial
		tween.tween_method(
			func(c: Color): mat.set_shader_parameter("chalk_color", c),
			Color(1.0, 0.2, 0.2, 1.0),
			ChalkLine.GHOST_REVEALED_COLOR,
			REVEAL_FADE_DURATION
		)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		node.default_color = ChalkLine.GHOST_REVEALED_COLOR
	)

	_ghost_reveal_tweens[line_id] = tween


## Smooth fade-in to full ghost revealed color (no penalty flash).
func _reveal_line_fade_in(line_id: int) -> void:
	var line := _find_ghost_line_by_id(line_id)
	if not line:
		return

	line.is_discovered = true

	var node: Line2D = _ghost_line_nodes.get(line_id, null)
	if not node or not is_instance_valid(node):
		_create_ghost_line_node(line)
		node = _ghost_line_nodes.get(line_id, null)
		if not node:
			return

	node.visible = true

	var tween := create_tween()
	if node.material and node.material is ShaderMaterial:
		var mat := node.material as ShaderMaterial
		tween.tween_method(
			func(c: Color): mat.set_shader_parameter("chalk_color", c),
			ChalkLine.CHALK_COLORS[ChalkLine.ChalkType.GHOST],
			ChalkLine.GHOST_REVEALED_COLOR,
			REVEAL_FADE_DURATION
		)
		tween.set_trans(Tween.TRANS_SINE)
		tween.set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		node.default_color = ChalkLine.GHOST_REVEALED_COLOR
	)

	_ghost_reveal_tweens[line_id] = tween


# ── Collision ──────────────────────────────────────────────────────────────────

## Check if a ghost (or any entity) overlaps any active ghost chalk line.
## Returns array of ghost line IDs that intersect the given circle.
func check_ghost_line_collision(center: Vector2, radius: float) -> Array[int]:
	var hit_ids: Array[int] = []
	for line in _active_ghost_lines:
		if line.points.size() < 2:
			continue
		for i in range(line.points.size() - 1):
			if _segment_intersects_circle(line.points[i], line.points[i + 1], center, radius):
				hit_ids.append(line.id)
				break
	return hit_ids


## Check if a line segment intersects a circle.
## Uses closest-point-on-segment distance.
static func _segment_intersects_circle(a: Vector2, b: Vector2, center: Vector2, radius: float) -> bool:
	var ab := b - a
	var ac := center - a
	var ab_len_sq := ab.length_squared()

	if ab_len_sq < 0.0001:
		return ac.length_squared() <= radius * radius

	var t := clampf(ac.dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest := a + ab * t
	return closest.distance_squared_to(center) <= radius * radius


# ── Helpers ────────────────────────────────────────────────────────────────────

func _find_ghost_line_by_id(line_id: int) -> ChalkLine:
	for line in _active_ghost_lines:
		if line.id == line_id:
			return line
	return null


func _get_line_ids(lines: Array[ChalkLine]) -> Array[int]:
	var ids: Array[int] = []
	for line in lines:
		ids.append(line.id)
	return ids


## Generate the next ghost line ID from the dedicated high namespace.
## Replaces the old `hash(...)` scheme, which could return negative values
## (colliding with the -1 "unconfirmed" sentinel) and could collide with
## DrawSystem's small sequential IDs.
func _generate_line_id() -> int:
	var id := _next_ghost_line_id
	_next_ghost_line_id += 1
	# Defensive wrap — the namespace (900M IDs) can never be exhausted in practice.
	if _next_ghost_line_id > GHOST_LINE_ID_MAX:
		_next_ghost_line_id = GHOST_LINE_ID_BASE
	return id


func _get_ghost_owner_id() -> int:
	for line in _active_ghost_lines:
		if line.ghost_owner_id >= 0:
			return line.ghost_owner_id
	return _local_ghost_owner_id


func _get_discoverer_id(_discovered_ids: Array[int]) -> int:
	# The discoverer is the player whose vision circle triggered the discovery.
	# For MVP, return the first player_id in the vision cache (typically the searcher).
	if _vision_cache.size() > 0:
		for pid in _vision_cache:
			return pid
	return -1


## Clear all ghost lines (Line2D nodes, tweens, and data).
func _clear_all_ghost_lines() -> void:
	# Kill all reveal tweens
	for tween in _ghost_reveal_tweens.values():
		if tween is Tween and tween.is_valid():
			tween.kill()
	_ghost_reveal_tweens.clear()

	# Remove all Line2D nodes
	for node in _ghost_line_nodes.values():
		if node is Line2D and is_instance_valid(node):
			_release_ghost_line_node(node)
	_ghost_line_nodes.clear()

	_active_ghost_lines.clear()
