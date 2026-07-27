# ChalkSlider.gd — Chalk-styled horizontal slider
# Track: #3B2D23, fill: #CC6B49 gradient, handle: 32×32 chalk circle.
# Configurable min/max/step/value via @export.
class_name ChalkSlider
extends HSlider

@export var slider_label: String = ""
@export var show_value: bool = true
@export var value_suffix: String = "%"

const COLOR_TRACK := Color("3B2D23")
const COLOR_FILL := Color("CC6B49")
const COLOR_HANDLE := Color("F5F0E8")

@onready var _label: Label = %SliderLabel
@onready var _value_label: Label = %ValueLabel

func _ready() -> void:
	custom_minimum_size = Vector2(200, 40)
	if _label:
		_label.text = slider_label
	_update_value_display()
	value_changed.connect(_on_value_changed)

func _on_value_changed(_new_value: float) -> void:
	_update_value_display()

func _update_value_display() -> void:
	if _value_label and show_value:
		_value_label.text = str(int(value)) + value_suffix

func get_value_int() -> int:
	return int(value)

func set_slider_value(v: float) -> void:
	value = v
	_update_value_display()
