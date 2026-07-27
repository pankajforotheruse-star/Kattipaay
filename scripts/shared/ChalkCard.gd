# ChalkCard.gd — Rounded panel with chalk border
# Optional title and content area. Used for player slots, reward cards, etc.
class_name ChalkCard
extends Panel

@export var card_title: String = ""
@export var show_border: bool = true
@export var is_highlighted: bool = false:
	set(v):
		is_highlighted = v
		_update_highlight()

const COLOR_BG := Color("2A2940")
const COLOR_BORDER := Color("C5BFB4")
const COLOR_HIGHLIGHT := Color("FFD700")

@onready var _title_label: Label = %CardTitle
@onready var _content: Control = %CardContent

func _ready() -> void:
	_apply_style()
	if _title_label:
		_title_label.text = card_title
		_title_label.visible = not card_title.is_empty()

func _apply_style() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_BG
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	if show_border:
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_color = COLOR_BORDER
	add_theme_stylebox_override("panel", sb)

func _update_highlight() -> void:
	var sb := get_theme_stylebox("panel").duplicate()
	if sb is StyleBoxFlat:
		sb.border_color = COLOR_HIGHLIGHT if is_highlighted else COLOR_BORDER
		sb.border_width_left = 3 if is_highlighted else 1
		sb.border_width_right = 3 if is_highlighted else 1
		sb.border_width_top = 3 if is_highlighted else 1
		sb.border_width_bottom = 3 if is_highlighted else 1
		add_theme_stylebox_override("panel", sb)
