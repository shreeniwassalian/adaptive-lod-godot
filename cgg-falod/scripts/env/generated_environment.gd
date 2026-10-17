@tool
extends Node3D
## Procedural environment generator. Builds the ground plus chunked MultiMesh scatter as children.
## In the editor: open scenes/generated/baked_environment.tscn, adjust the exports, press
## "Regenerate Environment" in the Inspector, then save the scene.

const TerrainBuilder := preload("res://scripts/env/terrain_builder.gd")
const MeshFactory := preload("res://scripts/env/mesh_factory.gd")

## Physics layers: the terrain heightmap and the per-chunk tree/rock bodies are kept separate.
const GROUND_LAYER := 1
const PROP_LAYER := 4
const TRUNK_SIDES := 6

@export var world_seed: int = 1337
@export var world_size: float = 256.0
@export var chunk_size: float = 64.0
@export var terrain_resolution: int = 128
@export var height_amplitude: float = 14.0
## Which tree mesh the chunked tree MultiMeshes use: 0 = high, 1 = medium, 2 = low.
@export_range(0, 2) var tree_lod_level: int = 0
## Densities are instances per square metre.
@export var tree_density: float = 0.02
@export var grass_density: float = 0.25
@export var rock_density: float = 0.004

@export_tool_button("Regenerate Environment", "Reload") var _regenerate_button: Callable = regenerate

var _terrain: TerrainBuilder
var _vertex_material: StandardMaterial3D
var _double_sided_material: StandardMaterial3D


func make_terrain() -> TerrainBuilder:
	return TerrainBuilder.new(world_seed, world_size, height_amplitude)


## Replaces all generated children. Returns false if this node is an instance inside another scene.
func regenerate() -> bool:
	if owner != null:
		push_warning("GeneratedEnvironment is instanced in '%s'. Open scenes/generated/baked_environment.tscn to regenerate it." % owner.name)
		return false
	for child in get_children():
		remove_child(child)
		child.free()

	_terrain = make_terrain()
	_vertex_material = MeshFactory.make_material(false)
	_vertex_material.resource_scene_unique_id = "StandardMaterial3D_vertex"
	_double_sided_material = MeshFactory.make_material(true)
	_double_sided_material.resource_scene_unique_id = "StandardMaterial3D_double_sided"
	var tree_mesh := MeshFactory.build_tree(tree_lod_level)
	tree_mesh.resource_scene_unique_id = "ArrayMesh_tree"
	var grass_mesh := MeshFactory.build_grass_clump()
	grass_mesh.resource_scene_unique_id = "ArrayMesh_grass"
	var rock_mesh := MeshFactory.build_rock()
	rock_mesh.resource_scene_unique_id = "ArrayMesh_rock"

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = _terrain.build_mesh(terrain_resolution)
	ground.mesh.resource_scene_unique_id = "ArrayMesh_ground"
	ground.material_override = _vertex_material
	add_child(ground)
	_add_ground_collision()
	var rock_faces := rock_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array

	var chunks_root := Node3D.new()
	chunks_root.name = "Chunks"
	add_child(chunks_root)
	var chunks_per_side := int(ceil(world_size / chunk_size))
	var half := world_size * 0.5
	for cz in chunks_per_side:
		for cx in chunks_per_side:
			var origin := Vector2(-half + cx * chunk_size, -half + cz * chunk_size)
			var extent := Vector2(minf(chunk_size, half - origin.x), minf(chunk_size, half - origin.y))
			var chunk := Node3D.new()
			chunk.name = "Chunk_%d_%d" % [cx, cz]
			chunks_root.add_child(chunk)
			var tag := "%d_%d" % [cx, cz]
			var trees := _scatter(_chunk_rng(cx, cz, 1), origin, extent, tree_density, 0.85, 0.8, 1.4, 0.0)
			var grass := _scatter(_chunk_rng(cx, cz, 2), origin, extent, grass_density, 0.75, 0.7, 1.3, 0.0)
			var rocks := _scatter(_chunk_rng(cx, cz, 3), origin, extent, rock_density, 0.0, 0.6, 2.2, 0.1)
			_add_multimesh(chunk, "Trees", tag, tree_mesh, trees, true)
			_add_multimesh(chunk, "Grass", tag, grass_mesh, grass, false)
			_add_multimesh(chunk, "Rocks", tag, rock_mesh, rocks, true)
			_add_prop_collision(chunk, tag, trees, rocks, rock_faces)

	_set_owner_recursive(self)
	return _verify_multimesh_data()


func get_stats() -> Dictionary:
	var stats := {"chunks": 0, "trees": 0, "grass": 0, "rocks": 0}
	var chunks_root := get_node_or_null("Chunks")
	if chunks_root == null:
		return stats
	for chunk in chunks_root.get_children():
		stats["chunks"] += 1
		for kind in ["Trees", "Grass", "Rocks"]:
			var mmi := chunk.get_node_or_null(kind) as MultiMeshInstance3D
			if mmi != null and mmi.multimesh != null:
				stats[kind.to_lower()] += mmi.multimesh.instance_count
	return stats


func _add_ground_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	body.collision_layer = GROUND_LAYER
	body.collision_mask = 0
	add_child(body)
	var shape := HeightMapShape3D.new()
	shape.resource_scene_unique_id = "HeightMapShape3D_ground"
	shape.map_width = terrain_resolution + 1
	shape.map_depth = terrain_resolution + 1
	shape.map_data = _terrain.build_height_data(terrain_resolution)
	var cell := world_size / float(terrain_resolution)
	var node := CollisionShape3D.new()
	node.name = "CollisionShape3D"
	node.shape = shape
	node.transform = Transform3D(Basis.from_scale(Vector3(cell, 1.0, cell)), Vector3.ZERO)
	body.add_child(node)


# One static body and one trimesh per chunk (trunk prisms + real rock faces), not one body per prop.
func _add_prop_collision(chunk: Node3D, tag: String, trees: Array[Transform3D],
		rocks: Array[Transform3D], rock_faces: PackedVector3Array) -> void:
	var faces := PackedVector3Array()
	for t in trees:
		_append_trunk_faces(faces, t)
	for t in rocks:
		for v in rock_faces:
			faces.append(t * v)
	if faces.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "PropBody"
	body.collision_layer = PROP_LAYER
	body.collision_mask = 0
	chunk.add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.resource_scene_unique_id = "ConcavePolygonShape3D_%s" % tag
	shape.backface_collision = true
	shape.data = faces
	var node := CollisionShape3D.new()
	node.name = "CollisionShape3D"
	node.shape = shape
	body.add_child(node)


func _append_trunk_faces(faces: PackedVector3Array, t: Transform3D) -> void:
	var s := t.basis.get_scale().x
	var base := t.origin + Vector3(0.0, -0.3 * s, 0.0)
	var rise := Vector3(0.0, 2.5 * s, 0.0)
	var r_bottom := 0.22 * s
	var r_top := 0.14 * s
	for i in TRUNK_SIDES:
		var a0 := TAU * float(i) / float(TRUNK_SIDES)
		var a1 := TAU * float(i + 1) / float(TRUNK_SIDES)
		var b0 := base + Vector3(cos(a0), 0.0, sin(a0)) * r_bottom
		var b1 := base + Vector3(cos(a1), 0.0, sin(a1)) * r_bottom
		var t0 := base + rise + Vector3(cos(a0), 0.0, sin(a0)) * r_top
		var t1 := base + rise + Vector3(cos(a1), 0.0, sin(a1)) * r_top
		faces.append_array(PackedVector3Array([b0, b1, t1, b0, t1, t0]))


# Headless runs use a dummy renderer that keeps no MultiMesh data, so a scene saved there would be empty.
func _verify_multimesh_data() -> bool:
	for mmi in find_children("*", "MultiMeshInstance3D", true, false):
		var multimesh := (mmi as MultiMeshInstance3D).multimesh
		if multimesh.buffer.size() != multimesh.instance_count * 12:
			push_error("MultiMesh data is unavailable (headless renderer?). Regenerate from the editor or without --headless.")
			return false
	return true


func _set_owner_recursive(node: Node) -> void:
	for child in node.get_children():
		child.owner = self
		_set_owner_recursive(child)


# Per-chunk, per-type RNG so each chunk's scatter is reproducible independent of the others.
func _chunk_rng(cx: int, cz: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = (world_seed * 73856093) ^ (cx * 19349663) ^ (cz * 83492791) ^ (salt * 2654435761)
	return rng


func _scatter(rng: RandomNumberGenerator, origin: Vector2, extent: Vector2, density: float,
		min_normal_y: float, scale_min: float, scale_max: float, sink: float) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var count := int(round(density * extent.x * extent.y))
	for i in count:
		var x := origin.x + rng.randf() * extent.x
		var z := origin.y + rng.randf() * extent.y
		var yaw := rng.randf() * TAU
		var s := rng.randf_range(scale_min, scale_max)
		if _terrain.normal_at(x, z).y < min_normal_y:
			continue
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
		result.append(Transform3D(basis, Vector3(x, _terrain.height_at(x, z) - sink * s, z)))
	return result


func _add_multimesh(parent: Node3D, node_name: String, chunk_tag: String, mesh: ArrayMesh,
		transforms: Array[Transform3D], casts_shadow: bool) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.resource_scene_unique_id = "MultiMesh_%s_%s" % [node_name, chunk_tag]
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = _vertex_material if casts_shadow else _double_sided_material
	if not casts_shadow:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
