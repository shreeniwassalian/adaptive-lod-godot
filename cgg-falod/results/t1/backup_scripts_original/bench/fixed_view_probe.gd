extends SceneTree
## Fixed-camera investigation probe (not part of the benchmark harness; the benchmark and scene are untouched).
## Holds the camera still at points of the benchmark path and compares LOD configurations and rendering ablations,
## interleaved round-robin over repetitions so slow machine drift (GPU clocks, contention) hits every config alike.
##   Godot_console.exe --path . --script res://scripts/bench/fixed_view_probe.gd -- --suite=compare|ablate|shots [options]
## Options: --reps=3 --frames=240 --settle=60 --views=0,150,300 --out=DIR --width=1920 --height=1080 --veg-mult=N
## --veg-mult=N (prototype of a vegetation stress scene, in memory only, saved scenes untouched): every tree, bush and debris
## MultiMesh gets N times its instances, the extra copies jittered up to 4 m from the original and put back on the terrain height.
## Collision is not duplicated; this is only meant to show how the cost of vegetation and the effect of LOD change with more of it.
## compare: none / baseline / adaptive pinned at bias 0.5, 1.0, 2.0 (controller held, category weights applied).
## ablate : the same modes with one rendering feature removed at a time (shadows, vegetation, terrain, river, render scale).
## --ablations=a,b,c and --modes=none,baseline,bias2.0 narrow the ablate suite; extra ablations hide_trees, hide_bushes,
## hide_debris, hide_rocks, hide_grass (visibility of that category's MultiMeshes).
## shots  : one PNG per view and config, plus image difference against baseline and none.
## Output: <out>/probe_<suite>_<stamp>.csv (one row per sample) and a printed table of medians over repetitions.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const MetricsSampler := preload("res://scripts/bench/metrics_sampler.gd")
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")

var _suite := "compare"
var _reps := 3
var _frames := 240
var _settle := 60
var _views: Array[float] = [0.0, 150.0, 300.0]
var _out := "res://results/probe"
var _size := Vector2i(1920, 1080)
var _veg_mult := 1
var _ablations: PackedStringArray = []
var _mode_names: PackedStringArray = []
var _hidden_backup := {}

var _env: Node3D
var _terrain: Terrain3D
var _manager: Node
var _adaptive: Node
var _camera: Camera3D
var _sampler: RefCounted
var _path: RefCounted
var _sun: DirectionalLight3D
var _rows: Array = []
var _shadow_backup := {}

const COLUMNS := ["suite", "rep", "view_m", "config", "ablation", "frames", "gpu_ms_median", "gpu_ms_mean", "gpu_ms_p95", "frame_ms_mean", "render_cpu_ms",
		"draw_main", "draw_all", "prim_main", "prim_all", "objects", "trees_lod0", "trees_lod1", "trees_lod2", "grass_clumps", "bushes", "debris",
		"policy_ms_per_frame", "viewport_w", "viewport_h"]


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var parts := arg.trim_prefix("--").split("=", true, 1)
		var value := parts[1] if parts.size() > 1 else ""
		match parts[0]:
			"suite": _suite = value
			"reps": _reps = value.to_int()
			"frames": _frames = value.to_int()
			"settle": _settle = value.to_int()
			"out": _out = value
			"width": _size.x = value.to_int()
			"height": _size.y = value.to_int()
			"veg-mult": _veg_mult = maxi(value.to_int(), 1)
			"ablations": _ablations = value.split(",", false)
			"modes": _mode_names = value.split(",", false)
			"views":
				_views.clear()
				for v in value.split(","):
					_views.append(v.to_float())
	root.mode = Window.MODE_WINDOWED
	DisplayServer.window_set_size(_size)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_env = (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(_env)
	_terrain = _env.get_node("Terrain3D")
	_manager = _env.get_node("LodManager")
	_adaptive = _env.get_node("AdaptiveLod")
	_sun = _env.get_node("Sun")
	for i in 6:
		await physics_frame
	_env.get_node("Player").process_mode = Node.PROCESS_MODE_DISABLED
	_env.get_node("Player").visible = false
	var fly := _env.get_node_or_null("Camera3D") as Camera3D
	if fly != null:
		fly.set_process(false)
	_camera = Camera3D.new()
	_camera.far = 3000.0
	_camera.fov = 75.0
	root.add_child(_camera)
	_camera.make_current()
	_terrain.set_camera(_camera)
	if _veg_mult > 1:
		_multiply_vegetation(_veg_mult)
	_adaptive.external_signal = true
	_adaptive.manage_measurement = false  # the sampler owns GPU time measurement; deactivate() would switch it off
	_sampler = MetricsSampler.new()
	_sampler.start(root)
	_path = CameraPath.new()
	_path.build(_terrain, 2.0, -6.0)
	print("[probe] suite=%s reps=%d frames=%d views=%s window=%s viewport=%s renderer=%s/%s" % [
			_suite, _reps, _frames, _views, root.size, root.get_visible_rect().size, RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name()])
	match _suite:
		"compare":
			await _suite_compare()
		"ablate":
			await _suite_ablate()
		"shots":
			await _suite_shots()
		"tune":
			await _suite_tune()
		"smooth":
			await _suite_smooth()
	_save()
	quit(0)


func _multiply_vegetation(factor: int) -> void:
	var before := {}
	var after := {}
	for chunk in _env.get_node("Vegetation").get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node == null or node.multimesh == null:
				continue
			var kind: String = node.get_meta("vegetation_kind", "")
			if kind != "tree" and kind != "bush" and kind != "debris":
				continue
			var multimesh := node.multimesh
			var count := multimesh.instance_count
			var originals: Array[Transform3D] = []
			for i in count:
				originals.append(multimesh.get_instance_transform(i))
			var rng := RandomNumberGenerator.new()
			rng.seed = hash("%s/%s" % [chunk.name, node.name])
			multimesh.instance_count = count * factor
			for i in count:
				multimesh.set_instance_transform(i, originals[i])
			for k in range(1, factor):
				for i in count:
					var t := originals[i]
					var x := t.origin.x + rng.randf_range(-4.0, 4.0)
					var z := t.origin.z + rng.randf_range(-4.0, 4.0)
					var h: float = _terrain.data.get_height(Vector3(x, 0.0, z))
					t.origin = Vector3(x, h if not is_nan(h) else t.origin.y, z)
					multimesh.set_instance_transform(k * count + i, t)
			before[kind] = before.get(kind, 0) + count
			after[kind] = after.get(kind, 0) + count * factor
	print("[probe] vegetation x%d (in memory): instances %s -> %s" % [factor, before, after])


func _modes() -> Array:
	return [["none", -1.0], ["baseline", 0.0], ["bias0.5", 0.5], ["bias1.0", 1.0], ["bias2.0", 2.0]]


func _suite_compare() -> void:
	# Warm every mode up once (builds the runtime data) so no sample contains a build.
	for mode in _modes():
		_set_mode(mode)
		_place(_views[0])
		await _wait(20)
	for rep in _reps:
		for view in _views:
			var order := _modes()
			for k in rep:  # rotate the order each repetition
				order.append(order.pop_front())
			for mode in order:
				await _sample("compare", rep, view, mode, "")


func _suite_ablate() -> void:
	var ablations: Array = ["", "shadows_off", "veg_no_shadow", "veg_hidden", "terrain_hidden", "river_hidden", "scale_0.5"]
	if not _ablations.is_empty():
		ablations = Array(_ablations).map(func(a: String) -> String: return "" if a == "full" else a)
	var modes: Array = [["none", -1.0], ["baseline", 0.0], ["bias2.0", 2.0]]
	if not _mode_names.is_empty():
		modes = _modes().filter(func(m: Array) -> bool: return _mode_names.has(m[0]))
	for mode in modes:
		_set_mode(mode)
		_place(_views[0])
		await _wait(20)
	for rep in _reps:
		for view in _views:
			var order := ablations.duplicate()
			for k in rep:
				order.append(order.pop_front())
			for ablation in order:
				for mode in modes:
					await _sample("ablate", rep, view, mode, ablation)


func _suite_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	var images := {}
	for view in _views:
		for mode in _modes():
			_set_mode(mode)
			_place(view)
			await _wait(_settle)
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var name := "shot_v%d_%s" % [int(view), mode[0]]
			image.save_png(ProjectSettings.globalize_path(_out).path_join(name + ".png"))
			images[name] = image
	print("[probe] image difference (mean abs per channel 0-255 / % of pixels differing by more than 24):")
	for view in _views:
		for ref in ["none", "baseline"]:
			for mode in _modes():
				if mode[0] == ref:
					continue
				var a: Image = images["shot_v%d_%s" % [int(view), ref]]
				var b: Image = images["shot_v%d_%s" % [int(view), mode[0]]]
				var diff := _image_diff(a, b)
				print("[probe]   view %4d m: %-8s vs %-8s mean %.2f, %.2f %% of pixels > 24" % [int(view), mode[0], ref, diff[0], diff[1]])


## tune: baseline vs adaptive pinned at bias 1.0 (current weights), bias 1.0 (proposed weights + bush/debris densities)
## and bias 2.0 (current weights). Everything is applied at runtime to the loaded scene only. Grass tier densities are
## baked into grass.scn and are not part of this comparison.
const CURRENT_WEIGHTS := {"trees": 0.6, "grass": 1.0, "bushes": 1.0, "debris": 1.25}
const PROPOSED_WEIGHTS := {"trees": 0.4, "grass": 1.0, "bushes": 0.5, "debris": 0.5}
const PROPOSED_DENSITIES := {"bushes": [1.0, 0.75, 0.45, 0.2], "debris": [1.0, 0.7, 0.4]}


func _suite_tune() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	var original_densities := {}
	for category in PROPOSED_DENSITIES:
		original_densities[category] = _manager.policy(category).tier_densities.duplicate()
	var configs := [
		{"name": "baseline", "bias": 0.0, "weights": CURRENT_WEIGHTS, "proposed": false},
		{"name": "cur_b1.0", "bias": 1.0, "weights": CURRENT_WEIGHTS, "proposed": false},
		{"name": "prop_b1.0", "bias": 1.0, "weights": PROPOSED_WEIGHTS, "proposed": true},
		{"name": "cur_b2.0", "bias": 2.0, "weights": CURRENT_WEIGHTS, "proposed": false},
	]
	for cfg in configs:  # warm-up: build everything once
		_apply_tune(cfg, original_densities)
		_set_mode([cfg["name"], cfg["bias"]])
		_place(_views[0])
		await _wait(20)
	var images := {}
	for rep in _reps:
		for view in _views:
			var order := configs.duplicate()
			for k in rep:
				order.append(order.pop_front())
			for cfg in order:
				_apply_tune(cfg, original_densities)
				await _sample("tune", rep, view, [cfg["name"], cfg["bias"]], "")
				if rep == 0:
					await RenderingServer.frame_post_draw
					var image := root.get_texture().get_image()
					image.save_png(ProjectSettings.globalize_path(_out).path_join("tune_v%d_%s.png" % [int(view), cfg["name"]]))
					images["%d_%s" % [int(view), cfg["name"]]] = image
	_apply_tune(configs[0], original_densities)
	print("[probe] image difference against baseline (mean abs per channel / %% of pixels differing by more than 24):")
	for view in _views:
		for cfg in configs.slice(1):
			var diff := _image_diff(images["%d_baseline" % int(view)], images["%d_%s" % [int(view), cfg["name"]]])
			print("[probe]   view %4d m %-10s mean %.2f, %.2f %%" % [int(view), cfg["name"], diff[0], diff[1]])


## smooth: baseline vs the previous adaptive mapping (tree floors off, weights 0.6 / 1 / 1 / 1.25, no onsets, caps at bias_max)
## vs the current mapping (floors, onsets, caps) at pinned global biases 1.0, 1.5 and 2.0. Runtime only.
func _suite_smooth() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	var trees: Node = _manager.policy("trees")
	var current := {"w": _adaptive.category_weights.duplicate(), "o": _adaptive.category_onset.duplicate(), "m": _adaptive.category_max.duplicate(),
			"f1": trees.adaptive_floor_lod1, "f2": trees.adaptive_floor_lod2}
	var legacy := {"w": {"trees": 0.6, "grass": 1.0, "bushes": 1.0, "debris": 1.25}, "o": {}, "m": {"trees": 2.0, "grass": 2.0, "bushes": 2.0, "debris": 2.0}, "f1": 0.0, "f2": 0.0}
	var configs := [
		{"name": "baseline", "bias": 0.0, "set": current},
		{"name": "old_b2.0", "bias": 2.0, "set": legacy},
		{"name": "new_b1.0", "bias": 1.0, "set": current},
		{"name": "new_b1.5", "bias": 1.5, "set": current},
		{"name": "new_b2.0", "bias": 2.0, "set": current},
	]
	for cfg in configs:
		_apply_smooth(cfg["set"], trees)
		_set_mode([cfg["name"], cfg["bias"]])
		_place(_views[0])
		await _wait(20)
	var images := {}
	for rep in _reps:
		for view in _views:
			var order := configs.duplicate()
			for k in rep:
				order.append(order.pop_front())
			for cfg in order:
				_apply_smooth(cfg["set"], trees)
				await _sample("smooth", rep, view, [cfg["name"], cfg["bias"]], "")
				if rep == 0:
					await RenderingServer.frame_post_draw
					var image := root.get_texture().get_image()
					image.save_png(ProjectSettings.globalize_path(_out).path_join("smooth_v%d_%s.png" % [int(view), cfg["name"]]))
					images["%d_%s" % [int(view), cfg["name"]]] = image
	_apply_smooth(current, trees)
	print("[probe] image difference against baseline (mean abs per channel / %% of pixels differing by more than 24):")
	for view in _views:
		for cfg in configs.slice(1):
			var diff := _image_diff(images["%d_baseline" % int(view)], images["%d_%s" % [int(view), cfg["name"]]])
			print("[probe]   view %4d m %-9s mean %.2f, %.2f %%" % [int(view), cfg["name"], diff[0], diff[1]])


func _apply_smooth(setting: Dictionary, trees: Node) -> void:
	_adaptive.category_weights = setting["w"]
	_adaptive.category_onset = setting["o"]
	_adaptive.category_max = setting["m"]
	trees.adaptive_floor_lod1 = setting["f1"]
	trees.adaptive_floor_lod2 = setting["f2"]
	for policy in _manager.policies():
		policy.request_resync()


func _apply_tune(cfg: Dictionary, original_densities: Dictionary) -> void:
	_adaptive.category_weights = cfg["weights"]
	for category in PROPOSED_DENSITIES:
		var policy: Node = _manager.policy(category)
		policy.tier_densities = PackedFloat32Array(PROPOSED_DENSITIES[category] if cfg["proposed"] else original_densities[category])
		policy._setup_tiers()
	for policy in _manager.policies():
		policy.request_resync()


func _image_diff(a: Image, b: Image) -> Array:
	var da := a.get_data()
	var db := b.get_data()
	var bytes := mini(da.size(), db.size())
	var total := 0
	var over := 0
	var pixels := bytes / 4 if a.get_format() == Image.FORMAT_RGBA8 else bytes / 3
	var stride := 4 if a.get_format() == Image.FORMAT_RGBA8 else 3
	for p in range(0, pixels, 3):  # every third pixel is plenty for a statistic
		var worst := 0
		for c in 3:
			var d := absi(da[p * stride + c] - db[p * stride + c])
			total += d
			worst = maxi(worst, d)
		if worst > 24:
			over += 1
	var counted := ceili(pixels / 3.0)
	return [float(total) / (counted * 3), 100.0 * over / counted]


## mode = [name, bias]: bias < 0 = none, 0 = baseline, > 0 = adaptive pinned at that bias with the controller held.
func _set_mode(mode: Array) -> void:
	var bias: float = mode[1]
	if bias < 0.0:
		_manager.set_mode("none")
	elif bias == 0.0:
		_manager.set_mode("baseline")
	else:
		_manager.set_mode("adaptive")
		_adaptive.hold = true
		_adaptive.controller.reset(bias)
		_adaptive.bias = bias
		_adaptive._apply_bias()


func _place(distance: float) -> void:
	_camera.global_transform = _path.sample(distance)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _sample(suite: String, rep: int, view: float, mode: Array, ablation: String) -> void:
	_set_mode(mode)
	_place(view)
	_apply_ablation(ablation, true)
	await _wait(_settle)
	var gpu: Array[float] = []
	var sums := {"frame": 0.0, "cpu": 0.0, "draw_main": 0.0, "draw_all": 0.0, "prim_main": 0.0, "prim_all": 0.0, "objects": 0.0, "policy": 0.0}
	var last := Time.get_ticks_usec()
	var counted := 0
	for i in _frames:
		await process_frame
		var now := Time.get_ticks_usec()
		var m: Dictionary = _sampler.sample()
		if m["render_gpu_ms"] != null:
			gpu.append(m["render_gpu_ms"])
		sums["frame"] += (now - last) / 1000.0
		sums["cpu"] += m["render_cpu_ms"] if m["render_cpu_ms"] != null else 0.0
		sums["draw_main"] += m["draw_calls_visible"] if m["draw_calls_visible"] != null else 0
		sums["draw_all"] += m["draw_calls"] if m["draw_calls"] != null else 0
		sums["prim_main"] += m["primitives_visible"] if m["primitives_visible"] != null else 0
		sums["prim_all"] += m["primitives"] if m["primitives"] != null else 0
		sums["objects"] += m["objects"] if m["objects"] != null else 0
		for p in _manager.policies():
			if p.enabled and p.is_built():
				sums["policy"] += p.last_update_ms
		last = now
		counted += 1
	if OS.get_environment("PROBE_DEBUG") != "":
		print("[probe] raw gpu ", gpu.slice(0, 40))
	gpu.sort()
	var n := float(counted)
	var gpu_mean := 0.0
	for g in gpu:
		gpu_mean += g
	gpu_mean /= maxf(gpu.size(), 1)
	var trees: PackedInt32Array = _manager.policy("trees").level_counts()
	var row := [suite, rep, view, mode[0], ablation, counted,
			gpu[gpu.size() / 2] if not gpu.is_empty() else null, gpu_mean if not gpu.is_empty() else null,
			gpu[int(gpu.size() * 0.95)] if not gpu.is_empty() else null, sums["frame"] / n, sums["cpu"] / n,
			sums["draw_main"] / n, sums["draw_all"] / n, sums["prim_main"] / n, sums["prim_all"] / n, sums["objects"] / n,
			trees[0], trees[1], trees[2], _manager.policy("grass").instance_drawn(), _manager.policy("bushes").instance_drawn(),
			_manager.policy("debris").instance_drawn(), sums["policy"] / n, root.size.x, root.size.y]
	_rows.append(row)
	_apply_ablation(ablation, false)
	print("[probe] gpu min %.2f max %.2f" % [gpu[0] if not gpu.is_empty() else -1.0, gpu[-1] if not gpu.is_empty() else -1.0])
	print("[probe] %s rep%d view %4d m %-8s %-14s gpu %.2f ms (p95 %.2f) frame %.2f draw %d/%d prim %.2fM/%.2fM policy %.2f ms" % [
			suite, rep, int(view), mode[0], ablation, row[6] if row[6] != null else -1.0, row[8] if row[8] != null else -1.0, row[9],
			row[11], row[12], row[13] / 1e6, row[14] / 1e6, row[22]])


func _apply_ablation(ablation: String, on: bool) -> void:
	match ablation:
		"shadows_off":
			_sun.shadow_enabled = not on
		"veg_no_shadow":
			_set_cast_shadows(not on)
		"veg_hidden":
			_env.get_node("Vegetation").visible = not on
			_env.get_node("GrassField").visible = not on
		"terrain_hidden":
			_terrain.visible = not on
		"river_hidden":
			_env.get_node("River").visible = not on
		"scale_0.5":
			root.scaling_3d_scale = 0.5 if on else 1.0
		"hide_trees", "hide_bushes", "hide_debris", "hide_rocks":
			_hide_kind({"hide_trees": "tree", "hide_bushes": "bush", "hide_debris": "debris", "hide_rocks": "rock"}[ablation], on)
		"hide_grass":
			_env.get_node("GrassField").visible = not on
		"hide_tree_l0", "hide_tree_l1", "hide_tree_l2":
			_hide_kind("tree", on, int(ablation.right(1)))


func _hide_kind(kind: String, on: bool, level := -1) -> void:
	for node in _env.get_node("Vegetation").find_children("*", "MultiMeshInstance3D", true, false):
		var instance := node as MultiMeshInstance3D
		if instance.get_meta("vegetation_kind", "") != kind:
			continue
		if level >= 0 and int(instance.get_meta("lod_level", 0)) != level:
			continue
		if on:
			_hidden_backup[instance.get_instance_id()] = instance.visible
			instance.visible = false
		elif _hidden_backup.has(instance.get_instance_id()):
			instance.visible = _hidden_backup[instance.get_instance_id()]


func _set_cast_shadows(restore: bool) -> void:
	for top in ["Vegetation", "GrassField"]:
		for node in _env.get_node(top).find_children("*", "GeometryInstance3D", true, false):
			var geometry := node as GeometryInstance3D
			if restore:
				if _shadow_backup.has(geometry.get_instance_id()):
					geometry.cast_shadow = _shadow_backup[geometry.get_instance_id()]
			else:
				_shadow_backup[geometry.get_instance_id()] = geometry.cast_shadow
				geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _save() -> void:
	if _rows.is_empty():
		return
	var directory := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp := Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "-")
	var file := FileAccess.open(directory.path_join("probe_%s_%s.csv" % [_suite, stamp]), FileAccess.WRITE)
	file.store_line(",".join(COLUMNS))
	for row in _rows:
		var cells := PackedStringArray()
		for v in row:
			cells.append("" if v == null else (String.num(v, 4) if v is float else str(v)))
		file.store_line(",".join(cells))
	file.close()
	print("[probe] wrote %s" % file.get_path())
