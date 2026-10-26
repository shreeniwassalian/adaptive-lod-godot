extends "res://scripts/lod/lod_policy.gd"
## Baseline vegetation LOD: fixed distance thresholds with hysteresis, applied per tree instance.
## Distance-only: no feedback, importance or rate limiting. Distance is measured from the active
## Camera3D of the viewport to each tree's origin, so it follows the player camera in normal play,
## the free-fly camera after F1, and the scripted camera in the benchmark, without reading any input.
##
## Level 0 is used up to lod1_distance, level 1 up to lod2_distance, level 2 beyond. A tree moves to a
## coarser level only after passing the threshold by `hysteresis` metres, and back to a finer one only after
## coming that far inside it. Storage and the one-level-per-instance guarantee are in vegetation_lod_set.gd.
##
## Disabled (enabled = false) the baked scene is left untouched, which is the "no LOD" reference.
## The MultiMesh levels are built on the first enabled frame, so toggling `enabled` before then is free.
## Disabling after that restores every tree to level 0 (the baked mesh); enabling again resyncs from the
## camera. Neither the restore nor the resync counts as LOD switches.

const TreeMeshes := preload("res://scripts/world/tree_meshes.gd")
const VegetationLodSet := preload("res://scripts/lod/vegetation_lod_set.gd")

@export var vegetation_path: NodePath = ^"../Vegetation"
@export_group("Distances")
## Distance in metres at which trees change from level 0 to level 1.
@export var lod1_distance: float = 60.0
## Distance in metres at which trees change from level 1 to level 2.
@export var lod2_distance: float = 150.0
## Half-width of the dead band around each threshold, in metres. A separate setting from the thresholds: it stays this
## many real metres whatever the adaptive bias does, so a tree must pass a threshold by this much before it switches.
@export var hysteresis: float = 10.0
@export_group("Adaptive minimum detail")
## Adaptive mode only (the baseline never reads these). A positive bias moves the two thresholds inwards, never below
## these floors: trees closer than `adaptive_floor_lod1` stay at LOD0 and trees closer than `adaptive_floor_lod2` stay at
## LOD0 or LOD1, exactly as in the baseline. The defaults keep the baseline LOD0 range completely and let only the
## 100-150 m band of LOD1 trees go to LOD2 under pressure. Set a floor to 0 to drop the constraint for that threshold,
## to the baseline threshold itself to forbid any coarsening there.
@export var adaptive_floor_lod1: float = 60.0
@export var adaptive_floor_lod2: float = 100.0

# frame_switches (instances that changed level during the most recent update), total_switches and last_update_ms
# (CPU time of that update: the policy plus buffer writes) come from LodPolicy.

var _lod_set: RefCounted
var _baked_tree_count: int = -1
## Effective thresholds in metres (max(floor, baseline / (1 + bias))) and the squared hysteresis limits derived from them.
var _thresholds := PackedFloat32Array()
var _up_sq := PackedFloat32Array()
var _down_sq := PackedFloat32Array()
var _thresholds_valid: bool = false
var _threshold_key := PackedFloat64Array()


func _ready() -> void:
	process_priority = -50  # after the benchmark runner has positioned the camera


func is_built() -> bool:
	return _lod_set != null


func _bias_changed() -> void:
	_thresholds_valid = false


## The tree thresholds in effect for the current bias (a copy), for the debug panel, tests and metadata.
func effective_thresholds() -> PackedFloat32Array:
	_rebuild_thresholds()
	return _thresholds.duplicate()


func _enabled_changed() -> void:
	_resync_pending = true
	if not enabled and _lod_set != null:
		var started := Time.get_ticks_usec()
		_lod_set.restore_baked()
		frame_switches = 0
		print("[lod] disabled: baked vegetation restored in %.0f ms" % ((Time.get_ticks_usec() - started) / 1000.0))


func category() -> String:
	return "trees"


func instance_total() -> int:
	return _lod_set.tree_instances if _lod_set != null else _count_baked_trees()


func instance_drawn() -> int:
	return instance_total()  # every tree is drawn at exactly one mesh level


func tier_counts() -> PackedInt32Array:
	return level_counts()


func tier_labels() -> PackedStringArray:
	return PackedStringArray(["LOD0", "LOD1", "LOD2"])


## Trees currently drawn at each level. Before the levels are built every tree is at level 0 (baked).
func level_counts() -> PackedInt32Array:
	if _lod_set != null:
		return _lod_set.totals.duplicate()
	return PackedInt32Array([_count_baked_trees(), 0, 0])


func describe() -> Dictionary:
	return {
		"lod1_distance_m": lod1_distance, "lod2_distance_m": lod2_distance, "hysteresis_m": hysteresis,
		"adaptive_floor_lod1_m": adaptive_floor_lod1, "adaptive_floor_lod2_m": adaptive_floor_lod2,
		"effective_thresholds_m": effective_thresholds(),
		"tree_instances": _lod_set.tree_instances if _lod_set != null else 0,
		"lod_multimesh_nodes_added": _lod_set.multimesh_nodes_added if _lod_set != null else 0,
		"chunks": _lod_set.chunks.size() if _lod_set != null else 0,
	}


## Empty string when every tree is drawn exactly once with its original transform and collision is unchanged.
func verify() -> String:
	return _lod_set.verify() if _lod_set != null else "not built"


## Reassigns every tree from the current camera position with no hysteresis and without counting switches.
## The benchmark calls this after its teleport so each measured run starts from the same state.
func resync() -> void:
	if not _prepare():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var origin := camera.global_position
	_lod_set.begin_frame()
	_lod_set.count_switches = false
	for chunk in _lod_set.chunks:
		for group in chunk.groups:
			for i in group.count:
				_lod_set.set_level(group, i, _plain_level(origin.distance_to(group.positions[i])))
		chunk.uniform_level = -1
	_lod_set.end_frame()
	frame_switches = 0


func _process(delta: float) -> void:
	if not enabled:
		return
	if not _prepare():
		enabled = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if _resync_pending:
		resync()
		_resync_pending = false
	if not _update_due(delta, camera.global_position):
		_skip_update()
		return
	_update(camera.global_position)


func _update(origin: Vector3) -> void:
	var started := _begin_update()
	_rebuild_thresholds()
	_lod_set.begin_frame()
	_lod_set.count_switches = true
	_backlog = false
	var chunks: Array = _lod_set.chunks
	var count: int = chunks.size()
	for k in count:
		var index: int = _cursor + k
		if index >= count:
			index -= count
		if not _update_chunk(chunks[index], origin):
			# Change budget used up inside this chunk: resume here next time.
			_cursor = index
			_backlog = true
			break
	_lod_set.end_frame()
	frame_switches = _lod_set.frame_switches
	_finish_update(started)
	total_switches = _lod_set.total_switches


## Updates one chunk. Returns false when max_changes_per_update was reached before the chunk was finished.
func _update_chunk(chunk: VegetationLodSet.Chunk, origin: Vector3) -> bool:
	var budget := max_changes_per_update
	if budget > 0 and _lod_set.frame_switches >= budget:
		return false
	var nearest := origin.distance_to(origin.clamp(chunk.bounds_min, chunk.bounds_max))
	var farthest := Vector3(
			maxf(absf(origin.x - chunk.bounds_min.x), absf(origin.x - chunk.bounds_max.x)),
			maxf(absf(origin.y - chunk.bounds_min.y), absf(origin.y - chunk.bounds_max.y)),
			maxf(absf(origin.z - chunk.bounds_min.z), absf(origin.z - chunk.bounds_max.z))).length()
	if _clear_of_bands(nearest, farthest):
		# Every tree is on the same side of every threshold: no hysteresis decision is possible.
		var level := _plain_level(nearest)
		if chunk.uniform_level != level:
			chunk.uniform_level = -1
			for group in chunk.groups:
				for i in group.count:
					if group.level[i] != level:
						_lod_set.set_level(group, i, level)
						if budget > 0 and _lod_set.frame_switches >= budget:
							return _chunk_done(chunk, level)
			chunk.uniform_level = level
	else:
		chunk.uniform_level = -1
		for group in chunk.groups:
			for i in group.count:
				var current: int = group.level[i]
				var target := _hysteresis_level(origin.distance_squared_to(group.positions[i]), current)
				if target != current:
					_lod_set.set_level(group, i, target)
					if budget > 0 and _lod_set.frame_switches >= budget:
						return false
	return true


## After a uniform pass was cut short by the budget: finished only if no instance is left at another level.
func _chunk_done(chunk: VegetationLodSet.Chunk, level: int) -> bool:
	for group in chunk.groups:
		if group.counts[level] != group.count:
			return false
	chunk.uniform_level = level
	return true


## True when no threshold's dead band overlaps the distance range [nearest, farthest].
func _clear_of_bands(nearest: float, farthest: float) -> bool:
	for t in _thresholds:
		if farthest >= t - hysteresis and nearest <= t + hysteresis:
			return false
	return true


func _plain_level(distance: float) -> int:
	var level := 0
	for t in _thresholds:
		if distance > t:
			level += 1
	return level


func _hysteresis_level(distance_sq: float, current: int) -> int:
	var level := current
	while level < VegetationLodSet.LEVELS - 1 and distance_sq > _up_sq[level]:
		level += 1
	while level > 0 and distance_sq < _down_sq[level - 1]:
		level -= 1
	return level


## Recomputes the effective thresholds when the bias or a setting changed. With bias 0 they are exactly the baseline
## thresholds (the floors only ever stop a shrunk threshold, they never move one), so baseline behaviour is unchanged.
func _rebuild_thresholds() -> void:
	var key := PackedFloat64Array([lod1_distance, lod2_distance, hysteresis, adaptive_floor_lod1, adaptive_floor_lod2, _dist_scale])
	if _thresholds_valid and key == _threshold_key:
		return
	_threshold_key = key
	_thresholds_valid = true
	var base := [lod1_distance, lod2_distance]
	var floors := [adaptive_floor_lod1, adaptive_floor_lod2]
	_thresholds.resize(2)
	_up_sq.resize(2)
	_down_sq.resize(2)
	for i in 2:
		var effective: float = base[i] / _dist_scale
		if _dist_scale > 1.0:  # coarser: shrink toward, but never below, the floor
			effective = minf(base[i], maxf(effective, floors[i]))
		_thresholds[i] = effective
		_up_sq[i] = (effective + hysteresis) * (effective + hysteresis)
		var inner := maxf(effective - hysteresis, 0.0)
		_down_sq[i] = inner * inner


## Builds the level MultiMeshes once. Returns false (and logs why) when the scene cannot be prepared.
func _prepare() -> bool:
	_rebuild_thresholds()
	if _lod_set != null:
		return true
	if lod2_distance <= lod1_distance + 2.0 * hysteresis:
		push_warning("[lod] lod2_distance should exceed lod1_distance + 2 * hysteresis")
	var vegetation := get_node_or_null(vegetation_path)
	if vegetation == null:
		push_error("[lod] vegetation node not found at %s" % vegetation_path)
		return false
	var started := Time.get_ticks_usec()
	var lod_set := VegetationLodSet.new()
	var baked: Variant = get_parent().get("tree_lod_level")
	var error: String = lod_set.build(vegetation, baked if baked is int else 0, _make_mesh)
	if not error.is_empty():
		push_error("[lod] %s" % error)
		return false
	_lod_set = lod_set
	build_ms = (Time.get_ticks_usec() - started) / 1000.0
	var camera := get_viewport().get_camera_3d()
	print("[lod] baseline built in %.0f ms: %d chunks, %d trees, +%d MultiMesh nodes, thresholds %.0f/%.0f m, hysteresis %.0f m, camera=%s" % [
			(Time.get_ticks_usec() - started) / 1000.0, _lod_set.chunks.size(), _lod_set.tree_instances,
			_lod_set.multimesh_nodes_added, lod1_distance, lod2_distance, hysteresis,
			camera.get_path() if camera != null else "none"])
	return true


func _count_baked_trees() -> int:
	if _baked_tree_count < 0:
		_baked_tree_count = 0
		var vegetation := get_node_or_null(vegetation_path)
		if vegetation != null:
			for chunk in vegetation.get_children():
				for child in chunk.get_children():
					var node := child as MultiMeshInstance3D
					if node != null and node.multimesh != null and node.get_meta("vegetation_kind", "") == "tree":
						_baked_tree_count += node.multimesh.instance_count
	return _baked_tree_count


func _make_mesh(species: String, level: int) -> Mesh:
	match species:
		"Spruce":
			return TreeMeshes.build_spruce(level)
		"Broadleaf":
			return TreeMeshes.build_broadleaf(level)
	return null
