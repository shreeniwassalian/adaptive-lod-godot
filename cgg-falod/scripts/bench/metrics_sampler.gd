extends RefCounted
## Reads Godot's rendering and timing counters once per frame. A metric that the engine cannot
## provide is returned as null (never as 0), so "unavailable" and "measured zero" stay distinct.
##
## Timing of the values: this is called at the start of a frame, before that frame is rendered, so the
## render counters and render times describe the PREVIOUS frame (the engine updates them after drawing).
## The runner pairs them with the previous frame's camera pose and frame interval.
##
## Sources:
##   draw_calls / primitives / objects   Performance.RENDER_TOTAL_* (visible + shadow passes, all viewports)
##   *_visible                           RenderingServer.viewport_get_render_info(..., INFO_TYPE_VISIBLE)
##   render_cpu_ms / render_gpu_ms       RenderingServer.viewport_get_measured_render_time_* (main viewport only)
##   process_ms_1hz / physics_ms_1hz     Performance.TIME_PROCESS / TIME_PHYSICS_PROCESS. The engine refreshes
##                                       these about once per second, so consecutive rows repeat a held value
##                                       (not a per-frame reading). The process time also includes time the
##                                       main thread waits on the GPU/present, so it is not pure CPU work.
## A rendered scene always has >0 draw calls, primitives and GPU time, so a reading of 0 for those is
## treated as "unavailable". process_ms_1hz / physics_ms_1hz are reported as read.

var _viewport_rid: RID


func start(viewport: Viewport) -> void:
	_viewport_rid = viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)


func stop() -> void:
	if _viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, false)


func sample() -> Dictionary:
	var visible := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	return {
		"process_ms_1hz": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms_1hz": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"render_cpu_ms": _positive(RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)),
		"render_gpu_ms": _positive(RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)),
		"draw_calls": _positive_int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"draw_calls_visible": _positive_int(RenderingServer.viewport_get_render_info(
				_viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)),
		"primitives": _positive_int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"primitives_visible": _positive_int(RenderingServer.viewport_get_render_info(
				_viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)),
		"objects": _positive_int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"video_mem_mb": _positive(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
	}


func _positive(value: float) -> Variant:
	return value if value > 0.0 else null


func _positive_int(value: float) -> Variant:
	return int(value) if value > 0.0 else null
