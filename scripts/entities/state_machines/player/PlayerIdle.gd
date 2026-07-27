# PlayerIdle.gd — Player is standing still, waiting for input.

class_name PlayerIdle
extends State

func enter(_prev: State) -> void:
	var player: CharacterBody2D = machine.get_parent()
	player.velocity = Vector2.ZERO
	print("Player %d: idle" % player.get_instance_id())

func physics_update(_delta: float) -> void:
	pass  # nothing moves in idle
