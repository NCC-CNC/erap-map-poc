---
name: update-layer-data
description: Refresh an existing map layer (vector, or a binary raster) after its source dataset in data/raw/ or RAW_DIR was replaced or updated - re-inspect the new data, compare fields, CRS, geometry and feature count (a raster - bands, values, nodata, extent) with what the layer config expects, flag breaking changes, rebuild, and compare before and after screenshots. Use when asked to update, refresh or reload a layer's data, or when a new version of a dataset arrives.
---

# Update a layer's data

The configs (`pipeline/layers/<name>.env`, `<name>.style.json`) stay as
they are unless the new data forces a change. Commands run from the repo
root in Git Bash. Never commit data or screenshots.

## 1. Before

Note the current build and take before shots while the old tiles are
still there (views as `zoom/lat/lon` from the entry's `bounds` and
`center` in `data/tiles/manifest.json`):

```sh
docker compose run --rm --build pipeline --status <name>
scripts/screenshot.sh -n <name>-before <z/lat/lon> <z/lat/lon> ...
```

Keep `feature_count` and, from `<name>.env`, `LAYER_INPUT`,
`LAYER_SOURCE_LAYER`, `LAYER_FIELDS` and `LAYER_FEATURE_ID`. For a raster
layer (`LAYER_TYPE=raster`), keep `bytes`, `width` and `height` from its
manifest entry instead.

## 2. Put the new data in place and inspect it

The new file goes where `LAYER_INPUT` points (or update `LAYER_INPUT` if
the name changed). A raster layer: inspect the new GeoTIFF with GDAL as in
the add-layer skill (Raster sources, steps 1 and 2) and stop if it is no
longer a single-band binary raster (0, 1 and nodata); compare the CRS,
pixel size, extent and nodata value with the old one (a new nodata value
may need `LAYER_NODATA`). A replaced file (a new size or modification
time) makes the next build prepare it again, replacing its cached copy in
`data/work/raster/`, so the rebuild takes the full first-build time
(about 9 to 10 minutes for a Canada-wide 30 m raster). A vector layer:

```sh
docker compose run --rm --build --entrypoint inspect.sh pipeline <LAYER_INPUT> --json
```

Compare with the config and the old build, and list what changed:

- Breaking: a source field in `LAYER_FIELDS` (the part before `:`) is
  gone or renamed; the id field is gone, no longer an integer or not
  unique; the CRS is gone (needs `LAYER_SOURCE_SRS`); the geometry type
  changed; a field the style uses changed type, or categorical values
  in `<name>.style.json` no longer occur.
- Worth flagging: feature count up or down by more than a few percent,
  extent moved, new categorical values (they draw in the fallback
  colour), new fields the user may want, polygon checks now failing.

Stop and agree any config change with the user before going on.

## 3. Rebuild and compare

```sh
docker compose run --rm --build pipeline <name>
docker compose run --rm --build pipeline --status <name>
scripts/screenshot.sh -n <name>-after <same views>
```

A failed build keeps the old tiles (or COG); see the build-layers skill
for the messages. Compare before and after shots on both basemaps and the
new `feature_count` (a raster: `bytes`, `width` and `height`), and tell
the user what changed.

## 4. PR, only if configs changed

The data itself is never committed. If a config changed, branch from
`main` (`feat/layer-<name>-data`), commit only `pipeline/layers/` files,
push, and open a DRAFT PR naming the new data version and what changed.
Never mark it ready: ready PRs merge themselves.
