extends Node
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

const TreeMeshes := preload("res://scripts/world/tree_meshes.gd")
const VegetationLodSet := preload("res://scripts/lod/vegetation_lod_set.gd")

@export var enabled: bool = true
@export var vegetation_path: NodePath = ^"../Vegetation"
@export_group("Distances")
## Distance in metres at which trees change from level 0 to level 1.
@export var lod1_distance: float = 60.0
## Distance in metres at which trees change from level 1 to level 2.
@export var lod2_distance: float = 150.0
## Half-width of the dead band around each threshold, in metres.
@export var hysteresis: float = 10.0

## Instances that changed level during the most recent update (what the previous frame rendered with).
var frame_switches: int = 0
var total_switches: int = 0
## CPU time of the most recent _update() in milliseconds (GDScript cost of the policy plus buffer writes).
var last_update_ms: float = 0.0

var _lod_set: RefCounted
var _thresholds := PackedFloat32Array()
var _up_sq := PackedFloat32Array()
var _down_sq := PackedFloat32Array()


func _ready() -> void:
	process_priority = -50  # after the benchmark runner has positioned the camera


func is_built() -> bool:
	return _lod_set != null


## Instances currently drawn at each level (empty before the first enabled frame).
func level_counts() -> PackedInt32Array:
	return _lod_set.totals.duplicate() if _lod_set != null else PackedInt32Array()


func describe() -> Dictionary:
	return {
		"lod1_distance_m": lod1_distance, "lod2_distance_m": lod2_distance, "hysteresis_m": hysteresis,
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


func _process(_delta: float) -> void:
	if not enabled:
		return
	var fresh := _lod_set == null
	if not _prepare():
		enabled = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if fresh:
		resync()
	_update(camera.global_position)


func _update(origin: Vector3) -> void:
	var started := Time.get_ticks_usec()
	_lod_set.begin_frame()
	_lod_set.count_switches = true
	for chunk in _lod_set.chunks:
		var nearest := origin.distance_to(origin.clamp(chunk.bounds_min, chunk.bounds_max))
		var farthest := Vector3(
				maxf(absf(origin.x - chunk.bounds_min.x), absf(origin.x - chunk.bounds_max.x)),
				maxf(absf(origin.y - chunk.bounds_min.y), absf(origin.y - chunk.bounds_max.y)),
				maxf(absf(origin.z - chunk.bounds_min.z), absf(origin.z - chunk.bounds_max.z))).length()
		if _clear_of_bands(nearest, farthest):
			# Every tree is on the same side of every threshold: no hysteresis decision is possible.
			var level := _plain_level(nearest)
			if chunk.uniform_level != level:
				for group in chunk.groups:
					for i in group.count:
						_lod_set.set_level(group, i, level)
				chunk.uniform_level = level
		else:
			for group in chunk.groups:
				for i in group.count:
					var current: int = group.level[i]
					var target := _hysteresis_level(origin.distance_squared_to(group.positions[i]), current)
					if target != current:
						_lod_set.set_level(group, i, target)
			chunk.uniform_level = -1
	_lod_set.end_frame()
	frame_switches = _lod_set.frame_switches
	total_switches = _lod_set.total_switches
	last_update_ms = (Time.get_ticks_usec() - started) / 1000.0


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


## Builds the level MultiMeshes once. Returns false (and logs why) when the scene cannot be prepared.
func _prepare() -> bool:
	_thresholds = PackedFloat32Array([lod1_distance, lod2_distance])
	_up_sq.resize(2)
	_down_sq.resize(2)
	for i in 2:
		_up_sq[i] = (_thresholds[i] + hysteresis) * (_thresholds[i] + hysteresis)
		var inner := maxf(_thresholds[i] - hysteresis, 0.0)
		_down_sq[i] = inner * inner
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
	var camera := get_viewport().get_camera_3d()
	print("[lod] baseline built in %.0f ms: %d chunks, %d trees, +%d MultiMesh nodes, thresholds %.0f/%.0f m, hysteresis %.0f m, camera=%s" % [
			(Time.get_ticks_usec() - started) / 1000.0, _lod_set.chunks.size(), _lod_set.tree_instances,
			_lod_set.multimesh_nodes_added, lod1_distance, lod2_distance, hysteresis,
			camera.get_path() if camera != null else "none"])
	return true


func _make_mesh(species: String, level: int) -> Mesh:
	match species:
		"Spruce":
			return TreeMeshes.build_spruce(level)
		"Broadleaf":
			return TreeMeshes.build_broadleaf(level)
	return null
