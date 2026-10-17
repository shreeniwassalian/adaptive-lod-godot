@tool
extends RefCounted
## Builds the spatially chunked vegetation: one MultiMeshInstance3D per category per 64 m chunk, plus
## one static body per chunk whose single trimesh covers tree trunks and large boulders.
## Placement is deterministic: each chunk/category has its own RNG derived from the world seed.

const TreeMeshes := preload("res://scripts/world/tree_meshes.gd")
const LandscapeModel := preload("res://scripts/world/landscape_model.gd")

const CHUNK_SIZE := 64.0
const PROP_LAYER := 4
const ROCK_MODELS := [
	"res://assets/terrain/models/RockA.glb",
	"res://assets/terrain/models/RockB.glb",
	"res://assets/terrain/models/RockC.glb",
]
const ROCK_MATERIAL := "res://assets/terrain/materials/rock_triplanar.tres"
const BIG_ROCK_SCALE := 0.3
const TRUNK_SIDES := 6

var model: LandscapeModel
var terrain: Terrain3D
var seed_value: int = 1337
var world_size: float = 1024.0
var tree_lod: int = 0
var spawn_center := Vector2.ZERO
var spawn_clear_radius := 30.0
var grass_density := 0.18
var grass_visibility_range := 0.0
var stats := {}

var _spruce: ArrayMesh
var _broadleaf: ArrayMesh
var _bush: ArrayMesh
var _grass: ArrayMesh
var _rock_meshes: Array[Mesh] = []
var _rock_faces: Array[PackedVector3Array] = []
var _rock_material: Material


func build() -> Node3D:
	_spruce = TreeMeshes.build_spruce(tree_lod)
	_broadleaf = TreeMeshes.build_broadleaf(tree_lod)
	_bush = TreeMeshes.build_bush()
	_grass = TreeMeshes.build_grass_clump()
	_rock_material = load(ROCK_MATERIAL)
	for path in ROCK_MODELS:
		var instance := (load(path) as PackedScene).instantiate()
		var mesh := (_find_mesh_instance(instance)).mesh
		instance.free()
		_rock_meshes.append(mesh)
		_rock_faces.append(_mesh_faces(mesh))
	stats = {"chunks": 0, "spruce": 0, "broadleaf": 0, "bushes": 0, "grass": 0, "rocks": 0, "debris": 0, "colliders": 0}

	var root := Node3D.new()
	root.name = "Vegetation"
	var half := world_size * 0.5
	var chunks_per_side := int(ceil(world_size / CHUNK_SIZE))
	for cz in chunks_per_side:
		for cx in chunks_per_side:
			var origin := Vector2(-half + cx * CHUNK_SIZE, -half + cz * CHUNK_SIZE)
			var chunk := _build_chunk(cx, cz, origin)
			if chunk != null:
				root.add_child(chunk)
				stats["chunks"] += 1
	_set_owner_recursive(root, root)
	return root


func _build_chunk(cx: int, cz: int, origin: Vector2) -> Node3D:
	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [cx, cz]
	chunk.set_meta("chunk_origin", origin)

	var spruce: Array[Transform3D] = []
	var broadleaf: Array[Transform3D] = []
	_place_trees(_rng(cx, cz, 1), origin, spruce, broadleaf)
	var bushes := _place_bushes(_rng(cx, cz, 2), origin)
	var grass := _place_grass(_rng(cx, cz, 3), origin)
	var rocks_by_type: Array = [[], [], []]
	_place_rocks(_rng(cx, cz, 4), origin, rocks_by_type)
	var debris := _place_debris(_rng(cx, cz, 5), origin)

	_add_multimesh(chunk, "Spruce", _spruce, spruce, true, null, "tree")
	_add_multimesh(chunk, "Broadleaf", _broadleaf, broadleaf, true, null, "tree")
	_add_multimesh(chunk, "Bushes", _bush, bushes, false, null, "bush")
	var grass_node := _add_multimesh(chunk, "Grass", _grass, grass, false, null, "grass")
	if grass_node != null and grass_visibility_range > 0.0:
		grass_node.visibility_range_end = grass_visibility_range
	for i in 3:
		_add_multimesh(chunk, "Rock%s" % "ABC"[i], _rock_meshes[i], rocks_by_type[i], true, _rock_material, "rock")
	_add_multimesh(chunk, "Debris", _rock_meshes[0], debris, false, _rock_material, "debris")
	_add_collision(chunk, spruce, broadleaf, rocks_by_type)

	stats["spruce"] += spruce.size()
	stats["broadleaf"] += broadleaf.size()
	stats["bushes"] += bushes.size()
	stats["grass"] += grass.size()
	stats["rocks"] += (rocks_by_type[0] as Array).size() + (rocks_by_type[1] as Array).size() + (rocks_by_type[2] as Array).size()
	stats["debris"] += debris.size()
	if chunk.get_child_count() == 0:
		chunk.free()
		return null
	return chunk


func _rng(cx: int, cz: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed_value * 73856093) ^ (cx * 19349663) ^ (cz * 83492791) ^ (salt * 2654435761)
	return rng


## Terrain height, slope (degrees) and clearance from the water edge; height is NAN outside the terrain.
func _sample(x: float, z: float) -> Vector3:
	var p := Vector3(x, 0.0, z)
	var h := terrain.data.get_height(p)
	if is_nan(h):
		return Vector3(NAN, 0.0, 0.0)
	var n := terrain.data.get_normal(p)
	var slope := rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
	return Vector3(h, slope, model.river_clearance(x, z))


func _spawn_factor(x: float, z: float) -> float:
	return smoothstep(spawn_clear_radius, spawn_clear_radius + 25.0, Vector2(x, z).distance_to(spawn_center))


func _place_trees(rng: RandomNumberGenerator, origin: Vector2, spruce: Array[Transform3D], broadleaf: Array[Transform3D]) -> void:
	var cells := 9
	var cell := CHUNK_SIZE / cells
	for iz in cells:
		for ix in cells:
			var x := origin.x + (ix + rng.randf_range(0.12, 0.88)) * cell
			var z := origin.y + (iz + rng.randf_range(0.12, 0.88)) * cell
			var accept := rng.randf()
			var species := rng.randf()
			var yaw := rng.randf() * TAU
			var size := rng.randf()
			var tilt_x := rng.randf_range(-0.03, 0.03)
			var tilt_z := rng.randf_range(-0.03, 0.03)
			var s := _sample(x, z)
			if is_nan(s.x):
				continue
			var density := model.forest_density(x, z, s.x, s.y, s.z) * _spawn_factor(x, z)
			if accept > density * 0.92:
				continue
			var is_spruce := species < model.spruce_fraction(x, z, s.x)
			var scale_value := lerpf(0.7, 1.3, pow(size, 0.8)) if is_spruce else lerpf(0.75, 1.25, pow(size, 0.8))
			var basis := Basis.from_euler(Vector3(tilt_x, yaw, tilt_z)).scaled(Vector3.ONE * scale_value)
			var xform := Transform3D(basis, Vector3(x, s.x - 0.15, z))
			if is_spruce:
				spruce.append(xform)
			else:
				broadleaf.append(xform)


func _place_bushes(rng: RandomNumberGenerator, origin: Vector2) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var cells := 12
	var cell := CHUNK_SIZE / cells
	for iz in cells:
		for ix in cells:
			var x := origin.x + (ix + rng.randf_range(0.1, 0.9)) * cell
			var z := origin.y + (iz + rng.randf_range(0.1, 0.9)) * cell
			var accept := rng.randf()
			var yaw := rng.randf() * TAU
			var size := rng.randf()
			var s := _sample(x, z)
			if is_nan(s.x) or s.y > 30.0 or s.x > 140.0:
				continue
			var forest := model.forest_density(x, z, s.x, s.y, s.z)
			var transition := forest * (1.0 - forest) * 4.0
			var bank := smoothstep(2.0, 6.0, s.z) * (1.0 - smoothstep(10.0, 22.0, s.z))
			var density := clampf(0.2 * forest + 0.3 * transition + 0.55 * bank, 0.0, 0.7) * _spawn_factor(x, z)
			if accept > density:
				continue
			var scale_value := lerpf(0.7, 1.5, size)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(scale_value, scale_value * 0.9, scale_value))
			result.append(Transform3D(basis, Vector3(x, s.x - 0.05, z)))
	return result


func _place_grass(rng: RandomNumberGenerator, origin: Vector2) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var cells := 40
	var cell := CHUNK_SIZE / cells
	for iz in cells:
		for ix in cells:
			var x := origin.x + (ix + rng.randf()) * cell
			var z := origin.y + (iz + rng.randf()) * cell
			var accept := rng.randf()
			var yaw := rng.randf() * TAU
			var size := rng.randf()
			var s := _sample(x, z)
			if is_nan(s.x) or s.z < 1.0:
				continue
			var forest := model.forest_density(x, z, s.x, s.y, s.z)
			var density := lerpf(1.0, 0.18, smoothstep(0.05, 0.45, forest))
			density *= smoothstep(32.0, 22.0, s.y) * smoothstep(150.0, 110.0, s.x) * smoothstep(1.0, 3.0, s.z)
			if accept > density * grass_density:
				continue
			var scale_value := lerpf(0.8, 1.6, size)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(scale_value, scale_value * lerpf(0.8, 1.3, size), scale_value))
			result.append(Transform3D(basis, Vector3(x, s.x - 0.02, z)))
	return result


func _place_rocks(rng: RandomNumberGenerator, origin: Vector2, by_type: Array) -> void:
	var cells := 4
	var cell := CHUNK_SIZE / cells
	for iz in cells:
		for ix in cells:
			var x := origin.x + (ix + rng.randf_range(0.15, 0.85)) * cell
			var z := origin.y + (iz + rng.randf_range(0.15, 0.85)) * cell
			var accept := rng.randf()
			var kind := rng.randi() % 3
			var size := rng.randf()
			var yaw := rng.randf() * TAU
			var pitch := rng.randf_range(-0.2, 0.2)
			var roll := rng.randf_range(-0.2, 0.2)
			var squash := rng.randf_range(0.8, 1.2)
			var s := _sample(x, z)
			if is_nan(s.x) or s.z < -0.5:
				continue
			var bank := 1.0 - smoothstep(2.0, 16.0, s.z)
			var density := (0.03 + 0.5 * smoothstep(16.0, 34.0, s.y) + 0.12 * bank) * smoothstep(0.0, 1.0, _spawn_factor(x, z))
			if accept > density:
				continue
			var scale_value := lerpf(0.22, 0.85, pow(size, 1.6))
			var basis := Basis.from_euler(Vector3(pitch, yaw, roll)).scaled(Vector3(scale_value, scale_value * squash, scale_value))
			(by_type[kind] as Array).append(Transform3D(basis, Vector3(x, s.x, z)))


func _place_debris(rng: RandomNumberGenerator, origin: Vector2) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var cells := 20
	var cell := CHUNK_SIZE / cells
	for iz in cells:
		for ix in cells:
			var x := origin.x + (ix + rng.randf()) * cell
			var z := origin.y + (iz + rng.randf()) * cell
			var accept := rng.randf()
			var size := rng.randf()
			var yaw := rng.randf() * TAU
			var tilt := rng.randf_range(-0.5, 0.5)
			var s := _sample(x, z)
			if is_nan(s.x) or s.z < 0.5 or s.y > 35.0:
				continue
			var forest := model.forest_density(x, z, s.x, s.y, s.z)
			var bank := 1.0 - smoothstep(1.0, 10.0, s.z)
			if accept > (0.012 * (0.4 + forest) + 0.05 * bank) * _spawn_factor(x, z):
				continue
			var scale_value := lerpf(0.03, 0.09, size)
			var basis := Basis.from_euler(Vector3(tilt, yaw, tilt * 0.6)).scaled(Vector3.ONE * scale_value)
			result.append(Transform3D(basis, Vector3(x, s.x - 0.05, z)))
	return result


func _add_multimesh(parent: Node3D, node_name: String, mesh: Mesh, transforms: Array, casts_shadow: bool,
		material: Material, kind: String) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.set_meta("vegetation_kind", kind)
	if material != null:
		instance.material_override = material
	if not casts_shadow:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


func _add_collision(chunk: Node3D, spruce: Array[Transform3D], broadleaf: Array[Transform3D], rocks_by_type: Array) -> void:
	var faces := PackedVector3Array()
	for t in spruce:
		_append_trunk_faces(faces, t, TreeMeshes.SPRUCE_TRUNK_RADIUS)
	for t in broadleaf:
		_append_trunk_faces(faces, t, TreeMeshes.BROADLEAF_TRUNK_RADIUS)
	for kind in 3:
		for t in rocks_by_type[kind] as Array:
			var xform: Transform3D = t
			if xform.basis.get_scale().x < BIG_ROCK_SCALE:
				continue
			for v in _rock_faces[kind]:
				faces.append(xform * v)
	if faces.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "PropBody"
	body.collision_layer = PROP_LAYER
	body.collision_mask = 0
	chunk.add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.data = faces
	var node := CollisionShape3D.new()
	node.name = "CollisionShape3D"
	node.shape = shape
	body.add_child(node)
	stats["colliders"] += 1


func _append_trunk_faces(faces: PackedVector3Array, t: Transform3D, trunk_radius: float) -> void:
	var s := t.basis.get_scale().x
	var base := t.origin + Vector3(0.0, -0.3 * s, 0.0)
	var rise := Vector3(0.0, 4.5 * s, 0.0)
	var r_bottom := trunk_radius * 1.05 * s
	var r_top := trunk_radius * 0.7 * s
	for i in TRUNK_SIDES:
		var a0 := TAU * float(i) / float(TRUNK_SIDES)
		var a1 := TAU * float(i + 1) / float(TRUNK_SIDES)
		var b0 := base + Vector3(cos(a0), 0.0, sin(a0)) * r_bottom
		var b1 := base + Vector3(cos(a1), 0.0, sin(a1)) * r_bottom
		var t0 := base + rise + Vector3(cos(a0), 0.0, sin(a0)) * r_top
		var t1 := base + rise + Vector3(cos(a1), 0.0, sin(a1)) * r_top
		faces.append_array(PackedVector3Array([b0, b1, t1, b0, t1, t0]))


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found
	return null


func _mesh_faces(mesh: Mesh) -> PackedVector3Array:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if indices == null:
		return vertices
	var faces := PackedVector3Array()
	for i in indices as PackedInt32Array:
		faces.append(vertices[i])
	return faces


func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_set_owner_recursive(child, scene_owner)
