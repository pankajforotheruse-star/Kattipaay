# PlayerWalking.gd — Player is moving toward a target position.

class_name PlayerWalking
extends State

var _arrival_threshold: float = 5.0

func enter(_prev: State) -> void:
	print("Player: walking")

func physics_update(delta: float) -> void:
	var player: CharacterBody2D = machine.get_parent()

	# Read target from the player's metadata (set by MovementSystem)
	if not player.has_meta("target_position") or not player.has_meta("has_target"):
		machine.transition_to("idle")
		return

	if not player.get_meta("has_target"):
		machine.transition_to("idle")
		return

	var target: Vector2 = player.get_meta("target_position")
	var direction := target - player.position
	var distance := direction.length()

	if distance < _arrival_threshold:
		# Arrived — snap to target and go idle
		player.position = target
		player.velocity = Vector2.ZERO
		player.set_meta("has_target", false)
		machine.transition_to("idle")
		return

	# Move toward target
	var speed: float = player.get_meta("move_speed", 200.0)
	player.velocity = direction.normalized() * speed
	player.move_and_slide()
