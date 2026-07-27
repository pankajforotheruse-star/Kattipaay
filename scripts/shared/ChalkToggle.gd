# ChalkToggle.gd — 2-segment ON/OFF toggle button
# Left segment = ON (selected by default), Right segment = OFF.
# Chalk border draws around active segment.
class_name ChalkToggle
extends HBoxContainer

signal toggled(on: bool)

@export var left_label: String = "ON"
@export var right_label: String = "OFF"
@export var is_on: bool = true:
	set(v):
		is_on = v
		_update_selection()

const COLOR_SELECTED_BG := Color("CC6B49")
const COLOR_UNSELECTED_BG := Color("2A2940")
const COLOR_SELECTED_TEXT := Color("F5F0E8")
const COLOR_UNSELECTED_TEXT := Color("C5BFB4")

@onready var _left_btn: Button = %LeftButton
@onready var _right_btn: Button = %RightButton

func _ready() -> void:
	_left_btn.text = left_label
	_right_btn.text = right_label
	_left_btn.pressed.connect(func(): _set_state(true))
	_right_btn.pressed.connect(func(): _set_state(false))
	_update_selection()

func _set_state(on_state: bool) -> void:
	if is_on == on_state:
		return
	is_on = on_state
	_update_selection()
	toggled.emit(is_on)
	EventBus.emit("ui.toggle_changed", {"toggle_name": name, "is_on": is_on})

func _update_selection() -> void:
	if not _left_btn or not _right_btn:
		return
	var sb_left := StyleBoxFlat.new()
	var sb_right := StyleBoxFlat.new()

	if is_on:
		sb_left.bg_color = COLOR_SELECTED_BG
		sb_right.bg_color = COLOR_UNSELECTED_BG
		_left_btn.add_theme_color_override("font_color", COLOR_SELECTED_TEXT)
		_right_btn.add_theme_color_override("font_color", COLOR_UNSELECTED_TEXT)
	else:
		sb_left.bg_color = COLOR_UNSELECTED_BG
		sb_right.bg_color = COLOR_SELECTED_BG
		_left_btn.add_theme_color_override("font_color", COLOR_UNSELECTED_TEXT)
		_right_btn.add_theme_color_override("font_color", COLOR_SELECTED_TEXT)

	sb_left.corner_radius_top_left = 8; sb_left.corner_radius_bottom_left = 8
	sb_right.corner_radius_top_right = 8; sb_right.corner_radius_bottom_right = 8

	_left_btn.add_theme_stylebox_override("normal", sb_left)
	_right_btn.add_theme_stylebox_override("normal", sb_right)
