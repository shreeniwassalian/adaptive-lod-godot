extends SceneTree
## Checks the baseline vegetation LOD in the real environment scene (needs a real renderer, not --headless):
##   Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd [-- nolod] [-- shots=<dir>]
## 1. Gameplay: the controller follows the player's camera, trees switch levels as the player is moved,
##    every tree stays drawn exactly once, and the player still stands on the ground.
## 2. Collision: rays at tree trunks hit the same bodies whatever the LOD state.
## 3. Benchmark-style camera: integrity along the scripted path, plus optional screenshots.
## `nolod` leaves the controller disabled (baked scene) so screenshots can be compared with the LOD ones.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const PROP_LAYER := 4

var _failures := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var lod_on := not "nolod" in args
	var shots_dir := ""
	for a in args:
		if a.begins_with("shots="):
			shots_dir = a.trim_prefix("shots=")

	var env: Node3D = (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(env)
	var lod := env.get_node("VegetationLod")
	lod.enabled = lod_on
	var terrain := env.get_node("Terrain3D") as Terrain3D
	var player := env.get_node("Player")
	for i in 40:
		await physics_frame
	await process_frame

	# 1. Gameplay camera and player movement
	_check(root.get_viewport().get_camera_3d() == player.get_camera(), "gameplay: active camera is the player's camera")
	_check(player.is_on_floor(), "gameplay: player stands on the ground after spawn")
	var spots := [Vector2(-300, -250), Vector2(250, 300), Vector2(-100, 350), Vector2(300, -300)]
	var last_counts := PackedInt32Array()
	var changed := 0
	if lod_on:
		_check(lod.is_built(), "gameplay: controller built itself on the first frame")
		last_counts = lod.level_counts()
		print("[selftest] spawn level counts: %s total_switches=%d" % [last_counts, lod.total_switches])
	for spot in spots:
		var ground := terrain.data.get_height(Vector3(spot.x, 0.0, spot.y))
		player.place_at(Vector3(spot.x, ground + 1.0, spot.y), 0.0)
		# Terrain3D streams collision in around the camera, so give it time to arrive.
		# is_on_floor() is stale until the next physics step, so fall for a few frames, then require a stable floor.
		for i in 5:
			await physics_frame
		var settled := 5
		var stable := 0
		while settled < 300 and stable < 10:
			await physics_frame
			settled += 1
			stable = stable + 1 if player.is_on_floor() else 0
		await process_frame
		var line := "[selftest] player at %s: on_floor=%s after %d physics frames" % [spot, player.is_on_floor(), settled]
		_check(player.is_on_floor(), "gameplay: player on ground at %s" % spot)
		if lod_on:
			var counts: PackedInt32Array = lod.level_counts()
			if counts != last_counts:
				changed += 1
			last_counts = counts
			var err: String = lod.verify()
			line += " levels %s switches_total=%d integrity=%s" % [counts, lod.total_switches, "ok" if err.is_empty() else err]
			_check(err.is_empty(), "gameplay: integrity at %s" % spot)
		print(line)
	if lod_on:
		_check(changed >= 3, "gameplay: level counts changed when the player moved (%d of 4 moves)" % changed)
		_check(lod.total_switches > 0, "gameplay: switches were counted")

	# 2. Collision independent of LOD
	var space := root.get_world_3d().direct_space_state
	var trunks: Array[Vector3] = []
	var set_chunks: Array = lod._lod_set.chunks if lod_on else []
	if lod_on:
		for chunk in set_chunks:
			for group in chunk.groups:
				if group.count > 0 and trunks.size() < 40 and chunk.node.get_index() % 6 == 0:
					trunks.append(group.transforms[0].origin)
	var hits_a := _trunk_hits(space, trunks)
	var spot_b := Vector3(trunks[0].x + 40.0, terrain.data.get_height(Vector3(trunks[0].x + 40.0, 0, trunks[0].z)) + 1.0, trunks[0].z) if lod_on else Vector3.ZERO
	if lod_on:
		player.place_at(spot_b, 0.0)
		for i in 20:
			await physics_frame
		await process_frame
	var hits_b := _trunk_hits(space, trunks)
	if lod_on:
		_check(hits_a == hits_b, "collision: trunk ray results identical after LOD changes")
		_check(hits_a.count(true) >= trunks.size() * 0.9, "collision: trunk rays hit (%d of %d)" % [hits_a.count(true), trunks.size()])
		print("[selftest] trunk ray hits %d/%d before and %d/%d after LOD changes" % [
				hits_a.count(true), trunks.size(), hits_b.count(true), trunks.size()])

	# 3. Scripted camera along the benchmark path
	var path := CameraPath.new()
	var path_error: String = path.build(terrain, 2.0, -6.0)
	_check(path_error.is_empty(), "path builds: %s" % path_error)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	var camera := Camera3D.new()
	camera.far = 3000.0
	root.add_child(camera)
	camera.make_current()
	terrain.set_camera(camera)
	var shot_poses := [0.0, 150.0, 330.0]
	var distance := 0.0
	while distance < path.length:
		camera.global_transform = path.sample(distance)
		await process_frame
		await process_frame
		if lod_on and int(distance) % 100 == 0:
			var err2: String = lod.verify()
			_check(err2.is_empty(), "path: integrity at %.0f m: %s" % [distance, err2])
		if shots_dir != "" and shot_poses.has(distance):
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			img.save_png("%s/%s_%03d.png" % [shots_dir, "lod" if lod_on else "nolod", int(distance)])
		distance += 10.0
	if lod_on:
		print("[selftest] path done: levels %s total_switches=%d" % [lod.level_counts(), lod.total_switches])

	print("[selftest] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _trunk_hits(space: PhysicsDirectSpaceState3D, trunks: Array[Vector3]) -> Array[bool]:
	var result: Array[bool] = []
	for p in trunks:
		var query := PhysicsRayQueryParameters3D.create(p + Vector3(3.0, 1.5, 0.0), p + Vector3(0.0, 1.5, 0.0), PROP_LAYER)
		result.append(not space.intersect_ray(query).is_empty())
	return result


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
	print("[selftest] %s %s" % ["ok  " if ok else "FAIL", message])
