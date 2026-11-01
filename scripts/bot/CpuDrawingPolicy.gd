# CpuDrawingPolicy.gd -- pure, repeatable difficulty-driven chalk quotas.
# The owner supplied Easy 50..100; higher ranges are AI-proposed and must be
# balanced against actual human stroke rates in real 40-second play.
class_name CpuDrawingPolicy
extends RefCounted

const RANGES := {
	0: Vector2i(50, 100),
	1: Vector2i(65, 120),
	2: Vector2i(85, 150),
	3: Vector2i(110, 180),
}

static func bounds_for(difficulty: int) -> Vector2i:
	return RANGES.get(difficulty, RANGES[1])

static func roll_count(difficulty: int, rng: RandomNumberGenerator,
		override: int = -1) -> int:
	var bounds := bounds_for(difficulty)
	if override >= 0:
		return override
	return rng.randi_range(bounds.x, bounds.y)
