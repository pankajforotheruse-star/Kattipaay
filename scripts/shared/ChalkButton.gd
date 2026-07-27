# ChalkButton.gd — Reusable chalk-styled button with variants
# Configurable label, icon, variant via @export.
# Emits signals through EventBus and locally. Minimum 56×56 tap target.
class_name ChalkButton
extends Button

enum Variant { PRIMARY, SECONDARY, TERTIARY, DANGER, SUCCESS, ICON }

@export var btn_variant: Variant = Variant.PRIMARY
@export var btn_label: String = "Button"
@export_multiline var btn_icon_text: String = ""  # Placeholder emoji/char icon

const COLOR_PRIMARY_BG := Color("CC6B49")
const COLOR_PRIMARY_BORDER := Color("FFD700")
const COLOR_SECONDARY_BG := Color("2A2940")
const COLOR_SECONDARY_BORDER := Color("C2783A")
const COLOR_TERTIARY_BG := Color("2A2940")
const COLOR_DANGER_BG := Color("B71C1C")
const COLOR_DANGER_BORDER := Color("E53935")
const COLOR_SUCCESS_BG := Color("7A9A6E")
const COLOR_SUCCESS_BORDER := Color("4CAF50")
const COLOR_TEXT := Color("F5F0E8")
const COLOR_TEXT_DIM := Color("C5BFB4")
const COLOR_TEXT_DISABLED := Color("C5BFB4")

@onready var _label: Label = %BtnLabel
@onready var _icon_label: Label = %BtnIcon

func _ready() -> void:
	custom_minimum_size = Vector2(56, 56)
	_apply_variant()
	if _label:
		_label.text = btn_label
	if _icon_label and not btn_icon_text.is_empty():
		_icon_label.text = btn_icon_text
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_hover)
	mouse_exited.connect(_on_unhover)

func _apply_variant() -> void:
	var sb := get_theme_stylebox("normal").duplicate() if get_theme_stylebox("normal") else StyleBoxFlat.new()
	if sb is StyleBoxFlat:
		match btn_variant:
			Variant.PRIMARY:
				sb.bg_color = COLOR_PRIMARY_BG
				sb.border_color = COLOR_PRIMARY_BORDER
				sb.border_width_left = 2; sb.border_width_right = 2
				sb.border_width_top = 2; sb.border_width_bottom = 2
				sb.corner_radius_top_left = 12; sb.corner_radius_top_right = 12
				sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
				add_theme_color_override("font_color", COLOR_TEXT)
				add_theme_font_size_override("font_size", 20)
			Variant.SECONDARY:
				sb.bg_color = COLOR_SECONDARY_BG
				sb.border_color = COLOR_SECONDARY_BORDER
				sb.border_width_left = 2; sb.border_width_right = 2
				sb.border_width_top = 2; sb.border_width_bottom = 2
				sb.corner_radius_top_left = 12; sb.corner_radius_top_right = 12
				sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
				add_theme_color_override("font_color", COLOR_TEXT)
				add_theme_font_size_override("font_size", 18)
			Variant.TERTIARY:
				sb.bg_color = COLOR_TERTIARY_BG
				sb.border_width_left = 0; sb.border_width_right = 0
				sb.border_width_top = 0; sb.border_width_bottom = 0
				add_theme_color_override("font_color", COLOR_TEXT_DIM)
				add_theme_font_size_override("font_size", 14)
			Variant.DANGER:
				sb.bg_color = COLOR_DANGER_BG
				sb.border_color = COLOR_DANGER_BORDER
				sb.border_width_left = 2; sb.border_width_right = 2
				sb.border_width_top = 2; sb.border_width_bottom = 2
				sb.corner_radius_top_left = 12; sb.corner_radius_top_right = 12
				sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
				add_theme_color_override("font_color", COLOR_TEXT)
				add_theme_font_size_override("font_size", 20)
			Variant.SUCCESS:
				sb.bg_color = COLOR_SUCCESS_BG
				sb.border_color = COLOR_SUCCESS_BORDER
				sb.border_width_left = 2; sb.border_width_right = 2
				sb.border_width_top = 2; sb.border_width_bottom = 2
				sb.corner_radius_top_left = 12; sb.corner_radius_top_right = 12
				sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
				add_theme_color_override("font_color", COLOR_TEXT)
				add_theme_font_size_override("font_size", 20)
			Variant.ICON:
				sb.bg_color = Color("2A2940")
				sb.border_color = Color("C5BFB4")
				sb.border_width_left = 1; sb.border_width_right = 1
				sb.border_width_top = 1; sb.border_width_bottom = 1
				sb.corner_radius_top_left = 8; sb.corner_radius_top_right = 8
				sb.corner_radius_bottom_left = 8; sb.corner_radius_bottom_right = 8
		add_theme_stylebox_override("normal", sb)

func _on_pressed() -> void:
	_animate_press()
	EventBus.emit("ui.button_pressed", {"button_name": name, "label": btn_label})

func _on_hover() -> void:
	if not disabled:
		modulate = Color(1.2, 1.2, 1.2, 1.0)

func _on_unhover() -> void:
	modulate = Color.WHITE

func _animate_press() -> void:
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2(0.95, 0.95), 0.1)
	tween.tween_property(self, "scale", Vector2.ONE, 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

func set_disabled(disabled_state: bool) -> void:
	disabled = disabled_state
	if disabled:
		modulate = Color(0.5, 0.5, 0.5, 0.5)
	else:
		modulate = Color.WHITE
