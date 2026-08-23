# Villager.gd — Procedural village character used as the accusation target in
# tutorial level 3. No art assets: a stylized figure built from one _draw().
#
# The ghost villager carries the game's hidden-role tell (animation-list.md
# ANM-G-09 "shade shimmer": a 0.2s opacity flicker to ~30% every 2-4s).
class_name Villager
extends Node2D

signal tapped

## Entity id — matches what ArgumentSystem expects as an accusation target.
var villager_id: int = -1
## Whether this villager is the hidden ghost (subtle shimmer tell).
var is_ghost: bool = false
var body_color := Color(0.9, 0.55, 0.2, 1.0)
var selected := false

var _t := 0.0
var _shimmer_timer := 2.0
var _flicker := 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	var dirty := false
	if is_ghost:
		_shimmer_timer -= delta
		if _shimmer_timer <= 0.0:
			_shimmer_timer = randf_range(2.0, 4.0)
			_flicker = 0.2
		if _flicker > 0.0:
			_flicker -= delta
			dirty = true
	if selected:
		dirty = true
	if dirty:
		queue_redraw()


func select() -> void:
	selected = true
	queue_redraw()


func deselect() -> void:
	selected = false
	queue_redraw()


func _draw() -> void:
	var body := body_color
	if is_ghost and _flicker > 0.0:
		body.a = 0.3                                # ANM-G-09 shimmer tell
	var skin := Color(0.93, 0.78, 0.6, body.a)
	var ink := Color(0.15, 0.1, 0.1, body.a)

	# selection ring (pulsing)
	if selected:
		var pulse := 0.5 + 0.5 * sin(_t * 6.0)
		draw_arc(Vector2.ZERO, 46.0 + pulse * 3.0, 0.0, TAU, 40, Color(1.0, 0.85, 0.4, 0.9), 3.5)
		draw_arc(Vector2.ZERO, 40.0, 0.0, TAU, 40, Color(1.0, 0.85, 0.4, 0.35), 2.0)

	# ground shadow (draw_ellipse removed: not present in Godot 4.4.1)
	var shadow_pts := PackedVector2Array()
	for si in 24:
		var sa := TAU * si / 24.0
		shadow_pts.append(Vector2(cos(sa) * 24.0, sin(sa) * 7.0))
	draw_colored_polygon(shadow_pts, Color(0, 0, 0, 0.25))

	# body
	draw_circle(Vector2(0, 6), 16.0, body)
	draw_rect(Rect2(-14, -6, 28, 26), body)

	# head
	draw_circle(Vector2(0, -26), 13.0, skin)

	# eyes
	draw_circle(Vector2(-5, -27), 2.2, ink)
	draw_circle(Vector2(5, -27), 2.2, ink)

	# hat / ghost veil
	if is_ghost:
		# wispy head veil
		draw_arc(Vector2(0, -34), 12.0, PI, TAU, 12, Color(0.8, 0.9, 1.0, 0.5 * body.a), 2.5)
		# wispy lower body
		for i in range(3):
			var wob := sin(_t * 3.0 + i * 1.4) * 4.0
			draw_arc(Vector2(-10 + i * 10 + wob * 0.4, 26), 9.0, PI, TAU, 10,
					Color(body.r, body.g, body.b, 0.3 * body.a), 2.0)
	else:
		# simple cap
		draw_arc(Vector2(0, -38), 10.0, PI, TAU, 16, body, 4.0)
		draw_circle(Vector2(0, -44), 5.0, body)
