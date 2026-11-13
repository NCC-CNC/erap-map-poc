---
name: build-layers
description: Build or rebuild map layer tiles with the pipeline (one layer, several, or all), then read the build report in data/tiles/manifest.json and explain any failure, such as a drop guard failure, and what to change. Use when asked to build, rebuild, regenerate or refresh layers or tiles, or why a layer build failed.
---

# Build layers

The pipeline turns each `pipeline/layers/<name>.env` plus
`<name>.style.json` into `data/tiles/<name>.pmtiles` (vector) or
`data/tiles/<name>.cog.tif` (raster, one COG; README, Tile formats) and a
`manifest.json` entry. Commands run from the repo root in Git Bash.
Nothing under `data/` is ever committed.

## 1. Decide what to build

If the user did not name layers, see what needs it:

```sh
docker compose run --rm --build pipeline --status
```

`stale` and `not built` layers need a build; `restyle` ones only need
their display updated, with no re-tiling:
`docker compose run --rm pipeline --style-only <name> ...` (no names: every
built layer), so do not rebuild them for that alone; `invalid` ones will
fail until their config is fixed (the notes say why); `orphan` is for the
remove-layer skill. `source missing` layers are skipped by a full build
(their data is not in `RAW_DIR`) and `disabled` ones are left out by the
user's map config (`map.config.json`, README, Your map config): build
neither unless the user fixes that.

To build only some layers, or one from another copy of its data, just for
the user, change their `map.config.json` (`enabled`, `disabled`, or
`overrides.<name>.input`) rather than the committed `.env`; a change for
everyone goes in `pipeline/layers/` with a draft PR. A bad map config
stops every run with exit 2 and one line per problem.

## 2. Build

```sh
docker compose run --rm --build pipeline <name> [<name> ...]   # or no names: every layer
```

Exit 0: all built. Exit 1: at least one layer failed, the others still
built, and a failed layer keeps its previous archive and manifest entry.
Exit 2: a usage error (a name with no `.env`), nothing built.

## 3. Explain failures

Find each `[ERROR] <name>:` line in the log and match it:

- `invalid display config`: the lines before it list each problem in
  `<name>.style.json` (schema, legend, MapLibre). Fix the style (see the
  restyle-layer skill); check without building with the style check in
  `CONTRIBUTING.md` (Adding or changing a layer).
- `input not found` or `ogr2ogr failed`: `LAYER_INPUT` is wrong, the data
  is missing from `data/raw/`, or a field in `LAYER_FIELDS` no longer
  exists. Run the inspect-data skill on the input and compare.
- `drop guard: required features missing`: at the zooms named in the
  `zN: X of Y required feature(s) missing, ids include ...` lines,
  tippecanoe dropped polygons big enough to see. Options, best first:
  remove the dropping flag (`--drop-densest-as-needed`) or use
  `LAYER_PROFILE=coverage` for a contiguous coverage; raise
  `LAYER_MIN_ZOOM`; raise `LAYER_MIN_VISIBLE_PX` (accepts bigger
  invisible gaps). Explain the trade-off; let the user choose.
- `tippecanoe failed`: a bad flag in `LAYER_TIPPECANOE_FLAGS`, or a
  tile too large with no dropping flag; the tippecanoe message says which.
- Raster layers (`LAYER_TYPE=raster`): `input not found` or `cannot read`
  means `LAYER_INPUT` or `RAW_DIR` is wrong (the source is under
  `RAW_DIR`, mounted at `/data/raw`); `no cover: no 1 cells` means the
  raster has no 1 values (check its nodata value, `LAYER_NODATA`, and that
  it is binary); `cannot create .../raster` or `work dir not writable`
  means `data/work/` is not writable by the container (Linux: README,
  Linux file ownership); `not a valid COG` or `cannot write the COG` is
  a GDAL problem, often a full disk (the build needs about 10 GB of
  scratch). A style error saying a raster layer needs the raster
  shorthand means `<name>.style.json` is not `"geometry": "raster"`.
  A Canada-wide 30 m raster takes about 9 to 10 minutes the first time
  (the log times `prepare`, `warp`, `overviews` and `cog`); build it on
  its own. Its source is prepared once into `data/work/raster/`, so later
  builds skip `prepare` (`prepared source cached` in the log) until the
  source file, `LAYER_SOURCE_SRS` or `LAYER_NODATA` changes. Deleting
  `data/work/raster/` only costs that step on the next build.
- `LAYER_... is not set` or `must be an integer`: fix the `.env`
  (every setting is described in `pipeline/lib/config.sh`).

## 4. Read the report

```sh
docker compose run --rm --build pipeline --status <name> ...
```

Then the layer's entry in `data/tiles/manifest.json`: `feature_count`
against what the source holds, and per zoom in `zooms[]` that
`required_present` equals `required` and `max_tile_bytes` stays under
about 500 kB. A raster layer (`type` raster, `format` cog) has no drop
guard and no tiles to count: its entry describes the COG, `bytes` (file
size), `width` and `height` (pixels at the max zoom, padded to the tile
grid, so mostly empty), `block_size` (256, one map tile),
`overview_count` (one per zoom below the max; it should equal `maxzoom -
minzoom`), `zooms[]` (each zoom's `width` and `height`, halving per zoom)
and `build_seconds`. A raster entry with `format` png and `tile_count` is
a build from before COGs: rebuild it. Summarise per layer: state,
features (or the COG's size), zooms, largest tile (vector), and anything
to act on. To see the result, use the run-map skill.
