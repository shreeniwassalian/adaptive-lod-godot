@tool
extends RefCounted
## Procedural grass meshes. One shared opaque ShaderMaterial (shaders/grass.gdshader, no alpha, no textures):
## colour comes from vertex colours (dark root to light tip, per-blade jitter, a few dry blades) and is tinted
## per clump through the MultiMesh instance colour; UV.y carries the height along each blade for wind and
## root darkening. Blade normals are tilted across the blade so each blade shades like a curved leaf.
##
## Two kinds of mesh:
## - Tufts (TUFT): the taller clumps. Level 0: 14 blades x 3 segments (70 triangles). Level 1: 8 blades x
##   2 segments, wider (24). Level 2: 5 blades x 1 segment, wider still (5). Lower levels keep the tallest-to-
##   shortest spread of the blades they come from, so the clump keeps its outline.
## - Turf (TURF): short, wide, dense patches that fill the ground between tufts. Level 0: 14 blades x
##   2 segments (42 triangles). Level 1: 7 blades x 1 segment, wider (7). No level 2: far away the tufts carry cover.
## There are several distinct variants per level to reduce visible repetition.

const LEVELS := 3
const TUFT := 0
const TURF := 1
const SHADER_PATH := "res://shaders/grass.gdshader"
## Per kind, per level: distinct meshes, blades, segments and blade width multiplier. Turf has no level 2.
const KIND_LEVELS: Array[int] = [3, 2]
const VARIANTS: Array = [[4, 2, 1], [4, 2]]
const BLADES: Array = [[14, 8, 5], [14, 7]]
const SEGMENTS: Array = [[3, 2, 1], [2, 1]]
const WIDTH_SCALE: Array = [[1.0, 1.7, 2.8], [1.0, 1.9]]
## Per kind: blades in the full clump, patch radius, blade height / half-width / lean ranges.
const SOURCE_COUNT: Array[int] = [14, 14]
const PATCH_RADIUS: Array[float] = [0.22, 0.5]
const HEIGHT_RANGE: Array[Vector2] = [Vector2(0.26, 0.55), Vector2(0.09, 0.26)]
const HALF_WIDTH_RANGE: Array[Vector2] = [Vector2(0.014, 0.03), Vector2(0.018, 0.034)]
const LEAN_RANGE: Array[Vector2] = [Vector2(0.08, 0.55), Vector2(0.2, 0.75)]

const ROOT_COLOR := Color(0.045, 0.10, 0.025)
const TIP_COLOR := Color(0.30, 0.50, 0.11)
const DRY_ROOT_COLOR := Color(0.11, 0.095, 0.04)
const DRY_TIP_COLOR := Color(0.46, 0.41, 0.15)
const DRY_CHANCE := 0.12
## How far the blade normals are bent toward straight up, for soft, uniform lighting on a lawn.
const NORMAL_UP_BLEND := 0.65
## How far each blade's normals tilt toward its edges, so a flat blade shades like a curved one.
const EDGE_NORMAL_TILT := 0.4


static func material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = "GrassMaterial"
	mat.shader = load(SHADER_PATH)
	return mat


static func levels(kind: int) -> int:
	return KIND_LEVELS[kind]


static func triangle_count(level: int, kind: int = TUFT) -> int:
	return BLADES[kind][level] * (2 * SEGMENTS[kind][level] - 1)


static func build(level: int, variant: int, mat: Material, kind: int = TUFT) -> ArrayMesh:
	level = clampi(level, 0, KIND_LEVELS[kind] - 1)
	var blades := _blades(kind, variant)
	# Lower levels take evenly spaced blades from the height-sorted list of the full clump.
	blades.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["height"] > b["height"])
	var count: int = BLADES[kind][level]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in count:
		var source := int(floor((float(i) + 0.5) * float(blades.size()) / float(count)))
		_add_blade(st, blades[source], SEGMENTS[kind][level], WIDTH_SCALE[kind][level])
	var mesh := st.commit()
	mesh.resource_name = "Grass%s_L%d_V%d" % ["Tuft" if kind == TUFT else "Turf", level, variant]
	mesh.surface_set_material(0, mat)
	return mesh


## The full-detail blade set of one clump variant: root offset, height, width, lean and colours.
static func _blades(kind: int, variant: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5000 + variant * 7919 + kind * 104729
	var patch_radius: float = PATCH_RADIUS[kind]
	var heights: Vector2 = HEIGHT_RANGE[kind]
	var widths: Vector2 = HALF_WIDTH_RANGE[kind]
	var leans: Vector2 = LEAN_RANGE[kind]
	var blades: Array = []
	for i in SOURCE_COUNT[kind]:
		var angle := rng.randf() * TAU
		var radius := patch_radius * sqrt(rng.randf())
		var root := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		# Blades lean away from the clump centre, with scatter, and the central ones stand taller.
		var outward := atan2(root.z, root.x) if radius > 0.01 else rng.randf() * TAU
		var lean_dir := outward + rng.randf_range(-0.9, 0.9)
		var centrality := 1.0 - radius / patch_radius
		var height := lerpf(heights.x, heights.y, rng.randf()) * lerpf(0.85, 1.25, centrality)
		var dry := rng.randf() < DRY_CHANCE
		var jitter := rng.randf_range(0.82, 1.18)
		blades.append({
			"root": root,
			"height": height,
			"half_width": rng.randf_range(widths.x, widths.y),
			"lean_dir": Vector2(cos(lean_dir), sin(lean_dir)),
			"lean": rng.randf_range(leans.x, leans.y),
			"root_color": (DRY_ROOT_COLOR if dry else ROOT_COLOR) * jitter,
			"tip_color": (DRY_TIP_COLOR if dry else TIP_COLOR).lerp(Color(0.38, 0.52, 0.12), rng.randf() * 0.5) * jitter,
		})
	return blades


static func _add_blade(st: SurfaceTool, blade: Dictionary, segments: int, width_scale: float) -> void:
	var root: Vector3 = blade["root"]
	var height: float = blade["height"]
	var lean_dir: Vector2 = blade["lean_dir"]
	var lean: float = blade["lean"]
	var half_width: float = blade["half_width"] * width_scale
	var dir := Vector3(lean_dir.x, 0.0, lean_dir.y)
	var side := Vector3(-lean_dir.y, 0.0, lean_dir.x)
	var normal := dir.lerp(Vector3.UP, NORMAL_UP_BLEND).normalized()
	var normal_left := (normal - side * EDGE_NORMAL_TILT).normalized()
	var normal_right := (normal + side * EDGE_NORMAL_TILT).normalized()

	var left: Array[Vector3] = []
	var right: Array[Vector3] = []
	var colors: Array[Color] = []
	var along := PackedFloat32Array()
	for i in segments:
		var t := float(i) / float(segments)
		var centre := root + Vector3.UP * (height * t) + dir * (lean * height * t * t)
		var hw := half_width * (1.0 - 0.7 * t)
		left.append(centre - side * hw)
		right.append(centre + side * hw)
		colors.append((blade["root_color"] as Color).lerp(blade["tip_color"], pow(t, 0.8)))
		along.append(t)
	var tip := root + Vector3.UP * height + dir * (lean * height)
	var tip_color: Color = blade["tip_color"]

	for i in segments - 1:
		_vertex(st, left[i], normal_left, colors[i], along[i])
		_vertex(st, right[i], normal_right, colors[i], along[i])
		_vertex(st, left[i + 1], normal_left, colors[i + 1], along[i + 1])
		_vertex(st, right[i], normal_right, colors[i], along[i])
		_vertex(st, right[i + 1], normal_right, colors[i + 1], along[i + 1])
		_vertex(st, left[i + 1], normal_left, colors[i + 1], along[i + 1])
	var last := segments - 1
	_vertex(st, left[last], normal_left, colors[last], along[last])
	_vertex(st, right[last], normal_right, colors[last], along[last])
	_vertex(st, tip, normal, tip_color, 1.0)


static func _vertex(st: SurfaceTool, position: Vector3, normal: Vector3, color: Color, along: float) -> void:
	st.set_color(color)
	st.set_normal(normal)
	st.set_uv(Vector2(0.0, along))
	st.add_vertex(position)
