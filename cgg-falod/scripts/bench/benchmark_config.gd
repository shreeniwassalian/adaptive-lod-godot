extends RefCounted
## Benchmark settings with defaults. Every value can be overridden on the command line after `--`:
##   Godot_console.exe --path . res://scenes/benchmark.tscn -- --bench-duration=60 --bench-vsync=off
## Unknown or malformed --bench-* options are collected in `errors`; the runner refuses to start with them.

const VSYNC_MODES := ["off", "on", "adaptive", "mailbox"]
const LOD_MODES := ["none", "baseline", "adaptive"]
const PROFILES := ["normal", "stress"]
const SIGNALS := ["auto", "gpu", "frame"]
const GRASS_STYLES := ["legacy", "v2"]
## Categories the baseline mode can cover; rocks have no LOD policy (metrics only).
const LOD_CATEGORIES := ["trees", "grass", "bushes", "debris"]

## Names the run in the output file names and the metadata.
var label: String = "no_lod"
## Vegetation LOD mode, one of LOD_MODES: "none" leaves the baked scene as is (reference run, every category
## at full detail); "baseline" enables the distance policies of the categories in `lod_categories`; "adaptive" runs
## the same policies with the PI controller setting their bias.
var lod_mode: String = "none"
## Named evaluation setups (--bench-profile=): "normal" = 1920x1080, target 16.67 ms; "stress" = 2560x1440, target 8 ms.
## The profile sets resolution and target first; explicit --bench-width/height/target-ms override it.
var profile: String = "normal"
## Which categories "baseline" and "adaptive" apply to (comma separated names from LOD_CATEGORIES, or "all"). Ignored by "none".
var lod_categories: PackedStringArray = PackedStringArray(LOD_CATEGORIES)
## Grass: "legacy" = the original sparse tufts (the earlier reference), "v2" = the procedural grass field.
## Legacy grass has no LOD policy, so it is only a reference for the grass visual change.
var grass_style: String = "v2"
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

## Adaptive controller settings (only used by lod_mode "adaptive"; recorded in the metadata of every run).
var target_ms: float = 16.67
var signal_source: String = "auto"
var kp: float = 0.6
var ki: float = 0.4
var bias_min: float = 0.0
var bias_max: float = 2.0
var controller_interval_s: float = 0.25
var smoothing_s: float = 0.5
var max_rise: float = 0.10
var max_fall: float = 0.03
var policy_interval_s: float = 0.1
## Per-update change limit for every category (0 = unlimited, -1 = the AdaptiveLod node's per-category defaults).
var switch_budget: int = -1

var errors: PackedStringArray = []


static func from_args(args: PackedStringArray) -> RefCounted:
	var config := new()
	# The profile sets the defaults that the other options may then override, whatever their order.
	for arg in args:
		if arg.begins_with("--bench-profile="):
			config.profile = arg.trim_prefix("--bench-profile=")
			config._apply_profile()
	for arg in args:
		if not arg.begins_with("--bench-") or arg.begins_with("--bench-profile="):
			continue
		var parts := arg.trim_prefix("--bench-").split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		config._apply(key, value)
	config._validate()
	return config


func _apply_profile() -> void:
	match profile:
		"normal":
			width = 1920
			height = 1080
			target_ms = 16.67
		"stress":
			width = 2560
			height = 1440
			target_ms = 8.0


func _apply(key: String, value: String) -> void:
	match key:
		"label": label = value
		"lod-mode": lod_mode = value
		"grass": grass_style = value
		"lod-categories": _set_categories(value)
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
		"target-ms": target_ms = _float(key, value)
		"signal": signal_source = value
		"kp": kp = _float(key, value)
		"ki": ki = _float(key, value)
		"bias-min": bias_min = _float(key, value)
		"bias-max": bias_max = _float(key, value)
		"ctrl-interval": controller_interval_s = _float(key, value)
		"smoothing": smoothing_s = _float(key, value)
		"max-rise": max_rise = _float(key, value)
		"max-fall": max_fall = _float(key, value)
		"policy-interval": policy_interval_s = _float(key, value)
		"switch-budget": switch_budget = _int(key, value)
		_: errors.append("unknown option --bench-%s" % key)


func _set_categories(value: String) -> void:
	lod_categories = PackedStringArray(LOD_CATEGORIES) if value == "all" else value.split(",", false)


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
	if not PROFILES.has(profile):
		errors.append("--bench-profile must be one of %s, got '%s'" % [PROFILES, profile])
	if not SIGNALS.has(signal_source):
		errors.append("--bench-signal must be one of %s, got '%s'" % [SIGNALS, signal_source])
	if target_ms <= 0.0 or kp < 0.0 or ki < 0.0 or bias_max < bias_min or bias_min <= -0.75 or controller_interval_s <= 0.0 			or smoothing_s <= 0.0 or max_rise <= 0.0 or max_fall <= 0.0 or policy_interval_s < 0.0:
		errors.append("invalid controller settings: need target-ms > 0, kp/ki >= 0, -0.75 < bias-min <= bias-max, intervals/smoothing/max-rise/max-fall > 0")
	if not LOD_MODES.has(lod_mode):
		errors.append("--bench-lod-mode must be one of %s, got '%s'" % [LOD_MODES, lod_mode])
	if not GRASS_STYLES.has(grass_style):
		errors.append("--bench-grass must be one of %s, got '%s'" % [GRASS_STYLES, grass_style])
	for category in lod_categories:
		if not LOD_CATEGORIES.has(category):
			errors.append("--bench-lod-categories entries must be from %s or 'all', got '%s'" % [LOD_CATEGORIES, category])
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
		"label": label, "lod_mode": lod_mode, "profile": profile,
		"lod_categories": lod_categories if lod_mode != "none" else PackedStringArray(),
		"grass_style": grass_style, "seed": seed_value, "warmup_s": warmup_s,
		"settle_frames": settle_frames, "duration_s": duration_s, "speed_mps": speed_mps,
		"eye_height_m": eye_height_m, "pitch_deg": pitch_deg, "fov_deg": fov_deg,
		"requested_width": width, "requested_height": height, "vsync": vsync, "max_fps": max_fps,
		"controller": {
			"target_ms": target_ms, "signal_source": signal_source, "kp": kp, "ki": ki, "bias_min": bias_min,
			"bias_max": bias_max, "update_interval_s": controller_interval_s, "smoothing_s": smoothing_s,
			"max_rise_per_update": max_rise, "max_fall_per_update": max_fall, "policy_update_interval_s": policy_interval_s,
			"switch_budget": switch_budget, "used": lod_mode == "adaptive",
		},
	}
