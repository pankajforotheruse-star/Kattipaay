# EventBus.gd — Global publish/subscribe event system
# All inter-system communication flows through this singleton.
# No system holds a direct reference to another system.

extends Node

# ── Event Name Constants ───────────────────────────────────────────
# Canonical registry of every EventBus event name. Systems MUST use
# these constants (EventBus.EV_*) instead of raw strings so typos are
# caught at parse time and renaming an event touches one place.
# Generated from actual code usage; keep in sync when adding events.
#
const EV_GAME_ARGUMENT_RESOLVED := "game.argument_resolved"
const EV_GAME_ARGUMENT_STARTED := "game.argument_started"
const EV_GAME_CHALK_EXHAUSTED := "game.chalk_exhausted"
const EV_GAME_CHALK_METER_CHANGED := "game.chalk_meter_changed"
const EV_GAME_CHALK_USED := "game.chalk_used"
const EV_GAME_CIRCLE_SEALED := "game.circle_sealed"
const EV_GAME_CLUSTER_BROKEN := "game.cluster_broken"
const EV_GAME_CLUSTER_FAILED := "game.cluster_failed"
const EV_GAME_CLUSTER_FORMED := "game.cluster_formed"
const EV_GAME_CLUSTER_SURVIVED := "game.cluster_survived"
const EV_GAME_DAILY_REWARD_CLAIMED := "game.daily_reward_claimed"
const EV_GAME_ENTITY_REGISTER := "game.entity_register"
const EV_GAME_ENTITY_UNREGISTER := "game.entity_unregister"
const EV_GAME_FOG_ACTIVATED := "game.fog_activated"
const EV_GAME_FOG_DEACTIVATED := "game.fog_deactivated"
const EV_GAME_FOG_GHOST_PULSE := "game.fog_ghost_pulse"
const EV_GAME_FOG_REVEALED := "game.fog_revealed"
const EV_GAME_GHOST_DRAW_ACTIVATED := "game.ghost_draw_activated"
const EV_GAME_GHOST_DRAW_PENALTY := "game.ghost_draw_penalty"
const EV_GAME_GHOST_LINE_DISCOVERED := "game.ghost_line_discovered"
const EV_GAME_GHOST_TOUCHES_LINE := "game.ghost_touches_line"
const EV_GAME_HINT_INVESTIGATED := "game.hint_investigated"
const EV_GAME_HINT_PLACED := "game.hint_placed"
const EV_GAME_HINT_REVEALED := "game.hint_revealed"
const EV_GAME_HINT_TRAP_TRIGGERED := "game.hint_trap_triggered"
const EV_GAME_LINE_DRAWN := "game.line_drawn"
const EV_GAME_LINE_EXPIRED := "game.line_expired"
const EV_GAME_LINE_REMOVED := "game.line_removed"
const EV_GAME_LINES_CONNECTED := "game.lines_connected"
const EV_GAME_PLAYER_ELIMINATED := "game.player_eliminated"
const EV_GAME_REWARDS_CLAIMED := "game.rewards_claimed"
const EV_GAME_ROUND_SCORE_CALCULATED := "game.round_score_calculated"
const EV_GAME_SCENE_LOADED := "game.scene_loaded"
const EV_GAME_SCORE_CHANGED := "game.score_changed"
const EV_GAME_SILENT_SNEAK_ACTIVATED := "game.silent_sneak_activated"
const EV_GAME_SILENT_SNEAK_COOLDOWN_ENDED := "game.silent_sneak_cooldown_ended"
const EV_GAME_SILENT_SNEAK_DEACTIVATED := "game.silent_sneak_deactivated"
const EV_GAME_SILENT_SNEAK_LINE_CROSSED := "game.silent_sneak_line_crossed"
const EV_GAME_SLOPPY_COUNT_FINISHED := "game.sloppy_count_finished"
const EV_GAME_SLOPPY_COUNT_RESULT := "game.sloppy_count_result"
const EV_GAME_SLOPPY_COUNT_STARTED := "game.sloppy_count_started"
const EV_GAME_SPECTATOR_REGISTERED := "game.spectator_registered"
const EV_GAME_SPECTATOR_REVEAL_USED := "game.spectator_reveal_used"
const EV_GAME_SPLASH_COMPLETE := "game.splash_complete"
const EV_GAME_STATE_CHANGED := "game.state_changed"
const EV_GAME_TIMER_EXPIRED := "game.timer_expired"
const EV_GAME_TIMER_PAUSED := "game.timer_paused"
const EV_GAME_TIMER_PENALTY := "game.timer_penalty"
const EV_GAME_TIMER_RESUMED := "game.timer_resumed"
const EV_GAME_TIMER_TICK := "game.timer_tick"
const EV_GAME_TOTAL_SCORE_UPDATED := "game.total_score_updated"
const EV_GAME_WAVE_ADVANCE := "game.wave_advance"
const EV_GAME_WINNER_DETERMINED := "game.winner_determined"
const EV_GAME_WORLD_READY := "game.world_ready"
const EV_INPUT_DRAW_END := "input.draw_end"
const EV_INPUT_DRAW_START := "input.draw_start"
const EV_INPUT_DRAW_UPDATE := "input.draw_update"
const EV_INPUT_MOVE_COMMAND_WORLD := "input.move_command_world"
const EV_INPUT_MOVE_END := "input.move_end"
const EV_INPUT_MOVE_START := "input.move_start"
const EV_INPUT_UNDO_DRAW := "input.undo_draw"
const EV_MATCH_DRAWING_STARTED := "match.drawing_started"
const EV_MATCH_SCORING_STARTED := "match.scoring_started"
const EV_MATCH_STATE_CHANGED := "match.state_changed"
const EV_NETWORK_CHALK_LINE_DRAWN := "network.chalk.line_drawn"
const EV_NETWORK_CHALK_LINE_REJECTED := "network.chalk.line_rejected"
const EV_NETWORK_CHALK_LINE_SYNC_BATCH := "network.chalk.line_sync_batch"
const EV_NETWORK_CHAT_SEND := "network.chat_send"
const EV_NETWORK_CONNECTED := "network.connected"
const EV_NETWORK_DISCONNECTED := "network.disconnected"
const EV_NETWORK_GHOST_LINES_PLACED := "network.ghost.lines_placed"
const EV_NETWORK_GHOST_LINES_REVEALED := "network.ghost.lines_revealed"
const EV_NETWORK_MATCH_FOUND := "network.match_found"
const EV_NETWORK_PLAYER_JOINED := "network.player_joined"
const EV_NETWORK_PLAYER_LEFT := "network.player_left"
const EV_NETWORK_PLAYER_READY := "network.player_ready"
const EV_NETWORK_PLAYER_READY_CHANGED := "network.player_ready_changed"
const EV_NETWORK_RPC_ARGUMENT_RESOLVED := "network.rpc.argument_resolved"
const EV_NETWORK_RPC_ARGUMENT_STARTED := "network.rpc.argument_started"
const EV_NETWORK_RPC_HINT_PLACED := "network.rpc.hint_placed"
const EV_NETWORK_RPC_HINT_RESOLVED := "network.rpc.hint_resolved"
const EV_NETWORK_RPC_HINT_REVEALED := "network.rpc.hint_revealed"
const EV_NETWORK_RPC_PLACE_FAKE_HINT := "network.rpc.place_fake_hint"
const EV_NETWORK_RPC_REQUEST_ARGUMENT := "network.rpc.request_argument"
const EV_NETWORK_RPC_SILENT_SNEAK_ACTIVATED := "network.rpc.silent_sneak_activated"
const EV_NETWORK_RPC_SILENT_SNEAK_DEACTIVATED := "network.rpc.silent_sneak_deactivated"
const EV_NETWORK_RPC_SPECTATOR_REVEAL := "network.rpc.spectator_reveal"
const EV_SAVE_LOCAL_COMPLETE := "save.local_complete"

# Internal storage: { "event.name": [Callable, Callable, ...] }
var _listeners: Dictionary = {}

## Subscribe to an event. The callback receives one argument: the payload.
func on(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		_listeners[event_name] = []
	var arr: Array = _listeners[event_name]
	if callback not in arr:
		arr.append(callback)

## Unsubscribe from an event.
func off(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		return
	var arr: Array = _listeners[event_name]
	var idx := arr.find(callback)
	if idx != -1:
		arr.remove_at(idx)
	# Clean up empty arrays
	if arr.is_empty():
		_listeners.erase(event_name)

## Emit an event with an optional payload. All subscribers are called.
func emit(event_name: String, payload = null) -> void:
	if not _listeners.has(event_name):
		return
	# Iterate over a copy — subscribers might add/remove during iteration
	var arr: Array = _listeners[event_name].duplicate()
	for callback in arr:
		if payload != null:
			callback.call(payload)
		else:
			callback.call()

## Remove all listeners (used on scene teardown or full reset).
func clear_all() -> void:
	_listeners.clear()

## Debug: list all registered events and subscriber counts.
func debug_print() -> void:
	print("=== EventBus Listeners ===")
	for event_name in _listeners:
		print("  %s → %d subscriber(s)" % [event_name, _listeners[event_name].size()])
	print("==========================")
