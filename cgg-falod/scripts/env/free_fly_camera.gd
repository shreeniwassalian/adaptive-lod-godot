extends Camera3D
## Debug free-fly camera: WASD move, Space up, Ctrl down, Shift fast, mouse look.
## Escape releases the mouse; clicking the window captures it again.

@export var move_speed: float = 12.0
@export var fast_multiplier: float = 4.0
@export var mouse_sensitivity: float = 0.0025
@export var capture_on_start: bool = true

var _yaw: float = 0.0
var _pitch: float = 0.0


func _ready() -> void:
	sync_from_transform()
	if capture_on_start:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Enables or disables movement and mouse look; enabling also makes this the current camera.
func set_active(value: bool) -> void:
	set_process(value)
	set_process_unhandled_input(value)
	if value:
		current = true
		sync_from_transform()


## Call after externally changing the camera transform so mouse look continues from it.
func sync_from_transform() -> void:
	var euler := global_transform.basis.get_euler()
	_pitch = euler.x
	_yaw = euler.y


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity,
				deg_to_rad(-89.0), deg_to_rad(89.0))
		global_transform.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	var basis := global_transform.basis
	if Input.is_physical_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_physical_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_physical_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL):
		dir += Vector3.DOWN
	if dir == Vector3.ZERO:
		return
	var speed := move_speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier
	global_position += dir.normalized() * speed * delta
