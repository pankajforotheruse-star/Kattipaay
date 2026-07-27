# SettingsScreen.gd — Settings screen per ui-ux-design.md §8
# Audio, controls, graphics, account, language sections.
# Reads/writes settings via SaveManager.
class_name SettingsScreen
extends Control

const SETTINGS_KEY := "settings"

@onready var _back_btn: Button = %BackButton
@onready var _title_label: Label = %TitleLabel

# Audio section
@onready var _master_slider: HSlider = %MasterSlider
@onready var _music_slider: HSlider = %MusicSlider
@onready var _sfx_slider: HSlider = %SFXSlider
@onready var _ui_sounds_slider: HSlider = %UISoundsSlider
@onready var _audio_reset_btn: Button = %AudioResetButton

# Controls section
@onready var _handed_toggle: ChalkToggle = %HandedToggle
@onready var _sensitivity_slider: HSlider = %SensitivitySlider
@onready var _dodge_slider: HSlider = %DodgeSlider
@onready var _double_tap_slider: HSlider = %DoubleTapSlider

# Graphics section
@onready var _quality_toggle: ChalkToggle = %QualityToggle
@onready var _fps_toggle: ChalkToggle = %FPSToggle
@onready var _shadows_toggle: ChalkToggle = %ShadowsToggle
@onready var _particles_toggle: ChalkToggle = %ParticlesToggle
@onready var _screen_shake_toggle: ChalkToggle = %ScreenShakeToggle

# Account section
@onready var _display_name_input: TextEdit = %DisplayNameInput
@onready var _player_id_label: Label = %PlayerIDLabel
@onready var _link_email_btn: Button = %LinkEmailButton
@onready var _copy_id_btn: Button = %CopyIDButton

# Language
@onready var _language_dropdown: OptionButton = %LanguageDropdown

# Bottom
@onready var _reset_defaults_btn: Button = %ResetDefaultsButton
@onready var _privacy_btn: Button = %PrivacyButton
@onready var _terms_btn: Button = %TermsButton
@onready var _version_label: Label = %VersionLabel

var _settings: Dictionary = {}

# Audio defaults
const DEFAULTS := {
	"master_volume": 85,
	"music_volume": 65,
	"sfx_volume": 100,
	"ui_volume": 90,
	"handedness": 0,  # 0=right, 1=left
	"sensitivity": 3,
	"dodge_swipe": 80,
	"double_tap_ms": 300,
	"quality": 0,  # 0=low, 1=medium
	"fps": 0,  # 0=30fps, 1=60fps
	"shadows": 1,  # 0=on, 1=off
	"particles": 0,  # 0=low, 1=high
	"screen_shake": 0,  # 0=on, 1=off
	"display_name": "GhostHunter",
	"language": 0,  # 0=English
}

func _ready() -> void:
	_load_settings()
	_connect_signals()
	_apply_settings()
	if _version_label:
		_version_label.text = "v1.0.0 (Build 42)"

func _connect_signals() -> void:
	if _back_btn: _back_btn.pressed.connect(_on_back)
	if _reset_defaults_btn: _reset_defaults_btn.pressed.connect(_on_reset_defaults)
	if _copy_id_btn: _copy_id_btn.pressed.connect(_on_copy_id)
	if _privacy_btn: _privacy_btn.pressed.connect(func(): EventBus.emit("ui.button_pressed", {"button": "privacy_policy"}))
	if _terms_btn: _terms_btn.pressed.connect(func(): EventBus.emit("ui.button_pressed", {"button": "terms_of_service"}))
	if _link_email_btn: _link_email_btn.pressed.connect(func(): EventBus.emit("ui.button_pressed", {"button": "link_email"}))

func _load_settings() -> void:
	_settings = SaveManager.load_local(SETTINGS_KEY, DEFAULTS.duplicate())

func _save_settings() -> void:
	SaveManager.save_local(SETTINGS_KEY, _settings)

func _apply_settings() -> void:
	if _master_slider: _master_slider.value = _settings.get("master_volume", 85)
	if _music_slider: _music_slider.value = _settings.get("music_volume", 65)
	if _sfx_slider: _sfx_slider.value = _settings.get("sfx_volume", 100)
	if _ui_sounds_slider: _ui_sounds_slider.value = _settings.get("ui_volume", 90)
	if _sensitivity_slider: _sensitivity_slider.value = _settings.get("sensitivity", 3)
	if _dodge_slider: _dodge_slider.value = _settings.get("dodge_swipe", 80)
	if _double_tap_slider: _double_tap_slider.value = _settings.get("double_tap_ms", 300)
	if _display_name_input: _display_name_input.text = _settings.get("display_name", "GhostHunter")
	if _player_id_label: _player_id_label.text = "#CH4LK-8F2A"
	if _handed_toggle: _handed_toggle.is_on = _settings.get("handedness", 0) == 0
	if _quality_toggle: _quality_toggle.is_on = _settings.get("quality", 0) == 0
	if _fps_toggle: _fps_toggle.is_on = _settings.get("fps", 0) == 0
	if _shadows_toggle: _shadows_toggle.is_on = _settings.get("shadows", 1) == 1
	if _particles_toggle: _particles_toggle.is_on = _settings.get("particles", 0) == 0
	if _screen_shake_toggle: _screen_shake_toggle.is_on = _settings.get("screen_shake", 0) == 0

func _on_back() -> void:
	_sync_from_ui()
	_save_settings()
	EventBus.emit("ui.button_pressed", {"button": "settings_back"})
	# Navigate back; SceneManager handles based on state
	GameState.transition(GameState.State.MAIN_MENU)

func _sync_from_ui() -> void:
	if _master_slider: _settings["master_volume"] = int(_master_slider.value)
	if _music_slider: _settings["music_volume"] = int(_music_slider.value)
	if _sfx_slider: _settings["sfx_volume"] = int(_sfx_slider.value)
	if _ui_sounds_slider: _settings["ui_volume"] = int(_ui_sounds_slider.value)
	if _sensitivity_slider: _settings["sensitivity"] = int(_sensitivity_slider.value)
	if _dodge_slider: _settings["dodge_swipe"] = int(_dodge_slider.value)
	if _double_tap_slider: _settings["double_tap_ms"] = int(_double_tap_slider.value)
	if _display_name_input: _settings["display_name"] = _display_name_input.text
	if _handed_toggle: _settings["handedness"] = 0 if _handed_toggle.is_on else 1
	if _quality_toggle: _settings["quality"] = 0 if _quality_toggle.is_on else 1
	if _fps_toggle: _settings["fps"] = 0 if _fps_toggle.is_on else 1
	if _shadows_toggle: _settings["shadows"] = 1 if _shadows_toggle.is_on else 0
	if _particles_toggle: _settings["particles"] = 0 if _particles_toggle.is_on else 1
	if _screen_shake_toggle: _settings["screen_shake"] = 0 if _screen_shake_toggle.is_on else 1

func _on_reset_defaults() -> void:
	_settings = DEFAULTS.duplicate()
	_apply_settings()
	_save_settings()
	EventBus.emit("ui.button_pressed", {"button": "settings_reset"})

func _on_copy_id() -> void:
	DisplayServer.clipboard_set("#CH4LK-8F2A")
	EventBus.emit("ui.toast", {"message": "Player ID copied!"})
