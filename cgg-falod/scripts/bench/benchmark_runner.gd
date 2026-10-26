extends Node
## Root of scenes/benchmark.tscn. Runs the existing Terrain3D environment under a scripted camera:
## startup -> warm-up (camera travels the path) -> settle (camera held at the path start) -> measured run.
## Writes <label>_<timestamp>.csv (one row per measured frame) and a matching .json (configuration,
## environment, scene fingerprint, summary statistics). See docs/benchmark.md.
##
## Independent of the interactive player: the Player node is disabled and hidden, F1 free-fly is turned
## off, and the only camera is $BenchmarkCamera. Esc aborts the run (partial data is saved, marked aborted).

const BenchmarkConfig := preload("res://scripts/bench/benchmark_config.gd")
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const MetricsSampler := preload("res://scripts/bench/metrics_sampler.gd")
const CsvLogger := preload("res://scripts/bench/csv_logger.gd")
const BenchmarkSummary := preload("res://scripts/bench/benchmark_summary.gd")
const VegetationCounts := preload("res://scripts/lod/vegetation_counts.gd")

enum Phase { STARTUP, WARMUP, SETTLE, MEASURE, DONE }

## Version of the CSV/JSON layout, written to the JSON as csv_schema_version.
## 1 = harness + trees, 2 = + grass columns, 3 = + bush/debris/rock columns and lod_total_update_ms,
## 4 = + adaptive controller columns (ctrl_*), lod_policies_updated; lod_bias is now filled in adaptive mode.
const CSV_SCHEMA_VERSION := 4

## One row per measured frame. Units are in docs/benchmark.md. Every row describes the frame that was
## just completed: pose = what was rendered, frame_time_ms = its duration, counters = its render stats.
const COLUMNS: PackedStringArray = [
	"frame", "t_s", "path_distance_m", "cam_x", "cam_y", "cam_z", "cam_yaw_deg",
	"frame_time_ms", "fps_instant", "process_ms_1hz", "physics_ms_1hz", "render_cpu_ms", "render_gpu_ms",
	"draw_calls", "draw_calls_visible", "primitives", "primitives_visible", "objects", "video_mem_mb",
	"lod_switches", "lod_bias", "lod_update_ms", "trees_lod0", "trees_lod1", "trees_lod2",
	"grass_clumps_t0", "grass_clumps_t1", "grass_clumps_t2", "grass_switches", "grass_update_ms",
	"bush_drawn", "bush_switches", "bush_update_ms", "debris_drawn", "debris_switches", "debris_update_ms",
	"rocks_instances", "lod_total_update_ms",
	"lod_policies_updated", "ctrl_signal", "ctrl_signal_ms", "ctrl_raw_ms", "ctrl_target_ms", "ctrl_error",
	"ctrl_p_term", "ctrl_i_term", "ctrl_update_ms",
]
const STARTUP_FRAMES := 3
const PROGRESS_INTERVAL_S := 10.0

var _config: RefCounted
var _path: RefCounted
var _sampler: RefCounted
var _csv: RefCounted
var _phase: Phase = Phase.STARTUP
var _frames_in_phase: int = 0
var _phase_start_us: int = 0
var _prev_tick_us: int = 0
var _prev_distance: float = 0.0
var _prev_pose: Transform3D
var _measured_rows: Array = []
var _next_progress_s: float = PROGRESS_INTERVAL_S
var _start_unix: float = 0.0
var _scene_info: Dictionary = {}
var _display_info: Dictionary = {}
var _aborted: bool = false
var _manager: Node
var _lod: Node  # tree policy
var _grass: Node
var _bush: Node
var _debris: Node
var _adaptive: Node
var _updates_seen: Dictionary = {}
var _init_costs: Dictionary = {}
var _measure_start: Dictionary = {}
var _display_at_end: Dictionary = {}
var _verify_start: Dictionary = {}
var _tree_instances: int = 0
var _debug_panel_removed: bool = false

@onready var _environment: Node = $Environment
@onready var _camera: Camera3D = $BenchmarkCamera


func _ready() -> void:
	process_priority = -100
	_config = BenchmarkConfig.from_args(OS.get_cmdline_user_args())
	if not _config.errors.is_empty():
		_fail("invalid configuration: %s" % ", ".join(_config.errors), 2)
		return
	seed(_config.seed_value)
	_display_info = _apply_display_settings()

	var terrain := _environment.get_node_or_null("Terrain3D") as Terrain3D
	if terrain == null:
		_fail("Environment has no Terrain3D node", 3)
		return
	_isolate_from_player()
	if not _setup_lod():
		return

	_path = CameraPath.new()
	var path_error: String = _path.build(terrain, _config.eye_height_m, _config.pitch_deg)
	if not path_error.is_empty():
		_fail("camera path: %s" % path_error, 3)
		return
	_camera.fov = _config.fov_deg
	_camera.far = 3000.0
	_camera.make_current()
	terrain.set_camera(_camera)
	_apply_pose(0.0)

	_sampler = MetricsSampler.new()
	_sampler.start(get_viewport())
	_csv = CsvLogger.new(COLUMNS)
	_scene_info = _scene_fingerprint(terrain)
	_start_unix = Time.get_unix_time_from_system()
	print("[bench] label=%s lod_mode=%s seed=%d world_seed=%s" % [
			_config.label, _config.lod_mode, _config.seed_value, _scene_info.get("world_seed")])
	print("[bench] path length=%.1f m points=%d ground=%.1f..%.1f m sha256=%s" % [
			_path.length, _path.point_count(), _path.ground_min, _path.ground_max, _path.sha256.substr(0, 16)])
	if _config.lod_mode == "adaptive":
		print("[bench] adaptive: target=%.2f ms signal=%s kp=%.2f ki=%.2f bias=[%.2f,%.2f] ctrl interval=%.2f s policy interval=%.2f s" % [
				_config.target_ms, _config.signal_source, _config.kp, _config.ki, _config.bias_min, _config.bias_max,
				_config.controller_interval_s, _config.policy_interval_s])
	print("[bench] window=%s vsync=%s max_fps=%d renderer=%s/%s adapter=%s" % [
			_display_info["window_size"], _config.vsync, _config.max_fps,
			_display_info["rendering_method"], _display_info["rendering_driver"], _display_info["adapter"]])
	print("[bench] warm-up %.0f s, settle %d frames, measure %.0f s at %.1f m/s" % [
			_config.warmup_s, _config.settle_frames, _config.duration_s, _config.speed_mps])


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if _phase != Phase.DONE:
			_aborted = true
			_finish()


func _process(_delta: float) -> void:
	if _phase == Phase.DONE or _config == null or not _config.errors.is_empty():
		return
	var now := Time.get_ticks_usec()
	_frames_in_phase += 1
	match _phase:
		Phase.STARTUP:
			if _frames_in_phase >= STARTUP_FRAMES:
				_enter_phase(Phase.WARMUP, now)
		Phase.WARMUP:
			var elapsed := (now - _phase_start_us) / 1000000.0
			_apply_pose(elapsed * _config.speed_mps)
			if elapsed >= _config.warmup_s:
				_apply_pose(0.0)
				_enter_phase(Phase.SETTLE, now)
				_reset_lod_state()  # same LOD state at the path start in every run, whatever the warm-up did
		Phase.SETTLE:
			if _frames_in_phase == 3:
				for p in _manager.policies():
					_verify_start[p.category()] = p.verify() if p.enabled and p.is_built() else "not active"
			if _frames_in_phase > _config.settle_frames:
				_enter_phase(Phase.MEASURE, now)
				_begin_measurement()
				_prev_tick_us = now
				_prev_distance = 0.0
				_prev_pose = _camera.global_transform
		Phase.MEASURE:
			_measure_frame(now)


func _enter_phase(phase: Phase, now: int) -> void:
	_phase = phase
	_frames_in_phase = 0
	_phase_start_us = now


func _measure_frame(now: int) -> void:
	var elapsed_s := (now - _phase_start_us) / 1000000.0
	var frame_us := now - _prev_tick_us
	var counters: Dictionary = _sampler.sample()
	var euler := _prev_pose.basis.get_euler(EULER_ORDER_YXZ)
	var row: Array = [
		_measured_rows.size(), elapsed_s, _prev_distance,
		_prev_pose.origin.x, _prev_pose.origin.y, _prev_pose.origin.z, rad_to_deg(euler.y),
		frame_us / 1000.0, 1000000.0 / frame_us if frame_us > 0 else null,
		counters["process_ms_1hz"], counters["physics_ms_1hz"], counters["render_cpu_ms"], counters["render_gpu_ms"],
		counters["draw_calls"], counters["draw_calls_visible"], counters["primitives"],
		counters["primitives_visible"], counters["objects"], counters["video_mem_mb"],
	] + _lod_columns() + _grass_columns() + _object_columns() + _controller_columns()
	_csv.add_row(row)
	_measured_rows.append(row)
	_prev_tick_us = now
	if elapsed_s >= _config.duration_s:
		_finish()
		return
	if elapsed_s >= _next_progress_s:
		_next_progress_s += PROGRESS_INTERVAL_S
		print("[bench] %.0f / %.0f s, %d frames" % [elapsed_s, _config.duration_s, _measured_rows.size()])
	_prev_distance = elapsed_s * _config.speed_mps
	_apply_pose(_prev_distance)
	_prev_pose = _camera.global_transform


## Picks the LOD mode of the instanced environment through its LodManager: "none" disables every category
## policy (baked scene, grass at full detail), "baseline" enables the policies of --bench-lod-categories.
func _setup_lod() -> bool:
	_manager = _environment.get_node_or_null("LodManager")
	if _manager == null:
		_fail("the environment has no LodManager node", 3)
		return false
	_lod = _manager.policy("trees")
	_grass = _manager.policy("grass")
	_bush = _manager.policy("bushes")
	_debris = _manager.policy("debris")
	if _lod == null or _grass == null or _bush == null or _debris == null:
		_fail("the environment is missing a category LOD policy (%s)" % _manager.categories(), 3)
		return false
	_adaptive = _manager.adaptive()
	if _config.lod_mode == "adaptive" and _adaptive == null:
		_fail("the environment has no AdaptiveLod node", 3)
		return false
	var wanted: PackedStringArray = _config.lod_categories if _config.lod_mode != "none" else PackedStringArray()
	_manager.set_categories(wanted)
	_grass.style = 1 if _config.grass_style == "v2" else 0
	if _config.lod_mode == "adaptive":
		_configure_adaptive()
		_adaptive.activate()
	return true


## Copies the controller settings of the run into the AdaptiveLod node. The benchmark's sampler already measures
## GPU render time, so the controller does not manage that itself.
func _configure_adaptive() -> void:
	_adaptive.target_ms = _config.target_ms
	_adaptive.signal_source = _config.signal_source
	_adaptive.kp = _config.kp
	_adaptive.ki = _config.ki
	_adaptive.bias_min = _config.bias_min
	_adaptive.bias_max = _config.bias_max
	_adaptive.update_interval_s = _config.controller_interval_s
	_adaptive.smoothing_s = _config.smoothing_s
	_adaptive.max_rise_per_update = _config.max_rise
	_adaptive.max_fall_per_update = _config.max_fall
	_adaptive.policy_update_interval_s = _config.policy_interval_s
	_adaptive.manage_measurement = false
	if _config.switch_budget >= 0:
		var budgets := {}
		for category in _manager.categories():
			budgets[category] = _config.switch_budget
		_adaptive.max_changes_per_update = budgets


func _adaptive_active() -> bool:
	return _adaptive != null and _adaptive.is_active() and _config.lod_mode == "adaptive"


## Warm-up -> settle: controller back to bias 0 and held, every category resynced from the path start. The time the
## resync takes is recorded per category (initialisation, not steady-state cost).
func _reset_lod_state() -> void:
	if _adaptive_active():
		_adaptive.hold = true
		_adaptive.reset()
	for p in _manager.policies():
		if p.enabled:
			var started := Time.get_ticks_usec()
			p.resync()
			_init_costs[p.category()] = {"resync_ms": (Time.get_ticks_usec() - started) / 1000.0}


## Settle -> measure: the controller starts the measured run from its reset state, and the counters reported for the
## measured window are taken relative to now.
func _begin_measurement() -> void:
	if _adaptive_active():
		_adaptive.reset()
		_adaptive.hold = false
	for p in _manager.policies():
		_updates_seen[p.category()] = p.updates_run
		_measure_start[p.category()] = {"updates_run": p.updates_run, "total_update_ms": p.total_update_ms}


func _lod_active() -> bool:
	return _lod != null and _lod.enabled


## Grass tiers only exist for the v2 field; legacy grass has no policy to run.
func _grass_lod_active() -> bool:
	return _grass != null and _grass.enabled and _config.grass_style == "v2"


## grass_clumps_t0..t2 (clumps drawn at each tier; legacy tufts count as t0), grass_switches (cells that
## changed tier in the previous frame's update), grass_update_ms (empty unless grass LOD is on).
func _grass_columns() -> Array:
	var clumps: PackedInt32Array = _grass.tier_clump_counts()
	if _grass_lod_active():
		return [clumps[0], clumps[1], clumps[2], _grass.frame_switches, _grass.last_update_ms]
	return [clumps[0], clumps[1], clumps[2], 0, null]


## bush_drawn / debris_drawn (instances drawn), *_switches (chunks that changed density tier in the previous frame's
## update, 0 when the policy is off), *_update_ms (empty when off), rocks_instances (constant: no rock LOD exists),
## lod_total_update_ms (sum of the update costs of all active policies; empty when none is active).
func _object_columns() -> Array:
	var total_ms := 0.0
	var any := false
	for p in _manager.policies():
		if p.enabled and p.is_built() and (p != _grass or _grass_lod_active()):
			total_ms += p.last_update_ms
			any = true
	return [
		_bush.instance_drawn(), _bush.frame_switches if _bush.enabled else 0, _bush.last_update_ms if _bush.enabled else null,
		_debris.instance_drawn(), _debris.frame_switches if _debris.enabled else 0, _debris.last_update_ms if _debris.enabled else null,
		_manager.rock_instances(), total_ms if any else null,
	]


## lod_switches (instances that changed level in the previous frame's update), lod_bias, lod_update_ms
## (CPU time of that update), trees at each level. "none": no controller exists, so zero switches, no
## update time (empty) and every tree stays at the baked level. lod_bias is the global controller bias in adaptive mode and empty otherwise. Level counts are read before this frame's update,
## so they match the frame the row describes.
func _lod_columns() -> Array:
	var counts := PackedInt32Array([0, 0, 0])
	if _lod_active():
		counts = _lod.level_counts()
		if counts.is_empty():
			return [0, null, null, null, null, null]
		return [_lod.frame_switches, _adaptive.bias if _adaptive_active() else null, _lod.last_update_ms, counts[0], counts[1], counts[2]]
	var baked_level := clampi(int(_scene_info.get("tree_lod_level", 0)), 0, 2)
	counts[baked_level] = _tree_instances
	return [0, null, null, counts[0], counts[1], counts[2]]


## lod_policies_updated (policies that ran an update since the previous row), then the controller columns:
## signal name, smoothed and raw signal, target, relative error, P and I terms (bias units), controller CPU ms.
## All empty unless the run is adaptive; the signal fields are also empty while the signal is unavailable.
func _controller_columns() -> Array:
	var updated := 0
	for p in _manager.policies():
		var now: int = p.updates_run
		if now != int(_updates_seen.get(p.category(), now)):
			updated += 1
		_updates_seen[p.category()] = now
	if not _adaptive_active():
		return [updated, null, null, null, null, null, null, null, null]
	var state: Dictionary = _adaptive.state()
	var has_signal: bool = state["signal_available"]
	return [
		updated, state["signal"] if has_signal else null, state["signal_ms"] if has_signal else null,
		state["raw_ms"] if has_signal else null, state["target_ms"], state["error"] if has_signal else null,
		state["p_term"] if has_signal else null, state["i_term"], _adaptive.last_update_ms,
	]


func _apply_pose(distance: float) -> void:
	_camera.global_transform = _path.sample(distance)


func _finish() -> void:
	_phase = Phase.DONE
	var measured_s := 0.0
	if not _measured_rows.is_empty():
		measured_s = (_measured_rows[_measured_rows.size() - 1] as Array)[1]
	_sampler.stop()
	_display_at_end = _display_state()
	var summary := BenchmarkSummary.summarize(COLUMNS, _measured_rows, measured_s)

	var directory := _output_directory()
	var stamp := Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "-")
	var base := directory.path_join("%s_%s" % [_config.label, stamp])
	var csv_error: int = _csv.save(base + ".csv")
	var meta := {
		"csv_schema_version": CSV_SCHEMA_VERSION,
		"completed": not _aborted,
		"aborted": _aborted,
		"started_unix": _start_unix,
		"config": _config.to_dict(),
		"lod": _lod_meta(),
		"grass": _grass_meta(),
		"categories": _categories_meta(),
		"terrain3d": _terrain_meta(),
		"adaptive": _adaptive_meta(),
		"debug_panel_removed": _debug_panel_removed,
		"display": _display_info,
		"display_at_end": _display_at_end,
		"engine": _engine_info(),
		"scene": _scene_info,
		"camera_path": {
			"length_m": _path.length, "points": _path.point_count(), "sha256": _path.sha256,
			"ground_min_m": _path.ground_min, "ground_max_m": _path.ground_max,
			"waypoints": Array(CameraPath.WAYPOINTS).map(func(p: Vector2) -> Array: return [p.x, p.y]),
		},
		"csv": base.get_file() + ".csv",
		"csv_rows": _csv.row_count(),
		"summary": summary,
	}
	var json_file := FileAccess.open(base + ".json", FileAccess.WRITE)
	if json_file != null:
		json_file.store_string(JSON.stringify(meta, "\t", false) + "\n")
		json_file.close()

	var frame_time: Dictionary = summary["columns"]["frame_time_ms"]
	print("[bench] %s: %d frames in %.1f s, avg %.1f fps" % [
			"ABORTED" if _aborted else "done", summary["frames"], measured_s,
			summary["avg_fps"] if summary["avg_fps"] != null else 0.0])
	if frame_time["available"]:
		print("[bench] frame time ms: mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f" % [
				frame_time["mean"], frame_time["p50"], frame_time["p95"], frame_time["p99"], frame_time["max"]])
	for name in ["render_gpu_ms", "render_cpu_ms", "draw_calls", "primitives"]:
		var stat: Dictionary = summary["columns"][name]
		print("[bench] %s: %s" % [name, "mean %.2f" % stat["mean"] if stat["available"] else "UNAVAILABLE"])
	for category in meta["categories"]:
		var info: Dictionary = meta["categories"][category]
		if info.get("enabled", false):
			print("[bench] lod %s: %d %s switches, integrity after resync: %s, at end: %s" % [
					category, info["total_switches_in_measured_run"], info["switch_unit"],
					"ok" if str(info["integrity_check_after_resync"]).is_empty() else info["integrity_check_after_resync"],
					"ok" if info["integrity_check_at_end"].is_empty() else info["integrity_check_at_end"]])
	if not _display_at_end.get("window_matches_request", true):
		print("[bench] WARNING: window is %s, not the requested %s" % [_display_at_end["window_size"], _display_at_end["requested_size"]])
	if _config.lod_mode == "adaptive":
		var stats: Dictionary = _adaptive.run_stats()
		print("[bench] adaptive: signal=%s final bias %.3f, %d PI steps, %d reversals, %d frames at max bias, %d frames without signal" % [
				_adaptive.signal_name, stats["final_bias"], stats["pi_steps"], stats["bias_reversals"],
				stats["frames_at_bias_max"], stats["unavailable_signal_frames"]])
	print("[bench] wrote %s.csv and .json (csv error=%s)" % [base, error_string(csv_error)])
	if _config.quit_when_done:
		get_tree().quit(0 if csv_error == OK and not _aborted else 1)


func _grass_meta() -> Dictionary:
	if _grass == null:
		return {"style": "legacy", "note": "no GrassLod node"}
	var meta: Dictionary = _grass.describe()
	meta["integrity_check_after_resync"] = _verify_start.get("grass", "not run")
	meta["integrity_check_at_end"] = _grass.verify()
	meta["total_switches_in_measured_run"] = int(_sum_column("grass_switches"))
	return meta


func _lod_meta() -> Dictionary:
	var meta := {"mode": _config.lod_mode}
	if _lod_active():
		meta.merge(_lod.describe())
		meta["integrity_check_after_resync"] = _verify_start.get("trees", "not run")
		meta["integrity_check_at_end"] = _lod.verify()
		meta["total_switches_in_measured_run"] = int(_sum_column("lod_switches"))
	return meta


## Per category: whether its policy ran, its settings, instance counts, switches in the measured run and integrity checks.
## Rocks are listed with their instance count only (no LOD exists for them).
func _categories_meta() -> Dictionary:
	var result := {}
	var switch_columns := {"trees": "lod_switches", "grass": "grass_switches", "bushes": "bush_switches", "debris": "debris_switches"}
	for p in _manager.policies():
		var category: String = p.category()
		var active: bool = p.enabled and p.is_built() and (p != _grass or _grass_lod_active())
		var info: Dictionary = {
			"enabled": active, "switch_unit": p.switch_unit(), "instances": p.instance_total(),
			"settings": p.describe(),
			"integrity_check_after_resync": _verify_start.get(category, "not run"),
			"integrity_check_at_end": p.verify() if active else "",
			"total_switches_in_measured_run": int(_sum_column(switch_columns[category])) if active else 0,
			# Initialisation is reported apart from the steady-state update cost: build_ms is the one-time build on the
			# first enabled frame (warm-up, outside the measured window), resync_ms the quiet resync at the path start.
			"initialization": {"build_ms": p.build_ms if p.is_built() else null, "resync_ms": _init_costs.get(category, {}).get("resync_ms")},
			"updates": _update_stats(p) if active else {},
		}
		if p == _grass:
			info["style"] = _config.grass_style
		result[category] = info
	result["rocks"] = {"enabled": false, "instances": _manager.rock_instances(), "note": "metrics only, no rock LOD"}
	return result


## Terrain3D's own LOD and collision settings. They are recorded, never changed: terrain LOD is independent of
## the object policies above. Only properties the loaded Terrain3D build actually has are listed.
## Update runs and CPU cost of one policy inside the measured window (frames skipped by the schedule cost nothing).
func _update_stats(p: Node) -> Dictionary:
	var start: Dictionary = _measure_start.get(p.category(), {"updates_run": 0, "total_update_ms": 0.0})
	var runs: int = p.updates_run - int(start["updates_run"])
	var total_ms: float = p.total_update_ms - float(start["total_update_ms"])
	return {
		"updates_run": runs, "total_update_ms": total_ms, "mean_ms_per_update": total_ms / maxf(runs, 1),
		"mean_ms_per_frame": total_ms / maxf(_measured_rows.size(), 1),
		"schedule_interval_s": p.update_interval_s, "min_camera_move_m": p.min_camera_move,
		"max_changes_per_update": p.max_changes_per_update,
	}


## Controller settings and what happened in the measured run (empty unless the run is adaptive).
func _adaptive_meta() -> Dictionary:
	if _config.lod_mode != "adaptive" or _adaptive == null:
		return {"used": false}
	var result: Dictionary = _adaptive.describe()
	result["used"] = true
	result["signal_in_use"] = _adaptive.signal_name
	result["run"] = _adaptive.run_stats()
	result["bias_applied_by_category"] = {}
	for p in _manager.policies():
		result["bias_applied_by_category"][p.category()] = p.lod_bias
	result["frames_with_signal"] = int(_summary_samples("ctrl_signal_ms"))
	result["measured_frames"] = _measured_rows.size()
	return result


func _summary_samples(column: String) -> int:
	var index := COLUMNS.find(column)
	var count := 0
	for row in _measured_rows:
		if row[index] != null:
			count += 1
	return count


## Window and rendering state read back from the engine, to confirm the requested setup was really applied.
func _display_state() -> Dictionary:
	var window := get_window()
	var viewport := get_viewport()
	var requested := Vector2i(_config.width, _config.height)
	return {
		"window_size": window.size, "viewport_size": viewport.size, "requested_size": requested,
		"window_matches_request": window.size == requested,
		"vsync_mode": DisplayServer.window_get_vsync_mode(), "max_fps": Engine.max_fps,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"screen_size": DisplayServer.screen_get_size(),
	}


func _terrain_meta() -> Dictionary:
	var terrain := _environment.get_node_or_null("Terrain3D")
	var result := {}
	if terrain == null:
		return result
	for name in ["mesh_lods", "mesh_size", "vertex_spacing", "region_size", "collision_mode", "collision_radius",
			"collision_shape_size", "collision_priority", "cull_margin", "gi_mode", "cast_shadows"]:
		if name in terrain:
			result[name] = terrain.get(name)
	var material: Variant = terrain.get("material")
	if material != null:
		result["world_background"] = material.get("world_background")
	result["version"] = str(terrain.get("version")) if "version" in terrain else "unknown"
	result["lod_changed_by_benchmark"] = false
	return result


func _sum_column(name: String) -> float:
	var index := COLUMNS.find(name)
	var total := 0.0
	for row in _measured_rows:
		if row[index] != null:
			total += float(row[index])
	return total


func _fail(message: String, exit_code: int) -> void:
	_phase = Phase.DONE
	push_error("[bench] %s" % message)
	print("[bench] FAILED: %s" % message)
	get_tree().quit(exit_code)


## Disables everything interactive in the instanced environment scene so the run depends on no input.
func _isolate_from_player() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_environment.set_process_unhandled_input(false)  # F1 free-fly toggle
	var debug_panel := _environment.get_node_or_null("LodDebugPanel")  # F3/F4 UI must not touch benchmark runs
	if debug_panel != null:
		_environment.remove_child(debug_panel)
		debug_panel.free()
		_debug_panel_removed = true
	var player := _environment.get_node_or_null("Player") as Node3D
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
		player.visible = false
	var fly := _environment.get_node_or_null("Camera3D") as Camera3D
	if fly != null:
		fly.set_process(false)
		fly.set_process_unhandled_input(false)


func _apply_display_settings() -> Dictionary:
	var window := get_window()
	window.mode = Window.MODE_WINDOWED
	window.size = Vector2i(_config.width, _config.height)
	var vsync_modes := {
		"off": DisplayServer.VSYNC_DISABLED, "on": DisplayServer.VSYNC_ENABLED,
		"adaptive": DisplayServer.VSYNC_ADAPTIVE, "mailbox": DisplayServer.VSYNC_MAILBOX,
	}
	DisplayServer.window_set_vsync_mode(vsync_modes[_config.vsync])
	Engine.max_fps = _config.max_fps
	var viewport := get_viewport()
	return {
		"window_size": window.size,
		"window_matches_request": window.size == Vector2i(_config.width, _config.height),
		# The 3D scene renders at window size (stretch mode canvas_items only scales the 2D canvas).
		"render_size_3d": Vector2i(Vector2(window.size) * viewport.scaling_3d_scale),
		"canvas_logical_size": viewport.get_visible_rect().size,
		"vsync_applied": DisplayServer.window_get_vsync_mode(),
		"max_fps_applied": Engine.max_fps,
		"screen_refresh_hz": DisplayServer.screen_get_refresh_rate(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"msaa_3d": viewport.msaa_3d,
		"screen_space_aa": viewport.screen_space_aa,
		"taa": viewport.use_taa,
		"scaling_3d_mode": viewport.scaling_3d_mode,
		"scaling_3d_scale": viewport.scaling_3d_scale,
	}


func _engine_info() -> Dictionary:
	return {
		"godot_version": Engine.get_version_info()["string"],
		"debug_build": OS.is_debug_build(),
		"editor_build": OS.has_feature("editor"),
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"cpu_threads": OS.get_processor_count(),
	}


## Counts what the benchmark is rendering, so two runs can be checked for the same content.
func _scene_fingerprint(terrain: Terrain3D) -> Dictionary:
	var chunks := 0
	var nodes := 0
	var instances := 0
	_tree_instances = 0
	var vegetation := _environment.get_node_or_null("Vegetation")
	if vegetation != null:
		for chunk in vegetation.get_children():
			chunks += 1
			for child in chunk.get_children():
				var multimesh_node := child as MultiMeshInstance3D
				if multimesh_node != null and multimesh_node.multimesh != null:
					nodes += 1
					instances += multimesh_node.multimesh.instance_count
					if multimesh_node.get_meta("vegetation_kind", "") == "tree":
						_tree_instances += multimesh_node.multimesh.instance_count
	return {
		"scene": _environment.scene_file_path,
		"world_seed": _environment.get("world_seed"),
		"tree_lod_level": _environment.get("tree_lod_level"),
		"terrain_regions": terrain.data.get_region_count(),
		"vegetation_chunks": chunks,
		"vegetation_multimesh_nodes": nodes,
		"vegetation_instances": instances,
		"tree_instances": _tree_instances,
		"instances_by_kind": VegetationCounts.count(vegetation),
		"grass_field_cells": _environment.get_node("GrassField").get_child_count() if _environment.has_node("GrassField") else 0,
	}


func _output_directory() -> String:
	var directory: String = _config.out_dir
	if directory.is_empty():
		directory = "res://results" if OS.has_feature("editor") else "user://results"
	directory = ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		directory = ProjectSettings.globalize_path("user://results")
		DirAccess.make_dir_recursive_absolute(directory)
	return directory
