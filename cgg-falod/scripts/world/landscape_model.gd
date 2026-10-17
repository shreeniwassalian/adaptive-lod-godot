@tool
extends RefCounted
## Deterministic landscape model: mountain range, valley, river path/profile, forest density and
## the height/control/colour maps that are imported into Terrain3D. No nodes, no rendering.

const RIVER_STEP := 4.0
const BANK_WIDTH := 9.0
const BANK_HEIGHT := 1.8
const FALLOFF := 75.0
const MAX_RIVER_HALF_WIDTH := 8.0
const CLEARANCE_RADIUS := 48.0

const TEX_GRASS := 0
const TEX_CLIFF := 1
const TEX_FOREST := 2
const TEX_GRAVEL := 3

var seed_value: int
var world_size: float
var half: float
var mountain_height: float

var river_points := PackedVector2Array()
var river_surface := PackedFloat32Array()
var river_half_width := PackedFloat32Array()

var _macro: FastNoiseLite
var _hills: FastNoiseLite
var _detail: FastNoiseLite
var _ridge: FastNoiseLite
var _warp: FastNoiseLite
var _forest: FastNoiseLite
var _species: FastNoiseLite
var _meander: FastNoiseLite
var _tint: FastNoiseLite
var _bank: FastNoiseLite

var _clearance_grid := PackedFloat32Array()
var _clearance_res := 0
const _CLEARANCE_CELL := 2.0


func _init(seed_in: int, world_size_in: float, mountain_height_in: float, river_source: Vector2) -> void:
	seed_value = seed_in
	world_size = world_size_in
	half = world_size_in * 0.5
	mountain_height = mountain_height_in
	_macro = _make_noise(1, 0.0012, 3, FastNoiseLite.FRACTAL_FBM)
	_hills = _make_noise(2, 0.004, 3, FastNoiseLite.FRACTAL_FBM)
	_detail = _make_noise(3, 0.03, 3, FastNoiseLite.FRACTAL_FBM)
	_ridge = _make_noise(4, 0.0022, 4, FastNoiseLite.FRACTAL_RIDGED)
	_ridge.fractal_gain = 0.42
	_warp = _make_noise(5, 0.0025, 2, FastNoiseLite.FRACTAL_FBM)
	_forest = _make_noise(6, 0.006, 3, FastNoiseLite.FRACTAL_FBM)
	_species = _make_noise(7, 0.012, 2, FastNoiseLite.FRACTAL_FBM)
	_meander = _make_noise(8, 1.0, 2, FastNoiseLite.FRACTAL_FBM)
	_tint = _make_noise(9, 0.02, 3, FastNoiseLite.FRACTAL_FBM)
	_bank = _make_noise(10, 0.05, 2, FastNoiseLite.FRACTAL_FBM)
	_build_river(river_source)


func _make_noise(offset: int, frequency: float, octaves: int, fractal: FastNoiseLite.FractalType) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value + offset * 101
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.frequency = frequency
	return n


## Terrain height before the river is carved into it.
func base_height(x: float, z: float) -> float:
	var wx := x + 90.0 * _warp.get_noise_2d(x, z + 500.0)
	var wz := z + 90.0 * _warp.get_noise_2d(x + 300.0, z)
	var u := wx / half
	var v := wz / half
	var valley := 14.0 + 5.0 * _hills.get_noise_2d(x, z) + 0.6 * _detail.get_noise_2d(x, z)
	var north := smoothstep(-0.04, -0.56, v)
	var sides := smoothstep(0.62, 0.98, absf(u)) * 0.75
	var mask := 1.0 - (1.0 - north) * (1.0 - sides)
	if mask <= 0.0:
		return valley
	var ridge := (_ridge.get_noise_2d(x, z) + 1.0) * 0.5
	var macro := (_macro.get_noise_2d(x, z) + 1.0) * 0.5
	var elevation := mountain_height * (0.35 + 0.65 * macro) * (0.25 + 0.75 * pow(ridge, 1.3))
	return valley + mask * mask * elevation + mask * 0.5 * _detail.get_noise_2d(x, z)


func _build_river(source: Vector2) -> void:
	var pos := source
	var heading := Vector2(0.0, 1.0)
	var pts: Array[Vector2] = [pos]
	var steps := 0
	while pos.y < half + 24.0 and steps < 1200:
		var arc := steps * RIVER_STEP
		var wander := 0.9 * _meander.get_noise_2d(arc * 0.012, 17.0) + 0.5 * sin(arc * 0.011)
		var target_dir := Vector2(0.0, 1.0).rotated(wander)
		var best_cost := INF
		var best_dir := heading
		for angle in [-40.0, -25.0, -12.0, 0.0, 12.0, 25.0, 40.0]:
			var d := heading.rotated(deg_to_rad(angle))
			var p := pos + d * RIVER_STEP
			var cost := base_height(p.x, p.y) * 0.6 + (1.0 - d.dot(target_dir)) * 45.0 + absf(angle) * 0.05
			if absf(p.x) > half - 60.0:
				cost += 200.0
			if cost < best_cost:
				best_cost = cost
				best_dir = d
		heading = heading.lerp(best_dir, 0.35).normalized()
		pos += heading * RIVER_STEP
		pts.append(pos)
		steps += 1
	river_points = PackedVector2Array(pts)

	var n := river_points.size()
	river_surface.resize(n)
	river_half_width.resize(n)
	var drop := 0.012 * RIVER_STEP
	river_surface[0] = base_height(source.x, source.y) - 2.0
	for i in range(1, n):
		var p := river_points[i]
		river_surface[i] = minf(river_surface[i - 1] - drop, base_height(p.x, p.y) - 1.2)
	# Smooth, then re-impose a monotone fall so the water never runs uphill.
	var smoothed := river_surface.duplicate()
	for i in n:
		var acc := 0.0
		var cnt := 0
		for j in range(maxi(0, i - 6), mini(n, i + 7)):
			acc += river_surface[j]
			cnt += 1
		smoothed[i] = acc / cnt
	for i in range(1, n):
		smoothed[i] = minf(smoothed[i], smoothed[i - 1] - drop * 0.5)
	river_surface = smoothed
	for i in n:
		var t := float(i) / float(n - 1)
		river_half_width[i] = lerpf(2.0, MAX_RIVER_HALF_WIDTH, smoothstep(0.0, 1.0, pow(t, 0.8)))


func river_length() -> float:
	return (river_points.size() - 1) * RIVER_STEP


## Squared-distance and fractional segment index of the nearest river segment on a cell-spaced grid.
func rasterize_river(res: int, cell: float, radius: float) -> Dictionary:
	var dist2 := PackedFloat32Array()
	dist2.resize(res * res)
	dist2.fill(1.0e12)
	var arc := PackedFloat32Array()
	arc.resize(res * res)
	var count := river_points.size()
	for i in count - 1:
		var a := river_points[i]
		var b := river_points[i + 1]
		var abx := b.x - a.x
		var abz := b.y - a.y
		var len2 := abx * abx + abz * abz
		var ix0 := maxi(0, int(floor((minf(a.x, b.x) - radius + half) / cell)))
		var ix1 := mini(res - 1, int(ceil((maxf(a.x, b.x) + radius + half) / cell)))
		var iz0 := maxi(0, int(floor((minf(a.y, b.y) - radius + half) / cell)))
		var iz1 := mini(res - 1, int(ceil((maxf(a.y, b.y) + radius + half) / cell)))
		for iz in range(iz0, iz1 + 1):
			var pz := -half + iz * cell
			for ix in range(ix0, ix1 + 1):
				var px := -half + ix * cell
				var t := clampf(((px - a.x) * abx + (pz - a.y) * abz) / len2, 0.0, 1.0)
				var dx := px - (a.x + abx * t)
				var dz := pz - (a.y + abz * t)
				var d2 := dx * dx + dz * dz
				var idx := iz * res + ix
				if d2 < dist2[idx]:
					dist2[idx] = d2
					arc[idx] = i + t
	return {"dist2": dist2, "arc": arc}


## Distance beyond the water's edge (negative inside the channel); capped at CLEARANCE_RADIUS.
func river_clearance(x: float, z: float) -> float:
	if _clearance_grid.is_empty():
		_clearance_res = int(world_size / _CLEARANCE_CELL) + 1
		var r := rasterize_river(_clearance_res, _CLEARANCE_CELL, CLEARANCE_RADIUS + MAX_RIVER_HALF_WIDTH)
		var d2: PackedFloat32Array = r["dist2"]
		var arc: PackedFloat32Array = r["arc"]
		_clearance_grid.resize(d2.size())
		for k in d2.size():
			if d2[k] > 1.0e11:
				_clearance_grid[k] = CLEARANCE_RADIUS
			else:
				var i := mini(int(arc[k]), river_half_width.size() - 2)
				var w := lerpf(river_half_width[i], river_half_width[i + 1], arc[k] - i)
				_clearance_grid[k] = minf(sqrt(d2[k]) - w, CLEARANCE_RADIUS)
	var fx := clampf((x + half) / _CLEARANCE_CELL, 0.0, _clearance_res - 1.001)
	var fz := clampf((z + half) / _CLEARANCE_CELL, 0.0, _clearance_res - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var g := _clearance_grid
	var r0 := lerpf(g[iz * _clearance_res + ix], g[iz * _clearance_res + ix + 1], tx)
	var r1 := lerpf(g[(iz + 1) * _clearance_res + ix], g[(iz + 1) * _clearance_res + ix + 1], tx)
	return lerpf(r0, r1, tz)


## 0..1 tree cover. `clearance` is the distance from the water edge.
func forest_density(x: float, z: float, height: float, slope_deg: float, clearance: float) -> float:
	var altitude := smoothstep(150.0, 95.0, height)
	var slope := smoothstep(32.0, 20.0, slope_deg)
	var cover := smoothstep(0.30, 0.55, (_forest.get_noise_2d(x, z) + 1.0) * 0.5)
	var water := smoothstep(6.0, 16.0, clearance)
	return altitude * slope * cover * water


## Probability that a tree at this spot is a spruce (conifer) rather than broadleaf.
func spruce_fraction(x: float, z: float, height: float) -> float:
	return clampf(smoothstep(35.0, 110.0, height) * 0.8 + 0.25 + 0.35 * _species.get_noise_2d(x, z), 0.0, 1.0)


## Builds the height, control and colour images for a res x res grid at 1 m spacing.
func build_maps(res: int) -> Dictionary:
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	for iz in res:
		var z := -half + iz
		for ix in res:
			heights[iz * res + ix] = base_height(-half + ix, z)

	var radius := MAX_RIVER_HALF_WIDTH + BANK_WIDTH + FALLOFF
	var r := rasterize_river(res, 1.0, radius)
	var dist2: PackedFloat32Array = r["dist2"]
	var arc: PackedFloat32Array = r["arc"]
	var clearance := PackedFloat32Array()
	clearance.resize(res * res)
	clearance.fill(CLEARANCE_RADIUS)
	var last := river_points.size() - 2
	for idx in res * res:
		if dist2[idx] > 1.0e11:
			continue
		var d := maxf(sqrt(dist2[idx]) + 2.4 * _bank.get_noise_2d(-half + idx % res, -half + idx / res), 0.0)
		var i := mini(int(arc[idx]), last)
		var t := arc[idx] - i
		var surface := lerpf(river_surface[i], river_surface[i + 1], t)
		var w := lerpf(river_half_width[i], river_half_width[i + 1], t)
		var profile: float
		if d <= w:
			var depth := 0.5 + 0.08 * w
			var q := d / w
			profile = -depth * (1.0 - q * q)
		elif d <= w + BANK_WIDTH:
			profile = BANK_HEIGHT * smoothstep(0.0, 1.0, (d - w) / BANK_WIDTH)
		else:
			profile = BANK_HEIGHT + (d - w - BANK_WIDTH) * 0.05
		var blend := 1.0 - smoothstep(w + BANK_WIDTH, w + BANK_WIDTH + FALLOFF, d)
		heights[idx] = lerpf(heights[idx], surface + profile, blend)
		clearance[idx] = minf(d - w, CLEARANCE_RADIUS)

	# Soften creases where the nearest river segment changes (bend interiors), away from the channel.
	for _pass in 3:
		var src := heights.duplicate()
		for iz in range(1, res - 1):
			for ix in range(1, res - 1):
				var bi := iz * res + ix
				if dist2[bi] > 1.0e11 or clearance[bi] < 6.0:
					continue
				var avg := (src[bi - res - 1] + src[bi - res] + src[bi - res + 1] + src[bi - 1] + src[bi]
						+ src[bi + 1] + src[bi + res - 1] + src[bi + res] + src[bi + res + 1]) / 9.0
				heights[bi] = lerpf(src[bi], avg, 0.8)

	var control := PackedByteArray()
	control.resize(res * res * 4)
	var color := PackedByteArray()
	color.resize(res * res * 4)
	var slope_sum := 0.0
	var slope_max := 0.0
	for iz in res:
		var z := -half + iz
		for ix in res:
			var idx := iz * res + ix
			var h := heights[idx]
			var hx := heights[iz * res + mini(ix + 1, res - 1)] - heights[iz * res + maxi(ix - 1, 0)]
			var hz := heights[mini(iz + 1, res - 1) * res + ix] - heights[maxi(iz - 1, 0) * res + ix]
			var slope := rad_to_deg(atan(sqrt(hx * hx + hz * hz) * 0.5))
			slope_sum += slope
			slope_max = maxf(slope_max, slope)
			var x := -half + ix
			var clear := clearance[idx]
			var w_cliff := maxf(smoothstep(24.0, 40.0, slope), smoothstep(140.0, 190.0, h))
			var w_gravel := 1.0 - smoothstep(0.8, 6.5, clear)
			var w_forest := forest_density(x, z, h, slope, clear) * (1.0 - w_cliff)
			var w_grass := maxf(0.05, 1.0 - maxf(w_cliff, maxf(w_forest, w_gravel)))
			var weights: Array[float] = [w_grass, w_cliff, w_forest, w_gravel]
			var first := 0
			for k in range(1, 4):
				if weights[k] > weights[first]:
					first = k
			var second := -1
			for k in 4:
				if k != first and (second < 0 or weights[k] > weights[second]):
					second = k
			var total := weights[first] + weights[second]
			var mix := int(round(255.0 * weights[second] / total)) if total > 0.0 else 0
			control.encode_u32(idx * 4, (first << 27) | (second << 22) | (mix << 14))
			var tint := (_tint.get_noise_2d(x, z) + 1.0) * 0.5
			var b := int(round(255.0 * (0.86 + 0.14 * tint)))
			color[idx * 4] = b
			color[idx * 4 + 1] = b
			color[idx * 4 + 2] = int(round(b * 0.96))
			color[idx * 4 + 3] = 127

	var height_bytes := heights.to_byte_array()
	return {
		"height": Image.create_from_data(res, res, false, Image.FORMAT_RF, height_bytes),
		"control": Image.create_from_data(res, res, false, Image.FORMAT_RF, control),
		"color": Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, color),
		"heights": heights,
		"slope_mean": slope_sum / (res * res),
		"slope_max": slope_max,
	}


## Flat ribbon along the river at water-surface height; edges tuck under the banks.
func build_river_mesh() -> ArrayMesh:
	var n := river_points.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var arc := 0.0
	for i in n:
		var p := river_points[i]
		var tangent := (river_points[mini(i + 1, n - 1)] - river_points[maxi(i - 1, 0)]).normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var extent := river_half_width[i] + 2.5
		var y := river_surface[i]
		for k in 3:
			var offset := (k - 1) * extent
			vertices.append(Vector3(p.x + side.x * offset, y, p.y + side.y * offset))
			normals.append(Vector3.UP)
			uvs.append(Vector2(k * 0.5, arc / 6.0))
		arc += RIVER_STEP
	for i in n - 1:
		for k in 2:
			var a := i * 3 + k
			var b := a + 1
			var c := a + 3
			var d := c + 1
			# Godot front faces are clockwise seen from above (+Y): a-c-b / b-c-d.
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
