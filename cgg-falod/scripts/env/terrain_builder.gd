@tool
extends RefCounted
## Seeded procedural heightfield: height/normal queries plus a single ground ArrayMesh.

const GRASS_COLOR := Color(0.28, 0.45, 0.16)
const DIRT_COLOR := Color(0.40, 0.33, 0.24)

var size: float
var amplitude: float
var _noise: FastNoiseLite


func _init(seed_value: int, world_size: float, height_amplitude: float) -> void:
	size = world_size
	amplitude = height_amplitude
	_noise = FastNoiseLite.new()
	_noise.seed = seed_value
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.frequency = 0.008


func height_at(x: float, z: float) -> float:
	return _noise.get_noise_2d(x, z) * amplitude


func normal_at(x: float, z: float) -> Vector3:
	var e := 0.5
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## Row-major (z * (resolution + 1) + x) heights at the same grid points as build_mesh().
func build_height_data(resolution: int) -> PackedFloat32Array:
	var verts_per_side := resolution + 1
	var half := size * 0.5
	var step := size / float(resolution)
	var data := PackedFloat32Array()
	data.resize(verts_per_side * verts_per_side)
	for zi in verts_per_side:
		for xi in verts_per_side:
			data[zi * verts_per_side + xi] = height_at(-half + xi * step, -half + zi * step)
	return data


func build_mesh(resolution: int) -> ArrayMesh:
	var verts_per_side := resolution + 1
	var half := size * 0.5
	var step := size / float(resolution)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(verts_per_side * verts_per_side)
	normals.resize(vertices.size())
	colors.resize(vertices.size())
	for zi in verts_per_side:
		for xi in verts_per_side:
			var x := -half + xi * step
			var z := -half + zi * step
			var n := normal_at(x, z)
			var idx := zi * verts_per_side + xi
			vertices[idx] = Vector3(x, height_at(x, z), z)
			normals[idx] = n
			colors[idx] = GRASS_COLOR.lerp(DIRT_COLOR, smoothstep(0.88, 0.70, n.y))

	var indices := PackedInt32Array()
	indices.resize(resolution * resolution * 6)
	var w := 0
	for zi in resolution:
		for xi in resolution:
			var i00 := zi * verts_per_side + xi
			var i10 := i00 + 1
			var i01 := i00 + verts_per_side
			var i11 := i01 + 1
			indices[w] = i00
			indices[w + 1] = i10
			indices[w + 2] = i01
			indices[w + 3] = i10
			indices[w + 4] = i11
			indices[w + 5] = i01
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
