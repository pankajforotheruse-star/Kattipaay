# MatchmakingScreen.gd — Online player matching screen
# Per ui-ux-design.md §4. Night sky, spinning diya, search rings, player count, tip cards.
class_name MatchmakingScreen
extends Control

const COLOR_BG_TOP := Color("1A1030")
const COLOR_BG_BOTTOM := Color("0D0520")

@onready var _search_panel: Panel = %SearchPanel
@onready var _searching_label: Label = %SearchingLabel
@onready var _spinner: ColorRect = %SpinnerRect
@onready var _spinner_anim: AnimationPlayer = %SpinnerAnim
@onready var _player_count_label: Label = %PlayerCountLabel
@onready var _wait_time_label: Label = %WaitTimeLabel
@onready var _tip_card: Panel = %TipCard
@onready var _tip_label: Label = %TipLabel
@onready var _cancel_btn: Button = %CancelButton
@onready var _bots_btn: Button = %BotsButton
@onready var _search_rings: Control = %SearchRings

var _search_elapsed: float = 0.0
var _player_count: int = 1
var _max_players: int = 4
var _tips: Array[String] = [
	"Yellow chalk reveals hidden shades.",
	"Draw a full circle to seal ghosts.",
	"Lanterns light your way in the dark.",
	"Two fingers let you draw on the ground.",
	"Red chalk does bonus damage to shades.",
	"Group up — sealed circles are stronger together."
]
var _tip_index: int = 0
var _tip_timer: float = 0.0

func _ready() -> void:
	_connect_signals()
	_setup_initial_state()
	EventBus.on(EventBus.EV_NETWORK_MATCH_FOUND, _on_match_found)

func _connect_signals() -> void:
	if _cancel_btn: _cancel_btn.pressed.connect(_on_cancel)
	if _bots_btn: _bots_btn.pressed.connect(_on_start_with_bots)

func _setup_initial_state() -> void:
	if _searching_label:
		_searching_label.text = "SEARCHING"
	if _player_count_label:
		_update_player_count()
	if _wait_time_label:
		_wait_time_label.text = "Est. wait: calculating..."
	if _bots_btn:
		_bots_btn.visible = false
	if _tip_label:
		_tip_label.text = _tips[0]
	_randomize_tip()

func _process(delta: float) -> void:
	_search_elapsed += delta
	
	# Update wait time every 5s
	if int(_search_elapsed) % 5 == 0:
		_update_wait_time()
	
	# Show bots button after 30s
	if _search_elapsed >= 30.0 and _bots_btn and not _bots_btn.visible:
		_bots_btn.visible = true
		_bots_btn.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(_bots_btn, "modulate:a", 1.0, 0.3).set_ease(Tween.EASE_OUT)
	
	# Rotate tips every 8s
	_tip_timer += delta
	if _tip_timer >= 8.0:
		_cycle_tip()

func _update_player_count() -> void:
	if _player_count_label:
		_player_count_label.text = "Players found: %d/%d" % [_player_count, _max_players]

func _update_wait_time() -> void:
	if not _wait_time_label:
		return
	var seconds := int(_search_elapsed)
	var mins := seconds / 60
	var secs := seconds % 60
	_wait_time_label.text = "Est. wait: %s" % _format_time(seconds)

func _format_time(total_s: int) -> String:
	var mins := total_s / 60
	var secs := total_s % 60
	if mins > 0:
		return "%dm %ds" % [mins, secs]
	return "%ds" % secs

func _cycle_tip() -> void:
	_tip_timer = 0.0
	_tip_index = (_tip_index + 1) % _tips.size()
	if _tip_label:
		var tween := create_tween()
		tween.tween_property(_tip_label, "modulate:a", 0.0, 0.25)
		tween.tween_callback(func():
			_tip_label.text = _tips[_tip_index]
		)
		tween.tween_property(_tip_label, "modulate:a", 1.0, 0.25)

func _randomize_tip() -> void:
	_tip_index = randi() % _tips.size()
	if _tip_label:
		_tip_label.text = _tips[_tip_index]

func _on_cancel() -> void:
	EventBus.emit("ui.button_pressed", {"button": "cancel_matchmaking"})
	GameState.transition(GameState.State.MAIN_MENU)

func _on_start_with_bots() -> void:
	EventBus.emit("ui.button_pressed", {"button": "start_with_bots"})
	EventBus.emit(EventBus.EV_NETWORK_MATCH_FOUND, {"match_id": "bots", "players": 1})
	GameState.transition(GameState.State.PLAYING)

func _on_match_found(_payload: Dictionary) -> void:
	# Auto-transitioned by SceneManager based on GameState change
	pass

func set_player_count(count: int) -> void:
	_player_count = count
	_update_player_count()
