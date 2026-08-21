# SloppyCountOverlay.gd — Full-screen result overlay for Sloppy Count Challenge
#
# CanvasLayer that sits on top of the HUD (layer 20). Creates all UI nodes
# programmatically — dark semi-transparent background, percentage count-up,
# PASS/FAIL label with color animation, score delta text, vignette effect,
# and "Tap to continue" prompt.
#
# All visuals meta-drawn — no textures.
#
# Public API:
#   show_result(percentage: float, passed: bool, score_delta: int) — start the overlay

class_name SloppyCountOverlay
extends CanvasLayer


# ── Constants ──────────────────────────────────────────────────────────────────

const COUNT_UP_DURATION := 0.8
const LABEL_DELAY := 0.3
const SCORE_BOUNCE_DURATION := 0.5
const SCREEN_SHAKE_AMPLITUDE := 5.0
const SCREEN_SHAKE_DURATION := 0.3
const TAP_PROMPT_DELAY := 2.0
const VIGNETTE_PULSE_DURATION := 1.0


# ── Onready / Dynamic Nodes ────────────────────────────────────────────────────

var _background: ColorRect = null
var _percentage_label: Label = null
var _result_label: Label = null
var _score_label: Label = null
var _tap_prompt: Label = null
var _vignette: ColorRect = null


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 20
	
	_create_background()
	_create_percentage_label()
	_create_result_label()
	_create_score_label()
	_create_tap_prompt()
	_create_vignette()


# ── Public API ─────────────────────────────────────────────────────────────────

func show_result(percentage: float, passed: bool, score_delta: int) -> void:
	# Set colors based on pass/fail
	var color: Color = Color(0.2, 1.0, 0.3, 1.0) if passed else Color(1.0, 0.15, 0.15, 1.0)
	var label_text: String = "CLEAN COUNT" if passed else "SLOPPY COUNT"
	
	# Start count-up animation
	_animate_count_up(percentage)
	
	# After count-up + delay, show result label
	var tween := create_tween()
	tween.tween_interval(COUNT_UP_DURATION + LABEL_DELAY)
	tween.tween_callback(func():
		_result_label.text = label_text
		_result_label.add_theme_color_override("font_color", color)
		_result_label.modulate.a = 0.0
		_result_label.show()
		
		var label_tween := create_tween()
		label_tween.tween_property(_result_label, "modulate:a", 1.0, 0.3)
		
		# Show score delta
		_show_score_delta(score_delta, passed)
		
		# Vignette pulse or shake
		if passed:
			_pulse_green_vignette()
		else:
			_shake_red_vignette()
	)
	
	# Show tap prompt after delay
	var prompt_tween := create_tween()
	prompt_tween.tween_interval(TAP_PROMPT_DELAY)
	prompt_tween.tween_callback(func():
		_tap_prompt.show()
		_tap_prompt.modulate.a = 0.0
		var fade_tween := create_tween()
		fade_tween.tween_property(_tap_prompt, "modulate:a", 0.8, 0.5)
	)


# ── UI Creation ────────────────────────────────────────────────────────────────

func _create_background() -> void:
	_background = ColorRect.new()
	_background.name = "Background"
	_background.color = Color(0.0, 0.0, 0.0, 0.5)
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_background)
	
	# Tap to dismiss
	_background.gui_input.connect(_on_background_input)


func _create_percentage_label() -> void:
	_percentage_label = Label.new()
	_percentage_label.name = "PercentageLabel"
	_percentage_label.text = "0%"
	_percentage_label.add_theme_font_size_override("font_size", 72)
	_percentage_label.add_theme_color_override("font_color", Color.WHITE)
	_percentage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_percentage_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_percentage_label.anchors_preset = Control.PRESET_CENTER
	_percentage_label.offset_left = -200
	_percentage_label.offset_top = -100
	_percentage_label.offset_right = 200
	_percentage_label.offset_bottom = 0
	add_child(_percentage_label)


func _create_result_label() -> void:
	_result_label = Label.new()
	_result_label.name = "ResultLabel"
	_result_label.text = ""
	_result_label.add_theme_font_size_override("font_size", 32)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.anchors_preset = Control.PRESET_CENTER
	_result_label.offset_left = -200
	_result_label.offset_top = 30
	_result_label.offset_right = 200
	_result_label.offset_bottom = 70
	_result_label.hide()
	add_child(_result_label)


func _create_score_label() -> void:
	_score_label = Label.new()
	_score_label.name = "ScoreLabel"
	_score_label.text = ""
	_score_label.add_theme_font_size_override("font_size", 40)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_label.anchors_preset = Control.PRESET_CENTER
	_score_label.offset_left = -200
	_score_label.offset_top = 80
	_score_label.offset_right = 200
	_score_label.offset_bottom = 130
	_score_label.hide()
	add_child(_score_label)


func _create_tap_prompt() -> void:
	_tap_prompt = Label.new()
	_tap_prompt.name = "TapPrompt"
	_tap_prompt.text = "Tap to continue"
	_tap_prompt.add_theme_font_size_override("font_size", 20)
	_tap_prompt.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.8))
	_tap_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tap_prompt.anchors_preset = -1
	_tap_prompt.anchor_left = 0.5
	_tap_prompt.anchor_right = 0.5
	_tap_prompt.anchor_top = 1.0
	_tap_prompt.anchor_bottom = 1.0
	_tap_prompt.offset_left = -150
	_tap_prompt.offset_top = -100
	_tap_prompt.offset_right = 150
	_tap_prompt.offset_bottom = -60
	_tap_prompt.hide()
	add_child(_tap_prompt)


func _create_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.name = "Vignette"
	_vignette.color = Color(0.0, 0.0, 0.0, 0.0)
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)


# ── Animations ─────────────────────────────────────────────────────────────────

func _animate_count_up(target: float) -> void:
	var elapsed := 0.0
	_percentage_label.text = "0%"
	
	var tween := create_tween()
	tween.tween_method(_set_percentage_amount, 0.0, target, COUNT_UP_DURATION)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)


func _set_percentage_amount(val: float) -> void:
	_percentage_label.text = "%d%%" % int(round(val))


func _show_score_delta(score_delta: int, passed: bool) -> void:
	var color: Color
	var prefix: String
	if score_delta >= 0:
		prefix = "+"
		color = Color(0.2, 1.0, 0.3, 1.0)
	else:
		prefix = ""
		color = Color(1.0, 0.15, 0.15, 1.0)
	
	_score_label.text = "%s%d" % [prefix, score_delta]
	_score_label.add_theme_color_override("font_color", color)
	_score_label.scale = Vector2.ZERO
	_score_label.show()
	
	# Bounce animation: 0 → 1.2 → 1.0
	var tween := create_tween()
	tween.tween_property(_score_label, "scale", Vector2(1.2, 1.2), SCORE_BOUNCE_DURATION * 0.6)
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(_score_label, "scale", Vector2(1.0, 1.0), SCORE_BOUNCE_DURATION * 0.4)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)


func _pulse_green_vignette() -> void:
	_vignette.color = Color(0.0, 0.5, 0.2, 0.0)
	var tween := create_tween()
	tween.set_loops(2)
	tween.tween_property(_vignette, "color:a", 0.15, VIGNETTE_PULSE_DURATION * 0.5)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_vignette, "color:a", 0.0, VIGNETTE_PULSE_DURATION * 0.5)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _shake_red_vignette() -> void:
	_vignette.color = Color(0.5, 0.0, 0.0, 0.2)
	
	# Screen shake: offset the CanvasLayer itself
	var original_offset := offset
	var shake_tween := create_tween()
	shake_tween.set_loops(6)
	shake_tween.tween_method(
		func(_x: float):
			offset = original_offset + Vector2(
				randf_range(-SCREEN_SHAKE_AMPLITUDE, SCREEN_SHAKE_AMPLITUDE),
				randf_range(-SCREEN_SHAKE_AMPLITUDE, SCREEN_SHAKE_AMPLITUDE)
			)
		,
		0.0,
		1.0,
		SCREEN_SHAKE_DURATION / 6.0
	)
	shake_tween.tween_callback(func():
		offset = original_offset
		_vignette.color = Color(0.5, 0.0, 0.0, 0.0)
	)


# ── Input ──────────────────────────────────────────────────────────────────────

func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_dismiss()
	elif event is InputEventScreenTouch and event.pressed:
		_dismiss()


func _dismiss() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.3)
	tween.tween_callback(queue_free)
