extends Node
## Scripted demonstration run for screen recording and screenshots. It is NOT a benchmark and writes no benchmark data.
## It shows the real scene on the benchmark camera path, switches the LOD mode by sending real F4 key events to the
## in-game LodDebugPanel (F4 toggles None <-> Adaptive), and keeps the panel visible so that mode, FPS, frame
## time, target, signal and bias are the live values of the running controller (the bias is never pinned or edited).
##
## Timeline (wall-clock seconds, see STEPS):
##   A. fixed viewpoint (path distance 0): None, Adaptive (controller starts from bias 0 and responds live)
##   B. the same 120 m path segment twice: None, then Adaptive (controller reset to bias 0 at the segment start)
## Screenshots (clean = no overlay, ui = with panel and labels) are taken near the end of the three fixed-view steps.
##
##   Godot_console.exe --path . res://scenes/demo.tscn -- --demo-out=<dir> [--demo-width=1920 --demo-height=1080]
## Writes <dir>/demo_timeline.json (per-second mode, bias, GPU and frame time as actually measured) and the screenshots.

const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const SPEED_MPS := 8.0
## Controller target used in the demo, ms: the project's stress-profile target. The 1080p default (16.67 ms) is never exceeded when the GPU is in its fast
## state (about 10 ms), so the controller would legitimately stay at bias 0 and there would be no response to show.
const DEMO_TARGET_MS := 8.0

## kind "fixed": camera held at path distance `from`. kind "path": camera moves from `from` to `to` metres at 8 m/s.
## f4: number of F4 presses on entry. shots: seconds into the step at which screenshots are taken.
const STEPS := [
	{"tag": "a_none", "title": "NONE", "sub": "no LOD: all vegetation at full detail", "kind": "fixed", "from": 0.0, "to": 0.0, "dur": 9.0, "f4": 0, "shots": [7.5], "first": true},
	{"tag": "a_adaptive", "title": "ADAPTIVE", "sub": "live PI controller, target 8 ms (stress-profile target), bias starts at 0", "kind": "fixed", "from": 0.0, "to": 0.0, "dur": 24.0, "f4": 1, "shots": [22.5]},
	{"tag": "b_none", "title": "NONE", "sub": "same 120 m path segment, no LOD", "kind": "path", "from": 0.0, "to": 120.0, "dur": 15.0, "f4": 1, "shots": []},
	{"tag": "b_adaptive", "title": "ADAPTIVE", "sub": "same 120 m path segment, controller reset to bias 0, target 8 ms", "kind": "path", "from": 0.0, "to": 120.0, "dur": 15.0, "f4": 1, "shots": []},
]
const START_DELAY_S := 3.0

var _out_dir: String = ""
var _width: int = 1920
var _height: int = 1080
var _path: RefCounted
var _camera: Camera3D
var _manager: Node
var _adaptive: Node
var _panel: Node
var _label_title: Label
var _label_sub: Label
var _label_gpu: Label
var _hud: CanvasLayer
var _step: int = -1
var _step_start_s: float = 0.0
var _clock_s: float = 0.0
var _next_sample_s: float = 0.0
var _shots_taken: int = 0
var _entering: bool = false
var _log: Array = []
var _steps_log: Array = []
var _gpu_ms: float = -1.0
var _frame_ms: float = 0.0
var _last_us: int = 0
var _done: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-out="):
			_out_dir = arg.substr(11)
		elif arg.begins_with("--demo-width="):
			_width = int(arg.substr(13))
		elif arg.begins_with("--demo-height="):
			_height = int(arg.substr(14))
	if _out_dir.is_empty():
		push_error("[demo] --demo-out=<dir> is required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out_dir)
	seed(1337)
	var window := get_window()
	window.mode = Window.MODE_WINDOWED
	window.borderless = true  # so a desktop capture of the window area contains no title bar
	window.size = Vector2i(_width, _height)
	window.position = Vector2i(0, 0)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

	var env := $Environment
	var terrain := env.get_node("Terrain3D") as Terrain3D
	env.set_process_unhandled_input(false)  # F1 free-fly toggle
	var player := env.get_node_or_null("Player") as Node3D
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
		player.visible = false
	var fly := env.get_node_or_null("Camera3D") as Camera3D
	if fly != null:
		fly.set_process(false)
		fly.set_process_unhandled_input(false)
	_manager = env.get_node("LodManager")
	_adaptive = env.get_node("AdaptiveLod")
	_panel = env.get_node("LodDebugPanel")
	_adaptive.manage_measurement = false  # this script owns GPU time measurement, like the benchmark sampler
	_adaptive.target_ms = DEMO_TARGET_MS
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	_path = CameraPath.new()
	var error: String = _path.build(terrain, 2.0, -6.0)  # same eye height and pitch as the benchmark
	if not error.is_empty():
		push_error("[demo] camera path: %s" % error)
		get_tree().quit(3)
		return
	_camera = $DemoCamera
	_camera.fov = 75.0
	_camera.far = 3000.0
	_camera.make_current()
	terrain.set_camera(_camera)
	_camera.global_transform = _path.sample(0.0)
	_build_hud()
	print("[demo] window %s, path sha256 %s, %d steps" % [window.size, _path.sha256.substr(0, 16), STEPS.size()])


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 90
	add_child(_hud)
	var box := VBoxContainer.new()
	# The 2D canvas is scaled from a logical size (1152x648 here) to the window, so position in logical units.
	box.position = Vector2(16, get_viewport().get_visible_rect().size.y - 118)
	_hud.add_child(box)
	_label_title = _make_label(34, Color(1, 1, 1))
	_label_sub = _make_label(15, Color(1, 1, 1, 0.95))
	_label_gpu = _make_label(15, Color(0.75, 0.95, 1.0))
	box.add_child(_label_title)
	box.add_child(_label_sub)
	box.add_child(_label_gpu)


func _make_label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("outline_size", 6)
	return label


func _process(_delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	var raw_ms := (now - _last_us) / 1000.0 if _last_us > 0 else 0.0
	_frame_ms = raw_ms if _frame_ms <= 0.0 else lerpf(_frame_ms, raw_ms, 0.05)  # smoothed for the on-screen text
	_last_us = now
	_clock_s += raw_ms / 1000.0
	var gpu: float = RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_gpu_ms = gpu if gpu > 0.0 else -1.0
	if _step < 0:
		if _clock_s >= START_DELAY_S:
			_begin_step(0)
		else:
			_label_title.text = "Starting"
			_label_sub.text = "scene loaded, recording should be running"
		return
	if _entering:
		return
	var step: Dictionary = STEPS[_step]
	var elapsed := _clock_s - _step_start_s
	if step["kind"] == "path":
		var distance: float = minf(float(step["from"]) + elapsed * SPEED_MPS, float(step["to"]))
		_camera.global_transform = _path.sample(distance)
	var bias: float = _adaptive.bias if _adaptive.is_active() else 0.0
	_label_gpu.text = ("GPU render time %.1f ms | frame %.1f ms | " % [_gpu_ms, _frame_ms]) + (
			"controller target %.1f ms, bias %.2f (live)" % [_adaptive.target_ms, bias] if _adaptive.is_active() else "controller off")
	if _clock_s >= _next_sample_s:
		_next_sample_s += 1.0
		_log.append({"t": snappedf(_clock_s, 0.01), "step": step["tag"], "mode": _manager.mode(), "bias": bias,
				"gpu_ms": _gpu_ms, "frame_ms": _frame_ms, "signal_ms": _adaptive.signal_ms if _adaptive.is_active() else null})
	var shots: Array = step["shots"]
	if _shots_taken < shots.size() and elapsed >= float(shots[_shots_taken]):
		_shots_taken += 1
		_take_shots(step["tag"])
	if elapsed >= float(step["dur"]):
		_steps_log.append({"tag": step["tag"], "mode_at_end": _manager.mode(), "end_clock_s": snappedf(_clock_s, 0.01),
				"final_bias": _adaptive.bias if _adaptive.is_active() else null})
		if _step + 1 < STEPS.size():
			_begin_step(_step + 1)
		else:
			_finish()


func _begin_step(index: int) -> void:
	_entering = true
	_step = index
	_shots_taken = 0
	var step: Dictionary = STEPS[index]
	_camera.global_transform = _path.sample(float(step["from"]))
	_label_title.text = step["title"]
	_label_sub.text = step["sub"]
	if step.get("first", false):
		_manager.set_mode("none")  # the scene starts in Baseline; start the demo from None, then F4 toggles None <-> Adaptive
		_panel._set_panel_visible(true)
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	for i in int(step["f4"]):
		_press_f4()
		await get_tree().process_frame
		await get_tree().process_frame
	_manager.resync_all()
	await get_tree().process_frame
	_step_start_s = _clock_s
	print("[demo] step %s: mode=%s at clock %.1f s" % [step["tag"], _manager.mode(), _clock_s])
	_entering = false


func _press_f4() -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_F4
		event.physical_keycode = KEY_F4
		event.pressed = pressed
		Input.parse_input_event(event)


func _take_shots(tag: String) -> void:
	# Clean frame (no overlay) first, then the frame as recorded (panel and labels visible).
	_panel._panel.visible = false
	_hud.visible = false
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/shot_%s_clean.png" % [_out_dir, tag])
	_panel._panel.visible = true
	_hud.visible = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/shot_%s_ui.png" % [_out_dir, tag])
	print("[demo] screenshots %s (mode %s, bias %.2f)" % [tag, _manager.mode(), _adaptive.bias if _adaptive.is_active() else 0.0])


func _finish() -> void:
	_done = true
	var report := {
		"purpose": "scripted demonstration, not a benchmark", "window": [_width, _height],
		"renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(), "path_sha256": _path.sha256,
		"controller_target_ms": _adaptive.target_ms, "target_note": "8 ms = project stress-profile target; the 1080p default 16.67 ms is not exceeded in the fast GPU state", "steps": _steps_log, "samples_1hz": _log,
		"note": "mode changes were made by F4 key events to the debug panel; the adaptive bias is the live controller output",
	}
	var file := FileAccess.open(_out_dir + "/demo_timeline.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t", false) + "\n")
		file.close()
	print("[demo] finished, %d steps, %d samples" % [_steps_log.size(), _log.size()])
	await get_tree().create_timer(1.5).timeout
	get_tree().quit(0)
