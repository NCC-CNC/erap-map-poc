# Pipeline

Turns source data into the files the map reads: a `.pmtiles` per vector
layer, a `.cog.tif` per raster layer, `style.json` and `build.json`, in
`data/tiles/`. Bash with GDAL/OGR, tippecanoe and the `pmtiles` CLI, plus
`yq`, `jq` and `jv` to read and check the YAML files (ADR 0002, 0015).
No Node. How the steps fit together is in `docs/how-it-works.md`; how to
run them is in `docs/guide.md`.

## Contents

| Path | What |
| --- | --- |
| `Dockerfile` | the image: pinned GDAL base, tippecanoe built from source, `pmtiles`, `yq`, `jv`, bats; targets `test` and `runtime` |
| `bin/` | the two commands (below) |
| `lib/` | the build steps, sourced by `bin/` (below) |
| `layers/` | the committed layer files, `<layer>.yaml` |
| `layers.local/` | your own layer files (git-ignored; not in the image, read from the repo mount) |
| `schema/` | `layer.schema.json` (a layer file) and `map.schema.json` (a map config) |
| `tests/` | bats tests (`*.bats`, `helpers.bash`), the test layers `sample` and `sample_points` (`tests/layers/`) and synthetic fixtures (`tests/fixtures/`, with the scripts that make them) |

In the image the pipeline is at `/opt/pipeline`; compose mounts
`layers/` over the image's copy, so a layer change needs no rebuild.

## bin/

- `run.sh`: the entry point of the image. Builds every layer or the
  named ones; `--status [--json]` lists each layer's state, `--style-only`
  rewrites `style.json` from the layer files' display without re-tiling,
  and `--remove` deletes a layer's build. `run.sh --help` has the options,
  environment variables and exit codes.
- `inspect.sh`: summarises a source dataset (fields, CRS, extent, id
  candidates, polygon validity and coverage checks); `--starter` prints a
  starter layer file for it. Read only.
  `inspect.sh --help` has the options.

## lib/

| File | What |
| --- | --- |
| `layerfile.sh` | reads every layer file and the map config once per run: checks them with `jv` and the checks a schema cannot make, applies overrides, resolves which layers to build and sets the processing preset's settings |
| `normalise.sh` | reads a source with `ogr2ogr` into GeoJSONSeq: EPSG:4326, valid geometries, the kept and renamed attributes, the feature id |
| `joins.sh` | `source.joins`: reads each table once and adds its rows by key, with jq |
| `calculated.sh` | `fields.calculated`: SQLite expressions run by `ogr2ogr -dialect SQLite`, one nested query per field |
| `generalise.sh` | polygon layers (`coverage` and `default`), every zoom: drop small parts and simplify per zoom (as a coverage for `coverage`), with GDAL (ADR 0016) |
| `tiles.sh` | runs tippecanoe into a temp file, verifies and checks it, then moves it into place |
| `guard.sh` | the drop guard: fails a build that lost a visible polygon at some zoom, and gathers per-zoom stats (ADR 0016) |
| `raster.sh` | the `raster` profile: prepares a binary raster once (cached in `data/work/raster/`), warps it with `gdalwarp` and writes a Web Mercator COG of the share covered with `gdal_translate -of COG` (average overviews; ADR 0010) |
| `build.sh` | `build.json`: the build report, one entry per built layer, with the hashes that spot stale builds |
| `style.sh` | `style.json`: the MapLibre style of every built layer, with `erap:` metadata |
| `status.sh` | `--status`: each layer's state, read only |
| `log.sh` | logging to stderr |

## Tests

`docker build --target test -t erap-map-pipeline:test pipeline` then
`docker run --rm erap-map-pipeline:test` runs every bats test. They use
the synthetic fixtures only, never real data. `CONTRIBUTING.md` (Checks)
has the full set of CI commands.
