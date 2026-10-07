# CpuSearchController.gd — Deterministic CPU search sweep (slice 3, R6)
#
# When the GHOST is the active searcher (EV_GAME_SEARCH_PHASE_STARTED with
# searcher = GHOST_ENTITY_ID), the visible NPC walks a simple greedy sweep
# through the PLAYER zone: head to the nearest still-hidden NON-SNEAK player
# chalk line, strike it when within the strike radius (visible WipeEffect — the
# defending player watches), then repeat. No target left = the phase can
# early-exit (the SoloMatchDriver owns that decision).
#
# Slice 4 (defender argue + sneak):
#   - ARGUE STALL: EV_GAME_DEFENDER_ARGUE_STARTED with target_searcher_id ==
#     GHOST_ENTITY_ID (the human defender argues/distracts) freezes the sweep
#     for stall_seconds (chalk_gaon/solo_argue_stall_seconds) so the CPU
#     misses lines while it is distracted.
#   - SNEAK NOTICE: sneak lines the defender draws during the CPU's phase are
#     NOT sweep targets (the sweep plan only contains non-sneak lines). The
#     FIRST time the sweep passes within NOTICE_RADIUS of a still-unresolved
#     sneak line the CPU rolls notice ONCE per line: with
#     chalk_gaon/cpu_sneak_notice_chance (default -1.0 -> per-difficulty
#     table: EASY 0.15 / NORMAL 0.35 / HARD 0.60 / NIGHTMARE 0.85) it emits
#     EV_GAME_SNEAK_NOTICED and applies the penalty — the sneak line is struck
#     out AND up to PENALTY_EXTRA_STRIKES nearby non-sneak defender lines are
#     auto-struck (the CPU "re-checks" the area). Unnoticed sneak lines remain
#     active and count as surviving lines at scoring. When the sweep plan ends,
#     leftover unresolved sneak lines each get one final roll (the CPU circles
#     back) so off-path sneaks stay risky, capped at one penalty.
#     The chance is read LIVE from ProjectSettings at each roll so the smoke
#     test / a settings screen can force it (1.0 / 0.0).
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
## Sneak-notice proximity: the CPU notices a sneak line only while sweeping
## within this radius of the line's center (once per line per phase).
const NOTICE_RADIUS := 170.0
## Pause after a NOTICED penalty so the defender sees the strikes.
const NOTICE_PAUSE_SECONDS := 0.6
## Auto-strike radius around a noticed sneak line for the extra penalty lines.
const PENALTY_RADIUS := 240.0
## How many existing defender lines the penalty strikes besides the sneak.
const PENALTY_EXTRA_STRIKES := 2
## Per-difficulty notice chance when chalk_gaon/cpu_sneak_notice_chance == -1.0.
const DIFFICULTY_NOTICE := {
	0: 0.15,  # EASY — rarely catches sneaks
	1: 0.35,  # NORMAL
	2: 0.60,  # HARD
	3: 0.85,  # NIGHTMARE — almost always catches them
}

var _active: bool = false
var _npc: CharacterBody2D = null
var _draw_sys: DrawSystem = null
var _current_target: ChalkLine = null
var _pause_timer: float = 0.0
var _sweep_speed: float = DEFAULT_SWEEP_SPEED
## Sneak line ids still waiting for a notice roll this CPU phase.
var _unresolved_sneaks: Dictionary = {}
## Per-difficulty notice chance cached at phase start (live override wins).
var _sneak_notice_chance: float = -1.0

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	var world := get_tree().current_scene as Node2D
	if world:
		var systems: Node = world.get_node_or_null("Systems")
		if systems:
			_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
		if _draw_sys and world.has_method("get_entity"):
			_npc = world.get_entity(GHOST_ENTITY_ID) as CharacterBody2D
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.on(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.off(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)


## Sweep speed + notice chance are read at every CPU phase start so tests and
## a future settings screen can override them at runtime.
func _read_settings() -> void:
	_sweep_speed = float(ProjectSettings.get_setting("chalk_gaon/cpu_sweep_speed", DEFAULT_SWEEP_SPEED))
	_sneak_notice_chance = _resolve_notice_chance()
	if _npc:
		_npc.set_meta("move_speed", _sweep_speed)


## -1.0 (default) resolves to the per-difficulty table; >= 0 uses the setting.
func _resolve_notice_chance() -> float:
	var setting := float(ProjectSettings.get_setting("chalk_gaon/cpu_sneak_notice_chance", -1.0))
	if setting >= 0.0:
		return setting
	return float(DIFFICULTY_NOTICE.get(GameState.cpu_difficulty, 0.35))


# ── Event handlers ───────────────────────────────────────────────────────────

func _on_search_phase_started(payload: Dictionary) -> void:
	_active = int(payload.get("searcher", -1)) == GHOST_ENTITY_ID
	_current_target = null
	_pause_timer = 0.0
	_unresolved_sneaks.clear()
	if not _active:
		return
	_read_settings()
	for line in _draw_sys.get_active_lines() if _draw_sys else []:
		if line.is_sneak and not line.is_struck:
			_unresolved_sneaks[line.id] = true


func _on_search_phase_ended(_payload: Dictionary) -> void:
	_active = false
	_current_target = null
	_unresolved_sneaks.clear()


## The defender argues (distract): the CPU's sweep freezes for stall_seconds.
## Only while the CPU is the active searcher and the argue targets the CPU.
func _on_defender_argue_started(payload: Dictionary) -> void:
	if not _active:
		return
	if int(payload.get("target_searcher_id", -1)) != GHOST_ENTITY_ID:
		return
	var stall: float = float(payload.get("stall_seconds", 3.0))
	_pause_timer = maxf(_pause_timer, stall)
	print("CpuSearchController: distracted by argue — sweep stalls %.1fs" % stall)


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
			_check_leftover_sneaks()
			return  # no lines left — the driver's early-exit / timer ends the phase
	_check_sneak_notices()
	var center := _center_of(_current_target.points)
	_walk_to(center)
	if _npc.global_position.distance_to(center) <= STRIKE_RADIUS:
		var target: ChalkLine = _current_target
		_current_target = null
		if _draw_sys.strike_line(target.id):
			_pause_timer = STRIKE_PAUSE_SECONDS  # let the defender watch the wipe
		else:
			_pause_timer = 0.15  # line vanished under us (decay) — re-pick


## Greedy nearest-first over NON-SNEAK lines only: the sweep plan fixes the
## lines the CPU will strike. Sneak lines drawn mid-sweep are never targeted;
## they are only ever caught by the one-shot probabilistic notice roll.
func _pick_target() -> void:
	var best: ChalkLine = null
	var best_d := INF
	for line in _draw_sys.get_active_lines():
		if line.is_sneak or line.is_struck or line.points.size() < 2:
			continue
		var d := _npc.global_position.distance_squared_to(_center_of(line.points))
		if d < best_d:
			best_d = d
			best = line
	_current_target = best


## One notice roll per unresolved sneak line, rolled the FIRST time the sweep
## passes within NOTICE_RADIUS of its center. Noticed → penalty; unnoticed →
## the line stays active and counts at scoring.
func _check_sneak_notices() -> void:
	if _unresolved_sneaks.is_empty():
		return
	var npc_pos: Vector2 = _npc.global_position
	for line_id in _unresolved_sneaks.keys():
		var line: ChalkLine = _find_line(int(line_id))
		if line == null or line.is_struck:
			_unresolved_sneaks.erase(line_id)
			continue
		if npc_pos.distance_to(_center_of(line.points)) > NOTICE_RADIUS:
			continue
		_unresolved_sneaks.erase(line_id)  # resolved — rolled ONCE, pass or fail
		if randf() < _resolve_notice_chance():
			_apply_notice_penalty(line)


## NOTICED: emit the event, strike the sneak line, then auto-strike up to
## PENALTY_EXTRA_STRIKES nearest non-sneak defender lines inside
## PENALTY_RADIUS. Pause so the defender sees the wipe.
func _apply_notice_penalty(sneak_line: ChalkLine) -> void:
	var penalized: Array = [sneak_line.id]
	var center := _center_of(sneak_line.points)
	_draw_sys.strike_line(sneak_line.id)
	var near: Array = []
	for line in _draw_sys.get_active_lines():
		if line.is_sneak or line.is_struck:
			continue
		if _center_of(line.points).distance_to(center) <= PENALTY_RADIUS:
			near.append(line)
	near.sort_custom(func(a: ChalkLine, b: ChalkLine) -> bool:
		return _center_of(a.points).distance_squared_to(center) < _center_of(b.points).distance_squared_to(center))
	for i in range(mini(PENALTY_EXTRA_STRIKES, near.size())):
		if _draw_sys.strike_line(near[i].id):
			penalized.append(near[i].id)
	EventBus.emit(EventBus.EV_GAME_SNEAK_NOTICED, {
		"line_id": sneak_line.id,
		"position": center,
		"notice_chance": _resolve_notice_chance(),
		"difficulty": GameState.cpu_difficulty,
		"penalty_line_ids": penalized,
	})
	_pause_timer = NOTICE_PAUSE_SECONDS
	print("CpuSearchController: NOTICED sneak line %d — penalty lines %s" % [sneak_line.id, str(penalized)])


## Sweep plan finished: the CPU circles back once. Every leftover unresolved
## sneak line gets a single notice roll; at most one penalty fires per sweep
## end so the moment stays readable.
func _check_leftover_sneaks() -> void:
	if _unresolved_sneaks.is_empty():
		return
	var pending: Array = _unresolved_sneaks.keys()
	_unresolved_sneaks.clear()
	for line_id in pending:
		var line: ChalkLine = _find_line(int(line_id))
		if line == null or line.is_struck:
			continue
		if randf() < _resolve_notice_chance():
			_apply_notice_penalty(line)
			return


func _walk_to(target: Vector2) -> void:
	_npc.set_meta("target_position", target)
	_npc.set_meta("has_target", true)
	var sm: Node = _npc.get_node_or_null("EntityStateMachine")
	if sm and sm.has_method("current_state_name") and sm.current_state_name() != "walking":
		sm.transition_to("walking")


func _find_line(line_id: int) -> ChalkLine:
	for line in _draw_sys.get_active_lines():
		if line.id == line_id:
			return line
	return null


static func _center_of(points: Array[Vector2]) -> Vector2:
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size()) if points.size() > 0 else Vector2.ZERO
