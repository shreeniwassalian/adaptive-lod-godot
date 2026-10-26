extends SceneTree
## Checks the adaptive (PI-controlled) LOD with synthetic timing, independent of GPU noise. Needs a real renderer:
##   Godot_console.exe --path . --script res://scripts/lod/adaptive_selftest.gd
##
## A. PiController alone against synthetic signals and a toy plant: direction, rate limits, saturation, anti-windup,
##    dead band, gradual recovery, reset and determinism.
## B. AdaptiveLod with the real environment, fed synthetic samples through step(): sustained pressure coarsens every
##    category, headroom recovers, spikes are rejected, an unavailable signal holds the bias, the mode switch resets,
##    category weights and clamps, change budgets and update scheduling, and that nothing is lost or duplicated.
## C. Benchmark configuration parsing for the new options.
## D. Debug panel: Adaptive button, F4 cycle, controller lines, "signal unavailable" warning.
## E. Measured costs (not pass/fail): initialisation (build) cost and steady-state update cost per category with the
##    baseline schedule and with the adaptive schedule, simulated at 60 fps along the benchmark path.
## These are synthetic controller tests; the real-rendering behaviour is measured by the benchmark (docs/adaptive_lod.md).

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const VEGETATION_SCENE := "res://scenes/generated/vegetation.scn"
const PiController := preload("res://scripts/lod/pi_controller.gd")
const LodPolicy := preload("res://scripts/lod/lod_policy.gd")
const BenchmarkConfig := preload("res://scripts/bench/benchmark_config.gd")
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const TERRAIN_PROPS := ["mesh_lods", "mesh_size", "vertex_spacing", "region_size", "collision_mode", "collision_radius", "collision_shape_size"]
const DT := 1.0 / 60.0

var _failures := 0
var _env: Node3D
var _terrain: Terrain3D
var _manager: Node
var _adaptive: Node
var _trees: Node
var _grass: Node
var _bush: Node
var _debris: Node
var _camera: Camera3D
var _baked_vegetation: Node
var _path: RefCounted
var _terrain_before := {}


func _initialize() -> void:
	_test_pi_controller()
	_test_config()
	_env = (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(_env)
	_terrain = _env.get_node("Terrain3D")
	_manager = _env.get_node("LodManager")
	_adaptive = _env.get_node("AdaptiveLod")
	for i in 6:
		await physics_frame
	_env.get_node("Player").process_mode = Node.PROCESS_MODE_DISABLED
	_env.get_node("Player").visible = false
	_camera = Camera3D.new()
	_camera.far = 3000.0
	root.add_child(_camera)
	_camera.make_current()
	_terrain.set_camera(_camera)
	_baked_vegetation = (load(VEGETATION_SCENE) as PackedScene).instantiate()
	_trees = _manager.policy("trees")
	_grass = _manager.policy("grass")
	_bush = _manager.policy("bushes")
	_debris = _manager.policy("debris")
	_path = CameraPath.new()
	_check(_path.build(_terrain, 2.0, -6.0).is_empty(), "setup: benchmark path builds")
	# The test steps the policies and the controller by hand at a simulated 60 fps.
	for node in [_trees, _grass, _bush, _debris]:
		node.set_process(false)
	_adaptive.external_signal = true
	_terrain_before = _terrain_settings()

	await _test_modes()
	await _test_pressure_and_recovery()
	await _test_spikes_and_unavailable()
	await _test_priority_and_clamps()
	await _test_tree_floor()
	await _test_hysteresis()
	await _test_transitions()
	await _test_budget_and_schedule()
	await _test_integrity()
	await _test_panel()
	await _report_costs()
	_baked_vegetation.free()
	print("[adaptive-test] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


# --- A. PiController

func _pi(kp := 0.6, ki := 0.4) -> RefCounted:
	var pi := PiController.new()
	pi.kp = kp
	pi.ki = ki
	pi.reset()
	return pi


func _test_pi_controller() -> void:
	# Direction: a slow frame raises the bias (coarser), never faster than max_rise per update.
	var pi := _pi()
	var previous: float = pi.bias
	var monotonic := true
	var step_ok := true
	for i in 12:
		pi.update(24.0, 16.67, 0.25)
		monotonic = monotonic and pi.bias >= previous
		step_ok = step_ok and pi.bias - previous <= pi.max_rise + 1e-9
		previous = pi.bias
	_check(pi.bias > 0.3 and monotonic, "pi: sustained overload raises the bias (%.3f)" % pi.bias)
	_check(step_ok, "pi: the bias rises by at most max_rise per update")

	# Saturation and anti-windup: an unreachable target pins the bias at bias_max and bounds the integral.
	for i in 400:
		pi.update(60.0, 8.0, 0.25)
	_check(pi.bias == pi.bias_max and pi.saturation == 1, "pi: unreachable target saturates at bias_max (%.3f)" % pi.bias)
	_check(pi.integral <= pi.bias_max + 1e-9, "pi: integral stays bounded while saturated (%.3f <= %.3f)" % [pi.integral, pi.bias_max])
	# Headroom after 100 s of saturation: the very next update already lowers the bias (no wound-up integral to unwind).
	pi.update(4.0, 16.67, 0.25)
	_check(pi.bias < pi.bias_max, "pi: anti-windup: first update after saturation already recovers (%.3f)" % pi.bias)
	var fall_ok := true
	previous = pi.bias
	var updates := 0
	while pi.bias > pi.bias_min and updates < 2000:
		pi.update(4.0, 16.67, 0.25)
		fall_ok = fall_ok and previous - pi.bias <= pi.max_fall + 1e-9 and pi.bias >= pi.bias_min
		previous = pi.bias
		updates += 1
	_check(fall_ok and pi.bias == pi.bias_min, "pi: headroom recovers gradually (<= max_fall per update) down to bias_min in %d updates" % updates)
	_check(updates >= int((pi.bias_max - 0.2) / pi.max_fall) - 2, "pi: recovery from the coarsest takes at least ~bias_max/max_fall updates")
	pi.update(4.0, 16.67, 0.25)
	_check(pi.bias == pi.bias_min and pi.saturation == -1 and pi.integral >= pi.bias_min, "pi: clamps at the finest permitted bias and does not go below it")

	# Dead band: small errors change nothing.
	var db := _pi()
	db.bias = 0.5
	db.integral = 0.5
	for i in 40:
		db.update(16.67 * 1.02, 16.67, 0.25)
	_check(db.bias == 0.5 and db.integral == 0.5, "pi: errors inside the dead band leave the bias alone")

	# Toy closed loop: cost falls with bias but has a floor. Reachable target -> converges without oscillating.
	var loop := _pi()
	var base := 24.0
	var trace: Array[float] = []
	var reversals := 0
	var last_dir := 0
	for i in 400:  # 100 s at 4 Hz
		var cost: float = base * (1.0 - 0.5 * loop.bias / (1.0 + loop.bias))
		var before: float = loop.bias
		loop.update(cost, 18.0, 0.25)
		trace.append(loop.bias)
		var dir := signi(roundi((loop.bias - before) * 10000.0))
		if i > 200 and dir != 0:
			if last_dir != 0 and dir != last_dir:
				reversals += 1
			last_dir = dir
	var final_cost: float = base * (1.0 - 0.5 * loop.bias / (1.0 + loop.bias))
	var spread := 0.0
	for i in range(300, 400):
		spread = maxf(spread, absf(trace[i] - loop.bias))
	_check(absf(final_cost - 18.0) / 18.0 < 0.05, "pi: toy loop converges to the target (cost %.2f ms vs 18.00, bias %.3f)" % [final_cost, loop.bias])
	_check(spread < 0.1 and reversals <= 4, "pi: toy loop is stable (bias spread %.3f in the last 25 s, %d reversals after 50 s)" % [spread, reversals])
	# Headroom returns to the baseline bias.
	base = 12.0
	var monotone_down := true
	previous = loop.bias
	for i in 800:
		loop.update(base * (1.0 - 0.5 * loop.bias / (1.0 + loop.bias)), 18.0, 0.25)
		monotone_down = monotone_down and loop.bias <= previous + 1e-9
		previous = loop.bias
	_check(loop.bias == loop.bias_min and monotone_down, "pi: toy loop recovers to the baseline bias monotonically when load drops")

	# Reset + determinism: the same inputs after reset() give the identical trace.
	var run_a := _trace(_pi())
	var again := _pi()
	_trace(again)
	again.reset()
	var run_b := _trace(again)
	_check(run_a == run_b and again.updates == 60, "pi: reset() restores the initial state and replays an identical trace")
	_check(again.bias != 0.0, "pi: the replayed trace is not trivially zero")


func _trace(pi: RefCounted) -> Array[float]:
	var values: Array[float] = []
	for i in 60:
		pi.update(30.0 if i < 40 else 10.0, 16.67, 0.25)
		values.append(pi.bias)
	return values


# --- C. configuration

func _test_config() -> void:
	var config := BenchmarkConfig.from_args(PackedStringArray(["--bench-lod-mode=adaptive", "--bench-profile=stress", "--bench-kp=0.8", "--bench-switch-budget=25"]))
	_check(config.errors.is_empty() and config.lod_mode == "adaptive", "config: --bench-lod-mode=adaptive is accepted %s" % [config.errors])
	_check(config.width == 2560 and config.height == 1440 and is_equal_approx(config.target_ms, 8.0), "config: stress profile = 2560x1440, 8 ms")
	_check(is_equal_approx(config.kp, 0.8) and config.switch_budget == 25, "config: controller options are parsed")
	var override := BenchmarkConfig.from_args(PackedStringArray(["--bench-target-ms=10", "--bench-profile=stress", "--bench-width=1920", "--bench-height=1080"]))
	_check(is_equal_approx(override.target_ms, 10.0) and override.width == 1920, "config: explicit options override the profile whatever the order")
	var normal := BenchmarkConfig.from_args(PackedStringArray(["--bench-lod-mode=baseline"]))
	_check(normal.width == 1920 and is_equal_approx(normal.target_ms, 16.67) and normal.vsync == "off" and normal.max_fps == 0, "config: defaults = 1080p, 16.67 ms, VSync off, uncapped")
	var controller: Dictionary = config.to_dict()["controller"]
	_check(controller["used"] and controller["kp"] == config.kp and controller["target_ms"] == 8.0, "config: to_dict records the controller parameters")
	_check(not BenchmarkConfig.from_args(PackedStringArray(["--bench-lod-mode=turbo"])).errors.is_empty(), "config: an unknown mode is rejected")
	_check(not BenchmarkConfig.from_args(PackedStringArray(["--bench-signal=cpu"])).errors.is_empty(), "config: an unknown signal is rejected")
	_check(not BenchmarkConfig.from_args(PackedStringArray(["--bench-kp=-1"])).errors.is_empty(), "config: a negative gain is rejected")


# --- B. AdaptiveLod with the real policies

func _test_modes() -> void:
	_manager.set_mode("baseline")
	_check(_manager.mode() == "baseline" and not _adaptive.is_active(), "modes: baseline selected, controller inactive")
	_camera.global_transform = _path.sample(0.0)
	await _frame_all(3, 16.67)
	var baseline_signature := _signature()
	_check(_trees.update_interval_s == 0.0 and _trees.max_changes_per_update == 0 and _trees.lod_bias == 0.0, "modes: baseline keeps the default schedule (every frame, no limit, bias 0)")
	_manager.set_mode("none")
	_check(_manager.mode() == "none" and _manager.is_none(), "modes: none disables every category")
	await _frame_all(2, 16.67)
	_check(_bush.instance_drawn() == _bush.instance_total() and _debris.instance_drawn() == _debris.instance_total(), "modes: none draws every bush and debris instance")
	_manager.set_mode("adaptive")
	_check(_manager.mode() == "adaptive" and _adaptive.is_active(), "modes: adaptive selected, controller active")
	_check(_trees.update_interval_s > 0.0 and _trees.max_changes_per_update > 0 and _adaptive.bias == 0.0, "modes: adaptive applies the update schedule and change budgets, bias starts at 0")
	await _frame_all(3, 16.67)
	_check(_signature() == baseline_signature, "modes: adaptive at bias 0 shows exactly the baseline state")
	_manager.set_mode("baseline")
	_check(_adaptive.bias == 0.0 and not _adaptive.is_active() and _trees.update_interval_s == 0.0 and _trees.max_changes_per_update == 0, "modes: leaving adaptive resets bias, schedule and budgets")
	await _frame_all(3, 16.67)
	_check(_signature() == baseline_signature, "modes: baseline after adaptive equals the original baseline state")


func _test_pressure_and_recovery() -> void:
	_camera.global_transform = _path.sample(120.0)
	_manager.set_mode("baseline")
	await _frame_all(3, 16.67)
	_manager.resync_all()
	var before := _counts()
	_manager.set_mode("adaptive")
	var start_bias: float = _adaptive.bias
	# Sustained 2x overload for 40 s of simulated time.
	await _frame_all(60 * 40, 2.0 * _adaptive.target_ms, true)
	var pressed := _counts()
	_check(_adaptive.bias > start_bias + 0.5 and _adaptive.bias <= _adaptive.bias_max, "pressure: sustained overload raises the bias (%.3f)" % _adaptive.bias)
	_check(_adaptive.controller.saturation == 1 and _adaptive.bias == _adaptive.bias_max, "pressure: an unreachable target pins the bias at the coarsest permitted value")
	_check(pressed["bushes"] < before["bushes"] and pressed["debris"] < before["debris"] and pressed["grass"] < before["grass"],
			"pressure: bushes %d -> %d, debris %d -> %d, grass clumps %d -> %d drawn" % [before["bushes"], pressed["bushes"], before["debris"], pressed["debris"], before["grass"], pressed["grass"]])
	_check(pressed["tree_lod2"] > before["tree_lod2"] and pressed["tree_lod0"] == before["tree_lod0"],
			"pressure: distant trees move to a coarser mesh, nearby LOD0 trees do not (LOD0 %d -> %d, LOD1 %d -> %d, LOD2 %d -> %d)" % [
			before["tree_lod0"], pressed["tree_lod0"], before["tree_lod1"], pressed["tree_lod1"], before["tree_lod2"], pressed["tree_lod2"]])
	_check(_manager.verify_all().is_empty(), "pressure: every category is consistent at the coarsest bias: %s" % _manager.verify_all())
	var peak_switches := _total_switches()
	# Without pressure change nothing is switched any more (stable at saturation).
	await _frame_all(60 * 5, 2.0 * _adaptive.target_ms, true)
	_check(_total_switches() == peak_switches, "pressure: no switching once the bias has stopped moving and the camera is still")
	# Headroom: 0.4x the target for as long as it takes. Gradual: the bias falls by at most max_fall per controller update.
	var biases: Array[float] = []
	var seconds := 0
	while _adaptive.bias > 0.0 and seconds < 120:
		await _frame_all(15, 0.4 * _adaptive.target_ms, true)
		biases.append(_adaptive.bias)
		seconds += 1
	var gradual := true
	for i in range(1, biases.size()):
		gradual = gradual and biases[i] <= biases[i - 1] + 1e-9 and biases[i - 1] - biases[i] <= _adaptive.max_fall_per_update * 1.5
	_check(_adaptive.bias == 0.0 and gradual, "headroom: bias recovers gradually to the baseline in about %.0f s (%d samples)" % [biases.size() * 0.25, biases.size()])
	await _frame_all(60, 0.4 * _adaptive.target_ms, true)
	var recovered := _counts()
	_check(recovered["bushes"] >= pressed["bushes"] and recovered["bushes"] <= before["bushes"] + 0, "headroom: bush count recovered toward the baseline (%d between %d and %d)" % [recovered["bushes"], pressed["bushes"], before["bushes"]])
	_check(_manager.verify_all().is_empty(), "headroom: every category is consistent after recovery: %s" % _manager.verify_all())


func _test_spikes_and_unavailable() -> void:
	_manager.set_mode("adaptive")
	_camera.global_transform = _path.sample(120.0)
	await _frame_all(60 * 3, _adaptive.target_ms, true)
	var calm: float = _adaptive.bias
	# One 1.5 s hitch (90 frames of 900 ms) cannot move the bias far: clipped to 3x the target and then smoothed.
	await _frame_all(2, 900.0, true)
	await _frame_all(60 * 3, _adaptive.target_ms, true)
	_check(_adaptive.bias <= calm + 0.15, "spike: a single 900 ms hitch moved the bias by only %.3f" % (_adaptive.bias - calm))
	# Unavailable signal: held, flagged, counted.
	_manager.set_mode("adaptive")
	await _frame_all(60 * 20, 2.0 * _adaptive.target_ms, true)
	var held: float = _adaptive.bias
	var steps: int = _adaptive.pi_steps
	await _frame_all(60 * 10, -1.0, true)
	_check(_adaptive.bias == held and _adaptive.pi_steps == steps and not _adaptive.signal_available and _adaptive.unavailable_frames >= 600,
			"unavailable: the bias is held (%.3f) and no PI step runs while the signal is missing (%d frames)" % [held, _adaptive.unavailable_frames])
	await _frame_all(60 * 4, 2.0 * _adaptive.target_ms, true)
	_check(_adaptive.signal_available and _adaptive.pi_steps > steps, "unavailable: control resumes when the signal returns")
	# Hold (benchmark settle) freezes it too.
	_adaptive.hold = true
	var frozen: float = _adaptive.bias
	await _frame_all(60 * 4, 0.3 * _adaptive.target_ms, true)
	_check(_adaptive.bias == frozen, "hold: a held controller does not move")
	_adaptive.hold = false
	_adaptive.reset()
	_check(_adaptive.bias == 0.0 and _adaptive.controller.integral == 0.0 and _adaptive.pi_steps == 0 and _trees.lod_bias == 0.0 and _bush.lod_bias == 0.0,
			"reset: bias, integral, counters and every policy's bias are back to 0")
	await _frame_all(60 * 20, 2.0 * _adaptive.target_ms, true)
	var run_a: float = _adaptive.bias
	_adaptive.reset()
	await _frame_all(60 * 20, 2.0 * _adaptive.target_ms, true)
	_check(is_equal_approx(run_a, _adaptive.bias), "reset: the same synthetic input after a reset gives the same bias (%.4f vs %.4f)" % [run_a, _adaptive.bias])
	_manager.set_mode("baseline")


## The adaptive budget is a priority list: grass first, then distant trees, bushes and debris last and mildly.
func _test_priority_and_clamps() -> void:
	_manager.set_mode("adaptive")
	var previous := {}
	var monotone := true
	var within := true
	var table := PackedStringArray()
	for global_bias in [0.0, 0.3, 0.8, 1.2, 1.6, 2.0]:
		_adaptive.controller.reset(global_bias)
		_adaptive.bias = global_bias
		_adaptive._apply_bias()
		var now := {}
		for p in _manager.policies():
			now[p.category()] = p.lod_bias
			monotone = monotone and p.lod_bias >= float(previous.get(p.category(), 0.0)) - 1e-9
			within = within and p.lod_bias >= _adaptive.bias_min and p.lod_bias <= _adaptive.bias_max
		table.append("%.1f: grass %.2f trees %.2f bushes %.2f debris %.2f" % [global_bias, now["grass"], now["trees"], now["bushes"], now["debris"]])
		if global_bias == 0.3:
			_check(now["grass"] > 0.0 and now["trees"] == 0.0 and now["bushes"] == 0.0 and now["debris"] == 0.0, "priority: at a small bias only grass coarsens (%s)" % table[-1])
		if global_bias == 0.8:
			_check(now["trees"] > 0.0 and now["bushes"] == 0.0 and now["debris"] == 0.0 and now["grass"] > now["trees"], "priority: distant trees follow grass, bushes and debris still untouched (%s)" % table[-1])
		if global_bias == 2.0:
			_check(is_equal_approx(now["grass"], 1.0) and is_equal_approx(now["trees"], 1.0) and is_equal_approx(now["bushes"], 0.5) and is_equal_approx(now["debris"], 0.5),
					"priority: every category stops at its own cap at the maximum global bias (%s)" % table[-1])
		previous = now
	_check(monotone and within, "priority: per-category bias is non-decreasing with the global bias and inside the safety limits")
	print("[adaptive-test] category bias by global bias: " + " | ".join(table))
	_adaptive.reset()
	_manager.set_mode("baseline")


## Trees: the adaptive bias may shrink the thresholds only down to the minimum-detail floors; the baseline is unchanged.
func _test_tree_floor() -> void:
	_manager.set_mode("baseline")
	await _frame_all(3, 16.67)
	var base: PackedFloat32Array = _trees.effective_thresholds()
	_check(base == PackedFloat32Array([60.0, 150.0]) and _trees.lod1_distance == 60.0 and _trees.lod2_distance == 150.0 and _trees.hysteresis == 10.0,
			"floor: baseline tree thresholds are exactly 60 / 150 m with hysteresis 10 m %s" % base)
	var previous := PackedFloat32Array([60.0, 150.0])
	var ok_floor := true
	var ok_sign := true
	for b in [0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 5.0]:
		_trees.set_lod_bias(b)
		var eff: PackedFloat32Array = _trees.effective_thresholds()
		ok_floor = ok_floor and eff[0] == 60.0 and eff[1] >= _trees.adaptive_floor_lod2 and eff[1] <= 150.0
		ok_sign = ok_sign and eff[0] <= previous[0] and eff[1] <= previous[1]
		previous = eff
	_check(ok_floor, "floor: at any positive bias LOD1 starts no closer than %.0f m and LOD2 no closer than %.0f m" % [_trees.adaptive_floor_lod1, _trees.adaptive_floor_lod2])
	_check(ok_sign, "floor: sign convention: a larger positive bias never moves a threshold outwards")
	_trees.set_lod_bias(2.0)
	_check(_trees.effective_thresholds() == PackedFloat32Array([60.0, 100.0]), "floor: bias 2.0 gives 60 / 100 m, not the unconstrained 20 / 50 m")
	# The floors are what protects the nearby trees: without them the same bias pulls LOD1 in to 20 m.
	var floors := [_trees.adaptive_floor_lod1, _trees.adaptive_floor_lod2]
	_trees.adaptive_floor_lod1 = 0.0
	_trees.adaptive_floor_lod2 = 0.0
	var unconstrained: PackedFloat32Array = _trees.effective_thresholds()
	_check(is_equal_approx(unconstrained[0], 20.0) and is_equal_approx(unconstrained[1], 50.0), "floor: with the floors removed bias 2.0 would coarsen trees from %s m" % unconstrained)
	_trees.adaptive_floor_lod1 = floors[0]
	_trees.adaptive_floor_lod2 = floors[1]
	_trees.set_lod_bias(-0.3)
	_check(_trees.effective_thresholds()[0] > 60.0, "floor: a negative (finer) bias moves the thresholds outwards")
	# Real trees: after a resync every tree closer than the floor has exactly its baseline level.
	for view in [60.0, 200.0, 350.0]:
		_camera.global_transform = _path.sample(view)
		_trees.set_lod_bias(0.0)
		_trees.resync()
		var baseline_levels := _tree_levels()
		_trees.set_lod_bias(2.0)
		_trees.resync()
		var adaptive_levels := _tree_levels()
		var violations := 0
		var coarser := 0
		var origin := _camera.global_position
		var index := 0
		for chunk in _trees._lod_set.chunks:
			for group in chunk.groups:
				for i in group.count:
					var distance := origin.distance_to(group.positions[i])
					if distance < 100.0 and adaptive_levels[index] != baseline_levels[index]:
						violations += 1
					if distance > 100.0 and adaptive_levels[index] > baseline_levels[index]:
						coarser += 1
					if adaptive_levels[index] < baseline_levels[index]:
						violations += 1
					index += 1
		_check(violations == 0, "floor: path %d m: no tree within 100 m differs from baseline and none is finer than baseline (%d violations, %d distant trees coarser)" % [int(view), violations, coarser])
	_trees.set_lod_bias(0.0)
	_manager.set_mode("baseline")
	_manager.resync_all()


func _tree_levels() -> PackedByteArray:
	var levels := PackedByteArray()
	for chunk in _trees._lod_set.chunks:
		for group in chunk.groups:
			levels.append_array(group.level)
	return levels


## Hysteresis: a tree wobbling inside the dead band around a threshold does not switch; it needs to pass the band.
func _test_hysteresis() -> void:
	_manager.set_mode("baseline")
	_trees.set_lod_bias(0.0)
	_trees.resync()
	var group = _trees._lod_set.chunks[0].groups[0]
	var tree_position: Vector3 = group.positions[0]
	for case in [[0.0, 60.0, 0], [1.0, 100.0, 1]]:
		var bias: float = case[0]
		var threshold: float = case[1]
		_trees.set_lod_bias(bias)
		_check(is_equal_approx(_trees.effective_thresholds()[case[2]], threshold), "hysteresis: bias %.1f threshold %d is %.0f m" % [bias, case[2], threshold])
		var h: float = _trees.hysteresis
		_place_at_distance(tree_position, threshold - 15.0)
		_trees.resync()
		var start_level: int = group.level[0]
		var changes := 0
		var seen: int = start_level
		for step in 60:  # wobble +-(h - 2) around the threshold
			_place_at_distance(tree_position, threshold + (h - 2.0) * sin(step * 0.7))
			_trees._process(DT)
			if group.level[0] != seen:
				changes += 1
				seen = group.level[0]
		_check(group.level[0] == start_level and changes == 0,
				"hysteresis: threshold %.0f m: wobbling +-%.0f m around it causes no switch of that tree (level %d, %d changes)" % [threshold, h - 2.0, group.level[0], changes])
		_place_at_distance(tree_position, threshold + h + 3.0)
		_trees._process(DT)
		var coarse_level: int = group.level[0]
		_check(coarse_level == start_level + 1, "hysteresis: past the band (%.0f m) the tree switches to the coarser level" % (threshold + h + 3.0))
		for step in 60:
			_place_at_distance(tree_position, threshold + (h - 2.0) * sin(step * 0.9))
			_trees._process(DT)
		_check(group.level[0] == coarse_level, "hysteresis: and wobbling back inside the band does not switch it back")
		_place_at_distance(tree_position, threshold - h - 3.0)
		_trees._process(DT)
		_check(group.level[0] == start_level, "hysteresis: it returns to the finer level only after passing the band on the near side")
	# A moving threshold (the controller changing the bias) above the floor range does not switch trees either.
	_trees.set_lod_bias(0.9)
	_place_at_distance(tree_position, 75.0)
	_trees.resync()
	var level_now: int = group.level[0]
	var switches: int = _trees.total_switches
	for b in [0.9, 1.1, 1.4, 1.0, 2.0, 0.6]:
		_trees.set_lod_bias(b)
		_trees._process(DT)
	_check(group.level[0] == level_now and _trees.total_switches == switches, "hysteresis: bias changes that stay above the floor move no tree at 75 m")
	_trees.set_lod_bias(0.0)
	_manager.resync_all()


func _place_at_distance(target: Vector3, distance: float) -> void:
	_camera.global_position = target + Vector3(distance, 0.0, 0.0)


## Walks 20 s of the benchmark path under synthetic pressure that rises and then falls and counts what individual
## trees do: bursts per update, trees that switch back within 2 s, most switches of one tree. Compared with baseline.
func _test_transitions() -> void:
	var results := {}
	for mode in ["baseline", "adaptive"]:
		_manager.set_mode(mode)
		_manager.resync_all()
		_camera.global_transform = _path.sample(200.0)
		await _frame_all(5, _adaptive.target_ms, true)
		var levels := _tree_levels()
		var count := levels.size()
		var last_step := PackedInt32Array()
		last_step.resize(count)
		var before_level := PackedByteArray()
		before_level.resize(count)
		var changes := PackedInt32Array()
		changes.resize(count)
		var switches := 0
		var flipbacks := 0
		var burst_max := 0
		var step := 0
		var frame_max := 0
		var peak_bias := 0.0
		var distance := 200.0
		for frame in 1200:  # 20 s at 60 fps, 8 m/s
			var pressure := 1.6 if frame < 700 else 0.5
			_camera.global_transform = _path.sample(distance)
			distance += 8.0 * DT
			if _adaptive.is_active():
				_adaptive.step(pressure * _adaptive.target_ms, DT)
			for p in _manager.policies():
				if p.enabled:
					p._process(DT)
			frame_max = maxi(frame_max, _trees.frame_switches)
			peak_bias = maxf(peak_bias, _adaptive.bias)
			if frame % 6 == 5:
				step += 1
				var now := _tree_levels()
				var burst := 0
				for i in count:
					if now[i] != levels[i]:
						burst += 1
						switches += 1
						changes[i] += 1
						if last_step[i] > 0 and step - last_step[i] <= 20 and before_level[i] == now[i]:
							flipbacks += 1
						before_level[i] = levels[i]
						last_step[i] = step
				burst_max = maxi(burst_max, burst)
				levels = now
			if frame % 40 == 39:
				await process_frame
		var most := 0
		for i in count:
			most = maxi(most, changes[i])
		results[mode] = {"switches": switches, "flipbacks": flipbacks, "burst": burst_max, "frame_max": frame_max, "per_tree_max": most, "peak_bias": peak_bias}
		print("[adaptive-test] transitions %-8s over 20 s: %d tree level changes, %d switched back within 2 s, largest burst %d trees per 0.1 s, most changes of one tree %d, largest single-frame switch count %d, peak bias %.2f" % [
				mode, switches, flipbacks, burst_max, most, frame_max, peak_bias])
	_check(results["adaptive"]["flipbacks"] <= results["baseline"]["flipbacks"] + 5, "transitions: adaptive control causes no more switch-backs than the baseline (%d vs %d)" % [results["adaptive"]["flipbacks"], results["baseline"]["flipbacks"]])
	_check(results["adaptive"]["frame_max"] <= _adaptive.max_changes_per_update["trees"], "transitions: no frame switched more trees than the change budget (%d <= %d)" % [results["adaptive"]["frame_max"], _adaptive.max_changes_per_update["trees"]])
	_check(results["adaptive"]["per_tree_max"] <= 4, "transitions: no tree changed level more than 4 times in 20 s (%d)" % results["adaptive"]["per_tree_max"])
	_check(results["adaptive"]["peak_bias"] > 0.5, "transitions: the controller actually applied pressure in this test (peak bias %.2f)" % results["adaptive"]["peak_bias"])
	_manager.set_mode("baseline")


func _test_budget_and_schedule() -> void:
	_camera.global_transform = _path.sample(200.0)
	# Reference: one unlimited update after a bias jump.
	var reference := {}
	for budget in [0, 12]:
		_manager.set_mode("baseline")
		for p in _manager.policies():
			p.max_changes_per_update = 0
			p.set_lod_bias(0.0)
			p.reset_schedule()
		await _frame_all(3, 16.67)
		_manager.resync_all()
		for p in _manager.policies():
			p.max_changes_per_update = budget
			p.set_lod_bias(0.9)
		var most := 0
		var updates := 0
		for i in 400:
			for p in _manager.policies():
				p._process(DT)
				most = maxi(most, p.frame_switches)
				if p.updates_run > 0 and p.last_update_ms > 0.0:
					updates += 1
			if budget > 0 and not _any_backlog() and i > 3:
				break
			if budget == 0 and i > 3:
				break
		var signature := _signature()
		if budget == 0:
			reference = {"signature": signature, "most": most}
		else:
			_check(most <= budget, "budget: no policy switched more than %d units in one update (most: %d)" % [budget, most])
			_check(most > 0 and updates > 4, "budget: the bias jump needed several updates to finish (%d policy updates)" % updates)
			_check(signature == reference["signature"], "budget: the budget-limited run converges to exactly the unlimited result")
			_check(reference["most"] > budget, "budget: the unlimited update did switch more than the budget (%d > %d), so the limit was exercised" % [reference["most"], budget])
	for p in _manager.policies():
		p.max_changes_per_update = 0
		p.set_lod_bias(0.0)
	_manager.set_mode("baseline")

	# Scheduling: a still camera costs nothing once converged; a moved camera triggers an update at the next interval.
	_manager.set_mode("adaptive")
	await _frame_all(120, _adaptive.target_ms, true)
	var runs := _updates_run()
	await _frame_all(120, _adaptive.target_ms, true)
	_check(_updates_run() == runs, "schedule: a still camera with unchanged bias runs no policy updates")
	_camera.global_position += Vector3(3.0, 0.0, 0.0)
	await _frame_all(12, _adaptive.target_ms, true)
	_check(_updates_run() > runs, "schedule: moving the camera runs an update within the interval")
	var skipped := 0
	var total_frames := 120
	runs = _updates_run()
	for i in total_frames:
		_camera.global_position += Vector3(0.13, 0.0, 0.0)
		await _frame_all(1, _adaptive.target_ms, true)
	var per_frame := float(_updates_run() - runs) / total_frames
	_check(per_frame < 4.0 * 0.5, "schedule: while moving at 8 m/s the four policies run %.2f updates per frame instead of 4" % per_frame)
	_manager.set_mode("baseline")


func _test_integrity() -> void:
	# After all of the above: nothing lost, duplicated or moved, collision and terrain untouched.
	_manager.set_mode("adaptive")
	await _frame_all(60 * 10, 2.0 * _adaptive.target_ms, true)
	var errors: String = _manager.verify_all()
	_check(errors.is_empty(), "integrity: all categories consistent under adaptive control: %s" % errors)
	_check(_trees.instance_drawn() == _trees.instance_total() and _trees.level_counts()[0] + _trees.level_counts()[1] + _trees.level_counts()[2] == _trees.instance_total(),
			"integrity: every tree is drawn exactly once at some level (%d)" % _trees.instance_total())
	var tree_baked := 0
	for chunk in _baked_vegetation.get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node != null and node.get_meta("vegetation_kind", "") == "tree":
				tree_baked += node.multimesh.instance_count
	_check(tree_baked == _trees.instance_total(), "integrity: tree instances equal the saved scene (%d == %d)" % [tree_baked, _trees.instance_total()])
	for p in [_bush, _debris]:
		var baked := {}
		for chunk in _baked_vegetation.get_children():
			for child in chunk.get_children():
				var node := child as MultiMeshInstance3D
				if node != null and node.get_meta("vegetation_kind", "") == p.kind:
					var list: Array = []
					for i in node.multimesh.instance_count:
						list.append(node.multimesh.get_instance_transform(i))
					baked["%s/%s" % [chunk.name, node.name]] = list
		var permutation: String = p.verify_permutation(baked)
		_check(permutation.is_empty(), "integrity: %s buffers are a permutation of the saved instances (transforms unchanged): %s" % [p.category(), permutation])
	var saved := LodPolicy.collision_signature(_baked_vegetation)
	_check(saved == LodPolicy.collision_signature(_env.get_node("Vegetation")), "integrity: collision bodies, shapes and vertices equal the saved scene %s" % saved)
	# Grass: tier assignment is a pure function of camera and bias (repeatable), cells keep their placement.
	var hashes: Array[String] = []
	for run in 2:
		_adaptive.reset()
		_camera.global_transform = _path.sample(260.0)
		_grass.set_lod_bias(0.7)
		_grass.resync()
		hashes.append(_grass_tier_hash())
	_check(hashes[0] == hashes[1], "determinism: grass tiers at a given camera and bias are identical across runs (%s)" % hashes[0].substr(0, 12))
	var tiers_a: PackedInt32Array = _grass.cell_tier_counts()
	var drawn_a: int = _grass.instance_drawn()
	_grass.set_lod_bias(0.0)
	_grass.resync()
	var tiers_b: PackedInt32Array = _grass.cell_tier_counts()
	_check(drawn_a < _grass.instance_drawn() and tiers_a[3] > tiers_b[3], "determinism: a positive bias moves cells to coarser tiers (clumps %d -> %d, culled cells %d -> %d)" % [_grass.instance_drawn(), drawn_a, tiers_b[3], tiers_a[3]])
	# Density order: two policies at the same bias show the same instance subsets (prefix of the fixed order).
	_bush.set_lod_bias(0.5)
	_bush.resync()
	var sig1 := _bush_signature()
	_bush.set_lod_bias(1.2)
	_bush.resync()
	_bush.set_lod_bias(0.5)
	_bush.resync()
	_check(sig1 == _bush_signature(), "determinism: bush density subsets depend only on camera and bias")
	_bush.set_lod_bias(0.0)
	_check(_terrain_settings() == _terrain_before, "terrain: Terrain3D LOD/mesh/collision settings unchanged by all adaptive activity %s" % _terrain_before)
	_manager.set_mode("baseline")


func _test_panel() -> void:
	var panel := _env.get_node("LodDebugPanel")
	var panels := 0
	for child in _env.get_children():
		if child.name.contains("Panel"):
			panels += 1
	_check(panels == 1, "panel: still exactly one panel node")
	_key(KEY_F3)
	await create_timer(0.4).timeout
	_check(panel.is_panel_visible(), "panel: F3 shows it")
	_manager.set_mode("baseline")
	var adaptive_button := panel.find_child("AdaptiveButton", true, false) as Button
	_check(adaptive_button != null, "panel: has an Adaptive button next to None and Baseline")
	adaptive_button.pressed.emit()
	_check(_manager.mode() == "adaptive", "panel: the Adaptive button selects adaptive mode")
	_adaptive.step(-1.0, DT)
	for i in 20:
		_adaptive.step(-1.0, DT)
	_adaptive.hold = false
	await create_timer(0.5).timeout
	var text: String = panel.get_text()
	print("[adaptive-test] panel text (Adaptive, no signal):\n" + text)
	_check(text.contains("Mode        Adaptive"), "panel: shows the Adaptive mode")
	_check(text.contains("UNAVAILABLE"), "panel: warns clearly that the timing signal is unavailable")
	for label in ["Target", "Bias", "Trees LOD0", "Grass", "Bushes", "Debris", "Rocks", "LOD update"]:
		_check(text.contains(label), "panel: shows a '%s' line" % label)
	# Feed synthetic samples so the signal exists.
	_adaptive.step(20.0, DT)
	_adaptive.step(20.0, DT)
	await create_timer(0.5).timeout
	text = panel.get_text()
	_check(text.contains("Signal") and not text.contains("UNAVAILABLE"), "panel: shows the signal once it is available")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(_manager.mode() == "none", "panel: F4 cycles Adaptive -> None")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(_manager.mode() == "baseline", "panel: F4 cycles None -> Baseline")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(_manager.mode() == "adaptive", "panel: F4 cycles Baseline -> Adaptive")
	_manager.set_mode("baseline")
	_key(KEY_F3)
	await _frames(2)
	_check(not panel.is_panel_visible(), "panel: F3 hides it")


# --- E. costs

func _report_costs() -> void:
	print("[adaptive-test] initialisation cost (first enabled frame): trees %.0f ms, grass %.0f ms, bushes %.0f ms, debris %.0f ms (measured once, in this process)" % [
			_trees.build_ms, _grass.build_ms, _bush.build_ms, _debris.build_ms])
	var configs := [["baseline (every frame)", "baseline", 1.0], ["adaptive, bias 0 (scheduled)", "adaptive", 1.0], ["adaptive, 1.6x overload", "adaptive", 1.6]]
	for config in configs:
		_manager.set_mode(config[1])
		_adaptive.reset()
		_camera.global_transform = _path.sample(0.0)
		await _frame_all(5, 16.67, true)
		var start := {}
		for p in _manager.policies():
			start[p.category()] = [p.total_update_ms, p.updates_run, p.total_switches]
		var controller_ms: float = _adaptive.total_update_ms
		var controller_frames: int = _adaptive.update_frames
		var frames := 0
		var distance := 0.0
		while distance < 400.0:  # 50 s at 8 m/s, simulated at 60 fps
			_camera.global_transform = _path.sample(distance)
			await _frame_all(1, config[2] * _adaptive.target_ms, true)
			distance += 8.0 * DT
			frames += 1
		var parts := PackedStringArray()
		var total := 0.0
		for p in _manager.policies():
			var ms: float = p.total_update_ms - start[p.category()][0]
			total += ms
			parts.append("%s %.3f (%d runs, %d sw)" % [p.category(), ms / frames, p.updates_run - start[p.category()][1], p.total_switches - start[p.category()][2]])
		var ctrl := ""
		if _adaptive.is_active():
			ctrl = ", controller %.4f ms/frame, final bias %.2f" % [(_adaptive.total_update_ms - controller_ms) / maxi(_adaptive.update_frames - controller_frames, 1), _adaptive.bias]
		print("[adaptive-test] cost %-30s %d frames: policies %.3f ms/frame total [%s]%s" % [config[0], frames, total / frames, "; ".join(parts), ctrl])
	_manager.set_mode("baseline")


# --- helpers

## Simulates `count` frames: controller step with `sample_ms`, then the policies in process order.
func _frame_all(count: int, sample_ms: float, adaptive := false) -> void:
	for i in count:
		if _adaptive.is_active():
			_adaptive.step(sample_ms, DT)
		for p in _manager.policies():
			if p.enabled:
				p._process(DT)
		if i % 30 == 29:
			await process_frame  # let the engine breathe (rendering, physics)


func _counts() -> Dictionary:
	var tree_levels: PackedInt32Array = _trees.level_counts()
	return {
		"bushes": _bush.instance_drawn(), "debris": _debris.instance_drawn(), "grass": _grass.instance_drawn(),
		"tree_lod0": tree_levels[0], "tree_lod1": tree_levels[1], "tree_lod2": tree_levels[2],
	}


func _total_switches() -> int:
	var total := 0
	for p in _manager.policies():
		total += p.total_switches
	return total


func _updates_run() -> int:
	var total := 0
	for p in _manager.policies():
		total += p.updates_run
	return total


func _any_backlog() -> bool:
	for p in _manager.policies():
		if p._backlog:
			return true
	return false


## Hash over the drawn state of every category: tier counts and the visible counts of every node.
func _signature() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for p in _manager.policies():
		ctx.update(("%s:%s:%d" % [p.category(), p.tier_counts(), p.instance_drawn()]).to_utf8_buffer())
	ctx.update(_grass_tier_hash().to_utf8_buffer())
	ctx.update(_bush_signature().to_utf8_buffer())
	for chunk in _trees._lod_set.chunks:
		for group in chunk.groups:
			ctx.update(group.level)
	return ctx.finish().hex_encode()


func _grass_tier_hash() -> String:
	var tiers := PackedByteArray()
	for cell in _grass._cells:
		tiers.append(cell.tier)
	return tiers.hex_encode().sha256_text()


func _bush_signature() -> String:
	var tiers := PackedByteArray()
	for chunk in _bush.chunks:
		tiers.append(chunk.tier)
	for chunk in _debris.chunks:
		tiers.append(chunk.tier)
	return tiers.hex_encode()


func _terrain_settings() -> Dictionary:
	var result := {}
	for name in TERRAIN_PROPS:
		if name in _terrain:
			result[name] = _terrain.get(name)
	return result


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
	print("[adaptive-test] %s %s" % ["ok  " if ok else "FAIL", message])

