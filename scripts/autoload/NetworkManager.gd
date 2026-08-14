# NetworkManager.gd — Transport abstraction + multiplayer layer hub
# (Prompt 17: lobby, host migration, reconnect, minimal bandwidth, authority).
#
# The rest of the game only calls THIS singleton and listens to EV_NETWORK_*
# / EV_NET_* events; the concrete networking classes live in scripts/networking/
# and are instantiated here as children:
#
#   MatchSession     — transport (Nakama REST+WS / simulated / offline), tick
#                      loop, batching, bandwidth accounting, binary protocol
#   LobbyManager     — room codes, player roster, ready state
#   HostMigration    — heartbeats, host-lost detection, deterministic
#                      re-election, state transfer
#   ReconnectManager — session resume via SaveManager, backoff, rejoin+resync
#   AuthorityGuard   — client-side enforcement of the authority model
#
# Offline fallback: when no server is configured or the connection fails,
# EV_NET_OFFLINE is emitted and the game keeps running on the existing
# local loop (mode OFFLINE, this device = HOST).
#
# NOTE: `disconnect_from_server` (NOT `disconnect`) — see below.

extends Node

enum Mode { NONE, ONLINE, OFFLINE }
enum Authority { NONE, SERVER, HOST, CLIENT }

const IDENTITY_SAVE_KEY := "net_identity"

var mode: int = Mode.NONE
var authority: int = Authority.NONE
var is_connected: bool = false

# Networking layer children (injected/wired below).
var session: MatchSession
var lobby: LobbyManager
var migration: HostMigration
var reconnect: ReconnectManager
var guard: AuthorityGuard

var player_name := "Player"
var _device_id := ""


func _ready() -> void:
	# Identity (persisted locally so reconnect survives restarts).
	var identity := SaveManager.load_local(IDENTITY_SAVE_KEY, {})
	if identity.has("device_id"):
		_device_id = str(identity["device_id"])
	else:
		_device_id = "dev_%s" % hash(OS.get_unique_id() if OS.get_unique_id() != "" else str(Time.get_unix_time_from_system()))
		SaveManager.save_local(IDENTITY_SAVE_KEY, {"device_id": _device_id})
	if identity.has("player_name"):
		player_name = str(identity["player_name"])

	# Instantiate the networking layer.
	session = MatchSession.new()
	add_child(session)
	lobby = LobbyManager.new()
	add_child(lobby)
	migration = HostMigration.new()
	add_child(migration)
	reconnect = ReconnectManager.new()
	add_child(reconnect)
	guard = AuthorityGuard.new()

	# Wire the layer together.
	session.setup(hash(_device_id), player_name, _device_id)
	session.attach(lobby, migration)
	lobby.setup(session, hash(_device_id))
	migration.setup(session, hash(_device_id))
	reconnect.setup(session)
	guard.set_role(AuthorityGuard.Role.NONE)
	guard.set_player_id(hash(_device_id))

	# React to transport outcomes.
	EventBus.on(EventBus.EV_NET_OFFLINE, _on_offline_fallback)
	EventBus.on(EventBus.EV_NETWORK_CONNECTED, _on_network_connected)
	EventBus.on(EventBus.EV_NETWORK_DISCONNECTED, _on_network_disconnected)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_NET_OFFLINE, _on_offline_fallback)
	EventBus.off(EventBus.EV_NETWORK_CONNECTED, _on_network_connected)
	EventBus.off(EventBus.EV_NETWORK_DISCONNECTED, _on_network_disconnected)


# ── Session lifecycle (existing API kept) ─────────────────────────────────

## Start an online session (Nakama). server_url may be empty — in that case
## the game falls back to the local offline loop (EV_NET_OFFLINE).
func start_online(server_url: String, auth_token: String = "") -> void:
	print("NetworkManager: start_online(%s)" % server_url)
	if session.connect_to_server(server_url, auth_token):
		mode = Mode.ONLINE
		authority = Authority.CLIENT  # Nakama server is the authority
		is_connected = true
		guard.set_role(AuthorityGuard.Role.CLIENT)
		if session.transport == MatchSession.Transport.SIMULATED:
			# Simulated server: still exercise the hosted-authority machinery
			# (room host = first creator) so lobby/migration flows are testable.
			hosted_mode(true)
	else:
		# connect_to_server already emitted EV_NET_OFFLINE; _on_offline_fallback
		# completes the local switch.
		pass


## Start an offline session (WiFi Direct / local host).
func start_offline() -> void:
	print("NetworkManager: start_offline")
	mode = Mode.OFFLINE
	authority = Authority.HOST  # this device is host for now
	is_connected = true
	hosted_mode(true)
	guard.set_role(AuthorityGuard.Role.HOST)
	EventBus.emit(EventBus.EV_NETWORK_CONNECTED, {"mode": "offline"})


## Disconnect from current session.
## NOTE: named `disconnect_from_server` (NOT `disconnect`) because `Node.disconnect`
## is a built-in used for signal disconnection — defining `disconnect()` here would
## shadow it on this Node and silently break any signal .disconnect() calls on it.
func disconnect_from_server() -> void:
	print("NetworkManager: disconnect_from_server")
	session.disconnect_session()
	reconnect.cancel()
	migration.stop()
	lobby.leave_lobby()
	mode = Mode.NONE
	authority = Authority.NONE
	is_connected = false
	guard.set_role(AuthorityGuard.Role.NONE)
	EventBus.emit(EventBus.EV_NETWORK_DISCONNECTED, {"reason": "manual"})


## Send an RPC to the authority (server or host).
## LEGACY SEAM: existing systems (e.g. GhostDrawSystem) call this with a
## method name + dictionary. The new typed senders below (send_line_drawn,
## send_ghost_line_placed, send_accusation, ...) replace call sites during
## the next milestone (converting the live loop to the binary protocol).
func send_rpc(method: String, payload: Dictionary = {}) -> void:
	if not is_connected:
		return
	# Audit M9: the legacy "ghost.lines_placed" batch path is removed - it
	# silently fell through to LINE_DRAWN and mangled the payload. Ghost
	# lines go through send_ghost_line_placed() (one typed msg per line).
	if method == "ghost.lines_placed":
		push_warning("NetworkManager: send_rpc('ghost.lines_placed') is removed - use send_ghost_line_placed() per line (audit M9)")
		return
	var player_id: int = payload.get("player_id", guard.session_player_id)
	if not guard.assert_action(_rpc_action_for(method), player_id):
		return
	if mode == Mode.ONLINE:
		# Legacy seam: pack the RPC into a typed binary message. Call sites
		# migrate to the typed senders (send_line_drawn, send_accusation, ...)
		# during the next milestone.
		var msg_type := _rpc_msg_type(method)
		if msg_type == NetSerializer.MsgType.LINE_DRAWN:
			session.broadcast_raw_bytes(msg_type, NetSerializer.encode_line(_rpc_to_line(payload)))
		else:
			session.broadcast_raw_bytes(msg_type, JSON.stringify(payload).to_utf8_buffer())
	else:
		print("NetworkManager: send_rpc '%s' → %s (local)" % [method, payload])


## Check if this device has authority to modify game state.
func has_authority() -> bool:
	return authority == Authority.SERVER or authority == Authority.HOST

func is_server() -> bool:
	return authority == Authority.SERVER

func is_host() -> bool:
	return authority == Authority.HOST

func is_online() -> bool:
	return mode == Mode.ONLINE


# ── Lobby API (UI hook points; events on EventBus EV_NET_LOBBY_*) ─────────

func create_lobby(display_name: String) -> String:
	return lobby.create_lobby(display_name)

func join_lobby(room_code: String) -> bool:
	return lobby.join_lobby(room_code)

func leave_lobby() -> void:
	lobby.leave_lobby()

func set_ready(ready: bool) -> bool:
	return lobby.set_ready(ready)

func start_match() -> bool:
	return lobby.start_match()

func get_lobby_players() -> Array[Dictionary]:
	return lobby.get_players()

func get_room_code() -> String:
	return lobby.room_code

func is_lobby_host() -> bool:
	return lobby.is_host


# ── Typed gameplay senders (binary protocol seam for the next milestone) ──

## Send a chalk line (ChalkLine.to_network_dict()) to the authority.
func send_line_drawn(line_dict: Dictionary) -> void:
	if not guard.assert_action("line.draw", int(line_dict.get("pid", -1))):
		return
	session.broadcast_raw_bytes(NetSerializer.MsgType.LINE_DRAWN, NetSerializer.encode_line(line_dict))

## Send a ghost-line placement (client request; server/host re-validates - audit M10).
func send_ghost_line_placed(line_dict: Dictionary) -> void:
	if not guard.assert_action("ghost.place", int(line_dict.get("pid", -1))):
		return
	session.broadcast_raw_bytes(NetSerializer.MsgType.GHOST_LINE_PLACED, NetSerializer.encode_line(line_dict))

func send_accusation(argument_id: int, accuser_id: int, target_id: int) -> void:
	if not guard.assert_action("accusation.start", accuser_id):
		return
	session.broadcast_raw_bytes(NetSerializer.MsgType.ACCUSATION, NetSerializer.encode_accusation(argument_id, accuser_id, target_id))

func send_accusation_resolution(argument_id: int, is_true: bool, penalty: bool) -> void:
	if not guard.assert_action("accusation.resolve"):
		return
	session.broadcast_raw_bytes(NetSerializer.MsgType.ACCUSATION_RESOLUTION, NetSerializer.encode_accusation_resolution(argument_id, is_true, penalty))

func send_score(player_id: int, round_number: int, score: int) -> void:
	if not guard.assert_action("score.commit"):
		return
	session.broadcast_raw_bytes(NetSerializer.MsgType.SCORE, NetSerializer.encode_score(player_id, round_number, score))

## Host/server side: feed the authoritative state into the session each tick.
func update_authoritative_state(match_state: int, round_number: int, players: Array, lines: Array, flags := 0) -> void:
	if not guard.assert_action("state.change"):
		return
	session.update_authoritative_state(match_state, round_number, players, lines, flags)


# ── Reconnect / resync ────────────────────────────────────────────────────

func request_resync() -> void:
	session.request_resync()

func try_reconnect_now() -> void:
	reconnect.try_now()

func persist_session_for_resume() -> void:
	reconnect.persist_session({
		"device_id": _device_id,
		"auth_token": session.auth_token,
		"refresh_token": session.refresh_token,
		"user_id": session.session_id,
		"last_room_code": session.room_code,
		"reconnect_token": session.session_id,
	})

func clear_saved_session() -> void:
	reconnect.clear_session()


# ── Host migration control ────────────────────────────────────────────────

## Enable the hosted-authority machinery (offline / WiFi Direct mode).
func hosted_mode(enabled: bool) -> void:
	session.hosted = enabled
	if enabled:
		migration.start(session.session_id)
	else:
		migration.stop()


# ── Internals ─────────────────────────────────────────────────────────────

func _on_offline_fallback(payload) -> void:
	mode = Mode.OFFLINE
	authority = Authority.HOST
	is_connected = true
	hosted_mode(true)
	guard.set_role(AuthorityGuard.Role.HOST)
	print("NetworkManager: offline fallback (%s)" % str(payload.get("reason", "unknown")))


func _on_network_connected(payload) -> void:
	if mode == Mode.OFFLINE:
		return
	mode = Mode.ONLINE
	authority = Authority.CLIENT
	is_connected = true
	guard.set_role(AuthorityGuard.Role.CLIENT)
	# Persist credentials for reconnect/resume.
	persist_session_for_resume()


func _on_network_disconnected(payload) -> void:
	if mode == Mode.NONE:
		return
	# If the drop was not manual, start the reconnect cycle (online mode only).
	var reason := str(payload.get("reason", "unknown"))
	if reason != "manual" and mode == Mode.ONLINE:
		reconnect.on_connection_lost()
		return
	authority = Authority.NONE
	is_connected = false


## Map legacy RPC method names to AuthorityGuard actions.
func _rpc_action_for(method: String) -> String:
	match method:
		"ghost.line_discovered":
			return "ghost.discover"
		"argument.request", "argument.resolved":
			return "accusation.start"
		"hint.placed", "hint.resolved", "hint.revealed", "place_fake_hint", "silent_sneak.activate", "silent_sneak.deactivate", "spectator.reveal":
			return "state.change"
	return "line.draw"


## Map legacy RPC method names to binary message types.
func _rpc_msg_type(method: String) -> int:
	match method:
		"ghost.line_discovered":
			return NetSerializer.MsgType.GHOST_LINE_DISCOVERED
		"argument.request":
			return NetSerializer.MsgType.ACCUSATION
		"argument.resolved":
			return NetSerializer.MsgType.ACCUSATION_RESOLUTION
	return NetSerializer.MsgType.LINE_DRAWN


## Build a minimal ChalkLine network dict from a legacy RPC payload.
func _rpc_to_line(payload: Dictionary) -> Dictionary:
	return {
		"id": payload.get("line_id", -1),
		"ct": payload.get("chalk_type", 0),
		"pid": payload.get("player_id", guard.session_player_id),
		"t": int(Time.get_ticks_msec()),
		"dd": 60,
		"cn": [],
		"pc": 0,
		"pd": PackedByteArray(),
		"wd": PackedByteArray(),
		"gh": payload.get("is_ghost", false),
		"gd": false,
	}
