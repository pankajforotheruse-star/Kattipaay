extends SceneTree
## Simulated touch arbitration only. Not a substitute for real Android devices.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if packed == null:
		push_error("Touch smoke scene missing")
		quit(1)
		return
	var game := packed.instantiate()
	root.add_child(game)
	await physics_frame
	var press := InputEventScreenTouch.new()
	press.index = 1
	press.position = Vector2(100, 420)
	press.pressed = true
	game.drawing_mode = false
	game._unhandled_input(press)
	_check(game.mobile_move_touch == 1, "Left thumb captures movement")
	var drag := InputEventScreenDrag.new()
	drag.index = 1
	drag.position = Vector2(160, 420)
	drag.relative = Vector2(60, 0)
	game._unhandled_input(drag)
	_check(game.mobile_move.x > 0.5, "Touch joystick produces movement vector")
	var release := InputEventScreenTouch.new()
	release.index = 1
	release.position = Vector2(160, 420)
	release.pressed = false
	game._unhandled_input(release)
	_check(game.mobile_move_touch == -1 and game.mobile_move == Vector2.ZERO, "Joystick releases without stuck input")
	game.drawing_mode = true
	game.draw_controller.enabled = true
	var draw_touch := InputEventScreenTouch.new()
	draw_touch.index = 2
	draw_touch.position = Vector2(230, 300)
	draw_touch.pressed = true
	game._unhandled_input(draw_touch)
	game.draw_controller._unhandled_input(draw_touch)
	_check(game.mobile_move_touch == -1, "Drawing finger cannot steal movement joystick")
	_check(game.draw_controller.active_touch_id == 2, "Drawing captures its own touch identifier")
	draw_touch.pressed = false
	game.draw_controller._unhandled_input(draw_touch)
	_check(game.draw_controller.active_touch_id == -1, "Drawing releases touch capture")
	game.match_paused = true
	game.draw_controller.enabled = false
	draw_touch.pressed = true
	game.draw_controller._unhandled_input(draw_touch)
	_check(game.draw_controller.active_touch_id == -1, "Paused game rejects new drawing touch")
	if failures.is_empty():
		print("CHALK_GAON_3D_TOUCH_ARBITRATION: PASS")
		quit(0)
	else:
		for issue in failures:
			push_error("TOUCH_ARBITRATION: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
