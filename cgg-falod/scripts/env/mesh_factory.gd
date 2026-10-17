@tool
extends RefCounted
## Procedural low-poly meshes: three tree LOD variants, a grass clump and a rock.
## All meshes use vertex colors, so one shared material covers everything.

const TREE_LOD_NAMES: PackedStringArray = ["high", "medium", "low"]

const TRUNK_COLOR := Color(0.36, 0.24, 0.14)
const FOLIAGE_DARK := Color(0.10, 0.34, 0.14)
const FOLIAGE_MID := Color(0.15, 0.42, 0.17)
const FOLIAGE_LIGHT := Color(0.22, 0.50, 0.20)


static func make_material(double_sided: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func build_tree(lod_level: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match clampi(lod_level, 0, 2):
		0:
			_add_frustum(st, 0.0, 2.2, 0.20, 0.12, 8, TRUNK_COLOR)
			_add_frustum(st, 1.6, 2.0, 1.50, 0.0, 10, FOLIAGE_DARK)
			_add_frustum(st, 2.8, 1.8, 1.15, 0.0, 10, FOLIAGE_MID)
			_add_frustum(st, 3.9, 1.6, 0.75, 0.0, 10, FOLIAGE_LIGHT)
		1:
			_add_frustum(st, 0.0, 2.0, 0.20, 0.12, 5, TRUNK_COLOR)
			_add_frustum(st, 1.8, 2.6, 1.40, 0.0, 7, FOLIAGE_MID)
			_add_frustum(st, 3.4, 2.0, 0.90, 0.0, 7, FOLIAGE_LIGHT)
		_:
			_add_frustum(st, 0.0, 1.8, 0.18, 0.10, 3, TRUNK_COLOR)
			_add_frustum(st, 1.5, 4.0, 1.30, 0.0, 5, FOLIAGE_MID)
	st.generate_normals()
	return st.commit()


static func build_grass_clump() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var base_color := Color(0.12, 0.30, 0.08)
	var tip_color := Color(0.38, 0.62, 0.18)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 5:
		var yaw := rng.randf() * TAU
		var side := Vector3(cos(yaw), 0.0, sin(yaw))
		var fwd := Vector3(-side.z, 0.0, side.x)
		var root := Vector3(rng.randf_range(-0.15, 0.15), 0.0, rng.randf_range(-0.15, 0.15))
		var half_width := rng.randf_range(0.03, 0.05)
		var height := rng.randf_range(0.35, 0.60)
		var tip := root + fwd * rng.randf_range(0.04, 0.12) + Vector3.UP * height
		_add_tri(st, root - side * half_width, root + side * half_width, tip,
				base_color, base_color, tip_color, fwd)
	st.generate_normals()
	return st.commit()


static func build_rock() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var t := (1.0 + sqrt(5.0)) * 0.5
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		var radius := 0.5 * rng.randf_range(0.8, 1.2)
		var v := verts[i].normalized() * radius
		verts[i] = Vector3(v.x, v.y * 0.7 + 0.25, v.z)
	var faces: Array[int] = [
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	]
	var center := Vector3(0.0, 0.25, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in range(0, faces.size(), 3):
		var a := verts[faces[f]]
		var b := verts[faces[f + 1]]
		var c := verts[faces[f + 2]]
		var shade := rng.randf_range(0.40, 0.55)
		var col := Color(shade, shade, shade * 1.05)
		_add_tri(st, a, b, c, col, col, col, (a + b + c) / 3.0 - center)
	st.generate_normals()
	return st.commit()


## Adds a tri, swapping vertices if needed so it faces `outward` (Godot front faces are clockwise).
static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		col_a: Color, col_b: Color, col_c: Color, outward: Vector3) -> void:
	if (b - a).cross(c - a).dot(outward) > 0.0:
		var tmp_v := b
		b = c
		c = tmp_v
		var tmp_c := col_b
		col_b = col_c
		col_c = tmp_c
	st.set_color(col_a)
	st.add_vertex(a)
	st.set_color(col_b)
	st.add_vertex(b)
	st.set_color(col_c)
	st.add_vertex(c)


## Cylinder/cone frustum along +Y. A zero top radius produces a cone with a single tri per side.
static func _add_frustum(st: SurfaceTool, base_y: float, height: float,
		r_bottom: float, r_top: float, sides: int, color: Color) -> void:
	var top_y := base_y + height
	var dark := color.darkened(0.15)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * r_bottom, base_y, sin(a0) * r_bottom)
		var b1 := Vector3(cos(a1) * r_bottom, base_y, sin(a1) * r_bottom)
		var t0 := Vector3(cos(a0) * r_top, top_y, sin(a0) * r_top)
		var t1 := Vector3(cos(a1) * r_top, top_y, sin(a1) * r_top)
		var mid_angle := (a0 + a1) * 0.5
		var outward := Vector3(cos(mid_angle), 0.0, sin(mid_angle))
		if r_top <= 0.0:
			_add_tri(st, b0, b1, t0, dark, dark, color, outward)
		else:
			_add_tri(st, b0, b1, t1, dark, dark, color, outward)
			_add_tri(st, b0, t1, t0, dark, color, color, outward)
