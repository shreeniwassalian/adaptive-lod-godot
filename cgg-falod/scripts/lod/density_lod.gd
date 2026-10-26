extends "res://scripts/lod/lod_policy.gd"
## Baseline distance-based density LOD for a MultiMesh category that has a single mesh (bushes, debris).
## Used for bushes because no lower-detail bush mesh exists; used for debris because tiny rocks only need thinning.
##
## Each chunk shows a fraction of its instances that falls with the distance from the active camera to the
## chunk's padded bounds: `tier_densities[t]` of them at tier t, tiers separated by `tier_distances` (with
## hysteresis), and none beyond `cull_distance` (0 = never cull). Tier 0 is always full density.
##
## Deterministic and cheap: on the first enabled frame every chunk's MultiMesh buffer is rewritten once in a
## fixed pseudo-random order (a hash of each instance's position, so it does not depend on scene order). A
## density is then just `visible_instance_count = ceil(n * density)`, a prefix of that order, so the instances
## shown at a coarser tier are always a subset of those at a finer one (no instance blinks on and off between
## tiers) and a tier change is one integer write per node. Transforms are copied unchanged, no nodes are
## added, collision bodies and the saved scene are never touched. Disabled it shows every instance.
## Chunk-level tiers have a small visible density step where neighbouring chunks sit in different tiers.

@export var kind: String = "bush"
@export var category_name: String = "bushes"
@export var vegetation_path: NodePath = ^"../Vegetation"
@export var process_order: int = -48
@export_group("Density tiers")
## Chunk distances (metres) where the density drops to the next entry of `tier_densities`.
@export var tier_distances := PackedFloat32Array([50.0, 100.0, 160.0])
## Fraction of instances drawn per tier; one more entry than `tier_distances`, the first must be 1.
@export var tier_densities := PackedFloat32Array([1.0, 0.6, 0.3, 0.1])
## Distance beyond which nothing is drawn; 0 keeps the last tier forever.
@export var cull_distance: float = 240.0
## Half-width of the dead band around each distance, in metres.
@export var hysteresis: float = 8.0
## Metres added around the instance origins when measuring a chunk's distance (covers the mesh extent).
@export var bounds_pad: float = 2.0

class Group:
	var node: MultiMeshInstance3D
	var count: int
	## Original transform of the instance now stored at buffer index j: transforms[j]. Order is the fixed rank order.
	var transforms: Array[Transform3D] = []
	var drawn: int

class Chunk:
	var node: Node3D
	var groups: Array[Group] = []
	var bounds_min := Vector3.ZERO
	var bounds_max := Vector3.ZERO
	var tier: int = 0

var chunks: Array[Chunk] = []
var _built: bool = false
var _total: int = 0
var _drawn: int = 0
var _chunks_by_tier := PackedInt32Array()
var _thresholds := PackedFloat32Array()
var _densities := PackedFloat32Array()
var _expected_collision := {}
var _valid: bool = true


func _ready() -> void:
	process_priority = process_order  # after the tree controller, before the debug panel


func category() -> String:
	return category_name


func switch_unit() -> String:
	return "chunks"


func is_built() -> bool:
	return _built


func instance_total() -> int:
	return _total if _built else _count_baked()


func instance_drawn() -> int:
	return _drawn if _built else _count_baked()


## Instances drawn at each tier (the last entry is the culled tier, always 0, when cull_distance > 0).
func tier_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(maxi(_densities.size(), 1))
	for chunk in chunks:
		for group in chunk.groups:
			counts[chunk.tier] += group.drawn
	return counts


## Chunks currently in each tier.
func chunk_tier_counts() -> PackedInt32Array:
	return _chunks_by_tier.duplicate()


func tier_labels() -> PackedStringArray:
	var labels := PackedStringArray()
	for d in _densities:
		labels.append("%d%%" % roundi(d * 100.0))
	return labels


func describe() -> Dictionary:
	return {
		"kind": kind, "tier_distances_m": tier_distances, "tier_densities": tier_densities,
		"cull_distance_m": cull_distance, "hysteresis_m": hysteresis,
		"instances": instance_total(), "chunks": chunks.size(),
		"mesh_lod": false, "note": "single mesh: density reduction only",
	}


func resync() -> void:
	if not _prepare():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if not enabled:
		_set_all(0)
		return
	var origin := camera.global_position
	for chunk in chunks:
		_apply(chunk, _plain_tier(_distance(chunk, origin)))
	frame_switches = 0


## Empty string when every node draws exactly the prefix its chunk's tier prescribes, the buffer holds the
## original transforms in the recorded order, and collision is unchanged.
func verify() -> String:
	if not _built:
		return "not built"
	var errors := PackedStringArray()
	var drawn := 0
	var by_tier := PackedInt32Array()
	by_tier.resize(_densities.size())
	for chunk in chunks:
		by_tier[chunk.tier] += 1
		for group in chunk.groups:
			var want := _drawn_count(group.count, _densities[chunk.tier])
			var multimesh := group.node.multimesh
			if multimesh.instance_count != group.count:
				errors.append("%s/%s instance_count changed" % [chunk.node.name, group.node.name])
			if multimesh.visible_instance_count != want or group.drawn != want:
				errors.append("%s/%s draws %d (tracked %d), tier %d wants %d" % [
						chunk.node.name, group.node.name, multimesh.visible_instance_count, group.drawn, chunk.tier, want])
			if group.node.visible != (want > 0):
				errors.append("%s/%s visibility %s with %d drawn" % [chunk.node.name, group.node.name, group.node.visible, want])
			for j in mini(group.count, 3):  # spot check; the full check is in the self-test
				if not multimesh.get_instance_transform(j).is_equal_approx(group.transforms[j]):
					errors.append("%s/%s transform %d changed" % [chunk.node.name, group.node.name, j])
			if group.node.get_parent() != chunk.node:
				errors.append("%s/%s moved out of its chunk" % [chunk.node.name, group.node.name])
			drawn += want
		if errors.size() > 10:
			break
	if drawn != _drawn:
		errors.append("drawn %d != tracked %d" % [drawn, _drawn])
	if by_tier != _chunks_by_tier:
		errors.append("chunks per tier %s != tracked %s" % [by_tier, _chunks_by_tier])
	var vegetation := get_node_or_null(vegetation_path)
	if vegetation != null and collision_signature(vegetation) != _expected_collision:
		errors.append("collision bodies changed")
	return "; ".join(errors)


## Full check used by the self-test: every buffer slot holds the recorded transform and the recorded order is a
## permutation of the baked instances (same multiset of transforms as in the saved scene).
func verify_permutation(baked: Dictionary) -> String:
	var errors := PackedStringArray()
	for chunk in chunks:
		for group in chunk.groups:
			var key := "%s/%s" % [chunk.node.name, group.node.name]
			if not baked.has(key):
				errors.append("%s unknown" % key)
				continue
			var original: Array = baked[key]
			var seen := {}
			for j in group.count:
				var t := group.node.multimesh.get_instance_transform(j)
				if not t.is_equal_approx(group.transforms[j]):
					errors.append("%s slot %d differs from the record" % [key, j])
					break
				seen[t.origin] = seen.get(t.origin, 0) + 1
			var expected := {}
			for t in original:
				expected[(t as Transform3D).origin] = expected.get((t as Transform3D).origin, 0) + 1
			if seen != expected or original.size() != group.count:
				errors.append("%s instances are not a permutation of the baked ones" % key)
	return "; ".join(errors)


func _process(delta: float) -> void:
	if not enabled:
		frame_switches = 0
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
	var last := _densities.size() - 1
	var count := chunks.size()
	_backlog = false
	for k in count:
		var index := _cursor + k
		if index >= count:
			index -= count
		var chunk := chunks[index]
		var distance := _distance(chunk, origin)
		var tier := chunk.tier
		while tier < last and distance > _thresholds[tier] + hysteresis:
			tier += 1
		while tier > 0 and distance < _thresholds[tier - 1] - hysteresis:
			tier -= 1
		if tier != chunk.tier:
			_apply(chunk, tier)
			frame_switches += 1
			if max_changes_per_update > 0 and frame_switches >= max_changes_per_update:
				# Budget used up: the chunks not looked at yet are handled by the next update.
				_cursor = index + 1 if index + 1 < count else 0
				_backlog = k < count - 1
				break
	_finish_update(started)


func _enabled_changed() -> void:
	_resync_pending = true
	if _built and not enabled:
		_set_all(0)
		frame_switches = 0


func _distance(chunk: Chunk, origin: Vector3) -> float:
	return origin.distance_to(origin.clamp(chunk.bounds_min, chunk.bounds_max)) * _dist_scale


func _plain_tier(distance: float) -> int:
	var tier := 0
	while tier < _densities.size() - 1 and distance > _thresholds[tier]:
		tier += 1
	return tier


func _drawn_count(count: int, density: float) -> int:
	if density <= 0.0 or count == 0:
		return 0
	return mini(count, maxi(1, ceili(count * density)))


## Moves a chunk to `tier` (no switch counting; the caller counts).
func _apply(chunk: Chunk, tier: int) -> void:
	if tier != chunk.tier:
		_chunks_by_tier[chunk.tier] -= 1
		_chunks_by_tier[tier] += 1
		chunk.tier = tier
	for group in chunk.groups:
		var want := _drawn_count(group.count, _densities[tier])
		if want != group.drawn:
			_drawn += want - group.drawn
			group.drawn = want
			group.node.multimesh.visible_instance_count = want
			group.node.visible = want > 0


func _set_all(tier: int) -> void:
	for chunk in chunks:
		_apply(chunk, tier)


## Finds the category's MultiMeshes, fixes their order, and prepares the tier tables. False if unusable.
func _prepare() -> bool:
	if _built:
		return _valid
	if not _setup_tiers():
		_valid = false
		_built = true
		return false
	var vegetation := get_node_or_null(vegetation_path)
	if vegetation == null:
		push_error("[%s] vegetation node not found at %s" % [category_name, vegetation_path])
		return false
	var started := Time.get_ticks_usec()
	for chunk_node in vegetation.get_children():
		var chunk := Chunk.new()
		chunk.node = chunk_node as Node3D
		if chunk.node == null:
			continue
		var first := true
		for child in chunk_node.get_children():
			var source := child as MultiMeshInstance3D
			if source == null or source.multimesh == null or source.get_meta("vegetation_kind", "") != kind:
				continue
			var group := _make_group(source)
			chunk.groups.append(group)
			for t in group.transforms:
				if first:
					chunk.bounds_min = t.origin
					chunk.bounds_max = t.origin
					first = false
				else:
					chunk.bounds_min = chunk.bounds_min.min(t.origin)
					chunk.bounds_max = chunk.bounds_max.max(t.origin)
			_total += group.count
		if not chunk.groups.is_empty():
			chunk.bounds_min -= Vector3.ONE * bounds_pad
			chunk.bounds_max += Vector3.ONE * bounds_pad
			chunks.append(chunk)
	_drawn = _total
	_chunks_by_tier.resize(_densities.size())
	_chunks_by_tier[0] = chunks.size()
	_expected_collision = collision_signature(vegetation)
	_built = true
	build_ms = (Time.get_ticks_usec() - started) / 1000.0
	print("[%s] density LOD built in %.0f ms: %d chunks, %d instances, densities %s at %s m, cull %.0f m, hysteresis %.0f m" % [
			category_name, (Time.get_ticks_usec() - started) / 1000.0, chunks.size(), _total, tier_labels(),
			tier_distances, cull_distance, hysteresis])
	return true


func _setup_tiers() -> bool:
	if tier_densities.size() != tier_distances.size() + 1 or tier_densities.is_empty():
		push_error("[%s] tier_densities needs exactly one more entry than tier_distances" % category_name)
		return false
	_thresholds = tier_distances.duplicate()
	_densities = tier_densities.duplicate()
	_densities[0] = 1.0
	if cull_distance > 0.0:
		_thresholds.append(cull_distance)
		_densities.append(0.0)
	for i in range(1, _thresholds.size()):
		if _thresholds[i] <= _thresholds[i - 1] + 2.0 * hysteresis:
			push_warning("[%s] tier distances should differ by more than 2 * hysteresis" % category_name)
	return true


## Reorders the node's MultiMesh buffer into the fixed rank order (once) and records the transforms.
func _make_group(source: MultiMeshInstance3D) -> Group:
	var group := Group.new()
	group.node = source
	var multimesh := source.multimesh
	group.count = multimesh.instance_count
	var original: Array[Transform3D] = []
	var ranked := PackedInt64Array()
	original.resize(group.count)
	ranked.resize(group.count)
	for i in group.count:
		original[i] = multimesh.get_instance_transform(i)
		# Rank (from the position) in the high bits, original index below it to break ties: a native sort, same result every run.
		ranked[i] = (_rank_key(original[i].origin) << 24) | i
	ranked.sort()
	group.transforms.resize(group.count)
	for j in group.count:
		group.transforms[j] = original[ranked[j] & 0xFFFFFF]
		multimesh.set_instance_transform(j, group.transforms[j])
	group.drawn = group.count
	multimesh.visible_instance_count = group.count
	return group


## Stable pseudo-random rank of an instance, derived from its position only.
func _rank_key(position: Vector3) -> int:
	var h := (roundi(position.x * 16.0) * 73856093) ^ (roundi(position.z * 16.0) * 19349663) ^ (roundi(position.y * 16.0) * 83492791)
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return h ^ (h >> 16)


func _count_baked() -> int:
	var total := 0
	var vegetation := get_node_or_null(vegetation_path)
	if vegetation != null:
		for chunk_node in vegetation.get_children():
			for child in chunk_node.get_children():
				var node := child as MultiMeshInstance3D
				if node != null and node.multimesh != null and node.get_meta("vegetation_kind", "") == kind:
					total += node.multimesh.instance_count
	return total
