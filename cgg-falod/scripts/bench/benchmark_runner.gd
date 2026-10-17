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

enum Phase { STARTUP, WARMUP, SETTLE, MEASURE, DONE }

## One row per measured frame. Units are in docs/benchmark.md. Every row describes the frame that was
## just completed: pose = what was rendered, frame_time_ms = its duration, counters = its render stats.
const COLUMNS: PackedStringArray = [
	"frame", "t_s", "path_distance_m", "cam_x", "cam_y", "cam_z", "cam_yaw_deg",
	"frame_time_ms", "fps_instant", "process_ms_1hz", "physics_ms_1hz", "render_cpu_ms", "render_gpu_ms",
	"draw_calls", "draw_calls_visible", "primitives", "primitives_visible", "objects", "video_mem_mb",
	"lod_switches", "lod_bias", "lod_update_ms", "trees_lod0", "trees_lod1", "trees_lod2",
	"grass_clumps_t0", "grass_clumps_t1", "grass_clumps_t2", "grass_switches", "grass_update_ms",
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
var _lod: Node
var _grass: Node
var _grass_verify_start: String = "not run"
var _lod_verify_start: String = "not run"
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
	if not _setup_grass():
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
				if _lod_active():
					_lod.resync()  # same LOD state at the path start in every run, whatever the warm-up did
				if _grass_lod_active():
					_grass.resync()
		Phase.SETTLE:
			if _frames_in_phase == 3 and _lod_active():
				_lod_verify_start = _lod.verify()
			if _frames_in_phase == 3 and _grass != null:
				_grass_verify_start = _grass.verify()
			if _frames_in_phase > _config.settle_frames:
				_enter_phase(Phase.MEASURE, now)
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
	] + _lod_columns() + _grass_columns()
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


## Picks the vegetation LOD mode of the instanced environment: "none" leaves the baked scene untouched.
func _setup_lod() -> bool:
	_lod = _environment.get_node_or_null("VegetationLod")
	if _config.lod_mode == "baseline":
		if _lod == null:
			_fail("lod_mode=baseline but the environment has no VegetationLod node", 3)
			return false
		_lod.enabled = true
	elif _lod != null:
		_lod.enabled = false
	return true


func _lod_active() -> bool:
	return _config.lod_mode == "baseline" and _lod != null


## Applies --bench-grass / --bench-grass-lod to the environment's GrassLod node.
func _setup_grass() -> bool:
	_grass = _environment.get_node_or_null("GrassLod")
	if _grass == null:
		if _config.grass_style == "v2":
			_fail("grass=v2 but the environment has no GrassLod node", 3)
			return false
		return true
	_grass.style = 1 if _config.grass_style == "v2" else 0
	_grass.lod_enabled = _config.grass_lod == "distance"
	return true


func _grass_lod_active() -> bool:
	return _grass != null and _config.grass_style == "v2" and _config.grass_lod == "distance"


## grass_clumps_t0..t2 (clumps drawn at each tier; legacy tufts count as t0), grass_switches (cells that
## changed tier in the previous frame's update), grass_update_ms (empty unless grass LOD is on).
func _grass_columns() -> Array:
	if _grass == null:
		return [null, null, null, null, null]
	var clumps: PackedInt32Array = _grass.tier_clump_counts()
	if _grass_lod_active():
		return [clumps[0], clumps[1], clumps[2], _grass.frame_switches, _grass.last_update_ms]
	return [clumps[0], clumps[1], clumps[2], 0, null]


## lod_switches (instances that changed level in the previous frame's update), lod_bias, lod_update_ms
## (CPU time of that update), trees at each level. "none": no controller exists, so zero switches, no
## update time (empty) and every tree stays at the baked level. lod_bias is empty in both modes. Level counts are read before this frame's update,
## so they match the frame the row describes.
func _lod_columns() -> Array:
	var counts := PackedInt32Array([0, 0, 0])
	if _lod_active():
		counts = _lod.level_counts()
		if counts.is_empty():
			return [0, null, null, null, null, null]
		return [_lod.frame_switches, null, _lod.last_update_ms, counts[0], counts[1], counts[2]]
	var baked_level := clampi(int(_scene_info.get("tree_lod_level", 0)), 0, 2)
	counts[baked_level] = _tree_instances
	return [0, null, null, counts[0], counts[1], counts[2]]


func _apply_pose(distance: float) -> void:
	_camera.global_transform = _path.sample(distance)


func _finish() -> void:
	_phase = Phase.DONE
	var measured_s := 0.0
	if not _measured_rows.is_empty():
		measured_s = (_measured_rows[_measured_rows.size() - 1] as Array)[1]
	_sampler.stop()
	var summary := BenchmarkSummary.summarize(COLUMNS, _measured_rows, measured_s)

	var directory := _output_directory()
	var stamp := Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "-")
	var base := directory.path_join("%s_%s" % [_config.label, stamp])
	var csv_error: int = _csv.save(base + ".csv")
	var meta := {
		"completed": not _aborted,
		"aborted": _aborted,
		"started_unix": _start_unix,
		"config": _config.to_dict(),
		"lod": _lod_meta(),
		"grass": _grass_meta(),
		"debug_panel_removed": _debug_panel_removed,
		"display": _display_info,
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
	if _lod_active():
		print("[bench] lod: %d switches, integrity after resync: %s, at end: %s" % [
				meta["lod"]["total_switches_in_measured_run"], _lod_verify_start if not _lod_verify_start.is_empty() else "ok",
				"ok" if meta["lod"]["integrity_check_at_end"].is_empty() else meta["lod"]["integrity_check_at_end"]])
	print("[bench] wrote %s.csv and .json (csv error=%s)" % [base, error_string(csv_error)])
	if _config.quit_when_done:
		get_tree().quit(0 if csv_error == OK and not _aborted else 1)


func _grass_meta() -> Dictionary:
	if _grass == null:
		return {"style": "legacy", "note": "no GrassLod node"}
	var meta: Dictionary = _grass.describe()
	meta["integrity_check_after_resync"] = _grass_verify_start
	meta["integrity_check_at_end"] = _grass.verify()
	meta["total_switches_in_measured_run"] = int(_sum_column("grass_switches"))
	return meta


func _lod_meta() -> Dictionary:
	var meta := {"mode": _config.lod_mode}
	if _lod_active():
		meta.merge(_lod.describe())
		meta["integrity_check_after_resync"] = _lod_verify_start
		meta["integrity_check_at_end"] = _lod.verify()
		meta["total_switches_in_measured_run"] = int(_sum_column("lod_switches"))
	return meta


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
