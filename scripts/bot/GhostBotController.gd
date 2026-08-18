# GhostBotController.gd — Solo "Play vs CPU" ghost AI for CHALK GAON: Ghost Lines
#
# The bot plays the GHOST role (entity id 2) against the human searcher (id 1)
# in solo mode. It is an IN-PROCESS MOCK NETWORK PEER: it never mutates other
# systems directly. Observation is exclusively EventBus listeners + public
# getters; action is emitting the exact EventBus payloads that a remote
# NetworkManager's decoded wire message would produce:
#
#   - Ghost line placement: EV_NETWORK_GHOST_LINES_PLACED
#     {"lines": Array[Dictionary], "owner_id": 2} — consumed by
#     GhostDrawSystem._on_network_ghost_lines_placed (the same seam
#     docs/networking.md §14 describes for decoded messages). GhostDrawSystem
#     rebuilds the lines as invisible ghost lines (chalk_type GHOST,
#     decay -1) and assigns IDs (the bot sends the -1 "unconfirmed" sentinel).
#     The bot respects the system's constraints: 2 lines per placement, max 4
#     active, once per round.
#   - Accusation: EV_NETWORK_RPC_ARGUMENT_STARTED
#     {"accuser_id": 2, "target_id": 1, "accusation_text": String,
#      "argument_id": int, "timestamp": float} — consumed by
#     ArgumentSystem._on_rpc_argument_started (full pause → 3s resolve →
#     penalty flow; a false accusation removes randf_range(3.0, 10.0)s).
#
# Difficulty brain (utility-style Guilt Confidence 0.0–1.0 drives accusations):
#   EASY     — zero memory, acts only on current-frame data; randf() anchor
#              near a world edge (clamped to FogSystem world bounds); random
#              5–15s placement delay after SEARCHING; accusation is pure
#              randf().
#   NORMAL   — remembers the last 3 searcher line-draw centroids
#              (EV_GAME_LINE_DRAWN → DrawSystem.get_active_lines()); targets
#              their centroid fuzzed ±100px; places briefly after observing.
#   HARD     — heatmap / spatial hash of the searcher's line-drawing density;
#              targets the densest cell (own heatmap, cross-checked against
#              ClusterSystem's surviving-cluster bounds) and places in the
#              path leading to the hot zone; guilt rises on silent-sneak
#              events and rapid line drawing; accuses at confidence > 0.7.
#   NIGHTMARE— explored/unexplored fog model fed by EV_GAME_FOG_REVEALED
#              circles; searcher velocity + heading derived from
#              EV_INPUT_MOVE_COMMAND_WORLD target history (dot-product
#              smoothing, reversal snap); places the ghost line at the
#              unrevealed-fog edge in the searcher's heading so the reaction
#              budget is < 0.5s; game-theoretic accusation: if the searcher
#              stops moving shortly after a line placement (they noticed it),
#              immediately fire a false accusation (confidence 1.0).
#
# Optimized: distance-squared over sqrt where possible, dot products for
# heading/prediction, no per-frame allocations in hot paths (the per-frame
# _process only ticks timers and does state checks), heavy CALCULATING work is
# event-driven or throttled at ≥0.5s cadence.

class_name GhostBotController
extends Node

enum Difficulty { EASY, NORMAL, HARD, NIGHTMARE }
enum AIState { IDLE, OBSERVING, CALCULATING, ACTING }

# ── Roles ────────────────────────────────────────────────────────────────────
## The bot is the ghost; id 2 matches ArgumentSystem._is_target_ghost
## (target_id == 2) and Tutorial.GHOST_TARGET_ID.
const GHOST_ENTITY_ID := 2
const HUMAN_ENTITY_ID := 1

# ── Placement geometry (mirrors GhostDrawSystem's line generation) ───────────
const LINES_PER_PLACEMENT := 2
const MAX_ACTIVE_GHOST_LINES := 4
const MIN_LINE_LENGTH := 100.0
const MAX_LINE_LENGTH := 200.0
const MIN_LINE_SEPARATION := 50.0
const MAX_LINE_SEPARATION := 150.0
const WORLD_EDGE_MARGIN := 120.0
## Fallback world bounds when FogSystem is unavailable (its default size).
const WORLD_BOUNDS_FALLBACK := Vector2(2400.0, 1800.0)

# ── Difficulty timing ────────────────────────────────────────────────────────
const EASY_PLACE_DELAY_MIN := 5.0
const EASY_PLACE_DELAY_MAX := 15.0
const NORMAL_PLACE_DELAY := 2.5      # brief wait after observing a line
const HARD_PLACE_DELAY := 1.5
const OBSERVE_FALLBACK_SECONDS := 6.0  # place even if the searcher drew nothing
const NORMAL_FUZZ := 100.0
const HARD_FUZZ := 60.0

# ── Guilt / accusation ───────────────────────────────────────────────────────
const ACCUSE_THRESHOLD_NORMAL := 0.75
const ACCUSE_THRESHOLD_HARD := 0.7
const ACCUSE_THRESHOLD_NIGHTMARE := 0.85
const EASY_ACCUSE_ROLL := 0.7          # EASY accuses when randf() > 0.7
const ACCUSATION_CHECK_INTERVAL := 1.5 # seconds between guilt re-checks
const RAPID_DRAW_WINDOW := 10.0        # seconds
const RAPID_DRAW_LINES := 3            # lines within the window → "rapid"
const STOP_THRESHOLD := 1.0            # NIGHTMARE: searcher idle (seconds)
const STOP_WATCH_WINDOW := 3.0         # NIGHTMARE: watch after our placement
const REACTION_BUDGET := 0.5           # NIGHTMARE: seconds of travel to line
const THINK_THROTTLE := 0.5            # min seconds between heavy calculations
const MAX_EXPLORED_CIRCLES := 64
const MAX_MOVE_SAMPLES := 16
const LINE_POS_MEMORY := 3             # NORMAL memory depth
const HEATMAP_CELL := 100.0            # HARD spatial hash cell size (px)

# ── Config ───────────────────────────────────────────────────────────────────
## Difficulty enum value (set by the solo driver from GameState.cpu_difficulty).
var difficulty: int = Difficulty.NORMAL

# ── Observational memory (all event-fed, per round) ──────────────────────────
var _searcher_line_centroids: Array[Vector2] = []  # NORMAL
var _heatmap: Dictionary = {}                       # HARD: "cx_cy" → {density, center}
var _explored_circles: Array[Dictionary] = []       # NIGHTMARE: {position, radius}
var _move_samples: Array[Dictionary] = []           # NIGHTMARE: {target, t}
var _draw_timestamps: Array[float] = []             # HARD: rapid-draw window
var _last_move_time: float = -INF
var _last_heading := Vector2.RIGHT
var _guilt: float = 0.0

# ── Round state ──────────────────────────────────────────────────────────────
var ai_state: int = AIState.IDLE
var _lines_placed_this_round: bool = false
var _accused_this_round: bool = false
var _placement_anchor := Vector2.ZERO
var _placement_delay: float = 0.0
var _placement_due: bool = false
var _fallback_timer: float = 0.0
var _accuse_check_timer: float = 0.0
var _rapid_draw_bumped: bool = false
var _watch_armed: bool = false
var _watch_deadline: float = -INF
var _next_argument_id: int = 10_000  # bot namespace, clear of ArgumentSystem's 0..n
var _last_accusation_index: int = -1

# ── References (public getters only) ─────────────────────────────────────────
var _game_world: Node2D = null
var _draw_sys: DrawSystem = null
var _ghost_sys: GhostDrawSystem = null
var _arg_sys: ArgumentSystem = null
var _cluster_sys: ClusterSystem = null
var _fog_sys: FogSystem = null
var _rng := RandomNumberGenerator.new()

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_rng.randomize()
	_find_systems()

	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.on(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.on(EventBus.EV_GAME_FOG_REVEALED, _on_fog_revealed)
	EventBus.on(EventBus.EV_INPUT_MOVE_COMMAND_WORLD, _on_move_command)
	EventBus.on(EventBus.EV_GAME_SILENT_SNEAK_ACTIVATED, _on_silent_sneak_activated)
	EventBus.on(EventBus.EV_GAME_SILENT_SNEAK_LINE_CROSSED, _on_silent_sneak_line_crossed)
	EventBus.on(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, _on_ghost_line_discovered)

	_ai_enter(AIState.IDLE)
	print("GhostBot: ready (difficulty %s, ghost id %d)" % [Difficulty.keys()[difficulty], GHOST_ENTITY_ID])


func _process(delta: float) -> void:
	# Cheap per-frame path: state checks + timer ticks only.
	_ai_tick(delta)


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)
	EventBus.off(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.off(EventBus.EV_GAME_FOG_REVEALED, _on_fog_revealed)
	EventBus.off(EventBus.EV_INPUT_MOVE_COMMAND_WORLD, _on_move_command)
	EventBus.off(EventBus.EV_GAME_SILENT_SNEAK_ACTIVATED, _on_silent_sneak_activated)
	EventBus.off(EventBus.EV_GAME_SILENT_SNEAK_LINE_CROSSED, _on_silent_sneak_line_crossed)
	EventBus.off(EventBus.EV_GAME_GHOST_LINE_DISCOVERED, _on_ghost_line_discovered)


# ── AI state machine ─────────────────────────────────────────────────────────

func _ai_enter(state: int) -> void:
	ai_state = state


## Per-frame brain tick. Does work only during DRAWING/SEARCHING and never
## while an argument holds the match in PAUSED.
func _ai_tick(delta: float) -> void:
	var ms := GameState.get_match_state()
	if ms != GameState.MatchState.DRAWING and ms != GameState.MatchState.SEARCHING:
		return

	# NIGHTMARE: arm placement once we have movement data + fog is live.
	if difficulty == Difficulty.NIGHTMARE and not _lines_placed_this_round \
			and _placement_delay <= 0.0 and not _placement_due \
			and _move_samples.size() >= 2 and ms == GameState.MatchState.SEARCHING:
		_schedule_placement(1.0)

	if _placement_delay > 0.0:
		_placement_delay -= delta
		if _placement_delay <= 0.0:
			_placement_delay = 0.0
			_placement_due = true
	elif _fallback_timer > 0.0:
		# NORMAL/HARD: if the searcher drew nothing, still place near them.
		_fallback_timer -= delta
		if _fallback_timer <= 0.0:
			_fallback_timer = 0.0
			if not _lines_placed_this_round and _placement_delay <= 0.0 and not _placement_due:
				_placement_anchor = _clamp_to_bounds(_searcher_position(), WORLD_EDGE_MARGIN)
				_schedule_placement(1.0)

	if _placement_due:
		_ai_enter(AIState.ACTING)
		_execute_placement()
		_ai_enter(AIState.OBSERVING)

	# Accusation cadence (SEARCHING only), throttled.
	if ms == GameState.MatchState.SEARCHING:
		_accuse_check_timer -= delta
		if _accuse_check_timer <= 0.0:
			_accuse_check_timer = ACCUSATION_CHECK_INTERVAL
			_maybe_accuse()
		# NIGHTMARE game-theoretic watch: searcher stopped shortly after a
		# placement → they noticed the line → false accusation, confidence 1.0.
		if difficulty == Difficulty.NIGHTMARE and _watch_armed:
			var now := _now()
			if now > _watch_deadline:
				_watch_armed = false
			elif now - _last_move_time > STOP_THRESHOLD:
				_watch_armed = false
				_forced_accuse()


# ── Placement ────────────────────────────────────────────────────────────────

func _schedule_placement(delay: float) -> void:
	_placement_delay = delay
	_placement_due = false


func _can_place() -> bool:
	if _lines_placed_this_round:
		return false
	if not _ghost_sys:
		return false
	if not _ghost_sys.is_ghost_draw_available():
		return false
	return _ghost_sys.get_active_ghost_lines().size() + LINES_PER_PLACEMENT <= MAX_ACTIVE_GHOST_LINES


func _execute_placement() -> void:
	_placement_due = false
	if not _can_place():
		return

	var anchor := Vector2.ZERO
	match difficulty:
		Difficulty.EASY:
			anchor = _easy_anchor()
		Difficulty.NIGHTMARE:
			anchor = _compute_nightmare_anchor()
		_:
			anchor = _placement_anchor  # computed when the observation arrived
	anchor = _clamp_to_bounds(anchor, WORLD_EDGE_MARGIN)

	var dicts := _build_line_dicts(anchor)
	EventBus.emit(EventBus.EV_NETWORK_GHOST_LINES_PLACED, {
		"lines": dicts,
		"owner_id": GHOST_ENTITY_ID,
	})
	_lines_placed_this_round = true
	if difficulty == Difficulty.NIGHTMARE and not _accused_this_round:
		_watch_armed = true
		_watch_deadline = _now() + STOP_WATCH_WINDOW
	print("GhostBot: placed %d ghost lines at %s (difficulty %s)" % [
		dicts.size(), anchor, Difficulty.keys()[difficulty]
	])


## Build the exact ChalkLine network dictionaries a remote ghost client would
## send (to_network_dict keys: id/ct/pid/t/dd/cn/pc/pd/wd/gh/go/gp/gd).
func _build_line_dicts(anchor: Vector2) -> Array[Dictionary]:
	var dicts: Array[Dictionary] = []
	var angle1 := _rng.randf_range(0.0, TAU)
	var angle_offset := _rng.randf_range(PI / 3.0, 2.0 * PI / 3.0)
	var angle2 := angle1 + angle_offset * (1.0 if _rng.randf() > 0.5 else -1.0)
	var sep := _rng.randf_range(MIN_LINE_SEPARATION, MAX_LINE_SEPARATION)
	var start1 := _clamp_to_bounds(anchor, WORLD_EDGE_MARGIN)
	var start2 := _clamp_to_bounds(anchor + Vector2.RIGHT.rotated(angle1) * sep, WORLD_EDGE_MARGIN)
	dicts.append(_build_one_line_dict(start1, angle1, _rng.randf_range(MIN_LINE_LENGTH, MAX_LINE_LENGTH)))
	dicts.append(_build_one_line_dict(start2, angle2, _rng.randf_range(MIN_LINE_LENGTH, MAX_LINE_LENGTH)))
	return dicts


func _build_one_line_dict(start: Vector2, angle: float, length: float) -> Dictionary:
	var line := ChalkLine.new()
	var end := start + Vector2.RIGHT.rotated(angle) * length
	var width := ChalkLine.BASE_WIDTHS[ChalkLine.ChalkType.GHOST]
	if _rng.randf() > 0.5:
		line.points = [start, end]
		line.widths = [width, width]
	else:
		# Slight curve via a perpendicular-perturbed midpoint (2–3 control pts).
		var mid := (start + end) * 0.5
		var perp := Vector2.RIGHT.rotated(angle + PI / 2.0)
		mid += perp * _rng.randf_range(-length * 0.2, length * 0.2)
		line.points = [start, mid, end]
		line.widths = [width, width, width]

	line.id = -1  # -1 unconfirmed sentinel → GhostDrawSystem assigns an ID
	line.chalk_type = ChalkLine.ChalkType.GHOST
	line.player_id = GHOST_ENTITY_ID
	line.created_at = Time.get_ticks_msec()
	line.decay_duration = ChalkLine.GHOST_DECAY_SENTINEL
	line.is_ghost = true
	line.is_discovered = false
	line.ghost_owner_id = GHOST_ENTITY_ID
	line.ghost_placed_at = Time.get_ticks_msec()
	return line.to_network_dict()


# ── Anchor computation per difficulty ────────────────────────────────────────

## EASY: random point on a random world edge, clamped into bounds.
func _easy_anchor() -> Vector2:
	var b := _world_bounds()
	var p := Vector2.ZERO
	match _rng.randi_range(0, 3):
		0:
			p = Vector2(_rng.randf_range(b.position.x, b.position.x + b.size.x), b.position.y)
		1:
			p = Vector2(_rng.randf_range(b.position.x, b.position.x + b.size.x), b.position.y + b.size.y)
		2:
			p = Vector2(b.position.x, _rng.randf_range(b.position.y, b.position.y + b.size.y))
		_:
			p = Vector2(b.position.x + b.size.x, _rng.randf_range(b.position.y, b.position.y + b.size.y))
	return _clamp_to_bounds(p, WORLD_EDGE_MARGIN)


## NORMAL: centroid of the remembered line-draw positions, fuzzed ±100px.
func _normal_anchor() -> Vector2:
	var base := Vector2.ZERO
	if _searcher_line_centroids.is_empty():
		base = _searcher_position()
	else:
		var sum := Vector2.ZERO
		for p in _searcher_line_centroids:
			sum += p
		base = sum / float(_searcher_line_centroids.size())
	return _clamp_to_bounds(
		base + Vector2(_rng.randf_range(-NORMAL_FUZZ, NORMAL_FUZZ), _rng.randf_range(-NORMAL_FUZZ, NORMAL_FUZZ)),
		WORLD_EDGE_MARGIN
	)


## HARD: highest-density heatmap cell (cross-checked with surviving clusters);
## place in the path leading to the hot zone (60% of the way from the
## searcher's last centroid toward the target).
func _hard_anchor(last_centroid: Vector2) -> Vector2:
	var target := Vector2.ZERO
	var has_heat := not _heatmap.is_empty()
	if has_heat:
		target = _hottest_cell_center()
	elif _cluster_sys:
		var clusters: Array[Cluster] = _cluster_sys.get_surviving_clusters()
		if not clusters.is_empty():
			target = clusters[0].get_bounds().get_center()
			has_heat = true
	var from := last_centroid
	if from == Vector2.ZERO:
		from = _searcher_position()
	var base := from.lerp(target, 0.6) if has_heat else from
	return _clamp_to_bounds(
		base + Vector2(_rng.randf_range(-HARD_FUZZ, HARD_FUZZ), _rng.randf_range(-HARD_FUZZ, HARD_FUZZ)),
		WORLD_EDGE_MARGIN
	)


## NIGHTMARE: walk the searcher's heading from their vision edge into the
## unrevealed fog; place the line just past the fog edge so the reaction
## budget (time before the searcher's vision circle would reach it at their
## current speed) is < REACTION_BUDGET seconds.
func _compute_nightmare_anchor() -> Vector2:
	var searcher_pos := _searcher_position()
	var speed := _searcher_speed()
	var heading := _last_heading
	if speed < 20.0:
		# Idle searcher: place at the edge of their current vision circle.
		var edge := searcher_pos + heading * FogSystem.VISION_RADIUS
		return _clamp_to_bounds(edge + heading * 60.0, WORLD_EDGE_MARGIN)
	var step := 40.0
	var dist := FogSystem.VISION_RADIUS
	var edge_point := searcher_pos + heading * dist
	while dist < 700.0:
		var p := searcher_pos + heading * dist
		if not _is_explored(p):
			edge_point = p
			break
		edge_point = p
		dist += step
	var budget_reach := speed * REACTION_BUDGET
	return _clamp_to_bounds(edge_point + heading * (budget_reach + 40.0), WORLD_EDGE_MARGIN)


func _is_explored(p: Vector2) -> bool:
	for circle in _explored_circles:
		var c: Vector2 = circle["position"]
		var r: float = circle["radius"]
		if p.distance_squared_to(c) <= r * r:
			return true
	return false


# ── Accusation (Guilt Confidence utility scoring) ────────────────────────────

func _maybe_accuse() -> void:
	if _accused_this_round:
		return
	# Respect ArgumentSystem's per-round limit (one accusation per accuser).
	if _arg_sys and _arg_sys.has_argued(GHOST_ENTITY_ID):
		return
	if GameState.get_match_state() != GameState.MatchState.SEARCHING:
		return
	if difficulty == Difficulty.EASY:
		# EASY: no memory — accusation confidence is pure randf().
		if _rng.randf() > EASY_ACCUSE_ROLL:
			_try_accuse()
		return
	if _guilt >= _accuse_threshold():
		_try_accuse()


func _accuse_threshold() -> float:
	match difficulty:
		Difficulty.HARD:
			return ACCUSE_THRESHOLD_HARD
		Difficulty.NIGHTMARE:
			return ACCUSE_THRESHOLD_NIGHTMARE
		_:
			return ACCUSE_THRESHOLD_NORMAL


## NIGHTMARE game-theoretic false accusation (confidence forced to 1.0).
func _forced_accuse() -> void:
	if _accused_this_round:
		return
	_guilt = 1.0
	_try_accuse()


func _try_accuse() -> void:
	_accused_this_round = true
	EventBus.emit(EventBus.EV_NETWORK_RPC_ARGUMENT_STARTED, {
		"accuser_id": GHOST_ENTITY_ID,
		"target_id": HUMAN_ENTITY_ID,
		"accusation_text": _pick_accusation_text(),
		"argument_id": _next_argument_id,
		"timestamp": float(Time.get_ticks_msec()),
	})
	_next_argument_id += 1
	print("GhostBot: accusing human (guilt %.2f, difficulty %s)" % [_guilt, Difficulty.keys()[difficulty]])


func _pick_accusation_text() -> String:
	var pool: Array[String] = ArgumentSystem.ACCUSATIONS
	if pool.is_empty():
		return "The chalk dust on your hands betrays you!"
	var idx := _rng.randi_range(0, pool.size() - 1)
	if idx == _last_accusation_index and pool.size() > 1:
		idx = (idx + 1) % pool.size()
	_last_accusation_index = idx
	return pool[idx]


func _bump_guilt(amount: float) -> void:
	_guilt = clampf(_guilt + amount, 0.0, 1.0)


# ── Event handlers (observation only) ────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var from_state: int = payload.get("from", -1)
	var to_state: int = payload.get("to", -1)

	# Argument pause → resume: re-arm the accusation cadence.
	if from_state == GameState.MatchState.PAUSED:
		_accuse_check_timer = 0.0
		return
	if to_state == GameState.MatchState.PAUSED:
		return

	if to_state == GameState.MatchState.DRAWING:
		_reset_round_memory()
		_fallback_timer = 0.0
		_placement_delay = 0.0
		_placement_due = false
		_ai_enter(AIState.OBSERVING)
		if difficulty == Difficulty.NORMAL or difficulty == Difficulty.HARD \
				or difficulty == Difficulty.NIGHTMARE:
			# NIGHTMARE included: if the searcher never moves (no move samples,
			# so the fog-edge placement never arms), the fallback still
			# guarantees a ghost-line placement for discovery gameplay.
			_fallback_timer = OBSERVE_FALLBACK_SECONDS
	elif to_state == GameState.MatchState.SEARCHING:
		_ai_enter(AIState.OBSERVING)
		if difficulty == Difficulty.EASY:
			_schedule_placement(_rng.randf_range(EASY_PLACE_DELAY_MIN, EASY_PLACE_DELAY_MAX))
		elif (difficulty == Difficulty.NORMAL or difficulty == Difficulty.HARD) \
				and not _lines_placed_this_round and _placement_delay <= 0.0 and not _placement_due:
			_placement_anchor = _clamp_to_bounds(_searcher_position(), WORLD_EDGE_MARGIN)
			_schedule_placement(1.0)
		elif difficulty == Difficulty.NIGHTMARE and _move_samples.size() >= 2 \
				and not _lines_placed_this_round and _placement_delay <= 0.0 and not _placement_due:
			_schedule_placement(1.0)


func _on_line_drawn(payload: Dictionary) -> void:
	if payload.get("player_id", -1) != HUMAN_ENTITY_ID:
		return
	var line_id: int = payload.get("line_id", -1)
	var line := _find_active_line(line_id)
	if not line or line.points.is_empty():
		return
	var centroid := _centroid_of(line.points)

	var now := _now()
	_draw_timestamps.append(now)
	while not _draw_timestamps.is_empty() and _draw_timestamps[0] < now - RAPID_DRAW_WINDOW:
		_draw_timestamps.pop_front()
	if _draw_timestamps.size() < RAPID_DRAW_LINES:
		_rapid_draw_bumped = false

	match difficulty:
		Difficulty.NORMAL:
			_searcher_line_centroids.append(centroid)
			while _searcher_line_centroids.size() > LINE_POS_MEMORY:
				_searcher_line_centroids.pop_front()
			_bump_guilt(0.12)
			if not _lines_placed_this_round and _placement_delay <= 0.0 and not _placement_due:
				_placement_anchor = _normal_anchor()
				_schedule_placement(NORMAL_PLACE_DELAY)
		Difficulty.HARD:
			_bump_guilt(0.10)
			_heatmap_add(centroid)
			if _draw_timestamps.size() >= RAPID_DRAW_LINES and not _rapid_draw_bumped:
				_rapid_draw_bumped = true
				_bump_guilt(0.15)
			if not _lines_placed_this_round and _placement_delay <= 0.0 and not _placement_due \
					and _draw_timestamps.size() >= 2:
				_placement_anchor = _hard_anchor(centroid)
				_schedule_placement(HARD_PLACE_DELAY)
		Difficulty.NIGHTMARE:
			_bump_guilt(0.08)


func _on_fog_revealed(payload: Dictionary) -> void:
	if difficulty != Difficulty.NIGHTMARE:
		return
	var pos: Vector2 = payload.get("position", Vector2.ZERO)
	var radius: float = payload.get("radius", FogSystem.VISION_RADIUS)
	# Dedupe circles that overlap an existing one (vision trails produce many).
	for circle in _explored_circles:
		var c: Vector2 = circle["position"]
		if pos.distance_squared_to(c) < radius * radius * 0.25:
			return
	_explored_circles.append({"position": pos, "radius": radius})
	while _explored_circles.size() > MAX_EXPLORED_CIRCLES:
		_explored_circles.pop_front()


func _on_move_command(payload: Dictionary) -> void:
	if difficulty != Difficulty.NIGHTMARE:
		return
	var target: Vector2 = payload.get("target", Vector2.ZERO)
	var now := _now()
	_move_samples.append({"target": target, "t": now})
	while _move_samples.size() > MAX_MOVE_SAMPLES:
		_move_samples.pop_front()
	_last_move_time = now

	# Derive velocity + heading from the target history (dot-product math).
	if _move_samples.size() >= 2:
		var last: Dictionary = _move_samples[-1]
		var prev: Dictionary = _move_samples[-2]
		var dt: float = float(last["t"]) - float(prev["t"])
		if dt > 0.001:
			var lt: Vector2 = last["target"]
			var pt: Vector2 = prev["target"]
			var v := (lt - pt) / dt
			var speed := v.length()
			if speed > 20.0:
				var h := v / speed
				if _last_heading.dot(h) < 0.0:
					_last_heading = h  # reversal — snap, don't blend
				else:
					_last_heading = _last_heading.lerp(h, 0.4).normalized()


func _on_silent_sneak_activated(payload: Dictionary) -> void:
	if payload.get("searcher_id", -1) != HUMAN_ENTITY_ID:
		return
	if difficulty == Difficulty.HARD:
		_bump_guilt(0.25)
	elif difficulty == Difficulty.NIGHTMARE:
		_bump_guilt(0.2)


func _on_silent_sneak_line_crossed(payload: Dictionary) -> void:
	if payload.get("searcher_id", -1) != HUMAN_ENTITY_ID:
		return
	if difficulty == Difficulty.HARD:
		_bump_guilt(0.3)
	elif difficulty == Difficulty.NIGHTMARE:
		_bump_guilt(0.25)


func _on_ghost_line_discovered(_payload: Dictionary) -> void:
	# The searcher found one of our lines — they are close and effective.
	if difficulty == Difficulty.HARD:
		_bump_guilt(0.15)
	elif difficulty == Difficulty.NIGHTMARE:
		_bump_guilt(0.15)


# ── Round bookkeeping ────────────────────────────────────────────────────────

func _reset_round_memory() -> void:
	_searcher_line_centroids.clear()
	_heatmap.clear()
	_explored_circles.clear()
	_draw_timestamps.clear()
	_move_samples.clear()
	_lines_placed_this_round = false
	_accused_this_round = false
	_placement_anchor = Vector2.ZERO
	_placement_due = false
	_watch_armed = false
	_watch_deadline = -INF
	_guilt = 0.0
	_rapid_draw_bumped = false
	_last_move_time = -INF


# ── Helpers ──────────────────────────────────────────────────────────────────

func _find_systems() -> void:
	var root := get_tree().current_scene
	if not root:
		return
	_game_world = root as Node2D
	var systems := root.get_node_or_null("Systems")
	if not systems:
		return
	_draw_sys = systems.get_node_or_null("DrawSystem") as DrawSystem
	_ghost_sys = systems.get_node_or_null("GhostDrawSystem") as GhostDrawSystem
	_arg_sys = systems.get_node_or_null("ArgumentSystem") as ArgumentSystem
	_cluster_sys = systems.get_node_or_null("ClusterSystem") as ClusterSystem
	_fog_sys = systems.get_node_or_null("FogSystem") as FogSystem


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _world_bounds() -> Rect2:
	if _fog_sys:
		return _fog_sys.get_world_bounds()
	return Rect2(Vector2.ZERO, WORLD_BOUNDS_FALLBACK)


func _clamp_to_bounds(p: Vector2, margin: float) -> Vector2:
	var b := _world_bounds()
	var min_x := b.position.x + margin
	var max_x := b.position.x + b.size.x - margin
	var min_y := b.position.y + margin
	var max_y := b.position.y + b.size.y - margin
	if max_x < min_x:
		max_x = min_x
	if max_y < min_y:
		max_y = min_y
	return Vector2(clampf(p.x, min_x, max_x), clampf(p.y, min_y, max_y))


func _searcher_position() -> Vector2:
	if _game_world:
		var entity: Node2D = _game_world.get_entity(HUMAN_ENTITY_ID) as Node2D
		if entity:
			return entity.global_position
	if _move_samples.size() > 0:
		var last: Dictionary = _move_samples[-1]
		var lt: Vector2 = last["target"]
		return lt
	return Vector2(200.0, 400.0)


func _searcher_speed() -> float:
	if _move_samples.size() < 2:
		return 0.0
	var last: Dictionary = _move_samples[-1]
	var prev: Dictionary = _move_samples[-2]
	var dt: float = float(last["t"]) - float(prev["t"])
	if dt <= 0.001:
		return 0.0
	var lt: Vector2 = last["target"]
	var pt: Vector2 = prev["target"]
	return (lt - pt).length() / dt


func _find_active_line(line_id: int) -> ChalkLine:
	if not _draw_sys:
		return null
	for line in _draw_sys.get_active_lines():
		if line.id == line_id:
			return line
	return null


func _centroid_of(points: Array[Vector2]) -> Vector2:
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size())


func _heatmap_add(pos: Vector2) -> void:
	var cx := int(floor(pos.x / HEATMAP_CELL))
	var cy := int(floor(pos.y / HEATMAP_CELL))
	var key := "%d_%d" % [cx, cy]
	if not _heatmap.has(key):
		_heatmap[key] = {
			"density": 1,
			"center": Vector2((float(cx) + 0.5) * HEATMAP_CELL, (float(cy) + 0.5) * HEATMAP_CELL),
		}
	else:
		var entry: Dictionary = _heatmap[key]
		entry["density"] = int(entry["density"]) + 1


func _hottest_cell_center() -> Vector2:
	var best := Vector2.ZERO
	var best_density := 0
	for key in _heatmap:
		var entry: Dictionary = _heatmap[key]
		var d: int = entry["density"]
		if d > best_density:
			best_density = d
			best = entry["center"]
	return best


# ── Public getters (for the driver / debugging) ──────────────────────────────

func get_difficulty() -> int:
	return difficulty

func get_guilt() -> float:
	return _guilt

func get_ai_state() -> int:
	return ai_state

func has_accused_this_round() -> bool:
	return _accused_this_round

func has_placed_this_round() -> bool:
	return _lines_placed_this_round
