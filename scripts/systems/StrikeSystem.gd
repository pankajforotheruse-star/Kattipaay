# StrikeSystem.gd — Live strike-out of hidden lines during the solo search phases
#
# Slice 3 (R6) core: during SEARCHING the ACTIVE SEARCHER wipes out the
# defender's hidden chalk lines. Striking = REMOVAL with the WipeEffect
# animation (meeting-phase-plan.md R6): the struck line is wiped away, removed
# from the world (is_struck set, Line2D released, entry dropped from the active
# array) and only "surviving" unstruck lines count at the end of the round.
#
# Two directions:
#   - HUMAN search: every tap (EV_INPUT_MOVE_START) near an eligible ghost line
#     strikes it (near-tap radius HUMAN_STRIKE_RADIUS). The tap also still moves
#     the player — walk up to a line and tap it to wipe it.
#   - CPU search: the CpuSearchController calls strike_player_line() — the same
#     removal path with the same WipeEffect + live counter.
#
# The live remaining-lines counter reads the active (unstruck) line arrays of
# GhostDrawSystem / DrawSystem — struck lines are removed from those arrays, so
# get_remaining_lines() is exact.
#
# Spawned by the SoloMatchDriver (solo mode only) as a child node.

class_name StrikeSystem
extends Node

## Near-tap radius for the human searcher (world pixels; generous for mobile).
const HUMAN_STRIKE_RADIUS := 90.0

var _game_world: Node2D = null
var _ghost_sys: GhostDrawSystem = null
var _draw_sys: DrawSystem = null

## True between SEARCH_PHASE_STARTED and SEARCH_PHASE_ENDED.
var _active: bool = false
## True when the HUMAN is the active searcher (so taps strike ghost lines).
var _human_is_searcher: bool = false
## Human strikes muffled for this many seconds (CPU defends + argues).
var _argue_muffled: float = 0.0
## One-shot per phase: the bot argues at most once while it defends.
var _cpu_argue_checked: bool = true
var _arg_sys: ArgumentSystem = null

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_game_world = get_tree().current_scene as Node2D
	if _game_world:
		var systems: Node = _game_world.get_node_or_null("Systems")
		if systems:
			_ghost_sys = systems.get_node_or_null("GhostDrawSystem") as GhostDrawSystem
			_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
	_arg_sys = systems.get_node_or_null("ArgumentSystem") as ArgumentSystem
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.on(EventBus.EV_INPUT_MOVE_START, _on_input_move_start)
	EventBus.on(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_ENDED, _on_search_phase_ended)
	EventBus.off(EventBus.EV_INPUT_MOVE_START, _on_input_move_start)
	EventBus.off(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, _on_defender_argue_started)


# ── Event handlers ───────────────────────────────────────────────────────────

func _on_search_phase_started(payload: Dictionary) -> void:
	_active = true
	_human_is_searcher = int(payload.get("searcher", -1)) == 1
	_argue_muffled = 0.0
	_cpu_argue_checked = false


func _on_search_phase_ended(_payload: Dictionary) -> void:
	_active = false
	_human_is_searcher = false


func _on_input_move_start(payload: Dictionary) -> void:
	if not _active or not _human_is_searcher:
		return
	if _argue_muffled > 0.0:
		return  # muffled by the CPU's argue
	var screen_pos: Vector2 = payload.get("screen_position", Vector2.ZERO)
	try_strike_at(InputManager.screen_to_world(screen_pos), HUMAN_STRIKE_RADIUS)


func _process(delta: float) -> void:
	if _argue_muffled > 0.0:
		_argue_muffled = maxf(_argue_muffled - delta, 0.0)
	if not _active or _human_is_searcher or _cpu_argue_checked:
		return
	_cpu_argue_checked = true
	if _arg_sys == null or _arg_sys.has_argued(2):
		return
	# The bot argues once while IT defends (the human searches its zone),
	# with chalk_gaon/cpu_argue_chance (read live for tests/tuning).
	if randf() < float(ProjectSettings.get_setting("chalk_gaon/cpu_argue_chance", 0.5)):
		_arg_sys.request_defender_argue(2)


## The CPU defender argues: the human searcher's strikes are muffled
## for stall_seconds (miss everything while the bot distracts).
func _on_defender_argue_started(payload: Dictionary) -> void:
	if not _active or not _human_is_searcher:
		return
	if int(payload.get("target_searcher_id", -1)) != 1:
		return
	_argue_muffled = float(payload.get("stall_seconds", 3.0))
	print("StrikeSystem: CPU argues — human strikes muffled for %.1fs" % _argue_muffled)


# ── Public API ───────────────────────────────────────────────────────────────

## Remaining hidden lines in the zone being searched (the live counter).
func get_remaining_lines() -> int:
	if not _active:
		return 0
	if _human_is_searcher:
		return _ghost_sys.get_active_ghost_lines().size() if _ghost_sys else 0
	return _draw_sys.get_active_lines().size() if _draw_sys else 0


## Strike the closest eligible ghost line within `radius` of `world_pos`
## (the human's near-tap). Returns true if a line was struck.
func try_strike_at(world_pos: Vector2, radius: float) -> bool:
	if not _active or not _human_is_searcher or not _ghost_sys:
		return false
	var best: ChalkLine = null
	var best_d := radius * radius
	for line in _ghost_sys.get_active_ghost_lines():
		var d := _point_segment_distance_sq(world_pos, line.points)
		if d <= best_d:
			best_d = d
			best = line
	if best == null:
		return false
	return strike_ghost_line(best.id)


## Strike a ghost line by id (human tap path; online RPC seam lands here too).
func strike_ghost_line(line_id: int) -> bool:
	if not _ghost_sys:
		return false
	var ok := _ghost_sys.strike_ghost_line(line_id)
	if ok:
		EventBus.emit(EventBus.EV_NETWORK_CHALK_LINE_STRUCK, {
			"line_id": line_id,
			"is_ghost": true,
		})
	return ok


## Strike a player line by id (the CPU's search sweep).
func strike_player_line(line_id: int) -> bool:
	if not _draw_sys:
		return false
	var ok := _draw_sys.strike_line(line_id)
	if ok:
		EventBus.emit(EventBus.EV_NETWORK_CHALK_LINE_STRUCK, {
			"line_id": line_id,
			"is_ghost": false,
		})
	return ok


# ── Helpers ─────────────────────────────────────────────────────────────────

## Minimum distance (squared) between `p` and any segment of `points`.
static func _point_segment_distance_sq(p: Vector2, points: Array[Vector2]) -> float:
	if points.is_empty():
		return INF
	if points.size() == 1:
		return p.distance_squared_to(points[0])
	var best := INF
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var closest := a + ab * t
		best = minf(best, closest.distance_squared_to(p))
	return best