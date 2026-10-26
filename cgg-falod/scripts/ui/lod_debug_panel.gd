extends CanvasLayer
## In-game vegetation LOD debug panel. F3 shows or hides it, F4 toggles None <-> Adaptive.
## It only drives and reads the existing controllers through LodManager: "None" disables every category policy
## (trees, grass, bushes, debris: the baked vegetation is restored), "Adaptive" enables them under the PI
## controller (AdaptiveLod). The fixed-distance Baseline mode still exists in LodManager (benchmarks) but is not offered here. It shows the per-category counts,
## switches and update cost and, in Adaptive, the target, signal, bias and controller state. Hidden by default and idle while hidden.
## While shown the mouse cursor is released so the buttons can be clicked; hiding restores the previous mode.
## The benchmark runner removes this node, so it never takes part in a benchmark run.

@export var lod_path: NodePath = ^"../VegetationLod"
@export var manager_path: NodePath = ^"../LodManager"
@export var toggle_key: Key = KEY_F3
@export var mode_key: Key = KEY_F4
## Seconds between text refreshes.
@export var refresh_interval: float = 0.2

const SMOOTHING := 0.1

var _lod: Node  # the tree policy
var _manager: Node
var _panel: PanelContainer
var _none_button: Button
var _adaptive_button: Button
var _cost_ms: float = 0.0
var _text: Label
var _frame_time_s: float = 0.0
var _last_tick_us: int = 0
var _next_refresh_us: int = 0
var _mouse_mode_before: Input.MouseMode = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	layer = 100
	_lod = get_node_or_null(lod_path)
	_manager = get_node_or_null(manager_path)
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
	elif key.keycode == mode_key and _manager != null:
		_set_mode(_next_mode(_manager.mode()))
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_s := (now - _last_tick_us) / 1000000.0
	_last_tick_us = now
	_frame_time_s = frame_s if _frame_time_s <= 0.0 else lerpf(_frame_time_s, frame_s, SMOOTHING)
	if _manager != null:
		var cost := 0.0
		for policy in _manager.policies():
			if policy.enabled and policy.is_built():
				cost += policy.last_update_ms
		_cost_ms = lerpf(_cost_ms, cost, SMOOTHING)
	if now >= _next_refresh_us:
		_next_refresh_us = now + int(refresh_interval * 1000000.0)
		_refresh()


func _set_panel_visible(value: bool) -> void:
	_panel.visible = value
	set_process(value)
	if value:
		# The scene starts in the fixed-distance Baseline mode, which this panel does not offer: show Adaptive instead.
		if _manager != null and _manager.mode() != "none" and _manager.mode() != "adaptive":
			_set_mode("adaptive")
		_mouse_mode_before = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_frame_time_s = 0.0
		_last_tick_us = Time.get_ticks_usec()
		_refresh()
	elif _mouse_mode_before == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## F4 toggles None <-> Adaptive. Anything else (e.g. "baseline" set from code) goes to None.
func _next_mode(current: String) -> String:
	return "adaptive" if current == "none" else "none"


func _set_mode(mode: String) -> void:
	if _manager == null:
		return
	_manager.set_mode(mode)
	_none_button.set_pressed_no_signal(mode == "none")
	_adaptive_button.set_pressed_no_signal(mode == "adaptive")
	# The controllers apply a newly enabled mode on their next frame (before this node's _process), so
	# refresh the numbers then instead of showing the previous mode's counts under the new label.
	_next_refresh_us = 0
	set_process(true)


func _refresh() -> void:
	if _lod == null or _manager == null:
		_text.text = "LOD nodes not found (%s, %s)" % [lod_path, manager_path]
		return
	var counts: PackedInt32Array = _lod.level_counts()
	var total := counts[0] + counts[1] + counts[2]
	var fps := 1.0 / _frame_time_s if _frame_time_s > 0.0 else 0.0
	var mode_id: String = _manager.mode()
	var baseline: bool = mode_id == "baseline" or mode_id == "adaptive"
	var mode := mode_id.capitalize()
	_none_button.set_pressed_no_signal(mode_id == "none")
	_adaptive_button.set_pressed_no_signal(mode_id == "adaptive")
	var lines := PackedStringArray([
		"Mode        %s" % mode,
		"FPS         %.1f" % fps,
		"Frame time  %.2f ms" % (_frame_time_s * 1000.0),
		"Trees LOD0  %d" % counts[0],
		"Trees LOD1  %d" % counts[1],
		"Trees LOD2  %d" % counts[2],
		"Trees total %d" % total,
		"LOD switches %d (+%d last frame)" % [_lod.total_switches, _lod.frame_switches],
		"Thresholds  %.0f / %.0f m, hysteresis %.0f m" % [_lod.effective_thresholds()[0], _lod.effective_thresholds()[1], _lod.hysteresis],
	])
	if mode_id == "adaptive":
		lines.append_array(_adaptive_lines(_manager.adaptive()))
	for category in ["grass", "bushes", "debris"]:
		var policy: Node = _manager.policy(category)
		if policy != null:
			lines.append(_category_line(policy))
	lines.append("Rocks       %d (metrics only, no LOD)" % _manager.rock_instances())
	if baseline and _lod.is_built():
		lines.append("LOD update  %.2f ms/frame (all categories, averaged)" % _cost_ms)
	_text.text = "\n".join(lines)


## Target, signal, bias and controller lines of the Adaptive mode; says so when the timing signal is unavailable.
func _adaptive_lines(controller: Node) -> PackedStringArray:
	if controller == null:
		return PackedStringArray(["Adaptive    ! no AdaptiveLod node"])
	var lines := PackedStringArray()
	var state: Dictionary = controller.state()
	lines.append("Target      %.2f ms (signal: %s)" % [state["target_ms"], controller.signal_source])
	if state["signal_available"]:
		lines.append("Signal      %s %.2f ms smoothed, %.2f raw" % [state["signal"], state["signal_ms"], state["raw_ms"]])
		lines.append("Error       %+.1f %%  P %+.3f  I %+.3f" % [state["error"] * 100.0, state["p_term"], state["i_term"]])
	else:
		lines.append("! Adaptive active but the timing signal is UNAVAILABLE (%s): bias is held" % _signal_hint(controller))
	var saturation := ""
	if state["saturation"] > 0:
		saturation = " (coarsest)"
	elif state["saturation"] < 0:
		saturation = " (finest detail)"
	lines.append("Bias        %+.3f%s   >0 = coarser" % [state["bias"], saturation])
	lines.append("Controller  %.3f ms/frame, %d PI steps" % [controller.last_update_ms, controller.pi_steps])
	return lines


func _signal_hint(controller: Node) -> String:
	if controller.signal_source == "gpu":
		return "no GPU render time from the driver"
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED or Engine.max_fps != 0:
		return "VSync or a frame cap is on and no GPU time is reported"
	return "waiting for samples"


## "Grass       drawn 12345 / 67890  per tier 1/2/3  switches 4 (+0) cells"
func _category_line(policy: Node) -> String:
	var name: String = policy.category().capitalize()
	var tiers := PackedStringArray()
	for count in policy.tier_counts():
		tiers.append(str(count))
	return "%sdrawn %d / %d  per tier %s  switches %d (+%d) %s" % [
			name.rpad(12), policy.instance_drawn(), policy.instance_total(), "/".join(tiers),
			policy.total_switches, policy.frame_switches, policy.switch_unit()]


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
	title.text = "Vegetation LOD  (F3 hide, F4 toggle None/Adaptive)"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(1, 1, 1, 0.7)
	column.add_child(title)

	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	var group := ButtonGroup.new()
	_none_button = _make_mode_button("NoneButton", "None", group)
	_adaptive_button = _make_mode_button("AdaptiveButton", "Adaptive", group)
	_none_button.pressed.connect(_set_mode.bind("none"))
	_adaptive_button.pressed.connect(_set_mode.bind("adaptive"))
	buttons.add_child(_none_button)
	buttons.add_child(_adaptive_button)

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
