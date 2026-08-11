# RewardsScreen.gd — Post-match rewards flow per ui-ux-design.md §10
# XP bar, Chalk Dust counter, reward cards, Battle Pass progress, claim button.
class_name RewardsScreen
extends Control

@onready var _result_banner: Label = %ResultBanner
@onready var _xp_bar: ProgressBar = %XPBar
@onready var _xp_gained_label: Label = %XPGainedLabel
@onready var _xp_level_label: Label = %XPLevelLabel
@onready var _chalk_dust_label: Label = %ChalkDustLabel
@onready var _chalk_dust_prev: Label = %ChalkDustPrev
@onready var _reward_card_1: Panel = %RewardCard1
@onready var _reward_card_2: Panel = %RewardCard2
@onready var _reward_card_3: Panel = %RewardCard3
@onready var _bp_tier_label: Label = %BPTierLabel
@onready var _bp_bar: ProgressBar = %BPBar
@onready var _bp_next_reward: Label = %BPNextReward
@onready var _claim_btn: Button = %ClaimButton
@onready var _share_btn: Button = %ShareButton
@onready var _home_btn: Button = %HomeButton
@onready var _ad_btn: Button = %AdButton

var _result: Dictionary = {}
var _is_win: bool = true

func _ready() -> void:
	_connect_signals()

func _connect_signals() -> void:
	if _claim_btn: _claim_btn.pressed.connect(_on_claim)
	if _share_btn: _share_btn.pressed.connect(_on_share)
	if _home_btn: _home_btn.pressed.connect(_on_home)
	if _ad_btn: _ad_btn.pressed.connect(_on_watch_ad)

func show_rewards(result: Dictionary) -> void:
	_result = result
	_is_win = result.get("win", true)
	
	if _result_banner:
		_result_banner.text = "✨ VILLAGE SAVED! ✨" if _is_win else "THE VILLAGE FALLS..."
	
	if _xp_gained_label:
		_xp_gained_label.text = "+%d" % result.get("xp_gained", 0)
	_animate_xp_bar(result.get("xp_gained", 0), result.get("xp_total", 1000))
	
	if _chalk_dust_label:
		_chalk_dust_label.text = "+%d" % result.get("dust_gained", 0)
	if _chalk_dust_prev:
		_chalk_dust_prev.text = "(was %d)" % result.get("dust_prev", 0)
	
	_animate_enter()

func _animate_xp_bar(xp_gained: int, xp_total: int) -> void:
	if not _xp_bar:
		return
	var current_pct := _xp_bar.value
	var gained_pct := float(xp_gained) / float(xp_total) * 100.0
	var target_pct := current_pct + gained_pct
	
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_xp_bar, "value", target_pct, 1.5)
	
	if _xp_level_label:
		_xp_level_label.text = "Lvl %d" % (_result.get("level", 1))

func _animate_enter() -> void:
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.5).set_ease(Tween.EASE_OUT)

func _on_claim() -> void:
	EventBus.emit("ui.button_pressed", {"button": "claim_rewards"})
	EventBus.emit(EventBus.EV_GAME_REWARDS_CLAIMED, {})

func _on_share() -> void:
	EventBus.emit("ui.button_pressed", {"button": "share_result"})

func _on_home() -> void:
	GameState.transition(GameState.State.MAIN_MENU)

func _on_watch_ad() -> void:
	EventBus.emit("ui.button_pressed", {"button": "watch_ad"})
	if _chalk_dust_label:
		var current := _result.get("dust_gained", 0)
		_result["dust_gained"] = current * 2
		_chalk_dust_label.text = "+%d" % (current * 2)
	_animate_count_bounce(_chalk_dust_label)
	if _ad_btn:
		_ad_btn.visible = false

func _animate_count_bounce(label: Label) -> void:
	if not label:
		return
	var tween := create_tween()
	tween.tween_property(label, "scale", Vector2(1.3, 1.3), 0.2)
	tween.tween_property(label, "scale", Vector2.ONE, 0.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)
