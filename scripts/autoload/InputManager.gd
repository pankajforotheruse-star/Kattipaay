# InputManager.gd — Normalizes all input into abstract game commands
# Touch, mouse, keyboard, and gamepad are translated into "input.*" events
# on the EventBus. Game systems never read Input.* directly.

extends Node

## If true, emits input.move_start on touch down, input.move_end on touch up.
## In future: can switch to joystick mode.
var touch_to_move_enabled: bool = true

func _ready() -> void:
	# Ensure mouse clicks act as touches (for desktop testing)
	pass

func _input(event: InputEvent) -> void:
	if not touch_to_move_enabled:
		return

	# Touch down / mouse click
	if event is InputEventScreenTouch and event.pressed:
		_handle_touch_start(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_touch_start(event.position)

	# Touch up / mouse release
	elif event is InputEventScreenTouch and not event.pressed:
		_handle_touch_end(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_handle_touch_end(event.position)

func _handle_touch_start(screen_pos: Vector2) -> void:
	EventBus.emit("input.move_start", {
		"screen_position": screen_pos,
	})

func _handle_touch_end(_screen_pos: Vector2) -> void:
	EventBus.emit("input.move_end", {})

## Convert screen position to world position using the current viewport's canvas transform.
static func screen_to_world(screen_pos: Vector2) -> Vector2:
	var viewport := Engine.get_main_loop().root
	if viewport is Window:
		var camera := viewport.get_camera_2d()
		if camera:
			return camera.get_screen_center() + (screen_pos - viewport.size / 2.0) * (1.0 / camera.zoom)
	return screen_pos
