# InputManager.gd — Normalizes all input into abstract game commands
# Touch, mouse, keyboard, and gamepad are translated into "input.*" events
# on the EventBus. Game systems never read Input.* directly.
#
# Two-finger drawing gesture (GDD §4):
#   1. Finger 0 down → EventBus.EV_INPUT_MOVE_START (anchor/movement finger)
#   2. Finger 1 down while Finger 0 is held → EventBus.EV_INPUT_DRAW_START (drawing finger)
#   3. Finger 1 moves → EventBus.EV_INPUT_DRAW_UPDATE
#   4. Finger 1 up → EventBus.EV_INPUT_DRAW_END
#   5. Finger 0 up → EventBus.EV_INPUT_MOVE_END
#
# Undo gesture:
#   - Shake-to-undo: accelerometer-based shake detection
#   - Keyboard shortcut: 'U' key for desktop testing

extends Node

## If true, emits input.move_start on touch down, input.move_end on touch up.
## In future: can switch to joystick mode.
var touch_to_move_enabled: bool = true

## Entity ID of the local player (set by GameWorld when player spawns).
var local_entity_id: int = 1

## Current active chalk type (set by HUD chalk selector).
var current_chalk_type: int = 0  # ChalkType.WHITE

# --- Two-Finger Gesture State ---

## Dictionary mapping touch index → {position: Vector2, start_time: float}
var _active_touches: Dictionary = {}

## Index of the anchor finger (first finger down — used for movement).
## -1 when no anchor is active.
var _anchor_touch_index: int = -1

## Index of the drawing finger (second finger down — used for chalk drawing).
## -1 when no drawing finger is active.
var _draw_touch_index: int = -1

## Whether the mouse is emulating the anchor finger (for desktop testing).
var _mouse_is_anchor: bool = false

## Whether the right mouse button / shift+click is emulating the drawing finger.
var _mouse_is_drawing: bool = false

# --- Shake Detection ---

## Whether accelerometer-based shake-to-undo is enabled.
var shake_to_undo_enabled: bool = true

## Threshold for shake detection (accelerometer magnitude change).
const SHAKE_THRESHOLD := 2.5

## Number of recent accelerometer samples to track.
const SHAKE_SAMPLE_COUNT := 20

## Minimum time between shake triggers (seconds).
const SHAKE_COOLDOWN := 1.0

var _accel_samples: Array[Vector3] = []
var _last_shake_time: float = -SHAKE_COOLDOWN
var _has_accelerometer: bool = false


func _ready() -> void:
	# Check accelerometer availability
	_has_accelerometer = not Input.get_accelerometer().is_zero_approx() or true
	# In practice: Input.get_accelerometer() returns (0,0,0) on desktop.
	# We try to use it; shake detection gracefully handles unavailable sensor.

	# Start accelerometer polling if available
	if _has_accelerometer:
		set_process(true)


func _process(_delta: float) -> void:
	# --- Poll accelerometer for shake detection ---
	if shake_to_undo_enabled:
		_poll_accelerometer()


func _input(event: InputEvent) -> void:
	if not touch_to_move_enabled:
		return

	# --- Keyboard: Undo shortcut (desktop testing) ---
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_U:
			EventBus.emit(EventBus.EV_INPUT_UNDO_DRAW, {})
			return

	# --- Touch handling ---
	if event is InputEventScreenTouch:
		if event.pressed:
			_handle_touch_down(event.index, event.position)
		else:
			_handle_touch_up(event.index)

	elif event is InputEventScreenDrag:
		_handle_touch_drag(event.index, event.position)

	# --- Mouse fallback (desktop testing) ---
	# Left click = anchor/movement finger
	# Right click (or Ctrl+Left click) = drawing finger
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if Input.is_key_pressed(KEY_CTRL):
					# Ctrl+Click = drawing finger
					_handle_mouse_draw_start(event.position)
				else:
					# Plain left click = anchor finger
					_handle_mouse_anchor_start(event.position)
			else:
				if _mouse_is_drawing:
					_handle_mouse_draw_end(event.position)
				elif _mouse_is_anchor:
					_handle_mouse_anchor_end(event.position)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_handle_mouse_draw_start(event.position)
			else:
				_handle_mouse_draw_end(event.position)

	elif event is InputEventMouseMotion:
		if _mouse_is_drawing:
			_handle_mouse_draw_move(event.position)


# =============================================================================
# TOUCH HANDLERS
# =============================================================================

func _handle_touch_down(index: int, screen_pos: Vector2) -> void:
	_active_touches[index] = {
		"position": screen_pos,
		"start_time": Time.get_ticks_msec() / 1000.0,
	}

	if _anchor_touch_index == -1:
		# First finger → anchor (movement)
		_anchor_touch_index = index
		EventBus.emit(EventBus.EV_INPUT_MOVE_START, {
			"entity_id": local_entity_id,
			"screen_position": screen_pos,
		})

	elif _draw_touch_index == -1 and index != _anchor_touch_index:
		# Second finger → drawing
		_draw_touch_index = index
		var world_pos := screen_to_world(screen_pos)
		EventBus.emit(EventBus.EV_INPUT_DRAW_START, {
			"entity_id": local_entity_id,
			"position": world_pos,
			"chalk_type": current_chalk_type,
		})


func _handle_touch_up(index: int) -> void:
	if _active_touches.has(index):
		_active_touches.erase(index)

	if index == _draw_touch_index:
		# Drawing finger released
		_draw_touch_index = -1
		EventBus.emit(EventBus.EV_INPUT_DRAW_END, {
			"entity_id": local_entity_id,
		})

	elif index == _anchor_touch_index:
		# Anchor finger released → end movement
		_anchor_touch_index = -1
		EventBus.emit(EventBus.EV_INPUT_MOVE_END, {})

		# If drawing finger is still active, cancel drawing too
		# (drawing requires anchor to be held — GDD §4)
		if _draw_touch_index != -1:
			EventBus.emit(EventBus.EV_INPUT_DRAW_END, {
				"entity_id": local_entity_id,
			})
			_draw_touch_index = -1


func _handle_touch_drag(index: int, screen_pos: Vector2) -> void:
	if _active_touches.has(index):
		_active_touches[index]["position"] = screen_pos

	if index == _draw_touch_index:
		# Drawing finger moved
		var world_pos := screen_to_world(screen_pos)
		EventBus.emit(EventBus.EV_INPUT_DRAW_UPDATE, {
			"entity_id": local_entity_id,
			"position": world_pos,
		})
	# Note: anchor finger drag is handled by the MovementSystem's continuous
	# pathfinding — InputManager already emitted move_start, and the system
	# follows the anchor position continuously via _process or repeated events.
	# For now, we re-emit move_start on anchor drag to update target.
	elif index == _anchor_touch_index:
		EventBus.emit(EventBus.EV_INPUT_MOVE_START, {
			"entity_id": local_entity_id,
			"screen_position": screen_pos,
		})


# =============================================================================
# MOUSE HANDLERS (Desktop Testing)
# =============================================================================

func _handle_mouse_anchor_start(screen_pos: Vector2) -> void:
	_mouse_is_anchor = true
	if _draw_touch_index != -1:
		return  # Already drawing via right-click
	EventBus.emit(EventBus.EV_INPUT_MOVE_START, {
		"entity_id": local_entity_id,
		"screen_position": screen_pos,
	})


func _handle_mouse_anchor_end(_screen_pos: Vector2) -> void:
	_mouse_is_anchor = false
	EventBus.emit(EventBus.EV_INPUT_MOVE_END, {})
	if _mouse_is_drawing:
		_mouse_is_drawing = false
		EventBus.emit(EventBus.EV_INPUT_DRAW_END, {
			"entity_id": local_entity_id,
		})


func _handle_mouse_draw_start(screen_pos: Vector2) -> void:
	if not _mouse_is_anchor:
		# Auto-start anchor if drawing without anchor (convenience for desktop)
		_mouse_is_anchor = true
		EventBus.emit(EventBus.EV_INPUT_MOVE_START, {
			"entity_id": local_entity_id,
			"screen_position": screen_pos,
		})
	_mouse_is_drawing = true
	var world_pos := screen_to_world(screen_pos)
	EventBus.emit(EventBus.EV_INPUT_DRAW_START, {
		"entity_id": local_entity_id,
		"position": world_pos,
		"chalk_type": current_chalk_type,
	})


func _handle_mouse_draw_end(_screen_pos: Vector2) -> void:
	_mouse_is_drawing = false
	EventBus.emit(EventBus.EV_INPUT_DRAW_END, {
		"entity_id": local_entity_id,
	})


func _handle_mouse_draw_move(screen_pos: Vector2) -> void:
	var world_pos := screen_to_world(screen_pos)
	EventBus.emit(EventBus.EV_INPUT_DRAW_UPDATE, {
		"entity_id": local_entity_id,
		"position": world_pos,
	})


# =============================================================================
# ACCELEROMETER (Shake-to-Undo)
# =============================================================================

func _poll_accelerometer() -> void:
	var accel := Input.get_accelerometer()

	# On desktop, accelerometer returns (0,0,0). Skip if no real data.
	if accel.length_squared() < 0.001:
		return

	_accel_samples.append(accel)
	if _accel_samples.size() > SHAKE_SAMPLE_COUNT:
		_accel_samples.pop_front()

	if _accel_samples.size() >= SHAKE_SAMPLE_COUNT:
		_detect_shake()


func _detect_shake() -> void:
	# Compute variance of acceleration magnitudes
	var sum := 0.0
	var magnitudes: Array[float] = []
	for a in _accel_samples:
		var m := a.length()
		magnitudes.append(m)
		sum += m
	var mean := sum / float(magnitudes.size())

	var variance := 0.0
	for m in magnitudes:
		variance += (m - mean) * (m - mean)
	variance /= float(magnitudes.size())

	# Count zero-crossings (direction changes) in each axis
	var crossings := 0
	for axis in range(3):
		for i in range(1, _accel_samples.size()):
			var prev := _accel_samples[i - 1][axis]
			var curr := _accel_samples[i][axis]
			if prev * curr < 0:  # sign change
				crossings += 1

	# Shake detected: high variance + many direction changes
	if variance > SHAKE_THRESHOLD and crossings > SHAKE_SAMPLE_COUNT / 2:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_shake_time >= SHAKE_COOLDOWN:
			_last_shake_time = now
			EventBus.emit(EventBus.EV_INPUT_UNDO_DRAW, {})
			print("InputManager: shake detected — undo triggered")


# =============================================================================
# UTILITY
# =============================================================================

## Convert screen position to world position using the current viewport's canvas transform.
static func screen_to_world(screen_pos: Vector2) -> Vector2:
	var viewport := Engine.get_main_loop().root
	if viewport is Window:
		var camera := viewport.get_camera_2d()
		if camera:
			return camera.get_screen_center() + (screen_pos - viewport.size / 2.0) * (1.0 / camera.zoom)
	return screen_pos


## Set chalk type from HUD (called when player switches chalk type).
func set_chalk_type(chalk_type: int) -> void:
	current_chalk_type = clampi(chalk_type, 0, 2)
