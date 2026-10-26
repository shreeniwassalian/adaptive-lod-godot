extends SceneTree
## Checks the procedural grass field and its LOD controller in the real environment (needs a real renderer):
##   Godot_console.exe --path . --script res://scripts/lod/grass_selftest.gd [-- shots=<dir>] [-- skip-determinism]
## Structure and tier nesting, determinism (the saved scene equals a fresh build), terrain conformity, style and
## tier switching with the integrity check, hysteresis, and measured popping when one cell changes tier. With
## shots=<dir> it also writes legacy / v2 comparison images, per-tier images and overdraw visualisations.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const GrassBuilder := preload("res://scripts/world/grass_builder.gd")
const GrassMeshes := preload("res://scripts/world/grass_meshes.gd")
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")

## Meadow near the spawn, used for the comparison views.
const VIEW_CELL := "Cell_17_17"

var _failures := 0
var _env: Node3D
var _terrain: Terrain3D
var _grass: Node
var _camera: Camera3D
var _shots := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("shots="):
			_shots = a.trim_prefix("shots=")
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

	var field := _env.get_node("GrassField")
	_test_structure(field)
	_test_nesting_and_conformity(field)
	if not "skip-determinism" in args:
		await _test_determinism(field)
	await _test_switching()
	await _test_hysteresis(field)
	await _test_popping(field)
	if _shots != "":
		await _write_shots(field)
	print("[grass-test] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _test_structure(field: Node) -> void:
	var cells := 0
	var nodes := 0
	var totals := [0, 0, 0]
	var meta_ok := true
	for cell in field.get_children():
		cells += 1
		var counts: PackedInt32Array = cell.get_meta("clumps")
		var per_tier := [0, 0, 0]
		for node in cell.get_children():
			var m := node as MultiMeshInstance3D
			nodes += 1
			per_tier[int(m.get_meta("grass_tier"))] += m.multimesh.instance_count
			if m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or not m.multimesh.use_colors:
				meta_ok = false
			if m.visible != (int(m.get_meta("grass_tier")) == 0):
				meta_ok = false  # the saved scene must be full detail: tier 0 visible only
		for t in 3:
			if per_tier[t] != counts[t]:
				meta_ok = false
			totals[t] += per_tier[t]
	_check(meta_ok, "structure: per-cell clump metadata matches the nodes, tier 0 visible, no shadows, instance colours")
	# About 13 nodes per cell (tufts and turf, variants per tier); the limit only guards against per-clump nodes.
	_check(nodes < 20000,"structure: %d MultiMesh nodes for %d cells (no per-clump nodes)" % [nodes, cells])
	var tris := [0, 0, 0]
	var kinds := {"tuft": 0, "turf": 0}
	for cell in field.get_children():
		for node in cell.get_children():
			var m := node as MultiMeshInstance3D
			var tier := int(m.get_meta("grass_tier"))
			var kind: int = GrassMeshes.TUFT if m.get_meta("grass_kind") == "tuft" else GrassMeshes.TURF
			kinds[m.get_meta("grass_kind")] += m.multimesh.instance_count
			tris[tier] += m.multimesh.instance_count * GrassMeshes.triangle_count(tier, kind)
	print("[grass-test] cells=%d nodes=%d clumps per tier=%s tuft/turf clumps=%s triangles per tier if all drawn=%s" % [cells, nodes, totals, kinds, tris])
	print("[grass-test] full-detail triangles %.2fM (legacy grass: %.2fM)" % [tris[0] / 1e6, 22320 * 27 / 1e6])


## Tier 1 is a subset of tier 0 and tier 2 of tier 1; clumps sit on the terrain, lean with it, and nothing floats.
func _test_nesting_and_conformity(field: Node) -> void:
	var nested := true
	var checked := 0
	var max_float := -1.0e9
	var max_sink := 1.0e9
	var worst_up := 1.0
	for cell in field.get_children():
		var sets: Array = [{}, {}, {}]
		for node in cell.get_children():
			var m := node as MultiMeshInstance3D
			var tier := int(m.get_meta("grass_tier"))
			for i in m.multimesh.instance_count:
				var xform := m.multimesh.get_instance_transform(i)
				sets[tier][xform.origin] = true
				if tier == 0 and checked < 30000 and randi() % 4 == 0:
					checked += 1
					var ground := _terrain.data.get_height(xform.origin)
					max_float = maxf(max_float, xform.origin.y - ground)
					max_sink = minf(max_sink, xform.origin.y - ground)
					var normal := _terrain.data.get_normal(xform.origin)
					worst_up = minf(worst_up, xform.basis.y.normalized().dot(normal))
		for origin in sets[1]:
			if not sets[0].has(origin):
				nested = false
		for origin in sets[2]:
			if not sets[1].has(origin):
				nested = false
	_check(nested, "nesting: every tier-2 clump is a tier-1 clump and every tier-1 clump is a tier-0 clump")
	_check(max_float < 0.0, "conformity: no sampled clump base above the terrain data (highest %.3f m)" % max_float)
	_check(max_sink > -0.06, "conformity: no sampled clump sunk more than 6 cm (deepest %.3f m, %d sampled)" % [max_sink, checked])
	_check(worst_up > 0.5, "conformity: clump axes stay near the surface normal (worst dot %.2f)" % worst_up)


## The saved scene must equal a fresh build from the same seed and terrain: repeatable placement.
func _test_determinism(field: Node) -> void:
	var builder := GrassBuilder.new()
	builder.model = _env.get_model()
	builder.terrain = _terrain
	builder.seed_value = _env.world_seed
	builder.world_size = _env.world_size()
	var fresh := builder.build()
	root.add_child(fresh)
	fresh.visible = false
	var same_cells := fresh.get_child_count() == field.get_child_count()
	var saved_hash := _field_hash(field)
	var fresh_hash := _field_hash(fresh)
	fresh.queue_free()
	await process_frame
	_check(same_cells and saved_hash == fresh_hash, "determinism: a fresh build equals the saved grass.scn (cells %s, hash %s)" % [same_cells, saved_hash.substr(0, 12)])


func _field_hash(field: Node) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for cell in field.get_children():
		ctx.update(String(cell.name).to_utf8_buffer())
		for node in cell.get_children():
			ctx.update((node as MultiMeshInstance3D).multimesh.buffer.to_byte_array())
	return ctx.finish().hex_encode()


## Style and LOD switching keep every cell on exactly one tier, and the legacy grass comes back intact.
func _test_switching() -> void:
	_grass.style = 1
	_grass.lod_enabled = false
	_place_camera(Vector3(47.8, 20.0, 47.7), Vector3(60, 14, 47.7))
	await _frames(5)
	_check(_grass.verify().is_empty(), "switching: v2 / LOD off integrity: %s" % _grass.verify())
	var full: PackedInt32Array = _grass.tier_clump_counts()
	_check(full[1] == 0 and full[2] == 0 and full[0] > 100000, "switching: LOD off draws every clump at tier 0 %s" % full)
	_grass.lod_enabled = true
	await _frames(5)
	var tiers: PackedInt32Array = _grass.tier_clump_counts()
	var cells: PackedInt32Array = _grass.cell_tier_counts()
	_check(_grass.verify().is_empty(), "switching: LOD on integrity: %s" % _grass.verify())
	_check(cells[0] > 0 and cells[1] > 0 and cells[2] > 0 and cells[3] > 0, "switching: all tiers and culling are in use %s cells" % cells)
	print("[grass-test] LOD on at the spawn meadow: clumps per tier %s, cells per tier %s (T0, T1, T2, culled)" % [tiers, cells])
	_grass.style = 0
	await _frames(3)
	_check(_grass.verify().is_empty(), "switching: legacy style integrity: %s" % _grass.verify())
	_check(_grass.tier_clump_counts()[0] == 22320, "switching: legacy shows its 22320 original tufts (%d)" % _grass.tier_clump_counts()[0])
	_grass.style = 1
	await _frames(3)
	_check(_grass.verify().is_empty(), "switching: back to v2 integrity: %s" % _grass.verify())
	# Walk the benchmark path.
	var path := CameraPath.new()
	_check(path.build(_terrain, 2.0, -6.0).is_empty(), "switching: benchmark path builds")
	var distance := 0.0
	var switches_before: int = _grass.total_switches
	var bad := ""
	while distance < path.length:
		_camera.global_transform = path.sample(distance)
		await _frames(2)
		var err: String = _grass.verify()
		if not err.is_empty():
			bad = "at %.0f m: %s" % [distance, err]
			break
		distance += 8.0
	_check(bad.is_empty(), "switching: integrity along the whole benchmark path %s" % bad)
	_check(_grass.total_switches > switches_before, "switching: cells changed tier along the path (%d switches)" % (_grass.total_switches - switches_before))


## A camera jittering inside a threshold's dead band must not make a cell flip.
func _test_hysteresis(field: Node) -> void:
	_grass.lod_enabled = true
	var cell := field.get_node(VIEW_CELL)
	var mn: Vector3 = cell.get_meta("cell_min")
	var mx: Vector3 = cell.get_meta("cell_max")
	var mid_z := (mn.z + mx.z) * 0.5
	var y := (mn.y + mx.y) * 0.5
	var t1: float = _grass.tier1_distance
	var h: float = _grass.hysteresis
	# Start well past the band (tier 1), then jitter between t1 + 3 and t1 - 3 (both inside the dead band).
	_place_camera(Vector3(mn.x - (t1 + h + 2.0), y, mid_z), Vector3(mx.x, y, mid_z))
	_grass.resync()
	await _frames(4)
	var before: int = _grass.total_switches
	for i in 20:
		var d := t1 + (3.0 if i % 2 == 0 else -3.0)
		_place_camera(Vector3(mn.x - d, y, mid_z), Vector3(mx.x, y, mid_z))
		await _frames(2)
	var flips: int = _grass.total_switches - before
	# Only the chosen cell is held by hysteresis here; the camera also moves 6 m relative to other cells.
	print("[grass-test] jitter of +-3 m inside the +-%.0f m dead band caused %d switches in all cells" % [h, flips])
	var cell_tier := _cell_tier(cell)
	_check(cell_tier == 1, "hysteresis: the test cell stays at tier 1 while the camera jitters inside the band (tier %d)" % cell_tier)


func _cell_tier(cell: Node) -> int:
	for node in cell.get_children():
		if (node as MultiMeshInstance3D).visible:
			return int((node as MultiMeshInstance3D).get_meta("grass_tier"))
	return 3


## Forces one cell across each boundary at a fixed camera and measures how much of the screen changes.
func _test_popping(field: Node) -> void:
	_grass.lod_enabled = true
	var cell := field.get_node(VIEW_CELL)
	var mn: Vector3 = cell.get_meta("cell_min")
	var mx: Vector3 = cell.get_meta("cell_max")
	var centre := (mn + mx) * 0.5
	var gcell: Object = null
	for c in _grass._cells:
		if c.node == cell:
			gcell = c
	var distances := [18.0, 40.0, 85.0]
	var labels := ["T0->T1 (view from 18 m)", "T1->T2 (view from 40 m)", "T2->culled (view from 85 m)"]
	for i in 3:
		var cam := Vector3(mn.x - distances[i], _terrain.data.get_height(Vector3(mn.x - distances[i], 0, centre.z)) + 2.0, centre.z)
		_grass.lod_enabled = false  # hold the state; we force the cell's tier by hand
		await _frames(2)
		_place_camera(cam, centre)
		_grass._set_all_tiers(0)
		# Put every other cell on the tier it would have at this distance, then toggle only our cell.
		for c in _grass._cells:
			_grass._set_tier(c, _grass._plain_tier(_grass._distance(c, cam)), false)
		_grass._set_tier(gcell, i, false)
		await _frames(6)
		var a := await _grab()
		_grass._set_tier(gcell, i + 1, false)
		await _frames(6)
		var b := await _grab()
		var stats := _diff(a, b)
		print("[grass-test] popping %s: %.3f%% of pixels change by >24/255, mean abs change %.4f/255, max %d" % [labels[i], stats[0], stats[1], stats[2]])
		if _shots != "":
			a.save_png("%s/pop_%d_before.png" % [_shots, i])
			b.save_png("%s/pop_%d_after.png" % [_shots, i])
	_grass.lod_enabled = true


func _write_shots(field: Node) -> void:
	var cell := field.get_node(VIEW_CELL)
	var centre := ((cell.get_meta("cell_min") as Vector3) + (cell.get_meta("cell_max") as Vector3)) * 0.5
	var ground := func(x: float, z: float) -> float: return _terrain.data.get_height(Vector3(x, 0, z))
	var poses := {
		"close": [Vector3(centre.x - 3.0, ground.call(centre.x - 3.0, centre.z) + 1.6, centre.z), centre + Vector3(8, 0, 0)],
		"mid": [Vector3(centre.x - 28.0, ground.call(centre.x - 28.0, centre.z) + 2.2, centre.z), centre],
		"far": [Vector3(centre.x - 2.0, ground.call(centre.x - 2.0, centre.z + 85.0) + 9.0, centre.z + 85.0), centre],
	}
	var configs := {"legacy": [0, false], "v2_full": [1, false], "v2_lod": [1, true]}
	for cfg in configs:
		_grass.style = configs[cfg][0]
		_grass.lod_enabled = configs[cfg][1]
		for name in poses:
			_place_camera(poses[name][0], poses[name][1])
			if configs[cfg][1]:
				_grass.resync()
			await _frames(14)
			var image := await _grab()
			image.save_png("%s/%s_%s.png" % [_shots, name, cfg])
			# Overdraw visualisation: brighter = more layers drawn per pixel.
			root.debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
			await _frames(3)
			var over := await _grab()
			root.debug_draw = Viewport.DEBUG_DRAW_DISABLED
			over.save_png("%s/%s_%s_overdraw.png" % [_shots, name, cfg])
			var sum := 0.0
			var lower := over.get_region(Rect2i(0, over.get_height() / 2, over.get_width(), over.get_height() / 2))
			for y in range(0, lower.get_height(), 3):
				for x in range(0, lower.get_width(), 3):
					sum += lower.get_pixel(x, y).get_luminance()
			var samples := (lower.get_height() / 3) * (lower.get_width() / 3)
			print("[grass-test] overdraw proxy (mean luminance of lower half) %s/%s = %.4f" % [name, cfg, sum / samples])
	_grass.style = 1
	_grass.lod_enabled = true


func _place_camera(position: Vector3, look_at_point: Vector3) -> void:
	_camera.global_position = position
	_camera.look_at(look_at_point, Vector3.UP)


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


## [% of pixels that differ by more than 24/255, mean absolute difference (0..255), maximum difference]
func _diff(a: Image, b: Image) -> Array:
	var changed := 0
	var total := 0.0
	var worst := 0
	var count := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := int(maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b)) * 255.0)
			if d > 24:
				changed += 1
			total += d
			worst = maxi(worst, d)
			count += 1
	return [100.0 * changed / count, total / count, worst]


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
	print("[grass-test] %s %s" % ["ok  " if ok else "FAIL", message])
