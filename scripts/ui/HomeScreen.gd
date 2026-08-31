# HomeScreen.gd — Main hub screen after splash
# Per ui-ux-design.md §2. All button signals, character swipe, transitions.
# Village silhouette background, title panel, daily reward, play buttons.
class_name HomeScreen
extends Control

const COLOR_BG := Color("1E1D2B")

const POPUP_SCENE: PackedScene = preload("res://scenes/shared/popup_dialog.tscn")

@onready var _play_online_btn: Button = %PlayOnlineButton
@onready var _offline_play_btn: Button = %OfflinePlayButton
@onready var _settings_btn: Button = %SettingsButton
@onready var _shop_btn: Button = %ShopButton
@onready var _battle_pass_btn: Button = %BattlePassButton
@onready var _collection_btn: Button = %CollectionButton
@onready var _daily_reward_btn: Button = %DailyRewardButton
@onready var _character_preview: Control = %CharacterPreview
@onready var _xp_bar: ProgressBar = %XPBar
@onready var _xp_label: Label = %XPLabel
@onready var _nav_dots: HBoxContainer = %NavDots
@onready var _tutorial_btn: Button = %TutorialButton
@onready var _play_vs_cpu_btn: Button = %PlayVsCPUButton
@onready var _version_label: Label = %VersionLabel
@onready var _sky_gradient: ColorRect = %SkyGradient
@onready var _village_silhouette: Node2D = %VillageSilhouette
@onready var _title_panel: Panel = %TitlePanel

var _current_character_index: int = 0
var _swipe_start: Vector2 = Vector2.ZERO

func _ready() -> void:
	_setup_background()
	_connect_signals()
	_update_xp_display()
	if _version_label:
		_version_label.text = "v1.0.0"

	# Animate title entrance
	_animate_title_entrance()

	EventBus.on(EventBus.EV_GAME_STATE_CHANGED, _on_game_state_changed)
	EventBus.on("ui.button_pressed", _on_button_event)

func _setup_background() -> void:
	if _sky_gradient:
		var mat := ShaderMaterial.new()
		# Simple gradient shader placeholder: handled by ColorRect gradient
		pass

func _connect_signals() -> void:
	if _play_online_btn:
		_play_online_btn.pressed.connect(_on_play_online)
	if _offline_play_btn:
		_offline_play_btn.pressed.connect(_on_offline_play)
	if _settings_btn:
		_settings_btn.pressed.connect(_on_settings)
	if _shop_btn:
		_shop_btn.pressed.connect(_on_shop)
	if _battle_pass_btn:
		_battle_pass_btn.pressed.connect(_on_battle_pass)
	if _collection_btn:
		_collection_btn.pressed.connect(_on_collection)
	if _daily_reward_btn:
		_daily_reward_btn.pressed.connect(_on_daily_reward)
	if _tutorial_btn:
		_tutorial_btn.pressed.connect(_on_tutorial)
	if _play_vs_cpu_btn:
		_play_vs_cpu_btn.pressed.connect(_on_play_vs_cpu)

func _animate_title_entrance() -> void:
	if not _title_panel:
		return
	_title_panel.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_title_panel, "modulate:a", 1.0, 0.8).set_ease(Tween.EASE_OUT)

func _on_play_online() -> void:
	EventBus.emit("ui.button_pressed", {"button": "play_online"})
	GameState.solo_vs_cpu = false  # normal online play never inherits solo mode
	GameState.transition(GameState.State.LOBBY)

func _on_offline_play() -> void:
	EventBus.emit("ui.button_pressed", {"button": "play_offline"})
	# For now, treat same as online for prototype
	GameState.solo_vs_cpu = false  # lobby play is not the solo loop
	GameState.transition(GameState.State.LOBBY)

func _on_settings() -> void:
	EventBus.emit("ui.button_pressed", {"button": "settings"})
	_show_coming_soon("Settings", "Settings are coming soon.")

func _on_shop() -> void:
	EventBus.emit("ui.button_pressed", {"button": "shop"})
	_show_coming_soon("Shop", "The village shop is coming soon.")

func _on_battle_pass() -> void:
	EventBus.emit("ui.button_pressed", {"button": "battle_pass"})
	_show_coming_soon("Battle Pass", "The battle pass is coming soon.")

func _on_collection() -> void:
	EventBus.emit("ui.button_pressed", {"button": "collection"})
	_show_coming_soon("Collection", "Your collection is coming soon.")

func _on_daily_reward() -> void:
	EventBus.emit("ui.button_pressed", {"button": "daily_reward"})
	_show_coming_soon("Daily Reward", "Claim your daily reward!")

func _show_coming_soon(title: String, body: String) -> void:
	if not POPUP_SCENE:
		return
	var popup: PopupDialog = POPUP_SCENE.instantiate()
	popup.dialog_title = title
	popup.body_text = body
	popup.button_mode = PopupDialog.ButtonMode.OK_ONLY
	popup.confirm_label = "OK"
	popup.dismiss_on_backdrop = true
	add_child(popup)
func _on_tutorial() -> void:
	EventBus.emit("ui.button_pressed", {"button": "tutorial"})
	SceneManager.go_to("tutorial/tutorial.tscn")
func _update_xp_display() -> void:
	if _xp_bar and _xp_label:
		var level := 14
		var xp := 2340
		var xp_max := 5000
		_xp_bar.value = float(xp) / float(xp_max) * 100.0
		_xp_label.text = "Lvl %d %s/%s" % [level, str(xp), str(xp_max)]

func _on_game_state_changed(payload: Dictionary) -> void:
	pass  # HomeScreen doesn't auto-advance; SceneManager handles it

func _on_button_event(payload: Dictionary) -> void:
	var btn = payload.get("button", "")
	print("HomeScreen: button event: %s" % btn)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		pass  # Character swipe handling

# ── Solo "Play vs CPU" ─────────────────────────────────────────────────────

## Difficulty picker panel for solo play (code-built, minimal).
var _difficulty_picker: Control = null

const SOLO_DIFFICULTY_LABELS: Array[String] = ["EASY", "NORMAL", "HARD", "NIGHTMARE"]

func _on_play_vs_cpu() -> void:
	# Toggle: pressing again while open closes the picker.
	if _difficulty_picker and is_instance_valid(_difficulty_picker):
		_close_difficulty_picker()
		return
	_build_difficulty_picker()

func _build_difficulty_picker() -> void:
	var panel := PanelContainer.new()
	panel.name = "DifficultyPicker"
	panel.anchors_preset = Control.PRESET_CENTER
	panel.custom_minimum_size = Vector2(340, 360)
	panel.add_theme_stylebox_override("panel", _picker_style())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title := Label.new()
	title.text = "Play vs CPU - pick difficulty"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	for i in range(SOLO_DIFFICULTY_LABELS.size()):
		var btn := Button.new()
		btn.text = SOLO_DIFFICULTY_LABELS[i]
		btn.custom_minimum_size = Vector2(0, 48)
		btn.pressed.connect(_start_solo_with_difficulty.bind(i))
		box.add_child(btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(0, 40)
	cancel.pressed.connect(_close_difficulty_picker)
	box.add_child(cancel)

	add_child(panel)
	_difficulty_picker = panel

func _picker_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.11, 0.17, 0.97)
	style.border_color = Color(0.55, 0.45, 0.75, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	return style

func _close_difficulty_picker() -> void:
	if _difficulty_picker and is_instance_valid(_difficulty_picker):
		_difficulty_picker.queue_free()
	_difficulty_picker = null

func _start_solo_with_difficulty(difficulty: int) -> void:
	_close_difficulty_picker()
	GameState.solo_vs_cpu = true
	GameState.cpu_difficulty = difficulty
	# Smallest safe path into the game world: GameState now allows
	# MAIN_MENU -> PLAYING (prototype bootstrap precedent), so SceneManager
	# routes straight to game_world.tscn with the solo flag set.
	GameState.transition(GameState.State.PLAYING)
