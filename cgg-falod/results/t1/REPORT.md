# Task 1 report: validation and benchmark of the current adaptive LOD

No source file was modified (scripts compared with the backup in `backup_scripts_original/`: identical). Only measurement tooling was added under `results/t1/`.

## Conditions
Godot 4.7.2-stable **debug + editor build** (no export templates are installed, so a release build was not possible), Forward+/D3D12, NVIDIA Quadro P3200 (driver 582.16), i7-8850H, 64 GB, Windows Balanced power plan, VSync off, FPS uncapped, seed 1337, camera path sha256 `54ab438e9ad0c934`, 10 s warm-up + 10 settle frames + 60 s measured, controller reset to bias 0 at the start of the measured window. Profiles: `normal` 1920x1080 (target 16.67 ms), `stress` 2560x1440 (target 8 ms), unchanged project defaults. Order interleaved and rotated per repetition. Nothing was discarded: 36 runs, all exit 0.

* `pre/` series 1: none / baseline / adaptive, 3 reps x 2 profiles (18 runs). **Primary dataset**: the GPU stayed in one state.
* `pre2/` series 2: baseline / adaptive / `sched0` (adaptive scheduling with bias pinned to 0 via `--bench-bias-max=0`), 3 reps x 2 profiles (18 runs). **Contaminated by GPU-state drift**: the same configuration ran at 9 to 34 ms GPU time (e.g. stress baseline 30 FPS in one run, 94 FPS in another, GPU clocks logged between 139 and 1531 MHz). Reported, not used for headline numbers; only state-matched triples are quoted. Cause of the drift is unknown (battery 25 %, AC online; not investigated further, no system settings were changed).

## Results, series 1 (n = 3 per cell, mean ± sd across runs)
| Mode | Res | Avg FPS | 1% low FPS (1000/p99) | Mean frame ms | p99 ms | GPU ms | Main-pass prims | FPS vs baseline | Frame time vs baseline |
|---|---|---|---|---|---|---|---|---|---|
| None | 1080p | 9.3 ± 1.3 | 6.0 | 109.2 | 171 | 107.9 | 11.16 M | -74 % | +295 % |
| Baseline | 1080p | 36.3 ± 2.5 | 25.5 | 27.66 | 39.6 | 23.78 | 1.09 M | - | - |
| Adaptive | 1080p | 40.8 ± 2.2 | 28.7 | 24.56 | 35.6 | 22.83 | 1.00 M | +12.5 % | -11.2 % |
| None | 1440p | 8.6 ± 0.1 | 5.8 | 115.8 | 172 | 114.0 | 11.27 M | -67 % | +202 % |
| Baseline | 1440p | 26.0 ± 0.1 | 20.9 | 38.40 | 48.0 | 36.43 | 1.09 M | - | - |
| Adaptive | 1440p | 26.6 ± 0.1 | 21.6 | 37.60 | 46.2 | 35.80 | 1.00 M | +2.1 % | -2.1 % |

Paired by repetition (same slot in the rotation): 1080p +14.5 / +10.8 / +12.3 % FPS; 1440p +2.7 / +1.7 / +2.0 %. The alternative 1% low (mean of the slowest 1 % of frames) is in `analysis_pre/per_run.csv`; at 1080p adaptive is 22.2 vs 23.6 FPS because adaptive run 3 contains stalls (below).
State-matched triples from series 2 (GPU time within 3 %): 1080p baseline 39.3 FPS, schedule-only 41.1 (+4.7 %), adaptive 42.0 (+7.0 %); 1440p baseline 70.5, schedule-only 71.0 (+0.8 %), adaptive 71.9 (+2.0 %).

Statistical status: the sign is consistent in every pair (1080p 4/4, 1440p 3/3 plus one matched triple), but n is small and the machine drifts by up to 2 to 3x between runs, so no statistical reliability is claimed. The 1440p gain is small but tight (sd 0.1 FPS); the 1080p gain is larger, with a plausible range of about +7 to +15 %.

## Bottleneck (Phase C)
* **GPU-bound.** GPU time is 92 to 95 % of frame time in baseline and adaptive at both resolutions.
* **Target unreachable.** Adaptive GPU time is about 22.8 ms (target 16.67) and 35.8 ms (target 8). Bias sits at its maximum 2.0 in 74 % (1080p) and 90 % (1440p) of frames. In the 1440p run the smoothed signal is a flat 24 ms: the controller's `spike_clip` (3 x target) caps it, so it never sees the real 30 to 40 ms.
* **Primitives are not GPU time.** Main-pass primitives fall 8 % (1.09 -> 1.00 M), GPU time falls 4 % (1080p) and 1.7 % (1440p). Terrain, shadows and the rest of the frame dominate.
* **Policy CPU cost matters at 1080p only.** Baseline policies cost 12.4 ms/frame (updated every frame; trees 5.8 + grass 5.0 + bushes 0.8 + debris 0.8 ms in this state); adaptive costs 2.7 to 3.9 ms/frame (one update per 0.1 s). The frame-minus-GPU gap is 3.9 ms (baseline) vs 1.7 ms (adaptive) at 1080p, 2.0 vs 1.8 at 1440p. So at 1080p most of the gain (-3.1 ms frame, only -0.95 ms GPU) appears to come from cheaper policy scheduling rather than coarser LOD; the schedule-only control (+4.7 % of the +7.0 % in its matched triple) supports this. This is a measured association, not a proven mechanism.
* **Not the cause of stalls.** See below.

## Frame stalls and the "<10 FPS" question
Frames over 100 ms, excluding `none` mode (which runs at ~9 FPS): series 1: adaptive 6 (all in one run, `pre_normal_adaptive_3`, worst 247 ms / 4 FPS), baseline 0; series 2: adaptive 3, baseline 8, schedule-only 5. In every stall frame GPU time (about 25 ms) and policy update time (0 to 16 ms) are normal, so neither explains them. Stalls occur in baseline and schedule-only runs too, so they are **not adaptive-specific**. Cause not identified (no explanation is asserted). A live mode toggle costs 17 to 52 ms in one frame (`stall_probe_before.txt`); the 1+ s per-policy build happens once at scene start because the policies are enabled by default, so it is not a live stall.

## Audit (Phase A) summary
Confirmed working: GPU signal from `viewport_get_measured_render_time_gpu` (available in 2287 of 2297 frames, source "gpu"); PI bias -> category mapping (observed 1.0 / 1.0 / 0.5 / 0.5 at bias 2.0, matches onset/gain/cap); tree floors, hysteresis, change budgets, scheduling, reset behaviour (all in the self-tests: `lod_selftest` PASS, `multi_lod_selftest` PASS, `adaptive_selftest` 110 ok, 2 FAIL).
Confirmed issues / observations (none changed):
1. `adaptive_selftest` fails 2 checks (F4 None -> Baseline -> Adaptive). The panel was changed (uncommitted) to toggle None <-> Adaptive only and the Baseline button was removed, so Baseline cannot be re-selected in live play; the test and `docs/adaptive_lod.md` are stale. Needs your decision (restore a 3-way cycle or update test/docs).
2. `benchmark_summary.gd` defines `fps_1pct_low` as 1000/p99, not the mean of the worst 1 %; both are in `per_run.csv`.
3. Signal clipping at 3 x target hides how far over target the GPU is when the target is far out of reach (stress profile).
4. Per-frame allocation in `baseline_lod._prepare()` (threshold key array) and `grass_lod._prepare()` (`_thresholds`); microseconds per frame, not measurable against the 1 ms+ noise, so not changed.
5. Grass/bush/debris hysteresis shrinks in real metres as bias rises (documented design).
6. Tree coarsening under adaptive is limited to the 100 to 150 m LOD1 -> LOD2 band by the floors; grass is the main lever.

## Optimisation (Phase D/E)
**No optimisation was made.** The candidates were checked against the data: first-enable build stall (not a live-play issue, see probe), per-frame allocations (negligible), policy update cost (workload is GPU-bound at 92 to 95 %, adaptive already schedules updates; a further CPU saving could not be separated from the drift), stalls (not LOD-attributable). Per the brief's rule, nothing unsupported was changed, so "optimized adaptive" equals "current adaptive" and no post-change rerun was needed.

## Files
`pre/`, `pre2/` raw CSV/JSON + stdout; `analysis_pre/`, `analysis_pre2/` per-run table, cells, charts; `charts/` presentation charts from series 1; `selftest_*.txt`; `stall_probe_before.txt`; `analyze.py`, `run_series.ps1`, `stall_probe.gd`; `aux/` launch test; `backup_scripts_original/`.
