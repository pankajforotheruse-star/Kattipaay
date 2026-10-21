# Pool.gd — Lightweight object pooling for CHALK GAON: Ghost Lines
#
# Android optimization (Prompt 16): the highest-churn objects in the game are
# Line2D visuals (chalk strokes + ghost lines) and one-shot feedback nodes
# (tutorial bursts). Every stroke previously allocated and freed a Line2D node
# plus its per-line ShaderMaterial; pooled, a stroke reuses a pre-warmed node
# and only re-configures it. Public behavior of the consuming systems is
# unchanged — pool clients call acquire()/release() where they used to call
# new()/queue_free().
#
# Design:
#   - RefCounted, so it lives exactly as long as its owning system.
#   - acquire() pops the most recently released instance (LIFO — the hottest
#     cache line); falls back to the factory when the pool is empty.
#   - Released instances stay parented to their container but hidden — no
#     add_child/remove_child churn, no per-frame allocation.
#   - reset_line2d() resets every property the line systems touch, so a
#     recycled node can never leak stale state into a new stroke.
class_name Pool
extends RefCounted

## Factory used to create fresh instances when the pool is empty.
var _factory: Callable

## Available (free) instances, LIFO.
var _free: Array = []


## Create a pool. `factory` is a Callable returning a new instance
## (e.g. `func() -> Line2D: return Line2D.new()`). Pre-warming allocates
## `prewarm` instances up front so steady-state churn is zero.
func _init(factory: Callable, prewarm: int = 0) -> void:
	_factory = factory
	for i in prewarm:
		_free.append(factory.call())


## Take an instance. If the pool is empty (or a pooled instance was freed
## behind our back — e.g. its parent scene was unloaded), a fresh one is made.
func acquire() -> Object:
	while not _free.is_empty():
		var obj: Object = _free.pop_back()
		if is_instance_valid(obj):
			return obj
	return _factory.call()


## Return an instance to the pool. The caller must have already reset it
## (see reset_line2d) and should leave it hidden — it stays in the scene
## tree, ready to be re-parented by the next acquire().
func release(obj: Object) -> void:
	_free.append(obj)


## Reset a Line2D node to a clean, hidden state ready for reuse.
static func reset_line2d(ln: Line2D) -> void:
	ln.clear_points()
	ln.width = 4.0
	ln.default_color = Color.WHITE
	ln.visible = false
	ln.modulate = Color.WHITE
	ln.material = null
	ln.position = Vector2.ZERO
	ln.rotation = 0.0
	ln.scale = Vector2.ONE
	ln.z_index = 0
	ln.name = "PooledLine2D"
