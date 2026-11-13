class_name ChalkMatchRules
extends RefCounted
## Owner-approved rules shared by 2D solo and 3D local play.
## Visuals, physics, input and network transport are deliberately external.
const HUMAN_ID := 1
const CPU_ID := 2
const DRAW_SECONDS := 40.0
const MEETING_SECONDS := 15.0
const SEARCH_SECONDS := 30.0
const DISCOVERY_DISTANCE_METRES := 3.5
const CPU_MARK_RANGES := [
	Vector2i(50, 100), Vector2i(65, 120),
	Vector2i(85, 150), Vector2i(110, 180)
]

static func opponent(owner: int) -> int:
	return CPU_ID if owner == HUMAN_ID else HUMAN_ID

static func first_searcher(coin_face: int, human_call: int) -> int:
	return HUMAN_ID if coin_face == human_call else CPU_ID

static func searcher_for_phase(first: int, phase_index: int) -> int:
	return first if phase_index == 1 else opponent(first)

static func winner_from_survivors(human: int, cpu: int) -> int:
	if human == cpu:
		return 0
	return HUMAN_ID if human > cpu else CPU_ID

static func winner_label(human: int, cpu: int) -> String:
	match winner_from_survivors(human, cpu):
		HUMAN_ID: return "HUMAN WINS"
		CPU_ID: return "CPU WINS"
		_: return "DRAW"

static func valid_searcher(owner: int, phase: String, active_searcher: int) -> bool:
	return phase == "SEARCHING" and owner == active_searcher

static func can_strike(stroke_owner: int, searcher: int, phase: String, already_struck: bool) -> bool:
	return valid_searcher(searcher, phase, searcher) and not already_struck and stroke_owner == opponent(searcher)

static func cpu_target_range(difficulty: int) -> Vector2i:
	return CPU_MARK_RANGES[clampi(difficulty, 0, CPU_MARK_RANGES.size() - 1)]
