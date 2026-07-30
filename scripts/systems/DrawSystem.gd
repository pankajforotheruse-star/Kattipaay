# DrawSystem.gd — Core chalk drawing mechanic for CHALK GAON
#
# Pluggable system: subscribes to EventBus drawing events and manages all chalk line state.
# ZERO coupling to other systems — communicates exclusively through EventBus.
#
# Responsibilities:
#   - Two-finger drawing: receive input.draw_* events, smooth with Catmull-Rom spline
#   - Line2D node lifecycle: create, update, destroy visual representations
#   - Variable thickness: speed-based + chalk-type-based width
#   - Collision: ghost-line overlap queries, sealed-circle detection, line-line connection
#   - Decay: per-line lifetime countdown with fade-out animation
#   - Chalk meter: track remaining chalk, emit warnings
#   - Network: compress lines, send to server, handle reconciliation
#   - Undo: last-line undo with cooldown and chalk refund
#
# Constraints:
#   - Max 50 active Line2D nodes
#   - Each line <200 points after compression
#   - Network message <500 bytes per line
#   - Total line data <100KB

class_name DrawSystem
extends Node

# --- Constants ---

## Maximum simultaneous chalk lines (GDD §4 constraint).
const MAX_ACTIVE_LINES := 50

## Minimum distance between raw touch samples before recording a point.
const MIN_SAMPLE_DISTANCE := 4.0

## Catmull-Rom interpolation spacing (pixels between smoothed points).
const SPLINE_SAMPLE_SPACING := 8.0

## RDP simplification epsilon (pixels) for network compression.
const RDP_EPSILON := 2.0

## Distance threshold for connecting to existing lines or closing a loop.
const CONNECTION_THRESHOLD := 20.0

## Minimum sealing circle diameter (GDD §4).
const MIN_CIRCLE_DIAMETER := 40.0

## Maximum sealing circle diameter (GDD §4).
const MAX_CIRCLE_DIAMETER := 200.0

## Total chalk pool capacity.
const CHALK_MAX := 100.0

## Starting chalk (GDD §3: starts at 80/100).
const CHALK_START := 80.0

## Chalk consumed per second while drawing (GDD §4: 2/sec).
const CHALK_COST_PER_SECOND := 2.0

## Warning threshold — below this, HUD shows warning (GDD §4).
const CHALK_WARNING_THRESHOLD := 0.2

## Time window for undo eligibility (seconds after drawing).
const UNDO_TIME_WINDOW := 3.0

## Cooldown between undos (seconds).
const UNDO_COOLDOWN := 5.0

## Percent of chalk cost refunded on undo.
const UNDO_REFUND_PCT := 0.5

## Fade-out duration for expiring lines (seconds).
const FADE_DURATION := 1.0

# --- Chalk type enum (mirrors ChalkLine.ChalkType for convenience) ---
enum ChalkType {
    WHITE = 0,
    RED = 1,
    YELLOW = 2,
    GHOST = 3,
}

# --- Instance State ---

## Reference to GameWorld (found in _ready).
var _game_world: Node2D = null

## Container Node2D for all Line2D chalk visuals — child of GameWorld.
var _chalk_container: Node2D = null

## Shared shader material for all chalk lines.
var _chalk_material: ShaderMaterial = null

## Array of all active ChalkLine resources.
var _active_lines: Array[ChalkLine] = []

## Map from ChalkLine id → Line2D node for quick lookup.
var _line_nodes: Dictionary = {}  # int → Line2D

## Map from ChalkLine id → Tween for fade-out animations.
var _fade_tweens: Dictionary = {}  # int → Tween

## Auto-incrementing line ID counter (never reused within a match).
var _next_line_id: int = 0

## Chalk remaining (0.0 to CHALK_MAX).
var _chalk_remaining: float = CHALK_START

## Whether chalk is exhausted (no more drawing allowed this match).
var _chalk_exhausted: bool = false

## Current match time limit exceeded flag.
var _match_time_exceeded: bool = false

# --- Active Drawing State ---

## Whether the player is currently drawing (between draw_start and draw_end).
var _is_drawing: bool = false

## Raw touch points collected during current draw stroke (world-space).
var _raw_draw_points: Array[Vector2] = []

## Raw widths (sampled at touch points) during current draw stroke.
var _raw_draw_widths: Array[float] = []

## Current chalk type being used for the active stroke.
var _current_chalk_type: int = ChalkType.WHITE

## Entity ID of the local player who is drawing.
var _drawing_entity_id: int = -1

## Timestamp of last draw_end (for undo window).
var _last_draw_end_time: float = 0.0

## ID of the last drawn line (for undo).
var _last_drawn_line_id: int = -1

## Timestamp of last undo (for cooldown).
var _last_undo_time: float = -UNDO_COOLDOWN

## Time spent drawing current stroke (for chalk consumption tracking).
var _current_stroke_duration: float = 0.0


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
    # --- Subscribe to input events ---
    EventBus.on("input.draw_start", _on_draw_start)
    EventBus.on("input.draw_update", _on_draw_update)
    EventBus.on("input.draw_end", _on_draw_end)
    EventBus.on("input.undo_draw", _on_undo_draw)

    # --- Subscribe to network events ---
    EventBus.on("network.chalk.line_drawn", _on_network_line_drawn)
    EventBus.on("network.chalk.line_rejected", _on_network_line_rejected)
    EventBus.on("network.chalk.line_sync_batch", _on_network_line_sync_batch)

    # --- Subscribe to match state ---
    EventBus.on("match.drawing_started", _on_match_drawing_started)
    EventBus.on("game.chalk_exhausted", _on_chalk_exhausted)

    # --- Find GameWorld ---
    _game_world = get_tree().current_scene as Node2D
    if not _game_world:
        push_warning("DrawSystem: GameWorld not found in current scene")

    # --- Create chalk line container ---
    _chalk_container = Node2D.new()
    _chalk_container.name = "ChalkLines"
    _chalk_container.z_index = 10  # Above ground, below entities
    if _game_world:
        _game_world.add_child(_chalk_container)

    # --- Load and configure shader ---
    var shader := load("res://assets/shaders/chalk_line.gdshader") as Shader
    if shader:
        _chalk_material = ShaderMaterial.new()
        _chalk_material.shader = shader
        # Default white chalk color
        _chalk_material.set_shader_parameter("chalk_color", ChalkLine.CHALK_COLORS[ChalkType.WHITE])
        _chalk_material.set_shader_parameter("alpha_mult", 1.0)
    else:
        push_warning("DrawSystem: chalk_line.gdshader not found — lines will render without shader")

    print("DrawSystem: ready — chalk remaining: %.1f/%.1f" % [_chalk_remaining, CHALK_MAX])


func _process(delta: float) -> void:
    # --- Tick line decay ---
    _tick_decay(delta)

    # --- Consume chalk while actively drawing ---
    if _is_drawing and not _chalk_exhausted and not _match_time_exceeded:
        _current_stroke_duration += delta
        _chalk_remaining -= CHALK_COST_PER_SECOND * delta
        if _chalk_remaining <= 0.0:
            _chalk_remaining = 0.0
            _chalk_exhausted = true
            EventBus.emit("game.chalk_exhausted", {})
            # Force-end current stroke
            if _is_drawing:
                _finish_drawing()

    # --- Emit chalk meter updates (throttled to ~4 Hz for performance) ---
    # We track last emitted value and only emit when significant change (>2%)
    _emit_chalk_meter_if_changed()


# =============================================================================
# INPUT EVENT HANDLERS
# =============================================================================

## Called when the second finger touches down while the first is held (draw gesture starts).
## payload: {entity_id: int, position: Vector2 (world-space), chalk_type: int}
func _on_draw_start(payload: Dictionary) -> void:
    if _chalk_exhausted or _match_time_exceeded:
        return
    if _active_lines.size() >= MAX_ACTIVE_LINES:
        # Remove oldest line to make room (GDD §4: oldest line fades when limit reached)
        _remove_oldest_line()
    if _chalk_remaining <= 0.0:
        return

    _is_drawing = true
    _drawing_entity_id = payload.get("entity_id", -1)
    _current_chalk_type = payload.get("chalk_type", ChalkType.WHITE)
    _current_stroke_duration = 0.0

    # Reset point buffers
    _raw_draw_points.clear()
    _raw_draw_widths.clear()

    # Record first point
    var pos: Vector2 = payload.get("position", Vector2.ZERO)
    _raw_draw_points.append(pos)
    _raw_draw_widths.append(_compute_width(pos, pos, 0.016))  # initial width = base width

    # Create a preview Line2D node for real-time visual feedback
    _create_preview_line()


## Called as the second finger moves during drawing.
## payload: {entity_id: int, position: Vector2 (world-space)}
func _on_draw_update(payload: Dictionary) -> void:
    if not _is_drawing:
        return
    if payload.get("entity_id", -1) != _drawing_entity_id:
        return

    var pos: Vector2 = payload.get("position", Vector2.ZERO)
    var last_pos := _raw_draw_points[-1] if _raw_draw_points.size() > 0 else pos

    # Only record if moved enough (avoid duplicate points)
    if pos.distance_squared_to(last_pos) >= MIN_SAMPLE_DISTANCE * MIN_SAMPLE_DISTANCE:
        # Compute width based on speed
        var delta_time := 0.016  # approximate; in production, pass from InputManager
        var w := _compute_width(pos, last_pos, delta_time)

        _raw_draw_points.append(pos)
        _raw_draw_widths.append(w)

        # Update preview line in real-time (smooth on the fly)
        _update_preview_line()


## Called when the second finger is released (draw gesture ends).
## payload: {entity_id: int}
func _on_draw_end(payload: Dictionary) -> void:
    if not _is_drawing:
        return
    if payload.get("entity_id", -1) != _drawing_entity_id:
        return

    _finish_drawing()


## Called when user triggers undo (shake gesture or HUD button).
func _on_undo_draw(_payload = null) -> void:
    var now := Time.get_ticks_msec() / 1000.0

    # Cooldown check
    if now - _last_undo_time < UNDO_COOLDOWN:
        return

    # Must have a line to undo
    if _last_drawn_line_id < 0:
        return

    # Find the line
    var line := _find_line_by_id(_last_drawn_line_id)
    if not line:
        return

    # Time window check: only undoable within UNDO_TIME_WINDOW seconds
    if now - _last_draw_end_time > UNDO_TIME_WINDOW:
        return

    # Only the drawing player can undo
    if line.player_id != _drawing_entity_id and NetworkManager.is_connected:
        return

    # --- Perform undo ---
    _remove_line(line, "undo")

    # Refund 50% of chalk cost
    var length := line.get_total_length()
    var chalk_cost := _current_stroke_duration * CHALK_COST_PER_SECOND
    _chalk_remaining = min(CHALK_MAX, _chalk_remaining + chalk_cost * UNDO_REFUND_PCT)
    _chalk_exhausted = false
    EventBus.emit("game.chalk_meter_changed", {
        "remaining_percent": _chalk_remaining / CHALK_MAX,
        "remaining_chalk": _chalk_remaining,
    })

    _last_undo_time = now
    _last_drawn_line_id = -1

    # Notify server if online
    if NetworkManager.is_connected and not NetworkManager.has_authority():
        NetworkManager.send_rpc("chalk.line_undone", {"line_id": line.id})

    print("DrawSystem: undone line %d, chalk refunded to %.1f" % [line.id, _chalk_remaining])


# =============================================================================
# LINE CREATION & FINALIZATION
# =============================================================================

## Finalize the current drawing stroke: smooth, create ChalkLine, compress, notify.
func _finish_drawing() -> void:
    _is_drawing = false

    if _raw_draw_points.size() < 2:
        # Not enough points for a valid line — remove preview
        _remove_preview_line()
        _drawing_entity_id = -1
        return

    # --- Step 1: Catmull-Rom spline interpolation ---
    var smoothed := _catmull_rom_smooth(_raw_draw_points, SPLINE_SAMPLE_SPACING)

    # Match widths to smoothed points (interpolate)
    var smoothed_widths: Array[float] = []
    if _raw_draw_widths.size() > 0:
        smoothed_widths = _interpolate_widths(_raw_draw_points, _raw_draw_widths, smoothed)

    # --- Step 2: Create ChalkLine resource ---
    var line := ChalkLine.new()
    line.points = smoothed
    line.widths = smoothed_widths
    line.chalk_type = _current_chalk_type
    line.player_id = _drawing_entity_id
    line.created_at = Time.get_ticks_msec()
    line.decay_duration = ChalkLine.DECAY_DURATIONS[_current_chalk_type]
    line.id = -1  # Will be assigned by server/host or locally

    # --- Step 3: Check line-line connections ---
    _check_line_connections(line)

    # --- Step 4: Detect sealed circles ---
    _check_sealed_circle(line)

    # --- Step 5: Network: send to server, or self-assign if offline host ---
    if NetworkManager.is_connected:
        if NetworkManager.has_authority():
            # Host/Server: assign ID directly and broadcast
            line.id = _next_line_id
            _next_line_id += 1
            _add_line(line)
            # Broadcast to other clients
            var compressed := line.to_network_dict()
            compressed["id"] = line.id
            NetworkManager.send_rpc("chalk.line_drawn", compressed)
        else:
            # Client: predict locally with temp ID, send to server
            line.id = _next_line_id
            _next_line_id += 1
            _add_line(line)
            # Send to server for validation
            var compressed := line.to_network_dict()
            compressed["id"] = line.id  # client-assigned temp ID
            NetworkManager.send_rpc("chalk.line_drawn", compressed)
    else:
        # Fully offline / no networking: assign ID and add
        line.id = _next_line_id
        _next_line_id += 1
        _add_line(line)

    # --- Track for undo ---
    _last_drawn_line_id = line.id
    _last_draw_end_time = Time.get_ticks_msec() / 1000.0

    # --- Remove preview ---
    _remove_preview_line()

    # --- Emit event ---
    var compressed_size := line.estimate_network_size()
    EventBus.emit("game.line_drawn", {
        "line_id": line.id,
        "player_id": line.player_id,
        "chalk_type": line.chalk_type,
        "point_count": line.points.size(),
        "compressed_size": compressed_size,
    })

    _drawing_entity_id = -1
    print("DrawSystem: line %d drawn — %d pts, %d bytes compressed" % [line.id, smoothed.size(), compressed_size])


## Add a fully-formed ChalkLine to the active set and create its Line2D visual.
func _add_line(line: ChalkLine) -> void:
    _active_lines.append(line)

    # Create Line2D node
    var line_node := _create_line2d_node(line)
    _line_nodes[line.id] = line_node

    # Enforce max line limit
    if _active_lines.size() > MAX_ACTIVE_LINES:
        _remove_oldest_line()


## Remove a line by reason. Cleans up Line2D node, tweens, and emits event.
func _remove_line(line: ChalkLine, reason: String) -> void:
    # Stop any fade tween
    if _fade_tweens.has(line.id):
        var t: Tween = _fade_tweens[line.id]
        if t.is_valid():
            t.kill()
        _fade_tweens.erase(line.id)

    # Remove Line2D node
    if _line_nodes.has(line.id):
        var node: Line2D = _line_nodes[line.id]
        if is_instance_valid(node):
            node.queue_free()
        _line_nodes.erase(line.id)

    # Remove from active array
    var idx := _active_lines.find(line)
    if idx != -1:
        _active_lines.remove_at(idx)

    EventBus.emit("game.line_removed", {
        "line_id": line.id,
        "reason": reason,
    })


## Remove the oldest line (by created_at). Used when hitting the 50-line cap.
func _remove_oldest_line() -> void:
    if _active_lines.is_empty():
        return
    var oldest := _active_lines[0]
    for line in _active_lines:
        if line.created_at < oldest.created_at:
            oldest = line
    _remove_line(oldest, "limit_reached")


# =============================================================================
# LINE2D VISUAL MANAGEMENT
# =============================================================================

var _preview_line_node: Line2D = null  # Line2D for in-progress drawing preview


## Create a Line2D preview during active drawing (updated per touch move).
func _create_preview_line() -> void:
    if _preview_line_node and is_instance_valid(_preview_line_node):
        _preview_line_node.queue_free()
    _preview_line_node = Line2D.new()
    _preview_line_node.name = "ChalkPreview"
    _preview_line_node.z_index = 11
    _preview_line_node.width = ChalkLine.BASE_WIDTHS.get(_current_chalk_type, 4.0)
    _preview_line_node.default_color = ChalkLine.CHALK_COLORS.get(_current_chalk_type, Color.WHITE)
    _preview_line_node.texture_mode = Line2D.LINE_TEXTURE_NONE
    _preview_line_node.joint_mode = Line2D.LINE_JOINT_ROUND
    _preview_line_node.end_cap_mode = Line2D.LINE_CAP_ROUND
    _preview_line_node.begin_cap_mode = Line2D.LINE_CAP_ROUND
    if _chalk_material:
        var mat := _chalk_material.duplicate() as ShaderMaterial
        mat.set_shader_parameter("chalk_color", ChalkLine.CHALK_COLORS.get(_current_chalk_type, Color.WHITE))
        mat.set_shader_parameter("alpha_mult", 0.7)  # Slightly transparent during preview
        _preview_line_node.material = mat
    if _chalk_container:
        _chalk_container.add_child(_preview_line_node)


## Update the preview line with current raw points (real-time feedback).
func _update_preview_line() -> void:
    if not _preview_line_node or not is_instance_valid(_preview_line_node):
        return
    # Smooth on the fly for preview quality
    var smoothed := _catmull_rom_smooth(_raw_draw_points, SPLINE_SAMPLE_SPACING)
    _preview_line_node.clear_points()
    for pt in smoothed:
        _preview_line_node.add_point(pt)
    # Set per-point widths if we have them
    if _raw_draw_widths.size() > 0:
        var interp_w := _interpolate_widths(_raw_draw_points, _raw_draw_widths, smoothed)
        _preview_line_node.width = 0  # Will be overridden by width_curve conceptually
        # For simplicity, use average width
        var avg_w := 0.0
        for w in interp_w:
            avg_w += w
        if interp_w.size() > 0:
            avg_w /= float(interp_w.size())
            _preview_line_node.width = avg_w


## Remove the preview line node.
func _remove_preview_line() -> void:
    if _preview_line_node and is_instance_valid(_preview_line_node):
        _preview_line_node.queue_free()
    _preview_line_node = null


## Create a permanent Line2D node from a ChalkLine resource.
func _create_line2d_node(line: ChalkLine) -> Line2D:
    var ln := Line2D.new()
    ln.name = "ChalkLine_%d" % line.id
    ln.z_index = 11  # Above ground, just below entities
    ln.width = line.get_base_width()
    ln.default_color = line.get_chalk_color()
    ln.texture_mode = Line2D.LINE_TEXTURE_NONE
    ln.joint_mode = Line2D.LINE_JOINT_ROUND
    ln.end_cap_mode = Line2D.LINE_CAP_ROUND
    ln.begin_cap_mode = Line2D.LINE_CAP_ROUND

    # Set points
    for pt in line.points:
        ln.add_point(pt)

    # Apply shader material
    if _chalk_material:
        var mat := _chalk_material.duplicate() as ShaderMaterial
        mat.set_shader_parameter("chalk_color", line.get_chalk_color())
        mat.set_shader_parameter("alpha_mult", 1.0)
        ln.material = mat

    if _chalk_container:
        _chalk_container.add_child(ln)

    return ln


# =============================================================================
# DECAY SYSTEM
# =============================================================================

## Tick per-line decay each frame. Fade out and remove expired lines.
func _tick_decay(delta: float) -> void:
    var expired: Array[ChalkLine] = []

    for line in _active_lines:
        if line.is_expired():
            # Start fade-out if not already fading
            if not _fade_tweens.has(line.id):
                _start_fade_out(line)
            # Check if fade animation has completed
            elif not _is_tween_active(line.id):
                expired.append(line)

    if expired.size() > 0:
        for line in expired:
            _remove_line(line, "expired")
            EventBus.emit("game.line_expired", {"line_id": line.id})


## Start fade-out animation for a line about to expire.
func _start_fade_out(line: ChalkLine) -> void:
    var node: Line2D = _line_nodes.get(line.id, null)
    if not node or not is_instance_valid(node):
        return
    if not node.material or not (node.material is ShaderMaterial):
        return

    var mat := node.material as ShaderMaterial
    var tween := create_tween()
    tween.set_parallel(false)
    tween.tween_method(
        func(alpha: float): mat.set_shader_parameter("alpha_mult", alpha),
        1.0,   # from full opacity
        0.0,   # to transparent
        FADE_DURATION
    )
    tween.set_trans(Tween.TRANS_SINE)
    tween.set_ease(Tween.EASE_IN)
    _fade_tweens[line.id] = tween


## Check if a fade tween is still active.
func _is_tween_active(line_id: int) -> bool:
    if not _fade_tweens.has(line_id):
        return false
    var t: Tween = _fade_tweens[line_id]
    return t.is_valid() and t.is_running()


# =============================================================================
# SPLINE & SMOOTHING
# =============================================================================

## Catmull-Rom spline interpolation.
## Given control points, produces a smooth curve sampled at `spacing` pixel intervals.
static func _catmull_rom_smooth(control_points: Array[Vector2], spacing: float) -> Array[Vector2]:
    if control_points.size() < 2:
        return control_points.duplicate()

    if control_points.size() == 2:
        # Just two points: subdivide linearly
        return _subdivide_line(control_points[0], control_points[1], spacing)

    var result: Array[Vector2] = [control_points[0]]

    # For each segment, interpolate between p1 and p2 using p0 and p3 as tangents
    for i in range(control_points.size() - 1):
        var p0 := control_points[maxi(i - 1, 0)]
        var p1 := control_points[i]
        var p2 := control_points[i + 1]
        var p3 := control_points[mini(i + 2, control_points.size() - 1)]

        var seg_length := p1.distance_to(p2)
        var steps := maxi(1, int(ceil(seg_length / spacing)))

        for s in range(1, steps + 1):
            var t := float(s) / float(steps)
            var pt := _catmull_rom_point(p0, p1, p2, p3, t)
            result.append(pt)

    return result


## Compute a single Catmull-Rom point at parameter t.
static func _catmull_rom_point(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
    var t2 := t * t
    var t3 := t2 * t
    # Catmull-Rom basis matrix:
    #  0.5 * [ -1  3 -3  1 ]
    #        [  2 -5  4 -1 ]
    #        [ -1  0  1  0 ]
    #        [  0  2  0  0 ]
    return 0.5 * (
        (2.0 * p1) +
        (-p0 + p2) * t +
        (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
        (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
    )


## Linear subdivision of a segment.
static func _subdivide_line(a: Vector2, b: Vector2, spacing: float) -> Array[Vector2]:
    var result: Array[Vector2] = [a]
    var dist := a.distance_to(b)
    var steps := maxi(1, int(ceil(dist / spacing)))
    for s in range(1, steps):
        var t := float(s) / float(steps)
        result.append(a.lerp(b, t))
    result.append(b)
    return result


# =============================================================================
# WIDTH COMPUTATION
# =============================================================================

## Compute line width at a point based on draw speed and chalk type.
## Slower drawing → thicker lines; faster → thinner.
func _compute_width(current_pos: Vector2, previous_pos: Vector2, delta_time: float) -> float:
    var base := ChalkLine.BASE_WIDTHS.get(_current_chalk_type, 4.0)
    var dist := current_pos.distance_to(previous_pos)
    var speed := dist / max(delta_time, 0.001)

    # Map speed to width: slow (0 px/s) → base + 4px, fast (800+ px/s) → base - 1px
    var speed_factor := clampf(1.0 - (speed / 800.0), 0.25, 2.0)
    var width := base * speed_factor

    # Clamp to sane range
    return clampf(width, 1.5, 10.0)


## Interpolate widths from raw points to smoothed points (nearest-neighbor match).
static func _interpolate_widths(raw_pts: Array[Vector2], raw_w: Array[float], smoothed: Array[Vector2]) -> Array[float]:
    var result: Array[float] = []
    for sp in smoothed:
        var best_idx := 0
        var best_dist := INF
        for i in range(raw_pts.size()):
            var d := sp.distance_squared_to(raw_pts[i])
            if d < best_dist:
                best_dist = d
                best_idx = i
        result.append(raw_w[best_idx] if best_idx < raw_w.size() else ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.WHITE])
    return result


# =============================================================================
# COLLISION DETECTION
# =============================================================================

## Check if a ghost overlaps any active chalk line.
## Returns array of line IDs that the ghost's circle intersects.
func check_ghost_collision(ghost_position: Vector2, ghost_radius: float) -> Array[int]:
    var hit_lines: Array[int] = []

    for line in _active_lines:
        if line.points.size() < 2:
            continue
        # Check each segment against the ghost's collision circle
        for i in range(line.points.size() - 1):
            var a := line.points[i]
            var b := line.points[i + 1]
            if _segment_intersects_circle(a, b, ghost_position, ghost_radius):
                hit_lines.append(line.id)
                EventBus.emit("game.ghost_touches_line", {
                    "ghost_id": -1,  # Filled by caller
                    "line_id": line.id,
                    "chalk_type": line.chalk_type,
                })
                break  # One hit per line is enough

    return hit_lines


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


## Detect if a newly drawn line forms a closed loop (sealing circle).
## Checks if endpoint is within CONNECTION_THRESHOLD of start point.
## If closed, also checks for ghosts inside the enclosed area.
func _check_sealed_circle(line: ChalkLine) -> void:
    if line.points.size() < 3:
        return

    var start := line.points[0]
    var end := line.points[-1]

    if start.distance_to(end) <= CONNECTION_THRESHOLD:
        # Line forms a closed loop
        var center := _compute_polygon_center(line.points)
        var radius := _compute_polygon_radius(line.points, center)

        # Validate min/max size
        if radius * 2.0 < MIN_CIRCLE_DIAMETER or radius * 2.0 > MAX_CIRCLE_DIAMETER:
            return

        # Find ghosts inside (delegated to GhostSystem in production; emit event here)
        # In prototype, we just emit with empty ghosts_inside — GhostSystem will populate
        EventBus.emit("game.circle_sealed", {
            "center": center,
            "radius": radius,
            "ghosts_inside": [],  # GhostSystem fills this in
            "player_id": line.player_id,
        })

        print("DrawSystem: sealed circle detected — center=%s, radius=%.1f" % [center, radius])


## Check if new line endpoints connect to any existing lines.
## Ghost lines do NOT connect to regular chalk lines.
func _check_line_connections(line: ChalkLine) -> void:
    if line.points.size() < 1:
        return

    # Ghost lines do not participate in line connections
    if line.is_ghost:
        return

    var start := line.points[0]
    var end := line.points[-1]

    for other in _active_lines:
        if other == line:
            continue
        if other.points.size() < 1:
            continue
        # Ghost lines do not connect to anything
        if other.is_ghost:
            continue

        # Check start → other start/end
        if start.distance_to(other.points[0]) <= CONNECTION_THRESHOLD:
            line.connected_to.append(other.id)
            other.connected_to.append(line.id)
            EventBus.emit("game.lines_connected", {"line_id_a": line.id, "line_id_b": other.id})
        elif start.distance_to(other.points[-1]) <= CONNECTION_THRESHOLD:
            line.connected_to.append(other.id)
            other.connected_to.append(line.id)
            EventBus.emit("game.lines_connected", {"line_id_a": line.id, "line_id_b": other.id})
        elif end.distance_to(other.points[0]) <= CONNECTION_THRESHOLD:
            line.connected_to.append(other.id)
            other.connected_to.append(line.id)
            EventBus.emit("game.lines_connected", {"line_id_a": line.id, "line_id_b": other.id})
        elif end.distance_to(other.points[-1]) <= CONNECTION_THRESHOLD:
            line.connected_to.append(other.id)
            other.connected_to.append(line.id)
            EventBus.emit("game.lines_connected", {"line_id_a": line.id, "line_id_b": other.id})


## Compute approximate center of a polygon from its vertices.
static func _compute_polygon_center(points: Array[Vector2]) -> Vector2:
    var sum := Vector2.ZERO
    for pt in points:
        sum += pt
    return sum / float(points.size())


## Compute approximate radius (average distance from center to vertices).
static func _compute_polygon_radius(points: Array[Vector2], center: Vector2) -> float:
    var total := 0.0
    for pt in points:
        total += center.distance_to(pt)
    return total / float(points.size())


# =============================================================================
# NETWORK HANDLERS
# =============================================================================

## Received from server/host: a new line was drawn by another player.
## payload: compressed line Dictionary from ChalkLine.to_network_dict()
func _on_network_line_drawn(payload: Dictionary) -> void:
    # Check if we already have this line (might have been predicted)
    var line_id: int = payload.get("id", -1)
    var existing := _find_line_by_id(line_id)
    if existing:
        # Server confirmed our prediction — update ID if needed
        # (In full impl: reconcile any differences)
        return

    # Decompress and add
    var line := ChalkLine.new()
    line.from_network_dict(payload)
    # Ensure ID is set
    if line.id < 0:
        line.id = _next_line_id
        _next_line_id += 1

    _add_line(line)
    print("DrawSystem: received remote line %d from player %d" % [line.id, line.player_id])


## Server rejected our predicted line (cheat detection, chalk exhausted, etc.).
## payload: {client_line_id: int, reason: String}
func _on_network_line_rejected(payload: Dictionary) -> void:
    var client_line_id: int = payload.get("client_line_id", -1)
    var reason: String = payload.get("reason", "unknown")

    var line := _find_line_by_id(client_line_id)
    if line:
        _remove_line(line, "rejected")
        print("DrawSystem: line %d rejected by server: %s" % [client_line_id, reason])


## Batch sync of all active lines when a new player joins mid-match.
## payload: {lines: Array[Dictionary]} — each dict from ChalkLine.to_network_dict()
func _on_network_line_sync_batch(payload: Dictionary) -> void:
    var lines_data: Array = payload.get("lines", [])
    # Clear existing lines first (fresh slate from server)
    clear_all_lines()

    for line_data in lines_data:
        var line := ChalkLine.new()
        line.from_network_dict(line_data)
        if line.id < 0:
            line.id = _next_line_id
            _next_line_id += 1
        _add_line(line)

    print("DrawSystem: synced %d lines from server" % lines_data.size())


# =============================================================================
# MATCH STATE HANDLERS
# =============================================================================

## Match preparation phase started — reset chalk, enable drawing.
func _on_match_drawing_started(_payload) -> void:
    _chalk_remaining = CHALK_START
    _chalk_exhausted = false
    _match_time_exceeded = false
    clear_all_lines()
    EventBus.emit("game.chalk_meter_changed", {
        "remaining_percent": _chalk_remaining / CHALK_MAX,
        "remaining_chalk": _chalk_remaining,
    })


func _on_chalk_exhausted(_payload) -> void:
    _chalk_exhausted = true
    if _is_drawing:
        _finish_drawing()


# =============================================================================
# CHALK METER
# =============================================================================

var _last_emitted_chalk_pct: float = 1.0

func _emit_chalk_meter_if_changed() -> void:
    var pct := _chalk_remaining / CHALK_MAX
    if abs(pct - _last_emitted_chalk_pct) > 0.02:  # 2% threshold
        _last_emitted_chalk_pct = pct
        EventBus.emit("game.chalk_meter_changed", {
            "remaining_percent": pct,
            "remaining_chalk": _chalk_remaining,
        })


# =============================================================================
# PUBLIC API
# =============================================================================

## Return all active ChalkLine resources (for GhostSystem, save system, etc.).
func get_active_lines() -> Array[ChalkLine]:
    return _active_lines.duplicate()


## Return remaining chalk as a float (0.0 to CHALK_MAX).
func get_chalk_remaining() -> float:
    return _chalk_remaining


## Remove all active lines — used for scene teardown, match reset.
func clear_all_lines() -> void:
    for line in _active_lines.duplicate():
        _remove_line(line, "clear")
    _active_lines.clear()
    _line_nodes.clear()
    _fade_tweens.clear()
    _next_line_id = 0


## Check if a closed loop is formed by all lines connected to the given line.
func detect_closed_loop(line: ChalkLine) -> bool:
    if line.points.size() < 3:
        return false
    return line.points[0].distance_to(line.points[-1]) <= CONNECTION_THRESHOLD


# =============================================================================
# HELPERS
# =============================================================================

## Find a ChalkLine by its ID in the active array.
func _find_line_by_id(line_id: int) -> ChalkLine:
    for line in _active_lines:
        if line.id == line_id:
            return line
    return null


## Return the active chalk type for HUD display.
func get_current_chalk_type() -> int:
    return _current_chalk_type


## Set the chalk type (called by HUD when player switches chalk).
func set_chalk_type(chalk_type: int) -> void:
    _current_chalk_type = clampi(chalk_type, ChalkType.WHITE, ChalkType.YELLOW)
