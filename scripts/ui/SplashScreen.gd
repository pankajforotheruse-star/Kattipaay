# SplashScreen.gd — Splash / loading screen
# Studio logo fades in, title draws itself, then auto-advances to Home.
# Dark slate background (#1E1D2B). After 2.5s transitions to Home.
class_name SplashScreen
extends Control

const STUDIO_NAME := "REKHA GAMES"
const GAME_TITLE := "CHALK GAON: Ghost Lines"
const DISPLAY_DURATION := 2.5

@onready var _studio_label: Label = %StudioLabel
@onready var _title_label: Label = %TitleLabel
@onready var _loading_bar: ProgressBar = %LoadingBar
@onready var _anim_player: AnimationPlayer = %AnimationPlayer

func _ready() -> void:
	# Set initial state
	modulate = Color.WHITE
	_studio_label.modulate.a = 0.0
	_title_label.modulate.a = 0.0
	_studio_label.text = STUDIO_NAME
	_title_label.text = GAME_TITLE

	# Start the intro sequence
	_play_intro()

func _play_intro() -> void:
	var tween := create_tween()

	# Studio logo fade in (0.5s), hold (0.5s), fade out (0.3s)
	tween.tween_property(_studio_label, "modulate:a", 1.0, 0.5)
	tween.tween_interval(0.5)
	tween.tween_property(_studio_label, "modulate:a", 0.0, 0.3)

	# Title fade in with scale bounce (0.8s)
	tween.tween_callback(func():
		_title_label.modulate = Color.WHITE
		_title_label.modulate.a = 0.0
		_title_label.scale = Vector2(0.8, 0.8)
	)
	var t2 := create_tween()
	t2.tween_property(_title_label, "modulate:a", 1.0, 0.5)
	t2.parallel().tween_property(_title_label, "scale", Vector2.ONE, 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

	# Loading bar fills
	if _loading_bar:
		_loading_bar.value = 0.0
		var lt := create_tween()
		lt.tween_property(_loading_bar, "value", 1.0, DISPLAY_DURATION)

	# After total duration, transition
	await get_tree().create_timer(DISPLAY_DURATION).timeout
	_transition_to_home()

func _transition_to_home() -> void:
	# Fade out and transition
	EventBus.emit("game.splash_complete", {})
	GameState.transition(GameState.State.MAIN_MENU)
