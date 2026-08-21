# ScoreboardScreen.gd — Post-wave scoreboard per ui-ux-design.md §7
# Shows rankings, wave stats, score breakdown, countdown to next wave.
class_name ScoreboardScreen
extends Control

@onready var _header_label: Label = %HeaderLabel
@onready var _top_player_card: Panel = %TopPlayerCard
@onready var _top_avatar: ColorRect = %TopAvatar
@onready var _top_name_label: Label = %TopNameLabel
@onready var _top_score_label: Label = %TopScoreLabel
@onready var _top_ghosts_label: Label = %TopGhostsLabel
@onready var _top_revives_label: Label = %TopRevivesLabel
@onready var _top_mvp_badge: Label = %MVPBadge

# Player 2-4 rows
@onready var _p2_card: Panel = %P2Card
@onready var _p2_name: Label = %P2Name
@onready var _p2_score: Label = %P2Score
@onready var _p3_card: Panel = %P3Card
@onready var _p3_name: Label = %P3Name
@onready var _p3_score: Label = %P3Score
@onready var _p4_card: Panel = %P4Card
@onready var _p4_name: Label = %P4Name
@onready var _p4_score: Label = %P4Score

@onready var _team_total_label: Label = %TeamTotalLabel
@onready var _wave_time_label: Label = %WaveTimeLabel
@onready var _chalk_used_label: Label = %ChalkUsedLabel
@onready var _downs_label: Label = %DownsLabel
@onready var _circles_label: Label = %CirclesLabel

@onready var _score_breakdown: Control = %ScoreBreakdown
@onready var _countdown_label: Label = %CountdownLabel
@onready var _countdown_bar: ProgressBar = %CountdownBar
@onready var _skip_btn: Button = %SkipButton
@onready var _tip_label: Label = %TipLabel

var _countdown_seconds: float = 30.0
var _is_counting: bool = false

func _ready() -> void:
	_connect_signals()
	reset_scoreboard()

func _connect_signals() -> void:
	if _skip_btn:
		_skip_btn.pressed.connect(_on_skip)

func reset_scoreboard() -> void:
	_countdown_seconds = 30.0
	_is_counting = false
	if _countdown_bar:
		_countdown_bar.value = 0.0
	if _countdown_label:
		_countdown_label.text = "NEXT WAVE IN 0:30"

func show_wave_result(wave_number: int) -> void:
	if _header_label:
		_header_label.text = "WAVE %d COMPLETE!" % wave_number
	_animate_scoreboard_enter()

func set_player_data(rankings: Array) -> void:
	for i in range(min(rankings.size(), 4)):
		var data: Dictionary = rankings[i]
		match i:
			0: _set_top_player(data)
			1: _set_player_row(_p2_name, _p2_score, data, 2)
			2: _set_player_row(_p3_name, _p3_score, data, 3)
			3: _set_player_row(_p4_name, _p4_score, data, 4)

func _set_top_player(data: Dictionary) -> void:
	if _top_name_label: _top_name_label.text = data.get("name", "Player")
	if _top_score_label: _animate_count_label(_top_score_label, data.get("score", 0), " pts")
	if _top_ghosts_label: _top_ghosts_label.text = "👻 %d banished" % data.get("ghosts", 0)
	if _top_revives_label: _top_revives_label.text = "❤️ %d revives" % data.get("revives", 0)
	if _top_mvp_badge: _top_mvp_badge.visible = data.get("mvp", false)

func _set_player_row(name_label: Label, score_label: Label, data: Dictionary, rank: int) -> void:
	if name_label: name_label.text = data.get("name", "Player %d" % rank)
	if score_label: score_label.text = "%d pts" % data.get("score", 0)

func set_team_total(total: int, ghosts: int) -> void:
	if _team_total_label:
		_team_total_label.text = "TEAM TOTAL: %d pts  |  👻 %d banished" % [total, ghosts]

func set_wave_stats(stats: Dictionary) -> void:
	if _wave_time_label: _wave_time_label.text = "⏱ %s" % stats.get("time", "0:00")
	if _chalk_used_label: _chalk_used_label.text = "🖍️ Chalk: %d%%" % stats.get("chalk_pct", 0)
	if _downs_label: _downs_label.text = "💀 Downs: %d" % stats.get("downs", 0)
	if _circles_label: _circles_label.text = "⭕ Circles: %d" % stats.get("circles", 0)

func start_countdown(seconds: float = 30.0) -> void:
	_countdown_seconds = seconds
	_is_counting = true
	if _countdown_bar:
		_countdown_bar.max_value = seconds
		_countdown_bar.value = 0.0

func _process(delta: float) -> void:
	if not _is_counting:
		return
	_countdown_seconds -= delta
	if _countdown_bar:
		_countdown_bar.value = _countdown_bar.max_value - _countdown_seconds
	if _countdown_label:
		var remaining = max(0, int(ceil(_countdown_seconds)))
		var mins = remaining / 60
		var secs = remaining % 60
		_countdown_label.text = "NEXT WAVE IN %01d:%02d" % [mins, secs]
		
		if remaining <= 10:
			_countdown_label.add_theme_color_override("font_color", Color("E53935"))
	
	if _countdown_seconds <= 0.0:
		_is_counting = false
		_on_countdown_complete()

func _on_countdown_complete() -> void:
	EventBus.emit(EventBus.EV_GAME_WAVE_ADVANCE, {})

func _on_skip() -> void:
	_is_counting = false
	EventBus.emit(EventBus.EV_GAME_WAVE_ADVANCE, {"skipped": true})

func _animate_count_label(label: Label, final_value: int, suffix: String) -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var current := 0.0
	tween.tween_method(
		func(v: float):
			label.text = "%d%s" % [int(v), suffix],
		current,
		float(final_value),
		1.0
	)

func _animate_scoreboard_enter() -> void:
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.4).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		EventBus.emit("ui.scoreboard_shown", {})
	)
