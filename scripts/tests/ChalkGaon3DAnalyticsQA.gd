extends SceneTree
## Validate statistics and runtime QA serialization; synthetic fixtures are NOT
## a human playtest or proof of difficulty balance.
var faults: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var records: Array[Dictionary] = []
	for difficulty in range(4):
		for i in range(120):
			var outcome := "HUMAN WINS" if i < [90, 65, 45, 25][difficulty] else "CPU WINS"
			records.append({
				"schema": "chalk_gaon_3d_match_v1", "session_kind": "local_play_vs_cpu", "difficulty": difficulty,
				"result": outcome, "cpu_inspections": i % 7,
				"cpu_search_cells": 8 + difficulty * 3,
				"human_marks": 80, "cpu_marks": 100
			})
	for difficulty in range(4):
		var report := MatchAnalytics3D.analyze(records, difficulty)
		_check(int(report["matches"]) == 120, "120 seeded statistical fixtures for difficulty %d" % difficulty)
		_check(bool(report["minimum_100_matches_met"]), "100-match threshold is correctly recognized")
		var bounds: Vector2 = report["human_win_rate_95ci"]
		_check(bounds.x <= float(report["human_win_rate"]) and bounds.y >= float(report["human_win_rate"]), "Wilson CI contains sample rate")
		if difficulty > 0:
			_check(float(report["human_win_rate"]) < float(MatchAnalytics3D.analyze(records, difficulty - 1)["human_win_rate"]), "Synthetic fixture monotonicity")
	var empty := MatchAnalytics3D.analyze([], 0)
	_check(int(empty["matches"]) == 0 and not bool(empty["minimum_100_matches_met"]), "Zero samples cannot claim balance")
	var qa := AndroidPerformance3D.new()
	root.add_child(qa)
	for i in range(100):
		qa.add_measurement(12.0 if i < 95 else 38.0, 125.0, 75000000.0, 3.2)
	var perf := qa.summary()
	_check(int(perf["sample_count"]) == 100, "Performance sample count")
	_check(float(perf["frame_p50_ms"]) == 12.0, "Median frame time")
	_check(float(perf["frame_p99_ms"]) == 38.0, "P99 frame time")
	_check(float(perf["peak_static_mb"]) > 70.0, "Peak memory conversion")
	_check(qa.export_report(), "Export QA CSV and JSON")
	if faults.is_empty():
		print("CHALK_GAON_3D_ANALYTICS_QA: PASS (statistics/percentiles/export; synthetic fixtures)")
		quit(0)
	else:
		for issue in faults:
			push_error("3D_ANALYTICS_QA: " + issue)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		faults.append(label)
