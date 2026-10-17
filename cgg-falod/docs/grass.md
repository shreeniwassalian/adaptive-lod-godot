# Procedural grass (v2) and grass LOD

Replaces the look of the original grass (22,320 identical 27-triangle tufts, flat dark green) with a procedural field
that is LOD-ready. The original grass is untouched in `vegetation.scn` and stays selectable as the reference.

## What it is
- **Meshes** (`scripts/world/grass_meshes.gd`): two kinds, both curved, tapered blades with varied height, width, lean
  and colour (dark root to light tip, a few dry blades), opaque, no textures, no alpha.
  - *Tufts*: the taller clumps. Level 0 = 14 blades x 3 segments (70 triangles), level 1 = 8 wider blades (24),
    level 2 = 5 wider blades (5); 4 / 2 / 1 distinct variants per level.
  - *Turf*: short, dense patches (blades 9-26 cm) that cover the ground between the tufts. Level 0 = 14 blades x
    2 segments (42 triangles), level 1 = 7 wider blades (7); 4 / 2 variants. No level 2: far away the tufts carry cover.
  Each clump is also tinted per instance (brightness and a noise-driven dry patch) through the MultiMesh instance colour.
- **Material** (`shaders/grass.gdshader`, one shared `ShaderMaterial`, two-sided, opaque): vertex-colour albedo, soft
  ambient occlusion at the roots, blade normals tilted across each blade so it shades like a curved leaf, light
  transmission through the blades (backlight) toward the tips, large-scale light/dark patches from world position, and
  wind sway (stiff roots, free tips). Wind is the only time-dependent part; `GrassLod.wind_strength = 0` switches it off.
- **Placement** (`scripts/world/grass_builder.gd`): tufts are clusters (2-7 clumps within 1.3 m) on a jittered grid;
  turf is one patch per ~1.1 m on a jittered grid. Both are thinned by the old suitability rules (forest shade, slope,
  altitude, water edge) and by low-frequency meadow patches. Turf uses its own random stream, so the tuft layout is the
  same as before turf existed. Clumps sit 3 cm below the terrain height, lean 35 % with the slope, vary in size and are
  deterministic: a fresh build equals the saved scene byte for byte (checked by the self-test).
- **Storage** (`scenes/generated/grass.scn`, node `GrassField`): 32 m cells, each with MultiMeshInstance3D nodes per kind,
  tier and variant, no per-clump nodes. Nodes carry `grass_tier` and `grass_kind` metadata. Tuft tier 1 is the first 40 %
  of a cell's tufts by a deterministic random rank, tier 2 the first 12 %; turf tier 1 the first 35 %; clumps are scaled up
  per tier to keep ground cover. The saved scene shows tier 0 only, so without any controller it is the full-detail
  reference. Grass casts no shadows.
- **Numbers:** 403,088 clumps (137,060 tufts + 266,028 turf) in 1,008 cells and 12,978 MultiMesh nodes; 20.8 M
  triangles if every clump is drawn at tier 0 (the legacy grass: 0.60 M). Regenerate with
  `Godot_console.exe --path . --script res://scripts/world/bake_grass.gd [-- density=1.0] [-- turf=1.0]` (real renderer, not
  `--headless`; reads the saved Terrain3D data and writes only `grass.scn`; about 40 s to 2 min). `turf=0` bakes tufts only.

## Controller (`scripts/lod/grass_lod.gd`, node `GrassLod`)
Independent of the tree controller and of Terrain3D's own terrain LOD.

| Export | Default | |
|---|---|---|
| `style` | V2 | `LEGACY` shows the original tufts and hides the field; `V2` the reverse |
| `lod_enabled` | true | false = every cell at tier 0 (no grass LOD) |
| `wind_strength` | 1.0 | sway amplitude of the shared grass material; 0 = still (use for comparable screenshots) |
| `tier1_distance` / `tier2_distance` / `cull_distance` | 25 / 60 / 110 m | cell distance for tier 0 -> 1 -> 2 -> no grass |
| `hysteresis` | 6 m | half-width of the dead band |

Distance is from the active camera to the cell's padded bounds. Each cell shows exactly one tier; switching toggles node
visibility only. It reads no input and follows the player, free-fly or benchmark camera. `verify()` checks that every
cell shows exactly the tier it records, the style matches visibility, and the tracked clump counts match the visible nodes.

## Tests
`Godot_console.exe --path . --script res://scripts/lod/grass_selftest.gd [-- shots=<dir>]`: structure, tier nesting, terrain
conformity, determinism, style and tier switching with integrity checks along the benchmark path, hysteresis, measured
popping when one cell changes tier, and comparison / overdraw images. Comparison images from the review are in
`docs/images/grass/`.

## Known limits
- Cells are 32 m, so a tier change is a visible patch, not per clump; there is no cross-fade. Measured pixel change per
  switch is in the report that accompanied this change.
- Wind is a vertex shader sway only (no interaction with the player). Nothing is billboarded.
- Turf and tufts are separate MultiMesh nodes per cell, so the node count roughly doubled; every visible node is a draw call.
- `scripts/lod/grass_compare.gd` renders legacy / earlier v2 / current grass from the same poses and records draw calls,
  primitives and GPU time per pose (single run, noisy; the benchmark harness is the authoritative measurement).
- The grass update loops over all 1,003 cells in GDScript every frame (about 1.2 ms in a debug build); a grid window
  around the camera would reduce it.
- Placement density is tuned by eye, and clump height/width constants were chosen by eye from screenshots.
- Clumps are placed on the terrain data heights; at far Terrain3D mesh LODs the rendered surface can differ slightly
  from the data (not measured).
