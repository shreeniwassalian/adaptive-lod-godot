extends SceneTree
## Regenerates only the procedural grass field (scenes/generated/grass.scn) from the saved Terrain3D data:
##   Godot_console.exe --path . --script res://scripts/world/bake_grass.gd [-- density=1.0] [-- turf=1.0]
## density scales the tufts, turf scales the short fill patches (0 = tufts only).
## Needs a real renderer (do NOT pass --headless). The environment scene is only read, never saved.

const ENV_SCENE := "res://scenes/terrain3d_environment.tscn"
const OUTPUT_PATH := "res://scenes/generated/grass.scn"
const GrassBuilder := preload("res://scripts/world/grass_builder.gd")


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("bake_grass.gd cannot run with --headless; use a real renderer.")
		quit(1)
		return
	var density := 1.0
	var turf := 1.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("density="):
			density = arg.trim_prefix("density=").to_float()
		elif arg.begins_with("turf="):
			turf = arg.trim_prefix("turf=").to_float()
	var env := (load(ENV_SCENE) as PackedScene).instantiate()
	root.add_child(env)
	await process_frame
	await process_frame
	var terrain := env.get_node("Terrain3D") as Terrain3D
	var builder := GrassBuilder.new()
	builder.model = env.get_model()
	builder.terrain = terrain
	builder.seed_value = env.world_seed
	builder.world_size = env.world_size()
	builder.density_scale = density
	builder.turf_scale = turf
	var started := Time.get_ticks_msec()
	var field := builder.build()
	var packed := PackedScene.new()
	var err := packed.pack(field)
	if err == OK:
		err = ResourceSaver.save(packed, OUTPUT_PATH)
	if err != OK:
		push_error("Saving %s failed: %s" % [OUTPUT_PATH, error_string(err)])
		quit(1)
		return
	print("[grass] saved %s in %.1f s (density %.2f, turf %.2f): %s" % [OUTPUT_PATH, (Time.get_ticks_msec() - started) / 1000.0, density, turf, builder.stats])
	field.free()
	quit(0)
