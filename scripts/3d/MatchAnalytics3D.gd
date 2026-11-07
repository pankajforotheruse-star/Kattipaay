class_name MatchAnalytics3D
extends RefCounted
## Privacy-minimal local match outcomes for *real* playtest evidence.
## Does not save personal information, touch coordinates or hidden chalk paths.
const FILE_PATH := "user://chalk_gaon_3d_match_telemetry.jsonl"
const MAX_MATCHES := 1000

static func append_match(outcome: Dictionary) -> bool:
	var lines := load_matches()
	lines.append(outcome.duplicate(true))
	if lines.size() > MAX_MATCHES:
		lines = lines.slice(lines.size() - MAX_MATCHES)
	var file := FileAccess.open(FILE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	for entry in lines:
		file.store_line(JSON.stringify(entry))
	file.close()
	return true

static func load_matches() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if not FileAccess.file_exists(FILE_PATH):
		return records
	var file := FileAccess.open(FILE_PATH, FileAccess.READ)
	if file == null:
		return records
	while not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary and parsed.get("schema", "") == "chalk_gaon_3d_match_v1":
			records.append(parsed)
	return records

static func analyze(records: Array[Dictionary], difficulty: int) -> Dictionary:
	var count := 0
	var human_wins := 0
	var cpu_wins := 0
	var draws := 0
	var inspections := 0.0
	var coverage := 0.0
	var human_marks := 0.0
	var cpu_marks := 0.0
	for entry in records:
		if int(entry.get("difficulty", -1)) != difficulty:
			continue
		count += 1
		var result := str(entry.get("result", ""))
		if result.begins_with("HUMAN WINS"):
			human_wins += 1
		elif result.begins_with("CPU WINS"):
			cpu_wins += 1
		else:
			draws += 1
		inspections += float(entry.get("cpu_inspections", 0))
		coverage += float(entry.get("cpu_search_cells", 0))
		human_marks += float(entry.get("human_marks", 0))
		cpu_marks += float(entry.get("cpu_marks", 0))
	var ci := wilson_interval(human_wins, count)
	return {
		"difficulty": difficulty, "matches": count,
		"human_wins": human_wins, "cpu_wins": cpu_wins, "draws": draws,
		"human_win_rate": float(human_wins) / float(maxi(count, 1)),
		"human_win_rate_95ci": ci,
		"mean_cpu_inspections": inspections / float(maxi(count, 1)),
		"mean_cpu_search_cells": coverage / float(maxi(count, 1)),
		"mean_human_marks": human_marks / float(maxi(count, 1)),
		"mean_cpu_marks": cpu_marks / float(maxi(count, 1)),
		"minimum_100_matches_met": count >= 100
	}

static func wilson_interval(successes: int, trials: int) -> Vector2:
	if trials <= 0:
		return Vector2.ZERO
	var z := 1.959963984540054
	var n := float(trials)
	var p := float(successes) / n
	var denominator := 1.0 + z * z / n
	var center := (p + z * z / (2.0 * n)) / denominator
	var radius := z * sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n)) / denominator
	return Vector2(maxf(0.0, center - radius), minf(1.0, center + radius))
