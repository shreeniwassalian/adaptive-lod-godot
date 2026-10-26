# Final evidence report (2026-10-23)

Everything here was produced by actually running the project; nothing is estimated. Build: **Godot 4.7.2 debug + editor build** (see "Release build").

## 1. Tests (`python scripts/lod/run_selftests.py`, logs in `selftests/`)
| Test | Result | ok checks | Script errors | FAIL lines |
|---|---|---|---|---|
| adaptive_selftest | PASS | 130 | 0 | 0 |
| multi_lod_selftest | PASS | 90 | 0 | 0 |
| lod_selftest | PASS | 51 | 0 | 0 |
| grass_selftest (`skip-determinism`) | PASS | 17 | 0 | 0 |

Runner exit code 0, minimum check counts unchanged. **The grass determinism stage was not run**, so it is not claimed to pass.

## 2. Release build
**Not possible.** The project has no `export_presets.cfg`, and the Godot export-templates folder is empty (`%APPDATA%\Godot\export_templates`). Creating a release build needs the export templates (a download/install) and a preset, which the task excludes. No rendering setting or dependency was changed. All numbers below come from the debug/editor build and must not be compared with release results.

## 3. Benchmark (`bench/`, analysis in `analysis_bench/`)
Existing harness (`benchmark.tscn`), profiles `normal` 1920x1080 (controller target 16.67 ms) and `stress` 2560x1440 (target 8 ms), VSync off, uncapped, seed 1337, path sha256 `54ab438e9ad0c934`, 10 s warm-up + 60 s measured, controller reset to bias 0 at the start of measurement. **5 repetitions per mode and resolution = 30 runs, all completed (exit 0), none discarded**, order rotated each repetition. Quadro P3200, driver 582.16. This session the GPU stayed in one stable state (sd of average FPS 0.03 to 0.32).

| Resolution | Mode | n | Avg FPS ± sd | Median | 1% low (1000/p99) | Mean ms | p95 / p99 ms | GPU ms | FPS change vs baseline | Frame-time reduction |
|---|---|---|---|---|---|---|---|---|---|---|
| 1920x1080 | None | 5 | 21.4 ± 0.1 | 23.4 | 13.9 | 46.72 | 70.5 / 72.0 | 46.27 | -77.9% | -351.6% |
| 1920x1080 | Baseline | 5 | 96.7 ± 0.3 | 97.7 | 77.2 | 10.35 | 12.2 / 13.0 | 9.86 | - | - |
| 1920x1080 | Adaptive | 5 | 96.8 ± 0.3 | 97.7 | 77.6 | 10.33 | 12.2 / 12.9 | 9.87 | **+0.2%** | +0.2% |
| 2560x1440 | None | 5 | 19.6 ± 0.0 | 21.2 | 13.0 | 51.15 | 75.2 / 77.0 | 50.57 | -72.2% | -260.4% |
| 2560x1440 | Baseline | 5 | 70.5 ± 0.2 | 70.9 | 55.7 | 14.19 | 16.5 / 18.0 | 13.59 | - | - |
| 2560x1440 | Adaptive | 5 | 72.1 ± 0.1 | 72.6 | 57.3 | 13.87 | 16.1 / 17.4 | 13.29 | **+2.4%** | +2.3% |

FPS change = (Adaptive - Baseline) / Baseline x 100; frame-time reduction = (Baseline - Adaptive) / Baseline x 100. Paired by repetition: 1440p +2.9 / +2.6 / +1.8 / +2.6 / +2.0 % (5 of 5 positive); 1080p +0.1 / +0.4 / +0.2 / +0.2 / -0.2 % (`analysis_bench/results_table.md`). "1% low" here is 1000 / p99 frame time; the mean of the slowest 1 % of frames is in `analysis_bench/per_run.csv`.

Other measured metrics (mean per frame): main-pass primitives 1.08 M (baseline) vs 1.08 M (adaptive) at 1080p and 1.09 M vs 1.00 M at 1440p; main-pass draw calls 592 vs 591 and 594 vs 552; policy CPU time 3.3 vs 0.34 ms (1080p) and 3.5 vs 0.42 ms (1440p); LOD switches 4077 vs 4076 and 4077 vs 3277 over the run; bias mean 0.00 (1080p) and 1.86 (1440p), at the maximum in 0 % and 84 % of frames. Frames under 10 FPS in the 20 baseline/adaptive runs: **0**; slowest single frame 62.9 ms (baseline) and 22.4 ms (adaptive).

How to read it:
* **1440p**: GPU time (13.6 ms) is above the 8 ms target, the controller saturates and adaptive is slightly faster in every pair. The primitive reduction (about 8 %) gives only about 2 % less GPU time; fewer primitives do not translate proportionally into FPS. The target itself is not reached even at maximum bias.
* **1080p**: GPU time (9.9 ms) is already under the 16.67 ms target, the controller stays at bias 0, and adaptive equals baseline. This does not reproduce the larger 1080p gain measured in the earlier session (+12.5 %, three runs), when the GPU was in a slower state (about 23 ms) and the controller was over target. Do not claim that earlier figure for the current build.
* **Supplementary, not a default configuration** (`bench_supplement/`): 1080p with the controller target lowered to 8 ms, 3 interleaved runs per mode. Baseline 97.0 FPS (97.9 / 96.8 / 96.3), adaptive 99.5 FPS (99.8 / 99.6 / 99.2), +2.6 %; bias mean 1.63, at maximum in 60 % of frames. This shows the controller helps at 1080p when it is over its target, by about as much as at 1440p.
* Statistical status: the sign is consistent (1440p 5/5, supplementary 3/3) and the spread is small, but n is small and the GPU state drifted 2 to 3x in earlier sessions, so no general reliability is claimed.

Charts (`charts/`, also in `analysis_bench/`): `chart_avg_fps.png`, `chart_frame_time.png`, `chart_gpu_time.png`, `chart_fps_over_time.png`, `chart_bias_vs_gpu.png`.

## 4. Gameplay recording (`media/`)
* `adaptive_lod_demo_1080p.mp4` (1920x1080, 30 fps, 74.7 s, H.264, 44 MB) and `adaptive_lod_demo_720p.mp4` (1280x720, 20 MB, the one embedded in the deck). Raw capture and logs: `media/rec2/` (`demo_raw.mkv`, `record_log.txt`, `demo_timeline.json` with the per-second mode, bias, GPU and frame time actually measured, `demo_stdout.txt`).
* How: `scenes/demo.tscn` + `scripts/bench/demo_recorder.gd` run the real scene on the benchmark camera path in a borderless 1920x1080 window; modes are changed by sending real **F4** key events to the in-game debug panel; FFmpeg `gdigrab` captured the window area (`results/t1/record_demo.ps1`).
* Content: None 9 s, Baseline 8 s, Adaptive 24 s at the **same fixed viewpoint** (controller starts at bias 0 and its bias rises live to about 1.4), then the **same 120 m path segment** in Baseline and in Adaptive (controller reset to bias 0). Mode labels and the real panel (FPS, frame time, target, signal, error, bias, thresholds) are on screen; the GPU/frame/bias line is read from the running controller. Nothing was edited into the video.
* Caveats: the demo controller target is **8 ms** (the project's stress-profile target). At 1080p the GPU takes about 9.5 ms against the default 16.67 ms target, so with the default the controller would correctly stay at bias 0 and there would be nothing to show; this is stated on screen. The bias is the live controller output, never pinned. The recording ran with screen capture active, so its FPS is not benchmark data. In the recording the GPU time barely changes as the bias rises (about 9.5 to 9.35 ms), consistent with the small benchmark gain.
* Not automated / limits: the first attempt (`rec1`) had its on-screen labels off-screen because of the 2D canvas scaling; it was discarded and re-recorded (rec2). The panel text is small at 720p.

## 5. Screenshots (`media/screenshots/`)
Real frames from the running project, same fixed viewpoint: `shot_a_none|baseline|adaptive_clean.png` (no overlay), `shot_a_*_ui.png` (with panel and labels), `compare_full_scene.png`, `compare_closeup_vegetation.png` (2x crop of the same pixel region), `shot_a_adaptive_ui.png` (panel in Adaptive: bias +1.39, thresholds 60 / 100 m). Adaptive frame taken at bias 1.40. Captions on the comparison images are annotations. Mean absolute pixel difference vs the baseline frame: None 3.8, Adaptive 4.0 (0-255); this includes grass wind animation, so it is not a pure LOD measure.

## 6. Presentation (`presentation/`)
`Adaptive_LOD_Godot_final.pptx` (8 slides, 22 MB, video embedded on slide 7 with a poster frame), `Adaptive_LOD_Godot_final.pdf`, `speaker_script_final.md`, `img/`, `render/` (slide PNGs from the export). Changes against the original: new native charts and table from the final series, real screenshots, the embedded recording, build/methodology updated (debug build, export blocked, 5 runs), the 1080p result corrected (+0.2 %, controller idle), the supplementary 1080p run and the live-controller evidence added, no novelty claim. **The original `S:\godot\adaptivelod\presentation\Adaptive_LOD_Godot.pptx` was not modified** (timestamp 2026-10-22 23:29). Embedded video playback was verified only through the export (the PDF shows the poster frame); play it once in PowerPoint before presenting.

## 7. Files changed or added
* New project files: `scenes/demo.tscn`, `scripts/bench/demo_recorder.gd` (demonstration only, no benchmark data, benchmark scripts untouched).
* New tooling: `results/t1/` gained `final_report.py`, `prep_final_deck.py`, `make_deck_final.js`, `record_demo.ps1`, `run_supplement.ps1` (reusing earlier `run_series.ps1`, `analyze.py`).
* All new outputs are in `results/final_run_20261023_005938/`; no earlier results, logs or the original deck were overwritten. Existing uncommitted work (LOD scripts, panel, docs, scene) is untouched by this task.

## 8. Remaining limitations
Debug/editor build only; grass determinism stage not run; gain is small and conditional on the GPU being over the controller target; earlier sessions showed large GPU-state drift (this one did not); no perceptual image metric; the recording is a demonstration with its own controller target; embedded video untested inside PowerPoint itself.
