# NetworkManager.gd — Transport abstraction layer
# Prototype: stub — no actual networking, but provides the interface
# so that game systems can be written against it from day one.

extends Node

enum Mode { NONE, ONLINE, OFFLINE }
enum Authority { NONE, SERVER, HOST, CLIENT }

var mode: int = Mode.NONE
var authority: int = Authority.NONE
var is_connected: bool = false

func _ready() -> void:
	pass

## Start an online session (Nakama).
func start_online(_server_url: String, _auth_token: String = "") -> void:
	print("NetworkManager: start_online (stub)")
	mode = Mode.ONLINE
	authority = Authority.CLIENT  # Nakama server is the authority
	is_connected = true
	EventBus.emit(EventBus.EV_NETWORK_CONNECTED, {"mode": "online"})

## Start an offline session (WiFi Direct).
func start_offline() -> void:
	print("NetworkManager: start_offline (stub)")
	mode = Mode.OFFLINE
	authority = Authority.HOST  # this device is host for now
	is_connected = true
	EventBus.emit(EventBus.EV_NETWORK_CONNECTED, {"mode": "offline"})

## Disconnect from current session.
## NOTE: named `disconnect_from_server` (NOT `disconnect`) because `Node.disconnect`
## is a built-in used for signal disconnection — defining `disconnect()` here would
## shadow it on this Node and silently break any signal .disconnect() calls on it.
func disconnect_from_server() -> void:
	print("NetworkManager: disconnect_from_server")
	mode = Mode.NONE
	authority = Authority.NONE
	is_connected = false
	EventBus.emit(EventBus.EV_NETWORK_DISCONNECTED, {"reason": "manual"})

## Send an RPC to the authority (server or host).
func send_rpc(_method: String, _payload: Dictionary = {}) -> void:
	# Stub: in prototype, just echo
	if not is_connected:
		return
	print("NetworkManager: send_rpc '%s' → %s" % [_method, _payload])

## Check if this device has authority to modify game state.
func has_authority() -> bool:
	return authority == Authority.SERVER or authority == Authority.HOST

func is_server() -> bool:
	return authority == Authority.SERVER

func is_host() -> bool:
	return authority == Authority.HOST

func is_online() -> bool:
	return mode == Mode.ONLINE
