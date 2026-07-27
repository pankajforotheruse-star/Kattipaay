# EntityStateMachine.gd — Specialized state machine for game entities
# Thin wrapper around StateMachine; provides entity-specific helpers.

class_name EntityStateMachine
extends StateMachine

## The entity that owns this state machine (set during _ready).
var entity: Node2D = null

func _ready() -> void:
	# Walk up to find the owning entity
	var p := get_parent()
	while p:
		if p is CharacterBody2D or p is Node2D:
			entity = p
			break
		p = p.get_parent()
