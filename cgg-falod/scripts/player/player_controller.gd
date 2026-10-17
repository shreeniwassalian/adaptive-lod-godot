extends CharacterBody3D
## Third-person player: camera-relative WASD, sprint, jump, mouse-orbit camera on a SpringArm3D.
## Input actions (see project.godot): move_forward/back/left/right, jump, sprint.
## Escape releases the mouse; clicking the window captures it again.

@export_group("Movement")
@export var walk_speed: float = 4.5
@export var sprint_speed: float = 8.0
@export var acceleration: float = 18.0
@export var deceleration: float = 22.0
## Fraction of ground acceleration available while airborne.
@export_range(0.0, 1.0) var air_control: float = 0.35
@export var jump_velocity: float = 5.0
## Higher turns the character faster toward its movement direction.
@export var turn_speed: float = 10.0

@export_group("Camera")
@export var mouse_sensitivity: float = 0.003
@export_range(-89.0, 0.0) var min_pitch_degrees: float = -70.0
@export_range(0.0, 89.0) var max_pitch_degrees: float = 35.0

var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-15.0)
var _active: bool = true
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var _visuals: Node3D = $Visuals
@onready var _pivot: Node3D = $CameraPivot
@onready var _arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D


func _ready() -> void:
	_apply_camera_rotation()
	set_active(true)


## Enables or disables player input and makes the player camera current when enabled.
func set_active(value: bool) -> void:
	_active = value
	if value:
		_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func get_camera() -> Camera3D:
	return _camera


## Teleports the player and points both character and camera along `yaw` (0 = looking toward -Z).
func place_at(position_in_world: Vector3, yaw: float) -> void:
	global_position = position_in_world
	velocity = Vector3.ZERO
	_yaw = yaw
	_visuals.rotation.y = yaw
	_apply_camera_rotation()


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity,
				deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
		_apply_camera_rotation()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	var input := Vector2.ZERO
	var wants_jump := false
	var sprinting := false
	if _active:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		wants_jump = Input.is_action_just_pressed("jump")
		sprinting = Input.is_action_pressed("sprint")

	var grounded := is_on_floor()
	if not grounded:
		velocity.y -= _gravity * delta
	elif wants_jump:
		velocity.y = jump_velocity

	var direction := Basis(Vector3.UP, _yaw) * Vector3(input.x, 0.0, input.y)
	var target := direction * (sprint_speed if sprinting else walk_speed)
	var rate := acceleration if input != Vector2.ZERO else deceleration
	if not grounded:
		rate *= air_control
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, rate * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	move_and_slide()

	if direction != Vector3.ZERO:
		var target_yaw := atan2(-direction.x, -direction.z)
		_visuals.rotation.y = lerp_angle(_visuals.rotation.y, target_yaw,
				1.0 - exp(-turn_speed * delta))


func _apply_camera_rotation() -> void:
	_pivot.rotation.y = _yaw
	_arm.rotation.x = _pitch
