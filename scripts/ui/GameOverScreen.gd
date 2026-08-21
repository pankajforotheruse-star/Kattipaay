# GameOverScreen.gd — Final post-match screen per ui-ux-design.md §11
# Result banner, final score, stats, Play Again/Change Loadout/Main Menu buttons.
class_name GameOverScreen
extends Control

@onready var _result_banner: Panel = %ResultBanner
@onready var _result_title: Label = %ResultTitle
@onready var _result_subtitle: Label = %ResultSubtitle
@onready var _final_score_label: Label = %FinalScoreLabel
@onready var _ghost_count_label: Label = %GhostCountLabel
@onready var _revive_count_label: Label = %ReviveCountLabel
@onready var _match_time_label: Label = %MatchTimeLabel

# Stats section
@onready var _chalk_used_bar: ProgressBar = %ChalkUsedBar
@onready var _chalk_used_value: Label = %ChalkUsedValue
@onready var _accuracy_bar: ProgressBar = %AccuracyBar
@onready var _accuracy_value: Label = %AccuracyValue
@onready var _damage_bar: ProgressBar = %DamageBar
@onready var _damage_value: Label = %DamageValue
@onready var _survival_bar: ProgressBar = %SurvivalBar
@onready var _survival_value: Label = %SurvivalValue
@onready var _combo_label: Label = %ComboLabel
@onready var _dodges_label: Label = %DodgesLabel

@onready var _ad_2x_btn: Button = %Ad2xButton
@onready var _play_again_btn: Button = %PlayAgainButton
@onready var _change_loadout_btn: Button = %ChangeLoadoutButton
@onready var _main_menu_btn: Button = %MainMenuButton
@onready var _share_btn: Button = %ShareResultButton
@onready var _breakdown_btn: Button = %BreakdownButton

var _match_result: Dictionary = {}
var _is_win: bool = true

func _ready() -> void:
	_connect_signals()

func _connect_signals() -> void:
	if _play_again_btn: _play_again_btn.pressed.connect(_on_play_again)
	if _change_loadout_btn: _change_loadout_btn.pressed.connect(_on_change_loadout)
	if _main_menu_btn: _main_menu_btn.pressed.connect(_on_main_menu)
	if _share_btn: _share_btn.pressed.connect(_on_share)
	if _breakdown_btn: _breakdown_btn.pressed.connect(_on_breakdown)
	if _ad_2x_btn: _ad_2x_btn.pressed.connect(_on_watch_ad)

func show_result(result: Dictionary) -> void:
	_match_result = result
	_is_win = result.get("win", true)
	
	if _result_title:
		_result_title.text = "RIFT SEALED!" if _is_win else "VILLAGE LOST..."
		_result_title.add_theme_color_override("font_color", Color("FFD700") if _is_win else Color("B71C1C"))
	if _result_subtitle:
		_result_subtitle.text = "Village is safe." if _is_win else "Try again..."
	
	if _final_score_label:
		_final_score_label.text = "FINAL SCORE: %d" % result.get("score", 0)
		_animate_count_label(_final_score_label, result.get("score", 0), "FINAL SCORE: ")
	
	if _ghost_count_label: _ghost_count_label.text = "👻 Banished: %d" % result.get("ghosts", 0)
	if _revive_count_label: _revive_count_label.text = "❤️ Revives: %d" % result.get("revives", 0)
	if _match_time_label: _match_time_label.text = "⏱ Match: %s" % result.get("time", "0:00")
	
	_animate_stat_bars(result)
	_animate_enter()

func _animate_stat_bars(result: Dictionary) -> void:
	var stats = result.get("stats", {})
	_animate_single_bar(_chalk_used_bar, _chalk_used_value, stats.get("chalk_pct", 0), "%")
	_animate_single_bar(_accuracy_bar, _accuracy_value, stats.get("accuracy", 0), "%")
	_animate_single_bar(_damage_bar, _damage_value, stats.get("damage_dealt", 0), "%")
	_animate_single_bar(_survival_bar, _survival_value, stats.get("survival", 0), "%")
	
	if _combo_label: _combo_label.text = "Combo max: %d×" % stats.get("combo_max", 0)
	if _dodges_label: _dodges_label.text = "Dodges: %d" % stats.get("dodges", 0)

func _animate_single_bar(bar: ProgressBar, value_label: Label, pct: float, suffix: String) -> void:
	if not bar:
		return
	bar.value = 0.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(bar, "value", pct, 0.8)
	if value_label:
		var current := 0.0
		tween.parallel().tween_method(
			func(v: float): value_label.text = "%d%s" % [int(v), suffix],
			current,
			pct,
			0.8
		)

func _animate_count_label(label: Label, final_value: int, prefix: String) -> void:
	var current := 0.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		func(v: float): label.text = "%s%d" % [prefix, int(v)],
		current,
		float(final_value),
		1.5
	)

func _animate_enter() -> void:
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.5).set_ease(Tween.EASE_OUT)

func _on_play_again() -> void:
	EventBus.emit("ui.button_pressed", {"button": "play_again"})
	GameState.transition(GameState.State.LOBBY)

func _on_change_loadout() -> void:
	EventBus.emit("ui.button_pressed", {"button": "change_loadout"})

func _on_main_menu() -> void:
	EventBus.emit("ui.button_pressed", {"button": "main_menu"})
	GameState.transition(GameState.State.MAIN_MENU)

func _on_share() -> void:
	EventBus.emit("ui.button_pressed", {"button": "share_result"})

func _on_breakdown() -> void:
	EventBus.emit("ui.button_pressed", {"button": "full_breakdown"})

func _on_watch_ad() -> void:
	EventBus.emit("ui.button_pressed", {"button": "watch_ad"})
	if _ad_2x_btn:
		_ad_2x_btn.visible = false
