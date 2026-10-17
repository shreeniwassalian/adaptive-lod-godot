extends Node
## Grass style and distance LOD for the procedural grass field (GrassField, built by grass_builder.gd).
##
## style LEGACY: the original sparse tufts baked into the Vegetation scene are shown and the new field is hidden
## (the reference configuration). style V2: the new field is shown and the legacy tufts are hidden.
## lod_enabled false: every V2 cell stays at tier 0, full detail (the "no grass LOD" reference).
## lod_enabled true: each 32 m cell shows exactly one tier by distance from the active camera to the cell's
## bounds, with hysteresis. Tier 0 = fuller clumps at full density, tier 1 = simpler clumps at 40 % density,
## tier 2 = simplest clumps at 12 %, beyond cull_distance = no grass. Distance-only, like the tree baseline.
## Storage is chunk-level MultiMesh data: switching a cell only toggles node visibility; transforms,
## placement and the saved scene are never modified. Independent of VegetationLod (trees).

enum Style { LEGACY, V2 }

const TIERS := 3

@export var style: Style = Style.V2:
	set = set_style
@export var lod_enabled: bool = true:
	set = set_lod_enabled
@export var field_path: NodePath = ^"../GrassField"
@export var legacy_path: NodePath = ^"../Vegetation"
## Sway amplitude of the grass shader (0 = still grass, 1 = default). Independent of the LOD settings.
@export_range(0.0, 2.0, 0.05) var wind_strength: float = 1.0:
	set = set_wind_strength
@export_group("Distances")
## Cell distance (metres) at which grass changes from tier 0 to tier 1.
@export var tier1_distance: float = 25.0
## ... from tier 1 to tier 2.
@export var tier2_distance: float = 60.0
## ... from tier 2 to no grass.
@export var cull_distance: float = 110.0
## Half-width of the dead band around each distance, in metres.
@export var hysteresis: float = 6.0

## Cells that changed tier in the most recent update, and in total (restores and resyncs are not counted).
var frame_switches: int = 0
var total_switches: int = 0
## CPU time of the most recent update in milliseconds.
var last_update_ms: float = 0.0

class Cell:
	var node: Node3D
	var bounds_min: Vector3
	var bounds_max: Vector3
	var tier: int = 0
	## Clumps drawn when this cell is at tier 0, 1, 2.
	var clumps: PackedInt32Array
	## tier_nodes[tier] = the MultiMeshInstance3D nodes of that tier.
	var tier_nodes: Array = []

var _built: bool = false
var _field: Node3D
var _cells: Array[Cell] = []
var _legacy_nodes: Array[MultiMeshInstance3D] = []
var _legacy_clumps: int = 0
var _tier_clumps := PackedInt32Array([0, 0, 0])
var _cells_by_tier := PackedInt32Array([0, 0, 0, 0])
var _thresholds := PackedFloat32Array()
var _resync_pending: bool = true
var _warned: bool = false
var _material: ShaderMaterial


func _ready() -> void:
	process_priority = -49  # after the tree controller, before the debug panel


func set_style(value: Style) -> void:
	style = value
	if _built:
		_apply_style()


func set_wind_strength(value: float) -> void:
	wind_strength = value
	if _material != null:
		_material.set_shader_parameter("wind_strength", wind_strength)


func set_lod_enabled(value: bool) -> void:
	if value == lod_enabled:
		return
	lod_enabled = value
	_resync_pending = true
	if _built and not lod_enabled:
		_set_all_tiers(0)


func is_built() -> bool:
	return _built


func is_v2_active() -> bool:
	return _built and style == Style.V2 and _field != null


## Clumps currently drawn at each tier (legacy tufts count as tier 0 in LEGACY style).
func tier_clump_counts() -> PackedInt32Array:
	if not _built:
		return PackedInt32Array([0, 0, 0])
	if style == Style.LEGACY or _field == null:
		return PackedInt32Array([_legacy_clumps, 0, 0])
	return _tier_clumps.duplicate()


## Cells at tier 0, 1, 2 and with no grass (index 3).
func cell_tier_counts() -> PackedInt32Array:
	return _cells_by_tier.duplicate()


func describe() -> Dictionary:
	return {
		"style": "v2" if style == Style.V2 else "legacy", "lod_enabled": lod_enabled,
		"tier1_distance_m": tier1_distance, "tier2_distance_m": tier2_distance, "cull_distance_m": cull_distance,
		"hysteresis_m": hysteresis, "cells": _cells.size(), "legacy_clumps": _legacy_clumps,
		"field_clumps_full_detail": _cell_total(0),
	}


## Reassigns every cell from the camera with no hysteresis and without counting switches.
func resync() -> void:
	if not _prepare():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null or style != Style.V2 or _field == null:
		return
	if not lod_enabled:
		_set_all_tiers(0)
		return
	var origin := camera.global_position
	for cell in _cells:
		_set_tier(cell, _plain_tier(_distance(cell, origin)), false)
	frame_switches = 0


## Empty string when every cell shows exactly the tier it records, and the style matches visibility.
func verify() -> String:
	if not _built:
		return "not built"
	var errors := PackedStringArray()
	var v2 := style == Style.V2 and _field != null
	if _field != null and _field.visible != v2:
		errors.append("field visibility %s but style is %s" % [_field.visible, "v2" if v2 else "legacy"])
	for node in _legacy_nodes:
		if node.visible == v2:
			errors.append("legacy node %s visibility %s in %s style" % [node.get_parent().name, node.visible, "v2" if v2 else "legacy"])
			break
	var drawn := PackedInt32Array([0, 0, 0])
	for cell in _cells:
		for tier in TIERS:
			for node in cell.tier_nodes[tier]:
				var should_show: bool = cell.tier == tier
				if (node as MultiMeshInstance3D).visible != should_show:
					errors.append("%s tier %d node visible=%s, cell tier is %d" % [cell.node.name, tier, node.visible, cell.tier])
				if should_show:
					drawn[tier] += (node as MultiMeshInstance3D).multimesh.instance_count
		if errors.size() > 10:
			break
	if drawn != _tier_clumps:
		errors.append("drawn clumps %s != tracked %s" % [drawn, _tier_clumps])
	return "; ".join(errors)


func _process(_delta: float) -> void:
	if not _prepare():
		return
	if style != Style.V2 or _field == null or not lod_enabled:
		frame_switches = 0
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if _resync_pending:
		resync()
		_resync_pending = false
	_update(camera.global_position)


func _update(origin: Vector3) -> void:
	var started := Time.get_ticks_usec()
	frame_switches = 0
	for cell in _cells:
		var distance := _distance(cell, origin)
		var tier := cell.tier
		while tier < TIERS and distance > _thresholds[tier] + hysteresis:
			tier += 1
		while tier > 0 and distance < _thresholds[tier - 1] - hysteresis:
			tier -= 1
		if tier != cell.tier:
			_set_tier(cell, tier, true)
	total_switches += frame_switches
	last_update_ms = (Time.get_ticks_usec() - started) / 1000.0


## Distance from `origin` to the nearest point of the cell's padded bounds.
func _distance(cell: Cell, origin: Vector3) -> float:
	var dx := maxf(maxf(cell.bounds_min.x - origin.x, origin.x - cell.bounds_max.x), 0.0)
	var dy := maxf(maxf(cell.bounds_min.y - origin.y, origin.y - cell.bounds_max.y), 0.0)
	var dz := maxf(maxf(cell.bounds_min.z - origin.z, origin.z - cell.bounds_max.z), 0.0)
	return sqrt(dx * dx + dy * dy + dz * dz)


func _plain_tier(distance: float) -> int:
	var tier := 0
	while tier < TIERS and distance > _thresholds[tier]:
		tier += 1
	return tier


func _set_tier(cell: Cell, tier: int, count: bool) -> void:
	if tier == cell.tier:
		return
	_show_tier(cell, cell.tier, false)
	_show_tier(cell, tier, true)
	cell.tier = tier
	if count:
		frame_switches += 1


func _show_tier(cell: Cell, tier: int, shown: bool) -> void:
	var direction := 1 if shown else -1
	_cells_by_tier[tier] += direction
	if tier >= TIERS:
		return
	_tier_clumps[tier] += direction * cell.clumps[tier]
	for node in cell.tier_nodes[tier]:
		(node as MultiMeshInstance3D).visible = shown


func _set_all_tiers(tier: int) -> void:
	for cell in _cells:
		_set_tier(cell, tier, false)
	frame_switches = 0


func _cell_total(tier: int) -> int:
	var total := 0
	for cell in _cells:
		total += cell.clumps[tier]
	return total


func _apply_style() -> void:
	var v2 := style == Style.V2 and _field != null
	if _field != null:
		_field.visible = v2
	for node in _legacy_nodes:
		node.visible = not v2
	_resync_pending = true


## Finds the field cells and legacy grass nodes once, then applies the style.
func _prepare() -> bool:
	_thresholds = PackedFloat32Array([tier1_distance, tier2_distance, cull_distance])
	if _built:
		return true
	var legacy_root := get_node_or_null(legacy_path)
	if legacy_root != null:
		for chunk in legacy_root.get_children():
			for child in chunk.get_children():
				var node := child as MultiMeshInstance3D
				if node != null and node.multimesh != null and node.get_meta("vegetation_kind", "") == "grass":
					_legacy_nodes.append(node)
					_legacy_clumps += node.multimesh.instance_count
	_field = get_node_or_null(field_path) as Node3D
	if _field == null:
		if not _warned:
			push_warning("[grass] no GrassField at %s: using the legacy grass" % field_path)
			_warned = true
	else:
		for cell_node in _field.get_children():
			var cell := Cell.new()
			cell.node = cell_node as Node3D
			if cell.node == null:
				continue
			cell.bounds_min = cell.node.get_meta("cell_min")
			cell.bounds_max = cell.node.get_meta("cell_max")
			cell.clumps = cell.node.get_meta("clumps")
			for tier in TIERS:
				cell.tier_nodes.append([])
			for child in cell.node.get_children():
				var node := child as MultiMeshInstance3D
				if node != null:
					cell.tier_nodes[int(node.get_meta("grass_tier"))].append(node)
					if _material == null:
						_material = node.multimesh.mesh.surface_get_material(0) as ShaderMaterial
			_cells.append(cell)
			_tier_clumps[0] += cell.clumps[0]
			_cells_by_tier[0] += 1
	_built = true
	set_wind_strength(wind_strength)
	_apply_style()
	print("[grass] %s style, %d cells, %d full-detail clumps, %d legacy clumps, LOD %s (%.0f/%.0f/%.0f m, hysteresis %.0f m)" % [
			"v2" if is_v2_active() else "legacy", _cells.size(), _cell_total(0), _legacy_clumps,
			"on" if lod_enabled else "off", tier1_distance, tier2_distance, cull_distance, hysteresis])
	return true
