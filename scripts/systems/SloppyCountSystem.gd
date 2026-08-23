# SloppyCountSystem.gd — Post-DRAWING quality validation for CHALK GAON
#
# When DRAWING ends → SEARCHING begins, runs a crossing-check on all
# regular player chalk lines. Lines that cross at least one other line
# form part of the trap net; isolated (non-crossing) lines are "sloppy."
#
# If ≥97% of lines cross others → PASS (+50 bonus). Otherwise → FAIL
# (-10 points per percentage point below 97%, score clamped to 0).
#
# Pluggable system: node under GameWorld/Systems. Communicates through
# EventBus. Uses segment-segment intersection geometry from ClusterSystem
# patterns (orientation test + bounding-box early-exit).
#
# Lifecycle:
#   match.state_changed(DRAWING→SEARCHING) → run_challenge()
#     → pause timer → zoom camera → analyze → highlight sloppy lines
#     → show overlay → apply score → resume timer
#
# Events (emitted):
#   game.sloppy_count_started     — {total_lines, timestamp}
#   game.sloppy_count_result      — {percentage, crossing_count, total_lines, passed, score_delta}
#   game.sloppy_count_finished    — {percentage, passed, score_delta}
#   game.score_changed            — {amount, reason: "sloppy_count", new_total}

class_name SloppyCountSystem
extends Node


# ── Constants ──────────────────────────────────────────────────────────────────

const THRESHOLD_PERCENT := 97
const BONUS_SCORE := 50
const PENALTY_PER_POINT := 10
const ZOOM_DURATION := 1.5
const HIGHLIGHT_DURATION := 3.0
const RESULT_DISPLAY_DURATION := 4.0
const CAMERA_RETURN_DURATION := 0.8
const ZOOM_PADDING := 0.2  # 20% padding around bounding rect


# ── Instance State ─────────────────────────────────────────────────────────────

## Reference to GameWorld root.
var _game_world: Node2D = null

## Reference to DrawSystem sibling for accessing active chalk lines.
var _draw_system: Node = null

## Reference to the Camera2D in game_world.
var _camera: Camera2D = null

## Saved camera state for restoration after challenge.
var _saved_camera_position: Vector2 = Vector2.ZERO
var _saved_camera_zoom: Vector2 = Vector2.ONE

## Whether the challenge is currently running.
var _is_running: bool = false

## Score tracking.
var _current_score: int = 0


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Find GameWorld
	_game_world = get_tree().current_scene as Node2D
	
	# Find sibling DrawSystem
	var systems_node := get_parent()
	if systems_node:
		_draw_system = systems_node.get_node_or_null("DrawSystem")
	
	# Find camera
	if _game_world:
		_camera = _game_world.get_node_or_null("Camera2D") as Camera2D
		if not _camera:
			# Search deeper
			for child in _game_world.get_children():
				if child is Camera2D:
					_camera = child as Camera2D
					break
	
	# Create camera if none exists
	if not _camera and _game_world:
		_camera = Camera2D.new()
		_camera.name = "Camera2D"
		_camera.enabled = true
		_camera.make_current()
		_game_world.add_child(_camera)
		print("SloppyCountSystem: created Camera2D")

	# Subscribe to match state changes
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	
	print("SloppyCountSystem: ready")


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)


# ── Event Handlers ─────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)
	
	# Trigger on DRAWING → SEARCHING transition
	if from_state == GameState.MatchState.DRAWING and to_state == GameState.MatchState.SEARCHING:
		run_challenge()


# ── Challenge Orchestration ────────────────────────────────────────────────────

func run_challenge() -> void:
	if _is_running:
		print("SloppyCountSystem: already running, skipping")
		return
	
	_is_running = true
	
	# Step 0: Pause match timer
	MatchTimer.pause()
	
	# Get active regular chalk lines (exclude ghost lines)
	var all_lines: Array = _get_regular_chalk_lines()
	var total_lines := all_lines.size()
	
	if total_lines < 2:
		print("SloppyCountSystem: fewer than 2 lines, skipping challenge")
		_is_running = false
		MatchTimer.resume()
		return
	
	# Emit started event
	EventBus.emit(EventBus.EV_GAME_SLOPPY_COUNT_STARTED, {
		"total_lines": total_lines,
		"timestamp": Time.get_ticks_msec(),
	})
	
	# Step 1: Zoom camera to frame all chalk lines
	await _zoom_to_chalk_lines(all_lines)
	
	# Step 2: Run crossing analysis
	var result: Dictionary = _analyze_crossings(all_lines)
	var percentage: float = result["percentage"]
	var crossing_count: int = result["crossing_count"]
	var non_crossing_ids: Array = result["non_crossing_line_ids"]
	
	# Step 3: Determine pass/fail and score delta
	var passed: bool = percentage >= THRESHOLD_PERCENT
	var score_delta: int
	if passed:
		score_delta = BONUS_SCORE
	else:
		var points_below := int(ceil(THRESHOLD_PERCENT - percentage))
		score_delta = -points_below * PENALTY_PER_POINT
	
	# Step 4: Emit result event
	EventBus.emit(EventBus.EV_GAME_SLOPPY_COUNT_RESULT, {
		"percentage": percentage,
		"crossing_count": crossing_count,
		"total_lines": total_lines,
		"passed": passed,
		"score_delta": score_delta,
	})
	
	# Step 5: Highlight sloppy lines (non-crossing) in red
	_highlight_sloppy_lines(non_crossing_ids, all_lines)
	
	# Step 6: Show result overlay
	_show_result_overlay(percentage, passed, score_delta)
	
	# Step 7: Wait for result display duration
	await _wait(RESULT_DISPLAY_DURATION)
	
	# Step 8: Un-highlight sloppy lines
	_unhighlight_sloppy_lines(non_crossing_ids, all_lines)
	
	# Step 9: Apply score
	_current_score = _apply_score(score_delta)
	
	# Step 10: Emit finished event
	EventBus.emit(EventBus.EV_GAME_SLOPPY_COUNT_FINISHED, {
		"percentage": percentage,
		"passed": passed,
		"score_delta": score_delta,
	})
	
	# Step 11: Return camera to original position
	await _return_camera()
	
	# Step 12: Resume match timer
	MatchTimer.resume()
	
	_is_running = false
	print("SloppyCountSystem: challenge complete — %.1f%% crossing, %s, score %+d" % [percentage, "PASS" if passed else "FAIL", score_delta])


# ── Camera Zoom ────────────────────────────────────────────────────────────────

func _zoom_to_chalk_lines(lines: Array) -> void:
	if not _camera:
		print("SloppyCountSystem: no camera found, skipping zoom")
		return
	
	# Save current camera state
	_saved_camera_position = _camera.position
	_saved_camera_zoom = _camera.zoom
	
	# Compute bounding rect of all line points
	var bbox := _compute_lines_bbox(lines)
	if bbox == Rect2():
		return
	
	# Add 20% padding
	var pad_x := bbox.size.x * ZOOM_PADDING
	var pad_y := bbox.size.y * ZOOM_PADDING
	bbox = Rect2(
		bbox.position.x - pad_x,
		bbox.position.y - pad_y,
		bbox.size.x + pad_x * 2.0,
		bbox.size.y + pad_y * 2.0
	)
	
	# Compute target center
	var target_center := bbox.position + bbox.size * 0.5
	
	# Compute zoom level to fit bounds in viewport
	var viewport_size := _camera.get_viewport_rect().size
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		viewport_size = Vector2(360, 640)  # fallback mobile resolution
	
	var zoom_x: float = viewport_size.x / max(bbox.size.x, 1.0)
	var zoom_y: float = viewport_size.y / max(bbox.size.y, 1.0)
	var target_zoom: float = min(zoom_x, zoom_y)
	# Clamp zoom — don't zoom out too far or too close
	target_zoom = clampf(target_zoom, 0.1, 3.0)
	
	# Tween to target
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_camera, "position", target_center, ZOOM_DURATION)
	tween.tween_property(_camera, "zoom", Vector2(target_zoom, target_zoom), ZOOM_DURATION)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	
	await tween.finished


func _return_camera() -> void:
	if not _camera:
		return
	
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_camera, "position", _saved_camera_position, CAMERA_RETURN_DURATION)
	tween.tween_property(_camera, "zoom", _saved_camera_zoom, CAMERA_RETURN_DURATION)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	
	await tween.finished


# ── Crossing Analysis ──────────────────────────────────────────────────────────

func _analyze_crossings(lines: Array) -> Dictionary:
	var total_lines := lines.size()
	var crossing_line_ids: Array[int] = []
	var non_crossing_line_ids: Array[int] = []
	
	# For each line, check if any segment intersects any segment of another line
	for i in range(total_lines):
		var line_a = lines[i]
		var crosses_any := false
		
		for j in range(total_lines):
			if i == j:
				continue
			
			var line_b = lines[j]
			if _lines_intersect(line_a, line_b):
				crosses_any = true
				break
		
		var line_id: int = line_a.get("line_id", -1)
		if crosses_any:
			crossing_line_ids.append(line_id)
		else:
			non_crossing_line_ids.append(line_id)
	
	var crossing_count := crossing_line_ids.size()
	var percentage: float
	if total_lines > 0:
		percentage = (float(crossing_count) / float(total_lines)) * 100.0
	else:
		percentage = 0.0
	
	print("SloppyCountSystem: %d/%d lines cross (%.1f%%)" % [crossing_count, total_lines, percentage])
	
	return {
		"total_lines": total_lines,
		"crossing_count": crossing_count,
		"crossing_line_ids": crossing_line_ids,
		"non_crossing_line_ids": non_crossing_line_ids,
		"percentage": percentage,
	}


## Check if any segment of line_a intersects any segment of line_b.
func _lines_intersect(line_a: Dictionary, line_b: Dictionary) -> bool:
	var pts_a: Array = line_a.get("points", [])
	var pts_b: Array = line_b.get("points", [])
	
	if pts_a.size() < 2 or pts_b.size() < 2:
		return false
	
	# Bounding box early exit
	var bbox_a: Rect2 = line_a.get("bbox", Rect2())
	var bbox_b: Rect2 = line_b.get("bbox", Rect2())
	if bbox_a != Rect2() and bbox_b != Rect2():
		if not bbox_a.intersects(bbox_b, true):
			return false
	
	for i in range(pts_a.size() - 1):
		var a1: Vector2 = pts_a[i]
		var a2: Vector2 = pts_a[i + 1]
		for j in range(pts_b.size() - 1):
			var b1: Vector2 = pts_b[j]
			var b2: Vector2 = pts_b[j + 1]
			if _segments_intersect(a1, a2, b1, b2):
				return true
	
	return false


## Check if two 2D line segments intersect using orientation (cross-product) test.
func _segments_intersect(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool:
	var o1: float = _orientation(a1, a2, b1)
	var o2: float = _orientation(a1, a2, b2)
	var o3: float = _orientation(b1, b2, a1)
	var o4: float = _orientation(b1, b2, a2)

	# General case: segments straddle each other
	if o1 * o2 < 0.0 and o3 * o4 < 0.0:
		return true

	# Collinear / endpoint-touching cases
	if o1 == 0.0 and _point_on_segment(a1, a2, b1): return true
	if o2 == 0.0 and _point_on_segment(a1, a2, b2): return true
	if o3 == 0.0 and _point_on_segment(b1, b2, a1): return true
	if o4 == 0.0 and _point_on_segment(b1, b2, a2): return true

	return false


func _orientation(p: Vector2, q: Vector2, r: Vector2) -> float:
	return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)


func _point_on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return (p.x >= min(a.x, b.x) - 0.0001 and p.x <= max(a.x, b.x) + 0.0001 and
			p.y >= min(a.y, b.y) - 0.0001 and p.y <= max(a.y, b.y) + 0.0001)


# ── Line Highlighting ──────────────────────────────────────────────────────────

## Turn non-crossing lines red by modulating their Line2D nodes.
func _highlight_sloppy_lines(non_crossing_ids: Array, lines: Array) -> void:
	if not _draw_system:
		return
	
	# Build a set of non-crossing IDs for quick lookup
	var id_set: Dictionary = {}
	for lid in non_crossing_ids:
		id_set[lid] = true
	
	# Find Line2D nodes and set modulate
	for line_data in lines:
		var line_id: int = line_data.get("line_id", -1)
		if not id_set.has(line_id):
			continue
		
		var line2d: Line2D = _find_line2d_node(line_id)
		if line2d and is_instance_valid(line2d):
			# Flash red
			var tween := create_tween()
			tween.tween_property(line2d, "modulate", Color(1.0, 0.15, 0.15, 1.0), 0.3)
			tween.set_trans(Tween.TRANS_SINE)
	
	print("SloppyCountSystem: highlighted %d sloppy lines" % non_crossing_ids.size())


## Restore original modulate on previously highlighted lines.
func _unhighlight_sloppy_lines(non_crossing_ids: Array, lines: Array) -> void:
	if not _draw_system:
		return
	
	var id_set: Dictionary = {}
	for lid in non_crossing_ids:
		id_set[lid] = true
	
	for line_data in lines:
		var line_id: int = line_data.get("line_id", -1)
		if not id_set.has(line_id):
			continue
		
		var line2d: Line2D = _find_line2d_node(line_id)
		if line2d and is_instance_valid(line2d):
			var tween := create_tween()
			tween.tween_property(line2d, "modulate", Color.WHITE, 0.3)
			tween.set_trans(Tween.TRANS_SINE)


# ── Result Overlay ─────────────────────────────────────────────────────────────

func _show_result_overlay(percentage: float, passed: bool, score_delta: int) -> void:
	var overlay_scene := load("res://scenes/overlay/sloppy_count_overlay.tscn") as PackedScene
	if not overlay_scene:
		push_warning("SloppyCountSystem: sloppy_count_overlay.tscn not found")
		return
	
	var overlay := overlay_scene.instantiate()
	get_tree().root.add_child(overlay)
	
	if overlay.has_method("show_result"):
		overlay.show_result(percentage, passed, score_delta)


# ── Score ──────────────────────────────────────────────────────────────────────

func _apply_score(score_delta: int) -> int:
	var new_score := _current_score + score_delta
	if new_score < 0:
		new_score = 0
	
	EventBus.emit(EventBus.EV_GAME_SCORE_CHANGED, {
		"amount": score_delta,
		"reason": "sloppy_count",
		"new_total": new_score,
	})
	
	print("SloppyCountSystem: score %+d → %d" % [score_delta, new_score])
	return new_score


# ── Helpers ────────────────────────────────────────────────────────────────────

## Get all regular chalk lines from DrawSystem (exclude ghost lines).
## Returns Array[Dictionary] with keys: line_id, points, bbox.
func _get_regular_chalk_lines() -> Array:
	var result: Array = []
	
	if not _draw_system:
		return result
	
	var active_lines: Array = _draw_system.get_active_lines()
	for line in active_lines:
		# Skip ghost lines
		if line.is_ghost:
			continue
		
		var pts: Array = line.points
		if pts.size() < 2:
			continue
		
		var bbox := _compute_bbox(pts)
		result.append({
			"line_id": line.id,
			"points": pts,
			"bbox": bbox,
			"line_ref": line,
		})
	
	return result


func _compute_bbox(points: Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x: float = points[0].x
	var min_y: float = points[0].y
	var max_x: float = points[0].x
	var max_y: float = points[0].y
	for pt in points:
		if pt.x < min_x: min_x = pt.x
		if pt.y < min_y: min_y = pt.y
		if pt.x > max_x: max_x = pt.x
		if pt.y > max_y: max_y = pt.y
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


func _compute_lines_bbox(lines: Array) -> Rect2:
	if lines.is_empty():
		return Rect2()
	
	var first_bbox: Rect2 = lines[0].get("bbox", Rect2())
	if first_bbox == Rect2():
		return Rect2()
	
	var min_x := first_bbox.position.x
	var min_y := first_bbox.position.y
	var max_x := first_bbox.position.x + first_bbox.size.x
	var max_y := first_bbox.position.y + first_bbox.size.y
	
	for i in range(1, lines.size()):
		var bb: Rect2 = lines[i].get("bbox", Rect2())
		if bb == Rect2():
			continue
		if bb.position.x < min_x: min_x = bb.position.x
		if bb.position.y < min_y: min_y = bb.position.y
		if bb.position.x + bb.size.x > max_x: max_x = bb.position.x + bb.size.x
		if bb.position.y + bb.size.y > max_y: max_y = bb.position.y + bb.size.y
	
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


## Find a Line2D node by its name (ChalkLine_<id>) in the DrawSystem's chalk container.
func _find_line2d_node(line_id: int) -> Line2D:
	if not _draw_system:
		return null
	
	# The chalk container is a child of GameWorld named "ChalkLines"
	var container: Node2D = null
	if _game_world:
		container = _game_world.get_node_or_null("ChalkLines") as Node2D
	
	if not container:
		# Fallback: search entire scene tree
		for node in get_tree().get_nodes_in_group("chalk_lines"):
			if node is Node2D:
				container = node
				break
	
	if not container:
		return null
	
	var node_name := "ChalkLine_%d" % line_id
	return container.get_node_or_null(node_name) as Line2D


func _wait(seconds: float) -> void:
	var timer := get_tree().create_timer(seconds)
	await timer.timeout
