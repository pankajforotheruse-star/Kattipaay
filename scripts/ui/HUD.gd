# HUD.gd — Heads-up display overlay for CHALK GAON
# CanvasLayer that sits on top of the game world (layer 1).
# Shows: state label, info label, timer display, chalk meter, argument button,
# hint counter, spectator reveal button, trap penalty flash, silent sneak button.
#
# ArgumentButton: visible only during SEARCHING, bottom-right corner (y≥850),
# terracotta background (#CC6B49), pulse animation, 15s cooldown.
# On press: if no target selected → prompt; if target → call ArgumentSystem.
#
# SilentSneakButton: visible only during SEARCHING, bottom-center (y≥850),
# brown background (#8B7355), disabled during cooldown with countdown.
# On press: call SilentSneakSystem.activate via EventBus.
#
# Hint Trap HUD elements:
#   - Hint counter: top of screen during SEARCHING, "Hints: N"
#   - Spectator button: visible when local player is spectator, "👁 Reveal Available"
#   - Penalty flash: "-20s" red center-screen on fake hint trap trigger

class_name HUD
extends CanvasLayer

# ── Onready Nodes ─────────────────────────────────────────────────────────────

@onready var _state_label: Label = $StateLabel
@onready var _info_label: Label = $InfoLabel

# ── Dynamic Nodes (created in _ready) ─────────────────────────────────────────

var _timer_label: Label = null
var _chalk_label: Label = null
var _argument_button: Button = null
var _argument_cooldown_label: Label = null
var _argument_pulse_tween: Tween = null
var _argument_cooldown_timer: float = 0.0
var _argument_on_cooldown: bool = false
var _selected_target_id: int = -1
var _is_searching: bool = false
var _argument_overlay: ArgumentOverlay = null

# ── Hint Trap UI Elements ────────────────────────────────────────────────────

var _hint_counter_label: Label = null
var _spectator_button: Button = null
var _spectator_notification_label: Label = null
var _sloppy_count_banner: Label = null
var _spectator_reveal_used: bool = false
var _is_spectator: bool = false

# ── Silent Sneak UI Elements ──────────────────────────────────────────────────

var _silent_sneak_button: Button = null
var _silent_sneak_cooldown_label: Label = null
var _silent_sneak_cooldown_timer: float = 0.0
var _silent_sneak_on_cooldown: bool = false
var _silent_sneak_active: bool = false

# ── Cooldown ──────────────────────────────────────────────────────────────────

const ARGUMENT_COOLDOWN := 15.0
const FAKE_HINT_PENALTY := 20

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
    layer = 1

    # --- Existing subscriptions ---
    EventBus.on("entity.state_changed", _on_entity_state_changed)
    EventBus.on("game.state_changed", _on_game_state_changed)

    # --- Match & timer subscriptions ---
    EventBus.on("match.state_changed", _on_match_state_changed)
    EventBus.on("game.timer_tick", _on_timer_tick)
    EventBus.on("game.timer_expired", _on_timer_expired)
    EventBus.on("game.chalk_meter_changed", _on_chalk_meter_changed)

    # --- Argument events ---
    EventBus.on("game.argument_started", _on_argument_started)
    EventBus.on("game.argument_resolved", _on_argument_resolved)

    # --- Hint Trap events ---
    EventBus.on("game.hint_revealed", _on_hint_revealed)
    EventBus.on("game.hint_placed", _on_hint_placed)
    EventBus.on("game.hint_investigated", _on_hint_investigated)
    EventBus.on("game.hint_trap_triggered", _on_hint_trap_triggered)
    EventBus.on("game.spectator_registered", _on_spectator_registered)
    EventBus.on("game.spectator_reveal_used", _on_spectator_reveal_used_local)

    # --- Sloppy Count events ---
    EventBus.on("game.sloppy_count_started", _on_sloppy_count_started)
    EventBus.on("game.sloppy_count_finished", _on_sloppy_count_finished)

    # --- Silent Sneak events ---
    EventBus.on("game.silent_sneak_activated", _on_silent_sneak_activated)
    EventBus.on("game.silent_sneak_deactivated", _on_silent_sneak_deactivated)
    EventBus.on("game.silent_sneak_cooldown_ended", _on_silent_sneak_cooldown_ended)

    # --- Create UI elements ---
    _create_timer_label()
    _create_chalk_label()
    _create_argument_button()
    _create_silent_sneak_button()
    _create_hint_counter_label()
    _create_spectator_button()
    _create_spectator_notification()
    _create_sloppy_count_banner()

    _update_info("Tap anywhere to move the RED player.\nBLUE player patrols automatically.\nGreen grid = 100px squares.")


func _process(delta: float) -> void:
    # Argument button cooldown tick
    if _argument_on_cooldown:
        _argument_cooldown_timer -= delta
        if _argument_cooldown_timer <= 0.0:
            _argument_on_cooldown = false
            _argument_cooldown_timer = 0.0
            if _argument_cooldown_label:
                _argument_cooldown_label.text = ""
            if _argument_button:
                _argument_button.disabled = false
                _argument_button.modulate = Color.WHITE
        else:
            if _argument_cooldown_label:
                _argument_cooldown_label.text = "%d" % int(ceil(_argument_cooldown_timer))

    # Silent sneak cooldown tick
    if _silent_sneak_on_cooldown:
        _silent_sneak_cooldown_timer -= delta
        if _silent_sneak_cooldown_timer <= 0.0:
            _silent_sneak_on_cooldown = false
            _silent_sneak_cooldown_timer = 0.0
            if _silent_sneak_cooldown_label:
                _silent_sneak_cooldown_label.text = ""
            if _silent_sneak_button:
                _silent_sneak_button.disabled = false
                _silent_sneak_button.modulate = Color.WHITE
        else:
            if _silent_sneak_cooldown_label:
                _silent_sneak_cooldown_label.text = "%d" % int(ceil(_silent_sneak_cooldown_timer))


func _exit_tree() -> void:
    EventBus.off("entity.state_changed", _on_entity_state_changed)
    EventBus.off("game.state_changed", _on_game_state_changed)
    EventBus.off("match.state_changed", _on_match_state_changed)
    EventBus.off("game.timer_tick", _on_timer_tick)
    EventBus.off("game.timer_expired", _on_timer_expired)
    EventBus.off("game.chalk_meter_changed", _on_chalk_meter_changed)
    EventBus.off("game.argument_started", _on_argument_started)
    EventBus.off("game.argument_resolved", _on_argument_resolved)
    EventBus.off("game.hint_revealed", _on_hint_revealed)
    EventBus.off("game.hint_placed", _on_hint_placed)
    EventBus.off("game.hint_investigated", _on_hint_investigated)
    EventBus.off("game.hint_trap_triggered", _on_hint_trap_triggered)
    EventBus.off("game.spectator_registered", _on_spectator_registered)
    EventBus.off("game.spectator_reveal_used", _on_spectator_reveal_used_local)
    EventBus.off("game.sloppy_count_started", _on_sloppy_count_started)
    EventBus.off("game.sloppy_count_finished", _on_sloppy_count_finished)
    EventBus.off("game.silent_sneak_activated", _on_silent_sneak_activated)
    EventBus.off("game.silent_sneak_deactivated", _on_silent_sneak_deactivated)
    EventBus.off("game.silent_sneak_cooldown_ended", _on_silent_sneak_cooldown_ended)

# ── UI Creation ───────────────────────────────────────────────────────────────

func _create_timer_label() -> void:
    _timer_label = Label.new()
    _timer_label.name = "TimerLabel"
    _timer_label.text = "3:00"
    _timer_label.add_theme_font_size_override("font_size", 28)
    _timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.65, 1.0))
    _timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _timer_label.anchors_preset = Control.PRESET_CENTER_TOP
    _timer_label.offset_top = 20
    _timer_label.offset_left = -100
    _timer_label.offset_right = 100
    _timer_label.offset_bottom = 54
    add_child(_timer_label)


func _create_chalk_label() -> void:
    _chalk_label = Label.new()
    _chalk_label.name = "ChalkLabel"
    _chalk_label.text = "Chalk: 80%"
    _chalk_label.add_theme_font_size_override("font_size", 16)
    _chalk_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.8, 0.8))
    _chalk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _chalk_label.anchors_preset = -1
    _chalk_label.anchor_left = 1.0
    _chalk_label.anchor_right = 1.0
    _chalk_label.offset_left = -190
    _chalk_label.offset_top = 60
    _chalk_label.offset_right = -16
    _chalk_label.offset_bottom = 84
    add_child(_chalk_label)


func _create_argument_button() -> void:
    var viewport_size := get_viewport().get_visible_rect().size

    # Button container for centering
    _argument_button = Button.new()
    _argument_button.name = "ArgumentButton"
    _argument_button.text = "ACCUSE"
    _argument_button.add_theme_font_size_override("font_size", 22)
    _argument_button.custom_minimum_size = Vector2(180, 64)

    # Position: bottom-right corner, y≥850
    _argument_button.anchors_preset = -1
    _argument_button.anchor_left = 1.0
    _argument_button.anchor_right = 1.0
    _argument_button.anchor_top = 1.0
    _argument_button.anchor_bottom = 1.0
    _argument_button.offset_left = -200
    _argument_button.offset_top = -180
    _argument_button.offset_right = -20
    _argument_button.offset_bottom = -116

    # Style: terracotta #CC6B49 background
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.8, 0.42, 0.29, 0.9)  # #CC6B49
    style.corner_radius_top_left = 12
    style.corner_radius_top_right = 12
    style.corner_radius_bottom_left = 12
    style.corner_radius_bottom_right = 12
    style.border_width_left = 2
    style.border_width_right = 2
    style.border_width_top = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.9, 0.55, 0.4, 1.0)
    _argument_button.add_theme_stylebox_override("normal", style)

    # Hover style
    var hover_style := style.duplicate() as StyleBoxFlat
    hover_style.bg_color = Color(0.85, 0.48, 0.35, 0.95)
    _argument_button.add_theme_stylebox_override("hover", hover_style)

    # Pressed style
    var pressed_style := style.duplicate() as StyleBoxFlat
    pressed_style.bg_color = Color(0.7, 0.35, 0.22, 1.0)
    _argument_button.add_theme_stylebox_override("pressed", pressed_style)

    # Font color
    _argument_button.add_theme_color_override("font_color", Color.WHITE)
    _argument_button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.85, 1.0))
    _argument_button.add_theme_color_override("font_pressed_color", Color(0.9, 0.85, 0.75, 1.0))

    _argument_button.pressed.connect(_on_argument_pressed)
    _argument_button.hide()
    add_child(_argument_button)

    # Cooldown label (inside/on top of button)
    _argument_cooldown_label = Label.new()
    _argument_cooldown_label.name = "ArgCooldownLabel"
    _argument_cooldown_label.add_theme_font_size_override("font_size", 14)
    _argument_cooldown_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.6, 1.0))
    _argument_cooldown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _argument_cooldown_label.anchors_preset = -1
    _argument_cooldown_label.anchor_left = 1.0
    _argument_cooldown_label.anchor_right = 1.0
    _argument_cooldown_label.anchor_top = 1.0
    _argument_cooldown_label.anchor_bottom = 1.0
    _argument_cooldown_label.offset_left = -200
    _argument_cooldown_label.offset_top = -110
    _argument_cooldown_label.offset_right = -20
    _argument_cooldown_label.offset_bottom = -92
    add_child(_argument_cooldown_label)

    # Start pulse animation
    _start_pulse_animation()


func _start_pulse_animation() -> void:
    if _argument_pulse_tween and _argument_pulse_tween.is_valid():
        _argument_pulse_tween.kill()
    _argument_pulse_tween = create_tween()
    _argument_pulse_tween.set_loops(0)  # Infinite
    _argument_pulse_tween.tween_property(_argument_button, "scale", Vector2(1.05, 1.05), 0.6)
    _argument_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    _argument_pulse_tween.tween_property(_argument_button, "scale", Vector2(1.0, 1.0), 0.6)
    _argument_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

# ── Silent Sneak Button ───────────────────────────────────────────────────────

func _create_silent_sneak_button() -> void:
    _silent_sneak_button = Button.new()
    _silent_sneak_button.name = "SilentSneakButton"
    _silent_sneak_button.text = "🐄 Sneak"
    _silent_sneak_button.add_theme_font_size_override("font_size", 20)
    _silent_sneak_button.custom_minimum_size = Vector2(160, 56)

    # Position: bottom-center, y≥850
    _silent_sneak_button.anchors_preset = -1
    _silent_sneak_button.anchor_left = 0.5
    _silent_sneak_button.anchor_right = 0.5
    _silent_sneak_button.anchor_top = 1.0
    _silent_sneak_button.anchor_bottom = 1.0
    _silent_sneak_button.offset_left = -80
    _silent_sneak_button.offset_top = -190
    _silent_sneak_button.offset_right = 80
    _silent_sneak_button.offset_bottom = -134

    # Style: brown #8B7355 background
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.545, 0.451, 0.333, 0.9)  # #8B7355
    style.corner_radius_top_left = 12
    style.corner_radius_top_right = 12
    style.corner_radius_bottom_left = 12
    style.corner_radius_bottom_right = 12
    style.border_width_left = 2
    style.border_width_right = 2
    style.border_width_top = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.65, 0.55, 0.42, 1.0)
    _silent_sneak_button.add_theme_stylebox_override("normal", style)

    # Hover style
    var hover_style := style.duplicate() as StyleBoxFlat
    hover_style.bg_color = Color(0.60, 0.50, 0.38, 0.95)
    _silent_sneak_button.add_theme_stylebox_override("hover", hover_style)

    # Pressed style
    var pressed_style := style.duplicate() as StyleBoxFlat
    pressed_style.bg_color = Color(0.48, 0.39, 0.28, 1.0)
    _silent_sneak_button.add_theme_stylebox_override("pressed", pressed_style)

    # Disabled style
    var disabled_style := style.duplicate() as StyleBoxFlat
    disabled_style.bg_color = Color(0.4, 0.35, 0.3, 0.5)
    _silent_sneak_button.add_theme_stylebox_override("disabled", disabled_style)

    # Font color
    _silent_sneak_button.add_theme_color_override("font_color", Color.WHITE)
    _silent_sneak_button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.85, 1.0))
    _silent_sneak_button.add_theme_color_override("font_pressed_color", Color(0.9, 0.85, 0.75, 1.0))
    _silent_sneak_button.add_theme_color_override("font_disabled_color", Color(0.6, 0.6, 0.6, 0.6))

    _silent_sneak_button.pressed.connect(_on_silent_sneak_pressed)
    _silent_sneak_button.hide()
    add_child(_silent_sneak_button)

    # Cooldown label (below button)
    _silent_sneak_cooldown_label = Label.new()
    _silent_sneak_cooldown_label.name = "SilentSneakCooldownLabel"
    _silent_sneak_cooldown_label.add_theme_font_size_override("font_size", 14)
    _silent_sneak_cooldown_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.6, 1.0))
    _silent_sneak_cooldown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _silent_sneak_cooldown_label.anchors_preset = -1
    _silent_sneak_cooldown_label.anchor_left = 0.5
    _silent_sneak_cooldown_label.anchor_right = 0.5
    _silent_sneak_cooldown_label.anchor_top = 1.0
    _silent_sneak_cooldown_label.anchor_bottom = 1.0
    _silent_sneak_cooldown_label.offset_left = -80
    _silent_sneak_cooldown_label.offset_top = -128
    _silent_sneak_cooldown_label.offset_right = 80
    _silent_sneak_cooldown_label.offset_bottom = -110
    add_child(_silent_sneak_cooldown_label)


func _on_silent_sneak_pressed() -> void:
    # Find SilentSneakSystem and activate
    var sneak_sys := _get_silent_sneak_system()
    if not sneak_sys:
        _update_info("Silent Sneak unavailable")
        return

    var local_player_id := 1  # Prototype: local player is entity_id=1
    var ok := sneak_sys.activate_silent_sneak(local_player_id)
    if not ok:
        _update_info("Cannot use Silent Sneak right now")


func _on_silent_sneak_activated(_payload: Dictionary) -> void:
    _silent_sneak_active = true
    if _silent_sneak_button:
        _silent_sneak_button.text = "🐄 Active!"
        _silent_sneak_button.disabled = true
        _silent_sneak_button.modulate = Color(0.6, 0.85, 0.6, 0.9)
    _silent_sneak_on_cooldown = false
    _silent_sneak_cooldown_timer = 0.0
    if _silent_sneak_cooldown_label:
        _silent_sneak_cooldown_label.text = ""


func _on_silent_sneak_deactivated(_payload: Dictionary) -> void:
    _silent_sneak_active = false
    # Start cooldown
    _silent_sneak_on_cooldown = true
    _silent_sneak_cooldown_timer = 30.0
    if _silent_sneak_button:
        _silent_sneak_button.text = "🐄 Sneak"
        _silent_sneak_button.disabled = true
        _silent_sneak_button.modulate = Color(0.5, 0.5, 0.5, 0.7)


func _on_silent_sneak_cooldown_ended(_payload: Dictionary) -> void:
    _silent_sneak_on_cooldown = false
    _silent_sneak_cooldown_timer = 0.0
    if _silent_sneak_button:
        _silent_sneak_button.disabled = false
        _silent_sneak_button.modulate = Color.WHITE
    if _silent_sneak_cooldown_label:
        _silent_sneak_cooldown_label.text = ""


func _get_silent_sneak_system():
    var root := get_tree().current_scene
    if not root:
        return null
    var systems := root.get_node_or_null("Systems")
    if not systems:
        return null
    return systems.get_node_or_null("SilentSneakSystem")

# ── Argument Button ───────────────────────────────────────────────────────────

func _on_argument_pressed() -> void:
    if _selected_target_id < 0:
        _update_info("Tap a player to accuse")
        # Flash the info label
        var tween := create_tween()
        tween.tween_property(_info_label, "modulate:a", 1.0, 0.1).from(0.4)
        return

    # Check if ArgumentSystem is available
    var arg_sys := _get_argument_system()
    if not arg_sys:
        _update_info("Argument system unavailable")
        return

    # Local player is entity_id=1 in prototype
    var local_player_id := 1
    var ok := arg_sys.request_argument(local_player_id, _selected_target_id)
    if not ok:
        _update_info("Cannot accuse right now")


## Update the selected target (called from game world when player is tapped).
func set_selected_target(entity_id: int) -> void:
    _selected_target_id = entity_id
    if entity_id > 0:
        _update_info("Target: Player %d" % entity_id)
    else:
        _update_info("Tap a player to accuse")
        _selected_target_id = -1

# ── Finding Systems ───────────────────────────────────────────────────────────

func _get_argument_system() -> ArgumentSystem:
    var root := get_tree().current_scene
    if not root:
        return null
    var systems := root.get_node_or_null("Systems")
    if not systems:
        return null
    return systems.get_node_or_null("ArgumentSystem") as ArgumentSystem

# ── Event Handlers ────────────────────────────────────────────────────────────

func _on_entity_state_changed(payload: Dictionary) -> void:
    var node = payload.get("node")
    if node is Player and node.is_local:
        var state_name := payload.get("current", "?")
        _state_label.text = "Player State: %s" % state_name


func _on_game_state_changed(payload: Dictionary) -> void:
    var to: int = payload.get("to", -1)
    _state_label.text = "Game: %s" % GameState.State.keys()[to]


func _on_match_state_changed(payload: Dictionary) -> void:
    var to_state: int = payload.get("to", -1)
    var from_state: int = payload.get("from", -1)

    # Toggle argument button visibility
    if to_state == GameState.MatchState.SEARCHING:
        _is_searching = true
        if _argument_button:
            _argument_button.show()
            _start_pulse_animation()
        if _hint_counter_label:
            _hint_counter_label.show()
        if _silent_sneak_button:
            _silent_sneak_button.show()
        _selected_target_id = -1
    elif from_state == GameState.MatchState.SEARCHING:
        _is_searching = false
        if _argument_button:
            _argument_button.hide()
        if _hint_counter_label:
            _hint_counter_label.hide()
        if _silent_sneak_button:
            _silent_sneak_button.hide()
        _selected_target_id = -1

    # Show spectator button when spectator enters SEARCHING
    if _is_spectator and to_state == GameState.MatchState.SEARCHING:
        if _spectator_button and not _spectator_reveal_used:
            _spectator_button.show()
    else:
        if _spectator_button:
            _spectator_button.hide()


func _on_timer_tick(payload: Dictionary) -> void:
    var remaining: int = payload.get("remaining_seconds", 0)
    var minutes := remaining / 60
    var seconds := remaining % 60
    if _timer_label:
        _timer_label.text = "%d:%02d" % [minutes, seconds]

        # Warning color when under 30s
        if remaining <= 30:
            _timer_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))
        elif remaining <= 60:
            _timer_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3, 1.0))
        else:
            _timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.65, 1.0))


func _on_timer_expired(_payload: Dictionary) -> void:
    if _timer_label:
        _timer_label.text = "0:00"
        _timer_label.add_theme_color_override("font_color", Color(1.0, 0.1, 0.1, 1.0))


func _on_chalk_meter_changed(payload: Dictionary) -> void:
    var pct: float = payload.get("remaining_percent", 1.0)
    if _chalk_label:
        _chalk_label.text = "Chalk: %d%%" % int(pct * 100)
        if pct <= 0.2:
            _chalk_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 0.9))
        else:
            _chalk_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.8, 0.8))


func _on_argument_started(payload: Dictionary) -> void:
    # Show the argument overlay
    if _argument_overlay and is_instance_valid(_argument_overlay):
        _argument_overlay.queue_free()

    var overlay_scene := load("res://scenes/overlay/argument_overlay.tscn") as PackedScene
    if overlay_scene:
        _argument_overlay = overlay_scene.instantiate() as ArgumentOverlay
        get_tree().root.add_child(_argument_overlay)
        _argument_overlay.start_argument(payload)

    # Blurt sound
    AudioManager.play_accusation_blurt()

    # Start cooldown on button
    _argument_on_cooldown = true
    _argument_cooldown_timer = ARGUMENT_COOLDOWN
    if _argument_button:
        _argument_button.disabled = true
        _argument_button.modulate = Color(0.5, 0.5, 0.5, 0.7)


func _on_argument_resolved(payload: Dictionary) -> void:
    # Show result on overlay
    if _argument_overlay and is_instance_valid(_argument_overlay):
        _argument_overlay.show_result(payload)

    # Update info with result
    var is_true: bool = payload.get("is_true", false)
    if is_true:
        _update_info("CORRECT ACCUSATION! Ghost revealed!")
    else:
        _update_info("FALSE ACCUSATION! -30s penalty.")

# ── Helpers ───────────────────────────────────────────────────────────────────

func _update_info(text: String) -> void:
    if _info_label:
        _info_label.text = text

# ── Hint Counter & Spectator UI Creation ──────────────────────────────────────

func _create_hint_counter_label() -> void:
    _hint_counter_label = Label.new()
    _hint_counter_label.name = "HintCounter"
    _hint_counter_label.text = "Hints: 0"
    _hint_counter_label.add_theme_font_size_override("font_size", 20)
    _hint_counter_label.add_theme_color_override("font_color", Color(0.83, 0.63, 0.09, 0.9))
    _hint_counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _hint_counter_label.anchors_preset = Control.PRESET_CENTER_TOP
    _hint_counter_label.offset_top = 60
    _hint_counter_label.offset_left = -100
    _hint_counter_label.offset_right = 100
    _hint_counter_label.offset_bottom = 88
    _hint_counter_label.hide()
    add_child(_hint_counter_label)


func _create_spectator_button() -> void:
    _spectator_button = Button.new()
    _spectator_button.name = "SpectatorRevealButton"
    _spectator_button.text = "👁 Reveal Available"
    _spectator_button.add_theme_font_size_override("font_size", 18)
    _spectator_button.custom_minimum_size = Vector2(200, 52)

    # Position: bottom-left
    _spectator_button.anchors_preset = -1
    _spectator_button.anchor_left = 0.0
    _spectator_button.anchor_right = 0.0
    _spectator_button.anchor_top = 1.0
    _spectator_button.anchor_bottom = 1.0
    _spectator_button.offset_left = 16
    _spectator_button.offset_top = -180
    _spectator_button.offset_right = 216
    _spectator_button.offset_bottom = -128

    # Style: ghostly teal
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.2, 0.6, 0.7, 0.85)
    style.corner_radius_top_left = 10
    style.corner_radius_top_right = 10
    style.corner_radius_bottom_left = 10
    style.corner_radius_bottom_right = 10
    style.border_width_left = 2
    style.border_width_right = 2
    style.border_width_top = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.3, 0.75, 0.85, 1.0)
    _spectator_button.add_theme_stylebox_override("normal", style)

    var hover_style := style.duplicate() as StyleBoxFlat
    hover_style.bg_color = Color(0.25, 0.68, 0.78, 0.9)
    _spectator_button.add_theme_stylebox_override("hover", hover_style)

    _spectator_button.add_theme_color_override("font_color", Color.WHITE)
    _spectator_button.pressed.connect(_on_spectator_reveal_pressed)
    _spectator_button.hide()
    add_child(_spectator_button)


func _create_spectator_notification() -> void:
    _spectator_notification_label = Label.new()
    _spectator_notification_label.name = "SpectatorNotification"
    _spectator_notification_label.text = ""
    _spectator_notification_label.add_theme_font_size_override("font_size", 18)
    _spectator_notification_label.add_theme_color_override("font_color", Color(0.3, 0.75, 0.85, 1.0))
    _spectator_notification_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _spectator_notification_label.anchors_preset = Control.PRESET_CENTER_TOP
    _spectator_notification_label.offset_top = 90
    _spectator_notification_label.offset_left = -250
    _spectator_notification_label.offset_right = 250
    _spectator_notification_label.offset_bottom = 120
    add_child(_spectator_notification_label)


# ── Hint Trap Event Handlers ──────────────────────────────────────────────────

func _on_hint_revealed(_payload: Dictionary) -> void:
    _update_hint_counter()


func _on_hint_placed(_payload: Dictionary) -> void:
    _update_hint_counter()


func _on_hint_investigated(_payload: Dictionary) -> void:
    _update_hint_counter()


func _on_hint_trap_triggered(payload: Dictionary) -> void:
    var penalty: int = payload.get("penalty", FAKE_HINT_PENALTY)
    _update_hint_counter()
    _show_penalty_flash(penalty)


func _on_spectator_registered(payload: Dictionary) -> void:
    var spectator_id: int = payload.get("spectator_id", -1)
    # Check if this is the local player (prototype: local entity_id=1)
    if spectator_id == 1:
        _is_spectator = true
        _spectator_reveal_used = false
        _show_spectator_notification("You are now a SPECTATOR.\nTap a ghost line to reveal it!")
        if _spectator_button:
            _spectator_button.text = "👁 Reveal Available"
            _spectator_button.disabled = false


func _on_spectator_reveal_used_local(payload: Dictionary) -> void:
    var spectator_id: int = payload.get("spectator_id", -1)
    if spectator_id == 1:
        _spectator_reveal_used = true
        if _spectator_button:
            _spectator_button.text = "Reveal Used"
            _spectator_button.disabled = true
            _spectator_button.hide()
        if _spectator_notification_label:
            _spectator_notification_label.text = "Reveal used"


# ── Spectator Button ──────────────────────────────────────────────────────────

func _on_spectator_reveal_pressed() -> void:
    # In production: spectator has selected a ghost line via tap,
    # then pressed this button to confirm. For prototype, this
    # activates reveal mode — next tap on a ghost line triggers the reveal.
    _update_info("Tap a ghost line to reveal it to searchers!")


# ── Penalty Flash ─────────────────────────────────────────────────────────────

func _show_penalty_flash(seconds: int) -> void:
    var flash_label := Label.new()
    flash_label.name = "PenaltyFlash"
    flash_label.text = "-%ds" % seconds
    flash_label.add_theme_font_size_override("font_size", 42)
    flash_label.add_theme_color_override("font_color", Color(1.0, 0.15, 0.15, 1.0))
    flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    flash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    flash_label.anchors_preset = Control.PRESET_CENTER
    flash_label.offset_left = -150
    flash_label.offset_top = -80
    flash_label.offset_right = 150
    flash_label.offset_bottom = -20
    add_child(flash_label)

    # Animate: scale up + fade out
    var tween := create_tween()
    tween.set_parallel(true)
    tween.tween_property(flash_label, "scale", Vector2(1.5, 1.5), 0.5)
    tween.tween_property(flash_label, "modulate:a", 0.0, 0.5)
    tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func():
        flash_label.queue_free()
    )


# ── Hint Counter ──────────────────────────────────────────────────────────────

func _update_hint_counter() -> void:
    if not _hint_counter_label:
        return
    var hint_sys := _get_hint_system()
    if hint_sys:
        var count := hint_sys.get_active_hint_count()
        _hint_counter_label.text = "Hints: %d" % count


# ── Spectator Notification ────────────────────────────────────────────────────

func _show_spectator_notification(text: String) -> void:
    if _spectator_notification_label:
        _spectator_notification_label.text = text
        _spectator_notification_label.modulate.a = 1.0

        var tween := create_tween()
        tween.tween_interval(4.0)
        tween.tween_property(_spectator_notification_label, "modulate:a", 0.0, 0.5)


# ── System Lookup ─────────────────────────────────────────────────────────────

func _get_hint_system():
    var root := get_tree().current_scene
    if not root:
        return null
    var systems := root.get_node_or_null("Systems")
    if not systems:
        return null
    return systems.get_node_or_null("HintSystem")

# ── Sloppy Count ─────────────────────────────────────────────────────────────

func _create_sloppy_count_banner() -> void:
    _sloppy_count_banner = Label.new()
    _sloppy_count_banner.name = "SloppyCountBanner"
    _sloppy_count_banner.text = ""
    _sloppy_count_banner.add_theme_font_size_override("font_size", 22)
    _sloppy_count_banner.add_theme_color_override("font_color", Color(0.83, 0.63, 0.09, 1.0))
    _sloppy_count_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _sloppy_count_banner.anchors_preset = Control.PRESET_CENTER_TOP
    _sloppy_count_banner.offset_top = 32
    _sloppy_count_banner.offset_left = -200
    _sloppy_count_banner.offset_right = 200
    _sloppy_count_banner.offset_bottom = 60
    _sloppy_count_banner.hide()
    add_child(_sloppy_count_banner)

func _on_sloppy_count_started(_payload: Dictionary) -> void:
    if _sloppy_count_banner:
        _sloppy_count_banner.text = "Analyzing chalk net..."
        _sloppy_count_banner.add_theme_color_override("font_color", Color(0.83, 0.63, 0.09, 1.0))
        _sloppy_count_banner.show()

func _on_sloppy_count_finished(payload: Dictionary) -> void:
    var percentage: float = payload.get("percentage", 0.0)
    var passed: bool = payload.get("passed", false)
    if _sloppy_count_banner:
        if passed:
            _sloppy_count_banner.text = "%d%% — CLEAN!" % int(percentage)
            _sloppy_count_banner.add_theme_color_override("font_color", Color(0.2, 0.9, 0.3, 1.0))
        else:
            _sloppy_count_banner.text = "%d%% — SLOPPY!" % int(percentage)
            _sloppy_count_banner.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2, 1.0))
        # Auto-hide after 3s
        var tween := create_tween()
        tween.tween_interval(3.0)
        tween.tween_callback(func():
            if _sloppy_count_banner:
                _sloppy_count_banner.hide()
        )
