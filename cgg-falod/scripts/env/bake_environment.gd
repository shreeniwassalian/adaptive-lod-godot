extends SceneTree
## Headless bake: godot --headless --path . --script res://scripts/env/bake_environment.gd
## Regenerates scenes/generated/baked_environment.tscn, keeping any parameters already saved in it.

const GeneratedEnvironment := preload("res://scripts/env/generated_environment.gd")
const OUTPUT_PATH := "res://scenes/generated/baked_environment.tscn"


func _initialize() -> void:
	var env: GeneratedEnvironment
	if ResourceLoader.exists(OUTPUT_PATH):
		env = (load(OUTPUT_PATH) as PackedScene).instantiate() as GeneratedEnvironment
	else:
		env = GeneratedEnvironment.new()
		env.name = "GeneratedEnvironment"
	if not env.regenerate():
		quit(1)
		return
	var packed := PackedScene.new()
	var err := packed.pack(env)
	if err == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
		err = ResourceSaver.save(packed, OUTPUT_PATH)
	if err == OK:
		err = _normalize_node_ids(OUTPUT_PATH)
	if err != OK:
		push_error("Bake failed: %s" % error_string(err))
		quit(1)
		return
	print("[bake] seed=%d saved %s stats=%s" % [env.world_seed, OUTPUT_PATH, env.get_stats()])
	env.free()
	quit(0)


# Godot assigns random node unique_ids on save; renumber them in order so re-bakes are byte-identical.
func _normalize_node_ids(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var lines := file.get_as_text().split("\n")
	file.close()
	var regex := RegEx.create_from_string(" unique_id=\\d+")
	var next_id := 1
	for i in lines.size():
		if lines[i].begins_with("[node "):
			lines[i] = regex.sub(lines[i], " unique_id=%d" % next_id)
			next_id += 1
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string("\n".join(lines))
	file.close()
	return OK
