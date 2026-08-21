# HintSystem.gd — Hint Trap deception mechanic for CHALK GAON: Ghost Lines
#
# Pluggable system: node under GameWorld/Systems.
# Implements the three-role deception mechanic:
#   - Spectator (eliminated ghost): reveals ONE real ghost line per match
#   - Drawer (active ghost): places up to 3 fake hint traps (15 chalk each) during DRAWING
#   - Searcher: investigates hints (real or fake) by tapping within 80px range
#
# All communication through EventBus. Network flow follows existing patterns
# using NetworkManager stubs.
#
# Constraints:
#   - All visual markers meta-drawn via _draw(), no textures
#   - Hint markers exist in world space (Node2D under GameWorld)
#   - One spectator reveal per match
#   - Max 3 fake hints active, 15 chalk cost each
#   - Searcher must physically approach (80px) to investigate
#   - 2-second investigation cooldown

class_name HintSystem
extends Node

# ── Constants ─────────────────────────────────────────────────────────────────

const FAKE_HINT_CHALK_COST := 15.0
const MAX_FAKE_HINTS := 3
const REAL_HINT_REVEAL_DURATION := 8.0   # seconds the ghost line stays visible
const FAKE_HINT_PENALTY := 20            # seconds removed from match timer
const SPECTATOR_REVEALS_PER_MATCH := 1
const HINT_INVESTIGATE_RANGE := 80.0     # pixels
const INVESTIGATION_COOLDOWN := 2.0      # seconds between investigations
const FAKE_HINT_MIN_OFFSET := 20.0       # min px offset from actual line
const FAKE_HINT_MAX_OFFSET := 60.0       # max px offset from actual line
const FAKE_HINT_MIN_SEPARATION := 100.0  # min px between fake hints
const SPECTATOR_GHOST_LINE_OPACITY := 0.3  # 30% for spectator ghost line view

# ── Instance State ────────────────────────────────────────────────────────────

## Active hint markers: Array[HintMarker]
var _active_hints: Array[HintMarker] = []

## Per-spectator reveal count: { spectator_peer_id: int }
var _spectator_reveal_counts: Dictionary = {}

## Track which spectators exist (have been eliminated): { spectator_peer_id: bool }
var _spectators: Dictionary = {}

## Auto-incrementing hint ID counter.
var _next_hint_id: int = 0

## Timestamp of the last investigation (for cooldown).
var _last_investigation_time: float = -INVESTIGATION_COOLDOWN

## Reference to GameWorld.
var _game_world: Node2D = null

## Container Node2D for HintMarker nodes.
var _hint_container: Node2D = null

## Map from hint_id → reveal timer for real hints (to hide line after 8s).
var _reveal_timers: Dictionary = {}  # int → SceneTreeTimer

## Whether the local player is a spectator.
var _is_local_spectator: bool = false

## Local player entity ID.
var _local_entity_id: int = 1

## Whether the local player is a ghost/drawer.
var _is_local_drawer: bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
    # Subscribe to match state changes
    EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)

    # Subscribe to network RPC stubs for hint events
    EventBus.on(EventBus.EV_NETWORK_RPC_SPECTATOR_REVEAL, _on_rpc_spectator_reveal)
    EventBus.on(EventBus.EV_NETWORK_RPC_PLACE_FAKE_HINT, _on_rpc_place_fake_hint)
    EventBus.on(EventBus.EV_NETWORK_RPC_HINT_REVEALED, _on_rpc_hint_revealed)
    EventBus.on(EventBus.EV_NETWORK_RPC_HINT_PLACED, _on_rpc_hint_placed)
    EventBus.on(EventBus.EV_NETWORK_RPC_HINT_RESOLVED, _on_rpc_hint_resolved)

    # Subscribe to chalk events (for deducting fake hint cost)
    EventBus.on(EventBus.EV_GAME_CHALK_USED, _on_chalk_used)

    # Listen for player role changes
    EventBus.on(EventBus.EV_GAME_PLAYER_ELIMINATED, _on_player_eliminated)

    # Find GameWorld
    _game_world = get_tree().current_scene as Node2D

    # Create hint container
    _hint_container = Node2D.new()
    _hint_container.name = "HintMarkers"
    _hint_container.z_index = 15  # Above chalk lines
    if _game_world:
        _game_world.add_child(_hint_container)

    print("HintSystem: ready")


func _exit_tree() -> void:
    EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
    EventBus.off(EventBus.EV_NETWORK_RPC_SPECTATOR_REVEAL, _on_rpc_spectator_reveal)
    EventBus.off(EventBus.EV_NETWORK_RPC_PLACE_FAKE_HINT, _on_rpc_place_fake_hint)
    EventBus.off(EventBus.EV_NETWORK_RPC_HINT_REVEALED, _on_rpc_hint_revealed)
    EventBus.off(EventBus.EV_NETWORK_RPC_HINT_PLACED, _on_rpc_hint_placed)
    EventBus.off(EventBus.EV_NETWORK_RPC_HINT_RESOLVED, _on_rpc_hint_resolved)
    EventBus.off(EventBus.EV_GAME_CHALK_USED, _on_chalk_used)
    EventBus.off(EventBus.EV_GAME_PLAYER_ELIMINATED, _on_player_eliminated)


# ── Public API ────────────────────────────────────────────────────────────────

## Spectator reveals a real ghost line to all searchers.
## Called from spectator UI when they tap a ghost line.
func spectator_reveal_line(spectator_peer_id: int, line_id: int) -> bool:
    # Validate: spectator is eliminated
    if not _spectators.has(spectator_peer_id):
        push_warning("HintSystem: player %d is not a spectator" % spectator_peer_id)
        return false

    # Validate: hasn't used their reveal yet
    var used = _spectator_reveal_counts.get(spectator_peer_id, 0)
    if used >= SPECTATOR_REVEALS_PER_MATCH:
        push_warning("HintSystem: spectator %d already used their reveal" % spectator_peer_id)
        return false

    # Validate: line exists in GhostDrawSystem
    var ghost_sys = _get_ghost_draw_system()
    if not ghost_sys:
        push_warning("HintSystem: GhostDrawSystem not found")
        return false

    var ghost_lines = ghost_sys.get_active_ghost_lines()
    var target_line: ChalkLine = null
    for line in ghost_lines:
        if line.id == line_id:
            target_line = line
            break
    if not target_line:
        push_warning("HintSystem: ghost line %d not found" % line_id)
        return false

    # Mark reveal as used
    _spectator_reveal_counts[spectator_peer_id] = used + 1

    # Network: client → host
    if NetworkManager.is_connected and not NetworkManager.has_authority():
        NetworkManager.send_rpc("spectator_reveal", {
            "spectator_id": spectator_peer_id,
            "line_id": line_id,
        })

    # Create real HintMarker at line midpoint
    var midpoint := _compute_line_midpoint(target_line)
    var marker := _create_hint_marker(HintMarker.Type.REAL, midpoint)
    marker.associated_line_id = line_id
    marker.spectator_id = spectator_peer_id

    _active_hints.append(marker)
    if _hint_container:
        _hint_container.add_child(marker)

    # Emit event
    EventBus.emit(EventBus.EV_GAME_HINT_REVEALED, {
        "hint_id": marker.hint_id,
        "type": "real",
        "line_id": line_id,
        "spectator_id": spectator_peer_id,
    })

    EventBus.emit(EventBus.EV_GAME_SPECTATOR_REVEAL_USED, {
        "spectator_id": spectator_peer_id,
        "line_id": line_id,
    })

    # Broadcast to all clients
    if NetworkManager.is_connected and NetworkManager.has_authority():
        NetworkManager.send_rpc("hint_revealed", {
            "hint_id": marker.hint_id,
            "line_id": line_id,
            "spectator_id": spectator_peer_id,
            "position": {"x": midpoint.x, "y": midpoint.y},
        })

    print("HintSystem: spectator %d revealed line %d (hint %d)" % [spectator_peer_id, line_id, marker.hint_id])
    return true


## Ghost/drawer places a fake hint trap during DRAWING state.
## Called from DrawSystem input or long-press handler.
func place_fake_hint(drawer_peer_id: int, world_position: Vector2) -> bool:
    # Validate: in DRAWING state
    if GameState.get_match_state() != GameState.MatchState.DRAWING:
        push_warning("HintSystem: fake hints can only be placed during DRAWING")
        return false

    # Validate: under max fake hints
    var fake_count := _count_hints_by_type(HintMarker.Type.FAKE, drawer_peer_id)
    if fake_count >= MAX_FAKE_HINTS:
        push_warning("HintSystem: max %d fake hints already placed" % MAX_FAKE_HINTS)
        return false

    # Validate: not within 100px of another fake hint
    for hint in _active_hints:
        if hint.type == HintMarker.Type.FAKE and hint.is_active:
            if hint.position.distance_to(world_position) < FAKE_HINT_MIN_SEPARATION:
                return false

    # Validate: not on top of existing real lines (must be near but not ON)
    var draw_sys = _get_draw_system()
    if draw_sys:
        for line in draw_sys.get_active_lines():
            if line.is_ghost:
                continue
            for i in range(line.points.size() - 1):
                var dist := _point_to_segment_distance(world_position, line.points[i], line.points[i + 1])
                if dist < 5.0:  # On top of line
                    return false

    # Validate chalk cost (15 chalk) — emit chalk_used for DrawSystem to deduct
    EventBus.emit(EventBus.EV_GAME_CHALK_USED, {
        "amount": FAKE_HINT_CHALK_COST,
        "player_id": drawer_peer_id,
        "reason": "fake_hint",
    })

    # Network: client → host
    if NetworkManager.is_connected and not NetworkManager.has_authority():
        NetworkManager.send_rpc("place_fake_hint", {
            "drawer_id": drawer_peer_id,
            "position": {"x": world_position.x, "y": world_position.y},
        })

    # Apply random offset (20-60px from position, so it's plausibly "near" a line)
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var offset := Vector2(
        rng.randf_range(-FAKE_HINT_MAX_OFFSET, FAKE_HINT_MAX_OFFSET),
        rng.randf_range(-FAKE_HINT_MAX_OFFSET, FAKE_HINT_MAX_OFFSET)
    )
    # Clamp to at least MIN_OFFSET from the original position in at least one axis
    if abs(offset.x) < FAKE_HINT_MIN_OFFSET and abs(offset.y) < FAKE_HINT_MIN_OFFSET:
        if rng.randf() > 0.5:
            offset.x = FAKE_HINT_MIN_OFFSET * (1.0 if offset.x >= 0 else -1.0)
        else:
            offset.y = FAKE_HINT_MIN_OFFSET * (1.0 if offset.y >= 0 else -1.0)

    var final_pos := world_position + offset

    # Create fake HintMarker
    var marker := _create_hint_marker(HintMarker.Type.FAKE, final_pos)
    marker.drawer_id = drawer_peer_id

    _active_hints.append(marker)
    if _hint_container:
        _hint_container.add_child(marker)

    # Emit event
    EventBus.emit(EventBus.EV_GAME_HINT_PLACED, {
        "hint_id": marker.hint_id,
        "type": "fake",
        "position": {"x": final_pos.x, "y": final_pos.y},
        "drawer_id": drawer_peer_id,
    })

    # Broadcast
    if NetworkManager.is_connected and NetworkManager.has_authority():
        NetworkManager.send_rpc("hint_placed", {
            "hint_id": marker.hint_id,
            "drawer_id": drawer_peer_id,
            "position": {"x": final_pos.x, "y": final_pos.y},
        })

    print("HintSystem: drawer %d placed fake hint %d at %s" % [drawer_peer_id, marker.hint_id, final_pos])
    return true


## Searcher investigates a hint by tapping it within range.
## Called from InputManager/HUD when a hint marker is tapped.
func investigate_hint(searcher_peer_id: int, hint_id: int, searcher_position: Vector2) -> bool:
    # Validate: in SEARCHING state
    if GameState.get_match_state() != GameState.MatchState.SEARCHING:
        return false

    # Cooldown check
    var now := Time.get_ticks_msec() / 1000.0
    if now - _last_investigation_time < INVESTIGATION_COOLDOWN:
        return false

    # Find the hint marker
    var marker: HintMarker = null
    for hint in _active_hints:
        if hint.hint_id == hint_id and hint.is_active:
            marker = hint
            break
    if not marker:
        return false

    # Range check
    var dist := searcher_position.distance_to(marker.position)
    if dist > HINT_INVESTIGATE_RANGE:
        return false

    # Network: client → host
    if NetworkManager.is_connected and not NetworkManager.has_authority():
        NetworkManager.send_rpc("investigate_hint", {
            "searcher_id": searcher_peer_id,
            "hint_id": hint_id,
        })

    # Resolve locally (host/server will broadcast authoritative result)
    _resolve_hint(searcher_peer_id, marker)

    return true


## Clear all hints — called on round end.
func clear_all_hints() -> void:
    # Kill all reveal timers
    for timer in _reveal_timers.values():
        if timer is SceneTreeTimer and timer.time_left > 0:
            pass  # Can't cancel SceneTreeTimer cleanly; the callbacks check validity

    _reveal_timers.clear()

    # Remove all markers
    for hint in _active_hints:
        if hint is HintMarker and is_instance_valid(hint):
            hint.queue_free()
    _active_hints.clear()

    print("HintSystem: cleared all hints")


## Register a player as eliminated (now a spectator).
func register_spectator(peer_id: int) -> void:
    _spectators[peer_id] = true
    if not _spectator_reveal_counts.has(peer_id):
        _spectator_reveal_counts[peer_id] = 0

    if peer_id == _local_entity_id:
        _is_local_spectator = true

    EventBus.emit(EventBus.EV_GAME_SPECTATOR_REGISTERED, {"spectator_id": peer_id})


## Get the number of active hints for HUD display.
func get_active_hint_count() -> int:
    var count := 0
    for hint in _active_hints:
        if hint.is_active:
            count += 1
    return count


# ── Internal Resolution ───────────────────────────────────────────────────────

func _resolve_hint(searcher_peer_id: int, marker: HintMarker) -> void:
    _last_investigation_time = Time.get_ticks_msec() / 1000.0

    if marker.type == HintMarker.Type.REAL:
        # Real hint — reveal the associated ghost line for 8s
        var line_id := marker.associated_line_id
        marker.play_real_result()

        # Reveal the ghost line
        _reveal_ghost_line(line_id, searcher_peer_id)

        # Schedule hiding after 8s
        var tree := get_tree()
        if tree:
            var timer := tree.create_timer(REAL_HINT_REVEAL_DURATION)
            timer.timeout.connect(func():
                _hide_ghost_line(line_id, searcher_peer_id)
            , CONNECT_ONE_SHOT)
            _reveal_timers[marker.hint_id] = timer

        EventBus.emit(EventBus.EV_GAME_HINT_INVESTIGATED, {
            "hint_id": marker.hint_id,
            "is_trap": false,
            "searcher_id": searcher_peer_id,
        })

    else:
        # Fake hint — trap triggered!
        marker.play_fake_result()

        # Apply 20s penalty to match timer
        MatchTimer.remove_time(FAKE_HINT_PENALTY)

        EventBus.emit(EventBus.EV_GAME_HINT_TRAP_TRIGGERED, {
            "hint_id": marker.hint_id,
            "is_trap": true,
            "penalty": FAKE_HINT_PENALTY,
            "searcher_id": searcher_peer_id,
        })

    # Broadcast resolution
    if NetworkManager.is_connected and NetworkManager.has_authority():
        NetworkManager.send_rpc("hint_resolved", {
            "hint_id": marker.hint_id,
            "is_trap": marker.type == HintMarker.Type.FAKE,
            "searcher_id": searcher_peer_id,
        })

    # Remove from active after animation
    _remove_hint_after_delay(marker)


# ── Ghost Line Visibility Helpers ─────────────────────────────────────────────

func _reveal_ghost_line(line_id: int, searcher_id: int) -> void:
    # Emit network event so all clients show the line
    var payload := {
        "line_ids": [line_id],
        "penalty_applied": false,
        "reveal_duration": REAL_HINT_REVEAL_DURATION,
    }
    # Re-use GhostDrawSystem's existing reveal mechanism
    EventBus.emit(EventBus.EV_NETWORK_GHOST_LINES_REVEALED, payload)


func _hide_ghost_line(line_id: int, _searcher_id: int) -> void:
    # After 8s, hide the line again
    var ghost_sys = _get_ghost_draw_system()
    if ghost_sys:
        for line in ghost_sys.get_active_ghost_lines():
            if line.id == line_id:
                line.is_discovered = false
                break
    # In full implementation, would send RPC to hide


# ── Event Handlers ────────────────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
    var to_state: int = payload.get("to", -1)
    var from_state: int = payload.get("from", -1)

    # Fake hints are only placed during DRAWING; they must survive the
    # DRAWING -> SEARCHING transition so the searcher can investigate them.
    # Clear on a fresh DRAWING entry (new round) and when SEARCHING ends,
    # but keep hints while paused mid-argument.
    if to_state == GameState.MatchState.DRAWING and from_state != GameState.MatchState.PAUSED:
        clear_all_hints()
    elif from_state == GameState.MatchState.SEARCHING and to_state != GameState.MatchState.PAUSED:
        clear_all_hints()

    # Reset spectator reveals on new match start
    if to_state == GameState.MatchState.WAITING:
        _spectator_reveal_counts.clear()
        _spectators.clear()
        _is_local_spectator = false


## Chalk used event — DrawSystem (the chalk owner) applies the deduction via
## this event (audit m4); this listener only logs.
func _on_chalk_used(payload: Dictionary) -> void:
    var reason: String = payload.get("reason", "")
    if reason == "fake_hint":
        print("HintSystem: chalk deducted for fake hint — %.0f" % payload.get("amount", 0.0))


## Player eliminated → becomes spectator.
func _on_player_eliminated(payload: Dictionary) -> void:
    var player_id: int = payload.get("player_id", -1)
    if player_id > 0:
        register_spectator(player_id)


# ── Network RPC Handlers ─────────────────────────────────────────────────────

func _on_rpc_spectator_reveal(payload: Dictionary) -> void:
    if not NetworkManager.has_authority():
        return
    var spectator_id: int = payload.get("spectator_id", -1)
    var line_id: int = payload.get("line_id", -1)
    spectator_reveal_line(spectator_id, line_id)


func _on_rpc_place_fake_hint(payload: Dictionary) -> void:
    if not NetworkManager.has_authority():
        return
    var drawer_id: int = payload.get("drawer_id", -1)
    var pos_dict: Dictionary = payload.get("position", {})
    var pos := Vector2(pos_dict.get("x", 0.0), pos_dict.get("y", 0.0))
    place_fake_hint(drawer_id, pos)


func _on_rpc_hint_revealed(payload: Dictionary) -> void:
    # Another client's spectator reveal — create the marker locally
    var hint_id: int = payload.get("hint_id", -1)
    var line_id: int = payload.get("line_id", -1)
    var spectator_id: int = payload.get("spectator_id", -1)
    var pos_dict: Dictionary = payload.get("position", {})
    var pos := Vector2(pos_dict.get("x", 0.0), pos_dict.get("y", 0.0))

    # Check we don't already have this hint
    if _find_hint_by_id(hint_id):
        return

    var marker := _create_hint_marker(HintMarker.Type.REAL, pos)
    marker.hint_id = hint_id
    marker.associated_line_id = line_id
    marker.spectator_id = spectator_id

    _active_hints.append(marker)
    if _hint_container:
        _hint_container.add_child(marker)

    # Update spectator count
    if not _spectator_reveal_counts.has(spectator_id):
        _spectator_reveal_counts[spectator_id] = 0
    _spectator_reveal_counts[spectator_id] += 1


func _on_rpc_hint_placed(payload: Dictionary) -> void:
    # Another client placed a fake hint — create the marker locally
    var hint_id: int = payload.get("hint_id", -1)
    var drawer_id: int = payload.get("drawer_id", -1)
    var pos_dict: Dictionary = payload.get("position", {})
    var pos := Vector2(pos_dict.get("x", 0.0), pos_dict.get("y", 0.0))

    if _find_hint_by_id(hint_id):
        return

    var marker := _create_hint_marker(HintMarker.Type.FAKE, pos)
    marker.hint_id = hint_id
    marker.drawer_id = drawer_id

    _active_hints.append(marker)
    if _hint_container:
        _hint_container.add_child(marker)


func _on_rpc_hint_resolved(payload: Dictionary) -> void:
    # Server/host broadcast: hint resolved — animate locally
    var hint_id: int = payload.get("hint_id", -1)
    var is_trap: bool = payload.get("is_trap", false)
    var searcher_id: int = payload.get("searcher_id", -1)

    var marker := _find_hint_by_id(hint_id)
    if not marker or not marker.is_active:
        return

    if is_trap:
        EventBus.emit(EventBus.EV_GAME_HINT_TRAP_TRIGGERED, {
            "hint_id": hint_id,
            "is_trap": true,
            "penalty": FAKE_HINT_PENALTY,
            "searcher_id": searcher_id,
        })
        marker.play_fake_result()
    else:
        EventBus.emit(EventBus.EV_GAME_HINT_INVESTIGATED, {
            "hint_id": hint_id,
            "is_trap": false,
            "searcher_id": searcher_id,
        })
        marker.play_real_result()

    _remove_hint_after_delay(marker)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _create_hint_marker(type: int, pos: Vector2) -> HintMarker:
    var marker := HintMarker.new()
    marker.type = type
    marker.position = pos
    marker.hint_id = _next_hint_id
    _next_hint_id += 1
    marker.is_active = true

    # If local is spectator, enable spectator view
    if _is_local_spectator:
        marker.set_spectator_view(true)

    return marker


func _find_hint_by_id(hint_id: int) -> HintMarker:
    for hint in _active_hints:
        if hint.hint_id == hint_id and hint.is_active:
            return hint
    return null


func _remove_hint_after_delay(marker: HintMarker) -> void:
    # Remove from active array after a short delay (animation completes)
    var tree := get_tree()
    if tree:
        tree.create_timer(0.6).timeout.connect(func():
            var idx := _active_hints.find(marker)
            if idx != -1:
                _active_hints.remove_at(idx)
        , CONNECT_ONE_SHOT)


func _count_hints_by_type(type: int, _owner_id: int = -1) -> int:
    var count := 0
    for hint in _active_hints:
        if hint.type == type and hint.is_active:
            count += 1
    return count


func _compute_line_midpoint(line: ChalkLine) -> Vector2:
    if line.points.is_empty():
        return Vector2.ZERO
    if line.points.size() == 1:
        return line.points[0]
    var mid_idx := line.points.size() / 2
    return line.points[mid_idx]


func _point_to_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
    var ab := b - a
    var ap := point - a
    var ab_len_sq := ab.length_squared()
    if ab_len_sq < 0.0001:
        return ap.length()
    var t := clampf(ap.dot(ab) / ab_len_sq, 0.0, 1.0)
    var closest := a + ab * t
    return point.distance_to(closest)


func _get_ghost_draw_system():
    var systems_node := get_parent()
    if not systems_node:
        return null
    return systems_node.get_node_or_null("GhostDrawSystem")


func _get_draw_system():
    var systems_node := get_parent()
    if not systems_node:
        return null
    return systems_node.get_node_or_null("DrawSystem")
