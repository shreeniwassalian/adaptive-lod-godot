@tool
extends RefCounted
## Builds the procedural grass field: clustered, deterministic clump placement on the Terrain3D heights,
## stored as 32 m cells. Every cell holds, for each of three detail tiers, a few MultiMeshInstance3D nodes
## (one per mesh variant and kind), so a controller can switch a whole cell between tiers by toggling node
## visibility, with no per-clump nodes. The saved scene has tier 0 visible everywhere (full detail).
##
## Two kinds of clump: tall tufts (clustered) and short turf patches (a dense fill between the tufts). Tiers are
## nested by a deterministic random rank per kind: tuft tier 1 is the first 40 % of a cell's tufts, tier 2 the first
## 12 %; turf tier 1 the first 35 %, none at tier 2. Each tier uses larger clumps (baked into their transforms) to
## keep the ground covered, and a simpler mesh.
## Same seed, terrain and settings always give the same placement.

const GrassMeshes := preload("res://scripts/world/grass_meshes.gd")
const LandscapeModel := preload("res://scripts/world/landscape_model.gd")

const CELL_SIZE := 32.0
## Fraction of a cell's tufts kept per tier, and the clump scale used to compensate.
const TIER_DENSITY: Array[float] = [1.0, 0.40, 0.12]
const TIER_SCALE: Array[float] = [1.0, 1.2, 1.6]
## The same for the turf patches (two tiers: none at tier 2).
const TURF_TIER_DENSITY: Array[float] = [1.0, 0.35]
const TURF_TIER_SCALE: Array[float] = [1.0, 1.35]
const TURF_SPACING := 1.1
const CLUSTER_SPACING := 2.9
const CLUSTER_RADIUS := 1.3
const SINK := 0.03

var model: LandscapeModel
var terrain: Terrain3D
var seed_value: int = 1337
var world_size: float = 1024.0
## Multiplies the chance that a cluster centre is accepted (1.0 = the densest sensible lawn).
var density_scale: float = 1.0
## Multiplies the chance that a turf patch is placed (0 = no turf, tufts only).
var turf_scale: float = 1.0
var stats := {}

var _meadow: FastNoiseLite
var _lush: FastNoiseLite
var _dry: FastNoiseLite
var _material: ShaderMaterial
var _meshes: Array = []  # [kind][level][variant] -> ArrayMesh


func build() -> Node3D:
	_setup_noise()
	_material = GrassMeshes.material()
	_meshes.clear()
	for kind in [GrassMeshes.TUFT, GrassMeshes.TURF]:
		var levels: Array = []
		for level in GrassMeshes.levels(kind):
			var variants: Array = []
			for v in GrassMeshes.VARIANTS[kind][level]:
				variants.append(GrassMeshes.build(level, v, _material, kind))
			levels.append(variants)
		_meshes.append(levels)
	stats = {"cells": 0, "clumps": 0, "tuft_clumps": 0, "turf_clumps": 0, "tier_clumps": [0, 0, 0], "multimesh_nodes": 0}

	var root := Node3D.new()
	root.name = "GrassField"
	root.set_meta("cell_size", CELL_SIZE)
	var half := world_size * 0.5
	var cells_per_side := int(ceil(world_size / CELL_SIZE))
	for cz in cells_per_side:
		for cx in cells_per_side:
			var cell := _build_cell(cx, cz, Vector2(-half + cx * CELL_SIZE, -half + cz * CELL_SIZE))
			if cell != null:
				root.add_child(cell)
				stats["cells"] += 1
	_set_owner_recursive(root, root)
	return root


func _setup_noise() -> void:
	_meadow = _noise(seed_value + 11, 0.011)
	_lush = _noise(seed_value + 23, 0.035)
	_dry = _noise(seed_value + 37, 0.018)


func _noise(noise_seed: int, frequency: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = noise_seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3
	n.frequency = frequency
	return n


func _rng(cx: int, cz: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed_value * 73856093) ^ (cx * 19349663) ^ (cz * 83492791) ^ (salt * 2654435761)
	return rng


## (height, normal.x, normal.z, clearance from the water edge); height is NAN outside the terrain.
func _sample(x: float, z: float) -> Vector4:
	var p := Vector3(x, 0.0, z)
	var h := terrain.data.get_height(p)
	if is_nan(h):
		return Vector4(NAN, 0.0, 0.0, 0.0)
	var n := terrain.data.get_normal(p)
	return Vector4(h, n.x, n.z, model.river_clearance(x, z))


func _slope_degrees(s: Vector4) -> float:
	return rad_to_deg(acos(sqrt(maxf(0.0, 1.0 - s.y * s.y - s.z * s.z))))


## 0..1 chance that grass grows here (same ingredients as the old grass: forest shade, slope, altitude, water).
func _suitability(x: float, z: float, s: Vector4) -> float:
	var slope := _slope_degrees(s)
	var forest := model.forest_density(x, z, s.x, slope, s.w)
	var density := lerpf(1.0, 0.25, smoothstep(0.05, 0.45, forest))
	density *= smoothstep(32.0, 22.0, slope) * smoothstep(150.0, 110.0, s.x) * smoothstep(1.0, 3.0, s.w)
	# Low-frequency meadow patches: lush areas and thin areas, not an even carpet.
	var meadow := lerpf(0.3, 1.0, smoothstep(-0.35, 0.45, _meadow.get_noise_2d(x, z)))
	return density * meadow * density_scale


func _build_cell(cx: int, cz: int, origin: Vector2) -> Node3D:
	var groups: Array = [_tuft_group(cx, cz, origin), _turf_group(cx, cz, origin) if turf_scale > 0.0 else _empty_group()]
	var total := 0
	for group in groups:
		total += (group["transforms"] as Array).size()
	if total == 0:
		return null

	var cell := Node3D.new()
	cell.name = "Cell_%d_%d" % [cx, cz]
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)
	for group in groups:
		for t in (group["transforms"] as Array[Transform3D]):
			bounds_min = bounds_min.min(t.origin)
			bounds_max = bounds_max.max(t.origin)
	# Pad by the tallest blade so distance tests use the whole clump.
	cell.set_meta("cell_min", bounds_min - Vector3(0.6, 0.1, 0.6))
	cell.set_meta("cell_max", bounds_max + Vector3(0.6, 1.2, 0.6))
	var clump_counts := PackedInt32Array([0, 0, 0])
	for kind in groups.size():
		var group: Dictionary = groups[kind]
		var transforms: Array[Transform3D] = group["transforms"]
		if transforms.is_empty():
			continue
		var keys: Array[float] = group["keys"]
		var order := range(transforms.size())
		order.sort_custom(func(a: int, b: int) -> bool: return keys[a] < keys[b])
		for tier in GrassMeshes.levels(kind):
			var density: float = TIER_DENSITY[tier] if kind == GrassMeshes.TUFT else TURF_TIER_DENSITY[tier]
			var keep := mini(transforms.size(), maxi(1, int(ceil(transforms.size() * density))))
			clump_counts[tier] += keep
			_add_tier(cell, kind, tier, keep, order, transforms, group["colors"])
			stats["tier_clumps"][tier] += keep
		stats["clumps"] += transforms.size()
		stats["tuft_clumps" if kind == GrassMeshes.TUFT else "turf_clumps"] += transforms.size()
	cell.set_meta("clumps", clump_counts)
	return cell


func _empty_group() -> Dictionary:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var keys: Array[float] = []
	return {"transforms": transforms, "colors": colors, "keys": keys}


## The taller tufts: clusters of 2-7 clumps on a jittered grid, thinned by suitability.
func _tuft_group(cx: int, cz: int, origin: Vector2) -> Dictionary:
	var rng := _rng(cx, cz, 31)
	var group := _empty_group()
	var steps := int(ceil(CELL_SIZE / CLUSTER_SPACING))
	var step := CELL_SIZE / steps
	for iz in steps:
		for ix in steps:
			var centre := Vector2(origin.x + (ix + rng.randf()) * step, origin.y + (iz + rng.randf()) * step)
			var accept := rng.randf()
			var count := 2 + rng.randi() % 6
			var cs := _sample(centre.x, centre.y)
			if is_nan(cs.x) or accept > _suitability(centre.x, centre.y, cs):
				continue
			for k in count:
				var angle := rng.randf() * TAU
				var radius := CLUSTER_RADIUS * sqrt(rng.randf())
				var x := centre.x + cos(angle) * radius
				var z := centre.y + sin(angle) * radius
				var yaw := rng.randf() * TAU
				var size := rng.randf()
				var squash := rng.randf()
				var value := rng.randf()
				var key := rng.randf()
				var s := _sample(x, z)
				if is_nan(s.x) or _slope_degrees(s) > 38.0 or s.w < 1.0:
					continue
				var lush := _lush.get_noise_2d(x, z)
				var scale_value := lerpf(0.8, 1.5, pow(size, 1.2)) * lerpf(0.85, 1.2, (lush + 1.0) * 0.5)
				_append_clump(group, x, z, s, yaw, scale_value, squash, value, key)
	return group


## The short turf patches: one per ~1.1 m on a jittered grid wherever grass grows, so the ground between the
## tufts is covered. A separate random stream, so adding turf never moves a tuft.
func _turf_group(cx: int, cz: int, origin: Vector2) -> Dictionary:
	var rng := _rng(cx, cz, 47)
	var group := _empty_group()
	var steps := int(ceil(CELL_SIZE / TURF_SPACING))
	var step := CELL_SIZE / steps
	for iz in steps:
		for ix in steps:
			var x := origin.x + (ix + rng.randf()) * step
			var z := origin.y + (iz + rng.randf()) * step
			var accept := rng.randf()
			var yaw := rng.randf() * TAU
			var size := rng.randf()
			var squash := rng.randf()
			var value := rng.randf()
			var key := rng.randf()
			var s := _sample(x, z)
			if is_nan(s.x) or _slope_degrees(s) > 38.0 or s.w < 1.0:
				continue
			if accept > smoothstep(0.06, 0.45, _suitability(x, z, s)) * turf_scale:
				continue
			var lush := _lush.get_noise_2d(x, z)
			var scale_value := lerpf(0.8, 1.4, size) * lerpf(0.85, 1.2, (lush + 1.0) * 0.5)
			_append_clump(group, x, z, s, yaw, scale_value, squash, value, key)
	return group


## Adds one clump standing on the terrain at (x, z): leans with the slope, spins, scales, and gets a tint.
func _append_clump(group: Dictionary, x: float, z: float, s: Vector4, yaw: float, scale_value: float,
		squash: float, value: float, key: float) -> void:
	var xz_scale := scale_value * lerpf(0.85, 1.2, squash)
	var y_scale := scale_value * lerpf(0.8, 1.3, squash)
	# Lean slightly with the slope, then spin around the clump's own axis.
	var up := Vector3(s.y * 0.35, 1.0, s.z * 0.35).normalized()
	var basis := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, yaw)
	basis = basis.scaled_local(Vector3(xz_scale, y_scale, xz_scale))
	(group["transforms"] as Array[Transform3D]).append(Transform3D(basis, Vector3(x, s.x - SINK, z)))
	(group["keys"] as Array[float]).append(key)
	var dry := smoothstep(0.1, 0.55, _dry.get_noise_2d(x, z))
	var v := lerpf(0.72, 1.0, value)
	(group["colors"] as Array[Color]).append(Color(v, v, v).lerp(Color(1.0, 0.86, 0.52) * v, dry * 0.65))


## One MultiMeshInstance3D per mesh variant holding this tier's share of the first `keep` clumps of a kind.
func _add_tier(cell: Node3D, kind: int, tier: int, keep: int, order: Array, transforms: Array[Transform3D], colors: Array[Color]) -> void:
	var variants: int = GrassMeshes.VARIANTS[kind][tier]
	var tier_scale: float = TIER_SCALE[tier] if kind == GrassMeshes.TUFT else TURF_TIER_SCALE[tier]
	var per_variant: Array = []
	for v in variants:
		per_variant.append([])
	for j in keep:
		(per_variant[j % variants] as Array).append(order[j])
	for v in variants:
		var ids: Array = per_variant[v]
		if ids.is_empty():
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = _meshes[kind][tier][v]
		multimesh.instance_count = ids.size()
		for i in ids.size():
			var xform: Transform3D = transforms[ids[i]]
			if tier_scale != 1.0:
				xform.basis = xform.basis.scaled_local(Vector3.ONE * tier_scale)
			multimesh.set_instance_transform(i, xform)
			multimesh.set_instance_color(i, colors[ids[i]])
		var node := MultiMeshInstance3D.new()
		node.name = "%s%d_V%d" % ["T" if kind == GrassMeshes.TUFT else "U", tier, v]
		node.multimesh = multimesh
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visible = tier == 0
		node.set_meta("vegetation_kind", "grass")
		node.set_meta("grass_tier", tier)
		node.set_meta("grass_kind", "tuft" if kind == GrassMeshes.TUFT else "turf")
		cell.add_child(node)
		stats["multimesh_nodes"] += 1


func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_set_owner_recursive(child, scene_owner)
