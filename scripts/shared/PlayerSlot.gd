# PlayerSlot.gd — Player slot component for lobby and scoreboard
# Shows avatar, name, status, ready badge, host crown, action button.
class_name PlayerSlot
extends Panel

enum SlotState { EMPTY, WAITING, READY, DOWN }

@export var player_name: String = "Player"
@export var slot_state: SlotState = SlotState.EMPTY
@export var is_host: bool = false
@export var player_index: int = 0

const COLOR_BG := Color("2A2940")
const COLOR_EMPTY_BORDER := Color("C5BFB4")
const COLOR_READY := Color("7A9A6E")
const COLOR_WAITING := Color("D4A017")
const COLOR_DOWN := Color("E53935")
const COLOR_HOST := Color("FFD700")

@onready var _avatar: ColorRect = %Avatar
@onready var _name_label: Label = %NameLabel
@onready var _status_label: Label = %StatusLabel
@onready var _host_icon: Label = %HostIcon
@onready var _ready_badge: Label = %ReadyBadge
@onready var _action_button: Button = %ActionButton
@onready var _empty_overlay: Control = %EmptyOverlay

signal invite_pressed(player_index: int)
signal edit_loadout_pressed(player_index: int)

func _ready() -> void:
	_apply_state()
	if _action_button:
		_action_button.pressed.connect(_on_action_pressed)

func set_slot_data(data: Dictionary) -> void:
	player_name = data.get("name", "Player")
	slot_state = data.get("state", SlotState.EMPTY)
	is_host = data.get("host", false)
	_apply_state()

func _apply_state() -> void:
	match slot_state:
		SlotState.EMPTY:
			_show_empty()
		SlotState.WAITING:
			_show_occupied(false)
		SlotState.READY:
			_show_occupied(true)
		SlotState.DOWN:
			_show_down()

	if _name_label:
		_name_label.text = player_name
	if _host_icon:
		_host_icon.visible = is_host

func _show_empty() -> void:
	if _empty_overlay:
		_empty_overlay.visible = true
	if _status_label:
		_status_label.text = "Waiting..."
		_status_label.add_theme_color_override("font_color", COLOR_EMPTY_BORDER)
	if _ready_badge:
		_ready_badge.visible = false
	if _action_button:
		_action_button.text = "INVITE"
		_action_button.visible = true
	var sb := get_theme_stylebox("panel").duplicate() if get_theme_stylebox("panel") else StyleBoxFlat.new()
	if sb is StyleBoxFlat:
		sb.border_color = COLOR_EMPTY_BORDER
		# Dashed border effect via lowered alpha
		sb.border_width_left = 2; sb.border_width_right = 2
		sb.border_width_top = 2; sb.border_width_bottom = 2
	add_theme_stylebox_override("panel", sb)

func _show_occupied(ready: bool) -> void:
	if _empty_overlay:
		_empty_overlay.visible = false
	if _status_label:
		if ready:
			_status_label.text = "✅ READY"
			_status_label.add_theme_color_override("font_color", COLOR_READY)
		else:
			_status_label.text = "⏳ WAITING"
			_status_label.add_theme_color_override("font_color", COLOR_WAITING)
	if _ready_badge:
		_ready_badge.visible = ready
		_ready_badge.text = "✓"
		_ready_badge.add_theme_color_override("font_color", COLOR_READY)
	if _action_button:
		_action_button.text = "EDIT LOADOUT"
		_action_button.visible = true
	var sb := get_theme_stylebox("panel").duplicate() if get_theme_stylebox("panel") else StyleBoxFlat.new()
	if sb is StyleBoxFlat:
		sb.border_color = COLOR_READY if ready else COLOR_WAITING
		sb.border_width_left = 2; sb.border_width_right = 2
		sb.border_width_top = 2; sb.border_width_bottom = 2
	add_theme_stylebox_override("panel", sb)

func _show_down() -> void:
	if _empty_overlay:
		_empty_overlay.visible = false
	if _status_label:
		_status_label.text = "💀 DOWN"
		_status_label.add_theme_color_override("font_color", COLOR_DOWN)
	if _ready_badge:
		_ready_badge.visible = false
	if _action_button:
		_action_button.visible = false
	var sb := get_theme_stylebox("panel").duplicate() if get_theme_stylebox("panel") else StyleBoxFlat.new()
	if sb is StyleBoxFlat:
		sb.border_color = COLOR_DOWN
		sb.border_width_left = 2; sb.border_width_right = 2
		sb.border_width_top = 2; sb.border_width_bottom = 2
	add_theme_stylebox_override("panel", sb)

func _on_action_pressed() -> void:
	match slot_state:
		SlotState.EMPTY:
			invite_pressed.emit(player_index)
		_:
			edit_loadout_pressed.emit(player_index)
