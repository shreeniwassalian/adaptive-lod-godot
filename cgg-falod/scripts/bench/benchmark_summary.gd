extends RefCounted
## Summary statistics over the recorded frame rows.

## Columns that get min/mean/percentile statistics (null cells are skipped, and counted).
const STAT_COLUMNS := [
	"frame_time_ms", "process_ms_1hz", "physics_ms_1hz", "render_cpu_ms", "render_gpu_ms",
	"draw_calls", "draw_calls_visible", "primitives", "primitives_visible", "objects", "video_mem_mb",
	"lod_switches", "lod_bias", "lod_update_ms", "trees_lod0", "trees_lod1", "trees_lod2",
	"grass_clumps_t0", "grass_clumps_t1", "grass_clumps_t2", "grass_switches", "grass_update_ms",
	"bush_drawn", "bush_switches", "bush_update_ms", "debris_drawn", "debris_switches", "debris_update_ms",
	"rocks_instances", "lod_total_update_ms", "lod_policies_updated", "ctrl_signal_ms", "ctrl_raw_ms", "ctrl_target_ms",
	"ctrl_error", "ctrl_p_term", "ctrl_i_term", "ctrl_update_ms",
]
## Frames slower than this count as hitches.
const HITCH_MS := 33.4


static func summarize(columns: PackedStringArray, rows: Array, measured_s: float) -> Dictionary:
	var result := {
		"frames": rows.size(),
		"measured_duration_s": measured_s,
		# Frames divided by wall time: the real average rate, not the engine's once-a-second counter.
		"avg_fps": rows.size() / measured_s if measured_s > 0.0 else null,
		"columns": {},
	}
	for name in STAT_COLUMNS:
		var index := columns.find(name)
		var values := PackedFloat64Array()
		for row in rows:
			if row[index] != null:
				values.append(float(row[index]))
		result["columns"][name] = _stats(values, rows.size())

	var switches: Dictionary = result["columns"]["lod_switches"]
	if switches["available"]:
		var index := columns.find("lod_switches")
		var total := 0
		var frames_with_switches := 0
		for row in rows:
			total += int(row[index])
			if int(row[index]) > 0:
				frames_with_switches += 1
		result["lod_switches_total"] = total
		result["frames_with_lod_switches"] = frames_with_switches

	var frame_stats: Dictionary = result["columns"]["frame_time_ms"]
	if frame_stats["available"]:
		# "1% low" here means 1000 / p99 frame time, not the mean of the slowest 1% of frames.
		result["fps_1pct_low"] = 1000.0 / frame_stats["p99"]
		var hitches := 0
		var index := columns.find("frame_time_ms")
		for row in rows:
			if float(row[index]) > HITCH_MS:
				hitches += 1
		result["hitches_over_%dms" % int(HITCH_MS)] = hitches
	return result


static func _stats(values: PackedFloat64Array, total_rows: int) -> Dictionary:
	if values.is_empty():
		return {"available": false, "samples": 0, "total_rows": total_rows}
	var sorted := values.duplicate()
	sorted.sort()
	var mean := 0.0
	for v in values:
		mean += v
	mean /= values.size()
	var variance := 0.0
	for v in values:
		variance += (v - mean) * (v - mean)
	return {
		"available": true, "samples": values.size(), "total_rows": total_rows,
		"mean": mean, "stddev": sqrt(variance / values.size()),
		"min": sorted[0], "p50": _percentile(sorted, 0.50), "p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99), "max": sorted[sorted.size() - 1],
	}


## Nearest-rank percentile of an ascending array.
static func _percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	var rank := clampi(int(ceil(fraction * sorted.size())) - 1, 0, sorted.size() - 1)
	return sorted[rank]
