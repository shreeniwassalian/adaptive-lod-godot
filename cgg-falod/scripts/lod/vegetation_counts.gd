extends RefCounted
## Instance counts of the chunked Vegetation scene by `vegetation_kind` (tree, bush, grass, rock, debris).


## {kind: instances} over all chunk MultiMeshes under `vegetation_root`; empty when it is null.
static func count(vegetation_root: Node) -> Dictionary:
	var result := {}
	if vegetation_root == null:
		return result
	for chunk in vegetation_root.get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node != null and node.multimesh != null:
				var kind := str(node.get_meta("vegetation_kind", "other"))
				result[kind] = int(result.get(kind, 0)) + node.multimesh.instance_count
	return result
