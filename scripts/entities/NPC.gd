# NPC.gd — AI-driven entity (patrol demo)
# Cycles between waypoints using the same state machine as Player.
# Proves the architecture supports multiple entity types.

class_name NPC
extends Entity

## Waypoints to patrol between (in world coordinates).
@export var patrol_points: Array[Vector2] = []

## Wait time at each waypoint (seconds).
@export var wait_time: float = 1.0

## Color of this NPC.
@export var npc_color: Color = Color.BLUE

const VISUAL_SIZE := Vector2(32, 32)

var state_machine: EntityStateMachine
var _current_waypoint_index: int = 0
var _wait_timer: float = 0.0
var _is_waiting: bool = false

func _ready() -> void:
	super._ready()
	entity_type = "npc"
	move_speed = 100.0

	# If no patrol points defined, create a default loop
	if patrol_points.is_empty():
		patrol_points = [
			Vector2(200, 200),
			Vector2(500, 200),
			Vector2(500, 500),
			Vector2(200, 500),
		]

	# State machine
	state_machine = EntityStateMachine.new()
	state_machine.name = "EntityStateMachine"
	add_child(state_machine)

	state_machine.add_state("idle", PlayerIdle.new())
	state_machine.add_state("walking", PlayerWalking.new())
	state_machine.transition_to("idle")

	set_meta("target_position", position)
	set_meta("has_target", false)
	set_meta("is_local", false)

	# Start moving to first waypoint
	_go_to_next_waypoint()

func _draw() -> void:
	var half := VISUAL_SIZE / 2.0
	draw_rect(Rect2(-half, VISUAL_SIZE), npc_color)
	draw_rect(Rect2(-half, VISUAL_SIZE), Color.BLACK, false, 2.0)

func _physics_process(delta: float) -> void:
	queue_redraw()

	if _is_waiting:
		_wait_timer -= delta
		if _wait_timer <= 0.0:
			_is_waiting = false
			_go_to_next_waypoint()
		return

	# Check if arrived at waypoint
	if not get_meta("has_target"):
		_is_waiting = true
		_wait_timer = wait_time
		state_machine.transition_to("idle")

func _go_to_next_waypoint() -> void:
	var target := patrol_points[_current_waypoint_index]
	_current_waypoint_index = (_current_waypoint_index + 1) % patrol_points.size()

	set_meta("target_position", target)
	set_meta("has_target", true)

	if state_machine.current_state_name() != "walking":
		state_machine.transition_to("walking")
