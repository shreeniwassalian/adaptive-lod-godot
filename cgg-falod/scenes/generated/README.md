# Generated environment

`baked_environment.tscn` is generated data (ground mesh plus per-chunk `MultiMeshInstance3D` nodes for
trees, grass and rocks). Do not hand-edit its text; regenerate it. Parameters (seed 1337, sizes,
densities, tree LOD level) are stored on its root node. The generator code is in
`scripts/env/generated_environment.gd`.

`scenes/test_environment.tscn` instances this scene as `GeneratedEnvironment`, so it shows in the
3D editor viewport without running the game. If that node is removed, the game generates the
environment at runtime instead.

## Regenerate in the editor
1. Open `scenes/generated/baked_environment.tscn` (not `test_environment.tscn`; regeneration is
   refused when the node is an instance inside another scene).
2. Select the root `GeneratedEnvironment` node and change `World Seed` or other exports in the Inspector.
3. Click **Regenerate Environment** in the Inspector. Old children are removed first, so nothing is duplicated.
4. Save with Ctrl+S.

## Regenerate from the command line
Must run with a real renderer. Do NOT pass `--headless`: the dummy renderer keeps no MultiMesh data
and the script refuses to save.

    Godot_console.exe --path . --script res://scripts/env/bake_environment.gd

It reloads the saved parameters, regenerates, and rewrites the file. Output is byte-identical for the
same parameters. To change the seed from the command line, edit `world_seed` in the saved scene first.

## Editing
Individual instances are not separate nodes. Edit parameters and regenerate, or edit the MultiMesh
resources. Manual edits to generated nodes are lost on regeneration.
