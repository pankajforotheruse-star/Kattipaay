class_name AndroidPerformance3D
extends Node
## Opt-in real-runtime sampling on Android/desktop. CSV + JSON under user://.
## No claim of device results until an actual handset runs the scene.
const SAMPLE_SECONDS := 0.5
const MAX_SAMPLES := 3600
var enabled := false
var elapsed := 0.0
var samples: Array[Dictionary] = []
var peak_static_bytes := 0.0
var frame_histogram := PackedInt32Array()
var frame_sample_count := 0
var display_label: Label

func _ready() -> void:
	enabled = bool(ProjectSettings.get_setting("chalk_gaon/3d_profile_enabled", false))
	set_process(enabled)
	if enabled:
		var layer := CanvasLayer.new()
		layer.name = "PerformanceQA"
		add_child(layer)
		display_label = Label.new()
		display_label.name = "PerformanceReadout"
		display_label.position = Vector2(15, 115)
		display_label.add_theme_font_size_override("font_size", 15)
		display_label.add_theme_color_override("font_color", Color(0.95, 0.91, 0.68))
		display_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(display_label)

func _process(delta: float) -> void:
	if not enabled:
		return
	_record_frame_delta(delta * 1000.0)
	elapsed += delta
	if elapsed < SAMPLE_SECONDS:
		return
	elapsed -= SAMPLE_SECONDS
	var fps := maxf(1.0, float(Performance.get_monitor(Performance.TIME_FPS)))
	var frame_ms := 1000.0 / fps
	var draw_calls := float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var memory_bytes := float(Performance.get_monitor(Performance.MEMORY_STATIC))
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	add_measurement(frame_ms, draw_calls, memory_bytes, physics_ms, false)
	if display_label != null:
		display_label.text = "QA  %d fps  |  %.1f ms  |  %d draws  |  %.0f MB" % [
			roundi(fps), frame_ms, roundi(draw_calls), memory_bytes / 1048576.0]

func add_measurement(frame_ms: float, draw_calls: float, memory_bytes: float, physics_ms: float = 0.0, count_frame: bool = true) -> void:
	if count_frame:
		_record_frame_delta(frame_ms)
	peak_static_bytes = maxf(peak_static_bytes, memory_bytes)
	if samples.size() >= MAX_SAMPLES:
		samples.pop_front()
	samples.append({
		"frame_ms": frame_ms, "draw_calls": draw_calls,
		"memory_bytes": memory_bytes, "physics_ms": physics_ms
	})

## Histogram records actual frame deltas every frame, with 0.5ms buckets
## (0..200ms). CSV samples remain low-frequency to minimize storage writes.
func _record_frame_delta(frame_ms: float) -> void:
	if frame_histogram.is_empty():
		frame_histogram.resize(401)
	var bucket := clampi(roundi(frame_ms * 2.0), 0, 400)
	frame_histogram[bucket] += 1
	frame_sample_count += 1

func _frame_percentile(percentile: float) -> float:
	if frame_sample_count == 0:
		return 0.0
	var target := maxi(1, ceili(float(frame_sample_count) * percentile))
	var cumulative := 0
	for i in range(frame_histogram.size()):
		cumulative += frame_histogram[i]
		if cumulative >= target:
			return float(i) * 0.5
	return 200.0

func summary() -> Dictionary:
	var frames: Array[float] = []
	var draw_sum := 0.0
	var physics_sum := 0.0
	for row in samples:
		frames.append(float(row["frame_ms"]))
		draw_sum += float(row["draw_calls"])
		physics_sum += float(row["physics_ms"])
	frames.sort()
	var count := frames.size()
	return {
		"schema": "chalk_gaon_3d_perf_v1",
		"platform": OS.get_name(),
		"sample_count": count,
		"frame_p50_ms": _frame_percentile(0.50),
		"frame_p95_ms": _frame_percentile(0.95),
		"frame_p99_ms": _frame_percentile(0.99),
		"frame_sample_count": frame_sample_count,
		"frame_percentile_source": "per_frame_delta_0.5ms_histogram",
		"mean_draw_calls": draw_sum / float(maxi(count, 1)),
		"mean_physics_ms": physics_sum / float(maxi(count, 1)),
		"peak_static_mb": peak_static_bytes / 1048576.0,
		"device_thermal": "not_available_from_godot_runtime",
		"note": "Frame percentiles use game-loop delta, not GPU presentation timestamps. Confirm with Android GPU tools."
	}

func _percentile(sorted: Array[float], percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := clampi(ceili(float(sorted.size()) * percentile) - 1, 0, sorted.size() - 1)
	return sorted[index]

func export_report() -> bool:
	if samples.is_empty():
		return false
	var csv := FileAccess.open("user://chalk_gaon_3d_perf.csv", FileAccess.WRITE)
	if csv == null:
		return false
	csv.store_line("sample,frame_ms,draw_calls,memory_bytes,physics_ms")
	for i in range(samples.size()):
		var row := samples[i]
		csv.store_line("%d,%.3f,%.0f,%.0f,%.3f" % [
			i, float(row["frame_ms"]), float(row["draw_calls"]),
			float(row["memory_bytes"]), float(row["physics_ms"])])
	csv.close()
	var file := FileAccess.open("user://chalk_gaon_3d_perf_summary.json", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(summary(), "  "))
	file.close()
	return true
