# MatchTimer.gd — Match countdown timer singleton for CHALK GAON
#
# Tracks match time as a countdown. Starts when match enters DRAWING or
# SEARCHING states. Emits tick events every second and an expired event
# when the timer hits zero. Supports pause/resume for argument mechanics
# and add/remove_time for penalty adjustments.
#
# Match Duration Config:
#   QUICK:    180s (3 minutes)
#   STANDARD: 480s (8 minutes)
#   ENDLESS:  -1   (no timer)

extends Node

# ── Duration Config ───────────────────────────────────────────────────────────

const MATCH_DURATIONS: Dictionary = {
	"quick":    180,
	"standard": 480,
	"endless":  -1,
}

# ── State ─────────────────────────────────────────────────────────────────────

var _remaining_seconds: float = 0.0
var _total_seconds: float = 0.0
var _is_running: bool = false
var _is_paused: bool = false
var _tick_accumulator: float = 0.0
var _last_emitted_second: int = -1
var _current_duration_key: String = "standard"
var _is_endless: bool = false

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.on("match.state_changed", _on_match_state_changed)
	print("MatchTimer: ready")

func _process(delta: float) -> void:
	if not _is_running or _is_paused or _is_endless:
		return

	_remaining_seconds -= delta

	# Clamp to zero
	if _remaining_seconds <= 0.0:
		_remaining_seconds = 0.0
		_is_running = false
		EventBus.emit("game.timer_expired", {
			"total_seconds": _total_seconds,
		})
		return

	# Emit tick every whole-second boundary
	var current_second := int(ceil(_remaining_seconds))
	if current_second != _last_emitted_second:
		_last_emitted_second = current_second
		EventBus.emit("game.timer_tick", {
			"remaining_seconds": current_second,
			"total_seconds": int(_total_seconds),
		})

# ── Public API ────────────────────────────────────────────────────────────────

## Start the timer with a duration key ("quick", "standard", "endless").
func start(duration_key: String = "standard") -> void:
	_current_duration_key = duration_key
	var duration: int = MATCH_DURATIONS.get(duration_key, 480)

	if duration <= 0:
		_is_endless = true
		_is_running = false
		_total_seconds = -1
		_remaining_seconds = -1
		print("MatchTimer: endless mode — no countdown")
		return

	_is_endless = false
	_total_seconds = float(duration)
	_remaining_seconds = float(duration)
	_last_emitted_second = duration
	_is_running = true
	_is_paused = false
	_tick_accumulator = 0.0

	EventBus.emit("game.timer_tick", {
		"remaining_seconds": duration,
		"total_seconds": duration,
	})
	print("MatchTimer: started — %ds (%s)" % [duration, duration_key])

## Pause the countdown (e.g., during argument phase).
func pause() -> void:
	if not _is_running or _is_paused:
		return
	_is_paused = true
	EventBus.emit("game.timer_paused", {
		"remaining_seconds": int(ceil(_remaining_seconds)),
	})
	print("MatchTimer: paused at %ds" % int(ceil(_remaining_seconds)))

## Resume the countdown.
func resume() -> void:
	if not _is_running or not _is_paused:
		return
	_is_paused = false
	_last_emitted_second = int(ceil(_remaining_seconds))
	EventBus.emit("game.timer_resumed", {
		"remaining_seconds": _last_emitted_second,
	})
	print("MatchTimer: resumed at %ds" % _last_emitted_second)

## Add time (e.g., bonus seconds). Clamped to total duration.
func add_time(seconds: float) -> void:
	if _is_endless:
		return
	_remaining_seconds = min(_remaining_seconds + seconds, _total_seconds)
	_last_emitted_second = int(ceil(_remaining_seconds))
	EventBus.emit("game.timer_tick", {
		"remaining_seconds": _last_emitted_second,
		"total_seconds": int(_total_seconds),
	})
	print("MatchTimer: +%ds → %ds remaining" % [int(seconds), _last_emitted_second])

## Remove time (penalty). Clamped to zero — won't go negative.
func remove_time(seconds: float) -> void:
	if _is_endless:
		return
	_remaining_seconds = max(_remaining_seconds - seconds, 0.0)
	_last_emitted_second = int(ceil(_remaining_seconds))
	EventBus.emit("game.timer_penalty", {
		"amount": int(seconds),
		"remaining_seconds": _last_emitted_second,
		"total_seconds": int(_total_seconds),
	})
	if _remaining_seconds <= 0.0:
		_is_running = false
		EventBus.emit("game.timer_expired", {
			"total_seconds": int(_total_seconds),
		})
	print("MatchTimer: -%ds penalty → %ds remaining" % [int(seconds), _last_emitted_second])

## Stop the timer completely (e.g., match ends).
func stop() -> void:
	_is_running = false
	_is_paused = false
	print("MatchTimer: stopped")

## Reset the timer to its configured duration but don't start.
func reset(duration_key: String = "") -> void:
	if duration_key != "":
		_current_duration_key = duration_key
	var duration: int = MATCH_DURATIONS.get(_current_duration_key, 480)
	_is_running = false
	_is_paused = false
	_is_endless = (duration <= 0)
	_total_seconds = float(duration) if not _is_endless else -1.0
	_remaining_seconds = float(duration) if not _is_endless else -1.0
	_last_emitted_second = duration if not _is_endless else -1
	_tick_accumulator = 0.0
	print("MatchTimer: reset to %d" % duration)

# ── Queries ───────────────────────────────────────────────────────────────────

func get_remaining_seconds() -> int:
	return int(ceil(_remaining_seconds)) if not _is_endless else -1

func get_total_seconds() -> int:
	return int(_total_seconds) if not _is_endless else -1

func is_running() -> bool:
	return _is_running

func is_paused() -> bool:
	return _is_paused

func is_endless() -> bool:
	return _is_endless

# ── Event Handlers ────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var to_state: int = payload.get("to", -1)

	# Start timer on DRAWING or SEARCHING
	if to_state == GameState.MatchState.DRAWING or to_state == GameState.MatchState.SEARCHING:
		if not _is_running:
			start(_current_duration_key)

	# Pause on match-level PAUSED
	elif to_state == GameState.MatchState.PAUSED:
		pause()

	# Resume when exiting PAUSED
	var from_state: int = payload.get("from", -1)
	if from_state == GameState.MatchState.PAUSED:
		resume()
