@tool
extends RefCounted
## Procedural placeholder vegetation meshes (no external model assets are available in the project).
## Spruce and broadleaf trees have three LOD levels (0 = most detailed). Materials use noise-based
## albedo textures; vertex colour is only a grey ambient-occlusion multiplier.

const SPRUCE_HEIGHT := 16.0
const BROADLEAF_HEIGHT := 12.0
const SPRUCE_TRUNK_RADIUS := 0.32
const BROADLEAF_TRUNK_RADIUS := 0.42


static func spruce_materials() -> Array[Material]:
	return [_bark_material(), _foliage_material(Color(0.08, 0.18, 0.09), Color(0.18, 0.33, 0.15), 0.17)]


static func broadleaf_materials() -> Array[Material]:
	return [_bark_material(), _foliage_material(Color(0.10, 0.21, 0.06), Color(0.25, 0.38, 0.11), 0.09)]


static func bush_material() -> Material:
	return _foliage_material(Color(0.09, 0.19, 0.07), Color(0.21, 0.34, 0.10), 0.12)


static func grass_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.30, 0.42, 0.14)
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Surface 0 = trunk (bark), surface 1 = foliage.
static func build_spruce(lod: int) -> ArrayMesh:
	lod = clampi(lod, 0, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1001
	var tiers: int = [16, 10, 6][lod]
	var tips: int = [10, 8, 6][lod]
	var trunk_sides: int = [8, 6, 4][lod]
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var path: Array[Vector3] = []
	var radii: Array[float] = []
	var segments: int = [5, 3, 2][lod]
	for i in segments + 1:
		var t := float(i) / float(segments)
		var y := lerpf(-0.4, SPRUCE_HEIGHT * 0.96, t)
		path.append(Vector3(0.22 * sin(y * 0.35), y, 0.15 * sin(y * 0.5 + 1.0)))
		radii.append(lerpf(SPRUCE_TRUNK_RADIUS, 0.04, pow(t, 0.8)))
	_add_tube(trunk, path, radii, trunk_sides, 3.0)

	var leaves := SurfaceTool.new()
	leaves.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in tiers:
		var t := float(i) / float(tiers - 1)
		var y := lerpf(2.2, SPRUCE_HEIGHT - 1.1, t)
		var radius := lerpf(3.0, 0.4, pow(t, 0.85))
		var rise := lerpf(2.4, 1.1, t)
		var center := Vector3(0.22 * sin(y * 0.35), 0.0, 0.15 * sin(y * 0.5 + 1.0))
		var twist := rng.randf() * TAU
		var apex := Vector3(center.x, y + rise, center.z)
		var ring: Array[Vector3] = []
		var ring_n: Array[Vector3] = []
		var ring_ao: Array[float] = []
		for k in tips * 2:
			var tip := k % 2 == 0
			var angle := twist + TAU * float(k) / float(tips * 2)
			var r := radius * (rng.randf_range(0.88, 1.15) if tip else rng.randf_range(0.42, 0.58))
			var dir := Vector3(cos(angle), 0.0, sin(angle))
			var drop := 0.28 * radius if tip else 0.04 * radius
			ring.append(Vector3(center.x + dir.x * r, y - drop, center.z + dir.z * r))
			ring_n.append((dir * 0.85 + Vector3.UP * 0.55).normalized())
			ring_ao.append(1.0 if tip else 0.78)
		var count := ring.size()
		for k in count:
			var kn := (k + 1) % count
			_add_vertex(leaves, apex, Vector3.UP, 0.6)
			_add_vertex(leaves, ring[k], ring_n[k], ring_ao[k])
			_add_vertex(leaves, ring[kn], ring_n[kn], ring_ao[kn])
	var mesh := ArrayMesh.new()
	trunk.commit(mesh)
	leaves.commit(mesh)
	_apply_materials(mesh, spruce_materials())
	return mesh


## Surface 0 = trunk and limbs (bark), surface 1 = crown clumps (foliage).
static func build_broadleaf(lod: int) -> ArrayMesh:
	lod = clampi(lod, 0, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2002
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.9
	var limbs: int = [6, 5, 4][lod]
	var trunk_sides: int = [8, 6, 5][lod]
	var clump_level: int = [1, 0, 0][lod]
	var clump_scale: float = [1.0, 1.12, 1.3][lod]

	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk_path: Array[Vector3] = [Vector3(0.0, -0.4, 0.0), Vector3(0.12, 1.8, 0.05), Vector3(-0.05, 3.6, 0.1), Vector3(0.0, 4.8, 0.0)]
	_add_tube(wood, trunk_path, [0.46, 0.38, 0.30, 0.22], trunk_sides, 2.5)

	var clump_centers: Array[Vector3] = []
	var clump_radii: Array[float] = []
	for i in limbs:
		var azimuth := TAU * float(i) / float(limbs) + rng.randf_range(-0.35, 0.35)
		var elevation := deg_to_rad(rng.randf_range(50.0, 74.0))
		var length := rng.randf_range(3.0, 4.4)
		var start := Vector3(0.0, rng.randf_range(2.6, 4.3), 0.0)
		var dir := Vector3(cos(azimuth) * cos(elevation), sin(elevation), sin(azimuth) * cos(elevation))
		var mid := start + dir * length * 0.5 + Vector3(0.0, 0.25, 0.0)
		var tip := start + dir * length
		_add_tube(wood, [start, mid, tip], [0.2, 0.13, 0.06], 5 if lod > 0 else 6, 2.0)
		clump_centers.append(tip + Vector3(0.0, 0.7, 0.0))
		clump_radii.append(rng.randf_range(2.1, 2.8))
		if lod == 0:
			clump_centers.append(mid + dir * 0.4 + Vector3(0.0, 1.1, 0.0))
			clump_radii.append(rng.randf_range(1.7, 2.2))
	clump_centers.append(Vector3(0.0, BROADLEAF_HEIGHT - 2.1, 0.0))
	clump_radii.append(2.4)
	if lod == 0:
		clump_centers.append(Vector3(1.6, BROADLEAF_HEIGHT - 6.0, -1.0))
		clump_radii.append(2.0)
		clump_centers.append(Vector3(-1.7, BROADLEAF_HEIGHT - 6.6, 1.2))
		clump_radii.append(1.9)

	var leaves := SurfaceTool.new()
	leaves.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sphere := _icosphere(clump_level)
	for c in clump_centers.size():
		var center := clump_centers[c]
		var radius := clump_radii[c] * clump_scale
		var verts: Array[Vector3] = []
		for v in sphere["verts"]:
			var dir: Vector3 = v
			var bump := 1.0 + 0.3 * noise.get_noise_3d(dir.x * 2.0 + c * 7.0, dir.y * 2.0, dir.z * 2.0)
			verts.append(center + Vector3(dir.x * radius * bump, dir.y * radius * 0.78 * bump, dir.z * radius * bump))
		var faces: Array = sphere["faces"]
		for f in range(0, faces.size(), 3):
			for k in 3:
				var index: int = faces[f + k]
				var dir: Vector3 = sphere["verts"][index]
				var ao := 0.5 + 0.5 * (dir.y * 0.5 + 0.5)
				_add_vertex(leaves, verts[index], (dir * 0.8 + Vector3.UP * 0.4).normalized(), ao)
	var mesh := ArrayMesh.new()
	wood.commit(mesh)
	leaves.commit(mesh)
	_apply_materials(mesh, broadleaf_materials())
	return mesh


static func build_bush() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3003
	var noise := FastNoiseLite.new()
	noise.seed = 31
	noise.frequency = 1.3
	var sphere := _icosphere(1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c in 5:
		var angle := rng.randf() * TAU
		var offset := rng.randf_range(0.0, 0.7)
		var center := Vector3(cos(angle) * offset, rng.randf_range(0.35, 0.7), sin(angle) * offset)
		var radius := rng.randf_range(0.5, 0.85)
		var verts: Array[Vector3] = []
		for v in sphere["verts"]:
			var dir: Vector3 = v
			var bump := 1.0 + 0.3 * noise.get_noise_3d(dir.x * 2.0 + c * 5.0, dir.y * 2.0, dir.z * 2.0)
			verts.append(center + Vector3(dir.x * radius * bump, dir.y * radius * 0.8 * bump, dir.z * radius * bump))
		var faces: Array = sphere["faces"]
		for f in range(0, faces.size(), 3):
			for k in 3:
				var index: int = faces[f + k]
				var dir: Vector3 = sphere["verts"][index]
				_add_vertex(st, verts[index], (dir * 0.8 + Vector3.UP * 0.4).normalized(), 0.55 + 0.45 * (dir.y * 0.5 + 0.5))
	var mesh := st.commit()
	mesh.surface_set_material(0, bush_material())
	return mesh


static func build_grass_clump() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4004
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 9:
		var yaw := rng.randf() * TAU
		var side := Vector3(cos(yaw), 0.0, sin(yaw))
		var fwd := Vector3(-side.z, 0.0, side.x)
		var root := Vector3(rng.randf_range(-0.18, 0.18), 0.0, rng.randf_range(-0.18, 0.18))
		var half_width := rng.randf_range(0.025, 0.04)
		var height := rng.randf_range(0.28, 0.6)
		var lean := rng.randf_range(0.05, 0.22)
		var mid := root + fwd * lean * 0.35 + Vector3.UP * height * 0.55
		var tip := root + fwd * lean + Vector3.UP * height
		var n := fwd
		_add_vertex(st, root - side * half_width, n, 0.45)
		_add_vertex(st, root + side * half_width, n, 0.45)
		_add_vertex(st, mid - side * half_width * 0.7, n, 0.8)
		_add_vertex(st, root + side * half_width, n, 0.45)
		_add_vertex(st, mid + side * half_width * 0.7, n, 0.8)
		_add_vertex(st, mid - side * half_width * 0.7, n, 0.8)
		_add_vertex(st, mid - side * half_width * 0.7, n, 0.8)
		_add_vertex(st, mid + side * half_width * 0.7, n, 0.8)
		_add_vertex(st, tip, n, 1.0)
	var mesh := st.commit()
	mesh.surface_set_material(0, grass_material())
	return mesh


static func triangle_count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		total += ((indices as PackedInt32Array).size() if indices != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return total


static func _apply_materials(mesh: ArrayMesh, materials: Array[Material]) -> void:
	for i in materials.size():
		mesh.surface_set_material(i, materials[i])


static func _add_vertex(st: SurfaceTool, position: Vector3, normal: Vector3, ao: float) -> void:
	st.set_color(Color(ao, ao, ao))
	st.set_normal(normal)
	st.set_uv(Vector2(position.x * 0.21 + position.z * 0.13, position.y * 0.23 + position.z * 0.11))
	st.add_vertex(position)


## Tube along `path` with per-point radii; smooth radial normals, bark-style UVs.
static func _add_tube(st: SurfaceTool, path: Array[Vector3], radii: Array[float], sides: int, v_scale: float) -> void:
	var rings: Array = []
	var normals: Array = []
	for i in path.size():
		var tangent := (path[mini(i + 1, path.size() - 1)] - path[maxi(i - 1, 0)]).normalized()
		var reference := Vector3.UP if absf(tangent.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var side := tangent.cross(reference).normalized()
		var up := side.cross(tangent).normalized()
		var ring: Array[Vector3] = []
		var ring_n: Array[Vector3] = []
		for k in sides:
			var angle := TAU * float(k) / float(sides)
			var radial := side * cos(angle) + up * sin(angle)
			ring.append(path[i] + radial * radii[i])
			ring_n.append(radial)
		rings.append(ring)
		normals.append(ring_n)
	var length_acc := 0.0
	var v_values: Array[float] = [0.0]
	for i in range(1, path.size()):
		length_acc += path[i].distance_to(path[i - 1])
		v_values.append(length_acc * v_scale * 0.25)
	for i in path.size() - 1:
		for k in sides:
			var kn := (k + 1) % sides
			var corners := [[i, k, k], [i, kn, k + 1], [i + 1, kn, k + 1], [i + 1, k, k]]
			var quad: Array[Vector3] = []
			var quad_n: Array[Vector3] = []
			var quad_uv: Array[Vector2] = []
			for corner in corners:
				quad.append(rings[corner[0]][corner[1]])
				quad_n.append(normals[corner[0]][corner[1]])
				quad_uv.append(Vector2(float(corner[2]) / float(sides) * 3.0, v_values[corner[0]]))
			for tri in [[0, 1, 2], [0, 2, 3]]:
				var a: Vector3 = quad[tri[0]]
				var b: Vector3 = quad[tri[1]]
				var c: Vector3 = quad[tri[2]]
				var order: Array = tri
				var outward: Vector3 = quad_n[tri[0]] + quad_n[tri[1]] + quad_n[tri[2]]
				if (b - a).cross(c - a).dot(outward) > 0.0:
					order = [tri[0], tri[2], tri[1]]
				for index in order:
					st.set_color(Color(0.9, 0.9, 0.9))
					st.set_normal(quad_n[index])
					st.set_uv(quad_uv[index])
					st.add_vertex(quad[index])


## Unit icosphere; `level` subdivisions. Returns {"verts": Array[Vector3], "faces": Array[int]}.
static func _icosphere(level: int) -> Dictionary:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		verts[i] = verts[i].normalized()
	var faces: Array[int] = [
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	]
	for _step in level:
		var cache := {}
		var next_faces: Array[int] = []
		for f in range(0, faces.size(), 3):
			var mids: Array[int] = []
			for e in 3:
				var a := faces[f + e]
				var b := faces[f + (e + 1) % 3]
				var key := mini(a, b) * 100000 + maxi(a, b)
				if not cache.has(key):
					cache[key] = verts.size()
					verts.append(((verts[a] + verts[b]) * 0.5).normalized())
				mids.append(cache[key])
			var a0 := faces[f]
			var b0 := faces[f + 1]
			var c0 := faces[f + 2]
			next_faces.append_array([a0, mids[0], mids[2], b0, mids[1], mids[0], c0, mids[2], mids[1], mids[0], mids[1], mids[2]])
		faces = next_faces
	# Winding: make every face clockwise seen from outside (Godot front face).
	for f in range(0, faces.size(), 3):
		var a := verts[faces[f]]
		var b := verts[faces[f + 1]]
		var c := verts[faces[f + 2]]
		if (b - a).cross(c - a).dot(a + b + c) > 0.0:
			var tmp := faces[f + 1]
			faces[f + 1] = faces[f + 2]
			faces[f + 2] = tmp
	return {"verts": verts, "faces": faces}


static func _bark_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _noise_texture(5, 0.045, Color(0.13, 0.09, 0.065), Color(0.30, 0.22, 0.15))
	mat.roughness = 0.95
	return mat


static func _foliage_material(dark: Color, light: Color, frequency: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _noise_texture(9, frequency, dark, light)
	mat.roughness = 0.82
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func _noise_texture(noise_seed: int, frequency: float, dark: Color, light: Color) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = frequency
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([dark, light])
	gradient.offsets = PackedFloat32Array([0.25, 0.8])
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.color_ramp = gradient
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	return tex
