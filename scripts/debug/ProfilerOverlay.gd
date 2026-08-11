# ProfilerOverlay.gd — Debug performance overlay (Android optimization, Prompt 16)
#
# Compact corner panel showing the metrics that matter on a phone:
#   - FPS + frame time (process)
#   - Draw calls (RENDER_TOTAL_DRAW_CALLS_IN_FRAME) and 2D item count
#   - Static RAM usage (Godot's tracked allocation) and node count
#
# Toggle:
#   - F3 key (desktop / wired keyboard)
#   - Third simultaneous finger down (mobile — deliberately does NOT collide
#     with the 1-finger move gesture or the 2-finger draw gesture)
#
# Release builds: the autoload is registered but immediately goes inert
# (no UI, no _process, no _input), so it costs nothing in a release APK.
# `OS.is_debug_build()` is false for Android release exports.
extends CanvasLayer

## UI refresh interval (seconds). Reading Performance monitors every frame is
## cheap, but 2 Hz is plenty for a debug readout and keeps the string work low.
const REFRESH_INTERVAL := 0.5

const PANEL_W := 280
const PANEL_H := 150
const MARGIN := 8

var _panel: Panel = null
var _label: Label = null
var _visible_flag: bool = false
var _accum: float = 0.0


func _ready() -> void:
	layer = 100  # Above HUD, scene transitions, everything.
	name = "ProfilerOverlay"
	if not OS.is_debug_build():
		# Release APK: zero cost — no UI, no processing, no input.
		set_process(false)
		set_process_input(false)
		return
	_build_ui()
	_set_overlay_visible(false)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	_update_stats()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_toggle()
	elif event is InputEventScreenTouch and event.pressed and event.index >= 2:
		_toggle()


# ── UI ────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_panel = Panel.new()
	_panel.name = "Panel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -PANEL_W - MARGIN
	_panel.offset_top = MARGIN
	_panel.offset_right = -MARGIN
	_panel.offset_bottom = MARGIN + PANEL_H
	add_child(_panel)

	_label = Label.new()
	_label.name = "Stats"
	_label.add_theme_font_size_override("font_size", 12)
	_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6, 1.0))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = 4
	_label.offset_top = 4
	_label.offset_right = -4
	_label.offset_bottom = -4
	_panel.add_child(_label)


func _update_stats() -> void:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS)
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var items_2d := Performance.get_monitor(Performance.RENDER_2D_ITEMS_IN_FRAME)
	var ram_mb := OS.get_static_memory_usage() / 1048576.0
	var ram_peak_mb := OS.get_static_memory_peak_usage() / 1048576.0
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	_label.text = (
		"FPS: %4.0f  |  frame: %5.2f ms\n"
		% [fps, frame_ms]
		+ "draw calls: %d  |  2D items: %d\n" % [draw_calls, items_2d]
		+ "RAM: %.1f MB (peak %.1f)\n" % [ram_mb, ram_peak_mb]
		+ "nodes: %d" % nodes
	)


func _toggle() -> void:
	_set_overlay_visible(not _visible_flag)


func _set_overlay_visible(v: bool) -> void:
	_visible_flag = v
	if _panel:
		_panel.visible = v
	print("ProfilerOverlay: %s" % ("on" if v else "off"))
