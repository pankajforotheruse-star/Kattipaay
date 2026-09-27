# CoinDeciderOverlay.gd — MEETING-phase coin decider UI ("The Coin at the Alley")
#
# Shown by the SoloMatchDriver when the match enters MEETING (owned by the
# driver, freed when SEARCHING starts — same pattern as the argument overlay).
#
# Flow (meeting-phase-plan.md R5):
#   1. Player calls HEADS or TAILS (two big buttons).
#   2. The CPU automatically takes the opposite side — flash "CPU calls: [side]".
#   3. ~2s coin flip animation (tweened face swaps) + procedural clink sound.
#   4. Result announced big: "YOU STRIKE FIRST!" or
#      "CPU STRIKES FIRST — protect your lines!".
#   5. Emits EventBus.EV_GAME_COIN_DECIDED with the roles so the driver can
#      record active_searcher/defender and start SEARCHING.
#
# Timeout safety: `auto_randomize()` (driver call when the player does not
# call within ~8s) picks a random side for the player and runs the same flow.
# `force_resolve()` is the driver's absolute safety net — never hang the round.
#
# The coin itself is FAIR at every difficulty (owner decision #2): the toss is
# a plain randi() 50/50 — difficulty never influences who searches first.

class_name CoinDeciderOverlay
extends Control

const HUMAN_ENTITY_ID := 1
const GHOST_ENTITY_ID := 2

enum CoinSide { HEADS = 0, TAILS = 1 }
enum Phase { CALL, FLIP, RESULT }

## Coin flip animation length (owner spec: ~2s). Runtime value so the
## smoke test can shorten it (ProjectSettings "chalk_gaon/solo_meeting_flip_duration").
var _flip_duration: float = 2.0
const FLIP_CYCLES := 7

# ── State ─────────────────────────────────────────────────────────────────────

var phase: int = Phase.CALL
var player_side: int = CoinSide.HEADS
var cpu_side: int = CoinSide.TAILS
var human_first: bool = false
var _resolved: bool = false

# ── UI nodes (built in _ready) ────────────────────────────────────────────────

var _banner_label: Label = null
var _prompt_label: Label = null
var _coin_panel: Panel = null
var _coin_face: Label = null
var _heads_btn: Button = null
var _tails_btn: Button = null
var _status_label: Label = null
var _result_label: Label = null
var _hint_label: Label = null
var _flip_tween: Tween = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	randomize()
	_flip_duration = float(ProjectSettings.get_setting("chalk_gaon/solo_meeting_flip_duration", 2.0))
	_build_ui()
	_reset_to_call()

func _exit_tree() -> void:
	if _flip_tween and _flip_tween.is_valid():
		_flip_tween.kill()
	_flip_tween = null

# ── Public API (driver-facing) ────────────────────────────────────────────────

## Timeout safety: the player never called — pick a random side for the player
## and run the exact same flip flow (round never hangs).
func auto_randomize() -> void:
	if phase != Phase.CALL or _resolved:
		return
	var side := randi() % 2
	_start_flip(side, "Time's up — coin called: ")

## Absolute safety net: if the flip animation somehow never completes, cut
## straight to the result and emit the decision.
func force_resolve() -> void:
	if _resolved:
		return
	if _flip_tween and _flip_tween.is_valid():
		_flip_tween.kill()
	_land_coin()

# ── Flow ──────────────────────────────────────────────────────────────────────

func _on_side_button(side: int) -> void:
	if phase != Phase.CALL or _resolved:
		return
	_start_flip(side, "You call: ")

func _start_flip(side: int, prefix: String) -> void:
	if phase != Phase.CALL or _resolved:
		return
	player_side = side
	cpu_side = 1 - side
	phase = Phase.FLIP
	_heads_btn.disabled = true
	_tails_btn.disabled = true
	_status_label.text = prefix + _side_name(player_side) + "  ·  CPU calls: " + _side_name(cpu_side)
	_coin_panel.show()
	AudioManager.play_coin_flip()
	_run_flip_animation()

func _run_flip_animation() -> void:
	if _flip_tween and _flip_tween.is_valid():
		_flip_tween.kill()
	_flip_tween = create_tween()
	var half := _flip_duration / (FLIP_CYCLES * 2.0)
	for i in range(FLIP_CYCLES * 2):
		_flip_tween.tween_property(_coin_panel, "scale:x", 0.05, half) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_flip_tween.tween_callback(_swap_coin_face)
		_flip_tween.tween_property(_coin_panel, "scale:x", 1.0, half) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# Landing squash for weight, then resolve (total ~2.2s - owner spec ~2s).
	_flip_tween.tween_property(_coin_panel, "scale:x", 0.05, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_flip_tween.tween_property(_coin_panel, "scale:x", 1.0, 0.1).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_flip_tween.tween_callback(_land_coin)

func _swap_coin_face() -> void:
	if _coin_face:
		_coin_face.text = "H" if randi() % 2 == 0 else "T"

## Coin lands: clink + resolve the toss against the player's call.
func _land_coin() -> void:
	if _resolved:
		return
	phase = Phase.RESULT
	_resolved = true
	AudioManager.play_coin_clink()

	var toss := randi() % 2
	human_first = (toss == player_side)
	if _coin_face:
		_coin_face.text = _side_name(toss).left(1)

	var searcher := HUMAN_ENTITY_ID if human_first else GHOST_ENTITY_ID
	var pdef := GHOST_ENTITY_ID if human_first else HUMAN_ENTITY_ID

	if human_first:
		_result_label.text = "YOU STRIKE FIRST!"
		_result_label.add_theme_color_override("font_color", Color(0.5, 0.95, 0.55, 1.0))
	else:
		_result_label.text = "CPU STRIKES FIRST —\nprotect your lines!"
		_result_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35, 1.0))
	_result_label.show()

	AudioManager.play_argument_result(human_first)

	EventBus.emit(EventBus.EV_GAME_COIN_DECIDED, {
		"active_searcher": searcher,
		"defender": pdef,
		"human_first": human_first,
		"cpu_first": not human_first,
		"player_side": player_side,
		"cpu_side": cpu_side,
	})

# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Dim backdrop (blocks stray taps; world input is also locked in
	# InputManager during MEETING).
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.08, 0.72)
	add_child(dim)

	_banner_label = _make_label("⏳ Time's up — meet at the alley.", 34, Color(1.0, 0.92, 0.7, 1.0))
	_banner_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner_label.offset_top = 70
	_banner_label.offset_left = -380
	_banner_label.offset_right = 380
	_banner_label.offset_bottom = 110
	add_child(_banner_label)

	_prompt_label = _make_label("Call it: HEADS or TAILS?", 26, Color(0.9, 0.9, 0.95, 1.0))
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_label.offset_left = -260
	_prompt_label.offset_top = -170
	_prompt_label.offset_right = 260
	_prompt_label.offset_bottom = -140
	add_child(_prompt_label)

	_coin_panel = Panel.new()
	_coin_panel.name = "Coin"
	_coin_panel.custom_minimum_size = Vector2(104, 104)
	var coin_style := StyleBoxFlat.new()
	coin_style.bg_color = Color(0.9, 0.76, 0.34, 1.0)
	coin_style.set_corner_radius_all(52)
	coin_style.border_color = Color(0.75, 0.55, 0.15, 1.0)
	coin_style.set_border_width_all(3)
	_coin_panel.add_theme_stylebox_override("panel", coin_style)
	_coin_panel.set_anchors_preset(Control.PRESET_CENTER)
	_coin_panel.offset_left = -52
	_coin_panel.offset_top = -108
	_coin_panel.offset_right = 52
	_coin_panel.offset_bottom = -4
	_coin_panel.hide()
	add_child(_coin_panel)

	_coin_face = Label.new()
	_coin_face.text = "?"
	_coin_face.set_anchors_preset(Control.PRESET_FULL_RECT)
	_coin_face.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coin_face.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_coin_face.add_theme_font_size_override("font_size", 52)
	_coin_face.add_theme_color_override("font_color", Color(0.45, 0.3, 0.05, 1.0))
	_coin_panel.add_child(_coin_face)

	var btn_row := HBoxContainer.new()
	btn_row.name = "CoinButtons"
	btn_row.set_anchors_preset(Control.PRESET_CENTER)
	btn_row.offset_left = -220
	btn_row.offset_top = 40
	btn_row.offset_right = 220
	btn_row.offset_bottom = 108
	btn_row.add_theme_constant_override("separation", 24)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(btn_row)

	_heads_btn = _make_side_button("HEADS", Color(0.25, 0.55, 0.9, 0.95), CoinSide.HEADS)
	_tails_btn = _make_side_button("TAILS", Color(0.85, 0.45, 0.3, 0.95), CoinSide.TAILS)
	btn_row.add_child(_heads_btn)
	btn_row.add_child(_tails_btn)

	_status_label = _make_label("", 22, Color(0.85, 0.85, 0.9, 1.0))
	_status_label.set_anchors_preset(Control.PRESET_CENTER)
	_status_label.offset_left = -400
	_status_label.offset_top = 130
	_status_label.offset_right = 400
	_status_label.offset_bottom = 160
	add_child(_status_label)

	_result_label = _make_label("", 40, Color(1.0, 1.0, 1.0, 1.0))
	_result_label.set_anchors_preset(Control.PRESET_CENTER)
	_result_label.offset_left = -420
	_result_label.offset_top = -40
	_result_label.offset_right = 420
	_result_label.offset_bottom = 10
	_result_label.hide()
	add_child(_result_label)

	_hint_label = _make_label("Call within 8 seconds, or the coin flips on its own.", 16, Color(1.0, 1.0, 1.0, 0.45))
	_hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint_label.offset_left = -360
	_hint_label.offset_top = -60
	_hint_label.offset_right = 360
	_hint_label.offset_bottom = -30
	add_child(_hint_label)

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _make_side_button(text: String, bg: Color, side: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(200, 64)
	btn.add_theme_font_size_override("font_size", 24)
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(14)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 1.0, 1.0, 0.35)
	btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = bg.lightened(0.12)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.darkened(0.15)
	btn.add_theme_stylebox_override("pressed", pressed)
	var disabled := style.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.25, 0.25, 0.3, 0.5)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.6, 0.6, 0.6, 0.6))
	btn.pressed.connect(_on_side_button.bind(side))
	return btn

func _reset_to_call() -> void:
	phase = Phase.CALL
	_resolved = false
	_heads_btn.disabled = false
	_tails_btn.disabled = false
	_coin_panel.hide()
	_result_label.hide()
	_status_label.text = "Who searches first? The coin decides."
	_prompt_label.show()
	_hint_label.show()

func _side_name(side: int) -> String:
	return "HEADS" if side == CoinSide.HEADS else "TAILS"
