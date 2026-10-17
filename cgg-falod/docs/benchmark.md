# Benchmark

Measures the Terrain3D scene along a scripted camera path with a selectable vegetation LOD mode
(`--bench-lod-mode=none|baseline`, see `docs/vegetation_lod.md`). `none` leaves the baked scene untouched and is
the reference run. It does not use the player, input, or physics.

## Run

    Godot_console.exe --path . res://scenes/benchmark.tscn -- [options]

Everything after `--` is read by `scripts/bench/benchmark_config.gd`. Defaults: 10 s warm-up, 10 settle frames,
60 s measured, 8 m/s, 1920x1080 window, VSync off, uncapped, label `no_lod`. Unknown or invalid options abort
with exit code 2. A finished run exits 0 (1 if the CSV could not be written or the run was aborted).

| Option | Default | Meaning |
|---|---|---|
| `--bench-label=NAME` | `no_lod` | file-name prefix, recorded in metadata |
| `--bench-lod-mode=none\|baseline` | `none` | `none` = baked scene, no LOD; `baseline` = distance LOD (`VegetationLod` node) |
| `--bench-seed=N` | 1337 | seeds Godot's global RNG. The world is baked and does not depend on it |
| `--bench-warmup=S` / `--bench-duration=S` | 10 / 60 | seconds |
| `--bench-settle-frames=N` | 10 | frames held at the path start, not recorded |
| `--bench-speed=MPS` | 8 | camera speed along the ground plane |
| `--bench-width=W --bench-height=H` | 1920 x 1080 | window (= 3D render) size |
| `--bench-vsync=off\|on\|adaptive\|mailbox` | `off` | |
| `--bench-max-fps=N` | 0 | `Engine.max_fps`, 0 = uncapped |
| `--bench-out=DIR` | `<project>/results` | `res://` and `user://` paths work |
| `--bench-no-quit` | | keep the window open at the end |

Renderer and driver cannot be changed at runtime; use Godot's own flags (`--rendering-method`,
`--rendering-driver`) and the actual values are recorded in the JSON. Esc aborts and saves partial data.

## Phases
startup (3 frames) -> warm-up (camera travels the path, not recorded) -> settle (camera held at path start)
-> measure (path distance = elapsed wall time x speed). Warm-up ends with a teleport back to the start so
every measured run covers exactly the same path from distance 0. In `baseline` mode the LOD state is also reset
(`resync()`, no hysteresis, no switches counted) at that point, so the measured run does not depend on the warm-up.

## Repeatability
The camera path (`benchmark_camera_path.gd`) is fixed waypoints -> Catmull-Rom -> 1 m samples, with height from the
baked terrain. The JSON stores its SHA-256 (`camera_path.sha256`) and a scene fingerprint (`scene.*`: world seed,
chunks, MultiMesh nodes and instance count). Two runs with the same path hash and fingerprint saw the same content.
Camera position is a function of elapsed time, so frame counts differ between runs but poses at equal path
distance are identical. The path is 528 m, so the default 60 s run covers 480 m (one partial lap).

## Output
`results/<label>_<YYYYMMDD-HHMMSS>.csv` (one row per measured frame) and `.json` (configuration, display,
engine, scene fingerprint, camera path, summary statistics). Empty CSV cell = **unavailable**; `0` = measured zero.

Each row describes the frame that was **just completed**: Godot updates render counters after drawing, so they
are read at the start of the next frame and paired with the previous frame's pose and duration.

| Column | Unit | Source / notes |
|---|---|---|
| `frame` | index | 0 = first measured frame |
| `t_s` | s | time since measuring started, at the end of the row's frame |
| `path_distance_m` | m | distance travelled along the loop for the row's frame |
| `cam_x`, `cam_y`, `cam_z` | m | camera position of the row's frame |
| `cam_yaw_deg` | deg | camera heading |
| `frame_time_ms` | ms | wall-clock interval between consecutive frame starts (`Time.get_ticks_usec`). The real frame time, including VSync/FPS-cap waits |
| `fps_instant` | 1/s | 1000 / `frame_time_ms` for this frame |
| `process_ms_1hz` | ms | `Performance.TIME_PROCESS`. **The engine refreshes it ~once per second**, so rows repeat a held value. It includes time waiting on the GPU/present, so it is not pure CPU work |
| `physics_ms_1hz` | ms | `Performance.TIME_PHYSICS_PROCESS`, same ~1 Hz refresh |
| `render_cpu_ms` | ms | `RenderingServer.viewport_get_measured_render_time_cpu`, main viewport, per frame |
| `render_gpu_ms` | ms | `viewport_get_measured_render_time_gpu`, main viewport, per frame. A GPU timestamp measurement; empty if the driver reports <= 0 |
| `draw_calls`, `primitives`, `objects` | count | `Performance.RENDER_TOTAL_*_IN_FRAME`: visible + shadow passes, all viewports |
| `draw_calls_visible`, `primitives_visible` | count | `viewport_get_render_info(..., INFO_TYPE_VISIBLE)`: main camera pass only, excludes shadows |
| `video_mem_mb` | MiB | `Performance.RENDER_VIDEO_MEM_USED`. Updates rarely; was constant in test runs |
| `lod_switches` | count | trees that changed LOD level in the update that preceded the row's frame. `0` in `none` mode (no controller exists, so there are none) |
| `lod_bias` | unitless | empty in both current modes (the baseline has no bias); reserved for the adaptive controller |
| `lod_update_ms` | ms | CPU time of that LOD update (policy plus buffer writes), per frame. Empty in `none` mode |
| `trees_lod0`, `trees_lod1`, `trees_lod2` | count | trees drawn at each mesh level (they sum to the tree total). In `none` mode all trees are at the baked level |

Draw-call, primitive and GPU readings of 0 are stored as empty (a rendered scene cannot have zero); the JSON
`summary.columns.<name>.available` says whether any sample existed.
Level counts and switches are read at the start of the frame, so they describe the LOD state the previous frame
was drawn with. `summary.lod_switches_total` and `lod.*` in the JSON hold the totals and the result of the two
LOD integrity checks (after the warm-up resync and at the end of the run).
`fps_1pct_low` is 1000 / p99 frame time (not the mean of the slowest 1 %). `avg_fps` is frames / measured seconds.

## Caveats
- Run from the editor binary (debug build): `engine.debug_build` and `engine.editor_build` are recorded. Debug-build
  numbers are not release-export numbers.
- GPU time covers the main viewport only. Frame time can also include waits not covered by GPU/CPU render time.
- Shadow passes are in the "total" counters; use the `_visible` columns for the camera pass alone.
- Comparisons are only valid between runs with the same hardware, driver, resolution, VSync/FPS cap, path hash and
  scene fingerprint. Close other GPU-heavy programs (including the Godot editor's own game window) first.
- The `Player` node is disabled/hidden and the free-fly camera is switched off, so the player mesh is not rendered.
