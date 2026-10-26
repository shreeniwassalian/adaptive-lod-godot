# Missing evidence and experiments

## Must supply before presenting
- [ ] Screen recording of the running system (none exists in the project folder). Insert on slide 7: Insert > Video > This Device. No URL/QR was created because no link exists.
- [ ] The log or recording of the live session where adaptive LOD dropped below 10 FPS. No saved adaptive benchmark run contains that: all 6 adaptive 60 s runs have 0 frames under 10 FPS (worst 20.7 FPS). The only sub-10 frame in the m4 series is in baseline run `m4_normal_base_1` (3.7 FPS). Short `smoke_stress` (adaptive, 477 frames) has 6 frames of 100-150 ms.
- [ ] GPU driver version, RAM, power plan, thermal state (not recorded in the result JSON).
- [ ] Confirm the "two floors/levels" wording: the code has distance floors (LOD1 not before 60 m, LOD2 not before 100 m) and per-category caps, not a literal 2-level limit. Slides 3 and 4 say so; change the wording if your supervisor's spec differs.

## Experiments that would strengthen the work
- [ ] Re-run the benchmark with the current (milestone-5) mapping; all timed results use the older milestone-4 mapping.
- [ ] Repeat on an idle machine, editor closed, 5+ runs per mode and profile (normal baseline #1 ran at 9.3 ms GPU vs ~19 ms for #2/#3).
- [ ] Release/export build run (results are from a debug + editor build).
- [ ] Capture frame-time while switching modes live to test the hypothesis that the 0.7-1 s first-enable build (trees 728-1009 ms) causes hitches.
- [ ] Perceptual metric (SSIM or FLIP) in place of mean absolute pixel difference.
- [ ] Baseline/adaptive screenshots along the path with the live controller, not only pinned bias 2.0.
- [ ] Literature check before claiming any novelty.
- [ ] Re-run the self-tests (`adaptive_selftest.gd` etc.); the deck cites them as documented passing, not re-run here.
