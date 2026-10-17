# Terrain3D environment

Main scene: `scenes/terrain3d_environment.tscn` (set as the project's main scene).
The earlier low-poly scene (`scenes/test_environment.tscn`, `scenes/generated/baked_environment.tscn`,
`scripts/env/`) is untouched and still runs, but must not be loaded together with this one.

## Run / open
- Run: F5. Controls: WASD, mouse, Space jump, Shift sprint, Esc releases the mouse, F1 toggles the free-fly camera.
- Edit: open the scene; Terrain3D, the river and the vegetation are separate nodes (`Terrain3D`, `River`, `Vegetation`).

## Layout
| Part | Where |
|---|---|
| Terrain3D 1.0.2 plugin (unmodified) | `addons/terrain_3d/` |
| Terrain region data (4 x 512 m) | `data/terrain3d/valley/*.res`, texture list `data/terrain3d/assets.tres` |
| River mesh + water shader | `scenes/generated/river.scn`, `shaders/river_water.gdshader` |
| Chunked vegetation (256 chunks, MultiMesh) | `scenes/generated/vegetation.scn` |
| Generators | `scripts/world/` (`landscape_model.gd`, `tree_meshes.gd`, `vegetation_builder.gd`, `landscape_environment.gd`) |
| Third-party assets | `assets/terrain/` (see its README) |

## Regenerate (seed 1337, fully deterministic)
In the editor: select the root node `Terrain3DEnvironment`, change exports (seed, mountain height, densities,
`tree_lod_level`, spawn point), press **Generate All** (or Terrain / River / Vegetation separately) in the
Inspector, then save the scene.

Command line (needs a real renderer; `--headless` is refused):

    Godot_console.exe --path . --script res://scripts/world/bake_landscape.gd              # everything
    Godot_console.exe --path . --script res://scripts/world/bake_landscape.gd -- vegetation # one stage

Generate the terrain before the vegetation (vegetation reads the saved heights). Re-running with the same
parameters reproduces identical terrain files and identical vegetation counts.

## Collision
Terrain3D `FULL_GAME` heightfield collision (layer 1) for the ground; one trimesh body per chunk (layer 4)
covering tree trunks and boulders with scale >= 0.3. Foliage, bushes, grass and debris have no collision.

## LOD separation
Terrain3D's own mesh LOD handles only the terrain. Vegetation is plain MultiMeshInstance3D nodes, each tagged
with `vegetation_kind` metadata; chunk nodes carry `chunk_origin`. Spruce and broadleaf meshes exist in three
detail levels (`tree_lod_level`, currently one level for all chunks). No distance culling is applied
(`grass_visibility_range = 0`), so a later LOD controller starts from an unmodified baseline.

## Placeholders and assets still needed
Not realistic yet. Please download (all CC0; confirm the license on each page before use):
- Trees: the procedural spruce/broadleaf meshes are placeholders. Poly Haven has photoscanned CC0 pines
  ([Pine Tree 01](https://polyhaven.com/a/pine_tree_01), [Pine Sapling Small](https://polyhaven.com/a/pine_sapling_small),
  [Trees category](https://polyhaven.com/models/nature/trees)) but they are very heavy (millions of triangles), so they
  need decimation and LOD meshes before use in a forest. Lighter stylised alternative:
  [Quaternius Ultimate Stylized Nature](https://quaternius.com/packs/ultimatestylizednature.html).
- Forest floor and riverbed textures (currently tinted copies of Ground037 / Rock023):
  ambientCG [Ground011](https://ambientcg.com/view?id=Ground011), [Ground038](https://ambientcg.com/view?id=Ground038),
  [Ground106](https://ambientcg.com/view?id=Ground106) (leaves/soil/riverbed tags). Convert to Terrain3D's packed
  format (albedo+height, normal+roughness) with the plugin's Channel Packer.
- Grass blades and undergrowth with alpha textures; the current grass is geometry-only.

## Known limitations
- Foliage is blobby/stylised, with no alpha-cut leaf cards. Broadleaf trees look especially low-poly.
- River is a flat ribbon at a fixed water level: no waves, current-driven physics, swimming or buoyancy; the player wades.
- Maximum terrain slope is about 66 degrees on a few mountain faces (0.6% of the map exceeds 55 degrees); the
  player cannot climb slopes above 50 degrees.
- World is 1 km x 1 km with a hard edge; the river leaves the map at the south edge.
