extends CanvasLayer
## In-game vegetation LOD debug panel. F3 shows or hides it, F4 switches between the two modes.
## It only drives and reads the existing VegetationLod controller (baseline_lod.gd): "None" disables it
## (the baked vegetation is restored), "Baseline" enables it. Hidden by default and idle while hidden.
## While shown the mouse cursor is released so the buttons can be clicked; hiding restores the previous mode.
## The benchmark runner removes this node, so it never takes part in a benchmark run.

@export var lod_path: NodePath = ^"../VegetationLod"
@export var toggle_key: Key = KEY_F3
@export var mode_key: Key = KEY_F4
## Seconds between text refreshes.
@export var refresh_interval: float = 0.2

const SMOOTHING := 0.1

var _lod: Node
var _panel: PanelContainer
var _none_button: Button
var _baseline_button: Button
var _text: Label
var _frame_time_s: float = 0.0
var _last_tick_us: int = 0
var _next_refresh_us: int = 0
var _mouse_mode_before: Input.MouseMode = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	layer = 100
	_lod = get_node_or_null(lod_path)
	_build_ui()
	_panel.visible = false
	set_process(false)


func is_panel_visible() -> bool:
	return _panel.visible


## The text currently shown in the stats area (used by the self-test).
func get_text() -> String:
	return _text.text


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == toggle_key:
		_set_panel_visible(not _panel.visible)
		get_viewport().set_input_as_handled()
	elif key.keycode == mode_key and _lod != null:
		_set_baseline(not _lod.enabled)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_s := (now - _last_tick_us) / 1000000.0
	_last_tick_us = now
	_frame_time_s = frame_s if _frame_time_s <= 0.0 else lerpf(_frame_time_s, frame_s, SMOOTHING)
	if now >= _next_refresh_us:
		_next_refresh_us = now + int(refresh_interval * 1000000.0)
		_refresh()


func _set_panel_visible(value: bool) -> void:
	_panel.visible = value
	set_process(value)
	if value:
		_mouse_mode_before = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_frame_time_s = 0.0
		_last_tick_us = Time.get_ticks_usec()
		_refresh()
	elif _mouse_mode_before == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _set_baseline(baseline: bool) -> void:
	if _lod == null:
		return
	_lod.enabled = baseline
	_none_button.set_pressed_no_signal(not baseline)
	_baseline_button.set_pressed_no_signal(baseline)
	# The controller applies a newly enabled mode on its next frame (before this node's _process), so
	# refresh the numbers then instead of showing the previous mode's counts under the new label.
	_next_refresh_us = 0
	set_process(true)


func _refresh() -> void:
	if _lod == null:
		_text.text = "VegetationLod node not found (%s)" % lod_path
		return
	var counts: PackedInt32Array = _lod.level_counts()
	var total := counts[0] + counts[1] + counts[2]
	var fps := 1.0 / _frame_time_s if _frame_time_s > 0.0 else 0.0
	var mode := "Baseline" if _lod.enabled else "None"
	_none_button.set_pressed_no_signal(not _lod.enabled)
	_baseline_button.set_pressed_no_signal(_lod.enabled)
	var lines := PackedStringArray([
		"Mode        %s" % mode,
		"FPS         %.1f" % fps,
		"Frame time  %.2f ms" % (_frame_time_s * 1000.0),
		"Trees LOD0  %d" % counts[0],
		"Trees LOD1  %d" % counts[1],
		"Trees LOD2  %d" % counts[2],
		"Trees total %d" % total,
		"LOD switches %d (+%d last frame)" % [_lod.total_switches, _lod.frame_switches],
		"Thresholds  %.0f / %.0f m, hysteresis %.0f m" % [_lod.lod1_distance, _lod.lod2_distance, _lod.hysteresis],
	])
	if _lod.enabled and _lod.is_built():
		lines.append("LOD update  %.2f ms/frame" % _lod.last_update_ms)
	_text.text = "\n".join(lines)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_top = 12.0
	_panel.offset_right = -12.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8.0)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	var title := Label.new()
	title.text = "Vegetation LOD  (F3 hide, F4 switch mode)"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(1, 1, 1, 0.7)
	column.add_child(title)

	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	var group := ButtonGroup.new()
	_none_button = _make_mode_button("NoneButton", "None", group)
	_baseline_button = _make_mode_button("BaselineButton", "Baseline", group)
	_none_button.pressed.connect(_set_baseline.bind(false))
	_baseline_button.pressed.connect(_set_baseline.bind(true))
	buttons.add_child(_none_button)
	buttons.add_child(_baseline_button)

	_text = Label.new()
	_text.name = "Stats"
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Consolas", "Courier New", "monospace"])
	_text.add_theme_font_override("font", font)
	_text.add_theme_font_size_override("font_size", 13)
	column.add_child(_text)


func _make_mode_button(node_name: String, label: String, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = label
	button.toggle_mode = true
	button.button_group = group
	# No keyboard focus, so Space (jump) and Enter never press a button by accident.
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return button
