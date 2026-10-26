Benchmark output (`<label>_<timestamp>.csv` + `.json`). Columns and units: `docs/benchmark.md`.

Run outputs are git-ignored. `example_schema.csv` is the only tracked CSV: the header and the first three
rows of a real 1080p baseline-LOD run, kept to show the column layout (empty cells = unavailable metric).
Do not use it as a performance reference.

`example_schema.csv` is a schema-version-1 excerpt (24 columns). The current layout is schema version 4 (`csv_schema_version` in
each run's JSON); its full column list is in `docs/benchmark.md` and in `COLUMNS` of `scripts/bench/benchmark_runner.gd`.
A `none` run from schema 3 or later (procedural grass by default) is not comparable with a schema-1 `none` run.
