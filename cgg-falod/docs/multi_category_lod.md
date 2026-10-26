# Multi-category baseline LOD (milestone 4)

Distance-based baseline LOD for trees, grass, bushes and debris behind one interface. No feedback, importance or
rate limiting (the adaptive controller does not exist yet). Rocks are metrics only.

## Architecture
- `scripts/lod/lod_policy.gd` (`LodPolicy`): base class of every category policy: `enabled`, `category()`,
  `instance_total()/instance_drawn()`, `tier_counts()`, `frame_switches/total_switches/last_update_ms`, `resync()`,
  `verify()`, `describe()`. Turning `enabled` off restores the baked/full-detail state; turning it on resyncs. Neither counts as switches.
- `lod_manager.gd` (node `LodManager`): finds the policy siblings; `set_baseline(bool)`, `set_categories([...])`, `resync_all()`,
  `verify_all()`, `rock_instances()`. Used by the debug panel and the benchmark runner. No LOD logic.
- Policies: `baseline_lod.gd` (trees, unchanged behaviour: 3 mesh levels, per-instance, hysteresis), `grass_lod.gd` (32 m cells, 3 tiers
  + cull, hysteresis; `lod_enabled` is kept as an alias of `enabled`), `density_lod.gd` (bushes and debris, below).
- All policies use chunked MultiMesh data, no per-instance nodes, never touch collision or the saved scenes, and are independent of Terrain3D.

## Grass
Tiers existed already (checked in `grass_builder.gd`/`grass_lod.gd`): tier 0 full, tier 1 40 % of the tufts / 35 % of turf with simpler
meshes and 1.2x/1.35x clump scale, tier 2 12 % of tufts, then culled at 110 m (25/60/110 m, hysteresis 6 m). Tiers are nested by a
deterministic per-clump key, so a clump never disappears between tiers. Unchanged in this milestone apart from the shared interface.

## Bushes
`TreeMeshes.build_bush()` is the only bush mesh; **no lower-detail variant exists**, so there is no bush mesh LOD. Fallback: density
reduction (`density_lod.gd`, node `BushLod`): per 64 m chunk, 100 % under 50 m, 60 % to 100 m, 30 % to 160 m, 10 % to 240 m, none beyond
(hysteresis 8 m). The original bush mesh is never touched.

## Debris
Same policy (`DebrisLod`): 100 % under 30 m, 50 % to 60 m, 20 % to 110 m, none beyond (hysteresis 5 m). Debris is the tiny rock mesh (scale 0.03-0.09).

## How the density policy works
On the first enabled frame each chunk's MultiMesh buffer is rewritten once, in memory, in a fixed pseudo-random order (hash of the
instance position). A density is then `visible_instance_count = ceil(n * density)`: a prefix of that order. Tier changes are one integer write
per node; instances at a coarser tier are always a subset of those at a finer one (no blinking between tiers). The saved `vegetation.scn` is
unchanged (it is not in `git status`). Build ~0.5 s per category on the first enabled frame.
Known visual limit: tiers are per chunk (nearest point of the chunk bounds), so where neighbouring chunks sit in different tiers there is a
density step (up to 40 percentage points at the 50 m boundary). There is no gap in coverage, only a change in bush density.

## Rocks
Metrics only (`rocks_instances` column, panel line, `LodManager.rock_instances()`); the nodes are never touched.

## Terrain3D
Native terrain LOD is independent. The benchmark JSON records `terrain3d` (`mesh_lods`, `mesh_size`, `vertex_spacing`, collision settings, version);
the self-test checks they do not change when LOD modes are switched. Terrain3D internals and mesh settings are not modified.

## Debug panel (F3 / F4)
Same single panel. None/Adaptive (buttons and F4) switch all four categories through `LodManager`; a partial selection reads "Mixed".
Added lines: Grass / Bushes / Debris (drawn / total, drawn per tier, switches, unit) and Rocks (metrics only); the update cost is summed over categories.

## Tests
    Godot_console.exe --path . --script res://scripts/lod/multi_lod_selftest.gd     # new: interface, density tiers, hysteresis, determinism, collision, modes, panel, path
    Godot_console.exe --path . --script res://scripts/lod/lod_selftest.gd           # original tree test
    Godot_console.exe --path . --script res://scripts/lod/grass_selftest.gd -- skip-determinism

## Benchmark results (this machine, 1080p, VSync off, 60 s, 3 interleaved runs per mode)
`results/mc_*.csv/json` (git-ignored). **Counts are reliable, timings are not**: frame time and GPU time varied 2-8x between identical runs
(none: mean GPU 35.6 / 40.5 / 84.3 ms; baseline: 18.4 / 15.5 / 25.0 ms; avg fps 11-100 across runs), p99 frame times of 60-800 ms, so
the machine was clearly contended during the series (the Godot editor was open). Do not quote frame-time gains from this series; repeat
on an idle machine.

| Mean per frame | none (3 runs) | baseline (3 runs) |
|---|---|---|
| draw calls (all passes) | 3525 / 4247 / 3921 | 1678 / 1530 / 1507 |
| draw calls, main pass | 2844 / 3370 / 3091 | 681 / 595 / 582 |
| primitives (all passes) | 14.9M / 18.8M / 18.0M | 3.16M / 2.92M / 2.89M |
| primitives, main pass | 9.6M / 11.7M / 11.0M | 1.21M / 1.11M / 1.09M |
| GPU ms (noisy) | 35.6 / 40.5 / 84.3 | 18.4 / 15.5 / 25.0 |
| bushes drawn | 7615 | ~664 |
| debris drawn | 1341 | ~33 |
| policy update cost (all categories) | - | 13.3 / 3.9 / 5.2 ms (run 1 had large hitches; CPU contention inflates it) |

Per-category switches along the path (baseline, runs 2-3): trees ~3255 instance switches, grass ~424 cells, bushes ~287 chunks, debris ~111 chunks.
Single-category runs (`mc_only_*`) show the expected ordering for draw calls (none ~3.9-4.2k; only trees 3245, only grass 1517, only bushes 3793, only debris 3879: grass dominates, trees next, bushes/debris small), but their timings are as noisy as above, so no per-category time saving is claimed.
Integrity checks (after resync and at the end) passed for all categories in every baseline run.

## Visual-quality limitations
Bushes and debris only thin out and disappear (no mesh simplification), so distant bush cover looks sparser, and cull at 240 m / 110 m may
be noticeable (the scene has light fog only). Chunk-level density steps (above). Grass keeps its existing tier popping behaviour (see `grass.md`).
Thresholds are first choices and untuned; no visual approval of the bush/debris settings has been done (no screenshots were taken in this milestone).
