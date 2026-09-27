# CpuSearchController.gd — Deterministic CPU search sweep (slice 3, R6)
#
# When the GHOST is the active searcher (EV_GAME_SEARCH_PHASE_STARTED with
# searcher = GHOST_ENTITY_ID), the visible NPC walks a simple greedy sweep
# through the PLAYER zone: head to the nearest still-hidden player chalk line,
# strike it when within the strike radius (visible WipeEffect — the defending
# player watches), then repeat. No target left = the phase can early-exit (the
# SoloMatchDriver owns that decision).
#
# Deliberately simple per the R6 scope note ("simple deterministic sweep — do
# NOT over-engineer AI"): difficulty-driven search tuning is a LATER slice.
#
# Spawned by the SoloMatchDriver (solo mode only) as a child node.

class_name CpuSearchController
extends Node

const GHOST_ENTITY_ID := 2
const DEFAULT_SWEEP_SPEED := 420.0
## Strike radius around each line's center (world pixels).
const STRIKE_RADIUS := 120.0
## Short pause after each strike so the defender sees the wipe.
const STRIKE_PAUSE_SECONDS := 0.8

var _active: bool = false
var _npc: CharacterBody2D = null
var _draw_sys: DrawSystem = null
var _current_target: ChalkLine = null
var _pause_timer: float = 0.0
var _sweep_speed: float = DEFAULT_SWEEP_SPEED

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_sweep_speed = float(ProjectSettings.get_setting("chalk_gaon/cpu_sweep_speed", DEFAULT_SWEEP_SPEED))
	var world := get_tree().current_scene as Node2D
	if world:
		var systems: Node = world.get_node_or_null("Systems")
		if systems:
			_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
		if _draw_sys and world.has_method("get_entity"):
			_npc = world.get_entity(GHOST_ENTITY_ID) as CharacterBody2D
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)


# ── Event handlers ───────────────────────────────────────────────────────────

func _on_search_phase_started(payload: Dictionary) -> void:
	_active = int(payload.get("searcher", -1)) == GHOST_ENTITY_ID
	_current_target = null
	_pause_timer = 0.0
	if _active and _npc:
		_npc.set_meta("move_speed", _sweep_speed)


func _on_search_phase_ended(_payload: Dictionary) -> void:
	_active = false
	_current_target = null


# ── Sweep ────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _active or _npc == null or _draw_sys == null:
		return
	if _pause_timer > 0.0:
		_pause_timer -= delta
		return
	if _current_target == null or not is_instance_valid(_current_target):
		_pick_target()
		if _current_target == null:
			return  # no lines left — the driver's early-exit / timer ends the phase
	var center := _center_of(_current_target.points)
	_walk_to(center)
	if _npc.global_position.distance_to(center) <= STRIKE_RADIUS:
		var target: ChalkLine = _current_target
		_current_target = null
		if _draw_sys.strike_line(target.id):
			_pause_timer = STRIKE_PAUSE_SECONDS  # let the defender watch the wipe
		else:
			_pause_timer = 0.15  # line vanished under us (decay) — re-pick


## Greedy nearest-first: the closest still-hidden player line is the next
## sweep target. Deterministic and simple — no search-AI tuning (R11).
func _pick_target() -> void:
	var best: ChalkLine = null
	var best_d := INF
	for line in _draw_sys.get_active_lines():
		if line.is_struck or line.points.size() < 2:
			continue
		var d := _npc.global_position.distance_squared_to(_center_of(line.points))
		if d < best_d:
			best_d = d
			best = line
	_current_target = best


func _walk_to(target: Vector2) -> void:
	_npc.set_meta("target_position", target)
	_npc.set_meta("has_target", true)
	var sm: Node = _npc.get_node_or_null("EntityStateMachine")
	if sm and sm.has_method("current_state_name") and sm.current_state_name() != "walking":
		sm.transition_to("walking")


static func _center_of(points: Array[Vector2]) -> Vector2:
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size()) if points.size() > 0 else Vector2.ZERO