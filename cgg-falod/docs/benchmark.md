# Benchmark

Measures the Terrain3D scene along a scripted camera path with a selectable vegetation LOD mode
(`--bench-lod-mode=none|baseline|adaptive`, see `docs/vegetation_lod.md`, `docs/multi_category_lod.md` and `docs/adaptive_lod.md`). `none` leaves
every category at full detail (baked trees, grass field at tier 0, all bushes and debris) and is the reference run;
`baseline` runs the distance policies of all categories; `adaptive` runs the same policies with the PI controller. It does not use the player, input, or physics.

## Run

    Godot_console.exe --path . res://scenes/benchmark.tscn -- [options]

Everything after `--` is read by `scripts/bench/benchmark_config.gd`. Defaults: 10 s warm-up, 10 settle frames,
60 s measured, 8 m/s, 1920x1080 window, VSync off, uncapped, label `no_lod`. Unknown or invalid options abort
with exit code 2. A finished run exits 0 (1 if the CSV could not be written or the run was aborted).

| Option | Default | Meaning |
|---|---|---|
| `--bench-label=NAME` | `no_lod` | file-name prefix, recorded in metadata |
| `--bench-lod-mode=none\|baseline\|adaptive` | `none` | `none` = every category at full detail; `baseline` = the distance policies of `--bench-lod-categories` (through the `LodManager` node); `adaptive` = the same policies under the PI controller |
| `--bench-profile=normal\|stress` | `normal` | `normal` = 1920x1080, target 16.67 ms; `stress` = 2560x1440, target 8 ms. Explicit width/height/target options override it |
| `--bench-target-ms=` `--bench-signal=auto\|gpu\|frame` `--bench-kp=` `--bench-ki=` `--bench-bias-min=` `--bench-bias-max=` `--bench-ctrl-interval=` `--bench-smoothing=` `--bench-max-rise=` `--bench-max-fall=` `--bench-policy-interval=` `--bench-switch-budget=` | see `docs/adaptive_lod.md` | adaptive controller settings; recorded in every run's `config.controller` |
| `--bench-lod-categories=all\|a,b,..` | `all` | baseline and adaptive: any of `trees,grass,bushes,debris`. Used for per-category ablation runs. Rocks have no policy |
| `--bench-grass=legacy\|v2` | `v2` | `v2` = procedural grass field (`docs/grass.md`, default since schema 3), `legacy` = the original sparse tufts (the earlier reference; has no LOD policy). Removed: `--bench-grass-lod` (use `--bench-lod-categories`) |
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
| `lod_bias` | unitless | the controller's global bias in adaptive mode (> 0 = coarser, see `docs/adaptive_lod.md`); empty in `none` and `baseline` |
| `lod_update_ms` | ms | CPU time of that LOD update (policy plus buffer writes), per frame. Empty in `none` mode |
| `trees_lod0`, `trees_lod1`, `trees_lod2` | count | trees drawn at each mesh level (they sum to the tree total). In `none` mode all trees are at the baked level |
| `grass_clumps_t0`, `grass_clumps_t1`, `grass_clumps_t2` | count | grass clumps drawn at each tier (legacy tufts count as t0) |
| `grass_switches` | count | grass cells that changed tier in the update that preceded the row's frame; `0` when grass LOD is off |
| `grass_update_ms` | ms | CPU time of that grass update. Empty unless grass LOD is on |
| `bush_drawn`, `debris_drawn` | count | bush / debris instances drawn (density policy applied; all of them in `none` mode) |
| `bush_switches`, `debris_switches` | count | chunks that changed density tier in the update that preceded the row's frame; `0` when off |
| `bush_update_ms`, `debris_update_ms` | ms | CPU time of those updates. Empty when off |
| `rocks_instances` | count | rock instances in the scene. Constant: rocks have no LOD (metrics only) |
| `lod_total_update_ms` | ms | sum of the update costs of all active policies (trees + grass + bushes + debris). Empty when none is active |
| `lod_policies_updated` | count | policies that ran an update since the previous row (all four every frame in baseline; fewer when the adaptive schedule skips updates) |
| `ctrl_signal` | text | `gpu` or `frame`: the timing signal the controller used for this row. Empty if not adaptive or the signal was unavailable |
| `ctrl_signal_ms`, `ctrl_raw_ms` | ms | smoothed signal fed to the PI step / the raw sample of the frame (clipped before smoothing). Empty as above |
| `ctrl_target_ms` | ms | target. Empty unless adaptive |
| `ctrl_error` | ratio | (signal - target) / target. Empty as above |
| `ctrl_p_term`, `ctrl_i_term` | bias units | proportional term / integral term of the last PI step (the integral is always present in adaptive mode) |
| `ctrl_update_ms` | ms | CPU time of the controller's own work in the frame (smoothing, PI step, applying the bias) |

Draw-call, primitive and GPU readings of 0 are stored as empty (a rendered scene cannot have zero); the JSON
`summary.columns.<name>.available` says whether any sample existed.

### Schema versions
**4** = + `lod_policies_updated` and the `ctrl_*` columns, `lod_bias` filled in adaptive mode; JSON adds `adaptive`, `config.controller`,
`config.profile`, `display_at_end` (window, viewport and renderer read back at the end of the run) and per-category
`initialization` (build and resync cost, separate from the steady-state `updates`). `csv_schema_version` in the JSON: 1 = harness + tree columns, 2 = + grass columns (not recorded then), **3** = + bush,
debris, rock and total-cost columns (new columns are appended; earlier columns keep their meaning). Version 3 also
changes the default grass to `v2`, so a v3 `none` run is not comparable with a v1 `none` run (different grass). The JSON
adds `categories` (per policy: settings, instance counts, switches in the measured run, integrity checks), `terrain3d`
(Terrain3D's own LOD/collision settings, recorded and never changed) and `scene.instances_by_kind`.

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
