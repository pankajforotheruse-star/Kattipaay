# ScoringManager.gd — Central scoring system for CHALK GAON: Ghost Lines
# Autoload singleton. Tracks per-round and total scores, applies scoring formula,
# determines winners, and persists statistics via SaveManager.
extends Node

# ── Scoring Formula Constants ─────────────────────────────────────────────
const BASE_LINE_POINTS := 10
const CLUSTER_BONUS_PER_LINE := 5       # on top of base, making cluster lines worth 15
const GHOST_DRAW_PENALTY := 5           # per discovered ghost line
const FALSE_ACCUSATION_PENALTY := 10
const HINT_TRAP_PENALTY := 10           # searcher fell for fake hint
const CORRECT_HINT_BONUS := 10          # searcher correctly identified real hint
const SILENT_SNEAK_BONUS := 20          # successful silent sneak line crossing

# ── State ─────────────────────────────────────────────────────────────────
var total_score: int = 0
var round_scores: Dictionary = {}        # {round_number: score}
var round_breakdowns: Dictionary = {}    # {round_number: Dictionary}
var current_round: int = 0
var winner_id: int = -1

# Per-round accumulators (reset each DRAWING phase)
var _lines_drawn: int = 0
var _cluster_lines_surviving: int = 0
var _ghost_lines_discovered: int = 0
var _false_accusations: int = 0
var _hint_traps_triggered: int = 0
var _correct_hints: int = 0
var _sloppy_count_delta: int = 0
var _silent_sneaks: int = 0

# Persistent stats
var _stats: Dictionary = {
	"games_played": 0,
	"wins": 0,
	"total_score_accumulated": 0,
	"best_round_score": 0,
	"total_rounds_played": 0,
	"last_played_timestamp": 0
}

var _all_player_scores: Dictionary = {}  # {player_id: total_score}

func _ready() -> void:
	_subscribe_events()
	_load_statistics()

func _subscribe_events() -> void:
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_GAME_SLOPPY_COUNT_RESULT, _on_sloppy_count_result)
	EventBus.on(EventBus.EV_GAME_ARGUMENT_RESOLVED, _on_argument_resolved)
	EventBus.on(EventBus.EV_GAME_HINT_TRAP_TRIGGERED, _on_hint_trap_triggered)
	EventBus.on(EventBus.EV_GAME_HINT_INVESTIGATED, _on_hint_investigated)
	EventBus.on(EventBus.EV_GAME_GHOST_DRAW_PENALTY, _on_ghost_draw_penalty)
	EventBus.on(EventBus.EV_GAME_CLUSTER_SURVIVED, _on_cluster_survived)
	EventBus.on(EventBus.EV_GAME_CLUSTER_FAILED, _on_cluster_failed)
	EventBus.on(EventBus.EV_GAME_SILENT_SNEAK_LINE_CROSSED, _on_silent_sneak_crossed)
	EventBus.on(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)

# ── Event Handlers ────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var to_state: int = payload.get("to", -1)
	var from_state: int = payload.get("from", -1)
	
	match to_state:
		GameState.MatchState.DRAWING:
			_reset_round_accumulators()
		GameState.MatchState.SCORING:
			current_round += 1
			_calculate_round_score()
		GameState.MatchState.WINNER:
			_determine_winner()
		GameState.MatchState.RETURN_TO_LOBBY:
			_save_statistics()

func _on_sloppy_count_result(payload: Dictionary) -> void:
	_sloppy_count_delta = payload.get("score_delta", 0)

func _on_argument_resolved(payload: Dictionary) -> void:
	var is_true: bool = payload.get("is_true", true)
	if not is_true:
		_false_accusations += 1

func _on_hint_trap_triggered(_payload: Dictionary) -> void:
	_hint_traps_triggered += 1

func _on_hint_investigated(_payload: Dictionary) -> void:
	_correct_hints += 1

func _on_ghost_draw_penalty(_payload: Dictionary) -> void:
	_ghost_lines_discovered += 1

func _on_cluster_survived(payload: Dictionary) -> void:
	var line_count: int = payload.get("line_count", 0)
	_cluster_lines_surviving += line_count

func _on_cluster_failed(_payload: Dictionary) -> void:
	# No bonus — cluster didn't survive
	pass

func _on_silent_sneak_crossed(_payload: Dictionary) -> void:
	_silent_sneaks += 1

# ── Round Calculation ─────────────────────────────────────────────────────

func _reset_round_accumulators() -> void:
	_lines_drawn = 0
	_cluster_lines_surviving = 0
	_ghost_lines_discovered = 0
	_false_accusations = 0
	_hint_traps_triggered = 0
	_correct_hints = 0
	_sloppy_count_delta = 0
	_silent_sneaks = 0

func register_line_drawn() -> void:
	_lines_drawn += 1
## EventBus handler: count only the local player's own chalk lines.
func _on_line_drawn(payload: Dictionary) -> void:
	if payload.get("player_id", -1) != InputManager.local_entity_id:
		return
	register_line_drawn()

func _calculate_round_score() -> void:
	var score := 0
	var breakdown := {
		"lines_drawn": _lines_drawn,
		"lines_score": _lines_drawn * BASE_LINE_POINTS,
		"cluster_lines": _cluster_lines_surviving,
		"cluster_bonus": _cluster_lines_surviving * CLUSTER_BONUS_PER_LINE,
		"ghost_penalty": _ghost_lines_discovered * GHOST_DRAW_PENALTY,
		"argument_penalty": _false_accusations * FALSE_ACCUSATION_PENALTY,
		"hint_trap_penalty": _hint_traps_triggered * HINT_TRAP_PENALTY,
		"correct_hint_bonus": _correct_hints * CORRECT_HINT_BONUS,
		"sloppy_count_delta": _sloppy_count_delta,
		"silent_sneak_bonus": _silent_sneaks * SILENT_SNEAK_BONUS
	}
	
	# Apply formula
	score += breakdown.lines_score
	score += breakdown.cluster_bonus
	score -= breakdown.ghost_penalty
	score -= breakdown.argument_penalty
	score -= breakdown.hint_trap_penalty
	score += breakdown.correct_hint_bonus
	score += breakdown.sloppy_count_delta
	score += breakdown.silent_sneak_bonus
	
	# Clamp to minimum 0
	score = maxi(score, 0)
	
	# Store
	round_scores[current_round] = score
	round_breakdowns[current_round] = breakdown
	total_score += score
	
	# Update persistent stats
	if score > _stats.best_round_score:
		_stats.best_round_score = score
	_stats.total_rounds_played += 1
	_stats.total_score_accumulated += score
	
	# Emit events
	EventBus.emit(EventBus.EV_GAME_ROUND_SCORE_CALCULATED, {
		"round_number": current_round,
		"score": score,
		"breakdown": breakdown
	})
	EventBus.emit(EventBus.EV_GAME_TOTAL_SCORE_UPDATED, {
		"total_score": total_score,
		"round_number": current_round
	})

# ── Winner Determination ───────────────────────────────────────────────────

func register_player_score(player_id: int, score: int) -> void:
	_all_player_scores[player_id] = score

func _determine_winner() -> void:
	# Use registered player scores if available, otherwise use local total
	var best_id := -1
	var best_score := -1
	
	if _all_player_scores.is_empty():
		# Single player / prototype mode
		winner_id = 1  # local player
		_stats.wins += 1
	else:
		for pid in _all_player_scores:
			var s: int = _all_player_scores[pid]
			if s > best_score:
				best_score = s
				best_id = pid
		winner_id = best_id
		if winner_id == 1:  # local player won
			_stats.wins += 1
	
	EventBus.emit(EventBus.EV_GAME_WINNER_DETERMINED, {
		"winner_id": winner_id,
		"final_score": best_score if best_score >= 0 else total_score,
		"all_scores": _all_player_scores,
		"total_score": total_score
	})

# ── Persistence ────────────────────────────────────────────────────────────

func _save_statistics() -> void:
	_stats.last_played_timestamp = Time.get_unix_time_from_system()
	SaveManager.save_local("player_statistics", _stats)

func _load_statistics() -> void:
	var saved = SaveManager.load_local("player_statistics", {})
	if saved is Dictionary and not saved.is_empty():
		_stats = saved

# ── Public API ─────────────────────────────────────────────────────────────

func get_total_score() -> int:
	return total_score

func get_round_score(round_num: int) -> int:
	return round_scores.get(round_num, 0)

func get_current_round() -> int:
	return current_round

func get_round_breakdown(round_num: int) -> Dictionary:
	return round_breakdowns.get(round_num, {})

func get_winner_id() -> int:
	return winner_id

func get_statistics() -> Dictionary:
	return _stats.duplicate()

func reset_match() -> void:
	total_score = 0
	round_scores.clear()
	round_breakdowns.clear()
	current_round = 0
	winner_id = -1
	_all_player_scores.clear()
	_reset_round_accumulators()
	EventBus.emit(EventBus.EV_GAME_TOTAL_SCORE_UPDATED, {"total_score": 0, "round_number": 0})
