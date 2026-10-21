# TutorialOverlay.gd — 5-step interactive tutorial overlay per ui-ux-design.md §9
# Dim overlay with spotlight hole, chalk arrow, instruction box, step dots.
class_name TutorialOverlay
extends Control

enum Step { DRAW = 0, HIDE = 1, TOSS = 2, SEARCH = 3, DEFEND = 4 }

const STEP_DATA := [
	{ "title": "DRAW", "body": "In your own half, drag one finger (or left mouse button) to draw as many chalk lines as you can before 40 seconds run out." },
	{ "title": "HIDE", "body": "Place marks against compound walls to conceal them. Hidden wall marks require searching closer than marks on open ground." },
	{ "title": "TOSS", "body": "Meet at the central alley, call heads or tails, and find out who searches the other half first." },
	{ "title": "SEARCH", "body": "During your 30-second search, tap to walk around the CPU's half. Get close enough to discover a mark, then tap it to strike it out." },
	{ "title": "DEFEND", "body": "When the CPU searches your half, distract it with ARGUE and sneak up to three extra marks. Then swap roles. More surviving lines wins; equal totals are a draw." },
]

@onready var _dim_overlay: ColorRect = %DimOverlay
@onready var _chalk_arrow: Line2D = %ChalkArrow
@onready var _instruction_box: Panel = %InstructionBox
@onready var _step_title_label: Label = %StepTitleLabel
@onready var _step_body_label: Label = %StepBodyLabel
@onready var _skip_btn: Button = %SkipButton
@onready var _next_btn: Button = %NextButton
@onready var _dots_container: HBoxContainer = %DotsContainer

var _current_step: int = Step.DRAW
var _step_dots: Array[ColorRect] = []

func _ready() -> void:
	_connect_signals()
	_create_step_dots()
	_show_step(Step.DRAW)

func _connect_signals() -> void:
	if _skip_btn: _skip_btn.pressed.connect(_on_skip)
	if _next_btn: _next_btn.pressed.connect(_on_next)

func _create_step_dots() -> void:
	if not _dots_container:
		return
	for _i in range(5):
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(8, 8)
		dot.color = Color("C5BFB4")
		_dots_container.add_child(dot)
		_step_dots.append(dot)
	_update_dots()

func _show_step(step: int) -> void:
	_current_step = step
	var data = STEP_DATA[step]
	
	if _step_title_label:
		_step_title_label.text = "%d/5. %s" % [step + 1, data["title"]]
	if _step_body_label:
		_step_body_label.text = data["body"]
	
	if _next_btn:
		if step == Step.DEFEND:
			_next_btn.text = "DONE ✓"
			_next_btn.add_theme_color_override("font_color", Color("7A9A6E"))
		else:
			_next_btn.text = "NEXT →"
	
	_update_dots()
	_animate_transition()

func _update_dots() -> void:
	for i in range(_step_dots.size()):
		var dot := _step_dots[i]
		if i < _current_step:
			dot.color = Color("7A9A6E")
		elif i == _current_step:
			dot.color = Color("F5F0E8")
		else:
			dot.color = Color("C5BFB4")

func _animate_transition() -> void:
	# Crossfade instruction text
	if _instruction_box:
		_instruction_box.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(_instruction_box, "modulate:a", 1.0, 0.3).set_ease(Tween.EASE_OUT)

func _on_next() -> void:
	if _current_step >= Step.DEFEND:
		_finish_tutorial()
		return
	
	var next_step := _current_step + 1
	_current_step = next_step
	_show_step(next_step)
	EventBus.emit("ui.tutorial_step", {"step": next_step})

func _on_skip() -> void:
	EventBus.emit("ui.dialog_opened", {"dialog_name": "skip_tutorial"})
	# For prototype: just finish
	_finish_tutorial()

func _finish_tutorial() -> void:
	EventBus.emit("ui.tutorial_complete", {})
	EventBus.emit("ui.button_pressed", {"button": "tutorial_done"})
	SaveManager.save_local("tutorial", {"completed": true})
	queue_free()

func set_highlight_position(_pos: Vector2) -> void:
	# Placeholder: in full implementation, moves the dim overlay hole
	pass
