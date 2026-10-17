extends Node3D
## Test environment scene script: LOD showcase and start camera. The terrain and scatter come from
## the GeneratedEnvironment child (baked scene); if it is missing, it is generated at runtime.
## Contains no LOD controller or benchmark logic.

const TerrainBuilder := preload("res://scripts/env/terrain_builder.gd")
const MeshFactory := preload("res://scripts/env/mesh_factory.gd")
const GeneratedEnvironment := preload("res://scripts/env/generated_environment.gd")
const PlayerController := preload("res://scripts/player/player_controller.gd")
const FreeFlyCamera := preload("res://scripts/env/free_fly_camera.gd")

const PROP_LAYER := 4

@export var show_lod_showcase: bool = true
## Horizontal point the player spawns near (the search moves outward until the spot is clear).
@export var spawn_center: Vector2 = Vector2(0.0, 22.0)
@export var spawn_max_slope_normal_y: float = 0.93

var _env: GeneratedEnvironment
var _terrain: TerrainBuilder
var _player: PlayerController
var _free_fly_on: bool = false
var _showcase_material: StandardMaterial3D
var _tree_meshes: Array[ArrayMesh] = []


func _ready() -> void:
	_env = get_node_or_null("GeneratedEnvironment") as GeneratedEnvironment
	var source := "baked"
	if _env == null:
		source = "runtime"
		_env = GeneratedEnvironment.new()
		_env.name = "GeneratedEnvironment"
		add_child(_env)
		_env.regenerate()
	_terrain = _env.make_terrain()

	_showcase_material = MeshFactory.make_material(true)
	for level in 3:
		_tree_meshes.append(MeshFactory.build_tree(level))
	if show_lod_showcase:
		_build_lod_showcase()
	_place_camera()
	_setup_player()

	var stats := _env.get_stats()
	print("[env] source=%s seed=%d chunks=%d trees=%d grass=%d rocks=%d tree_lod=%s" % [
			source, _env.world_seed, stats["chunks"], stats["trees"], stats["grass"],
			stats["rocks"], MeshFactory.TREE_LOD_NAMES[_env.tree_lod_level]])
	print("[env] tree triangles high/medium/low = %d / %d / %d" % [
			_triangle_count(_tree_meshes[0]), _triangle_count(_tree_meshes[1]),
			_triangle_count(_tree_meshes[2])])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_F1:
			toggle_free_fly()


## F1: switch between the player camera and the debug free-fly camera.
func toggle_free_fly() -> void:
	var fly := get_node_or_null("Camera3D") as FreeFlyCamera
	if _player == null or fly == null:
		return
	_free_fly_on = not _free_fly_on
	if _free_fly_on:
		fly.global_transform = _player.get_camera().global_transform
		fly.set_active(true)
	else:
		fly.set_active(false)
	_player.set_active(not _free_fly_on)


func _setup_player() -> void:
	var fly := get_node_or_null("Camera3D") as FreeFlyCamera
	if fly != null:
		fly.set_active(false)
	_player = get_node_or_null("Player") as PlayerController
	if _player == null:
		if fly != null:
			fly.set_active(true)
		return
	# Hold the player still until the static bodies exist in the physics space.
	_player.set_physics_process(false)
	_player.place_at(Vector3(spawn_center.x, _terrain.height_at(spawn_center.x, spawn_center.y) + 1.0,
			spawn_center.y), 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var spawn := _find_spawn()
	_player.place_at(spawn, 0.0)
	_player.set_physics_process(true)
	print("[env] player spawn=%s ground_y=%.3f" % [spawn, _terrain.height_at(spawn.x, spawn.z)])


## Spirals outward from spawn_center for gentle ground with no tree/rock overlapping the player.
func _find_spawn() -> Vector3:
	var space := get_world_3d().direct_space_state
	var probe := CapsuleShape3D.new()
	probe.radius = 0.8
	probe.height = 2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = PROP_LAYER
	for ring in 24:
		var radius := ring * 1.5
		var steps := 1 if ring == 0 else 6 + ring * 2
		for i in steps:
			var angle := TAU * float(i) / float(steps)
			var x := spawn_center.x + cos(angle) * radius
			var z := spawn_center.y + sin(angle) * radius
			if _terrain.normal_at(x, z).y < spawn_max_slope_normal_y:
				continue
			var ground := _terrain.height_at(x, z)
			query.transform = Transform3D(Basis.IDENTITY, Vector3(x, ground + 1.2, z))
			if space.intersect_shape(query, 1).is_empty():
				return Vector3(x, ground + 0.05, z)
	push_warning("No clear spawn found near %s; using the centre." % spawn_center)
	return Vector3(spawn_center.x, _terrain.height_at(spawn_center.x, spawn_center.y) + 0.5, spawn_center.y)


func _build_lod_showcase() -> void:
	var root := Node3D.new()
	root.name = "LodShowcase"
	add_child(root)
	for level in 3:
		var x := (level - 1) * 8.0
		var tree := MeshInstance3D.new()
		tree.name = "Tree_%s" % MeshFactory.TREE_LOD_NAMES[level]
		tree.mesh = _tree_meshes[level]
		tree.material_override = _showcase_material
		tree.position = Vector3(x, _terrain.height_at(x, 0.0), 0.0)
		root.add_child(tree)


func _place_camera() -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	camera.position = Vector3(0.0, _terrain.height_at(0.0, 18.0) + 6.0, 18.0)
	camera.look_at(Vector3(0.0, _terrain.height_at(0.0, 0.0) + 2.5, 0.0))
	if camera.has_method("sync_from_transform"):
		camera.call("sync_from_transform")


func _triangle_count(mesh: ArrayMesh) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if indices != null:
		return (indices as PackedInt32Array).size() / 3
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
