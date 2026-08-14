# LobbyManager.gd — Lobby + room-code layer (Prompt 17, item 1)
#
# Responsibilities:
#   - create a lobby → 6-char room code (Nakama match create with custom
#     match_id; collision-tolerant retry)
#   - join a lobby by room code
#   - maintain the player list (name, is_host, ready state) locally
#   - leave / close a lobby
#
# The class is transport-agnostic: every transport operation is delegated to
# MatchSession (real Nakama REST/WS, simulated server, or offline fallback).
# The UI never talks to this class directly — it goes through NetworkManager
# and listens to EV_NET_LOBBY_* events (see EventBus.gd).

class_name LobbyManager
extends Node

const ROOM_CODE_LENGTH := 6
# No confusable characters (no I/L/O/0/1). 31^6 ≈ 887M codes.
const ROOM_CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const MAX_ROOM_CODE_ATTEMPTS := 5
const MAX_PLAYERS := 6

## Current room code ("" when not in a lobby).
var room_code := ""
## Whether THIS device created (and therefore hosts) the lobby.
var is_host := false

## Player roster keyed by session id: { id, name, is_host, ready }.
var _players: Dictionary = {}

var _session: MatchSession = null  # injected by NetworkManager
var _my_player_id := -1

# Async (HTTP_WS) lobby-create state — the transport answers via
# _on_async_create_result / _on_async_join_result.
var _pending_create_attempts := 0
var _pending_create_name := ""
var _pending_join_code := ""


func _ready() -> void:
	randomize()


## Inject the transport owner (called by NetworkManager).
func setup(session: MatchSession, my_player_id: int) -> void:
	_session = session
	_my_player_id = my_player_id


# ── Public API (UI hook points) ───────────────────────────────────────────

## Create a lobby. Returns the room code, or "" on failure (after
## MAX_ROOM_CODE_ATTEMPTS collision retries). In HTTP_WS mode the create
## is asynchronous (returns "" immediately); the real outcome arrives via
## EV_NET_LOBBY_CREATED — the UI must listen for that event either way.
func create_lobby(display_name: String) -> String:
	if _session == null:
		push_error("LobbyManager: no MatchSession injected")
		return ""
	if room_code != "":
		push_warning("LobbyManager: already in lobby %s — leaving first" % room_code)
		leave_lobby()
	var display := display_name.strip_edges()
	if display.is_empty():
		display = "Player"
	_pending_create_attempts = 0
	_pending_create_name = display
	return _try_create(display)

## One create attempt with collision retry. Recursion depth ≤ 5.
func _try_create(display: String) -> String:
	var code := _generate_room_code()
	var result := _session.create_match(code)
	if result == MatchSession.CreateResult.OK:
		room_code = code
		is_host = true
		_register_self(display, true)
		EventBus.emit(EventBus.EV_NET_LOBBY_CREATED, {"room_code": code, "ok": true})
		print("LobbyManager: lobby created — code %s" % code)
		return code
	if result == MatchSession.CreateResult.CODE_TAKEN:
		# Collision — retry with a fresh code.
		_pending_create_attempts += 1
		if _pending_create_attempts < MAX_ROOM_CODE_ATTEMPTS:
			return _try_create(display)
		EventBus.emit(EventBus.EV_NET_LOBBY_CREATED, {"room_code": "", "ok": false, "reason": "collisions"})
		return ""
	if result == MatchSession.CreateResult.PENDING:
		# HTTP_WS: server will confirm asynchronously.
		return ""
	EventBus.emit(EventBus.EV_NET_LOBBY_CREATED, {"room_code": "", "ok": false, "reason": "error"})
	push_warning("LobbyManager: could not create lobby (result %d)" % result)
	return ""

## Async completion of a create request (HTTP_WS transport).
func _on_async_create_result(code: String, ok: bool, reason := "") -> void:
	if not ok and reason == "code_taken" and _pending_create_attempts < MAX_ROOM_CODE_ATTEMPTS - 1:
		_pending_create_attempts += 1
		_try_create(_pending_create_name)
		return
	if ok:
		room_code = code
		is_host = true
		_register_self(_pending_create_name, true)
		EventBus.emit(EventBus.EV_NET_LOBBY_CREATED, {"room_code": code, "ok": true})
		print("LobbyManager: lobby created — code %s" % code)
	else:
		EventBus.emit(EventBus.EV_NET_LOBBY_CREATED, {"room_code": code, "ok": false, "reason": reason})
		push_warning("LobbyManager: create failed (%s)" % reason)

## Join an existing lobby by room code. Returns true on success.
## In HTTP_WS mode the join is asynchronous (returns false immediately);
## the real outcome arrives via EV_NET_LOBBY_JOINED.
func join_lobby(code: String) -> bool:
	if _session == null:
		push_error("LobbyManager: no MatchSession injected")
		return false
	if room_code != "":
		leave_lobby()
	var normalized := code.strip_edges().to_upper()
	if normalized.length() != ROOM_CODE_LENGTH:
		EventBus.emit(EventBus.EV_NET_LOBBY_JOINED, {"room_code": code, "ok": false, "reason": "bad_format"})
		return false
	var result := _session.join_match(normalized)
	if result == MatchSession.JoinResult.OK:
		room_code = normalized
		is_host = false
		_register_self(_self_display_name(), false)  # audit M14: mirror the create path
		EventBus.emit(EventBus.EV_NET_LOBBY_JOINED, {"room_code": normalized, "ok": true})
		print("LobbyManager: joined lobby %s" % normalized)
		return true
	if result == MatchSession.JoinResult.PENDING:
		_pending_join_code = normalized
		return false
	var reason := "not_found"
	if result == MatchSession.JoinResult.FULL:
		reason = "full"
	elif result == MatchSession.JoinResult.TIMEOUT:
		reason = "timeout"
	EventBus.emit(EventBus.EV_NET_LOBBY_JOINED, {"room_code": normalized, "ok": false, "reason": reason})
	return false

## Async completion of a join request (HTTP_WS transport).
func _on_async_join_result(code: String, ok: bool, reason := "") -> void:
	if ok:
		room_code = code
		is_host = false
		_register_self(_self_display_name(), false)  # audit M14: self must be in _players for set_ready()
		EventBus.emit(EventBus.EV_NET_LOBBY_JOINED, {"room_code": code, "ok": true})
		print("LobbyManager: joined lobby %s" % code)
	else:
		EventBus.emit(EventBus.EV_NET_LOBBY_JOINED, {"room_code": code, "ok": false, "reason": reason})
		push_warning("LobbyManager: join failed (%s)" % reason)

## Leave the current lobby (or close it if this device is the host).
func leave_lobby() -> void:
	if room_code == "":
		return
	if is_host and _session != null:
		_session.close_match(room_code)
		EventBus.emit(EventBus.EV_NET_LOBBY_CLOSED, {"room_code": room_code, "reason": "host_left"})
	elif _session != null:
		_session.leave_match(room_code)
	EventBus.emit(EventBus.EV_NET_LOBBY_LEFT, {"room_code": room_code})
	room_code = ""
	is_host = false
	_players.clear()


## Toggle this device's ready state. Returns false if not in a lobby.
func set_ready(ready: bool) -> bool:
	if room_code == "" or _my_player_id < 0:
		return false
	if not _players.has(_my_player_id):
		return false
	_players[_my_player_id]["ready"] = ready
	if _session != null:
		_session.broadcast_ready(_my_player_id, ready)
	EventBus.emit(EventBus.EV_NET_LOBBY_PLAYER_READY, {"player_id": _my_player_id, "ready": ready})
	return true


## Host-only: start the match when everyone is ready (or force-start).
## Returns false if this device is not the host.
func start_match() -> bool:
	if room_code == "":
		return false
	if not is_host:
		EventBus.emit(EventBus.EV_NET_ACTION_REJECTED, {"action": "match.start", "reason": "not_host"})
		return false
	if _session != null:
		_session.broadcast_match_start()
	return true


## Snapshot of the roster for UI rendering.
func get_players() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _players:
		out.append(_players[id].duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("id", 0)) < int(b.get("id", 0)))
	return out

func get_player_count() -> int:
	return _players.size()


# ── Roster maintenance (fed by MatchSession presence events) ──────────────

## Display name used when registering self after a join (mirrors the
## create path's _pending_create_name; audit M14).
func _self_display_name() -> String:
	if _session != null and not _session.player_name.is_empty():
		return _session.player_name
	return "Player"

func _register_self(display_name: String, host: bool) -> void:
	if _my_player_id < 0:
		return
	_players[_my_player_id] = {
		"id": _my_player_id,
		"name": display_name,
		"is_host": host,
		"ready": false,
	}

func _on_player_joined(player: Dictionary) -> void:
	var pid: int = int(player.get("id", -1))
	if pid < 0 or _players.has(pid):
		return
	_players[pid] = {
		"id": pid,
		"name": str(player.get("name", "Player")),
		"is_host": bool(player.get("is_host", false)),
		"ready": false,
	}
	EventBus.emit(EventBus.EV_NET_LOBBY_PLAYER_JOINED, {"player": _players[pid].duplicate()})
	print("LobbyManager: player %d joined" % pid)

func _on_player_left(player_id: int) -> void:
	if not _players.has(player_id):
		return
	_players.erase(player_id)
	EventBus.emit(EventBus.EV_NET_LOBBY_PLAYER_LEFT, {"player_id": player_id})

func _on_player_ready(player_id: int, ready: bool) -> void:
	if _players.has(player_id):
		_players[player_id]["ready"] = ready
	EventBus.emit(EventBus.EV_NET_LOBBY_PLAYER_READY, {"player_id": player_id, "ready": ready})

## Called by NetworkManager when the transport reports a full lobby state
## (join, reconnect, host transfer).
func _apply_snapshot(state: Dictionary) -> void:
	var players: Array = state.get("players", [])
	_players.clear()
	for p in players:
		var pid: int = int(p.get("id", -1))
		if pid < 0:
			continue
		_players[pid] = {
			"id": pid,
			"name": str(p.get("name", "Player")),
			"is_host": bool(p.get("is_host", false)),
			"ready": bool(p.get("ready", false)),
		}
	print("LobbyManager: snapshot applied — %d players" % _players.size())


# ── Helpers ───────────────────────────────────────────────────────────────

func _generate_room_code() -> String:
	var code := ""
	for i in ROOM_CODE_LENGTH:
		code += ROOM_CODE_ALPHABET[randi() % ROOM_CODE_ALPHABET.length()]
	return code
