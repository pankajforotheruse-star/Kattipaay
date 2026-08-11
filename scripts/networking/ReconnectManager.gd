# ReconnectManager.gd — Session resume, auto-reconnect with backoff, and
# match rejoin by room code + reconnect token (Prompt 17, item 3).
#
# Flow (documented in docs/networking.md §9):
#   1. Session credentials are persisted via SaveManager under "net_session":
#      { device_id, auth_token, refresh_token, user_id, last_room_code,
#        reconnect_token }
#   2. On connection loss → schedule reconnect with exponential backoff
#      (1s, 2s, 4s, 8s, 16s, 30s max, ±20% jitter), capped at
#      MAX_RECONNECT_ATTEMPTS.
#   3. On reconnect: MatchSession authenticates (refresh token preferred,
#      falls back to device auth) and rejoins last_room_code with
#      MSG_RECONNECT {code, reconnect_token} → host/server replies RESYNC
#      with the full authoritative snapshot.
#   4. Failure after all attempts → EV_NET_RECONNECT_FAILED → offline fallback.

class_name ReconnectManager
extends Node

const SAVE_KEY := "net_session"
const BASE_BACKOFF := 1.0
const BACKOFF_MULTIPLIER := 2.0
const MAX_BACKOFF := 30.0
const JITTER_RATIO := 0.2
const MAX_RECONNECT_ATTEMPTS := 5

var _attempt := 0
var _wait_seconds := 0.0
var _countdown := 0.0
var _pending := false
var _session: MatchSession = null


func _ready() -> void:
	pass


## Inject transport owner (called by NetworkManager).
func setup(session: MatchSession) -> void:
	_session = session


# ── Persistence (via existing SaveManager) ────────────────────────────────

## Persist the current Nakama session so a later launch can resume.
func persist_session(data: Dictionary) -> void:
	var merged: Dictionary = load_session()
	for k in data:
		merged[k] = data[k]
	SaveManager.save_local(SAVE_KEY, merged)


## Load the last persisted session. Empty dict when none / corrupt.
func load_session() -> Dictionary:
	return SaveManager.load_local(SAVE_KEY, {})


## Clear persisted session (logout / forced reset).
func clear_session() -> void:
	SaveManager.save_local(SAVE_KEY, {})


# ── Reconnect cycle ───────────────────────────────────────────────────────

## Call when the connection drops. Starts the backoff cycle.
func on_connection_lost() -> void:
	if _pending:
		return
	_attempt = 0
	_pending = true
	_wait_seconds = BASE_BACKOFF
	_countdown = _jittered(_wait_seconds)
	EventBus.emit(EventBus.EV_NET_RECONNECTING, {"attempt": _attempt + 1, "delay": _countdown})
	print("ReconnectManager: connection lost — first retry in %.1fs" % _countdown)


## Immediately attempt one reconnect (used on app foreground / explicit retry).
func try_now() -> void:
	_pending = true
	_attempt = 0
	_attempt_reconnect()


func cancel() -> void:
	_pending = false
	_countdown = 0.0


func is_pending() -> bool:
	return _pending


func _process(delta: float) -> void:
	if not _pending or _session == null:
		return
	_countdown -= delta
	if _countdown > 0.0:
		return
	_attempt_reconnect()


func _attempt_reconnect() -> void:
	if _attempt >= MAX_RECONNECT_ATTEMPTS:
		_pending = false
		EventBus.emit(EventBus.EV_NET_RECONNECT_FAILED, {"attempts": _attempt})
		push_warning("ReconnectManager: gave up after %d attempts" % _attempt)
		return
	_attempt += 1
	var data := load_session()
	if data.is_empty():
		# Nothing to resume — a fresh session would be needed.
		_pending = false
		EventBus.emit(EventBus.EV_NET_RECONNECT_FAILED, {"attempts": _attempt, "reason": "no_session"})
		return
	EventBus.emit(EventBus.EV_NET_RECONNECTING, {"attempt": _attempt, "delay": 0.0})
	print("ReconnectManager: attempt %d/%d" % [_attempt, MAX_RECONNECT_ATTEMPTS])
	var ok := _session.resume_and_rejoin(data)
	if ok:
		_pending = false
		EventBus.emit(EventBus.EV_NET_RECONNECTED, {"room_code": data.get("last_room_code", "")})
		print("ReconnectManager: reconnected to %s" % data.get("last_room_code", ""))
	else:
		# Schedule the next attempt with growing backoff.
		_wait_seconds = mini(_wait_seconds * BACKOFF_MULTIPLIER, MAX_BACKOFF)
		_countdown = _jittered(_wait_seconds)
		print("ReconnectManager: attempt failed — next in %.1fs" % _countdown)


func _jittered(seconds: float) -> float:
	var jitter := seconds * JITTER_RATIO
	return maxf(0.1, seconds + randf_range(-jitter, jitter))
