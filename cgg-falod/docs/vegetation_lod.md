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

## Tests
`Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd [-- nolod] [-- shots=<dir>]` (needs a real
renderer): follows the player camera, moves the player, checks integrity (`verify()`: every tree drawn once, original
transforms, counts, collision bodies unchanged), compares trunk raycasts across LOD changes, and walks the benchmark path.
