# ArgumentOverlay.gd — Full-screen argument/accusation overlay for CHALK GAON
#
# CanvasLayer that sits above the HUD during the 3-second argument pause.
# Shows accusation text with typewriter animation, player portraits,
# dramatic transitions, and result flash.
#
# Timeline:
#   0.0s: overlay fades in (0.3s)
#   0.3s: portraits slide in from left/right (0.4s, ease-out)
#   0.7s: accusation text typewriter begins (50ms per character)
#   2.5s: tension hold (subtle camera shake)
#   3.0s: result flash — green (TRUE) or red (FALSE) + penalty text
#   3.5s: overlay fades out (0.3s)

class_name ArgumentOverlay
extends CanvasLayer

# ── Constants ─────────────────────────────────────────────────────────────────

const TYPEWRITER_SPEED := 0.05  # seconds per character
const OVERLAY_ALPHA := 0.7
const PORTRAIT_RADIUS := 48.0
const PORTRAIT_SLIDE_DISTANCE := 120.0

# ── Nodes ─────────────────────────────────────────────────────────────────────

var _background: ColorRect = null
var _vignette: ColorRect = null
var _accusation_label: Label = null
var _accusation_rich: RichTextLabel = null
var _portrait_left: Control = null
var _portrait_right: Control = null
var _portrait_left_label: Label = null
var _portrait_right_label: Label = null
var _result_flash: ColorRect = null
var _penalty_label: Label = null
var _animation_player: AnimationPlayer = null

# ── State ─────────────────────────────────────────────────────────────────────

var _full_text: String = ""
var _typewriter_index: int = 0
var _typewriter_timer: float = 0.0
var _is_showing: bool = false
var _argument_data: Dictionary = {}
var _result_data: Dictionary = {}

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10  # Above HUD
	_setup_ui()
	hide()

func _process(delta: float) -> void:
	if not _is_showing or _typewriter_index >= _full_text.length():
		return

	_typewriter_timer += delta
	while _typewriter_timer >= TYPEWRITER_SPEED and _typewriter_index < _full_text.length():
		_typewriter_timer -= TYPEWRITER_SPEED
		_typewriter_index += 1
		if _accusation_rich:
			_accusation_rich.text = _full_text.substr(0, _typewriter_index)

# ── Setup ─────────────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	# --- Background ---
	_background = ColorRect.new()
	_background.name = "Background"
	_background.color = Color(0.05, 0.03, 0.08, OVERLAY_ALPHA)  # Dark purple
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)

	# --- Vignette ---
	_vignette = ColorRect.new()
	_vignette.name = "Vignette"
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Vignette drawn with a shader or just darkened edges via modulate
	_vignette.color = Color(0.0, 0.0, 0.0, 0.3)
	add_child(_vignette)

	# --- Accusation Text (RichTextLabel for styling) ---
	_accusation_rich = RichTextLabel.new()
	_accusation_rich.name = "AccusationText"
	_accusation_rich.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_accusation_rich.set_anchor_and_offset(SIDE_TOP, 0.5, -100)
	_accusation_rich.set_anchor_and_offset(SIDE_BOTTOM, 0.5, 100)
	_accusation_rich.set_anchor_and_offset(SIDE_LEFT, 0.5, -300)
	_accusation_rich.set_anchor_and_offset(SIDE_RIGHT, 0.5, 300)
	_accusation_rich.bbcode_enabled = true
	_accusation_rich.fit_content = true
	_accusation_rich.scroll_active = false
	_accusation_rich.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_accusation_rich.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_accusation_rich)

	# --- Left Portrait Container ---
	_portrait_left = Control.new()
	_portrait_left.name = "PortraitLeft"
	_portrait_left.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_portrait_left.position = Vector2(-200, 120)
	_portrait_left.size = Vector2(PORTRAIT_RADIUS * 2 + 20, PORTRAIT_RADIUS * 2 + 60)
	add_child(_portrait_left)

	_portrait_left_label = Label.new()
	_portrait_left_label.name = "PortraitLeftLabel"
	_portrait_left_label.text = "ACCUSER"
	_portrait_left_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait_left_label.add_theme_font_size_override("font_size", 14)
	_portrait_left_label.add_theme_color_override("font_color", Color(0.4, 0.6, 1.0, 1.0))  # Blue tint
	_portrait_left_label.size = Vector2(160, 30)
	_portrait_left_label.position = Vector2(-20, PORTRAIT_RADIUS * 2 + 10)
	_portrait_left.add_child(_portrait_left_label)

	# --- Right Portrait Container ---
	_portrait_right = Control.new()
	_portrait_right.name = "PortraitRight"
	_portrait_right.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_portrait_right.position = Vector2(40, 120)
	_portrait_right.size = Vector2(PORTRAIT_RADIUS * 2 + 20, PORTRAIT_RADIUS * 2 + 60)
	add_child(_portrait_right)

	_portrait_right_label = Label.new()
	_portrait_right_label.name = "PortraitRightLabel"
	_portrait_right_label.text = "ACCUSED"
	_portrait_right_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait_right_label.add_theme_font_size_override("font_size", 14)
	_portrait_right_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))  # Red tint
	_portrait_right_label.size = Vector2(160, 30)
	_portrait_right_label.position = Vector2(-20, PORTRAIT_RADIUS * 2 + 10)
	_portrait_right.add_child(_portrait_right_label)

	# --- Result Flash ---
	_result_flash = ColorRect.new()
	_result_flash.name = "ResultFlash"
	_result_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_flash.modulate.a = 0.0
	_result_flash.visible = false
	add_child(_result_flash)

	# --- Penalty Label ---
	_penalty_label = Label.new()
	_penalty_label.name = "PenaltyLabel"
	_penalty_label.text = "-30s"
	_penalty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_penalty_label.add_theme_font_size_override("font_size", 64)
	_penalty_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2, 1.0))
	_penalty_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_penalty_label.position = Vector2(-100, -40)
	_penalty_label.size = Vector2(200, 80)
	_penalty_label.modulate.a = 0.0
	_penalty_label.scale = Vector2(0.5, 0.5)
	_penalty_label.visible = false
	add_child(_penalty_label)

# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	if not _is_showing:
		return

	var center := get_viewport().get_visible_rect().size / 2.0

	# Draw left portrait circle (accuser — blue tint)
	var left_center := center + Vector2(-200, 120)
	draw_circle(left_center, PORTRAIT_RADIUS, Color(0.12, 0.2, 0.35, 0.9))  # Dark blue fill
	draw_arc(left_center, PORTRAIT_RADIUS, 0, TAU, 32, Color(0.4, 0.6, 1.0, 1.0), 3.0)  # Blue border
	# Simple face silhouette
	draw_circle(left_center + Vector2(0, -10), 14, Color(0.3, 0.5, 0.8, 0.8))
	draw_rect(Rect2(left_center + Vector2(-10, 8), Vector2(20, 16)), Color(0.3, 0.5, 0.8, 0.8))

	# Draw right portrait circle (accused — red tint)
	var right_center := center + Vector2(40, 120)
	draw_circle(right_center, PORTRAIT_RADIUS, Color(0.35, 0.12, 0.12, 0.9))  # Dark red fill
	draw_arc(right_center, PORTRAIT_RADIUS, 0, TAU, 32, Color(1.0, 0.3, 0.3, 1.0), 3.0)  # Red border
	# Simple face silhouette
	draw_circle(right_center + Vector2(0, -10), 14, Color(0.8, 0.3, 0.3, 0.8))
	draw_rect(Rect2(right_center + Vector2(-10, 8), Vector2(20, 16)), Color(0.8, 0.3, 0.3, 0.8))

# ── Public API ────────────────────────────────────────────────────────────────

## Start the argument overlay with data from game.argument_started event.
## data: { accuser_id, target_id, accusation_text, argument_id }
func start_argument(data: Dictionary) -> void:
	_argument_data = data
	_is_showing = true
	_full_text = data.get("accusation_text", "")
	_typewriter_index = 0
	_typewriter_timer = 0.0

	var accuser_id: int = data.get("accuser_id", 1)
	var target_id: int = data.get("target_id", 2)

	# Update portrait labels
	_portrait_left_label.text = "P%d" % accuser_id
	_portrait_right_label.text = "P%d" % target_id

	# Reset visuals
	_modulate.a = 0.0
	show()
	queue_redraw()

	# Setup accusation text with BBCode styling
	_accusation_rich.text = ""
	_accusation_rich.bbcode_enabled = true
	_accusation_rich.clear()

	# Hide result elements
	_result_flash.visible = false
	_result_flash.modulate.a = 0.0
	_penalty_label.visible = false
	_penalty_label.modulate.a = 0.0
	_penalty_label.scale = Vector2(0.5, 0.5)

	# ── Animation Sequence ──
	var tween := create_tween()
	tween.set_parallel(false)

	# 0.0s: Fade in overlay
	tween.tween_property(self, "modulate:a", 1.0, 0.3)
	tween.set_trans(Tween.TRANS_SINE)

	# 0.3s: Portraits slide in from sides
	tween.tween_callback(_animate_portraits_in)

	# 0.7s: Start typewriter (triggered in _process via _is_showing)
	# The actual timing: portraits finish by 0.7s, then typewriter runs naturally

	# 2.5s: Camera shake hint (subtle vibration)
	tween.tween_interval(1.8)  # Wait until 2.5s mark
	tween.tween_callback(_trigger_tension_shake)

	# 3.0s: Result animation (called externally via show_result)

	print("ArgumentOverlay: started — \"%s\"" % _full_text)


## Show the result of the argument.
## data: { argument_id, is_true, penalty_applied }
func show_result(data: Dictionary) -> void:
	_result_data = data
	var is_true: bool = data.get("is_true", false)
	var penalty_applied: bool = data.get("penalty_applied", false)

	var tween := create_tween()
	tween.set_parallel(true)

	# Flash color
	_result_flash.visible = true
	if is_true:
		_result_flash.color = Color(0.0, 1.0, 0.2, 0.5)  # Green flash
	else:
		_result_flash.color = Color(1.0, 0.1, 0.1, 0.5)  # Red flash

	tween.tween_property(_result_flash, "modulate:a", 1.0, 0.15)
	tween.tween_property(_result_flash, "modulate:a", 0.0, 0.3).set_delay(0.15)

	# Penalty text if false accusation
	if not is_true and penalty_applied:
		_penalty_label.visible = true
		var pt := create_tween()
		pt.set_parallel(true)
		pt.tween_property(_penalty_label, "modulate:a", 1.0, 0.2)
		pt.tween_property(_penalty_label, "scale", Vector2(1.5, 1.5), 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		pt.tween_property(_penalty_label, "modulate:a", 0.0, 0.5).set_delay(0.8)
		pt.tween_property(_penalty_label, "scale", Vector2(2.0, 2.0), 0.5).set_delay(0.8)

	# Fade out after result
	var fade_tween := create_tween()
	fade_tween.tween_interval(0.5)  # Hold result for 0.5s
	fade_tween.tween_property(self, "modulate:a", 0.0, 0.3)
	fade_tween.set_trans(Tween.TRANS_SINE)
	fade_tween.tween_callback(_on_overlay_done)

	print("ArgumentOverlay: result — ghost=%s, penalty=%s" % [is_true, penalty_applied])


# ── Animation Helpers ─────────────────────────────────────────────────────────

func _animate_portraits_in() -> void:
	# Portraits are already positioned; we animate their modulate and offset
	# For simplicity, we use a scale + fade approach since we draw manually
	var tween := create_tween()
	tween.set_parallel(true)

	# Fade in the label elements
	tween.tween_property(_portrait_left_label, "modulate:a", 1.0, 0.4).from(0.0)
	tween.tween_property(_portrait_right_label, "modulate:a", 1.0, 0.4).from(0.0)

	# Queue redraw for animated feel
	for i in range(5):
		var tw := create_tween()
		tw.tween_callback(queue_redraw).set_delay(i * 0.08)


func _trigger_tension_shake() -> void:
	# Subtle position shake for tension
	var tween := create_tween()
	tween.set_loops(3)
	tween.tween_property(_accusation_rich, "position", _accusation_rich.position + Vector2(2, 0), 0.05)
	tween.tween_property(_accusation_rich, "position", _accusation_rich.position + Vector2(-2, 1), 0.05)
	tween.tween_property(_accusation_rich, "position", _accusation_rich.position + Vector2(1, -1), 0.05)

	queue_redraw()


func _on_overlay_done() -> void:
	_is_showing = false
	hide()
	queue_redraw()
	print("ArgumentOverlay: done")
