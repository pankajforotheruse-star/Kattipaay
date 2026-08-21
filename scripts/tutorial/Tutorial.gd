# Tutorial.gd — Wordless three-level tutorial for CHALK GAON: Ghost Lines.
#
# A ghost hand (GhostHand) pantomimes each mechanic; the player imitates it.
# No text anywhere — no labels, no instructions, only motion and feedback.
# Reuses the real game systems (DrawSystem, GhostDrawSystem, ArgumentSystem)
# so the tutorial teaches the actual mechanics, not a mock.
#
#   Level 1 — DRAW:  the hand presses an anchor then swipes a chalk line
#                    (the real two-finger draw gesture). The player draws a
#                    line connecting the two chalk rings.
#   Level 2 — HUNT:  the hand hovers over a spot, pauses, then reveals a
#                    hidden ghost line (GhostDrawSystem fade-in, ANM-P-05).
#                    The player taps the map to discover fresh hidden lines.
#   Level 3 — ACCUSE: the hand taps the ghost villager, then the accusation
#                    stamp. The player selects a villager and performs the
#                    accusation through ArgumentSystem.
#
# Prompt 15 (owner): "Create tutorial. No text. Ghost hand animations.
# Three levels."
#
# Design notes:
#   - The tutorial runs standalone from the main menu. SceneManager routes
#     scenes/overlays on GameState *events*, so we set GameState.current_match
#     directly (no event emitted) to satisfy the systems' state checks and
#     restore it on exit.
#   - MatchStateMachine is intentionally NOT wired here: its transitions emit
#     match.state_changed, which SceneManager turns into scene/overlay routing
#     (pause overlay during arguments, searching overlay, etc.). Driving the
#     systems directly keeps the tutorial self-contained.
class_name Tutorial
extends Node2D

enum Phase { IDLE, L1_DEMO, L1_PLAY, L2_DEMO, L2_PLAY, L3_DEMO, L3_PLAY, DONE }

# ── Level 1: drawing ─────────────────────────────────────────────────────────
const L1_A := Vector2(190, 720)
const L1_B := Vector2(530, 720)
const GOAL_REACH := 75.0

# ── Level 2: ghost hunt ──────────────────────────────────────────────────────
const L2_DEMO_SPOT := Vector2(360, 540)
const L2_ANCHORS: Array[Vector2] = [Vector2(170, 480), Vector2(550, 640)]
const FIND_RADIUS := 170.0

# ── Level 3: accusation ──────────────────────────────────────────────────────
const L3_VILLAGERS: Array[Dictionary] = [
	{"id": 1, "pos": Vector2(215, 640), "color": Color(0.91, 0.55, 0.2, 1.0)},
	{"id": 2, "pos": Vector2(360, 640), "color": Color(0.72, 0.82, 1.0, 0.8), "ghost": true},
	{"id": 3, "pos": Vector2(505, 640), "color": Color(0.38, 0.45, 0.85, 1.0)},
]
const ACCUSE_POS := Vector2(600, 1052)
const ACCUSE_RADIUS := 58.0

# ── Redraw throttle (Prompt 16) ──────────────────────────────────────────────────────
## Min seconds between full-scene redraws (30 fps is plenty for the level
## dots / goal rings / stamp pulse; the fast accuse wobble bypasses this).
const REDRAW_INTERVAL := 1.0 / 30.0

const GHOST_TARGET_ID := 2    # ArgumentSystem stub: _is_target_ghost(id) == (id == 2)
const PLAYER_ID := 1          # local player / accuser id (prototype convention)

# ── State ────────────────────────────────────────────────────────────────────
var _draw_sys: DrawSystem = null
var _ghost_sys: GhostDrawSystem = null
var _arg_sys: ArgumentSystem = null
var _hand: GhostHand = null
var _villagers: Array[Villager] = []

var _phase: int = Phase.IDLE
var _goal_rings: Array[Vector2] = []   # level-1 anchor rings to draw
var _level_dot: int = 0                # completed levels (0..3)
var _player_lines: Array = []          # ChalkLines drawn by the player in L1
var _found: Dictionary = {}            # discovered ghost line id → true
var _total_hidden: int = 0
var _selected: int = -1                # selected villager id (L3)
var _t: float = 0.0                    # tutorial clock
var _accuse_pulse: float = 0.0
var _accuse_flash: float = 0.0
var _accuse_wobble_t: float = 1.0      # 1 = not wobbling (decayed)
var _dim: float = 0.0                  # argument-pause dim flash
var _leaving: bool = false
var _hand_idle_pos := Vector2(360, 200)

## Redraw throttle accumulator (30 fps cap — see _process).
var _redraw_accum: float = 0.0


# ── Lifecycle ────────────────────────────────────────────────────────────────
func _ready() -> void:
	_draw_sys = get_node_or_null("Systems/DrawSystem") as DrawSystem
	_ghost_sys = get_node_or_null("Systems/GhostDrawSystem") as GhostDrawSystem
	_arg_sys = get_node_or_null("Systems/ArgumentSystem") as ArgumentSystem
	_hand = get_node_or_null("GhostHand") as GhostHand

	# The systems expect a live match sub-state (ArgumentSystem allows
	# accusations only in SEARCHING). Set it directly — no event, so
	# SceneManager stays out of the tutorial. Restored in _exit_tree().
	GameState.current_match = GameState.MatchState.SEARCHING
	MatchTimer.stop()

	EventBus.on(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.on(EventBus.EV_GAME_ARGUMENT_STARTED, _on_argument_started)
	EventBus.on(EventBus.EV_GAME_ARGUMENT_RESOLVED, _on_argument_resolved)

	# Real match reset path: fresh chalk + empty line state.
	EventBus.emit(EventBus.EV_MATCH_DRAWING_STARTED, {})

	set_process(true)
	_start_level_1()


func _process(delta: float) -> void:
	_t += delta
	_accuse_pulse += delta
	_accuse_wobble_t += delta
	_accuse_flash = maxf(0.0, _accuse_flash - delta * 2.5)
	# the hand idles with a soft bob while the player works
	if _phase == Phase.L2_PLAY or _phase == Phase.L3_PLAY:
		_hand.global_position = _hand_idle_pos + Vector2(0.0, sin(_t * 1.6) * 5.0)
	# Throttle the full-scene redraw to 30 fps (Prompt 16). The accusation
	# stamp's fast 26 Hz wobble is the only effect that needs full rate —
	# redraw at 60 fps while it is active so the shake never aliases.
	if _accuse_wobble_t < 0.5:
		queue_redraw()
	else:
		_redraw_accum += delta
		if _redraw_accum >= REDRAW_INTERVAL:
			_redraw_accum = 0.0
			queue_redraw()


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.off(EventBus.EV_GAME_ARGUMENT_STARTED, _on_argument_started)
	EventBus.off(EventBus.EV_GAME_ARGUMENT_RESOLVED, _on_argument_resolved)
	# DrawSystem has no _exit_tree() — release its subscriptions so future
	# input events can never hit a freed node after the tutorial scene leaves.
	if _draw_sys:
		EventBus.off(EventBus.EV_INPUT_DRAW_START, _draw_sys._on_draw_start)
		EventBus.off(EventBus.EV_INPUT_DRAW_UPDATE, _draw_sys._on_draw_update)
		EventBus.off(EventBus.EV_INPUT_DRAW_END, _draw_sys._on_draw_end)
		EventBus.off(EventBus.EV_INPUT_UNDO_DRAW, _draw_sys._on_undo_draw)
		EventBus.off(EventBus.EV_NETWORK_CHALK_LINE_DRAWN, _draw_sys._on_network_line_drawn)
		EventBus.off(EventBus.EV_NETWORK_CHALK_LINE_REJECTED, _draw_sys._on_network_line_rejected)
		EventBus.off(EventBus.EV_NETWORK_CHALK_LINE_SYNC_BATCH, _draw_sys._on_network_line_sync_batch)
		EventBus.off(EventBus.EV_MATCH_DRAWING_STARTED, _draw_sys._on_match_drawing_started)
		EventBus.off(EventBus.EV_GAME_CHALK_EXHAUSTED, _draw_sys._on_chalk_exhausted)
	# restore what we borrowed
	GameState.current_match = GameState.MatchState.NONE
	GameState.pre_pause_match = GameState.MatchState.NONE
	InputManager.touch_to_move_enabled = true
	MatchTimer.stop()


# ── Input ────────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if _leaving:
		return
	if event is InputEventScreenTouch and event.pressed and event.index == 0:
		match _phase:
			Phase.L2_PLAY:
				_handle_level_2_tap(event.position)
			Phase.L3_PLAY:
				_handle_level_3_tap(event.position)


func screen_to_world(screen_pos: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_2d()
	if cam:
		return cam.get_screen_center() + (screen_pos - get_viewport().get_visible_rect().size / 2.0) / cam.zoom
	return screen_pos


# ── Level 1 — DRAW ───────────────────────────────────────────────────────────
func _start_level_1() -> void:
	_phase = Phase.L1_DEMO
	_goal_rings = [L1_A, L1_B]
	_hand_idle_pos = Vector2(360, 380)
	queue_redraw()
	_run_level_1_demo()


func _run_level_1_demo() -> void:
	await _hand.appear()
	# glide in above the start ring
	await _hand.move_to(L1_A + Vector2(0, 130), 0.7)
	await _hand.hover(0.35)
	# anchor finger: press once on the start ring
	await _hand.tap_at(L1_A, 0.18)
	# drawing finger: swipe a chalk line A → B (trail fades to 15% per ANM-P-04)
	await _hand.draw_swipe(L1_A, L1_B, 1.15)
	# step back and watch the player
	await _hand.move_to(_hand_idle_pos, 0.6)
	await _hand.hover(0.2)
	_phase = Phase.L1_PLAY


func _on_line_drawn(payload: Dictionary) -> void:
	if _phase != Phase.L1_PLAY:
		return
	var line_id: int = payload.get("line_id", -1)
	if line_id < 0:
		return
	for line in _draw_sys.get_active_lines():
		if line.id == line_id and not _player_lines.has(line):
			_player_lines.append(line)
			break
	_check_level_1_goal()


func _check_level_1_goal() -> void:
	var hit_a := false
	var hit_b := false
	for line in _player_lines:
		for p in line.points:
			if p.distance_to(L1_A) <= GOAL_REACH:
				hit_a = true
			if p.distance_to(L1_B) <= GOAL_REACH:
				hit_b = true
	if hit_a and hit_b:
		_level_1_complete()


func _level_1_complete() -> void:
	_phase = Phase.IDLE
	_level_dot = 1
	AudioManager.play_argument_result(true)   # ascending chime — success
	TutorialBurst.spawn(self, (L1_A + L1_B) / 2.0, Color(1.0, 0.9, 0.6, 1.0), 80.0)
	_run_level_1_celebration()


func _run_level_1_celebration() -> void:
	var mid := (L1_A + L1_B) / 2.0
	await _hand.move_to(mid + Vector2(0, 110), 0.45)
	await _hand.hover(0.6)
	_draw_sys.clear_all_lines()
	_player_lines.clear()
	_goal_rings.clear()
	_hand.clear_trail()
	queue_redraw()
	_start_level_2()


# ── Level 2 — GHOST HUNT ─────────────────────────────────────────────────────
func _start_level_2() -> void:
	_phase = Phase.L2_DEMO
	InputManager.touch_to_move_enabled = false   # tap-only levels from here on
	_ghost_sys.reset_for_new_round()
	_run_level_2_demo()


func _run_level_2_demo() -> void:
	# approach the spot
	await _hand.move_to(L2_DEMO_SPOT + Vector2(0, 130), 0.7)
	# hover… pause… (the "is it here?" beat)
	await _hand.hover(0.9)
	# place hidden ghost lines (real mechanic)
	_ghost_sys.activate_ghost_draw(L2_DEMO_SPOT, GHOST_TARGET_ID)
	var lines := _ghost_sys.get_active_ghost_lines()
	# tap down — reveal the first hidden line (ANM-P-05: 0.5s fade-in)
	await _hand.tap_at(L2_DEMO_SPOT, 0.25)
	if not lines.is_empty():
		_ghost_sys._reveal_line_fade_in(lines[0].id)
		var pts: Array = lines[0].points
		var mid = (pts[0] + pts[-1]) / 2.0
		TutorialBurst.spawn(self, mid, Color(0.6, 0.8, 1.0, 1.0), 60.0)
	await _hand.hover(0.55)
	await _hand.move_to(Vector2(360, 200), 0.6)
	await _hand.hover(0.2)
	# player phase: fresh hidden lines to find
	_ghost_sys.reset_for_new_round()
	_found.clear()
	_total_hidden = 0
	for anchor in L2_ANCHORS:
		_ghost_sys.activate_ghost_draw(anchor, GHOST_TARGET_ID)
	_total_hidden = _ghost_sys.get_active_ghost_lines().size()
	_hand_idle_pos = Vector2(360, 200)
	_phase = Phase.L2_PLAY


func _handle_level_2_tap(screen_pos: Vector2) -> void:
	var world := screen_to_world(screen_pos)
	var hits := _ghost_sys.check_ghost_line_collision(world, FIND_RADIUS)
	if hits.is_empty():
		return
	var new_found := false
	for id in hits:
		if not _found.has(id):
			_found[id] = true
			_ghost_sys._reveal_line_fade_in(id)
			new_found = true
	if new_found:
		TutorialBurst.spawn(self, world, Color(0.6, 0.8, 1.0, 1.0), 54.0)
	if _found.size() >= _total_hidden:
		_level_2_complete()


func _level_2_complete() -> void:
	_phase = Phase.IDLE
	_level_dot = 2
	AudioManager.play_argument_result(true)
	TutorialBurst.spawn(self, Vector2(360, 540), Color(0.6, 0.8, 1.0, 1.0), 110.0)
	_run_level_2_celebration()


func _run_level_2_celebration() -> void:
	await _hand.move_to(Vector2(360, 500), 0.5)
	await _hand.hover(0.8)
	_ghost_sys.reset_for_new_round()
	_start_level_3()


# ── Level 3 — ACCUSE ─────────────────────────────────────────────────────────
func _start_level_3() -> void:
	_phase = Phase.L3_DEMO
	InputManager.touch_to_move_enabled = false
	_spawn_villagers()
	_run_level_3_demo()


func _spawn_villagers() -> void:
	for v in _villagers:
		if is_instance_valid(v):
			v.queue_free()
	_villagers.clear()
	for data in L3_VILLAGERS:
		var v := Villager.new()
		v.villager_id = data.get("id", -1)
		v.is_ghost = data.get("ghost", false)
		v.body_color = data.get("color", Color.WHITE)
		v.position = data.get("pos", Vector2.ZERO)
		v.z_index = 3
		add_child(v)
		_villagers.append(v)


func _run_level_3_demo() -> void:
	var ghost: Villager = null
	for v in _villagers:
		if v.villager_id == GHOST_TARGET_ID:
			ghost = v
			break
	if ghost == null:
		_phase = Phase.L3_PLAY
		return
	# glide to the ghost villager and tap it — target selection
	await _hand.move_to(ghost.position + Vector2(0, 120), 0.65)
	await _hand.hover(0.35)
	await _hand.tap_at(ghost.position, 0.3)
	ghost.select()
	TutorialBurst.spawn(self, ghost.position, Color(1.0, 0.85, 0.4, 1.0), 48.0)
	await _hand.hover(0.3)
	# glide to the accusation stamp and press it
	await _hand.move_to(ACCUSE_POS + Vector2(0, 110), 0.6)
	await _hand.tap_at(ACCUSE_POS, 0.3)
	_accuse_flash = 1.0
	queue_redraw()
	# perform the accusation through the real system (correct target)
	_arg_sys.request_argument(PLAYER_ID, GHOST_TARGET_ID)
	# retreat while the argument resolves
	await _hand.move_to(Vector2(360, 150), 0.7)
	await _hand.vanish()


func _handle_level_3_tap(screen_pos: Vector2) -> void:
	var world := screen_to_world(screen_pos)
	if world.distance_to(ACCUSE_POS) <= ACCUSE_RADIUS:
		_accuse_button_pressed()
		return
	for v in _villagers:
		if is_instance_valid(v) and world.distance_to(v.position) <= 62.0:
			_select_villager(v.villager_id)
			return


func _select_villager(id: int) -> void:
	_selected = id
	for v in _villagers:
		v.selected = (v.villager_id == id)
		if v.villager_id == id:
			TutorialBurst.spawn(self, v.position, Color(1.0, 0.85, 0.4, 1.0), 42.0)


func _accuse_button_pressed() -> void:
	_accuse_flash = 1.0
	queue_redraw()
	if _selected < 0:
		_wobble_stamp()   # "pick a target first" — motion feedback, no text
		return
	if not _arg_sys.request_argument(PLAYER_ID, _selected):
		_wobble_stamp()


func _wobble_stamp() -> void:
	_accuse_wobble_t = 0.0


func _on_argument_started(_payload) -> void:
	# argument freeze flash — the accusation has landed
	_dim = 1.0
	queue_redraw()
	var tw := create_tween()
	tw.tween_property(self, "_dim", 0.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _on_argument_resolved(payload: Dictionary) -> void:
	var is_true: bool = payload.get("is_true", false)
	if _phase == Phase.L3_DEMO:
		# the demo's (correct) accusation resolved — now let the player try
		if is_true:
			_demo_success_visuals()
		_phase = Phase.L3_PLAY
		_arg_sys._argued_this_round.clear()
		_hand_idle_pos = Vector2(360, 150)
		_prepare_level_3_play()
		return
	if _phase != Phase.L3_PLAY:
		return
	if is_true:
		_level_3_complete()
	else:
		_wrong_accusation()


func _prepare_level_3_play() -> void:
	_hand.global_position = _hand_idle_pos
	_hand.rotation = 0.0
	await _hand.appear()


func _demo_success_visuals() -> void:
	for v in _villagers:
		if v.villager_id == GHOST_TARGET_ID:
			TutorialBurst.spawn(self, v.position, Color(1.0, 0.9, 0.6, 1.0), 60.0)
			break


func _wrong_accusation() -> void:
	# red flash on the accused villager + red burst; allow a retry
	for v in _villagers:
		if v.villager_id == _selected:
			var tw := v.create_tween()
			tw.tween_property(v, "modulate", Color(1.6, 0.5, 0.5, 1.0), 0.15)
			tw.tween_property(v, "modulate", Color.WHITE, 0.4)
			TutorialBurst.spawn(self, v.position, Color(1.0, 0.3, 0.3, 1.0), 55.0)
			break
	# ArgumentSystem blocks a second accusation per round — clear for retry
	_arg_sys._argued_this_round.clear()
	_arg_sys._pending_arguments.clear()


func _level_3_complete() -> void:
	_phase = Phase.DONE
	_level_dot = 3
	AudioManager.play_argument_result(true)
	_run_level_3_celebration()


func _run_level_3_celebration() -> void:
	await _hand.appear()
	# villagers banish: shrink + fade + bursts
	for v in _villagers:
		if is_instance_valid(v):
			var tw := v.create_tween()
			tw.set_parallel(true)
			tw.tween_property(v, "scale", Vector2(0.1, 0.1), 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
			tw.tween_property(v, "modulate:a", 0.0, 0.5)
			TutorialBurst.spawn(self, v.position, Color(1.0, 0.9, 0.6, 1.0), 70.0)
	await _hand.move_to(Vector2(360, 560), 0.5)
	await _hand.hover(1.2)
	_finish_tutorial()


# ── Finish ───────────────────────────────────────────────────────────────────
func _finish_tutorial() -> void:
	SaveManager.save_local("tutorial", {"completed": true})
	EventBus.emit("ui.tutorial_complete", {})
	EventBus.emit("ui.button_pressed", {"button": "tutorial_done"})
	_leaving = true
	_run_finish_sequence()


func _run_finish_sequence() -> void:
	await _hand.hover(0.8)
	await _hand.vanish()
	SceneManager.go_to("menu/home.tscn")


# ── World-space UI (drawn, never text) ───────────────────────────────────────
func _draw() -> void:
	_draw_level_dots()
	_draw_goal_rings()
	_draw_accuse_button()
	_draw_dim_flash()


func _draw_level_dots() -> void:
	for i in range(3):
		var pos := Vector2(330 + i * 30, 34)
		draw_circle(pos, 9.0, Color(0.2, 0.24, 0.32, 0.85))
		if i < _level_dot:
			draw_circle(pos, 6.5, Color(0.95, 0.9, 0.6, 0.95))
		else:
			draw_circle(pos, 6.5, Color(0.55, 0.6, 0.7, 0.7))
		if i == _level_dot and _phase not in [Phase.IDLE, Phase.DONE]:
			draw_arc(pos, 14.0, 0.0, TAU, 24, Color(0.95, 0.9, 0.6, 0.6 + 0.3 * sin(_t * 4.0)), 2.0)


func _draw_goal_rings() -> void:
	for ring_pos in _goal_rings:
		draw_circle(ring_pos, 5.0, Color(0.95, 0.94, 0.88, 0.5))
		draw_arc(ring_pos, 26.0, 0.0, TAU, 32, Color(0.95, 0.94, 0.88, 0.6), 2.5)
		draw_arc(ring_pos, 26.0 + sin(_accuse_pulse * 2.0) * 3.0, 0.0, TAU, 32,
				Color(0.95, 0.94, 0.88, 0.25), 1.5)


func _draw_accuse_button() -> void:
	if _phase != Phase.L3_DEMO and _phase != Phase.L3_PLAY and _phase != Phase.DONE:
		return
	var pulse := 0.5 + 0.5 * sin(_accuse_pulse * 3.0)
	var r := ACCUSE_RADIUS * (0.98 + 0.04 * pulse)
	var wob := sin(_accuse_wobble_t * 26.0) * 0.12 * maxf(0.0, 1.0 - _accuse_wobble_t * 3.0)
	draw_set_transform(ACCUSE_POS, wob, Vector2.ONE)
	# terracotta stamp — matches the HUD accusation button (#CC6B49)
	draw_circle(Vector2.ZERO, r, Color(0.8, 0.42, 0.29, 0.92))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(0.95, 0.6, 0.45, 1.0), 3.0)
	# hand-print glyph: palm + four fingers
	draw_circle(Vector2(0, 6), 9.0, Color(0.95, 0.88, 0.8, 0.95))
	for i in range(4):
		var a := -1.15 + i * 0.72
		var dir := Vector2.from_angle(a)
		draw_line(Vector2(0, 6), Vector2(0, 6) + dir * 15.0, Color(0.95, 0.88, 0.8, 0.95), 5.0)
		draw_circle(Vector2(0, 6) + dir * 15.0, 2.8, Color(0.95, 0.88, 0.8, 0.95))
	# press flash
	if _accuse_flash > 0.0:
		draw_circle(Vector2.ZERO, r + 8.0, Color(1.0, 0.9, 0.5, _accuse_flash * 0.6))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_dim_flash() -> void:
	if _dim > 0.001:
		draw_rect(Rect2(-1000, -1000, 3000, 3000), Color(0.02, 0.02, 0.08, _dim * 0.55))
