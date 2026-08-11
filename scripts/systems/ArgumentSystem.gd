# ArgumentSystem.gd — Social deception accusation mechanic for CHALK GAON
#
# Pluggable system: node under GameWorld/Systems.
# Handles the full argument flow: accusation request → validation → dramatic pause →
# resolution (ghost check) → result broadcast.
#
# All communication flows through EventBus and NetworkManager stubs.
#
# Constraints:
#   - One argument per player per round (reset on DRAWING → SEARCHING)
#   - Accusations only valid in SEARCHING state
#   - Accuser must be a searcher (not a ghost)
#   - Target must be alive

class_name ArgumentSystem
extends Node

# ── Accusation Pool ───────────────────────────────────────────────────────────

const ACCUSATIONS: Array[String] = [
	"I saw chalk dust on your hands near the well!",
	"You vanished during the last search round!",
	"The village elder saw strange markings behind your hut!",
	"You were the last one near the temple when the ghost appeared!",
	"Your lamp flickered out exactly when the ghost struck!",
	"I heard whispering from your direction in the dark!",
	"The footprints in the mud lead straight to your door!",
	"You knew which house the ghost would strike before anyone else!",
	"Your shadow moved the wrong way under the banyan tree!",
	"The chaiwallah says you were not in bed when the rooster crowed!",
	"Your voice echoed from two places at once near the ghat!",
	"The sacred chalk broke when you touched it!",
	"You were seen drawing lines that vanished at dawn!",
	"Your eyes glowed green when the search lantern passed!",
	"The village dogs bark only when you walk past!",
	"You refused to enter the circle of protection!",
	"Your hands are cold as the river at midnight!",
	"The old widow swears she saw you floating, not walking!",
	"Your reflection disappeared in the temple mirror!",
	"You named the ghost's next move before it happened!",
	"The rangoli outside your house was smeared at night!",
	"You alone were not searching when the ghost left its mark!",
	"Your breath leaves no fog on the cold morning air!",
	"The crows circle only above your roof at sunset!",
]

# ── State ─────────────────────────────────────────────────────────────────────

## Track which players have used their argument this round: { player_id: bool }
var _argued_this_round: Dictionary = {}

## Recently used accusation indices (FIFO, avoid repeats).
var _recent_accusations: Array[int] = []

## Number of recent accusations to track to avoid repeats.
const RECENT_POOL_SIZE := 8

## Pending argument data: { argument_id: { accuser_id, target_id, accusation_text, timestamp } }
var _pending_arguments: Dictionary = {}

## Auto-incrementing argument ID counter.
var _next_argument_id: int = 0

## Pending resolution timers: { argument_id: SceneTreeTimer }
## Tracked so stale callbacks can be cancelled on round reset / scene exit
## (otherwise a timeout could fire on dead state and resolve an old argument).
var _argument_timers: Dictionary = {}

## Dramatic pause duration before an argument auto-resolves (seconds).
const ARGUMENT_RESOLUTION_SECONDS := 3.0

## Timer penalty for a FALSE accusation (seconds removed from the match clock).
## Owner decision (2026-08-11): random between 3 and 10 seconds, rolled per
## false accusation via randf_range(). gdd.md does not specify a value.
const FALSE_ACCUSATION_PENALTY_MIN_SECONDS := 3.0
const FALSE_ACCUSATION_PENALTY_MAX_SECONDS := 10.0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)

	# Listen for network RPC simulation events
	EventBus.on(EventBus.EV_NETWORK_RPC_REQUEST_ARGUMENT, _on_rpc_request_argument)
	EventBus.on(EventBus.EV_NETWORK_RPC_ARGUMENT_STARTED, _on_rpc_argument_started)
	EventBus.on(EventBus.EV_NETWORK_RPC_ARGUMENT_RESOLVED, _on_rpc_argument_resolved)

	print("ArgumentSystem: ready — %d accusations in pool" % ACCUSATIONS.size())


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_NETWORK_RPC_REQUEST_ARGUMENT, _on_rpc_request_argument)
	EventBus.off(EventBus.EV_NETWORK_RPC_ARGUMENT_STARTED, _on_rpc_argument_started)
	EventBus.off(EventBus.EV_NETWORK_RPC_ARGUMENT_RESOLVED, _on_rpc_argument_resolved)
	# Kill pending resolution timers so no callback fires after teardown.
	_cancel_all_argument_timers()

# ── Public API ────────────────────────────────────────────────────────────────

## Request an argument (called from ArgumentButton in HUD).
## Validates: match state, accuser role, target alive, per-round limit.
## Sends to server/host via NetworkManager for validation and broadcast.
func request_argument(accuser_peer_id: int, target_peer_id: int) -> bool:
	# Validate match state
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		push_warning("ArgumentSystem: arguments only allowed in SEARCHING state")
		return false

	# Validate per-round limit
	if _argued_this_round.get(accuser_peer_id, false):
		push_warning("ArgumentSystem: player %d already argued this round" % accuser_peer_id)
		return false

	# Validate target is alive (stub: always valid for prototype)
	# In production: check entity_registry for target health/state

	if NetworkManager.is_connected and not NetworkManager.has_authority():
		# Client: send request to server/host
		NetworkManager.send_rpc("request_argument", {
			"accuser_id": accuser_peer_id,
			"target_id": target_peer_id,
		})
		# Simulate immediate local response via EventBus for prototype
		_simulate_local_argument(accuser_peer_id, target_peer_id)
	else:
		# Host/server or offline: process locally
		_process_argument_request(accuser_peer_id, target_peer_id)

	return true

# ── Internal Processing ───────────────────────────────────────────────────────

## Pick a random accusation from the pool, avoiding recent repeats.
func _pick_accusation() -> String:
	var available: Array[int] = []
	for i in range(ACCUSATIONS.size()):
		if i not in _recent_accusations:
			available.append(i)

	if available.is_empty():
		# All accusations used recently — clear the recent list and try again
		_recent_accusations.clear()
		for i in range(ACCUSATIONS.size()):
			available.append(i)

	var idx: int = available[randi() % available.size()]
	_recent_accusations.append(idx)
	while _recent_accusations.size() > RECENT_POOL_SIZE:
		_recent_accusations.pop_front()

	return ACCUSATIONS[idx]


## Process an argument request (host/server side or offline).
func _process_argument_request(accuser_id: int, target_id: int) -> void:
	# Mark as argued
	_argued_this_round[accuser_id] = true

	# Pick accusation text
	var text := _pick_accusation()
	var arg_id := _next_argument_id
	_next_argument_id += 1

	# Store pending
	_pending_arguments[arg_id] = {
		"accuser_id": accuser_id,
		"target_id": target_id,
		"accusation_text": text,
		"timestamp": Time.get_ticks_msec(),
	}

	# Broadcast start
	EventBus.emit(EventBus.EV_NETWORK_RPC_ARGUMENT_STARTED, {
		"accuser_id": accuser_id,
		"target_id": target_id,
		"accusation_text": text,
		"argument_id": arg_id,
		"timestamp": Time.get_ticks_msec(),
	})

	if NetworkManager.is_connected and NetworkManager.has_authority():
		NetworkManager.send_rpc("argument_started", {
			"accuser_id": accuser_id,
			"target_id": target_id,
			"accusation_text": text,
			"argument_id": arg_id,
			"timestamp": Time.get_ticks_msec(),
		})


## Simulate local argument for prototype (client-side without real server).
func _simulate_local_argument(accuser_id: int, target_id: int) -> void:
	# Simulate as if server processed it — emit started event locally
	var text := _pick_accusation()
	var arg_id := _next_argument_id
	_next_argument_id += 1

	_argued_this_round[accuser_id] = true

	_pending_arguments[arg_id] = {
		"accuser_id": accuser_id,
		"target_id": target_id,
		"accusation_text": text,
		"timestamp": Time.get_ticks_msec(),
	}

	# Simulate broadcast from server
	EventBus.emit(EventBus.EV_NETWORK_RPC_ARGUMENT_STARTED, {
		"accuser_id": accuser_id,
		"target_id": target_id,
		"accusation_text": text,
		"argument_id": arg_id,
		"timestamp": Time.get_ticks_msec(),
	})


## Resolve an argument after the 3-second dramatic pause.
func _resolve_argument(argument_id: int) -> void:
	if not _pending_arguments.has(argument_id):
		return

	var data: Dictionary = _pending_arguments[argument_id]
	var target_id: int = data["target_id"]

	# Check if target is a ghost (stub: random for prototype)
	# In production: query GameWorld.entity_registry for ghost flag
	var is_true_ghost: bool = _is_target_ghost(target_id)

	# Broadcast resolution
	EventBus.emit(EventBus.EV_NETWORK_RPC_ARGUMENT_RESOLVED, {
		"argument_id": argument_id,
		"is_true_ghost": is_true_ghost,
	})

	if NetworkManager.is_connected and NetworkManager.has_authority():
		NetworkManager.send_rpc("argument_resolve", {
			"argument_id": argument_id,
			"is_true_ghost": is_true_ghost,
		})

	_pending_arguments.erase(argument_id)


# ── Resolution Timer Management ──────────────────────────────────────────────

## Schedule auto-resolution of an argument after the dramatic pause.
## The SceneTreeTimer is stored per argument_id so it can be cancelled on
## round reset / scene exit — prevents stale timeouts firing on dead state.
func _schedule_argument_resolution(argument_id: int) -> void:
	_cancel_argument_timer(argument_id)  # never double-schedule the same argument
	var tree := get_tree()
	if not tree:
		return
	var timer := tree.create_timer(ARGUMENT_RESOLUTION_SECONDS)
	_argument_timers[argument_id] = timer
	timer.timeout.connect(_on_argument_timer_timeout.bind(argument_id), CONNECT_ONE_SHOT)


## Timeout fired: resolve the argument (if it is still pending).
func _on_argument_timer_timeout(argument_id: int) -> void:
	_argument_timers.erase(argument_id)
	_resolve_argument(argument_id)


## Cancel a single pending resolution timer (disconnect = callback never fires).
func _cancel_argument_timer(argument_id: int) -> void:
	if not _argument_timers.has(argument_id):
		return
	var timer: SceneTreeTimer = _argument_timers[argument_id]
	if timer and timer.timeout.is_connected(_on_argument_timer_timeout.bind(argument_id)):
		timer.timeout.disconnect(_on_argument_timer_timeout.bind(argument_id))
	_argument_timers.erase(argument_id)


## Cancel every pending resolution timer (round reset, scene exit, teardown).
func _cancel_all_argument_timers() -> void:
	for argument_id in _argument_timers.keys():
		_cancel_argument_timer(argument_id)
	_argument_timers.clear()


## Stub: check if target is a ghost.
## In production: query entity registry.
func _is_target_ghost(_target_id: int) -> bool:
	# Prototype: NPC1 (entity_id=2) is always the "ghost"
	# In production, this queries the actual entity's ghost flag
	return _target_id == 2

# ── Event Handlers ────────────────────────────────────────────────────────────

## Match state changed: reset per-round arguments on DRAWING → SEARCHING.
func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)

	if from_state == GameState.MatchState.DRAWING and to_state == GameState.MatchState.SEARCHING:
		_argued_this_round.clear()
		_recent_accusations.clear()
		# Drop any stale pending arguments/timers from a previous round so no
		# resolution callback can fire into the new round.
		_pending_arguments.clear()
		_cancel_all_argument_timers()
		print("ArgumentSystem: reset for new round")


## Received RPC: argument requested (server/host side).
func _on_rpc_request_argument(payload: Dictionary) -> void:
	if not NetworkManager.has_authority():
		return
	var accuser_id: int = payload.get("accuser_id", -1)
	var target_id: int = payload.get("target_id", -1)
	_process_argument_request(accuser_id, target_id)


## Received RPC: argument started (all clients).
func _on_rpc_argument_started(payload: Dictionary) -> void:
	var argument_id: int = payload.get("argument_id", -1)

	# Pause timer
	MatchTimer.pause()

	# Enter PAUSED match state for argument duration
	if GameState.get_match_state() != GameState.MatchState.PAUSED:
		GameState.enter_match_state(GameState.MatchState.PAUSED)

	# Emit game event
	EventBus.emit(EventBus.EV_GAME_ARGUMENT_STARTED, payload)

	# Play sound
	AudioManager.play_argument_start()

	# Auto-resolve after the dramatic pause (tracked so it can be cancelled).
	_schedule_argument_resolution(argument_id)


## Received RPC: argument resolved (all clients).
func _on_rpc_argument_resolved(payload: Dictionary) -> void:
	var argument_id: int = payload.get("argument_id", -1)
	var is_true: bool = payload.get("is_true_ghost", false)
	var penalty_applied: bool = false

	if not is_true:
		# False accusation: remove random time penalty (3–10s, owner decision 2026-08-11)
		var penalty_seconds := randf_range(FALSE_ACCUSATION_PENALTY_MIN_SECONDS, FALSE_ACCUSATION_PENALTY_MAX_SECONDS)
		MatchTimer.remove_time(penalty_seconds)
		penalty_applied = true

	# Play result sound
	AudioManager.play_argument_result(is_true)

	# Emit resolved event
	EventBus.emit(EventBus.EV_GAME_ARGUMENT_RESOLVED, {
		"argument_id": argument_id,
		"is_true": is_true,
		"penalty_applied": penalty_applied,
	})

	# Resume match state (exit PAUSED)
	if GameState.get_match_state() == GameState.MatchState.PAUSED:
		var pre_pause := GameState.get_pre_pause_match_state()
		if pre_pause != GameState.MatchState.NONE:
			GameState.enter_match_state(pre_pause)
		else:
			GameState.enter_match_state(GameState.MatchState.SEARCHING)

	# Resume timer
	MatchTimer.resume()

	print("ArgumentSystem: argument %d resolved — ghost=%s, penalty=%s" % [argument_id, is_true, penalty_applied])

# ── Queries ───────────────────────────────────────────────────────────────────

## Check if a player has already used their argument this round.
func has_argued(player_id: int) -> bool:
	return _argued_this_round.get(player_id, false)

## Get remaining cooldown for a player (stub: 15s since last argument).
## In production, track per-player timestamps.
func get_cooldown_remaining(_player_id: int) -> float:
	return 0.0
