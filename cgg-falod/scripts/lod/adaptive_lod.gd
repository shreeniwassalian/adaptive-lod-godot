extends Node
## Adaptive mode: one PI controller (pi_controller.gd) that watches the rendering cost and sets a single LOD bias,
## which is handed to every enabled category policy of the LodManager. It owns no LOD data and creates no nodes;
## the baseline policies (trees, grass, bushes, debris) do the switching, now with thresholds scaled by the bias.
## Rocks have no policy and Terrain3D's own terrain LOD is never touched.
##
## Bias convention: bias > 0 = coarser, bias < 0 = finer, 0 = the baseline distances. A policy sees the distance
## `d * (1 + bias_c)` (trees use the equivalent shrunk thresholds, held above their minimum-detail floors, see
## baseline_lod.gd). Each category gets its own share of the global bias, which makes the adaptive budget a priority list:
##   bias_c = clamp((bias - onset_c) * gain_c, bias_min, cap_c)        for bias > 0 (finer biases pass through the gain)
## category_onset: the global bias at which the category starts to coarsen; category_weights: its gain;
## category_max: its own cap. The defaults spend the budget in this order: grass first (onset 0), distant trees next
## (onset 0.5, and the tree floors keep nearby trees at baseline detail), bushes and debris last and only mildly
## (onset 1.0, gain 0.5, cap 0.5: their measured GPU cost is negligible). This is category-level priority, not
## screen-space importance: the policies only see distances, so per-instance or screen-coverage importance would need
## new data (see docs/adaptive_lod.md); it is left out, not guessed.
##
## Signal (which timing feeds the controller, exposed as `signal_name`):
##   "gpu"   RenderingServer.viewport_get_measured_render_time_gpu of the main viewport (a few frames old; excludes
##           VSync waits, frame caps and present, so it is the cost the LOD can actually change).
##   "frame" total frame time (delta). Only valid when VSync is off and Engine.max_fps is 0; otherwise the frame
##           time includes waits that LOD cannot remove, so it is refused (signal unavailable) rather than used.
##   `signal_source` "auto" = gpu when the engine reports it, else frame when valid, else unavailable.
## While the signal is unavailable the bias is held (no integration) and `signal_available` is false.
## Each raw sample is clipped to spike_clip * target, then smoothed with an exponential moving average of time
## constant smoothing_s, so one hitch cannot move the bias; the PI step runs every update_interval_s.

const LodPolicy := preload("res://scripts/lod/lod_policy.gd")
const PiController := preload("res://scripts/lod/pi_controller.gd")

signal bias_changed(bias: float)

@export var manager_path: NodePath = ^"../LodManager"
@export var process_order: int = -60
@export_group("Target and signal")
## Rendering cost the controller tries to stay under, in milliseconds (16.67 = 60 fps).
@export var target_ms: float = 16.67
@export_enum("auto", "gpu", "frame") var signal_source: String = "auto"
## Time constant of the exponential smoothing of the signal, seconds.
@export var smoothing_s: float = 0.5
## A single sample is clipped to this multiple of the target before smoothing.
@export var spike_clip: float = 3.0
## Seconds between PI steps.
@export var update_interval_s: float = 0.25
## Samples ignored after (re)starting, frames.
@export var warmup_frames: int = 10
@export_group("PI gains")
@export var kp: float = 0.6
@export var ki: float = 0.4
@export var bias_min: float = 0.0
@export var bias_max: float = 2.0
@export var max_rise_per_update: float = 0.10
@export var max_fall_per_update: float = 0.03
@export var deadband: float = 0.03
@export_group("Importance and switching")
## Per-category share of the global bias: gain, onset and cap (see the header). Missing entries mean gain 1, onset 0,
## cap bias_max.
@export var category_weights := {"trees": 1.0, "grass": 1.0, "bushes": 0.5, "debris": 0.5}
@export var category_onset := {"trees": 0.5, "grass": 0.0, "bushes": 1.0, "debris": 1.0}
@export var category_max := {"trees": 1.0, "grass": 1.0, "bushes": 0.5, "debris": 0.5}
## Policy update period while adaptive (0 = every frame, as baseline).
@export var policy_update_interval_s: float = 0.1
## Policies skip an update when the camera moved less than this and nothing is pending (metres).
@export var policy_min_camera_move: float = 0.5
## Most units (instances / cells / chunks) a policy may switch per update; 0 = unlimited.
@export var max_changes_per_update := {"trees": 200, "grass": 30, "bushes": 20, "debris": 20}
## False when something else already enables GPU time measurement (the benchmark's sampler).
@export var manage_measurement: bool = true

var active: bool = false
## True when something else (the self-test) calls step() with its own samples; _process then does nothing.
var external_signal: bool = false
## Freezes the controller (it keeps its state and the applied bias) without deactivating it.
var hold: bool = false
var controller := PiController.new()
## Global bias (before the category weights).
var bias: float = 0.0
var signal_name: String = "none"
var signal_available: bool = false
var raw_ms: float = -1.0
var signal_ms: float = -1.0
## CPU time of this frame's controller work, milliseconds, and its running totals.
var last_update_ms: float = 0.0
var total_update_ms: float = 0.0
var update_frames: int = 0
var pi_steps: int = 0
var unavailable_frames: int = 0

var _manager: Node
var _frames_active: int = 0
var _accumulated: float = 0.0
var _smoothed_ready: bool = false
var _reversals: int = 0
var _last_direction: int = 0
var _frames_at_max: int = 0


func _ready() -> void:
	process_priority = process_order  # before the policies, so they use this frame's bias
	_manager = get_node_or_null(manager_path)
	_sync_controller()
	set_process(false)


func is_active() -> bool:
	return active


## Starts adaptive control: resets the controller, applies the scheduling limits to the policies and resyncs them.
func activate() -> void:
	if _manager == null:
		_manager = get_node_or_null(manager_path)
	_sync_controller()
	active = true
	hold = false
	if manage_measurement:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var index := 0
	for policy in _policies():
		policy.set_schedule(policy_update_interval_s, policy_min_camera_move, 0.25 * index)
		policy.max_changes_per_update = int(max_changes_per_update.get(policy.category(), 0))
		index += 1
	reset()
	for policy in _policies():
		policy.request_resync()
	set_process(true)


## Back to the baseline behaviour: bias 0, every policy updating each frame without limits, resynced quietly.
func deactivate() -> void:
	if not active:
		return
	active = false
	set_process(false)
	if manage_measurement:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
	bias = 0.0
	controller.reset(0.0)
	for policy in _policies():
		policy.set_lod_bias(0.0)
		policy.set_schedule(0.0, 0.0, 0.0)
		policy.max_changes_per_update = 0
		policy.request_resync()
	signal_available = false
	signal_name = "none"


## Clears the controller state (bias 0, integral 0, smoothing restarted) and applies bias 0 to the policies.
## The benchmark calls this before the measured run so every run starts from the same controller state.
func reset() -> void:
	_sync_controller()
	controller.reset(0.0)
	bias = 0.0
	signal_ms = -1.0
	raw_ms = -1.0
	signal_available = false
	_smoothed_ready = false
	_frames_active = 0
	_accumulated = 0.0
	_reversals = 0
	_last_direction = 0
	_frames_at_max = 0
	pi_steps = 0
	unavailable_frames = 0
	update_frames = 0
	total_update_ms = 0.0
	last_update_ms = 0.0
	_apply_bias()
	for policy in _policies():
		policy.reset_schedule()


func _process(delta: float) -> void:
	if not active or external_signal:
		return
	var sample := _read_signal(delta)
	step(sample, delta)


## One frame of control with an explicit sample (milliseconds, negative = unavailable). `_process` feeds the measured
## signal; the self-test feeds synthetic ones.
func step(sample_ms: float, delta: float) -> void:
	var started := Time.get_ticks_usec()
	_frames_active += 1
	if hold or _frames_active <= warmup_frames:
		last_update_ms = (Time.get_ticks_usec() - started) / 1000.0
		return
	if sample_ms > 0.0:
		raw_ms = sample_ms
		var clipped := minf(sample_ms, spike_clip * target_ms)
		if _smoothed_ready:
			signal_ms = lerpf(signal_ms, clipped, 1.0 - exp(-delta / maxf(smoothing_s, 0.001)))
		else:
			signal_ms = clipped
			_smoothed_ready = true
		signal_available = true
	else:
		raw_ms = -1.0
		signal_available = false
		unavailable_frames += 1
	_accumulated += delta
	if _accumulated >= update_interval_s:
		var dt := _accumulated
		_accumulated = 0.0
		if signal_available and _smoothed_ready:
			var previous := bias
			controller.update(signal_ms, target_ms, dt)
			bias = controller.bias
			pi_steps += 1
			var direction := signi(roundi((bias - previous) * 1000.0))
			if direction != 0:
				if _last_direction != 0 and direction != _last_direction:
					_reversals += 1
				_last_direction = direction
			if bias != previous:
				_apply_bias()
				bias_changed.emit(bias)
	if controller.saturation > 0:
		_frames_at_max += 1
	update_frames += 1
	last_update_ms = (Time.get_ticks_usec() - started) / 1000.0
	total_update_ms += last_update_ms


## Effective bias of one category: its share of the global bias, inside the category cap and the safety limits.
func category_bias(category: String) -> float:
	var gain := clampf(float(category_weights.get(category, 1.0)), 0.0, 2.0)
	var onset := maxf(float(category_onset.get(category, 0.0)), 0.0)
	var cap := minf(float(category_max.get(category, bias_max)), bias_max)
	var shifted := bias if bias <= 0.0 else maxf(bias - onset, 0.0)
	return clampf(shifted * gain, bias_min, cap)


func state() -> Dictionary:
	return {
		"active": active, "bias": bias, "signal": signal_name, "signal_available": signal_available,
		"signal_ms": signal_ms, "raw_ms": raw_ms, "target_ms": target_ms, "error": controller.error,
		"p_term": controller.p_term, "i_term": controller.integral, "saturation": controller.saturation,
	}


## Settings for the benchmark metadata.
func describe() -> Dictionary:
	var result := controller.describe()
	result.merge({
		"target_ms": target_ms, "signal_source": signal_source, "smoothing_s": smoothing_s, "spike_clip": spike_clip,
		"controller_update_interval_s": update_interval_s, "warmup_frames": warmup_frames,
		"category_weights": category_weights, "category_onset": category_onset, "category_max": category_max,
		"policy_update_interval_s": policy_update_interval_s,
		"policy_min_camera_move_m": policy_min_camera_move, "max_changes_per_update": max_changes_per_update,
		"importance": "category-level priority (onset, gain, cap); no per-instance or screen-coverage importance",
		"bias_convention": "bias > 0 = coarser; policies use distance * (1 + category_bias)",
	}, true)
	return result


## Run statistics for the benchmark metadata.
func run_stats() -> Dictionary:
	return {
		"pi_steps": pi_steps, "bias_reversals": _reversals, "frames_at_bias_max": _frames_at_max,
		"unavailable_signal_frames": unavailable_frames, "final_bias": bias,
		"mean_update_ms_per_frame": total_update_ms / maxf(update_frames, 1),
	}


func _sync_controller() -> void:
	controller.kp = kp
	controller.ki = ki
	controller.bias_min = bias_min
	controller.bias_max = bias_max
	controller.max_rise = max_rise_per_update
	controller.max_fall = max_fall_per_update
	controller.deadband = deadband


func _policies() -> Array[Node]:
	return _manager.policies() if _manager != null else ([] as Array[Node])


func _apply_bias() -> void:
	for policy in _policies():
		policy.set_lod_bias(category_bias(policy.category()))


## The measured timing for this frame in milliseconds, or -1 when the chosen signal is unavailable.
func _read_signal(delta: float) -> float:
	if signal_source != "frame":
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		if gpu > 0.0:
			signal_name = "gpu"
			return gpu
		if signal_source == "gpu":
			signal_name = "none"
			return -1.0
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED and Engine.max_fps == 0:
		signal_name = "frame"
		return delta * 1000.0
	signal_name = "none"
	return -1.0
