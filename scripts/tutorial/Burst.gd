# Burst.gd — One-shot expanding ring burst used for tutorial feedback
# (success, ghost-line discovery, target selection). Pure _draw() + time;
# no assets, no text.
#
# Pooled (Prompt 16): bursts live ~0.55 s and can fire in rapid succession
# during tutorial celebrations, so nodes are recycled instead of freed —
# spawn() acquires from a static pool, _process() releases back into it.
class_name TutorialBurst
extends Node2D

const DURATION := 0.55

## Pre-warmed bursts in the static pool.
const POOL_PREWARM := 4

## Static pool of idle (hidden, unprocessed) burst nodes.
static var _pool: Array[TutorialBurst] = []

var _color := Color(1.0, 0.9, 0.6, 1.0)
var _max_radius := 60.0
var _t := 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		_release_to_pool()


## Return this burst to the pool: stop processing and hide. The node stays
## parented (no add/remove churn). If its parent scene is unloaded while the
## node is pooled, the node is freed with it — the pool's acquire path checks
## instance validity and creates a fresh burst instead.
func _release_to_pool() -> void:
	set_process(false)
	visible = false
	_pool.append(self)


func _draw() -> void:
	var k := minf(_t / DURATION, 1.0)
	var r := _max_radius * (0.2 + 0.8 * ease(k, 0.35))
	var alpha := (1.0 - k) * 0.9
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(_color.r, _color.g, _color.b, alpha), 3.0)
	draw_circle(Vector2.ZERO, 2.0 + 6.0 * (1.0 - k), Color(_color.r, _color.g, _color.b, alpha * 0.8))


## Convenience: spawn a burst as a child of `parent` at `pos`.
static func spawn(parent: Node, pos: Vector2, color: Color, max_radius: float = 60.0) -> void:
	_prewarm_pool()
	var b: TutorialBurst = _acquire_from_pool()
	b.position = pos
	b._color = color
	b._max_radius = max_radius
	b._t = 0.0
	b.visible = true
	b.set_process(true)
	if b.get_parent() != parent:
		parent.add_child(b)


## Warm the pool once with hidden, unparented nodes (parented on first spawn).
static func _prewarm_pool() -> void:
	if _pool.is_empty():
		for i in POOL_PREWARM:
			_pool.append(TutorialBurst.new())


## Pop a live burst from the pool, or create a fresh one if empty/stale.
static func _acquire_from_pool() -> TutorialBurst:
	while not _pool.is_empty():
		var b: TutorialBurst = _pool.pop_back()
		if is_instance_valid(b):
			return b
	return TutorialBurst.new()
