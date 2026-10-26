extends SceneTree
## Measures the wall time of every frame around the first switch to a LOD mode in the real environment scene
## (needs a real renderer). Reports the longest frame in the window after set_mode(), i.e. the first-enable stall.
##   Godot_console.exe --path . --script res://results/t1/stall_probe.gd [-- prebuild]
## With `prebuild` it first calls LodManager.prebuild() (if the method exists), then does the same measurement.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")


func _initialize() -> void:
	var use_prebuild := OS.get_cmdline_user_args().has("prebuild")
	var env := (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(env)
	var terrain := env.get_node("Terrain3D") as Terrain3D
	var manager := env.get_node("LodManager")
	for i in 6:
		await physics_frame
	env.get_node("Player").process_mode = Node.PROCESS_MODE_DISABLED
	env.get_node("Player").visible = false
	var path := CameraPath.new()
	path.build(terrain, 2.0, -6.0)
	var camera := Camera3D.new()
	camera.far = 3000.0
	root.add_child(camera)
	camera.make_current()
	terrain.set_camera(camera)
	camera.global_transform = path.sample(0.0)
	await _frames(20, null, "", 0.0)  # settle
	if use_prebuild:
		if manager.has_method("prebuild"):
			var t0 := Time.get_ticks_usec()
			manager.prebuild()
			print("[probe] prebuild() call took %.0f ms (this is load time, not a rendered frame)" % ((Time.get_ticks_usec() - t0) / 1000.0))
		else:
			print("[probe] LodManager has no prebuild(): measuring without")
	await _frames(20, null, "", 0.0)
	for mode in ["baseline", "none", "adaptive", "none", "adaptive"]:
		var worst := await _frames(12, manager, mode, 0.0)
		print("[probe] set_mode(%s): longest frame in the next 12 frames = %.1f ms" % [mode, worst])
		await _frames(20, null, "", 0.0)
	quit(0)


## Runs `count` frames; sets the mode before the first one. Returns the longest frame time in ms.
func _frames(count: int, manager: Node, mode: String, _unused: float) -> float:
	var worst := 0.0
	if manager != null:
		manager.set_mode(mode)
	var last := Time.get_ticks_usec()
	for i in count:
		await process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
	return worst
