extends SceneTree
## Checks the multi-category baseline LOD (trees, grass, bushes, debris) in the real environment scene
## (needs a real renderer, not --headless):
##   Godot_console.exe --path . --script res://scripts/lod/multi_lod_selftest.gd
## 1. Shared interface: LodManager finds the four LodPolicy nodes, each reports counts.
## 2. Density policies (bushes, debris): the reordered buffers are permutations of the baked instances, tiers and
##    drawn counts follow the camera distance, thresholds have hysteresis, no chunk flickers along the benchmark path.
## 3. Determinism: independently built policies on freshly loaded vegetation are identical.
## 4. Collision: collision bodies and trunk rays are unchanged by any mode switch.
## 5. Modes: None restores everything without counting switches, Baseline resyncs, category subsets, rocks untouched,
##    Terrain3D settings untouched.
## 6. Debug panel: one panel, None/Baseline drive every category, per-category numbers match the controllers.
## Also prints measured per-category update costs along the path (not pass/fail).

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const VEGETATION_SCENE := "res://scenes/generated/vegetation.scn"
const DensityLod := preload("res://scripts/lod/density_lod.gd")
const LodPolicy := preload("res://scripts/lod/lod_policy.gd")
const VegetationCounts := preload("res://scripts/lod/vegetation_counts.gd")
const CameraPath := preload("res://scripts/bench/benchmark_camera_path.gd")
const PROP_LAYER := 4
const TERRAIN_PROPS := ["mesh_lods", "mesh_size", "vertex_spacing", "region_size", "collision_mode", "collision_radius", "collision_shape_size"]

var _failures := 0
var _env: Node3D
var _terrain: Terrain3D
var _manager: Node
var _trees: Node
var _grass: Node
var _bush: Node
var _debris: Node
var _camera: Camera3D
var _baked_vegetation: Node


func _initialize() -> void:
	_env = (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(_env)
	_terrain = _env.get_node("Terrain3D")
	_manager = _env.get_node("LodManager")
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

	_test_interface()
	await _test_density_structure()
	await _test_tiers_and_hysteresis()
	await _test_determinism()
	await _test_collision_and_modes()
	await _test_rocks_and_terrain()
	await _test_panel()
	await _test_path_flicker_and_cost()
	_baked_vegetation.free()
	print("[multi-test] %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _test_interface() -> void:
	var names: PackedStringArray = _manager.categories()
	_check(names == PackedStringArray(["trees", "grass", "bushes", "debris"]), "interface: manager found the policies %s" % names)
	_trees = _manager.policy("trees")
	_grass = _manager.policy("grass")
	_bush = _manager.policy("bushes")
	_debris = _manager.policy("debris")
	_check(_manager.policy("rocks") == null, "interface: rocks have no policy (metrics only)")
	for p in _manager.policies():
		_check(p is LodPolicy, "interface: %s extends LodPolicy" % p.category())
	_check(_manager.is_baseline(), "interface: every policy is enabled by default (baseline)")
	_check(_manager.policy("grass").switch_unit() == "cells" and _bush.switch_unit() == "chunks" and _trees.switch_unit() == "instances",
			"interface: switch units are reported per policy")


func _test_density_structure() -> void:
	_place(Vector3(0, 100, 0))
	await _frames(4)
	var baked := VegetationCounts.count(_baked_vegetation)
	_check(_bush.is_built() and _debris.is_built(), "density: bush and debris policies built on the first enabled frame")
	_check(_bush.instance_total() == baked.get("bush", -1), "density: bush total %d equals the baked scene (%d)" % [_bush.instance_total(), baked.get("bush", -1)])
	_check(_debris.instance_total() == baked.get("debris", -1), "density: debris total %d equals the baked scene (%d)" % [_debris.instance_total(), baked.get("debris", -1)])
	print("[multi-test] baked instances by kind: %s" % baked)
	for p in [_bush, _debris]:
		_check(p.verify().is_empty(), "density: %s integrity: %s" % [p.category(), p.verify()])
		_check(p.verify_permutation(_baked_transforms(p.kind)).is_empty(),
				"density: %s buffers are a permutation of the baked instances: %s" % [p.category(), p.verify_permutation(_baked_transforms(p.kind))])
		_check(_manager.policy(p.category()) == p, "density: manager returns the %s policy" % p.category())
	var added := 0
	for chunk in _env.get_node("Vegetation").get_children():
		for child in chunk.get_children():
			if child.name.contains("_LOD"):
				added += 1
	_check(_count_nodes(_env.get_node("Vegetation")) - added == _count_nodes(_baked_vegetation),
			"density: only tree LOD level nodes were added (%d), none by bushes/debris" % added)


## Distances, drawn counts, and the hysteresis dead band of one dense bush chunk.
func _test_tiers_and_hysteresis() -> void:
	var chunk: DensityLod.Chunk = _densest_chunk(_bush)
	var group: DensityLod.Group = chunk.groups[0]
	var n := group.count
	_check(n >= 20, "tiers: test chunk %s has %d bushes" % [chunk.node.name, n])
	var wanted_density := [1.0, 0.6, 0.3, 0.1, 0.0]
	var distances := [10.0, 70.0, 130.0, 200.0, 280.0]
	var previous := n + 1
	for i in distances.size():
		_place(_at_distance(chunk, distances[i]))
		_bush.resync()
		var want: int = 0 if wanted_density[i] == 0.0 else mini(n, maxi(1, ceili(n * wanted_density[i])))
		_check(chunk.tier == i and group.drawn == want and group.node.multimesh.visible_instance_count == want,
				"tiers: %.0f m -> tier %d (want %d), draws %d of %d (want %d)" % [distances[i], chunk.tier, i, group.drawn, n, want])
		_check(group.drawn <= previous, "tiers: drawn count does not grow with distance")
		_check(group.node.visible == (want > 0), "tiers: node hidden exactly when nothing is drawn")
		previous = group.drawn
	_check(_bush.verify().is_empty(), "tiers: integrity after the distance sweep: %s" % _bush.verify())

	# Dead band around the first threshold (50 m, hysteresis 8): jitter inside it never flips the chunk.
	var threshold: float = _bush.tier_distances[0]
	var band: float = _bush.hysteresis
	_place(_at_distance(chunk, threshold + band * 0.5))
	_bush.resync()
	var start_tier := chunk.tier  # plain tier: beyond the threshold
	var flips := 0
	var last := chunk.tier
	for k in 60:
		_place(_at_distance(chunk, threshold + band * 0.5 + (3.0 if k % 2 == 0 else -3.0)))
		await process_frame
		if chunk.tier != last:
			flips += 1
			last = chunk.tier
	_check(start_tier == 1 and flips == 0, "hysteresis: jitter of +/-3 m inside the +/-%.0f m dead band causes %d flips (tier %d)" % [band, flips, start_tier])
	# Crossing the whole band does switch: 0 -> 1 -> 0, each crossing counted.
	var counts_before: int = _bush.total_switches
	var tiers := []
	for d in [threshold - band - 4.0, threshold + band + 4.0, threshold - band - 4.0]:
		_place(_at_distance(chunk, d))
		await process_frame
		tiers.append(chunk.tier)
	_check(tiers == [0, 1, 0], "hysteresis: tier follows the camera across the whole dead band %s" % [tiers])
	_check(_bush.total_switches >= counts_before + 2, "hysteresis: the crossings were counted as switches (%d)" % (_bush.total_switches - counts_before))


func _test_determinism() -> void:
	_place(Vector3(120, 60, -80))
	await _frames(3)
	_bush.resync()
	_debris.resync()
	var copies := []
	for label in ["A", "B"]:
		var holder := Node3D.new()
		holder.name = "Det%s" % label
		var vegetation := (load(VEGETATION_SCENE) as PackedScene).instantiate()
		vegetation.name = "Vegetation"
		holder.add_child(vegetation)
		var bush := DensityLod.new()
		bush.name = "Bush"
		var debris := DensityLod.new()
		debris.name = "Debris"
		debris.kind = "debris"
		debris.category_name = "debris"
		debris.tier_distances = _debris.tier_distances
		debris.tier_densities = _debris.tier_densities
		debris.cull_distance = _debris.cull_distance
		debris.hysteresis = _debris.hysteresis
		debris.bounds_pad = _debris.bounds_pad
		holder.add_child(bush)
		holder.add_child(debris)
		root.add_child(holder)
		holder.visible = false
		copies.append([bush, debris])
	await _frames(3)
	for pair in copies:
		for p in pair:
			p.resync()
	var reference := [_bush, _debris]
	for i in 2:
		var signature := _signature(reference[i])
		for c in copies:
			_check(_signature(c[i]) == signature, "determinism: independent %s build #%d equals the scene's (hash %s)" % [reference[i].category(), copies.find(c) + 1, signature.substr(0, 12)])
	for c in copies:
		(c[0].get_parent() as Node).queue_free()
	await process_frame
	# World generation is baked; the scene's rock/debris counts are the fingerprint the benchmark records.
	# Trees are excluded: the tree LOD adds duplicate-capacity level nodes of the same kind.
	var baked_counts := VegetationCounts.count(_baked_vegetation)
	var live_counts := VegetationCounts.count(_env.get_node("Vegetation"))
	baked_counts.erase("tree")
	live_counts.erase("tree")
	_check(baked_counts == live_counts, "determinism: live bush/grass/rock/debris counts equal a fresh load of vegetation.scn %s" % [live_counts])


func _test_collision_and_modes() -> void:
	var vegetation := _env.get_node("Vegetation")
	var signature_baked := LodPolicy.collision_signature(_baked_vegetation)
	var space := root.get_world_3d().direct_space_state
	var trunks: Array[Vector3] = []
	for chunk in _trees._lod_set.chunks:
		for group in chunk.groups:
			if group.count > 0 and trunks.size() < 40 and chunk.node.get_index() % 6 == 0:
				trunks.append(group.transforms[0].origin)
	var spot := Vector3(trunks[0].x + 30.0, _terrain.data.get_height(Vector3(trunks[0].x + 30.0, 0, trunks[0].z)) + 3.0, trunks[0].z)
	_place(spot)
	_manager.resync_all()
	await _frames(20)  # let terrain/prop collision stream in around the camera
	var hits_baseline := _trunk_hits(space, trunks)
	_check(LodPolicy.collision_signature(vegetation) == signature_baked, "collision: bodies equal the saved scene in baseline mode %s" % [LodPolicy.collision_signature(vegetation)])

	var switches := _switch_totals()
	_manager.set_baseline(false)
	await _frames(3)
	_check(_manager.is_none(), "modes: None disables every policy")
	_check(_switch_totals() == switches, "modes: restoring to None does not count switches")
	for p in _manager.policies():
		_check(p.instance_drawn() == p.instance_total(), "modes: None draws every %s instance (%d of %d)" % [p.category(), p.instance_drawn(), p.instance_total()])
	_check(_bush.verify().is_empty() and _debris.verify().is_empty(), "modes: bush/debris integrity in None: %s%s" % [_bush.verify(), _debris.verify()])
	for p in [_bush, _debris]:
		for chunk in p.chunks:
			for group in chunk.groups:
				if not group.node.visible or group.node.multimesh.visible_instance_count != group.count:
					_check(false, "modes: %s/%s not fully restored" % [chunk.node.name, group.node.name])
					break
	var hits_none := _trunk_hits(space, trunks)
	_check(LodPolicy.collision_signature(vegetation) == signature_baked, "collision: bodies equal the saved scene in None mode")
	_check(_grass.tier_clump_counts()[1] == 0 and _grass.tier_clump_counts()[2] == 0, "modes: grass back to full detail in None %s" % _grass.tier_clump_counts())

	_manager.set_baseline(true)
	_manager.resync_all()
	await _frames(3)
	_check(_manager.is_baseline(), "modes: Baseline enables every policy")
	_check(_manager.verify_all().is_empty(), "modes: integrity after Baseline: %s" % _manager.verify_all())
	_check(_bush.instance_drawn() < _bush.instance_total() and _debris.instance_drawn() < _debris.instance_total(),
			"modes: Baseline thins bushes (%d of %d) and debris (%d of %d) at this camera" % [
			_bush.instance_drawn(), _bush.instance_total(), _debris.instance_drawn(), _debris.instance_total()])
	var hits_after := _trunk_hits(space, trunks)
	_check(hits_baseline == hits_none and hits_none == hits_after, "collision: trunk ray results identical across None/Baseline (%d/%d hit)" % [hits_after.count(true), trunks.size()])
	_check(hits_after.count(true) >= trunks.size() * 0.9, "collision: trunk rays hit (%d of %d)" % [hits_after.count(true), trunks.size()])
	_check(LodPolicy.collision_signature(vegetation) == signature_baked, "collision: bodies equal the saved scene in Baseline mode")

	# Category subsets
	var unknown: PackedStringArray = _manager.set_categories(PackedStringArray(["bushes", "nonsense"]))
	await _frames(3)
	_check(unknown == PackedStringArray(["nonsense"]), "modes: unknown category names are reported %s" % unknown)
	_check(_bush.enabled and not _trees.enabled and not _grass.enabled and not _debris.enabled, "modes: only the requested category runs")
	_check(not _manager.is_baseline() and not _manager.is_none(), "modes: a subset is neither None nor Baseline (Mixed)")
	_check(_trees.instance_drawn() == _trees.instance_total() and _trees.level_counts()[1] == 0 and _trees.level_counts()[2] == 0, "modes: disabled trees are all LOD0")
	_manager.set_baseline(true)
	_manager.resync_all()
	await _frames(3)


func _test_rocks_and_terrain() -> void:
	var before := _terrain_settings()
	var rocks_ok := true
	var rocks := 0
	for chunk in _env.get_node("Vegetation").get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node != null and node.get_meta("vegetation_kind", "") == "rock":
				rocks += node.multimesh.instance_count
				if not node.visible or node.multimesh.visible_instance_count != -1:
					rocks_ok = false
	_check(rocks > 0 and rocks == _manager.rock_instances(), "rocks: %d instances reported as metrics (manager says %d)" % [rocks, _manager.rock_instances()])
	_check(rocks_ok, "rocks: untouched by Baseline (all nodes visible, all instances drawn)")
	for pos in [Vector3(-300, 80, -250), Vector3(250, 90, 300)]:
		_place(pos)
		await _frames(3)
	_manager.set_baseline(false)
	await _frames(2)
	_manager.set_baseline(true)
	await _frames(2)
	var after := _terrain_settings()
	_check(before == after, "terrain: native Terrain3D LOD/collision settings unchanged by LOD mode switches %s" % [after])


func _test_panel() -> void:
	var panel := _env.get_node("LodDebugPanel")
	var panels := 0
	for child in _env.get_children():
		if child.name.contains("Panel"):
			panels += 1
	_check(panels == 1, "panel: exactly one panel node exists")
	var none_button := panel.find_child("NoneButton", true, false) as Button
	var baseline_button := panel.find_child("AdaptiveButton", true, false) as Button  # Baseline is not offered in the panel
	_check(panel.find_child("BaselineButton", true, false) == null, "panel: no Baseline button")
	_key(KEY_F3)
	await create_timer(0.5).timeout
	_check(panel.is_panel_visible(), "panel: F3 shows it")
	var text: String = panel.get_text()
	print("[multi-test] panel text (Adaptive):\n" + text)
	_check(text.contains("Mode        Adaptive"), "panel: opening it switches the scene default (Baseline) to Adaptive")
	for label in ["Trees LOD0", "Grass", "Bushes", "Debris", "Rocks", "LOD update"]:
		_check(text.contains(label), "panel: shows a '%s' line" % label)
	_check(text.contains("Bushes      drawn %d / %d" % [_bush.instance_drawn(), _bush.instance_total()]), "panel: bush drawn/total match the controller")
	_check(text.contains("Debris      drawn %d / %d" % [_debris.instance_drawn(), _debris.instance_total()]), "panel: debris drawn/total match the controller")
	_check(text.contains("Rocks       %d (metrics only" % _manager.rock_instances()), "panel: rock count shown as metrics only")

	none_button.pressed.emit()
	await create_timer(0.5).timeout
	text = panel.get_text()
	_check(_manager.is_none() and text.contains("Mode        None"), "panel: None button disables every category")
	_check(text.contains("Bushes      drawn %d / %d" % [_bush.instance_total(), _bush.instance_total()]), "panel: None shows all bushes drawn")
	baseline_button.pressed.emit()
	await create_timer(0.5).timeout
	text = panel.get_text()
	_check(_manager.is_baseline() and text.contains("Mode        Adaptive"), "panel: Adaptive button enables every category")
	_check(text.contains("Bushes      drawn %d / %d" % [_bush.instance_drawn(), _bush.instance_total()]), "panel: numbers follow the new mode")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(_manager.is_none(), "panel: F4 toggles Adaptive -> None")
	_key(KEY_F4)
	await create_timer(0.3).timeout
	_check(_manager.mode() == "adaptive", "panel: F4 toggles None -> Adaptive")
	_manager.set_categories(PackedStringArray(["trees"]))
	await create_timer(0.5).timeout
	_check(panel.get_text().contains("Mode        Mixed"), "panel: a partial selection is labelled Mixed")
	_manager.set_baseline(true)
	await create_timer(0.3).timeout
	_key(KEY_F3)
	await _frames(2)
	_check(not panel.is_panel_visible(), "panel: F3 hides it")


## Walks the benchmark path: no chunk flip-flops, integrity holds, and reports the measured update costs.
func _test_path_flicker_and_cost() -> void:
	var path := CameraPath.new()
	_check(path.build(_terrain, 2.0, -6.0).is_empty(), "path: benchmark path builds")
	_manager.set_baseline(true)
	var last_tier := {}
	var last_switch := {}
	var pingpong := 0
	var errors := ""
	var cost := {"trees": 0.0, "grass": 0.0, "bushes": 0.0, "debris": 0.0}
	var samples := 0
	var start_switches := {}
	for p in _manager.policies():
		start_switches[p.category()] = p.total_switches
	var distance := 0.0
	while distance < path.length:
		_camera.global_transform = path.sample(distance)
		await process_frame
		await process_frame
		samples += 1
		for p in _manager.policies():
			cost[p.category()] += p.last_update_ms
		for p in [_bush, _debris]:
			for chunk in p.chunks:
				var key := "%s/%s" % [p.category(), chunk.node.name]
				var previous: int = last_tier.get(key, chunk.tier)
				if chunk.tier != previous:
					var recent: Array = last_switch.get(key, [])
					# Returning to the tier left less than 12 m of path ago is a flicker.
					if recent.size() == 2 and recent[1] == chunk.tier and distance - float(recent[0]) < 12.0:
						pingpong += 1
					last_switch[key] = [distance, previous]
					last_tier[key] = chunk.tier
				last_tier[key] = chunk.tier
		if int(distance) % 100 == 0 and errors.is_empty():
			errors = _manager.verify_all()
		distance += 2.0
	_check(errors.is_empty(), "path: integrity of every category along the path: %s" % errors)
	_check(pingpong == 0, "path: %d chunk tier changes returned to the previous tier within 12 m (flicker)" % pingpong)
	var line := PackedStringArray()
	for p in _manager.policies():
		line.append("%s %d %s switches, mean update %.3f ms" % [p.category(), p.total_switches - start_switches[p.category()], p.switch_unit(), cost[p.category()] / samples])
	print("[multi-test] along the 528 m path (%d samples): %s" % [samples, "; ".join(line)])


# --- helpers

func _place(position: Vector3) -> void:
	_camera.global_position = position


## A camera position `distance` metres from the chunk's padded bounds, along +x, at the bounds' mid height.
func _at_distance(chunk: DensityLod.Chunk, distance: float) -> Vector3:
	var middle := (chunk.bounds_min + chunk.bounds_max) * 0.5
	return Vector3(chunk.bounds_max.x + distance, middle.y, middle.z)


func _densest_chunk(policy: Node) -> DensityLod.Chunk:
	var best: DensityLod.Chunk = policy.chunks[0]
	for chunk in policy.chunks:
		if chunk.groups[0].count > best.groups[0].count:
			best = chunk
	return best


## Order-independent-of-nothing signature: chunk names, tiers, drawn counts and the exact buffer contents.
func _signature(policy: Node) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for chunk in policy.chunks:
		ctx.update(("%s:%d" % [chunk.node.name, chunk.tier]).to_utf8_buffer())
		for group in chunk.groups:
			ctx.update(("%s:%d:%d" % [group.node.name, group.drawn, group.node.multimesh.visible_instance_count]).to_utf8_buffer())
			ctx.update(group.node.multimesh.buffer.to_byte_array())
	return ctx.finish().hex_encode()


## {"Chunk/Node": [Transform3D...]} for one vegetation kind, read from a fresh copy of the saved scene.
func _baked_transforms(kind: String) -> Dictionary:
	var result := {}
	for chunk in _baked_vegetation.get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node != null and node.get_meta("vegetation_kind", "") == kind:
				var list: Array = []
				for i in node.multimesh.instance_count:
					list.append(node.multimesh.get_instance_transform(i))
				result["%s/%s" % [chunk.name, node.name]] = list
	return result


func _count_nodes(vegetation: Node) -> int:
	var total := 0
	for chunk in vegetation.get_children():
		for child in chunk.get_children():
			if child is MultiMeshInstance3D:
				total += 1
	return total


func _switch_totals() -> Array:
	var totals := []
	for p in _manager.policies():
		totals.append(p.total_switches)
	return totals


func _terrain_settings() -> Dictionary:
	var result := {}
	for name in TERRAIN_PROPS:
		if name in _terrain:
			result[name] = _terrain.get(name)
	return result


func _trunk_hits(space: PhysicsDirectSpaceState3D, trunks: Array[Vector3]) -> Array[bool]:
	var result: Array[bool] = []
	for p in trunks:
		var query := PhysicsRayQueryParameters3D.create(p + Vector3(3.0, 1.5, 0.0), p + Vector3(0.0, 1.5, 0.0), PROP_LAYER)
		result.append(not space.intersect_ray(query).is_empty())
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
	print("[multi-test] %s %s" % ["ok  " if ok else "FAIL", message])
