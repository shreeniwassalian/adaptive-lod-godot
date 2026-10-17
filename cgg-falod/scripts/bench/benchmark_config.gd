extends RefCounted
## Benchmark settings with defaults. Every value can be overridden on the command line after `--`:
##   Godot_console.exe --path . res://scenes/benchmark.tscn -- --bench-duration=60 --bench-vsync=off
## Unknown or malformed --bench-* options are collected in `errors`; the runner refuses to start with them.

const VSYNC_MODES := ["off", "on", "adaptive", "mailbox"]
const LOD_MODES := ["none", "baseline"]

## Names the run in the output file names and the metadata.
var label: String = "no_lod"
## Vegetation LOD mode, one of LOD_MODES: "none" leaves the baked scene as is (reference run).
var lod_mode: String = "none"
## Seeds Godot's global RNG at start. The world itself is baked and does not depend on it
## (its own seed is read from the scene and recorded as world_seed).
var seed_value: int = 1337
## Time on the camera path before measuring, in seconds.
var warmup_s: float = 10.0
## Frames held at the path start after warm-up and before measuring, so teleport hitches are excluded.
var settle_frames: int = 10
## Measured duration in seconds (wall clock).
var duration_s: float = 60.0
## Camera speed along the ground plane, metres per second.
var speed_mps: float = 8.0
var eye_height_m: float = 2.0
var pitch_deg: float = -6.0
var fov_deg: float = 75.0
var width: int = 1920
var height: int = 1080
## One of VSYNC_MODES.
var vsync: String = "off"
## Engine.max_fps; 0 = uncapped.
var max_fps: int = 0
## Output directory. Empty = <project>/results when run from the editor binary, else user://results.
var out_dir: String = ""
var quit_when_done: bool = true

var errors: PackedStringArray = []


static func from_args(args: PackedStringArray) -> RefCounted:
	var config := new()
	for arg in args:
		if not arg.begins_with("--bench-"):
			continue
		var parts := arg.trim_prefix("--bench-").split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		config._apply(key, value)
	config._validate()
	return config


func _apply(key: String, value: String) -> void:
	match key:
		"label": label = value
		"lod-mode": lod_mode = value
		"seed": seed_value = _int(key, value)
		"warmup": warmup_s = _float(key, value)
		"settle-frames": settle_frames = _int(key, value)
		"duration": duration_s = _float(key, value)
		"speed": speed_mps = _float(key, value)
		"eye-height": eye_height_m = _float(key, value)
		"pitch": pitch_deg = _float(key, value)
		"fov": fov_deg = _float(key, value)
		"width": width = _int(key, value)
		"height": height = _int(key, value)
		"vsync": vsync = value
		"max-fps": max_fps = _int(key, value)
		"out": out_dir = value
		"no-quit": quit_when_done = false
		_: errors.append("unknown option --bench-%s" % key)


func _int(key: String, value: String) -> int:
	if not value.is_valid_int():
		errors.append("--bench-%s needs an integer, got '%s'" % [key, value])
		return 0
	return value.to_int()


func _float(key: String, value: String) -> float:
	if not value.is_valid_float():
		errors.append("--bench-%s needs a number, got '%s'" % [key, value])
		return 0.0
	return value.to_float()


func _validate() -> void:
	if not VSYNC_MODES.has(vsync):
		errors.append("--bench-vsync must be one of %s, got '%s'" % [VSYNC_MODES, vsync])
	if not LOD_MODES.has(lod_mode):
		errors.append("--bench-lod-mode must be one of %s, got '%s'" % [LOD_MODES, lod_mode])
	if duration_s <= 0.0 or warmup_s < 0.0 or speed_mps <= 0.0:
		errors.append("duration and speed must be > 0, warmup >= 0")
	if width < 320 or height < 240:
		errors.append("resolution too small: %dx%d" % [width, height])
	if max_fps < 0 or settle_frames < 0:
		errors.append("max-fps and settle-frames must be >= 0")
	if label.is_empty() or not label.is_valid_filename():
		errors.append("--bench-label must be a valid file name, got '%s'" % label)


func to_dict() -> Dictionary:
	return {
		"label": label, "lod_mode": lod_mode, "seed": seed_value, "warmup_s": warmup_s,
		"settle_frames": settle_frames, "duration_s": duration_s, "speed_mps": speed_mps,
		"eye_height_m": eye_height_m, "pitch_deg": pitch_deg, "fov_deg": fov_deg,
		"requested_width": width, "requested_height": height, "vsync": vsync, "max_fps": max_fps,
	}
