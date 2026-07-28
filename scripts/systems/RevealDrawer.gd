# RevealDrawer.gd — Draws vision circles into the SubViewport's reveal texture
#
# Lives inside the RevealViewport SubViewport owned by FogSystem.
# Each call to _draw() renders all active and explored reveal circles
# as concentric radial gradients — white circles where the player can see,
# gray circles for previously-explored areas.
#
# Performance: uses draw_circle() with step-based gradient (no texture
# allocations). Coordinates are world-space; the SubViewport's Camera2D
# maps them to the texture.

class_name RevealDrawer
extends Node2D

## Number of concentric circles per reveal entry for gradient approximation.
const GRADIENT_STEPS := 16

## Inner solid core radius as fraction of total radius (0.0–1.0).
const SOLID_CORE_FRACTION := 0.3

# --- State ---

## Reveal entries queued for the next redraw.
## Each entry: { position: Vector2, radius: float, is_active: bool }
var _entries: Array[Dictionary] = []


func _draw() -> void:
	for entry in _entries:
		var pos: Vector2 = entry["position"]
		var radius: float = entry["radius"]
		var is_active: bool = entry.get("is_active", true)
		var base_color := Color.WHITE if is_active else Color(0.5, 0.5, 0.5, 1.0)
		_draw_radial_gradient(pos, radius, base_color)


## Draw a filled circle with radial gradient: solid core, fading to transparent edge.
## Uses concentric draw_circle() calls — no texture allocations, GPU-friendly.
func _draw_radial_gradient(center: Vector2, radius: float, color: Color) -> void:
	if radius <= 0.0:
		return

	# Solid inner core
	var core_radius := radius * SOLID_CORE_FRACTION
	if core_radius > 1.0:
		draw_circle(center, core_radius, color)

	# Gradient rings: core → edge
	var outer_start := core_radius
	var outer_range := radius - outer_start
	if outer_range <= 0.0:
		return

	for i in range(GRADIENT_STEPS):
		var t := float(i) / float(GRADIENT_STEPS)
		var r := outer_start + outer_range * (1.0 - t)
		var alpha := (1.0 - t) * color.a * 0.7  # accumulate to approximate smooth falloff
		var ring_color := Color(color.r, color.g, color.b, alpha)
		draw_circle(center, r, ring_color)

	# Final faint outer ring for anti-aliasing feel
	draw_circle(center, radius, Color(color.r, color.g, color.b, color.a * 0.05))


# --- Public API ---

## Queue a reveal circle for the next redraw.
## is_active=true draws white (active vision), false draws gray (explored memory).
func add_reveal(position: Vector2, radius: float, is_active: bool = true) -> void:
	_entries.append({
		"position": position,
		"radius": radius,
		"is_active": is_active,
	})


## Remove entries of the given type.
## @param active_only — if true, only clears active (white) entries, keeping explored.
##                      if false, clears everything.
func clear_entries(active_only: bool = false) -> void:
	if active_only:
		var kept: Array[Dictionary] = []
		for entry in _entries:
			if not entry.get("is_active", true):
				kept.append(entry)
		_entries = kept
	else:
		_entries.clear()


## Whether any entries are queued.
func has_entries() -> bool:
	return not _entries.is_empty()
