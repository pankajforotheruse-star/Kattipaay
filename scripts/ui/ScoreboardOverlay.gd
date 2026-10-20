# ScoreboardOverlay.gd — Minimal round-end score overlay for the VS CPU loop.
# Shows the round / total score so DONE #6 ("score shows") holds. Read-only:
# the SoloMatchDriver advances the match flow onward after SCORING.
class_name ScoreboardOverlay
extends CanvasLayer

@onready var _score_label: Label = %ScoreLabel

func _ready() -> void:
	layer = 30
	var total := ScoringManager.get_total_score()
	var round := ScoringManager.get_round_score(ScoringManager.get_current_round())
	var human_lines := ScoringManager.get_human_surviving_lines()
	var cpu_lines := ScoringManager.get_cpu_surviving_lines()
	if _score_label:
		if GameState.solo_vs_cpu:
			# Survivor counts decide this game. Legacy bonus points are
			# optional statistics and must not masquerade as the win score.
			_score_label.text = "YOUR LINES: %d\nCPU LINES: %d" % [human_lines, cpu_lines]
		elif round != 0:
			_score_label.text = "Round: %+d\nTotal: %d" % [round, total]
		else:
			_score_label.text = "Total score: %d" % total
