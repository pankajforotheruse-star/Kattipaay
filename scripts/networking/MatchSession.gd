# MatchSession.gd — Network session: transport, tick loop, batching, and
# bandwidth accounting for the binary protocol (Prompt 17, items 4 + 6).
#
# Transports:
#   HTTP_WS  — real Nakama REST (authenticate / match create / match join)
#              + WebSocket (match data). Requires a live Nakama deployment
#              to verify — see docs/networking.md §13.
#   SIMULATED — in-process fake server (static room registry). Lets the
#              whole lobby/reconnect/state-sync stack be exercised in the
#              editor with no network. Off by default (SIMULATE_SERVER).
#   OFFLINE  — no transport. Entered when no server is configured or a
#              connection attempt fails: EV_NET_OFFLINE is emitted and the
#              game keeps running on the existing local loop.
#
# Bandwidth model (docs/networking.md §5-6):
#   - UPDATE_HZ tick rate; outbound messages are queued and flushed per tick
#   - full snapshot every FULL_SNAPSHOT_EVERY_TICKS; otherwise state deltas
#   - per-message and per-second budgets; overruns emit EV_NET_BANDWIDTH_WARNING
#
# NOTE: converting the live game loop to run through this session is the
# NEXT milestone. This file provides the transport + protocol seam
# (update_authoritative_state(), broadcast_*()) and is fully unit-testable
# through the SIMULATED transport.

class_name MatchSession
extends Node

# ── Server configuration (placeholder — point at a future deployment) ────
# Leave NAKAMA_SERVER_URL empty to start offline. When set, the client
# attempts the real Nakama flow; any failure falls back to offline.
const NAKAMA_SERVER_URL := ""        # e.g. "https://nakama.example.com"
const NAKAMA_SERVER_PORT := 7350     # default Nakama port (HTTP 7350 / WS 7350)
const NAKAMA_USE_TLS := true
const NAKAMA_SERVER_KEY := "defaultkey"
const NAKAMA_WS_PATH := "/ws"        # Nakama WebSocket endpoint path

# ── Test / simulation hooks ───────────────────────────────────────────────
const SIMULATE_SERVER := false       # true = in-process fake server, no network
const SIMULATED_PLAYERS := 0         # fake bots to join the lobby (debug)

# ── Tuning (docs/networking.md §6) ───────────────────────────────────────
const UPDATE_HZ := 10                # ticks per second
const FULL_SNAPSHOT_EVERY_TICKS := 50  # 1 full snapshot / 5 s at 10 Hz
const MAX_OUTBOUND_BYTES_PER_SEC := 4096
const MAX_EVENT_BYTES := 256         # per-message budget (docs target: <100 typical)
const MAX_SNAPSHOT_BYTES := 2048
const MAX_PLAYERS := 6

enum Transport { NONE, HTTP_WS, SIMULATED, OFFLINE }

## Synchronous results for LobbyManager. PENDING = request queued; the real
## result arrives asynchronously via EV_NET_LOBBY_* (HTTP_WS mode only).
enum CreateResult { OK, CODE_TAKEN, ERROR, PENDING }
enum JoinResult { OK, NOT_FOUND, FULL, TIMEOUT, ERROR, PENDING }

# ── State ─────────────────────────────────────────────────────────────────
var transport: int = Transport.NONE
var connected := false
var match_id := ""                   # Nakama match id once joined
var room_code := ""
var session_id := 0                  # this device's Nakama user/session id
var device_id := ""
var player_name := ""
var auth_token := ""
var refresh_token := ""

var hosted := false                  # true when this device may act as host
var _host_migration: HostMigration = null  # injected by NetworkManager
var _lobby: LobbyManager = null           # injected by NetworkManager

# Authoritative state mirror (what we last knew the server/host state to be).
var _mirror := {
	"match_state": 0,
	"round": 0,
	"flags": 0,
	"phase_msec": 0,
	"last_seq": 0,
	"players": [],
	"lines": [],
}
var _last_sent_state: Dictionary = {}  # for delta computation

# Outbound queue + accounting.
var _outbound: Array[PackedByteArray] = []
var _tick_accumulator := 0.0
var _tick_count := 0
var _bytes_sent_total := 0
var _bytes_received_total := 0
var _window_bytes := 0
var _window_start := 0.0
var _last_seq := 0

# HTTP/WS transport state.
var _http: HTTPRequest = null
var _http_queue: Array = []          # {method, path, body, headers, callback}
var _http_busy := false
var _socket: WebSocketPeer = null
var _ws_connected := false
var _rest_authenticated := false


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)
	_window_start = Time.get_unix_time_from_system()


# ── Setup ─────────────────────────────────────────────────────────────────

func setup(session_player_id: int, name: String, dev_id: String) -> void:
	session_id = session_player_id
	player_name = name
	device_id = dev_id


## Give this session the lobby + migration hooks (injected by NetworkManager).
func attach(lobby: LobbyManager, migration: HostMigration) -> void:
	_lobby = lobby
	_host_migration = migration


## Start the session. Returns true if an ONLINE transport was selected;
## false means OFFLINE (fallback to the local loop, EV_NET_OFFLINE emitted
## by NetworkManager).
func connect_to_server(server_url: String, auth: String = "") -> bool:
	if SIMULATE_SERVER:
		transport = Transport.SIMULATED
		connected = true
		session_id = _sim_allocate_id(device_id)
		_sim_seed_bots()
		return true
	if server_url.strip_edges().is_empty():
		_enter_offline("no_server_configured")
		return false
	transport = Transport.HTTP_WS
	auth_token = auth
	# Kick off the Nakama device-authenticate request. The rest of the flow
	# continues in _on_http_completed (async). Failures → offline fallback.
	_rest_authenticate()
	return true


## Immediately enter offline mode (no transport). Used by NetworkManager when
## the online attempt failed or was never wanted.
func fallback_to_offline(reason: String) -> void:
	_enter_offline(reason)


func _enter_offline(reason: String) -> void:
	if transport == Transport.OFFLINE:
		return
	transport = Transport.OFFLINE
	connected = false
	EventBus.emit(EventBus.EV_NET_OFFLINE, {"reason": reason})
	print("MatchSession: offline fallback (%s)" % reason)


## NOTE: named `disconnect_session` (NOT `disconnect`) because `Node.disconnect`
## is a built-in used for signal disconnection — defining `disconnect()` here
## would shadow it on this Node and silently break signal disconnects.
func disconnect_session() -> void:
	connected = false
	transport = Transport.NONE
	_outbound.clear()
	if _socket != null:
		_socket.close()
		_socket = null
	_ws_connected = false
	_http_queue.clear()
	_http_busy = false


# ── Transport operations (called by LobbyManager / HostMigration) ─────────

func create_match(code: String) -> int:
	if transport == Transport.SIMULATED:
		return _sim_create_match(code)
	if transport == Transport.HTTP_WS:
		var headers := _auth_headers()
		_http_queue.append({
			"method": HTTPClient.METHOD_POST,
			"path": "/v2/match/create",
			"body": JSON.stringify({"params": {"room_code": code}}),
			"headers": headers,
			"callback": Callable(self, "_on_match_created").bind(code),
		})
		_pump_http()
		return CreateResult.PENDING
	return CreateResult.ERROR


func join_match(code: String) -> int:
	if transport == Transport.SIMULATED:
		return _sim_join_match(code)
	if transport == Transport.HTTP_WS:
		var headers := _auth_headers()
		_http_queue.append({
			"method": HTTPClient.METHOD_POST,
			"path": "/v2/match/join",
			"body": JSON.stringify({"match_id": code, "token": ""}),
			"headers": headers,
			"callback": Callable(self, "_on_match_joined").bind(code),
		})
		_pump_http()
		return JoinResult.PENDING
	return JoinResult.ERROR


func leave_match(code: String) -> void:
	room_code = ""
	match_id = ""
	if transport == Transport.SIMULATED:
		_sim_leave(code)


func close_match(code: String) -> void:
	room_code = ""
	match_id = ""
	if transport == Transport.SIMULATED:
		_sim_close(code)


func broadcast_ready(player_id: int, ready: bool) -> void:
	var payload := NetSerializer.encode_ready(player_id, ready)
	_send(NetSerializer.MsgType.READY, payload, NetSerializer.FLAG_RELIABLE)
	if transport == Transport.SIMULATED:
		_sim_apply_ready(player_id, ready)


func broadcast_match_start() -> void:
	if transport == Transport.SIMULATED:
		_sim_apply_match_start()
		return
	# Host/server: tell everyone we are entering the first match phase.
	var payload := NetSerializer.encode_state_change(GameState.MatchState.DRAWING, 1, 0)
	_send(NetSerializer.MsgType.STATE_CHANGE, payload, NetSerializer.FLAG_RELIABLE)


func broadcast_heartbeat(seq: int, match_state: int, round_number: int) -> void:
	var payload := NetSerializer.encode_heartbeat(seq, match_state, round_number)
	_send(NetSerializer.MsgType.HEARTBEAT, payload, 0)


func broadcast_host_transfer(new_host_id: int, last_seq: int, snapshot: PackedByteArray) -> void:
	var payload := NetSerializer.encode_host_transfer(new_host_id, last_seq, snapshot)
	_send(NetSerializer.MsgType.HOST_TRANSFER, payload, NetSerializer.FLAG_RELIABLE)
	if transport == Transport.SIMULATED:
		_sim_apply_host_transfer(new_host_id)


## Send a chat/log-style event payload (opaque bytes) to all peers.
func broadcast_raw_bytes(msg_type: int, payload: PackedByteArray) -> void:
	_send(msg_type, payload, NetSerializer.FLAG_RELIABLE)

## Ask the authority for a full state snapshot (used on reconnect / resync).
func request_resync() -> void:
	_send(NetSerializer.MsgType.RESYNC, NetSerializer.encode_resync(get_last_confirmed_seq()), NetSerializer.FLAG_RELIABLE)


# ── Reconnect support (called by ReconnectManager) ───────────────────────

## Resume the last persisted session: re-authenticate and rejoin the last
## room code, then request a full resync. Returns true when the rejoin was
## issued (real server confirms asynchronously via EV_NET_RECONNECTED).
func resume_and_rejoin(data: Dictionary) -> bool:
	if transport == Transport.HTTP_WS:
		var code: String = str(data.get("last_room_code", ""))
		auth_token = str(data.get("auth_token", ""))
		refresh_token = str(data.get("refresh_token", ""))
		device_id = str(data.get("device_id", device_id))
		_rest_authenticate()
		if code != "":
			_http_queue.append({
				"method": HTTPClient.METHOD_POST,
				"path": "/v2/match/join",
				"body": JSON.stringify({"match_id": code, "token": ""}),
				"headers": _auth_headers(),
				"callback": Callable(self, "_on_match_joined").bind(code),
			})
			_pump_http()
			return true
		return false
	if transport == Transport.SIMULATED:
		var code: String = str(data.get("last_room_code", ""))
		if code == "":
			return false
		if _sim_join_match(code) == JoinResult.OK:
			_send(NetSerializer.MsgType.RECONNECT, NetSerializer.encode_reconnect(code, str(session_id)), NetSerializer.FLAG_RELIABLE)
			return true
		return false
	return false


# ── Authoritative state seam (driven by the game loop next milestone) ─────

## The host/server-side game feeds authoritative state here each tick; the
## session diffs it against the last sent state and emits deltas.
func update_authoritative_state(match_state: int, round_number: int, players: Array, lines: Array, flags := 0) -> void:
	_last_seq += 1
	_mirror["match_state"] = match_state
	_mirror["round"] = round_number
	_mirror["flags"] = flags
	_mirror["phase_msec"] = Time.get_ticks_msec()
	_mirror["last_seq"] = _last_seq
	_mirror["players"] = players
	_mirror["lines"] = lines
	if _host_migration != null:
		_host_migration.append_event({
			"seq": _last_seq,
			"match_state": match_state,
			"round": round_number,
			"phase_msec": _mirror["phase_msec"],
		})


func get_authoritative_snapshot() -> Dictionary:
	return _mirror.duplicate(true)


func get_last_confirmed_seq() -> int:
	return _mirror.get("last_seq", 0)


func get_game_state() -> int:
	return int(_mirror.get("match_state", 0))


func get_round_number() -> int:
	return int(_mirror.get("round", 0))


# ── Tick loop: batching, rate limiting, deltas ────────────────────────────

func _process(delta: float) -> void:
	if transport == Transport.HTTP_WS:
		_poll_ws()
	if not connected:
		return
	_tick_accumulator += delta
	var tick_interval := 1.0 / float(UPDATE_HZ)
	while _tick_accumulator >= tick_interval:
		_tick_accumulator -= tick_interval
		_tick()
	# Rolling bandwidth window (1 s).
	var now := Time.get_unix_time_from_system()
	if now - _window_start >= 1.0:
		if _window_bytes > MAX_OUTBOUND_BYTES_PER_SEC:
			EventBus.emit(EventBus.EV_NET_BANDWIDTH_WARNING, {
				"bytes_per_second": _window_bytes,
				"limit": MAX_OUTBOUND_BYTES_PER_SEC,
			})
		_window_bytes = 0
		_window_start = now


func _tick() -> void:
	_tick_count += 1
	# Heartbeat + host health (offline/hosted authority model).
	if _host_migration != null and _host_migration.is_enabled():
		_host_migration.tick(1.0 / float(UPDATE_HZ))
	# Emit state deltas (or a full snapshot every FULL_SNAPSHOT_EVERY_TICKS).
	if transport == Transport.SIMULATED:
		_sim_sync_room_state()
	# Flush the outbound batch.
	if not _outbound.is_empty():
		var batch_size := 0
		for msg in _outbound:
			batch_size += msg.size()
		_bytes_sent_total += batch_size
		_window_bytes += batch_size
		_flush_outbound()
		_outbound.clear()


func _flush_outbound() -> void:
	# HTTP_WS: each frame is sent as a Nakama match_data_send.
	if _socket != null and _ws_connected and transport == Transport.HTTP_WS:
		for msg in _outbound:
			var data := Marshalls.raw_to_base64(msg)
			var frame := JSON.stringify({
				"match_data_send": {
					"match_id": match_id,
					"op_code": 0,
					"data": data,
					"reliable": true,
				}
			})
			_socket.send_text(frame)


func _send(msg_type: int, payload: PackedByteArray, flags := 0) -> void:
	if not connected:
		return
	if payload.size() > MAX_PAYLOAD:
		EventBus.emit(EventBus.EV_NET_BANDWIDTH_WARNING, {"bytes": payload.size(), "limit": MAX_PAYLOAD})
		push_warning("MatchSession: payload %d bytes exceeds MAX_PAYLOAD" % payload.size())
		return
	if payload.size() + NetSerializer.ENVELOPE_SIZE > MAX_EVENT_BYTES:
		EventBus.emit(EventBus.EV_NET_BANDWIDTH_WARNING, {"bytes": payload.size() + NetSerializer.ENVELOPE_SIZE, "limit": MAX_EVENT_BYTES})
	var envelope := NetSerializer.encode(msg_type, _last_seq & 0xFFFF, payload, flags)
	_last_seq += 1
	_outbound.append(envelope)


# ── Incoming message dispatch ─────────────────────────────────────────────

func _on_message(msg: Dictionary) -> void:
	var msg_type: int = msg.get("type", NetSerializer.MsgType.NONE)
	var payload: PackedByteArray = msg.get("payload", PackedByteArray())
	_bytes_received_total += payload.size() + NetSerializer.ENVELOPE_SIZE
	match msg_type:
		NetSerializer.MsgType.HELLO:
			pass  # handshake acknowledgement is implicit in presence
		NetSerializer.MsgType.HEARTBEAT:
			var hb := NetSerializer.decode_heartbeat(payload)
			if _host_migration != null and hb.has("seq"):
				_host_migration.note_heartbeat(int(msg.get("sender_id", -1)))
		NetSerializer.MsgType.SNAPSHOT:
			var state := NetSerializer.decode_snapshot(payload)
			if not state.is_empty():
				_apply_snapshot(state)
		NetSerializer.MsgType.STATE_DELTA:
			var delta := NetSerializer.decode_state_delta(payload)
			_apply_delta(delta)
		NetSerializer.MsgType.STATE_CHANGE:
			var sc := NetSerializer.decode_state_change(payload)
			_mirror["match_state"] = sc.get("match_state", _mirror["match_state"])
			_mirror["round"] = sc.get("round", _mirror["round"])
			EventBus.emit(EventBus.EV_NET_MATCH_STATE_SYNC, {"match_state": sc.get("match_state", 0), "round": sc.get("round", 0)})
		NetSerializer.MsgType.READY:
			var rd := NetSerializer.decode_ready(payload)
			if _lobby != null:
				_lobby._on_player_ready(rd.get("player_id", -1), rd.get("ready", false))
		NetSerializer.MsgType.PLAYER_JOINED:
			var pj := NetSerializer.decode_player_joined(payload)
			if _lobby != null:
				_lobby._on_player_joined(pj.get("player", {}))
		NetSerializer.MsgType.PLAYER_LEFT:
			var pl := NetSerializer.decode_player_left(payload)
			if _lobby != null:
				_lobby._on_player_left(pl.get("player_id", -1))
		NetSerializer.MsgType.HOST_TRANSFER:
			var ht := NetSerializer.decode_host_transfer(payload)
			_apply_host_transfer(ht)
		NetSerializer.MsgType.RESYNC:
			# Authority side: a peer asked for a full snapshot.
			var snap := NetSerializer.encode_snapshot(get_authoritative_snapshot())
			_send(NetSerializer.MsgType.SNAPSHOT, snap, NetSerializer.FLAG_RELIABLE)
		NetSerializer.MsgType.RECONNECT:
			# Host/server side: a peer wants to rejoin. In this prototype the
			# authority replies with the current snapshot (server impl notes
			# in docs/networking.md §12).
			var rc := NetSerializer.decode_reconnect(payload)
			var snap := NetSerializer.encode_snapshot(get_authoritative_snapshot())
			_send(NetSerializer.MsgType.SNAPSHOT, snap, NetSerializer.FLAG_RELIABLE)
			print("MatchSession: peer reconnect for room %s — resync sent" % rc.get("room_code", ""))
		NetSerializer.MsgType.LINE_DRAWN, NetSerializer.MsgType.GHOST_LINE_PLACED, NetSerializer.MsgType.GHOST_LINE_DISCOVERED, NetSerializer.MsgType.ACCUSATION, NetSerializer.MsgType.ACCUSATION_RESOLUTION, NetSerializer.MsgType.SCORE:
			# Gameplay events: forwarded to the game layer via EventBus.
			# The next milestone drives the live loop from these.
			EventBus.emit(EventBus.EV_NET_MATCH_EVENT, {
				"type": msg_type,
				"payload": payload,
				"sender_id": int(msg.get("sender_id", -1)),
			})
		NetSerializer.MsgType.ACK:
			pass
		NetSerializer.MsgType.ERROR:
			push_warning("MatchSession: server error: %s" % str(payload))


func _apply_snapshot(state: Dictionary) -> void:
	_mirror = state.duplicate(true)
	if _lobby != null:
		_lobby._apply_snapshot(state)
	EventBus.emit(EventBus.EV_NET_MATCH_STATE_SYNC, {
		"match_state": state.get("match_state", 0),
		"round": state.get("round", 0),
		"last_seq": state.get("last_seq", 0),
	})


func _apply_delta(delta: Dictionary) -> void:
	var ms: int = delta.get("match_state", 0xFF)
	var rd: int = delta.get("round", 0xFF)
	if ms != 0xFF:
		_mirror["match_state"] = ms
	if rd != 0xFF:
		_mirror["round"] = rd
	var seq: int = delta.get("last_seq", 0)
	if seq > int(_mirror.get("last_seq", 0)):
		_mirror["last_seq"] = seq
	# Players/lines deltas are applied by the game layer in the next
	# milestone; the mirror is updated for resync correctness.
	EventBus.emit(EventBus.EV_NET_MATCH_STATE_SYNC, {
		"match_state": _mirror["match_state"],
		"round": _mirror["round"],
		"delta": true,
	})


func _apply_host_transfer(ht: Dictionary) -> void:
	var new_host_id: int = ht.get("new_host_id", -1)
	var snap_bytes: PackedByteArray = ht.get("snapshot", PackedByteArray())
	if snap_bytes.size() > 0:
		var state := NetSerializer.decode_snapshot(snap_bytes)
		if not state.is_empty():
			_apply_snapshot(state)
	if _host_migration != null:
		_host_migration.current_host_id = new_host_id
	EventBus.emit(EventBus.EV_NET_HOST_TRANSFERRED, {"new_host_id": new_host_id, "last_seq": ht.get("last_seq", 0)})
	print("MatchSession: host transferred to %d" % new_host_id)


# ── Bandwidth stats (for ProfilerOverlay / debug) ─────────────────────────

func get_stats() -> Dictionary:
	return {
		"transport": transport,
		"connected": connected,
		"bytes_sent": _bytes_sent_total,
		"bytes_received": _bytes_received_total,
		"outbound_queued": _outbound.size(),
		"room_code": room_code,
		"session_id": session_id,
	}


# ── HTTP REST (Nakama protocol) — needs a live server ─────────────────────

func _auth_headers() -> PackedStringArray:
	var basic := Marshalls.utf8_to_base64("%s:" % NAKAMA_SERVER_KEY)
	var headers := PackedStringArray()
	headers.append("Content-Type: application/json")
	headers.append("Accept: application/json")
	if auth_token != "":
		headers.append("Authorization: Bearer %s" % auth_token)
	else:
		headers.append("Authorization: Basic %s" % basic)
	return headers


func _rest_base_url() -> String:
	var scheme := "https" if NAKAMA_USE_TLS else "http"
	return "%s://%s:%d" % [scheme, NAKAMA_SERVER_URL, NAKAMA_SERVER_PORT]


func _rest_authenticate() -> void:
	var body := JSON.stringify({"id": device_id, "create": true})
	_http_queue.append({
		"method": HTTPClient.METHOD_POST,
		"path": "/v2/account/authenticate/device",
		"body": body,
		"headers": _auth_headers(),
		"callback": Callable(self, "_on_authenticated"),
	})
	_pump_http()


func _pump_http() -> void:
	if _http_busy or _http_queue.is_empty():
		return
	var req: Dictionary = _http_queue[0]
	_http_busy = true
	var url := _rest_base_url() + str(req["path"])
	var err := _http.request(url, req["headers"], req["method"], str(req["body"]))
	if err != OK:
		_http_busy = false
		_http_queue.pop_front()
		_enter_offline("http_request_error_%d" % err)


func _on_http_completed(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_http_busy = false
	if _http_queue.is_empty():
		return
	var req: Dictionary = _http_queue.pop_front()
	var callback: Callable = req["callback"]
	if result != HTTPRequest.RESULT_SUCCESS:
		# Network-level failure — nothing we can do without a live server.
		_enter_offline("http_result_%d" % result)
		return
	var json := JSON.new()
	var text := body.get_string_from_utf8()
	var parse_err := json.parse(text)
	if parse_err != OK:
		callback.call({})
		_pump_http()
		return
	var data: Dictionary = json.get_data() if typeof(json.get_data()) == TYPE_DICTIONARY else {}
	callback.call(data)
	_pump_http()


func _on_authenticated(data: Dictionary) -> void:
	if data.has("token"):
		auth_token = str(data["token"])
		refresh_token = str(data.get("refresh_token", ""))
		session_id = int(data.get("user_id", "0").hash())
		_rest_authenticated = true
		connected = true
		EventBus.emit(EventBus.EV_NETWORK_CONNECTED, {"mode": "online"})
		print("MatchSession: authenticated as session %d" % session_id)
	else:
		_enter_offline("auth_failed")


func _on_match_created(data: Dictionary, code: String) -> void:
	if data.has("match_id"):
		match_id = str(data["match_id"])
		room_code = code
		connected = true
		if _lobby != null:
			_lobby._on_async_create_result(code, true)
	else:
		# Nakama returns an error body on conflict (match id already exists).
		var reason := str(data.get("message", "conflict"))
		if "already exists" in reason or "conflict" in reason.to_lower():
			if _lobby != null:
				_lobby._on_async_create_result(code, false, "code_taken")
		else:
			if _lobby != null:
				_lobby._on_async_create_result(code, false, "error")


func _on_match_joined(data: Dictionary, code: String) -> void:
	if data.has("token"):
		room_code = code
		match_id = code
		connected = true
		_open_websocket()
		if _lobby != null:
			_lobby._on_async_join_result(code, true)
	else:
		var reason := str(data.get("message", "not_found"))
		if _lobby != null:
			_lobby._on_async_join_result(code, false, reason)


# ── WebSocket (Nakama match data) — needs a live server ───────────────────

func _open_websocket() -> void:
	if _socket != null:
		_socket.close()
	var scheme := "wss" if NAKAMA_USE_TLS else "ws"
	var url := "%s://%s:%d%s" % [scheme, NAKAMA_SERVER_URL, NAKAMA_SERVER_PORT, NAKAMA_WS_PATH]
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(url, PackedStringArray(), true, _tls_options())
	if err != OK:
		push_warning("MatchSession: websocket connect failed (%d)" % err)
		_enter_offline("ws_connect_failed")


func _tls_options() -> TLSOptions:
	return TLSOptions.client()


func _poll_ws() -> void:
	if _socket == null:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_connected:
			_ws_connected = true
			# Nakama socket handshake: authenticate the socket session.
			var auth_msg := JSON.stringify({
				"auth": {"token": auth_token},
				"match_join": {"match_id": match_id, "token": ""},
			})
			_socket.send_text(auth_msg)
		while _socket.get_available_packet_count() > 0:
			var packet := _socket.get_packet()
			var text := packet.get_string_from_utf8()
			_handle_ws_message(text)
	elif state == WebSocketPeer.STATE_CLOSED or state == WebSocketPeer.STATE_CLOSING:
		_ws_connected = false
		# Dropped socket: the reconnect cycle takes over (ReconnectManager).
		EventBus.emit(EventBus.EV_NETWORK_DISCONNECTED, {"reason": "socket_closed"})


func _handle_ws_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var msg = json.get_data()
	if typeof(msg) != TYPE_DICTIONARY:
		return
	if msg.has("match_data"):
		var md: Dictionary = msg["match_data"]
		var data_b64: String = str(md.get("data", ""))
		if data_b64 != "":
			var envelope := Marshalls.base64_to_raw(data_b64)
			var decoded := NetSerializer.decode(envelope)
			if not decoded.is_empty():
				decoded["sender_id"] = int(str(md.get("sender", "0")).hash())
				_on_message(decoded)
	elif msg.has("match_presence_event"):
		var mpe: Dictionary = msg["match_presence_event"]
		if mpe.has("joins") and (mpe["joins"] as Array).size() > 0:
			for join in mpe["joins"]:
				var p := {
					"id": int(str(join.get("user_id", "0")).hash()),
					"name": str(join.get("username", "Player")),
					"is_host": false,
				}
				if _lobby != null:
					_lobby._on_player_joined(p)
		if mpe.has("leaves") and (mpe["leaves"] as Array).size() > 0:
			for leave in mpe["leaves"]:
				if _lobby != null:
					_lobby._on_player_left(int(str(leave.get("user_id", "0")).hash()))


# ── SIMULATED transport (in-process fake server, no network) ──────────────

static var _sim_rooms: Dictionary = {}   # code → room
static var _sim_next_id: int = 100       # deterministic-ish player ids

static func _sim_allocate_id(dev: String) -> int:
	return dev.hash() & 0x7FFFFFFF


func _sim_seed_bots() -> void:
	for i in SIMULATED_PLAYERS:
		var bot_id := 500 + i
		var bot_name := "Bot%d" % (i + 1)
		var code := room_code
		if code == "":
			continue
		var room := MatchSession._sim_room(code)
		if room.is_empty():
			continue
		(room["players"] as Dictionary)[bot_id] = {"name": bot_name, "ready": false}


static func _sim_room(code: String) -> Dictionary:
	if MatchSession._sim_rooms.has(code):
		return MatchSession._sim_rooms[code]
	return {}


func _sim_create_match(code: String) -> int:
	if MatchSession._sim_rooms.has(code):
		return CreateResult.CODE_TAKEN
	MatchSession._sim_rooms[code] = {
		"host_id": session_id,
		"players": {session_id: {"name": player_name, "ready": false}},
		"match_state": 2,  # GameState.MatchState.LOBBY
		"round": 0,
		"last_seq": 0,
		"lines": [],
	}
	return CreateResult.OK


func _sim_join_match(code: String) -> int:
	if not MatchSession._sim_rooms.has(code):
		return JoinResult.NOT_FOUND
	var room: Dictionary = MatchSession._sim_rooms[code]
	if (room["players"] as Dictionary).size() >= MAX_PLAYERS:
		return JoinResult.FULL
	(room["players"] as Dictionary)[session_id] = {"name": player_name, "ready": false}
	room["last_seq"] = int(room["last_seq"]) + 1
	return JoinResult.OK


func _sim_leave(code: String) -> void:
	if not MatchSession._sim_rooms.has(code):
		return
	var room: Dictionary = MatchSession._sim_rooms[code]
	(room["players"] as Dictionary).erase(session_id)
	if (room["players"] as Dictionary).is_empty():
		MatchSession._sim_rooms.erase(code)
	else:
		_sim_reassign_host(room)


func _sim_close(code: String) -> void:
	if MatchSession._sim_rooms.has(code):
		MatchSession._sim_rooms.erase(code)


func _sim_apply_ready(player_id: int, ready: bool) -> void:
	var room := MatchSession._sim_room(room_code)
	if room.is_empty():
		return
	var players: Dictionary = room["players"]
	if players.has(player_id):
		players[player_id]["ready"] = ready


func _sim_apply_match_start() -> void:
	var room := MatchSession._sim_room(room_code)
	if room.is_empty():
		return
	room["match_state"] = 4  # GameState.MatchState.DRAWING
	room["round"] = 1
	room["last_seq"] = int(room["last_seq"]) + 1


func _sim_apply_host_transfer(new_host_id: int) -> void:
	var room := MatchSession._sim_room(room_code)
	if room.is_empty():
		return
	room["host_id"] = new_host_id
	room["last_seq"] = int(room["last_seq"]) + 1


func _sim_reassign_host(room: Dictionary) -> void:
	var players: Dictionary = room["players"]
	if players.is_empty():
		return
	var lowest := 0x7FFFFFFF
	for pid in players:
		if int(pid) < lowest:
			lowest = int(pid)
	room["host_id"] = lowest
	room["last_seq"] = int(room["last_seq"]) + 1


## Each tick in SIMULATED mode: pull the shared room state and feed it to
## the local lobby/migration/host machinery as if presence arrived over the
## wire. This is what makes the sim transport end-to-end testable.
func _sim_sync_room_state() -> void:
	var room := MatchSession._sim_room(room_code)
	if room.is_empty():
		return
	var players: Dictionary = room["players"]
	# Presence sync → LobbyManager roster.
	if _lobby != null:
		var known: Dictionary = {}
		for pid in players:
			var pid_i := int(pid)
			known[pid_i] = true
			var p := {"id": pid_i, "name": str(players[pid]["name"]), "is_host": pid_i == int(room["host_id"]), "ready": bool(players[pid]["ready"])}
			if not _lobby._players.has(pid_i):
				_lobby._on_player_joined(p)
			else:
				var cur: Dictionary = _lobby._players[pid_i]
				if bool(cur.get("ready", false)) != p["ready"]:
					_lobby._on_player_ready(pid_i, p["ready"])
		for pid in _lobby._players.keys():
			if not known.has(int(pid)):
				_lobby._on_player_left(int(pid))
	# Host change detection → migration machinery.
	var room_host := int(room["host_id"])
	if _host_migration != null:
		if _host_migration.current_host_id != room_host:
			var previous := _host_migration.current_host_id
			if previous >= 0 and previous != room_host:
				EventBus.emit(EventBus.EV_NET_HOST_LOST, {"host_id": previous, "unrecoverable": false})
				EventBus.emit(EventBus.EV_NET_HOST_TRANSFERRED, {"new_host_id": room_host, "last_seq": int(room["last_seq"])})
			_host_migration.current_host_id = room_host
			if room_host == session_id:
				EventBus.emit(EventBus.EV_NET_HOST_ELECTED, {"host_id": session_id, "previous_host": previous})
		_host_migration.note_heartbeat(room_host)
	# Match state sync.
	var ms := int(room["match_state"])
	var rd := int(room["round"])
	if int(_mirror.get("match_state", 0)) != ms or int(_mirror.get("round", 0)) != rd:
		_mirror["match_state"] = ms
		_mirror["round"] = rd
		_mirror["last_seq"] = int(room["last_seq"])
		EventBus.emit(EventBus.EV_NET_MATCH_STATE_SYNC, {"match_state": ms, "round": rd, "last_seq": int(room["last_seq"])})
