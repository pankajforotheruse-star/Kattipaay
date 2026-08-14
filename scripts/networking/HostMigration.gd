# HostMigration.gd — Host loss detection, deterministic re-election, state
# transfer (Prompt 17, item 2).
#
# Applies to the OFFLINE (WiFi Direct / local hosted) authority model, where
# one elected device is the authority. In ONLINE (Nakama) mode the server is
# the authority and never drops — see docs/networking.md §8.
#
# Model:
#   - every peer sends a HEARTBEAT every HEARTBEAT_INTERVAL seconds
#   - each peer tracks last-seen per session id; when the CURRENT HOST's
#     heartbeats are missing for MISSED_HEARTBEAT_THRESHOLD × interval,
#     the host is declared lost
#   - re-election is deterministic: the remaining peer with the LOWEST
#     session id becomes the new host (every peer computes the same answer)
#   - the new host rebuilds authoritative state from its local mirror plus
#     the confirmed-event log, then broadcasts HOST_TRANSFER + snapshot

class_name HostMigration
extends Node

const HEARTBEAT_INTERVAL := 2.0        # seconds between heartbeats
const MISSED_HEARTBEAT_THRESHOLD := 3  # missed beats → host considered lost
const REELECTION_TIMEOUT := 4.0        # seconds to converge before giving up
const MAX_EVENT_LOG_ENTRIES := 256     # ring-buffer cap for state transfer

## session_id of the current authority host (-1 = unknown).
var current_host_id := -1
var _enabled := false
var _last_seen: Dictionary = {}        # session_id → unix time of last heartbeat
var _heartbeat_seq := 0
var _my_session_id := -1
var _tick_accumulator := 0.0
var _reelection_accumulator := 0.0
var _reelecting := false
var _session: MatchSession = null      # injected by NetworkManager

## Confirmed event log (ring buffer) — the basis for state transfer.
var _event_log: Array[Dictionary] = []


func _ready() -> void:
	pass


## Inject transport owner + identity.
func setup(session: MatchSession, my_session_id: int) -> void:
	_session = session
	_my_session_id = my_session_id


func start(host_id: int) -> void:
	current_host_id = host_id
	_enabled = true
	_tick_accumulator = 0.0
	_reelecting = false
	_last_seen.clear()
	# Audit M7: seed our own last-seen so the host never declares itself
	# lost before it has sent a single heartbeat (offline/WiFi-Direct mode).
	if _my_session_id >= 0:
		_last_seen[_my_session_id] = Time.get_unix_time_from_system()


func stop() -> void:
	_enabled = false


func is_enabled() -> bool:
	return _enabled


# ── Per-tick updates (called from MatchSession._process) ──────────────────

func tick(delta: float) -> void:
	if not _enabled:
		return
	_tick_accumulator += delta
	if _tick_accumulator >= HEARTBEAT_INTERVAL:
		_tick_accumulator = 0.0
		_send_heartbeat()
	check_host_health()


## Record that a heartbeat from `session_id` was seen.
func note_heartbeat(session_id: int) -> void:
	_last_seen[session_id] = Time.get_unix_time_from_system()


## Record a confirmed event for later state transfer. Entries are capped.
func append_event(entry: Dictionary) -> void:
	_event_log.append(entry)
	if _event_log.size() > MAX_EVENT_LOG_ENTRIES:
		_event_log.pop_front()


## Events with seq > last_seq (for the new host to replay after transfer).
func get_event_log_since(last_seq: int) -> Array:
	var out: Array = []
	for entry in _event_log:
		if int(entry.get("seq", 0)) > last_seq:
			out.append(entry)
	return out


# ── Host health ───────────────────────────────────────────────────────────

## Check whether the current host has missed too many heartbeats.
func check_host_health() -> void:
	if not _enabled or current_host_id < 0:
		return
	var now := Time.get_unix_time_from_system()
	# Audit M7: this device IS the host - alive by construction; keep our
	# own last-seen fresh every tick so we never re-elect ourselves.
	if current_host_id == _my_session_id:
		_last_seen[current_host_id] = now
	var last: float = _last_seen.get(current_host_id, 0.0)
	if now - last > HEARTBEAT_INTERVAL * MISSED_HEARTBEAT_THRESHOLD:
		_on_host_lost(current_host_id)


func _on_host_lost(lost_host_id: int) -> void:
	if _reelecting:
		return  # audit M7: no re-entry while a re-election is in flight
	print("HostMigration: host %d lost" % lost_host_id)
	EventBus.emit(EventBus.EV_NET_HOST_LOST, {"host_id": lost_host_id, "unrecoverable": false})
	# Stop tracking the dead host.
	_last_seen.erase(lost_host_id)
	current_host_id = -1
	_reelecting = true
	_reelection_accumulator = 0.0

	# Deterministic re-election: lowest remaining session id.
	var new_host_id := _elect_new_host()
	if new_host_id < 0:
		EventBus.emit(EventBus.EV_NET_HOST_LOST, {"host_id": lost_host_id, "unrecoverable": true})
		push_warning("HostMigration: no candidates for re-election — match cannot continue")
		return
	current_host_id = new_host_id
	if new_host_id == _my_session_id:
		_become_host(lost_host_id)
	else:
		print("HostMigration: waiting for host transfer from %d" % new_host_id)


func _elect_new_host() -> int:
	var best := -1
	for sid in _last_seen:
		var id := int(sid)
		if best < 0 or id < best:
			best = id
	return best


func _become_host(lost_host_id: int) -> void:
	EventBus.emit(EventBus.EV_NET_HOST_ELECTED, {"host_id": _my_session_id, "previous_host": lost_host_id})
	print("HostMigration: I am the new host (session %d)" % _my_session_id)
	if _session == null:
		return
	# Rebuild authoritative state: current mirror + replay of unapplied events.
	var state := _session.get_authoritative_snapshot()
	var snapshot_bytes := NetSerializer.encode_snapshot(state)
	var last_seq := _session.get_last_confirmed_seq()
	# Broadcast authority handoff to all remaining peers.
	_session.broadcast_host_transfer(_my_session_id, last_seq, snapshot_bytes)
	_reelecting = false


func _process(delta: float) -> void:
	if not _reelecting:
		return
	_reelection_accumulator += delta
	if _reelection_accumulator >= REELECTION_TIMEOUT:
		_reelecting = false
		EventBus.emit(EventBus.EV_NET_HOST_LOST, {"host_id": -1, "unrecoverable": true})
		push_warning("HostMigration: re-election timed out — match cannot continue")


func _send_heartbeat() -> void:
	if _session == null:
		return
	_heartbeat_seq += 1
	var match_state := 0
	var round_number := 0
	if _session.get_game_state() != null:
		match_state = _session.get_game_state()
		round_number = _session.get_round_number()
	_session.broadcast_heartbeat(_heartbeat_seq, match_state, round_number)
