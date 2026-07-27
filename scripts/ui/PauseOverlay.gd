# PauseOverlay.gd — In-game pause overlay
# Semi-transparent overlay with Resume/Settings/Quit buttons.
class_name PauseOverlay
extends Control

@onready var _overlay_bg: ColorRect = %OverlayBg
@onready var _paused_label: Label = %PausedLabel
@onready var _resume_btn: Button = %ResumeButton
@onready var _settings_btn: Button = %SettingsButton
@onready var _quit_btn: Button = %QuitButton

func _ready() -> void:
	_connect_signals()
	_animate_enter()

func _connect_signals() -> void:
	if _resume_btn: _resume_btn.pressed.connect(_on_resume)
	if _settings_btn: _settings_btn.pressed.connect(_on_settings)
	if _quit_btn: _quit_btn.pressed.connect(_on_quit)

func _animate_enter() -> void:
	if _overlay_bg:
		_overlay_bg.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(_overlay_bg, "modulate:a", 0.6, 0.3)
	
	if _paused_label:
		_paused_label.modulate.a = 0.0
		_paused_label.position.y -= 20
		var tween := create_tween()
		tween.tween_property(_paused_label, "modulate:a", 1.0, 0.25)
		tween.parallel().tween_property(_paused_label, "position:y", _paused_label.position.y + 20, 0.25).set_ease(Tween.EASE_OUT)

func _on_resume() -> void:
	EventBus.emit("ui.button_pressed", {"button": "resume"})
	GameState.transition(GameState.State.PLAYING)

func _on_settings() -> void:
	EventBus.emit("ui.button_pressed", {"button": "pause_settings"})

func _on_quit() -> void:
	EventBus.emit("ui.button_pressed", {"button": "pause_quit"})
	GameState.transition(GameState.State.MAIN_MENU)
