# HUD.gd — Heads-up display overlay
# CanvasLayer that sits on top of the game world.
# Shows entity state info and debug output.

class_name HUD
extends CanvasLayer

@onready var _state_label: Label = $StateLabel
@onready var _info_label: Label = $InfoLabel

func _ready() -> void:
	EventBus.on("entity.state_changed", _on_entity_state_changed)
	EventBus.on("game.state_changed", _on_game_state_changed)

	_update_info("Tap anywhere to move the RED player.\nBLUE player patrols automatically.\nGreen grid = 100px squares.")

func _on_entity_state_changed(payload: Dictionary) -> void:
	var node = payload.get("node")
	if node is Player and node.is_local:
		var state_name := payload.get("current", "?")
		_state_label.text = "Player State: %s" % state_name

func _on_game_state_changed(payload: Dictionary) -> void:
	var to: int = payload.get("to", -1)
	_state_label.text = "Game: %s" % GameState.State.keys()[to]

func _update_info(text: String) -> void:
	if _info_label:
		_info_label.text = text
