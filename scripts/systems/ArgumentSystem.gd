# ArgumentSystem.gd — Defender argue/distract for CHALK GAON: Ghost Lines
#
# Slice 4 (R6): the accusation-era role is REPLACED. In the Play VS CPU MVP the
# searcher no longer ACCUSES (they STRIKE hidden lines, slice 3); the DEFENDER
# (whose lines the CPU is searching) instead ARGUES/DISTRACTS to make the CPU
# miss lines for a short window. This system owns the defender-argue role:
#
#   - One ARGUE per defender phase (owner spec: ~1 use per defender phase).
#   - The human presses the HUD "ARGUE" button → request_defender_argue(1).
#   - The mock CPU peer (GhostBotController) argues during ITS defender phase
#     through the same EventBus event (pure-random roll — no difficulty scaling,
#     owner scope note), via trigger_argue(...). The CPU's argue blocks the
#     human's near-tap strikes briefly (symmetric mechanic, slices both ways).
#   - Both cases emit EV_GAME_DEFENDER_ARGUE_STARTED
#     {arguer_id, target_searcher_id, stall_seconds, taunt, argument_id}:
#       · CpuSearchController stalls its sweep (CPU is the search head),
#       · StrikeSystem blocks human near-tap strikes (human is the search head).
#
# The legacy accusation entry (request_argument → EV_GAME_ARGUMENT_STARTED /
# EV_GAME_ARGUMENT_RESOLVED) is retained ONLY as a compat shim for the wordless
# tutorial's level-3 demo, which predates the MVP's replacement of accusations
# by tap-strike search + defender argue. No solo VS CPU path emits it.
#
# Networked (multiplayer) argue replication is a later slice: in solo both
# arguers are in-process, so the event itself is the broadcast.

class_name ArgumentSystem
extends Node

# ── Argue taunts (the former accusation pool — loud "defends" read the same) ──

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

## Which players have used their argue THIS defender phase: { player_id: true }.
## Cleared on every search-phase start (owner: once per defender phase).
var _argued_this_phase: Dictionary = {}

## Recently used taunt indices (FIFO, avoid repeats).
var _recent_taunts: Array[int] = []

## Number of recent taunts to track to avoid repeats.
const RECENT_POOL_SIZE := 8

## Legacy (tutorial-only) pending accusations: { argument_id: target_id }.
var _legacy_pending: Dictionary = {}

## Legacy resolution timers: { argument_id: SceneTreeTimer }.
var _legacy_timers: Dictionary = {}

## Auto-incrementing payload id (shared by argue + legacy accusation).
var _next_id: int = 0

## Legacy accusation dramatic pause before auto-resolve (seconds).
const LEGACY_RESOLUTION_SECONDS := 3.0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	print("ArgumentSystem: ready — %d argue taunts in pool" % ACCUSATIONS.size())


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_SEARCH_PHASE_STARTED, _on_search_phase_started)
	_cancel_legacy_timers()

# ── Public API ────────────────────────────────────────────────────────────────

## Defender argue/distract. Validates: solo match, SEARCHING, the arguer IS the
## current defender, and the per-phase use cap. Emits
## EV_GAME_DEFENDER_ARGUE_STARTED so the CPU's sweep stalls (it misses lines)
## for chalk_gaon/solo_argue_stall_seconds (~3s).
func request_defender_argue(arguer_id: int) -> bool:
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		push_warning("ArgumentSystem: argue only allowed during SEARCHING")
		return false
	if not GameState.solo_vs_cpu:
		return false
	if arguer_id != GameState.solo_defender:
		push_warning("ArgumentSystem: player %d is not the defender — argue rejected" % arguer_id)
		return false
	if _argued_this_phase.get(arguer_id, false):
		push_warning("ArgumentSystem: player %d already argued this defender phase" % arguer_id)
		return false
	var uses: int = maxi(int(ProjectSettings.get_setting("chalk_gaon/solo_argue_uses_per_phase", 1)), 1)
	if _argued_this_phase.size() >= uses:
		push_warning("ArgumentSystem: argue use-cap (%d) reached this phase" % uses)
		return false
	_argued_this_phase[arguer_id] = true
	_emit_argue(arguer_id, _opponent(arguer_id))
	return true


## Emit an argue from any arguer (the mock CPU peer's symmetric defender argue:
## pure-random, no difficulty scaling — the bot owns its own single-use flag).
func trigger_argue(arguer_id: int, target_searcher_id: int, taunt: String) -> void:
	var stall: float = float(ProjectSettings.get_setting("chalk_gaon/solo_argue_stall_seconds", 3.0))
	EventBus.emit(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, {
		"arguer_id": arguer_id,
		"target_searcher_id": target_searcher_id,
		"stall_seconds": stall,
		"taunt": taunt,
		"argument_id": _next_id,
	})
	_next_id += 1
	print("ArgumentSystem: arguer %d argues — searcher %d misses lines for %.1fs" % [
		arguer_id, target_searcher_id, stall
	])


## Legacy accuse-era entry used by the wordless tutorial's level-3 demo (a
## correct accusation of the ghost villager). Emits the old
## EV_GAME_ARGUMENT_STARTED/RESOLVED flow so the tutorial's visuals stay
## unchanged; nothing in the solo VS CPU MVP path calls this.
func request_argument(accuser_id: int, target_id: int) -> bool:
	_argued_this_phase[accuser_id] = true
	var argument_id := _next_id
	_next_id += 1
	_legacy_pending[argument_id] = target_id
	EventBus.emit(EventBus.EV_GAME_ARGUMENT_STARTED, {
		"accuser_id": accuser_id,
		"target_id": target_id,
		"accusation_text": _pick_taunt(),
		"argument_id": argument_id,
		"timestamp": Time.get_ticks_msec(),
	})
	_schedule_legacy_resolve(argument_id)
	print("ArgumentSystem: legacy accusation %d started (tutorial)" % argument_id)
	return true


## True when the player already argued this defender phase (HUD disables the
## ARGUE button accordingly).
func has_argued(player_id: int) -> bool:
	return _argued_this_phase.get(player_id, false)

# ── Internal ──────────────────────────────────────────────────────────────────

## Build and emit the defender-argue event (shared by the human button and the
## bot's symmetric argue).
func _emit_argue(arguer_id: int, target_searcher_id: int) -> void:
	var stall: float = float(ProjectSettings.get_setting("chalk_gaon/solo_argue_stall_seconds", 3.0))
	EventBus.emit(EventBus.EV_GAME_DEFENDER_ARGUE_STARTED, {
		"arguer_id": arguer_id,
		"target_searcher_id": target_searcher_id,
		"stall_seconds": stall,
		"taunt": _pick_taunt(),
		"argument_id": _next_id,
	})
	_next_id += 1
	print("ArgumentSystem: defender %d argues — searcher %d misses lines for %.1fs" % [
		arguer_id, target_searcher_id, stall
	])


## Pick a random taunt, avoiding recent repeats.
func _pick_taunt() -> String:
	var available: Array[int] = []
	for i in range(ACCUSATIONS.size()):
		if i not in _recent_taunts:
			available.append(i)
	if available.is_empty():
		_recent_taunts.clear()
		for i in range(ACCUSATIONS.size()):
			available.append(i)
	var idx: int = available[randi() % available.size()]
	_recent_taunts.append(idx)
	while _recent_taunts.size() > RECENT_POOL_SIZE:
		_recent_taunts.pop_front()
	return ACCUSATIONS[idx]


func _opponent(entity_id: int) -> int:
	return 1 if entity_id == 2 else 2

# ── Legacy (tutorial) resolution ──────────────────────────────────────────────

func _schedule_legacy_resolve(argument_id: int) -> void:
	_cancel_legacy_timer(argument_id)
	var tree := get_tree()
	if not tree:
		return
	var timer := tree.create_timer(LEGACY_RESOLUTION_SECONDS)
	_legacy_timers[argument_id] = timer
	timer.timeout.connect(_on_legacy_timer_timeout.bind(argument_id), CONNECT_ONE_SHOT)


func _on_legacy_timer_timeout(argument_id: int) -> void:
	_legacy_timers.erase(argument_id)
	if not _legacy_pending.has(argument_id):
		return
	var target_id: int = _legacy_pending[argument_id]
	_legacy_pending.erase(argument_id)
	EventBus.emit(EventBus.EV_GAME_ARGUMENT_RESOLVED, {
		"argument_id": argument_id,
		"is_true": target_id == 2,  # the tutorial ghost villager is id 2
		"penalty_applied": false,
		"penalty_amount": 0.0,
	})


func _cancel_legacy_timer(argument_id: int) -> void:
	if not _legacy_timers.has(argument_id):
		return
	var timer: SceneTreeTimer = _legacy_timers[argument_id]
	if timer and timer.timeout.is_connected(_on_legacy_timer_timeout.bind(argument_id)):
		timer.timeout.disconnect(_on_legacy_timer_timeout.bind(argument_id))
	_legacy_timers.erase(argument_id)


func _cancel_legacy_timers() -> void:
	for argument_id in _legacy_timers.keys():
		_cancel_legacy_timer(argument_id)
	_legacy_timers.clear()

# ── Event handlers ────────────────────────────────────────────────────────────

## Match state changed: clear the per-phase argue flags on round boundaries.
func _on_match_state_changed(payload: Dictionary) -> void:
	var to_state: int = payload.get("to", -1)
	if to_state == GameState.MatchState.DRAWING:
		_argued_this_phase.clear()
		_legacy_pending.clear()
		_cancel_legacy_timers()
		print("ArgumentSystem: argue uses reset for new round")


## Each search phase gets a fresh argue budget (1 use per defender phase).
func _on_search_phase_started(_payload: Dictionary) -> void:
	_argued_this_phase.clear()