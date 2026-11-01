# Player.gd — Player-controlled entity
# Listens for input events targeting this player via EventBus.
# Uses EntityStateMachine for idle/walking transitions.

class_name Player
extends Entity

## Color of this player's rectangle (for visual distinction).
@export var player_color: Color = Color.RED

## If true, this player is controlled by the local device.
@export var is_local: bool = true

## Reference to the state machine node (child).
var state_machine: EntityStateMachine

## Size of the player visual (centered on entity origin).
const VISUAL_SIZE := Vector2(32, 32)

func _ready() -> void:
	super._ready()
	entity_type = "player"

	# Find or create the state machine
	state_machine = get_node_or_null("EntityStateMachine")
	if not state_machine:
		state_machine = EntityStateMachine.new()
		state_machine.name = "EntityStateMachine"
		add_child(state_machine)

	# Register states
	state_machine.add_state("idle", PlayerIdle.new())
	state_machine.add_state("walking", PlayerWalking.new())
	state_machine.transition_to("idle")

	# Listen for move commands via EventBus (if this is the local player)
	if is_local:
		EventBus.on(EventBus.EV_INPUT_MOVE_START, _on_move_command)
		EventBus.on(EventBus.EV_INPUT_MOVE_END, _on_move_stop)

	# Initialize meta for movement
	set_meta("target_position", position)
	set_meta("has_target", false)
	set_meta("is_local", is_local)

## Draw the player as a colored rectangle + direction indicator.
func _draw() -> void:
	# Simple legible child silhouette instead of an arcade debug rectangle.
	# The full character art pass can replace this procedural placeholder.
	var skin := Color(0.86, 0.65, 0.45)
	var ink := Color(0.13, 0.17, 0.20)
	draw_line(Vector2(-5, 9), Vector2(-8, 21), ink, 4.0)
	draw_line(Vector2(5, 9), Vector2(8, 21), ink, 4.0)
	draw_line(Vector2(-7, -1), Vector2(-15, 7), skin, 4.0)
	draw_line(Vector2(7, -1), Vector2(15, 7), skin, 4.0)
	draw_circle(Vector2(0, 2), 10.0, player_color)
	draw_circle(Vector2(0, -13), 9.0, skin)
	draw_arc(Vector2(0, -13), 9.0, PI, TAU, 16, ink, 2.5)
	draw_circle(Vector2(-3, -13), 1.15, ink)
	draw_circle(Vector2(3, -13), 1.15, ink)
	draw_circle(Vector2(0, 2), 10.0, Color(0, 0, 0, 0.38), false, 1.4)

## Handle a move command from InputManager (via EventBus).
func _on_move_command(payload: Dictionary) -> void:
	if not is_local:
		return

	# Convert screen position to world position
	var screen_pos: Vector2 = payload.get("screen_position", Vector2.ZERO)
	var world_pos := InputManager.screen_to_world(screen_pos)

	# MVP zone lock: during DRAWING the player can move only inside the PLAYER
	# zone - the move target is clamped to the zone rect so walking stops at
	# the boundary. Movement outside DRAWING (meeting/search) stays free.
	if GameState.get_match_state() == GameState.MatchState.DRAWING:
		world_pos = ZoneLayout.clamp_to_player_zone(world_pos)

	set_meta("target_position", world_pos)
	set_meta("has_target", true)

	# Also emit a game-level event so systems can react
	EventBus.emit(EventBus.EV_INPUT_MOVE_COMMAND_WORLD, {
		"entity_id": entity_id,
		"target": world_pos,
	})

	if state_machine.current_state_name() != "walking":
		state_machine.transition_to("walking")

func _on_move_stop(_payload: Dictionary) -> void:
	if not is_local:
		return
	set_meta("has_target", false)
	if state_machine.current_state_name() == "walking":
		state_machine.transition_to("idle")

func _physics_process(delta: float) -> void:
	# Queue redraw every frame so the indicator updates
	queue_redraw()

func _exit_tree() -> void:
	# Clean up event listeners
	if is_local:
		EventBus.off(EventBus.EV_INPUT_MOVE_START, _on_move_command)
		EventBus.off(EventBus.EV_INPUT_MOVE_END, _on_move_stop)
