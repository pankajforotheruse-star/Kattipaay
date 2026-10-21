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
	if _score_label:
		if round != 0:
			_score_label.text = "Round: %+d\nTotal: %d" % [round, total]
		else:
			_score_label.text = "Total score: %d" % total
