# PopupDialog.gd — Reusable popup dialog component
# Configurable via @export vars for title, body, and button labels.
# Emits signals on confirm/cancel. Dark overlay backdrop (optional tap-to-dismiss).
class_name PopupDialog
extends CanvasLayer

## Emitted when the user taps the confirm button.
signal confirmed()
## Emitted when the user taps the cancel button or backdrop (if dismissible).
signal cancelled()

enum ButtonMode { OK_ONLY, OK_CANCEL, CONFIRM_CANCEL, CUSTOM }

@export var dialog_title: String = "Dialog Title"
@export var body_text: String = "Body text goes here."
@export var button_mode: ButtonMode = ButtonMode.OK_CANCEL
@export var confirm_label: String = "OK"
@export var cancel_label: String = "Cancel"
@export var dismiss_on_backdrop: bool = true

@onready var _overlay: ColorRect = %Overlay
@onready var _panel: Panel = %Panel
@onready var _title_label: Label = %TitleLabel
@onready var _body_label: Label = %BodyLabel
@onready var _confirm_btn: Button = %ConfirmButton
@onready var _cancel_btn: Button = %CancelButton
@onready var _vbox: VBoxContainer = %ButtonVBox

func _ready() -> void:
	_overlay.gui_input.connect(_on_overlay_gui_input)
	_confirm_btn.pressed.connect(_on_confirm)
	_cancel_btn.pressed.connect(_on_cancel)

	_title_label.text = dialog_title
	_body_label.text = body_text
	_confirm_btn.text = confirm_label
	_cancel_btn.text = cancel_label

	match button_mode:
		ButtonMode.OK_ONLY:
			_cancel_btn.visible = false
		ButtonMode.OK_CANCEL:
			_confirm_btn.text = "OK"
			_cancel_btn.text = "Cancel"
		ButtonMode.CONFIRM_CANCEL:
			pass
		ButtonMode.CUSTOM:
			pass

	EventBus.emit("ui.dialog_opened", {"dialog_name": "popup"})

	# Entrance animation: scale 80% → 100%
	_panel.pivot_offset = _panel.size / 2.0
	_panel.scale = Vector2(0.8, 0.8)
	var tween := create_tween()
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)
	_overlay.modulate.a = 0.0
	tween.parallel().tween_property(_overlay, "modulate:a", 0.5, 0.15)

func _on_confirm() -> void:
	_close()
	confirmed.emit()
	EventBus.emit("ui.dialog_closed", {"dialog_name": "popup"})

func _on_cancel() -> void:
	_close()
	cancelled.emit()
	EventBus.emit("ui.dialog_closed", {"dialog_name": "popup"})

func _on_overlay_gui_input(event: InputEvent) -> void:
	if dismiss_on_backdrop and event is InputEventMouseButton and event.pressed:
		_on_cancel()

func _close() -> void:
	var tween := create_tween()
	tween.tween_property(_panel, "scale", Vector2(0.8, 0.8), 0.15)
	tween.parallel().tween_property(_overlay, "modulate:a", 0.0, 0.15)
	tween.tween_callback(queue_free)
