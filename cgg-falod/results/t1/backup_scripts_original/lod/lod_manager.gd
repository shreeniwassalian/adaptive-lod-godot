extends Node
## Groups the category LOD policies of the environment (every LodPolicy sibling: trees, grass, bushes, debris)
## so that "None", "Baseline" and "Adaptive" mean the same thing for all of them. Adaptive = the same policies
## with the PI controller (adaptive_lod.gd, node AdaptiveLod) setting their bias; this node is the only mode switch. It owns no LOD logic and no per-frame work;
## the debug panel and the benchmark runner use it to switch modes and to read per-category statistics.
## Rocks have no policy on purpose (measured saving was negligible); `rock_instances()` only reports them.

const LodPolicy := preload("res://scripts/lod/lod_policy.gd")
const VegetationCounts := preload("res://scripts/lod/vegetation_counts.gd")

const MODES := ["none", "baseline", "adaptive"]

@export var vegetation_path: NodePath = ^"../Vegetation"
@export var adaptive_path: NodePath = ^"../AdaptiveLod"

var _policies: Array[Node] = []
var _rocks: int = -1


func _ready() -> void:
	for sibling in get_parent().get_children():
		if sibling is LodPolicy:
			_policies.append(sibling)


## The PI controller node, or null.
func adaptive() -> Node:
	return get_node_or_null(adaptive_path)


## "none", "baseline", "adaptive", or "mixed" when only some policies are enabled.
func mode() -> String:
	var controller := adaptive()
	if controller != null and controller.is_active() and is_baseline():
		return "adaptive"
	if is_baseline():
		return "baseline"
	return "none" if is_none() else "mixed"


## Selects one of MODES for every policy. Entering or leaving adaptive resets the controller and resyncs the
## policies without counting switches; "none" shows the baked vegetation.
func set_mode(new_mode: String) -> void:
	assert(MODES.has(new_mode), "unknown LOD mode %s" % new_mode)
	var controller := adaptive()
	if new_mode != "adaptive" and controller != null:
		controller.deactivate()
	for p in _policies:
		p.enabled = new_mode != "none"
	if new_mode == "adaptive" and controller != null:
		controller.activate()


func policies() -> Array[Node]:
	return _policies


## The policy of one category ("trees", "grass", "bushes", "debris"), or null.
func policy(category: String) -> Node:
	for p in _policies:
		if p.category() == category:
			return p
	return null


func categories() -> PackedStringArray:
	var names := PackedStringArray()
	for p in _policies:
		names.append(p.category())
	return names


## True when every policy is enabled.
func is_baseline() -> bool:
	for p in _policies:
		if not p.enabled:
			return false
	return not _policies.is_empty()


func is_none() -> bool:
	for p in _policies:
		if p.enabled:
			return false
	return true


func set_baseline(baseline: bool) -> void:
	set_mode("baseline" if baseline else "none")


## Enables exactly the named categories (an empty list = "none"). Unknown names are returned.
func set_categories(names: PackedStringArray) -> PackedStringArray:
	var unknown := names.duplicate()
	for p in _policies:
		p.enabled = names.has(p.category())
		var at := unknown.find(p.category())
		if at >= 0:
			unknown.remove_at(at)
	return unknown


func resync_all() -> void:
	for p in _policies:
		if p.enabled:
			p.resync()


## Concatenated integrity-check results of the enabled policies; "" when all pass.
func verify_all() -> String:
	var errors := PackedStringArray()
	for p in _policies:
		if p.enabled and p.is_built():
			var error: String = p.verify()
			if not error.is_empty():
				errors.append("%s: %s" % [p.category(), error])
	return "; ".join(errors)


## Static rock instance count (metrics only: no rock LOD exists).
func rock_instances() -> int:
	if _rocks < 0:
		_rocks = VegetationCounts.count(get_node_or_null(vegetation_path)).get("rock", 0)
	return _rocks
