# Burst.gd — One-shot expanding ring burst used for tutorial feedback
# (success, ghost-line discovery, target selection). Pure _draw() + time;
# no assets, no text.
class_name TutorialBurst
extends Node2D

const DURATION := 0.55

var _color := Color(1.0, 0.9, 0.6, 1.0)
var _max_radius := 60.0
var _t := 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	var k := minf(_t / DURATION, 1.0)
	var r := _max_radius * (0.2 + 0.8 * ease(k, 0.35))
	var alpha := (1.0 - k) * 0.9
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(_color.r, _color.g, _color.b, alpha), 3.0)
	draw_circle(Vector2.ZERO, 2.0 + 6.0 * (1.0 - k), Color(_color.r, _color.g, _color.b, alpha * 0.8))


## Convenience: spawn a burst as a child of `parent` at `pos`.
static func spawn(parent: Node, pos: Vector2, color: Color, max_radius: float = 60.0) -> void:
	var b := TutorialBurst.new()
	b.position = pos
	b._color = color
	b._max_radius = max_radius
	parent.add_child(b)
