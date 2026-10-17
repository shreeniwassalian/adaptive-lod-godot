@tool
extends Node3D
## Root of scenes/terrain3d_environment.tscn. Builds the Terrain3D landscape from a fixed seed.
## Editor: select this node and use the buttons in the Inspector, then save the scene.
## Command line (needs a real renderer, not --headless): scripts/world/bake_landscape.gd

const LandscapeModel := preload("res://scripts/world/landscape_model.gd")
const PlayerController := preload("res://scripts/player/player_controller.gd")
const FreeFlyCamera := preload("res://scripts/env/free_fly_camera.gd")
const VegetationBuilder := preload("res://scripts/world/vegetation_builder.gd")

const DATA_DIR := "res://data/terrain3d/valley"
const ASSETS_PATH := "res://data/terrain3d/assets.tres"
const TEXTURE_DIR := "res://assets/terrain/textures/"
const RIVER_SCENE_PATH := "res://scenes/generated/river.scn"
const VEGETATION_SCENE_PATH := "res://scenes/generated/vegetation.scn"
const WATER_SHADER := "res://shaders/river_water.gdshader"

@export_group("World")
@export var world_seed: int = 1337
## Terrain3D region size in metres; the world is 2 x 2 regions.
@export_enum("256", "512") var region_size: int = 512
@export var mountain_height: float = 170.0
@export var river_source: Vector2 = Vector2(95.0, -410.0)

@export_group("Vegetation")
## Tree mesh detail for all chunks: 0 = high, 1 = medium, 2 = low (the LOD controller will vary this later).
@export_range(0, 2) var tree_lod_level: int = 0
## Fraction of grass cells that receive a clump.
@export var grass_density: float = 0.18
## 0 disables distance culling of grass.
@export var grass_visibility_range: float = 0.0
## Player spawn point; vegetation and boulders are cleared around it.
@export var spawn_center: Vector2 = Vector2(180.0, 182.0)
@export var spawn_clear_radius: float = 30.0

@export_group("Generate")
@export_tool_button("Generate Terrain", "Terrain3D") var _terrain_button: Callable = generate_terrain
@export_tool_button("Generate River", "Curve3D") var _river_button: Callable = generate_river
@export_tool_button("Generate Vegetation", "MultiMeshInstance3D") var _vegetation_button: Callable = generate_vegetation
@export_tool_button("Generate All", "Reload") var _all_button: Callable = generate_all

const PROP_LAYER := 4

var _model: LandscapeModel
var _player: PlayerController
var _free_fly_on := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_setup_player()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
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
	_point_terrain_at_camera()


func _point_terrain_at_camera() -> void:
	var terrain := get_node_or_null("Terrain3D") as Terrain3D
	if terrain == null or _player == null:
		return
	var fly := get_node_or_null("Camera3D") as Camera3D
	terrain.set_camera(fly if _free_fly_on else _player.get_camera())


func _setup_player() -> void:
	var fly := get_node_or_null("Camera3D") as FreeFlyCamera
	if fly != null:
		fly.set_active(false)
	_player = get_node_or_null("Player") as PlayerController
	var terrain := get_node_or_null("Terrain3D") as Terrain3D
	if _player == null or terrain == null:
		if fly != null:
			fly.set_active(true)
		return
	# Hold the player still until the terrain collision and prop bodies exist in the physics space.
	_player.set_physics_process(false)
	_point_terrain_at_camera()
	var guess := Vector3(spawn_center.x, _ground_height(terrain, spawn_center) + 1.0, spawn_center.y)
	_player.place_at(guess, 0.0)
	for i in 4:
		await get_tree().physics_frame
	var spawn := _find_spawn(terrain)
	_player.place_at(spawn, 0.0)
	_player.set_physics_process(true)
	print("[landscape] player spawn=%s ground=%.2f water_clearance=%.1f m" % [
			spawn, _ground_height(terrain, Vector2(spawn.x, spawn.z)), get_model().river_clearance(spawn.x, spawn.z)])


func _ground_height(terrain: Terrain3D, xz: Vector2) -> float:
	return terrain.data.get_height(Vector3(xz.x, 0.0, xz.y))


## Spirals outward from spawn_center for gentle, dry ground with no tree or boulder overlapping.
func _find_spawn(terrain: Terrain3D) -> Vector3:
	var model := get_model()
	var space := get_world_3d().direct_space_state
	var probe := CapsuleShape3D.new()
	probe.radius = 0.9
	probe.height = 2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = PROP_LAYER
	for ring in 30:
		var radius := ring * 1.5
		var steps := 1 if ring == 0 else 6 + ring * 2
		for i in steps:
			var angle := TAU * float(i) / float(steps)
			var x := spawn_center.x + cos(angle) * radius
			var z := spawn_center.y + sin(angle) * radius
			var ground := terrain.data.get_height(Vector3(x, 0.0, z))
			if is_nan(ground):
				continue
			if terrain.data.get_normal(Vector3(x, 0.0, z)).y < 0.95 or model.river_clearance(x, z) < 8.0:
				continue
			query.transform = Transform3D(Basis.IDENTITY, Vector3(x, ground + 1.3, z))
			if space.intersect_shape(query, 1).is_empty():
				return Vector3(x, ground + 0.05, z)
	push_warning("No clear spawn found near %s; using the centre." % spawn_center)
	return Vector3(spawn_center.x, _ground_height(terrain, spawn_center) + 0.5, spawn_center.y)


func world_size() -> float:
	return float(region_size * 2)


func get_model() -> LandscapeModel:
	if _model == null:
		_model = LandscapeModel.new(world_seed, world_size(), mountain_height, river_source)
	return _model


## Imports the generated height/control/colour maps into Terrain3D and saves the region files.
func generate_terrain() -> bool:
	var terrain := get_node_or_null("Terrain3D") as Terrain3D
	if terrain == null:
		push_error("Terrain3DEnvironment needs a child node named 'Terrain3D'.")
		return false
	_model = null
	var model := get_model()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))
	_remove_old_region_files()

	terrain.change_region_size(region_size)
	terrain.assets = _make_assets()
	if terrain.material == null:
		terrain.material = Terrain3DMaterial.new()
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.material.set_shader_param("enable_macro_variation", true)
	terrain.material.set_shader_param("macro_variation1", Color(0.92, 0.96, 0.88))
	terrain.material.set_shader_param("macro_variation2", Color(1.0, 0.95, 0.88))
	terrain.collision_mode = Terrain3DCollision.FULL_GAME
	terrain.mesh_lods = 7
	terrain.mesh_size = 48

	var data := terrain.data
	for location in data.get_region_locations():
		data.remove_regionl(location, false)
	var res := int(world_size())
	var maps := model.build_maps(res)
	data.import_images([maps["height"], maps["control"], maps["color"]],
			Vector3(-world_size() * 0.5, 0.0, -world_size() * 0.5), 0.0, 1.0)
	data.calc_height_range()
	data.save_directory(DATA_DIR)
	terrain.data_directory = DATA_DIR  # reloads terrain.data from disk
	print("[landscape] terrain saved: regions=%d slope_mean=%.1f slope_max=%.1f" % [
			terrain.data.get_region_count(), maps["slope_mean"], maps["slope_max"]])
	return true


func _remove_old_region_files() -> void:
	var dir := DirAccess.open(DATA_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		if file.begins_with("terrain3d") and file.ends_with(".res"):
			dir.remove(file)


func _make_assets() -> Terrain3DAssets:
	var assets := Terrain3DAssets.new()
	# Grass and cliff use the CC0 ambientCG sets as-is. Forest floor and gravel are tinted variants of
	# those sets until dedicated soil/gravel textures are downloaded (see assets/terrain/README.md).
	var defs := [
		{"name": "Grass", "set": "ground037", "tint": Color(0.67451, 0.74902, 0.686275), "uv": 0.1},
		{"name": "Cliff", "set": "rock023", "tint": Color(1, 1, 1), "uv": 0.06},
		{"name": "ForestFloor", "set": "ground037", "tint": Color(0.56, 0.55, 0.42), "uv": 0.14},
		{"name": "Gravel", "set": "rock023", "tint": Color(0.58, 0.55, 0.5), "uv": 0.32},
	]
	for i in defs.size():
		var def: Dictionary = defs[i]
		var tex := Terrain3DTextureAsset.new()
		tex.name = def["name"]
		tex.id = i
		tex.albedo_color = def["tint"]
		tex.albedo_texture = load(TEXTURE_DIR + "%s_alb_ht.png" % def["set"])
		tex.normal_texture = load(TEXTURE_DIR + "%s_nrm_rgh.png" % def["set"])
		tex.uv_scale = def["uv"]
		assets.set_texture(i, tex)
	assets.save(ASSETS_PATH)
	return assets


## Builds the water ribbon, saves it as a separate scene and instances it as the `River` child.
func generate_river() -> bool:
	var model := get_model()
	var river := Node3D.new()
	river.name = "River"
	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = model.build_river_mesh()
	water.material_override = _make_water_material()
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	river.add_child(water)
	water.owner = river
	if not _save_and_instance(river, RIVER_SCENE_PATH, "River"):
		return false
	print("[landscape] river saved: length=%.0f m, surface %.1f -> %.1f m" % [
			model.river_length(), model.river_surface[0], model.river_surface[model.river_surface.size() - 1]])
	return true


func _make_water_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(WATER_SHADER)
	material.set_shader_parameter("normal_a", _make_noise_texture(11, 0.02, true))
	material.set_shader_parameter("normal_b", _make_noise_texture(23, 0.035, true))
	material.set_shader_parameter("foam_noise", _make_noise_texture(37, 0.04, false))
	return material


func _make_noise_texture(noise_seed: int, frequency: float, as_normal: bool) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.as_normal_map = as_normal
	tex.bump_strength = 8.0
	return tex


## Saves `content` as a scene file and replaces the child named `child_name` with an instance of it.
func _save_and_instance(content: Node, path: String, child_name: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var packed := PackedScene.new()
	var err := packed.pack(content)
	if err == OK:
		err = ResourceSaver.save(packed, path)
	content.free()
	if err != OK:
		push_error("Saving %s failed: %s" % [path, error_string(err)])
		return false
	var old := get_node_or_null(child_name)
	if old != null:
		remove_child(old)
		old.free()
	var instance := (ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene).instantiate()
	instance.name = child_name
	add_child(instance)
	instance.owner = owner if owner != null else self
	return true


## Terrain, then river, then vegetation (vegetation reads the freshly saved terrain heights).
func generate_all() -> bool:
	return generate_terrain() and generate_river() and generate_vegetation()


## Places seeded, chunked vegetation on the current Terrain3D data and instances it as `Vegetation`.
func generate_vegetation() -> bool:
	var terrain := get_node_or_null("Terrain3D") as Terrain3D
	if terrain == null or terrain.data.get_region_count() == 0:
		push_error("Generate the terrain before the vegetation.")
		return false
	var builder := VegetationBuilder.new()
	builder.model = get_model()
	builder.terrain = terrain
	builder.seed_value = world_seed
	builder.world_size = world_size()
	builder.tree_lod = tree_lod_level
	builder.spawn_center = spawn_center
	builder.spawn_clear_radius = spawn_clear_radius
	builder.grass_density = grass_density
	builder.grass_visibility_range = grass_visibility_range
	var started := Time.get_ticks_msec()
	var root := builder.build()
	if not _save_and_instance(root, VEGETATION_SCENE_PATH, "Vegetation"):
		return false
	print("[landscape] vegetation saved in %.1f s: %s" % [(Time.get_ticks_msec() - started) / 1000.0, builder.stats])
	return true
