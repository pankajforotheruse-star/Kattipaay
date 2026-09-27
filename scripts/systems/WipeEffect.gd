# WipeEffect.gd — One-shot chalk-wipe removal animation for struck-out lines.
#
# Spawned when a line is STRUCK OUT (wiped away) by a searcher:
#   1. Rapid scribble: 3-4 jittering chalk polylines dancing along the line's
#      extent (built procedurally, no art assets).
#   2. "X" mark on the spot (the clear struck-out read).
#   3. Small chalk-dust particle burst.
#   4. Fade to zero, then the effect frees itself.
#
# Compatible with the pooled Line2D style of DrawSystem/GhostDrawSystem: the
# effect is a leaf Node2D added to the line's container, animates itself with a
# Tween, and queue_free()s — no pooling needed (short-lived, one per strike).

class_name WipeEffect
extends Node2D

## Total effect lifetime (seconds).
const DURATION := 0.7
## Scribble polyline count.
const SCRIBBLE_COUNT := 4
## X mark half-size (world pixels).
const X_HALF := 14.0

## Static factory: create a wipe effect over `center` with an extent of
## `size` (the struck line's bounding size), tinted `color`.
## Parented under `parent` (the chalk container) so z-order matches chalk.
static func play(parent: Node, center: Vector2, size: Vector2, color: Color) -> void:
	var fx := WipeEffect.new()
	fx.position = center
	fx.set_meta("wipe_color", color)
	fx.set_meta("wipe_size", size)
	if parent and is_instance_valid(parent):
		parent.add_child(fx)
	else:
		fx.call_deferred("_spawn_under_scene")
	return


func _spawn_under_scene() -> void:
	# Added to the scene tree fires _ready() -> _play() exactly once.
	var tree := get_tree()
	if tree and tree.current_scene:
		var root := tree.current_scene as Node2D
		if root:
			root.add_child(self)
			return
	queue_free()


func _ready() -> void:
	_play()


func _play() -> void:
	var color: Color = get_meta("wipe_color", Color.WHITE)
	var size: Vector2 = get_meta("wipe_size", Vector2(60, 20))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(position.x + position.y * 7919.0) + Time.get_ticks_msec()

	# 1) Rapid scribble polylines: a few jittering strokes across the line.
	for i in range(SCRIBBLE_COUNT):
		var stroke := Line2D.new()
		stroke.z_index = 12
		stroke.width = 2.5
		stroke.default_color = Color(color.r, color.g, color.b, 0.9)
		stroke.texture_mode = Line2D.LINE_TEXTURE_NONE
		stroke.joint_mode = Line2D.LINE_JOINT_ROUND
		stroke.end_cap_mode = Line2D.LINE_CAP_ROUND
		stroke.begin_cap_mode = Line2D.LINE_CAP_ROUND
		var pts := PackedVector2Array()
		var from := Vector2(-size.x * 0.5, -size.y * 0.5) + Vector2(
			rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
		var to := Vector2(size.x * 0.5, size.y * 0.5) + Vector2(
			rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
		# Zigzag scribble body.
		pts.append(from)
		var steps := 5
		for s in range(1, steps):
			var t := float(s) / float(steps)
			var base := from.lerp(to, t)
			var perp := Vector2(1.0, -1.0) if rng.randf() > 0.5 else Vector2(-1.0, 1.0)
			pts.append(base + perp * rng.randf_range(-7.0, 7.0))
		pts.append(to)
		stroke.points = pts
		add_child(stroke)

	# 2) X mark on the spot (struck-out read).
	var xmark := Line2D.new()
	xmark.z_index = 12
	xmark.width = 3.5
	xmark.default_color = Color(1.0, 1.0, 1.0, 0.95)
	xmark.texture_mode = Line2D.LINE_TEXTURE_NONE
	xmark.joint_mode = Line2D.LINE_JOINT_ROUND
	xmark.end_cap_mode = Line2D.LINE_CAP_ROUND
	xmark.begin_cap_mode = Line2D.LINE_CAP_ROUND
	xmark.points = PackedVector2Array([
		Vector2(-X_HALF, -X_HALF), Vector2(X_HALF, X_HALF),
	])
	var xmark2 := Line2D.new()
	xmark2.z_index = 12
	xmark2.width = 3.5
	xmark2.default_color = Color(1.0, 1.0, 1.0, 0.95)
	xmark2.texture_mode = Line2D.LINE_TEXTURE_NONE
	xmark2.joint_mode = Line2D.LINE_JOINT_ROUND
	xmark2.end_cap_mode = Line2D.LINE_CAP_ROUND
	xmark2.begin_cap_mode = Line2D.LINE_CAP_ROUND
	xmark2.points = PackedVector2Array([
		Vector2(-X_HALF, X_HALF), Vector2(X_HALF, -X_HALF),
	])
	add_child(xmark)
	add_child(xmark2)

	# 3) Chalk-dust particles.
	var dust := CPUParticles2D.new()
	dust.z_index = 13
	dust.amount = 16
	dust.lifetime = 0.5
	dust.one_shot = true
	dust.explosiveness = 1.0
	dust.direction = Vector2(0, -1)
	dust.spread = 180.0
	dust.initial_velocity_min = 40.0
	dust.initial_velocity_max = 120.0
	dust.gravity = Vector2(0, 220)
	dust.scale_amount_min = 2.0
	dust.scale_amount_max = 4.5
	dust.color = Color(0.95, 0.95, 1.0, 1.0)
	dust.emitting = true
	add_child(dust)

	# 4) Animate: scribbles rattle around the spot, X pops in, whole effect
	# fades, then the effect frees itself.
	for stroke in get_children():
		if stroke is Line2D and stroke != xmark and stroke != xmark2:
			stroke.scale = Vector2(0.7, 0.7)
	var tween := create_tween()
	tween.set_parallel(true)
	for stroke in get_children():
		if stroke is Line2D and stroke != xmark and stroke != xmark2:
			tween.tween_property(stroke, "scale", Vector2(1.15, 1.15), DURATION * 0.28) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tween.tween_property(stroke, "position", Vector2(
				rng.randf_range(-5.0, 5.0), rng.randf_range(-5.0, 5.0)), DURATION * 0.28) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(xmark, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(xmark2, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, DURATION * 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func():
		queue_free()
	)
	# X starts small and pops in.
	xmark.scale = Vector2(0.2, 0.2)
	xmark2.scale = Vector2(0.2, 0.2)