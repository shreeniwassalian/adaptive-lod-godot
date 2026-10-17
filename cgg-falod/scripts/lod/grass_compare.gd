extends SceneTree
## Renders the same camera poses with different grass configurations and records render statistics (real renderer):
##   Godot_console.exe --path . --script res://scripts/lod/grass_compare.gd -- shots=<dir> [old=<path to an earlier grass.scn>]
## Configurations: legacy tufts, the earlier v2 field (only with old=), the current field at full detail, the current
## field with distance LOD. Each pose is held for a settle period, then draw calls, primitives and GPU frame time are
## averaged over a fixed number of frames. Wind is switched off so the frames are comparable.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const VIEW_CELL := "Cell_17_17"
const MEASURE_FRAMES := 60

var _env: Node3D
var _terrain: Terrain3D
var _grass: Node
var _camera: Camera3D
var _old_field: Node3D
var _shots := ""


func _initialize() -> void:
	var old_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("shots="):
			_shots = a.trim_prefix("shots=")
		elif a.begins_with("old="):
			old_path = a.trim_prefix("old=")
	_env = (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(_env)
	_terrain = _env.get_node("Terrain3D")
	_grass = _env.get_node("GrassLod")
	_env.get_node("VegetationLod").enabled = false
	_env.get_node("LodDebugPanel").queue_free()
	for i in 6:
		await physics_frame
	_env.get_node("Player").process_mode = Node.PROCESS_MODE_DISABLED
	_env.get_node("Player").visible = false
	_camera = Camera3D.new()
	_camera.far = 3000.0
	_camera.fov = 70.0
	root.add_child(_camera)
	_camera.make_current()
	_terrain.set_camera(_camera)
	_grass.wind_strength = 0.0
	if old_path != "":
		_old_field = (ResourceLoader.load(old_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
		_old_field.visible = false
		_env.add_child(_old_field)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)

	var field := _env.get_node("GrassField")
	var cell := field.get_node(VIEW_CELL)
	var centre := ((cell.get_meta("cell_min") as Vector3) + (cell.get_meta("cell_max") as Vector3)) * 0.5
	var ground := func(x: float, z: float) -> float: return _terrain.data.get_height(Vector3(x, 0, z))
	var poses := {
		"close": [Vector3(centre.x - 3.0, ground.call(centre.x - 3.0, centre.z) + 1.6, centre.z), centre + Vector3(8, 0, 0)],
		"low": [Vector3(centre.x - 2.0, ground.call(centre.x - 2.0, centre.z) + 0.45, centre.z), centre + Vector3(8, 0.2, 0)],
		"mid": [Vector3(centre.x - 28.0, ground.call(centre.x - 28.0, centre.z) + 2.2, centre.z), centre],
		"far": [Vector3(centre.x - 2.0, ground.call(centre.x - 2.0, centre.z + 85.0) + 9.0, centre.z + 85.0), centre],
	}
	var configs: Array = ["legacy"]
	if _old_field != null:
		configs.append("v2_before")
	configs.append_array(["v2_full", "v2_lod"])
	for cfg in configs:
		_apply(cfg)
		for pose in poses:
			_camera.global_position = poses[pose][0]
			_camera.look_at(poses[pose][1], Vector3.UP)
			if cfg == "v2_lod":
				_grass.resync()
			for i in 20:
				await process_frame
			var image := await _grab()
			image.save_png("%s/%s_%s.png" % [_shots, pose, cfg])
			var draw := 0.0
			var prims := 0.0
			var gpu := 0.0
			for i in MEASURE_FRAMES:
				await process_frame
				draw += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
				prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			print("[grass-compare] %s/%s: draw calls %.0f, primitives %.2fM, GPU %.2f ms" % [
					pose, cfg, draw / MEASURE_FRAMES, prims / MEASURE_FRAMES / 1e6, gpu / MEASURE_FRAMES])
	quit(0)


func _apply(cfg: String) -> void:
	if _old_field != null:
		_old_field.visible = cfg == "v2_before"
	match cfg:
		"legacy":
			_grass.style = 0
		"v2_before":
			_grass.style = 0  # legacy tufts and the new field both off: hide the legacy nodes too
			for node in _grass._legacy_nodes:
				node.visible = false
		"v2_full":
			_grass.style = 1
			_grass.lod_enabled = false
		"v2_lod":
			_grass.style = 1
			_grass.lod_enabled = true


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
