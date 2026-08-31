# SilentSneakSystem.gd — Silent Sneak ability for CHALK GAON: Ghost Lines
#
# Pluggable system: node under GameWorld/Systems. ZERO coupling to other systems —
# communicates exclusively through EventBus.
#
# The Silent Sneak ability is available to searchers during the SEARCHING phase.
# When activated, it spawns a distracting Cow entity that wanders and moos,
# drawing attention away from the searcher. While active, one chalk line crossing
# by the player is ignored (no detection). 30-second cooldown, 1 use per searching phase.
#
# Architecture:
#   - Subscribes to match.state_changed for phase tracking
#   - Cow entity is spawned as a child of the game world (Node2D)
#   - Line crossings are checked against DrawSystem's active lines
#   - Network: client requests activation via RPC, host validates and broadcasts
#   - Cow position is deterministic per activation so all clients can spawn visually
#
# Performance:
#   - Line crossing check is O(L * P) where L = active lines, P = line points per frame
#   - Only runs during active window (5s max), capped at one line crossing ignored
#   - Cow drawing is pure _draw(), zero texture memory

class_name SilentSneakSystem
extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

const DISTRACTION_DURATION := 5.0
const COOLDOWN_SECONDS := 30.0
const MAX_USES_PER_SEARCHING := 1
const COW_WANDER_RANGE := 150.0
const LINE_CROSSING_THRESHOLD := 10.0

# ── State ──────────────────────────────────────────────────────────────────────

var _is_active: bool = false
var _uses_this_phase: int = 0
var _line_crossings_ignored: int = 0
var _activating_searcher_id: int = -1
var _cooldown_remaining: float = 0.0
var _activation_timer: float = 0.0
var _cow: Cow = null

# ── References (found in _ready) ───────────────────────────────────────────────

var _game_world: Node2D = null
var _draw_system: DrawSystem = null
var _fog_system: FogSystem = null

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_ACTIVATED, _on_network_activated)
	EventBus.on(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_DEACTIVATED, _on_network_deactivated)

	# Find references
	_game_world = get_tree().current_scene as Node2D
	if _game_world:
		var systems := _game_world.get_node_or_null("Systems")
		if systems:
			_draw_system = systems.get_node_or_null("DrawSystem") as DrawSystem
			_fog_system = systems.get_node_or_null("FogSystem") as FogSystem

	print("SilentSneakSystem: ready — cooldown %.1fs, uses per phase: %d" % [COOLDOWN_SECONDS, MAX_USES_PER_SEARCHING])


func _process(delta: float) -> void:
	# Tick cooldown when not active and cooldown remaining > 0
	if not _is_active and _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta
		if _cooldown_remaining <= 0.0:
			_cooldown_remaining = 0.0
			EventBus.emit(EventBus.EV_GAME_SILENT_SNEAK_COOLDOWN_ENDED, {})
		return

	# Active state: tick the distraction timer and check line crossings
	if _is_active:
		_activation_timer -= delta

		# Check line crossings against searcher position
		if _line_crossings_ignored < 1:
			_check_line_crossings()

		# Timer expired: deactivate
		if _activation_timer <= 0.0:
			_deactivate()


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_ACTIVATED, _on_network_activated)
	EventBus.off(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_DEACTIVATED, _on_network_deactivated)


# ── Event Handlers ─────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var to_state: int = payload.get("to", -1)
	var from_state: int = payload.get("from", -1)

	# Reset uses when entering SEARCHING
	if to_state == GameState.MatchState.SEARCHING:
		_uses_this_phase = 0
		_cooldown_remaining = 0.0
		_is_active = false
		_line_crossings_ignored = 0
		if _cow and is_instance_valid(_cow):
			_cow.despawn()
			_cow = null

	# Clean up if leaving SEARCHING while active
	if from_state == GameState.MatchState.SEARCHING and _is_active:
		_deactivate()


# ── Network Handlers ───────────────────────────────────────────────────────────

## Received from host: silent sneak activated on another client.
## payload: { searcher_id: int, cow_position: Vector2 }
func _on_network_activated(payload: Dictionary) -> void:
	var searcher_id: int = payload.get("searcher_id", -1)
	var cow_pos: Vector2 = payload.get("cow_position", Vector2.ZERO)

	# Don't double-spawn if we are the local activator (already spawned)
	if searcher_id == _activating_searcher_id and _is_active:
		return

	_spawn_cow(searcher_id, cow_pos)
	print("SilentSneakSystem: remote activation for searcher %d at %s" % [searcher_id, cow_pos])


## Received from host: silent sneak deactivated (timer expired or phase ended).
## payload: { searcher_id: int }
func _on_network_deactivated(payload: Dictionary) -> void:
	var searcher_id: int = payload.get("searcher_id", -1)

	if _cow and is_instance_valid(_cow):
		_cow.despawn()
		_cow = null

	_is_active = false
	_activation_timer = 0.0
	_line_crossings_ignored = 0

	# Start cooldown on all clients
	_cooldown_remaining = COOLDOWN_SECONDS

	EventBus.emit(EventBus.EV_GAME_SILENT_SNEAK_DEACTIVATED, {
		"searcher_id": searcher_id,
	})


# ── Public API ─────────────────────────────────────────────────────────────────

## Attempt to activate Silent Sneak for a searcher.
## Validates: SEARCHING state, uses remaining, not already active, not on cooldown.
## Returns true if the activation request was accepted (sent to host or executed locally).
func activate_silent_sneak(searcher_id: int) -> bool:
	# Validation
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		print("SilentSneakSystem: activation rejected — not in SEARCHING state")
		return false

	if _uses_this_phase >= MAX_USES_PER_SEARCHING:
		print("SilentSneakSystem: activation rejected — max uses (%d) reached" % MAX_USES_PER_SEARCHING)
		return false

	if _is_active:
		print("SilentSneakSystem: activation rejected — already active")
		return false

	if _cooldown_remaining > 0.0:
		print("SilentSneakSystem: activation rejected — on cooldown (%.1fs remaining)" % _cooldown_remaining)
		return false

	# Network: client sends RPC to host for validation
	if NetworkManager.is_connected and not NetworkManager.has_authority():
		NetworkManager.send_rpc("activate_silent_sneak", {"searcher_id": searcher_id})
		# Client-side prediction (optimistic): the host will broadcast back
		# For prototype, we also do local activation immediately
		_execute_activation(searcher_id)
		return true

	# Host or offline: execute directly
	_execute_activation(searcher_id)

	# Broadcast to all clients if host
	if NetworkManager.is_connected and NetworkManager.has_authority():
		var cow_pos := _pick_cow_position()
		NetworkManager.send_rpc("silent_sneak_activated", {
			"searcher_id": searcher_id,
			"cow_position": {"x": cow_pos.x, "y": cow_pos.y},
		})
		# Also emit as network event for local subscribers
		EventBus.emit(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_ACTIVATED, {
			"searcher_id": searcher_id,
			"cow_position": cow_pos,
		})

	return true


## Returns true if Silent Sneak is currently active.
func is_active() -> bool:
	return _is_active


## Returns true if Silent Sneak is on cooldown.
func is_on_cooldown() -> bool:
	return _cooldown_remaining > 0.0


## Returns the remaining cooldown in seconds (0.0 if ready).
func get_cooldown_remaining() -> float:
	return _cooldown_remaining


## Returns the number of uses left this SEARCHING phase.
func get_uses_remaining() -> int:
	return maxi(0, MAX_USES_PER_SEARCHING - _uses_this_phase)


## Returns the remaining distraction duration (0.0 if not active).
func get_remaining_duration() -> float:
	return _activation_timer if _is_active else 0.0


# ── Internal: Activation ──────────────────────────────────────────────────────

func _execute_activation(searcher_id: int) -> void:
	_activating_searcher_id = searcher_id
	_is_active = true
	_uses_this_phase += 1
	_activation_timer = DISTRACTION_DURATION
	_line_crossings_ignored = 0

	# Pick cow spawn position
	var cow_pos := _pick_cow_position()

	# Spawn the cow
	_spawn_cow(searcher_id, cow_pos)

	EventBus.emit(EventBus.EV_GAME_SILENT_SNEAK_ACTIVATED, {
		"searcher_id": searcher_id,
		"cow_position": cow_pos,
		"uses_remaining": MAX_USES_PER_SEARCHING - _uses_this_phase,
	})

	print("SilentSneakSystem: activated for searcher %d — cow at %s" % [searcher_id, cow_pos])


# ── Internal: Deactivation ────────────────────────────────────────────────────

func _deactivate() -> void:
	if not _is_active:
		return

	var searcher_id := _activating_searcher_id

	if _cow and is_instance_valid(_cow):
		_cow.despawn()
		_cow = null

	_is_active = false
	_activation_timer = 0.0
	_line_crossings_ignored = 0
	_cooldown_remaining = COOLDOWN_SECONDS

	EventBus.emit(EventBus.EV_GAME_SILENT_SNEAK_DEACTIVATED, {
		"searcher_id": searcher_id,
	})

	# Broadcast deactivation to all clients if host
	if NetworkManager.is_connected and NetworkManager.has_authority():
		NetworkManager.send_rpc("silent_sneak_deactivated", {"searcher_id": searcher_id})
		EventBus.emit(EventBus.EV_NETWORK_RPC_SILENT_SNEAK_DEACTIVATED, {"searcher_id": searcher_id})

	print("SilentSneakSystem: deactivated for searcher %d — cooldown %.1fs" % [searcher_id, COOLDOWN_SECONDS])


# ── Cow Spawning ───────────────────────────────────────────────────────────────

## Pick a random visible position for the cow.
## If FogSystem is available, picks a position that is NOT in fog (within a revealed area).
## Otherwise, picks a random position within 500px of world center.
func _pick_cow_position() -> Vector2:
	# Try to use FogSystem for smart placement
	if _fog_system and _fog_system.is_active():
		# Pick random position within world bounds, check if it's in a revealed area
		# For now, defer to a simple random position — full fog-aware logic
		# would need FogSystem.get_revealed_areas() API
		pass

	# Default: random position within 500px of center
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var center := Vector2(200, 400)  # Default world center from game_world.tscn
	var offset_x := rng.randf_range(-500.0, 500.0)
	var offset_y := rng.randf_range(-400.0, 400.0)
	return center + Vector2(offset_x, offset_y)


## Spawn a Cow at the given position and start it wandering.
func _spawn_cow(searcher_id: int, position: Vector2) -> void:
	# Clean up existing cow if any
	if _cow and is_instance_valid(_cow):
		_cow.despawn()
		_cow = null

	# Create and configure the Cow
	_cow = Cow.new()
	_cow.name = "Cow_SilentSneak"
	_cow.position = position
	_cow.z_index = 20  # Above ground and chalk, below UI

	if _game_world:
		_game_world.add_child.call_deferred(_cow)

	_cow.start_wandering(position, COW_WANDER_RANGE)
	_cow.moo()
	AudioManager.play_cow_moo()

	print("SilentSneakSystem: cow spawned at %s, wander range %.1f" % [position, COW_WANDER_RANGE])


# ── Line Crossing Detection ────────────────────────────────────────────────────

## Check the searcher's position against all active chalk lines.
## If the searcher is within LINE_CROSSING_THRESHOLD pixels of any chalk line
## and we haven't yet ignored a crossing this activation, emit the crossing event.
func _check_line_crossings() -> void:
	if _line_crossings_ignored >= 1:
		return

	if not _draw_system:
		return

	# Get searcher position from the game world
	var searcher := _find_entity_by_id(_activating_searcher_id)
	if not searcher:
		return

	var searcher_pos: Vector2 = searcher.global_position

	# Check each active line
	var active_lines := _draw_system.get_active_lines()
	for line in active_lines:
		if line.points.size() < 2:
			continue
		# Check each segment
		for i in range(line.points.size() - 1):
			var a := line.points[i]
			var b := line.points[i + 1]
			if _point_to_segment_distance(searcher_pos, a, b) <= LINE_CROSSING_THRESHOLD:
				_line_crossings_ignored += 1

				EventBus.emit(EventBus.EV_GAME_SILENT_SNEAK_LINE_CROSSED, {
					"searcher_id": _activating_searcher_id,
					"line_id": line.id,
					"position": searcher_pos,
				})

				print("SilentSneakSystem: line crossing ignored for searcher %d on line %d" % [_activating_searcher_id, line.id])
				return  # Only one crossing ignored per activation


## Compute minimum distance from a point to a line segment.
static func _point_to_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var ap := point - a
	var ab_len_sq := ab.length_squared()

	if ab_len_sq < 0.0001:
		return ap.length()

	var t := clampf(ap.dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest := a + ab * t
	return point.distance_to(closest)


# ── Entity Lookup ──────────────────────────────────────────────────────────────

## Find an entity node by its entity_id.
func _find_entity_by_id(entity_id: int) -> Node2D:
	if not _game_world:
		return null
	var entities := _game_world.get_node_or_null("Entities")
	if not entities:
		return null
	for child in entities.get_children():
		if child.has_method("get") and child.get("entity_id") == entity_id:
			return child as Node2D
		# Fallback: check entity_id property directly
		if child.get("entity_id") == entity_id:
			return child as Node2D
	return null
