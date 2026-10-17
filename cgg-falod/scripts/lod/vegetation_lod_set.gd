extends RefCounted
## Runtime LOD storage for the chunked tree MultiMeshes. Policy-free: a controller decides each
## instance's level and calls set_level(); this class keeps the buffers consistent.
##
## For every tree MultiMeshInstance3D in a chunk ("Spruce", "Broadleaf") it creates one MultiMesh per mesh
## detail level, all in the same chunk node. Each level holds a packed range [0, count) of the instances
## currently drawn at that level (visible_instance_count = count), so an instance is drawn at exactly one
## level. Instance transforms are copied unchanged from the baked scene; collision bodies are never touched.
## The saved scene file is not modified: everything happens in memory after load.

const LEVELS := 3
const TREE_KIND := "tree"

class Group:
	var chunk: Chunk
	var name: String
	var count: int
	var transforms: Array[Transform3D] = []
	var positions := PackedVector3Array()
	var level := PackedByteArray()
	## Position of each instance inside its level's packed range.
	var slot := PackedInt32Array()
	## packed[level][slot] = instance id.
	var packed: Array[PackedInt32Array] = []
	var counts := PackedInt32Array([0, 0, 0])
	var nodes: Array[MultiMeshInstance3D] = []
	var multimeshes: Array[MultiMesh] = []
	var dirty := false

class Chunk:
	var node: Node3D
	var groups: Array[Group] = []
	## Box around all tree origins in the chunk.
	var bounds_min := Vector3.ZERO
	var bounds_max := Vector3.ZERO
	## Level every tree in the chunk is known to be at, or -1 when it is mixed or unknown.
	var uniform_level := 0

var chunks: Array[Chunk] = []
var totals := PackedInt32Array([0, 0, 0])
var tree_instances: int = 0
var multimesh_nodes_added: int = 0
## Switches performed since begin_frame(); only counted while count_switches is true.
var frame_switches: int = 0
var total_switches: int = 0
var count_switches := false

var _expected_collision := {}


## Finds the tree MultiMeshInstance3D nodes under `vegetation_root` and builds the level MultiMeshes for
## each. `baked_level` is the detail level of the mesh already stored in the scene; the other levels come
## from `mesh_provider(node_name: String, level: int) -> Mesh`. Returns "" or an error message.
func build(vegetation_root: Node, baked_level: int, mesh_provider: Callable) -> String:
	var baked_meshes := {}
	for chunk_node in vegetation_root.get_children():
		var chunk := Chunk.new()
		chunk.node = chunk_node as Node3D
		if chunk.node == null:
			continue
		var first := true
		for child in chunk_node.get_children():
			var source := child as MultiMeshInstance3D
			if source == null or source.get_meta("vegetation_kind", "") != TREE_KIND or source.multimesh == null:
				continue
			if not baked_meshes.has(source.name):
				baked_meshes[source.name] = _level_meshes(source.multimesh.mesh, baked_level, mesh_provider, source.name)
				if (baked_meshes[source.name] as Array).is_empty():
					return "no LOD meshes for '%s'" % source.name
			var group := _make_group(chunk, source, baked_meshes[source.name])
			chunk.groups.append(group)
			for p in group.positions:
				if first:
					chunk.bounds_min = p
					chunk.bounds_max = p
					first = false
				else:
					chunk.bounds_min = chunk.bounds_min.min(p)
					chunk.bounds_max = chunk.bounds_max.max(p)
		if not chunk.groups.is_empty():
			chunks.append(chunk)
	for chunk in chunks:
		for group in chunk.groups:
			tree_instances += group.count
	totals = PackedInt32Array([tree_instances, 0, 0])
	_expected_collision = _collision_signature(vegetation_root)
	return ""


func begin_frame() -> void:
	frame_switches = 0


## Pushes the new per-level counts to the MultiMeshes of every group that changed.
func end_frame() -> void:
	for chunk in chunks:
		for group in chunk.groups:
			if group.dirty:
				_flush(group)


## Moves one instance to `new_level`. O(1): swap-remove from its old level, append to the new one.
func set_level(group: Group, id: int, new_level: int) -> void:
	var old_level := group.level[id]
	if old_level == new_level:
		return
	var s := group.slot[id]
	var last := group.counts[old_level] - 1
	var moved := group.packed[old_level][last]
	if moved != id:
		group.packed[old_level][s] = moved
		group.slot[moved] = s
		group.multimeshes[old_level].set_instance_transform(s, group.transforms[moved])
	group.counts[old_level] = last

	var new_slot := group.counts[new_level]
	group.packed[new_level][new_slot] = id
	group.slot[id] = new_slot
	group.multimeshes[new_level].set_instance_transform(new_slot, group.transforms[id])
	group.counts[new_level] = new_slot + 1

	group.level[id] = new_level
	group.dirty = true
	totals[old_level] -= 1
	totals[new_level] += 1
	if count_switches:
		frame_switches += 1
		total_switches += 1


## Puts every tree back at level 0 (the baked mesh) without counting switches. Level 1 and 2 nodes end up hidden.
func restore_baked() -> void:
	begin_frame()
	count_switches = false
	for chunk in chunks:
		for group in chunk.groups:
			for i in group.count:
				set_level(group, i, 0)
		chunk.uniform_level = 0
	end_frame()


## Checks the invariants: every instance in exactly one level, buffers hold the original transform,
## visible counts match, totals match, and the collision bodies are unchanged. Returns "" when all hold.
func verify() -> String:
	var errors := PackedStringArray()
	var seen_total := 0
	var summed := PackedInt32Array([0, 0, 0])
	for chunk in chunks:
		for group in chunk.groups:
			var seen := PackedByteArray()
			seen.resize(group.count)
			for lv in LEVELS:
				var visible_count := group.multimeshes[lv].visible_instance_count
				if visible_count != group.counts[lv]:
					errors.append("%s/%s L%d visible_instance_count %d != %d" % [chunk.node.name, group.name, lv, visible_count, group.counts[lv]])
				for s in group.counts[lv]:
					var id := group.packed[lv][s]
					if seen[id] != 0:
						errors.append("%s/%s instance %d drawn more than once" % [chunk.node.name, group.name, id])
					seen[id] = 1
					if group.level[id] != lv or group.slot[id] != s:
						errors.append("%s/%s instance %d bookkeeping mismatch" % [chunk.node.name, group.name, id])
					if not group.multimeshes[lv].get_instance_transform(s).is_equal_approx(group.transforms[id]):
						errors.append("%s/%s instance %d transform changed" % [chunk.node.name, group.name, id])
				summed[lv] += group.counts[lv]
			for id in group.count:
				if seen[id] == 0:
					errors.append("%s/%s instance %d not drawn at any level" % [chunk.node.name, group.name, id])
			seen_total += group.count
			if group.nodes[0].get_parent() != chunk.node:
				errors.append("%s/%s moved out of its chunk" % [chunk.node.name, group.name])
			if errors.size() > 20:
				break
	if seen_total != tree_instances:
		errors.append("instance total %d != %d" % [seen_total, tree_instances])
	if summed != totals:
		errors.append("level totals %s != %s" % [summed, totals])
	var collision := _collision_signature(chunks[0].node.get_parent()) if not chunks.is_empty() else {}
	if collision != _expected_collision:
		errors.append("collision bodies changed: %s != %s" % [collision, _expected_collision])
	return "; ".join(errors)


func _make_group(chunk: Chunk, source: MultiMeshInstance3D, meshes: Array) -> Group:
	var group := Group.new()
	group.chunk = chunk
	group.name = source.name
	var source_mm := source.multimesh
	group.count = source_mm.instance_count
	group.transforms.resize(group.count)
	group.positions.resize(group.count)
	group.level.resize(group.count)
	group.slot.resize(group.count)
	var bounds := AABB()
	var mesh_box: AABB = (meshes[0] as Mesh).get_aabb()
	for lv in range(1, LEVELS):
		mesh_box = mesh_box.merge((meshes[lv] as Mesh).get_aabb())
	for i in group.count:
		var xform := source_mm.get_instance_transform(i)
		group.transforms[i] = xform
		group.positions[i] = xform.origin
		bounds = (xform * mesh_box) if i == 0 else bounds.merge(xform * mesh_box)
		group.slot[i] = i

	for lv in LEVELS:
		var packed := PackedInt32Array()
		packed.resize(group.count)
		group.packed.append(packed)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[lv]
		mm.instance_count = group.count
		# Unused slots stay zero, so fix the bounds instead of letting the engine derive them from the buffer.
		mm.custom_aabb = bounds
		mm.visible_instance_count = 0
		group.multimeshes.append(mm)
		var node: MultiMeshInstance3D
		if lv == 0:
			node = source
		else:
			node = source.duplicate() as MultiMeshInstance3D
			node.name = "%s_LOD%d" % [source.name, lv]
			multimesh_nodes_added += 1
		node.multimesh = mm
		node.set_meta("lod_level", lv)
		if lv > 0:
			source.get_parent().add_child(node)
		group.nodes.append(node)

	# Everything starts at level 0, in the original order.
	for i in group.count:
		group.packed[0][i] = i
		group.multimeshes[0].set_instance_transform(i, group.transforms[i])
	group.counts[0] = group.count
	group.multimeshes[0].visible_instance_count = group.count
	for lv in range(1, LEVELS):
		group.nodes[lv].visible = false
	return group


func _flush(group: Group) -> void:
	for lv in LEVELS:
		group.multimeshes[lv].visible_instance_count = group.counts[lv]
		# A level with no instances is hidden so the renderer never submits it.
		group.nodes[lv].visible = group.counts[lv] > 0
	group.dirty = false


## Returns the LEVELS meshes for one species. The baked mesh is reused for `baked_level`; the others
## come from `mesh_provider(species_name, level)` and take their materials from the baked mesh.
func _level_meshes(baked: Mesh, baked_level: int, mesh_provider: Callable, species: String) -> Array:
	var result: Array = []
	for lv in LEVELS:
		if lv == baked_level:
			result.append(baked)
			continue
		var mesh: Mesh = mesh_provider.call(species, lv)
		if mesh == null or mesh.get_surface_count() != baked.get_surface_count():
			return []
		for s in baked.get_surface_count():
			mesh.surface_set_material(s, baked.surface_get_material(s))
		result.append(mesh)
	return result


## Number of collision bodies/shapes and total collision triangle data under all chunks.
func _collision_signature(vegetation_root: Node) -> Dictionary:
	var bodies := 0
	var shapes := 0
	var vertices := 0
	for chunk_node in vegetation_root.get_children():
		for child in chunk_node.get_children():
			var body := child as StaticBody3D
			if body == null:
				continue
			bodies += 1
			for shape_node in body.get_children():
				var collision := shape_node as CollisionShape3D
				if collision != null and collision.shape is ConcavePolygonShape3D:
					shapes += 1
					vertices += (collision.shape as ConcavePolygonShape3D).data.size()
	return {"bodies": bodies, "shapes": shapes, "vertices": vertices}
