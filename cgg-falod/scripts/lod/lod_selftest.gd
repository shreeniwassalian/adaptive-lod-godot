extends SceneTree
## Checks the baseline vegetation LOD in the real environment scene (needs a real renderer, not --headless):
##   Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd [-- nolod] [-- shots=<dir>]
## 1. Gameplay: the controller follows the player's camera, trees switch levels as the player is moved,
##    every tree stays drawn exactly once, and the player still stands on the ground.
## 2. Collision: rays at tree trunks hit the same bodies whatever the LOD state.
## 3. Benchmark-style camera: integrity along the scripted path, plus optional screenshots.
## 4. Debug panel (LOD on only): F3/F4, the None/Baseline buttons, displayed counters, mode round trips.
## `restored` runs the panel round trips, then disables the LOD for the path screenshots (compare with `nolod`).
## `nolod` leaves the controller disabled (baked scene) so screenshots can be compared with the LOD ones.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const PROP_LAYER := 4

var _failures := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var lod_on := not "nolod" in args
	var restored := "restored" in args
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

	if lod_on:
		await _test_panel(env, lod, player, terrain, shots_dir)

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
	if restored and lod_on:
		lod.enabled = false  # shots now show the baked scene restored after the mode round trips
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
			img.save_png("%s/%s_%03d.png" % [shots_dir, "restored" if restored else ("lod" if lod_on else "nolod"), int(distance)])
		distance += 10.0
	if lod_on:
		print("[selftest] path done: levels %s total_switches=%d" % [lod.level_counts(), lod.total_switches])

	print("[selftest] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _test_panel(env: Node, lod: Node, player: Node, terrain: Terrain3D, shots_dir: String) -> void:
	var panel := env.get_node("LodDebugPanel")
	var none_button := panel.find_child("NoneButton", true, false) as Button
	var baseline_button := panel.find_child("AdaptiveButton", true, false) as Button  # Baseline is not offered in the panel
	_check(panel.find_child("BaselineButton", true, false) == null, "panel: no Baseline button")
	var total: int = lod._lod_set.tree_instances
	_check(not panel.is_panel_visible(), "panel: hidden by default")
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "panel: mouse captured before opening")
	_key(KEY_F3)
	await create_timer(0.5).timeout
	_check(panel.is_panel_visible(), "panel: F3 shows it")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "panel: cursor released while shown")
	await _check_panel_matches(panel, lod, "Adaptive", "initial")
	var text: String = panel.get_text()
	print("[selftest] panel text:\n" + text)
	_check(text.contains("Thresholds  60 / 150 m, hysteresis 10 m"), "panel: thresholds shown")
	var fps := _number_after(text, "FPS")
	_check(fps > 1.0, "panel: FPS shown (%.1f)" % fps)
	_check(_number_after(text, "Frame time") > 0.0, "panel: frame time shown")

	# None: baked vegetation restored
	var before_switches: int = lod.total_switches
	none_button.pressed.emit()
	await create_timer(0.5).timeout
	_check(not lod.enabled, "panel: None button disables the LOD")
	_check(lod.level_counts() == PackedInt32Array([total, 0, 0]), "panel: None restores all %d trees to level 0" % total)
	_check(lod.verify().is_empty(), "panel: integrity after None: %s" % lod.verify())
	_check(lod.total_switches == before_switches, "panel: restore does not count as switches")
	for chunk in lod._lod_set.chunks:
		for group in chunk.groups:
			if group.nodes[1].visible or group.nodes[2].visible or group.nodes[0].multimesh.visible_instance_count != group.count:
				_check(false, "panel: %s/%s not fully restored" % [chunk.node.name, group.name])
				break
	await _check_panel_matches(panel, lod, "None", "None mode")
	# The player must not influence the vegetation while the LOD is off.
	var ground := terrain.data.get_height(Vector3(-150, 0, 100))
	player.place_at(Vector3(-150, ground + 1.0, 100), 0.0)
	await create_timer(0.5).timeout
	_check(lod.level_counts() == PackedInt32Array([total, 0, 0]), "panel: levels stay baked while None and the camera moves")

	# Adaptive again
	baseline_button.pressed.emit()
	await create_timer(0.5).timeout
	var counts: PackedInt32Array = lod.level_counts()
	_check(lod.enabled and counts[0] < total and counts[1] + counts[2] > 0, "panel: Adaptive button re-enables the LOD %s" % counts)
	# Immediately after a click (a few frames, not the refresh interval) the label and numbers must agree.
	none_button.pressed.emit()
	await process_frame
	await process_frame
	await _check_panel_matches(panel, lod, "None", "2 frames after None", 0.0)
	baseline_button.pressed.emit()
	await process_frame
	await process_frame
	await _check_panel_matches(panel, lod, "Adaptive", "2 frames after Adaptive", 0.0)
	counts = lod.level_counts()
	_check(counts[0] + counts[1] + counts[2] == total, "panel: tree total unchanged (%d)" % total)
	_check(lod.verify().is_empty(), "panel: integrity after Adaptive: %s" % lod.verify())
	await _check_panel_matches(panel, lod, "Adaptive", "Adaptive mode")

	# Counters follow camera movement
	var switches_before: int = lod.total_switches
	var spot := Vector2(60, -120)
	player.place_at(Vector3(spot.x, terrain.data.get_height(Vector3(spot.x, 0, spot.y)) + 1.0, spot.y), 0.0)
	await create_timer(0.6).timeout
	_check(lod.total_switches > switches_before, "panel: switches counted after moving (%d -> %d)" % [switches_before, lod.total_switches])
	await _check_panel_matches(panel, lod, "Adaptive", "after moving")

	# F4 and repeated round trips keep every tree
	# F4 toggles Adaptive <-> None (adaptive keeps the tree policy enabled)
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(not lod.enabled, "panel: F4 switches Adaptive to None")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(lod.enabled and env.get_node("LodManager").mode() == "adaptive", "panel: F4 switches back to Adaptive")
	for i in 5:
		none_button.pressed.emit()
		await process_frame
		await process_frame
		baseline_button.pressed.emit()
		await process_frame
		await process_frame
		await process_frame
	var round_trip: PackedInt32Array = lod.level_counts()
	_check(round_trip[0] + round_trip[1] + round_trip[2] == total, "panel: 5 round trips keep all %d trees" % total)
	_check(lod.verify().is_empty(), "panel: integrity after round trips: %s" % lod.verify())

	if shots_dir != "":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("%s/panel.png" % shots_dir)
	_key(KEY_F3)
	await process_frame
	await process_frame
	_check(not panel.is_panel_visible(), "panel: F3 hides it")
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "panel: mouse captured again after hiding")


## The panel text must show the controller's current mode and numbers.
func _check_panel_matches(panel: Node, lod: Node, mode: String, context: String, wait_s: float = 0.4) -> void:
	if wait_s > 0.0:
		await create_timer(wait_s).timeout
	var text: String = panel.get_text()
	var counts: PackedInt32Array = lod.level_counts()
	var ok := text.contains("Mode        %s" % mode) and text.contains("Trees LOD0  %d\n" % counts[0]) \
			and text.contains("Trees LOD1  %d\n" % counts[1]) and text.contains("Trees LOD2  %d\n" % counts[2]) \
			and text.contains("LOD switches %d " % lod.total_switches)
	_check(ok, "panel shows controller state (%s): mode=%s counts=%s switches=%d" % [context, mode, counts, lod.total_switches])
	if not ok:
		print(text)


func _number_after(text: String, label: String) -> float:
	var regex := RegEx.create_from_string(label + "\\s+([0-9.]+)")
	var m := regex.search(text)
	return m.get_string(1).to_float() if m != null else -1.0


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)


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
