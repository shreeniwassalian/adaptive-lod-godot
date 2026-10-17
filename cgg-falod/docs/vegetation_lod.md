# Baseline vegetation LOD (milestone 2)

Distance-based LOD for spruce and broadleaf trees. Distance only: no feedback, importance weighting, rate limiting
or switch budget (those belong to the adaptive controller, which does not exist yet).

## What it does
Trees have three mesh detail levels (`TreeMeshes.build_spruce/build_broadleaf`, level 0 = most detailed).
The scene file is **not** modified: the baked chunk MultiMeshes hold level 0 only. On the first enabled frame
`scripts/lod/baseline_lod.gd` (node `VegetationLod` in `terrain3d_environment.tscn`) rebuilds, in memory, each
chunk's `Spruce` and `Broadleaf` MultiMesh into three MultiMeshInstance3D nodes (`Spruce`, `Spruce_LOD1`,
`Spruce_LOD2`) in the same chunk node. Each holds a packed range of the trees currently at that level
(`visible_instance_count`), so every tree is drawn at exactly one level. Levels 1 and 2 reuse level 0's materials.
Transforms are copied unchanged. A level with no trees is hidden so the renderer does not submit it.
Collision (`PropBody` per chunk) is never touched, so it does not depend on render LOD.
Node count: +958 MultiMesh nodes for 9,816 trees in 253 chunks (no per-tree nodes). Build time about 0.3 s.

## Rule
Level 0 up to `lod1_distance`, level 1 up to `lod2_distance`, level 2 beyond; distance is from the active
camera to the tree's origin. A tree moves to a coarser level only after passing a threshold by `hysteresis`
metres, and to a finer one only after coming that far inside it. Chunks whose distance range is clear of every dead
band are decided in one step; only chunks near a threshold are evaluated per tree.

| Export (on `VegetationLod`) | Default | |
|---|---|---|
| `enabled` | true | false = baked scene untouched (the no-LOD reference) |
| `lod1_distance` | 60 m | level 0 -> 1 |
| `lod2_distance` | 150 m | level 1 -> 2 |
| `hysteresis` | 10 m | half-width of the dead band (warns if `lod2 <= lod1 + 2 * hysteresis`) |

The defaults are a first choice for ~16 m / ~12 m trees; they have not been tuned.

## Camera
Uses `get_viewport().get_camera_3d()`: the player camera in normal play, the free-fly camera after F1, the scripted
camera in the benchmark. It reads no input.

## Debug panel (F3)
`scripts/ui/lod_debug_panel.gd` (node `LodDebugPanel` in the environment scene). F3 shows or hides it; F4 switches mode
without the mouse. Hidden by default and idle while hidden. While shown the cursor is released (so the buttons work) and
hiding recaptures it if it was captured. It shows the mode, FPS and frame time (smoothed over the recent frames, not the
benchmark's per-frame values), trees at LOD0/1/2 and their total, the cumulative LOD switches (+ last frame), thresholds,
hysteresis and the LOD update cost.
- **None** disables `VegetationLod`: every tree is moved back to level 0 (the baked mesh), levels 1 and 2 are hidden,
  and the controller stops updating. **Baseline** enables it again and resyncs from the camera. Neither the restore nor the
  resync counts as LOD switches, so the switch counter only reflects movement. Each switch takes about 20 ms once.
- The panel only drives and reads the existing controller; there is no second controller. The benchmark runner removes
  the panel node at start, so it never takes part in a benchmark run.
- `results/.gdignore` stops the editor importing benchmark CSVs as translations.

## Tests
`Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd [-- nolod|restored] [-- shots=<dir>]` (needs a real
renderer): drives the debug panel (F3/F4, buttons, displayed numbers, mode round trips), follows the player camera, moves the player, checks integrity (`verify()`: every tree drawn once, original
transforms, counts, collision bodies unchanged), compares trunk raycasts across LOD changes, and walks the benchmark path.
