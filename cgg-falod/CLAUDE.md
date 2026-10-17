# CGG-FALOD — Adaptive LOD Research Prototype

## Project
- Engine: Godot 4.x
- Language: GDScript, with static typing where practical
- Goal: Build and evaluate a PI-controlled, importance-aware adaptive Level of Detail system.
- No C#, engine modifications, or external game injection.

## Architecture
- scenes/: Godot scenes
- scripts/lod/: baseline and adaptive LOD controllers
- scripts/bench/: deterministic benchmark and CSV logger
- assets/: meshes, textures, and other assets
- results/: benchmark output

## LOD Modes
1. BaselineLOD: fixed distance thresholds with hysteresis.
2. AdaptiveLOD: PI-controlled LOD bias, importance weighting, hysteresis, rate limiting, and a per-frame switch budget.

Both modes must use the same test scene and camera path.

## Performance
- Prefer spatially chunked MultiMeshInstance3D for large vegetation populations.
- Measure frame time, draw calls, rendered primitives, LOD switches, and controller bias.
- Distinguish CPU/process time from actual GPU frame time.
- Do not claim a performance improvement without benchmark evidence.

## Development Rules
- Work in small milestones.
- Inspect existing files before modifying them.
- Avoid unrelated features and unnecessary dependencies.
- Run Godot validation after changes where possible.
- Report files changed, commands executed, test results, and known limitations.
- Never claim a test passed unless it was actually run.
