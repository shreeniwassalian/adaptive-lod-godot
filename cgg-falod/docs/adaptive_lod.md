# Adaptive multi-category LOD (milestone 4)

Three modes over the same scene, categories and camera path:

| Mode | What runs |
|---|---|
| `none` | baked vegetation, every custom policy disabled |
| `baseline` | the four distance policies (trees, grass, bushes, debris), fixed thresholds, unchanged from milestone 3 |
| `adaptive` | the **same** four policies, thresholds scaled by one PI-controlled bias |

`LodManager.set_mode("none"|"baseline"|"adaptive")` is the only switch. Rocks stay metrics-only; Terrain3D's native LOD is
never touched (its settings are recorded in the benchmark JSON and the self-test checks they do not change).

## Files
- `scripts/lod/pi_controller.gd`: the PI maths, no engine access (tested with synthetic input).
- `scripts/lod/adaptive_lod.gd` (node `AdaptiveLod`): reads the timing signal, smooths it, steps the PI controller, distributes the bias.
- `scripts/lod/lod_policy.gd`: base class gained `set_lod_bias()`, `set_schedule()`, `max_changes_per_update`, `build_ms`, update counters.
- `baseline_lod.gd`, `grass_lod.gd`, `density_lod.gd`: apply the bias, the change budget and the schedule. With the defaults (bias 0, no schedule, no budget) they behave exactly as the baseline.
- `lod_manager.gd`: `mode()` / `set_mode()`. `lod_debug_panel.gd`: Adaptive button, F4 toggles None <-> Adaptive.
- `scripts/lod/adaptive_selftest.gd`: synthetic controller tests.

## Bias convention
`bias > 0` = **coarser**, `bias < 0` = finer, `0` = the baseline distances. A policy compares `distance * (1 + bias_c)`
(never below 0.25) against its unchanged thresholds and hysteresis, i.e. a bias of 1 halves every threshold in metres. With bias 0 the multiplier
is exactly 1.0, so baseline output is bit-for-bit unchanged. The default `bias_min` is 0: **adaptive never draws more detail than baseline**; a negative `bias_min` (>= -0.75) allows it.

## Controller
```
signal    = EMA of min(sample, spike_clip * target)         time constant smoothing_s
e         = (signal - target) / target                       relative error, > 0 when too slow
e_eff     = e shrunk toward 0 by deadband (0 inside it)
P         = kp * e_eff
I        += ki * e_eff * dt        (not while the output is saturated in the direction of e)
wanted    = clamp(P + I, bias_min, bias_max)
bias      = clamp(wanted, bias - max_fall, bias + max_rise)  per controller step
if rate-limited: I = clamp(bias - P)                         back-calculation, so I never runs ahead of the applied bias
```
| Parameter | Default | Unit | Meaning |
|---|---|---|---|
| `target_ms` | 16.67 | ms | rendering cost to stay under (stress profile 8) |
| `kp` | 0.6 | bias / relative error | 50 % over target -> +0.3 bias immediately |
| `ki` | 0.4 | bias / (relative error * s) | 50 % over for 1 s -> +0.2 more |
| `bias_min`, `bias_max` | 0, 2 | bias | permitted range (2 = thresholds / 3) |
| `max_rise`, `max_fall` | 0.10, 0.03 | bias / step | coarsen fast, recover slowly (about 17 s for 2 -> 0 at 4 steps/s) |
| `deadband` | 0.03 | relative error | no reaction within 3 % of target |
| `update_interval_s` | 0.25 | s | PI step period |
| `smoothing_s` | 0.5 | s | EMA time constant |
| `spike_clip` | 3 | x target | one sample cannot count for more than 3x the target |

The gains are conservative first choices, **not tuned**; they were chosen so that the rate limits, not the gains, bound the speed of change. All are exposed
as `AdaptiveLod` exports and `--bench-*` options and recorded in every run.

## Signal
`signal_source` `auto` (default) = GPU render time of the main viewport (`viewport_get_measured_render_time_gpu`: excludes VSync waits,
frame caps and present) else total frame time **only if VSync is off and `Engine.max_fps` is 0**; otherwise the signal is *unavailable*:
the bias is held, nothing is integrated, and the panel shows "Adaptive active but the timing signal is UNAVAILABLE". `gpu` and `frame` force one source.
The active source is `ctrl_signal` in the CSV. Limits: GPU time lags the frame by a couple of frames; and a CPU-bound frame is invisible
to a GPU signal (the controller would see headroom while the frame is slow).

## Per category (revised in milestone 5: priority, floors, caps)
The first version scaled every category by `1 + bias * weight`, which pulled nearby trees to coarse meshes (LOD1 at 27 m at bias 2.0). The current rules:

**Category bias** `bias_c = clamp((bias - onset_c) * gain_c, bias_min, cap_c)` for a positive global bias, so the budget is spent in priority order:

| Category | Onset | Gain | Cap | What it moves |
|---|---|---|---|---|
| grass | 0 | 1.0 | 1.0 | tier distances 25 / 60 m and cull 110 m (at the cap: 12 / 30 m, cull 55 m); density tiers 100 / 40 / 12 % unchanged |
| trees | 0.5 | 1.0 | 1.0 | LOD thresholds, held above the floors below |
| bushes | 1.0 | 0.5 | 0.5 | tier distances 50 / 100 / 160 m, cull 240 m (at the cap: 33 / 67 / 107 m, cull 160 m) |
| debris | 1.0 | 0.5 | 0.5 | tier distances 30 / 60 m, cull 110 m (at the cap: 20 / 40 m, cull 73 m) |
| rocks, Terrain3D | | | | untouched |

Bushes and debris come last and mildly because their measured GPU cost is about zero (hiding them changed GPU time by 0.0-0.1 ms, also with 4x the instances), so thinning them buys nothing. `category_onset`, `category_weights` (gain) and `category_max` are exports of `AdaptiveLod`; the global `bias_max` (2.0) and the PI gains are unchanged.

**Tree minimum detail (floors).** The effective tree thresholds are `max(floor, baseline / (1 + bias_trees))`, never above the baseline value and in real metres:
`adaptive_floor_lod1 = 60 m` (the baseline LOD0 range is never reduced) and `adaptive_floor_lod2 = 100 m` (trees closer than 100 m keep their baseline LOD0 or LOD1). So adaptive pressure can only move the 100-150 m band of LOD1 trees to LOD2. Both are exports of `baseline_lod.gd`, used only when the bias is positive; with bias 0 the thresholds are exactly 60 / 150 m and the baseline is unchanged. Setting a floor to 0 removes the constraint for that threshold (used in the tests to show what it prevents); a negative bias (finer) moves the thresholds outwards. Trees keep their per-instance hysteresis and one MultiMesh per level; there are no per-tree nodes and no rebuild.

**Hysteresis** is a separate setting (`hysteresis`, 10 m for trees; 6 / 8 / 5 m for grass / bushes / debris): the tree must pass the threshold by that many real metres before it switches, and by the same amount on the way back. For trees it no longer scales with the bias (it is added to the effective threshold in metres). Grass, bushes and debris still compare `distance * (1 + bias_c)` against fixed thresholds, so their hysteresis shrinks with the bias in real metres.

## Smoothing and what it can and cannot do
Quality changes already pass through: the controller rate limits (+0.10 / -0.03 bias per 0.25 s step, so detail comes back about 3x slower than it goes), the 3 % dead band, signal smoothing and spike clipping; the per-policy update schedule (every 0.1 s, staggered by a quarter interval so the four categories never update on the same frame); and the change budget per update (now trees 200 instances, grass 30 cells, bushes and debris 20 chunks) with a rotating cursor, so a bias step is spread over several updates. Density tiers are nested prefixes of a fixed order, so a density change never makes an instance blink, only appear or disappear.
**Not smoothed:** an individual tree still switches mesh in one frame (a pop). Cross-fading or dithering needs a shader/material change on the tree meshes (and a second draw for the fade), which this architecture does not have; it is documented, not approximated. The floors and hysteresis keep the pops away from the nearby field and from trees wobbling around a threshold.

## Importance
Only category-level priority (onset / gain / cap above) is implemented. Per-instance or screen-coverage importance is **not** implemented and not approximated: the
policies decide per chunk/cell from camera distance and have no per-instance projected size; adding it means per-instance data and a new update path (next step).

## Update cost and stability
Measured before changing anything (self-test, 528 m path, one policy update per rendered frame, debug build): trees 2.1 ms, grass 1.6 ms, bushes 0.26 ms, debris 0.23 ms
per frame, about 4 ms in total. This is genuine GDScript cost (a full chunk/cell scan each frame), not just contention noise, so the baseline spends a large share of a 16.7 ms frame on it.
Adaptive mode therefore adds, per policy and only while adaptive:
- **schedule**: one update per `policy_update_interval_s` (0.1 s), staggered 0.25 interval apart, skipped if the camera moved less than 0.5 m and nothing is pending;
- **change budget** `max_changes_per_update` (trees 200 instances, grass 30 cells, bushes/debris 20 chunks): the rest waits for the next update; a rotating cursor stops the start of the list from being served first. The budget-limited result converges to exactly the unlimited one (tested);
- **initialisation** (building the runtime data on the first enabled frame, `build_ms`) happens during warm-up, outside the measured window, and is reported separately from the update cost in the JSON (`categories.<name>.initialization` and `.updates`).
No per-instance nodes, no queues, and no rebuild after the first enabled frame.

## Benchmark use
```
Godot_console.exe --path . res://scenes/benchmark.tscn -- --bench-label=NAME --bench-lod-mode=none     [--bench-profile=normal|stress]
Godot_console.exe --path . res://scenes/benchmark.tscn -- --bench-label=NAME --bench-lod-mode=baseline [--bench-profile=normal|stress]
Godot_console.exe --path . res://scenes/benchmark.tscn -- --bench-label=NAME --bench-lod-mode=adaptive [--bench-profile=normal|stress]
```
Profiles: `normal` = 1920x1080, target 16.67 ms; `stress` = 2560x1440, target 8 ms (an experimental target, not a promise). Both: VSync off, uncapped.
At the end of settle the controller is reset and held at bias 0, every category is resynced from the path start, and the controller is released at the first measured frame, so every run starts from the same state.
`display_at_end` in the JSON reads the window size, renderer and VSync back from the engine.

## Tests
    Godot_console.exe --path . --script res://scripts/lod/adaptive_selftest.gd      # synthetic controller tests + real policies, see header
    Godot_console.exe --path . --script res://scripts/lod/multi_lod_selftest.gd     # multi-category baseline
    Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd           # original tree LOD
    Godot_console.exe --path . --script res://scripts/lod/grass_selftest.gd         # grass incl. determinism (rebuild equals grass.scn)
The synthetic tests prove direction, saturation, anti-windup, smoothing, resets and budgets independent of GPU noise. They do **not** show that the controller helps a real frame; only the benchmark does.

## Measurements (this machine, debug build, forward_plus/d3d12, Quadro P3200, VSync off, uncapped, 60 s, interleaved baseline/adaptive)
*These measurements, and "Known limitations" below, were taken with the milestone-4 mapping (weights 0.6 / 1 / 1 / 1.25, no tree floors). The current mapping is described under "Per category" and measured in the milestone 5 section at the end.*
Files: `results/m4_*.csv/json` (git-ignored). Per-frame means; main pass = `draw_calls_visible` / `primitives_visible`.

| Run | frame ms | GPU ms | draw calls (main / all) | primitives main | bias (mean) | policy CPU ms/frame | switches |
|---|---|---|---|---|---|---|---|
| normal baseline 1 | 9.62 | 9.29 | 662 / 1584 | 1.07M | | 3.88 | 4077 |
| normal baseline 2 | 21.76 | 19.85 | 593 / 1529 | 1.09M | | 4.46 | 4077 |
| normal baseline 3 | 20.53 | 18.82 | 600 / 1537 | 1.10M | | 4.26 | 4077 |
| normal adaptive 1-3 | 21.70 / 20.84 / 21.81 | 19.64 / 18.94 / 19.71 | 530-537 / ~1460 | 0.91-0.92M | 1.62-1.65 | 0.69-0.85 | ~2440 |
| stress baseline 1 / 2 | 31.73 / 31.67 | 29.29 / 29.39 | 595 / 1536 | 1.09M | | 4.32 / 4.04 | 4077 |
| stress adaptive 1 / 2 | 29.95 / 29.95 | 27.72 / 27.74 | 532 / 1448 | 0.91M | 1.90 | 1.03 / 0.96 | 2538 |

What can and cannot be concluded:
- **Targets were not reachable.** At 1080p the GPU time is about 19-20 ms in both modes against a 16.67 ms target; at 1440p about 28-29 ms against 8 ms. The bias therefore saturated at `bias_max` for 44-56 % (normal) / 91 % (stress) of the frames. The controller did what it should (coarsen, clamp, stay stable: no reversals in stress) but the vegetation LOD cannot buy the missing milliseconds; terrain, shadows and the rest of the frame dominate.
- **Stress (2 pairs, repeatable):** adaptive GPU time 27.7 ms vs 29.3 ms for baseline (-5.5 %), frame time -5.6 %, main-pass primitives -17 %, main-pass draw calls -10 %. Both pairs agree to 0.1 ms, so this small gain is real for this setup; it comes from much coarser vegetation (bushes drawn 166 vs 665, grass clumps 2.2k vs 7.0k).
- **Normal (3 pairs): no frame-time conclusion.** Baseline run 1 ran at 9.3 ms GPU (104 fps) and baselines 2-3 at 19-20 ms in the same configuration, so the machine's GPU state changed between runs (clocks, contention); the adaptive runs (18.9-19.7 ms) are indistinguishable from baselines 2-3 (18.8-19.9 ms). Not claimed as an improvement or a regression.
- **Policy CPU cost is lower, and this is direct:** the four policies cost 3.9-4.5 ms/frame in baseline and 0.7-1.0 ms/frame in adaptive (update scheduling), measured with the same counters in both modes. This is CPU work inside the debug build's GDScript; its effect on frame time is invisible here because the runs are GPU-bound.
- **Reachable target** (`--bench-target-ms=19`, one run, normal): the bias rose to about 1.3 over ~30 s and the smoothed GPU signal settled at 18.8-19.3 ms (target 19.0) without hitting `bias_max`. The ramp is slow because of the rate limits; 54 small bias reversals (steps of 0.01-0.03) happened in 60 s as the path's load varies. Indicative only, one run.
- Adaptive reduces visual quality by design (bias up to 2 = thresholds / 3); there are no screenshots and no visual approval of those settings.

## Initialisation and controller cost (self-test, same process, GDScript debug build)
| | trees | grass | bushes | debris |
|---|---|---|---|---|
| first-enabled-frame build (`build_ms`) | 728-1009 ms | 23-30 ms | 236-302 ms | 160-274 ms |
| update, baseline, per frame (528 m path at 60 fps) | 1.57-1.68 ms | 1.44-1.54 ms | 0.25 ms | 0.23-0.25 ms |
| update, adaptive scheduled, per frame | 0.22 ms | 0.19 ms | 0.03 ms | 0.03 ms |

Controller itself: 0.001-0.002 ms per frame (smoothing every frame, PI step four times a second). In the benchmark JSON `categories.trees.initialization` reports a 761 ms build and 12 ms resync (build happens in warm-up, outside the measured window); the cost per policy update in adaptive mode was 1.7 ms for trees (274 updates in 30 s).

## Known limitations
- Importance is category-level only (no screen coverage, no per-instance size); see above.
- Gains and thresholds are untuned; a `bias_max` of 2 is a large visual change (grass cull 110 m -> 37 m, bushes 240 m -> 80 m); no screenshots reviewed.
- Slow settling (rate limits, 25-30 s to converge) and small steady-state wiggles (the deadband is 3 %); the path's own load changes cause bias changes.
- GPU signal lags 2-3 frames, ignores CPU-bound frames, and is noisy on this machine; GPU state changed between identical runs.
- Policies' bias transitions can briefly show different tiers in neighbouring chunks/cells while a change budget is spreading a change over several updates.
- Debug-build GDScript timings; an exported release build would change the CPU numbers.
- Pre-existing, not touched: the grass determinism test rebuilds the grass field and logs ~2400 engine "vectors must not be zero" errors from `grass_builder.gd` (`_append_clump`); the rebuilt field still equals `grass.scn`.


## Milestone 5: tests and fixed-view results (smooth, visually stable mapping)
**Tests** (`adaptive_selftest.gd`, all passing, 0 failures; `lod_selftest`, `multi_lod_selftest` and the full `grass_selftest` also pass):
- baseline tree thresholds are exactly 60 / 150 m, hysteresis 10 m; at any positive bias LOD1 starts at 60 m and LOD2 no closer than 100 m, a larger bias never moves a threshold outwards; with the floors removed bias 2.0 would give 20 / 50 m;
- after a resync at bias 2.0, on three path positions, no tree within 100 m differs from its baseline level and none is finer than baseline (0 violations; 559 / 318 / 433 distant trees are coarser);
- hysteresis: a tree wobbling +-8 m around 60 m (bias 0) and around 100 m (bias 1.0) never changes level, it switches once past the +10 m band and returns only past the -10 m band; bias changes above the floor move no tree at 75 m;
- priority: at global bias 0.3 only grass coarsens, at 0.8 trees join (bushes and debris untouched), at 2.0 every category sits at its cap (grass 1.0, trees 1.0, bushes 0.5, debris 0.5); non-decreasing and inside the limits;
- 20 s of path under rising then falling synthetic pressure (tree level changes, sampled every 0.1 s): baseline 1110 changes, burst 13, 0 switch-backs within 2 s; adaptive 998 changes, burst 38 (budget 200, largest single frame 38), 4 switch-backs within 2 s, no tree changed level more than 3 times;
- the earlier tests for pressure, recovery (gradual, no windup), clamps, budgets (a budget-limited run converges to the unlimited result), update schedule, density permutation / determinism, collision, transforms, instance totals and Terrain3D settings still pass.
Update cost (self-test, 60 fps, 528 m path): baseline 3.9 ms per frame for the four policies, adaptive scheduled 0.5-0.6 ms; controller 0.002 ms; first-frame builds trees 0.49 s, bushes 0.15 s, debris 0.15 s, grass 0.02 s.

**Fixed-view comparison** (`fixed_view_probe.gd --suite=smooth`, views at 0 / 150 / 300 m, 3 interleaved repetitions, pinned global bias; `results/probe/smooth/` holds the CSV and screenshots). Exact counts (reliable), main-pass primitives against baseline:

| | old mapping, bias 2.0 | new, bias 1.0 | new, bias 1.5 | new, bias 2.0 |
|---|---|---|---|---|
| 0 m | -23 % | -5 % | -8 % | -9 % |
| 150 m | -12 % | -1 % | -4 % | -5 % |
| 300 m | -21 % | -4 % | -8 % | -10 % |
| trees LOD0 / 1 / 2 at 0 m (baseline 37 / 605 / 9174) | 0 / 61 / 9755 | 37 / 164 / 9615 | same | same |
| image difference vs baseline, mean abs (0 / 150 / 300 m) | 4.92 / 1.76 / 1.76 | 3.56 / 0.79 / 1.22 | 4.09 / 0.78 / 0.68 | 4.27 / 0.87 / 0.98 |

The new mapping is visually much closer to baseline (nearby trees are identical to baseline; the nearest tree stays LOD0 where the old mapping flattened it) and removes roughly 20-45 % as much drawn geometry as the old one at bias 2.0 (about 9 / 5 / 10 % against 23 / 12 / 21 % of primitives); what remains is mid-field grass thinning, a little distant tree simplification and thinner bushes. **GPU timing in this run was unstable** (identical configs drifted between 10 and 16 ms, with large spikes), so no frame-time or GPU-time claim is made; the per-repetition GPU ratios to baseline scatter between 0.69 and 1.21.
**Consequence for performance:** protecting nearby trees gives up most of the measured saving of the old mapping, since trees were its main lever. If more saving is wanted the knobs are `adaptive_floor_lod2`, the grass cap and the grass tier densities (baked into `grass.scn`); none was tuned here.

## Remaining limitations
- Tree mesh switches still pop (no cross-fade); only their distance, rate and burst size are controlled.
- Adaptive savings are now small (mid-single-digit percent of drawn primitives at bias 1.0-2.0) until the knobs above are revisited; no GPU gain is demonstrated.
- Grass, bush and debris hysteresis still scales with the bias in real metres; thinning is chunk/cell based, so neighbouring cells can briefly sit in different tiers.
- Per-pass GPU timings are not available outside the editor Visual Profiler.
