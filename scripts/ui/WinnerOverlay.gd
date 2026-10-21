# WinnerOverlay.gd — Round-winner banner for the WINNER match state
#
# Lightweight post-round result (slice 3, R6): the round ends with this banner,
# a driver-owned hold (chalk_gaon/solo_winner_hold_seconds), then home. The
# heavier GameOverScreen scene belongs to the long-form game flow; routing it
# here would unload the game world mid-driver-flow.
#
# Reads the result from ScoringManager (winner_id + surviving hidden-line
# counts — the R6 "surviving lines win" scoring).

class_name WinnerOverlay
extends Control

func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.08, 0.62)
	add_child(dim)

	var human_won := ScoringManager.get_winner_id() == 1

	var title := Label.new()
	title.name = "WinnerTitle"
	title.text = "YOU WIN!" if human_won else "CPU WINS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_color_override("font_color", Color("FFD700") if human_won else Color("E57373"))
	title.set_anchors_preset(Control.PRESET_CENTER)
	title.offset_left = -480
	title.offset_top = -190
	title.offset_right = 480
	title.offset_bottom = -110
	add_child(title)

	var human_survivors := ScoringManager.get_human_surviving_lines()
	var cpu_survivors := ScoringManager.get_cpu_surviving_lines()

	var sub := Label.new()
	sub.name = "WinnerSubtitle"
	sub.text = "Your hidden lines survived: %d\nCPU\u2019s hidden lines survived: %d" % [human_survivors, cpu_survivors]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 24)
	sub.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95, 0.95))
	sub.set_anchors_preset(Control.PRESET_CENTER)
	sub.offset_left = -480
	sub.offset_top = -60
	sub.offset_right = 480
	sub.offset_bottom = 20
	add_child(sub)

	var sub2 := Label.new()
	sub2.name = "WinnerNote"
	sub2.text = "More surviving hidden lines wins" if human_survivors != cpu_survivors else "Tie broken in your favor"
	sub2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub2.add_theme_font_size_override("font_size", 16)
	sub2.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	sub2.set_anchors_preset(Control.PRESET_CENTER)
	sub2.offset_left = -480
	sub2.offset_top = 36
	sub2.offset_right = 480
	sub2.offset_bottom = 66
	add_child(sub2)