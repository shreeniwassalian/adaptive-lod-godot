extends RefCounted
## Deterministic closed camera loop over the baked terrain. Fixed XZ waypoints are turned into a
## Catmull-Rom curve, resampled every SAMPLE_SPACING metres, and given a smoothed terrain-following
## height. The pose at a given distance is a pure function of the baked terrain data, so every run
## sees the same path. Nothing here reads input or physics.

## Ground-plane waypoints in world metres (the loop is closed), around the player spawn area.
const WAYPOINTS: Array[Vector2] = [
	Vector2(235, 120), Vector2(212, 156), Vector2(195, 198), Vector2(150, 198),
	Vector2(115, 181), Vector2(70, 166), Vector2(70, 120), Vector2(86, 83),
	Vector2(106, 44), Vector2(150, 44), Vector2(192, 47), Vector2(211, 85),
]
const SPLINE_SUBDIVISIONS := 24
const SAMPLE_SPACING := 1.0
## Heading looks this many metres ahead along the path.
const LOOKAHEAD := 8.0
## Ground height is averaged over +/- this many samples (metres) before adding the eye height.
const HEIGHT_SMOOTHING := 6

var length: float = 0.0
var ground_min: float = 0.0
var ground_max: float = 0.0
var pitch: float = 0.0
## SHA-256 of the sampled positions and headings; identical for identical paths.
var sha256: String = ""

var _positions := PackedVector3Array()
var _yaws := PackedFloat32Array()
var _spacing: float = SAMPLE_SPACING


## Returns an empty string on success, otherwise a description of what failed.
func build(terrain: Terrain3D, eye_height: float, pitch_degrees: float) -> String:
	if terrain == null or terrain.data == null or terrain.data.get_region_count() == 0:
		return "Terrain3D has no loaded regions"
	pitch = deg_to_rad(pitch_degrees)
	var xz := _resample(_spline())
	var count := xz.size()
	var ground := PackedFloat32Array()
	ground.resize(count)
	for i in count:
		var h := terrain.data.get_height(Vector3(xz[i].x, 0.0, xz[i].y))
		if is_nan(h):
			return "path point %s is outside the terrain" % xz[i]
		ground[i] = h
	ground_min = ground[0]
	ground_max = ground[0]
	for h in ground:
		ground_min = minf(ground_min, h)
		ground_max = maxf(ground_max, h)

	_positions.resize(count)
	for i in count:
		var sum := 0.0
		for k in range(-HEIGHT_SMOOTHING, HEIGHT_SMOOTHING + 1):
			sum += ground[posmod(i + k, count)]
		# Never dip below the real ground where the smoothed value lags a ridge.
		var base := maxf(sum / float(HEIGHT_SMOOTHING * 2 + 1), ground[i])
		_positions[i] = Vector3(xz[i].x, base + eye_height, xz[i].y)

	_yaws.resize(count)
	var ahead := maxi(1, int(round(LOOKAHEAD / _spacing)))
	for i in count:
		var d := xz[(i + ahead) % count] - xz[i]
		_yaws[i] = atan2(-d.x, -d.y)

	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(_positions.to_byte_array())
	hashing.update(_yaws.to_byte_array())
	sha256 = hashing.finish().hex_encode()
	return ""


## Camera transform after travelling `distance` metres along the loop (wraps at the loop length).
func sample(distance: float) -> Transform3D:
	var d := fposmod(distance, length) / _spacing
	var i := int(d) % _positions.size()
	var j := (i + 1) % _positions.size()
	var f := d - floorf(d)
	var yaw := lerp_angle(_yaws[i], _yaws[j], f)
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0), EULER_ORDER_YXZ)
	return Transform3D(basis, _positions[i].lerp(_positions[j], f))


func point_count() -> int:
	return _positions.size()


func _spline() -> PackedVector2Array:
	var dense := PackedVector2Array()
	var n := WAYPOINTS.size()
	for i in n:
		var p0 := WAYPOINTS[posmod(i - 1, n)]
		var p1 := WAYPOINTS[i]
		var p2 := WAYPOINTS[(i + 1) % n]
		var p3 := WAYPOINTS[(i + 2) % n]
		for s in SPLINE_SUBDIVISIONS:
			dense.append(p1.cubic_interpolate(p2, p0, p3, float(s) / SPLINE_SUBDIVISIONS))
	return dense


## Resamples the closed polyline at equal arc-length steps.
func _resample(dense: PackedVector2Array) -> PackedVector2Array:
	var n := dense.size()
	var cumulative := PackedFloat32Array()
	cumulative.resize(n + 1)
	for i in n:
		cumulative[i + 1] = cumulative[i] + dense[i].distance_to(dense[(i + 1) % n])
	length = cumulative[n]
	var count := maxi(8, int(round(length / SAMPLE_SPACING)))
	_spacing = length / float(count)
	var result := PackedVector2Array()
	result.resize(count)
	var seg := 0
	for k in count:
		var target := k * _spacing
		while cumulative[seg + 1] < target:
			seg += 1
		var seg_len := cumulative[seg + 1] - cumulative[seg]
		var t := 0.0 if seg_len <= 0.0 else (target - cumulative[seg]) / seg_len
		result[k] = dense[seg].lerp(dense[(seg + 1) % n], t)
	return result
