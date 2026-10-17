extends SceneTree
## Regenerates the Terrain3D landscape: godot --path . --script res://scripts/world/bake_landscape.gd
## Needs a real renderer: do NOT pass --headless (it keeps no MultiMesh/terrain GPU data).
## Optional user args after `--`: terrain | river | vegetation (default: everything available).

const SCENE_PATH := "res://scenes/terrain3d_environment.tscn"


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("bake_landscape.gd cannot run with --headless; use a real renderer.")
		quit(1)
		return
	var what := OS.get_cmdline_user_args()
	var all := what.is_empty()
	var scene := (load(SCENE_PATH) as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	var ok := true
	if all or "terrain" in what:
		ok = ok and scene.generate_terrain()
	if scene.has_method("generate_river") and (all or "river" in what):
		ok = ok and scene.generate_river()
	if scene.has_method("generate_vegetation") and (all or "vegetation" in what):
		ok = ok and scene.generate_vegetation()
	if not ok:
		quit(1)
		return
	var packed := PackedScene.new()
	var err := packed.pack(scene)
	if err == OK:
		err = ResourceSaver.save(packed, SCENE_PATH)
	if err != OK:
		push_error("Saving %s failed: %s" % [SCENE_PATH, error_string(err)])
		quit(1)
		return
	print("[bake] saved ", SCENE_PATH)
	scene.queue_free()
	await process_frame
	quit(0)
