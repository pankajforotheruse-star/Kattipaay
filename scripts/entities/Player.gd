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
		EventBus.on("input.move_start", _on_move_command)
		EventBus.on("input.move_end", _on_move_stop)

	# Initialize meta for movement
	set_meta("target_position", position)
	set_meta("has_target", false)
	set_meta("is_local", is_local)

## Draw the player as a colored rectangle + direction indicator.
func _draw() -> void:
	var half := VISUAL_SIZE / 2.0
	# Main body
	draw_rect(Rect2(-half, VISUAL_SIZE), player_color)
	# Border
	draw_rect(Rect2(-half, VISUAL_SIZE), Color.WHITE if is_local else Color.BLACK, false, 2.0)
	# Direction indicator (small triangle pointing "up" relative to entity)
	var indicator_color := Color.WHITE
	var points := PackedVector2Array([
		Vector2(0, -half.y - 8),
		Vector2(-5, -half.y),
		Vector2(5, -half.y),
	])
	draw_polygon(points, PackedColorArray([indicator_color, indicator_color, indicator_color]))

## Handle a move command from InputManager (via EventBus).
func _on_move_command(payload: Dictionary) -> void:
	if not is_local:
		return

	# Convert screen position to world position
	var screen_pos: Vector2 = payload.get("screen_position", Vector2.ZERO)
	var world_pos := InputManager.screen_to_world(screen_pos)

	set_meta("target_position", world_pos)
	set_meta("has_target", true)

	# Also emit a game-level event so systems can react
	EventBus.emit("input.move_command_world", {
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
		EventBus.off("input.move_start", _on_move_command)
		EventBus.off("input.move_end", _on_move_stop)
