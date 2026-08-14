# LobbyScreen.gd — Pre-match gathering lobby
# Per ui-ux-design.md §3. Player slots, loadout, ready toggle, chat, host controls.
class_name LobbyScreen
extends Control

@onready var _back_btn: Button = %BackButton
@onready var _room_code_label: Label = %RoomCodeLabel
@onready var _map_name_label: Label = %MapNameLabel
@onready var _info_btn: Button = %InfoButton
@onready var _player_slots: Array[PlayerSlot] = []
@onready var _chat_panel: Control = %ChatPanel
@onready var _chat_input: TextEdit = %ChatInput
@onready var _chat_send_btn: Button = %ChatSendButton
@onready var _chat_messages: VBoxContainer = %ChatMessages
@onready var _ready_toggle_btn: Button = %ReadyToggleButton
@onready var _start_game_btn: Button = %StartGameButton
@onready var _copy_code_btn: Button = %CopyCodeButton
@onready var _share_btn: Button = %ShareButton
@onready var _leave_btn: Button = %LeaveButton
@onready var _host_controls: Control = %HostControls
@onready var _map_dropdown: OptionButton = %MapDropdown
@onready var _waves_dropdown: OptionButton = %WavesDropdown
@onready var _mode_label: Label = %ModeLabel
@onready var _chalk_selector: Control = %ChalkSelector
@onready var _item_dropdown: OptionButton = %ItemDropdown
@onready var _loadout_label: Label = %LoadoutLabel
@onready var _solo_notice_label: Label = %SoloNoticeLabel

var _is_ready: bool = false
var _is_host: bool = false
var _room_code: String = "CH4LK"

func _ready() -> void:
	_connect_signals()
	_setup_player_slots()
	_update_host_ui()

	if _room_code_label:
		_room_code_label.text = "Room: " + _room_code
	if _map_name_label:
		_map_name_label.text = "Map: Dholpur"
	if _mode_label:
		_mode_label.text = "Mode: Co-op"

	EventBus.on(EventBus.EV_NETWORK_PLAYER_JOINED, _on_player_joined)
	EventBus.on(EventBus.EV_NETWORK_PLAYER_LEFT, _on_player_left)
	EventBus.on(EventBus.EV_NETWORK_PLAYER_READY_CHANGED, _on_player_ready_changed)

func _connect_signals() -> void:
	if _back_btn: _back_btn.pressed.connect(_on_back)
	if _ready_toggle_btn: _ready_toggle_btn.pressed.connect(_on_toggle_ready)
	if _start_game_btn: _start_game_btn.pressed.connect(_on_start_game)
	if _leave_btn: _leave_btn.pressed.connect(_on_leave)
	if _copy_code_btn: _copy_code_btn.pressed.connect(_on_copy_code)
	if _share_btn: _share_btn.pressed.connect(_on_share)
	if _chat_send_btn: _chat_send_btn.pressed.connect(_on_send_chat)

func _setup_player_slots() -> void:
	# Find player slots by name pattern
	for i in range(1, 5):
		var slot := get_node_or_null("PlayerSlots/P%dSlot" % i) as PlayerSlot
		if slot:
			_player_slots.append(slot)
			slot.player_index = i
			slot.invite_pressed.connect(_on_invite_player)
			slot.edit_loadout_pressed.connect(_on_edit_loadout)

	# Default: P1 is host, filled
	if _player_slots.size() > 0:
		_player_slots[0].set_slot_data({
			"name": "You",
			"state": PlayerSlot.SlotState.WAITING,
			"host": true,
		})
		_is_host = true

func _update_host_ui() -> void:
	if _host_controls:
		_host_controls.visible = _is_host
	if _start_game_btn:
		_start_game_btn.visible = _is_host
		_start_game_btn.disabled = not _all_ready()

func _all_ready() -> bool:
	for slot in _player_slots:
		if slot.slot_state != PlayerSlot.SlotState.EMPTY and slot.slot_state != PlayerSlot.SlotState.READY:
			return false
	return true

func _on_back() -> void:
	GameState.transition(GameState.State.MAIN_MENU)

func _on_toggle_ready() -> void:
	_is_ready = not _is_ready
	if _ready_toggle_btn:
		_ready_toggle_btn.text = "✅ READY" if _is_ready else "✕ UNREADY"
		var color := Color("7A9A6E") if _is_ready else Color("E53935")
		_ready_toggle_btn.add_theme_color_override("font_color", color)
	# Audit M8: keep the local slot in sync so the host "Start Game" button
	# can enable (the legacy EV_NETWORK_PLAYER_READY_CHANGED never fires).
	if _player_slots.size() > 0:
		var slot_state := PlayerSlot.SlotState.READY if _is_ready else PlayerSlot.SlotState.WAITING
		_player_slots[0].set_slot_data({"name": "You", "state": slot_state, "host": true})
	_update_host_ui()
	EventBus.emit(EventBus.EV_NETWORK_PLAYER_READY, {"ready": _is_ready})

func _on_start_game() -> void:
	if not _all_ready():
		return
	EventBus.emit("ui.button_pressed", {"button": "start_game"})
	# Audit M8: the live loop does not run through the network layer yet -
	# gate the online/offline "Start Game" behind the validated solo-vs-CPU
	# loop so the player ALWAYS lands in a runnable round (never bare PLAYING
	# with no SoloMatchDriver). Honest notice + solo start; no fake online.
	if _solo_notice_label:
		_solo_notice_label.text = "ONLINE PLAY IS COMING SOON - starting a SOLO match (vs CPU) instead."
	GameState.solo_vs_cpu = true
	GameState.transition(GameState.State.PLAYING)

func _on_leave() -> void:
	GameState.transition(GameState.State.MAIN_MENU)

func _on_copy_code() -> void:
	DisplayServer.clipboard_set(_room_code)
	EventBus.emit("ui.toast", {"message": "Room code copied!"})

func _on_share() -> void:
	EventBus.emit("ui.button_pressed", {"button": "share_room"})

func _on_send_chat() -> void:
	if _chat_input and not _chat_input.text.strip_edges().is_empty():
		var msg := _chat_input.text.strip_edges()
		_add_chat_message("You", msg)
		_chat_input.text = ""
		EventBus.emit(EventBus.EV_NETWORK_CHAT_SEND, {"message": msg})

func _add_chat_message(sender: String, message: String) -> void:
	if not _chat_messages:
		return
	var label := Label.new()
	label.text = "%s: %s" % [sender, message]
	label.add_theme_font_size_override("font_size", 14)
	_chat_messages.add_child(label)

func _on_invite_player(index: int) -> void:
	EventBus.emit("ui.button_pressed", {"button": "invite_player", "slot": index})

func _on_edit_loadout(index: int) -> void:
	EventBus.emit("ui.button_pressed", {"button": "edit_loadout", "slot": index})

func _on_player_joined(payload: Dictionary) -> void:
	var idx := payload.get("slot", 1) - 1
	if idx < _player_slots.size():
		_player_slots[idx].set_slot_data({
			"name": payload.get("name", "Player"),
			"state": PlayerSlot.SlotState.WAITING,
			"host": false,
		})
	_update_host_ui()

func _on_player_left(payload: Dictionary) -> void:
	var idx := payload.get("slot", 1) - 1
	if idx < _player_slots.size():
		_player_slots[idx].set_slot_data({
			"name": "Player",
			"state": PlayerSlot.SlotState.EMPTY,
		})
	_update_host_ui()

func _on_player_ready_changed(payload: Dictionary) -> void:
	_update_host_ui()
