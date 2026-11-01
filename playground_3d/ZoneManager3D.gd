# Two-territory spatial boundary for exploratory 3D gameplay.
# Actual phase permissions remain owned by existing 2D/game-rule code until integrated.
extends Node3D

enum Territory { OUTSIDE, HUMAN, CPU, ALLEY }
@export var half_length: float = 13.0
@export var half_width: float = 6.0
@export var alley_half_width: float = 1.0

func classify_world_position(position: Vector3) -> Territory:
	if absf(position.z) > half_length or absf(position.x) > half_width:
		return Territory.OUTSIDE
	if absf(position.x) <= alley_half_width:
		return Territory.ALLEY
	if position.x < 0.0:
		return Territory.HUMAN
	return Territory.CPU

func can_draw_in_territory(position: Vector3, territory: int) -> bool:
	if territory != Territory.HUMAN and territory != Territory.CPU:
		return false
	return classify_world_position(position) == territory
