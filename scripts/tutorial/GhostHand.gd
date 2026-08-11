# GhostHand.gd — Procedural ghost hand that teaches the tutorial with zero text.
#
# A pale, translucent Node2D hand with a pointing finger (animation-list.md
# ANM-P-04 "ghost-line placement gesture": 0.3s hand-swipe, small arc, fade to
# 15% opacity line). All teaching is pantomime: the hand glides, hovers, taps,
# and draws chalk; the player imitates the gesture. No art assets — the whole
# hand is one _draw().
#
# The tutorial drives it through small async methods that emit `move_finished`
# when each motion completes, so sequences read top-to-bottom with `await`.
#
# Android optimization (Prompt 16): the ~11 static body primitives are baked
# ONCE into a 128×128 texture (throwaway SubViewport) — the live hand renders
# as a single textured quad plus 2 animated accents, redrawn at 30 fps instead
# of 60. _draw_hand_body() doubles as the fallback if the bake isn't ready.
class_name GhostHand
extends Node2D

## Finger tip offset in local space — the point that "touches" the world.
const TIP := Vector2(10, -46)

## Min seconds between redraws (30 fps — plenty for the 2 Hz glow pulse).
const REDRAW_INTERVAL := 1.0 / 30.0

## Bake viewport size — 2x the ~64 px hand for crisp edges.
const HAND_TEX_SIZE := 128

## Where the baked texture is drawn so the hand's local origin (0,0) aligns
## with the bake drawer placed at the viewport center.
const HAND_TEX_TOP_LEFT := Vector2(-64, -64)

const HAND_BODY := Color(0.82, 0.88, 1.0, 0.6)
const HAND_EDGE := Color(0.93, 0.96, 1.0, 0.8)
const TRAIL_COLOR := Color(0.75, 0.85, 1.0, 0.35)
## ANM-P-04: the demo line fades to 15% opacity once drawn.
const TRAIL_FADED := Color(0.75, 0.85, 1.0, 0.15)

signal move_finished

## World-space chalk trail left by the pointing finger while "drawing".
## Parented to the tutorial root (world space) so rotated hand motion
## still traces a stable line.
var trail: Line2D = null

var _trailing: bool = false
var _trail_world: Array[Vector2] = []
var _bob_time: float = 0.0
var _bobbing: bool = false
var _press: float = 0.0
var _glow_t: float = 0.0

## Baked static hand texture (null until the async bake completes).
var _hand_texture: Texture2D = null

var _redraw_accum: float = 0.0


func _ready() -> void:
	trail = Line2D.new()
	trail.name = "GhostTrail"
	trail.width = 5.0
	trail.default_color = TRAIL_COLOR
	trail.joint_mode = Line2D.LINE_JOINT_ROUND
	trail.begin_cap_mode = Line2D.LINE_CAP_ROUND
	trail.end_cap_mode = Line2D.LINE_CAP_ROUND
	trail.z_index = 5
	if get_parent():
		get_parent().add_child(trail)
	trail.visible = false
	modulate.a = 0.0
	set_process(true)
	_bake_hand_texture()


func _process(delta: float) -> void:
	_bob_time += delta
	_glow_t += delta
	# Redraw throttled to 30 fps — the glow pulse is a 2 Hz sine, so 30 fps is
	# visually identical while halving vertex generation on low-end phones.
	_redraw_accum += delta
	if _redraw_accum >= REDRAW_INTERVAL:
		_redraw_accum = 0.0
		queue_redraw()
	if _trailing:
		_trail_world.append(get_finger_tip_world())
		if _trail_world.size() > 1:
			trail.points = PackedVector2Array(_trail_world)


# ── Queries ────────────────────────────────────────────────────────────────────

## World position of the drawn finger tip (accounts for hand rotation).
func get_finger_tip_world() -> Vector2:
	return global_position + TIP.rotated(rotation)


## Rotate the hand so the pointing finger aims at a world point.
func face_towards(world_point: Vector2) -> void:
	rotation = (world_point - global_position).angle() - TIP.angle()


# ── Motion API (all awaitable via `move_finished`) ────────────────────────────

## Fade the hand in.
func appear() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await tw.finished
	emit_signal("move_finished")


## Fade the hand out.
func vanish() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tw.finished
	emit_signal("move_finished")


## Glide to a world position, finger leading the way.
func move_to(target: Vector2, duration: float) -> void:
	_bobbing = false
	var from := global_position
	if duration > 0.0 and target.distance_to(from) > 2.0:
		rotation = (target - from).angle() - TIP.angle()
	var tw := create_tween()
	tw.tween_property(self, "global_position", target, duration)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	emit_signal("move_finished")


## Bob gently in place for `duration` seconds — the "thinking / watching" beat.
func hover(duration: float) -> void:
	_bobbing = true
	var base := global_position
	var t := 0.0
	while t < duration:
		await get_tree().process_frame
		t += get_process_delta_time()
		global_position = base + Vector2(0.0, sin(t * 5.0) * 4.0)
	_bobbing = false
	global_position = base
	emit_signal("move_finished")


## Approach `point` and press the finger tip onto it, hold, then lift off.
## This is the game's "tap / investigate / select" gesture.
func tap_at(point: Vector2, hold: float = 0.25) -> void:
	var down_rot := PI / 2.0 - TIP.angle()        # finger points straight down
	var tip_down := TIP.rotated(down_rot)         # ≈ (0, 47)
	var hover_pos := point - tip_down + Vector2(0, 26)

	rotation = lerp_angle(rotation, down_rot, 0.9)
	var tw := create_tween()
	tw.tween_property(self, "global_position", hover_pos, 0.3)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(self, "global_position", point - tip_down, 0.12)
	tw2.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw2.tween_property(self, "_press", 1.0, 0.12)
	await tw2.finished

	if hold > 0.0:
		await get_tree().create_timer(hold).timeout

	var tw3 := create_tween()
	tw3.set_parallel(true)
	tw3.tween_property(self, "global_position", point - tip_down + Vector2(0, -24), 0.14)
	tw3.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw3.tween_property(self, "_press", 0.0, 0.14)
	await tw3.finished
	emit_signal("move_finished")


## Draw a chalk line from `from` to `to` with the pointing finger, leaving a
## pale trail (ANM-P-04), then fade the trail to 15% opacity.
func draw_swipe(from: Vector2, to: Vector2, duration: float) -> void:
	rotation = (to - from).angle() - TIP.angle()
	var tip_offset := TIP.rotated(rotation)
	global_position = from - tip_offset
	_trail_world.clear()
	_trail_world.append(get_finger_tip_world())
	trail.points = PackedVector2Array(_trail_world)
	trail.visible = true
	_trailing = true
	var tw := create_tween()
	tw.tween_property(self, "global_position", to - tip_offset, duration)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	_trailing = false
	# ANM-P-04: hand-swipe line fades to 15% opacity.
	var tw2 := create_tween()
	tw2.tween_property(trail, "default_color", TRAIL_FADED, 0.3)
	await tw2.finished
	emit_signal("move_finished")


## Erase the demo trail (level transitions).
func clear_trail() -> void:
	_trailing = false
	_trail_world.clear()
	if trail:
		trail.points = PackedVector2Array()
		trail.visible = false
		trail.default_color = TRAIL_COLOR


# ── Drawing ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	var dim := 1.0 - _press * 0.22
	if _hand_texture:
		# Baked body: one textured quad; the modulate color's alpha applies the
		# press dim to the whole baked hand in a single primitive.
		draw_texture(_hand_texture, HAND_TEX_TOP_LEFT, Color(1.0, 1.0, 1.0, dim))
	else:
		# Fallback (bake not ready yet or failed): draw the body directly.
		_draw_hand_body(dim)

	# soft breathing glow (kept dynamic — it pulses at 2 Hz)
	draw_circle(Vector2.ZERO, 34.0, Color(0.8, 0.9, 1.0, 0.09 + 0.02 * sin(_glow_t * 2.0)))

	# tap ripple at the finger tip while pressed
	if _press > 0.4:
		draw_arc(TIP, 9.0 + _press * 7.0, 0.0, TAU, 24, Color(0.9, 0.95, 1.0, 0.5 * _press), 2.0)


## Draw the static hand body primitives. Used by the one-time bake and as the
## runtime fallback while the bake is pending.
func _draw_hand_body(dim: float) -> void:
	var body := Color(HAND_BODY.r * dim, HAND_BODY.g * dim, HAND_BODY.b * dim, HAND_BODY.a)
	var edge := Color(HAND_EDGE.r * dim, HAND_EDGE.g * dim, HAND_EDGE.b * dim, HAND_EDGE.a)

	# wrist / palm
	draw_circle(Vector2(0, 10), 13.0, body)

	# pointing index finger (thick rounded line: circles + line)
	var knuckle := Vector2(2, -6)
	draw_circle(knuckle, 6.6, body)
	draw_circle(TIP, 6.6, body)
	draw_line(knuckle, TIP, body, 11.0)

	# three curled fingers (arcs on the palm side)
	for i in range(3):
		var base_ang := 2.2 + i * 0.35
		draw_arc(Vector2(-8, 2), 9.0, base_ang, base_ang + 1.6, 6, body, 8.0)

	# thumb
	draw_arc(Vector2(6, 6), 10.0, -0.5, 0.9, 6, body, 7.0)

	# edge highlight on the pointing finger
	draw_line(knuckle, TIP, edge, 3.5)


## One-time bake: render the static hand body into a 128×128 texture via a
## throwaway SubViewport, then upload it as an ImageTexture and free the
## viewport. Async — _draw_hand_body() covers frames until it completes.
func _bake_hand_texture() -> void:
	var vp := SubViewport.new()
	vp.name = "GhostHandBakeViewport"
	vp.size = Vector2i(HAND_TEX_SIZE, HAND_TEX_SIZE)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)
	var drawer := StaticHandDrawer.new()
	drawer.position = Vector2(HAND_TEX_SIZE * 0.5, HAND_TEX_SIZE * 0.5)
	vp.add_child(drawer)
	await RenderingServer.frame_post_draw
	if not is_inside_tree():
		return  # scene already left — nothing to keep
	var tex := vp.get_texture()
	if tex == null:
		vp.queue_free()
		return  # bake failed — the _draw_hand_body() fallback stays active
	var img := tex.get_image()
	_hand_texture = ImageTexture.create_from_image(img)
	vp.queue_free()


## Renders the static hand body once into the bake viewport. Duplicates
## _draw_hand_body() geometry because GDScript inner classes cannot reference
## outer-class constants — keep the two bodies in sync when editing shapes.
class StaticHandDrawer:
	extends Node2D
	var body := Color(0.82, 0.88, 1.0, 0.6)
	var edge := Color(0.93, 0.96, 1.0, 0.8)
	func _draw() -> void:
		draw_circle(Vector2(0, 10), 13.0, body)
		var knuckle := Vector2(2, -6)
		draw_circle(knuckle, 6.6, body)
		draw_circle(Vector2(10, -46), 6.6, body)
		draw_line(knuckle, Vector2(10, -46), body, 11.0)
		for i in range(3):
			var base_ang := 2.2 + i * 0.35
			draw_arc(Vector2(-8, 2), 9.0, base_ang, base_ang + 1.6, 6, body, 8.0)
		draw_arc(Vector2(6, 6), 10.0, -0.5, 0.9, 6, body, 7.0)
		draw_line(knuckle, Vector2(10, -46), edge, 3.5)
