extends Node
## Common interface of the per-category LOD policies (trees, grass, bushes, debris). Each policy is a node
## in the environment scene that watches the active Camera3D and changes what its category's chunked
## MultiMeshes draw. Policies are independent of each other and of Terrain3D's own terrain LOD, and they never
## create per-instance nodes or modify collision or the saved scene. LodManager (lod_manager.gd) drives them together.
##
## Contract for a subclass:
## - `enabled` false = the baked scene is shown untouched (the "none" reference); turning it off after the
##   policy has built restores the baked state, turning it on resyncs from the camera. Neither counts as switches.
## - A policy builds its runtime data lazily on the first enabled frame (`is_built()`).
## - `frame_switches` / `total_switches` count units that changed tier in the latest / all updates (`switch_unit()`),
##   `last_update_ms` is the CPU time of the latest update.
## - `resync()` reassigns everything from the camera with no hysteresis and no switch counting (benchmark reset).
## - `verify()` returns "" when every instance is drawn consistently and collision is unchanged.
## - Adaptive mode (adaptive_lod.gd) only adds three things on top of that, all neutral by default so the baseline
##   is unchanged: `set_lod_bias(b)` scales the distances the policy compares (distance * (1 + b); b > 0 = coarser),
##   `set_schedule(interval, min_move, phase)` lets the policy skip updates when the camera has not moved, and
##   `max_changes_per_update` caps the units switched per update (the rest waits for the next update).

@export var enabled: bool = true:
	set = set_enabled

var frame_switches: int = 0
var total_switches: int = 0
## CPU time of this frame's update; 0 on a frame where the update was skipped by the schedule.
var last_update_ms: float = 0.0
## Updates actually run and their summed CPU time (mean cost per run = total_update_ms / updates_run).
var updates_run: int = 0
var total_update_ms: float = 0.0
## One-time initialisation cost (building the runtime data on the first enabled frame), kept out of the update cost.
var build_ms: float = 0.0

## Current LOD bias (> 0 coarser) and the distance multiplier derived from it. 1.0 exactly in baseline.
var lod_bias: float = 0.0
var _dist_scale: float = 1.0
## Update schedule. Interval 0 and move 0 = update every frame (baseline). max_changes_per_update 0 = unlimited.
var update_interval_s: float = 0.0
var min_camera_move: float = 0.0
var max_changes_per_update: int = 0

var _resync_pending: bool = true
var _phase: float = 0.0
var _since_update: float = 0.0
var _last_origin := Vector3(INF, INF, INF)
var _dirty: bool = true
## True while a change budget left work undone; forces the next scheduled update to run.
var _backlog: bool = false
## Where the next budget-limited pass resumes, so a limit cannot starve the end of the list.
var _cursor: int = 0


func set_enabled(value: bool) -> void:
	if value == enabled:
		return
	enabled = value
	_enabled_changed()


## Short category name used in the debug panel, benchmark metadata and logs ("trees", "grass", ...).
func category() -> String:
	return "category"


## What `frame_switches` counts: "instances", "cells" or "chunks".
func switch_unit() -> String:
	return "instances"


func is_built() -> bool:
	return false


## Instances of this category in the scene, and how many are currently drawn (LOD tiers/densities applied).
## For a policy that shows the same instance at several mesh levels, every instance counts once as drawn.
func instance_total() -> int:
	return 0


func instance_drawn() -> int:
	return 0


## Instances (or clumps) drawn at each tier, finest first. Tier meaning is policy specific, see tier_labels().
func tier_counts() -> PackedInt32Array:
	return PackedInt32Array()


func tier_labels() -> PackedStringArray:
	return PackedStringArray()


## Settings and static counts for the benchmark metadata.
func describe() -> Dictionary:
	return {}


func resync() -> void:
	pass


## Empty string when consistent.
func verify() -> String:
	return ""


func _enabled_changed() -> void:
	pass


## Bias > 0 = coarser, < 0 = finer. The scale never drops below 0.25 (a bias of -0.75 at most).
func set_lod_bias(value: float) -> void:
	if is_equal_approx(value, lod_bias):
		return
	lod_bias = value
	_dist_scale = maxf(1.0 + value, 0.25) if value != 0.0 else 1.0
	_dirty = true
	_bias_changed()


## Called when the bias changed; a policy that caches values derived from it refreshes them here.
func _bias_changed() -> void:
	pass


func set_schedule(interval_s: float, min_move: float, phase: float = 0.0) -> void:
	update_interval_s = maxf(interval_s, 0.0)
	min_camera_move = maxf(min_move, 0.0)
	_phase = phase
	reset_schedule()


## Forgets the schedule's history (timer back at its phase, no pending work, change budget cursor at the start),
## so a benchmark run starts from the same scheduling state every time.
func reset_schedule() -> void:
	_since_update = _phase * update_interval_s
	_last_origin = Vector3(INF, INF, INF)
	_dirty = true
	_backlog = false
	_cursor = 0


## Asks for a quiet resync (no switch counting) on the next enabled frame.
func request_resync() -> void:
	_resync_pending = true
	_dirty = true


## True when this frame should run the policy update. Always true with the default schedule. Otherwise the update
## runs once per interval, and only if the camera moved, the bias changed or work is left over from a change budget.
func _update_due(delta: float, origin: Vector3) -> bool:
	if update_interval_s <= 0.0 and min_camera_move <= 0.0:
		return true
	_since_update += delta
	if _since_update < update_interval_s:
		return false
	if not (_dirty or _backlog) and origin.distance_squared_to(_last_origin) < min_camera_move * min_camera_move:
		return false
	_since_update = 0.0
	_last_origin = origin
	return true


func _skip_update() -> void:
	frame_switches = 0
	last_update_ms = 0.0


func _begin_update() -> int:
	frame_switches = 0
	return Time.get_ticks_usec()


func _finish_update(started: int) -> void:
	last_update_ms = (Time.get_ticks_usec() - started) / 1000.0
	updates_run += 1
	total_update_ms += last_update_ms
	total_switches += frame_switches
	_dirty = false


## Mean CPU cost of one update run, milliseconds.
func mean_update_ms() -> float:
	return total_update_ms / maxf(updates_run, 1)


## Number of collision bodies/shapes and total collision triangle data under all vegetation chunks.
static func collision_signature(vegetation_root: Node) -> Dictionary:
	var bodies := 0
	var shapes := 0
	var vertices := 0
	for chunk_node in vegetation_root.get_children():
		for child in chunk_node.get_children():
			var body := child as StaticBody3D
			if body == null:
				continue
			bodies += 1
			for shape_node in body.get_children():
				var collision := shape_node as CollisionShape3D
				if collision != null and collision.shape is ConcavePolygonShape3D:
					shapes += 1
					vertices += (collision.shape as ConcavePolygonShape3D).data.size()
	return {"bodies": bodies, "shapes": shapes, "vertices": vertices}
