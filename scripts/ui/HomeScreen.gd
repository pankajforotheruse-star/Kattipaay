# HomeScreen.gd — Main hub screen after splash
# Per ui-ux-design.md §2. All button signals, character swipe, transitions.
# Village silhouette background, title panel, daily reward, play buttons.
class_name HomeScreen
extends Control

const COLOR_BG := Color("1E1D2B")

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

	EventBus.on("game.state_changed", _on_game_state_changed)
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

func _animate_title_entrance() -> void:
	if not _title_panel:
		return
	_title_panel.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_title_panel, "modulate:a", 1.0, 0.8).set_ease(Tween.EASE_OUT)

func _on_play_online() -> void:
	EventBus.emit("ui.button_pressed", {"button": "play_online"})
	GameState.transition(GameState.State.LOBBY)

func _on_offline_play() -> void:
	EventBus.emit("ui.button_pressed", {"button": "play_offline"})
	# For now, treat same as online for prototype
	GameState.transition(GameState.State.LOBBY)

func _on_settings() -> void:
	EventBus.emit("ui.button_pressed", {"button": "settings"})

func _on_shop() -> void:
	EventBus.emit("ui.button_pressed", {"button": "shop"})

func _on_battle_pass() -> void:
	EventBus.emit("ui.button_pressed", {"button": "battle_pass"})

func _on_collection() -> void:
	EventBus.emit("ui.button_pressed", {"button": "collection"})

func _on_daily_reward() -> void:
	EventBus.emit("ui.button_pressed", {"button": "daily_reward"})
	EventBus.emit("game.daily_reward_claimed", {})

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
	var btn := payload.get("button_name", "")
	print("HomeScreen: button event: %s" % btn)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		pass  # Character swipe handling
