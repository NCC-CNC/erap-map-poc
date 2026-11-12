---
name: build-layers
description: Build or rebuild map layer tiles with the pipeline (one layer, several, or all), then read the build report in data/tiles/manifest.json and explain any failure, such as a drop guard failure, and what to change. Use when asked to build, rebuild, regenerate or refresh layers or tiles, or why a layer build failed.
---

# Build layers

The pipeline turns each `pipeline/layers/<name>.env` plus
`<name>.style.json` into `data/tiles/<name>.pmtiles` and a
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
- Raster layers (`LAYER_TYPE=raster`): `gdalwarp failed` or `input not
  found` means `LAYER_INPUT` or `RAW_DIR` is wrong (the source is under
  `RAW_DIR`, mounted at `/data/raw`); `no tiles: no 1 cells` means the
  raster has no 1 values in the zoom range (check its nodata value,
  `LAYER_NODATA`); a style error saying a raster layer needs the raster
  shorthand means `<name>.style.json` is not `"geometry": "raster"`. A
  Canada-wide raster takes tens of minutes; build it on its own.
- `LAYER_... is not set` or `must be an integer`: fix the `.env`
  (every setting is described in `pipeline/lib/config.sh`).

## 4. Read the report

```sh
docker compose run --rm --build pipeline --status <name> ...
```

Then the layer's entry in `data/tiles/manifest.json`: `feature_count`
against what the source holds, and per zoom in `zooms[]` that
`required_present` equals `required` and `max_tile_bytes` stays under
about 500 kB. A raster layer (`type` raster) has no drop guard: its entry
has `tile_count`, `bytes`, `build_seconds` and per zoom `tiles` and
`max_tile_bytes`. Summarise per layer: state, features (or tiles), zooms,
largest tile,
and anything to act on. To see the result, use the run-map skill.
