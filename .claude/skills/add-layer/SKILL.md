---
name: add-layer
description: Add a new map layer from a source dataset in data/raw/ or RAW_DIR (shapefile, zipped shapefile, GeoPackage, GeoJSON, ..., or a binary GeoTIFF as a display-only raster layer). Inspects the data, writes pipeline/layers/<name>.env and <name>.style.json, builds the tiles, checks the build report and screenshots, and opens a draft PR with the configs only. Use when asked to add, load or publish a dataset as a layer.
---

# Add a layer

A layer is `pipeline/layers/<name>.env` (input, fields, zooms, tiling) plus
`pipeline/layers/<name>.style.json` (title, order, style, legend, pop-up).
Nothing in `web/` changes. Reference: `pipeline/lib/config.sh` (every `.env`
setting), `docs/design/02_data_layers_and_popups.md` and
`pipeline/schema/layer-style.schema.json` (display config), and the
test layers `pipeline/tests/layers/sample*` as worked examples (`forest` in
`pipeline/layers/` for a raster).

Never commit data: `data/raw/`, `data/tiles/`, `.pmtiles` and screenshots
stay out of git. Commands below run from the repo root in Git Bash; give
paths relative to `data/raw/` (no leading `/`).

## Raster sources (GeoTIFF)

A binary raster (cells of 1 on 0 or nodata, for example a forest or
cropland mask) is a raster layer, display only (ADR 0008,
`docs/design/02_data_layers_and_popups.md`, Raster layers). Large source
rasters usually live outside the repo: `RAW_DIR` in `.env` points at their
folder, mounted read-only at `/data/raw`. Never copy them into the repo.
For a raster, follow this section in place of steps 1 and 2, then steps 3
to 5.

1. Inspect with GDAL (`inspect.sh` is for vector data):

   ```sh
   MSYS_NO_PATHCONV=1 docker compose run --rm --build --entrypoint gdalinfo pipeline \
     -stats /data/raw/<file.tif>
   ```

   Note the CRS, size and pixel size, data type, nodata value, block
   layout and the min and max. Values must be 0, 1 and nodata only; if not,
   stop and ask (other values are drawn as covered).
2. `<name>.env`: `LAYER_TYPE=raster`, `LAYER_INPUT=<file.tif>` (relative to
   `RAW_DIR`), `LAYER_MIN_ZOOM` (2 for Canada-wide, higher for a region),
   `LAYER_MAX_ZOOM` close to the source resolution (12 for 30 m, at most
   14). `LAYER_NODATA` only if gdalinfo shows no nodata value (or a wrong
   one); `LAYER_SOURCE_SRS` only if there is no CRS. No `LAYER_FIELDS`,
   feature id, profile or tippecanoe flags.
3. `<name>.style.json`: the raster shorthand only, no `popup`:
   `"symbology": {"geometry": "raster", "color": "#rrggbb", "opacity": 0.7,
   "label": "..."}` and an `order` below the vector layers. The colour and
   opacity are applied by the map, not stored in the tiles.
4. Build (step 3 below). A Canada-wide 30 m raster takes tens of minutes
   and a few GB; say so before starting, and try a regional clip first if
   the user only wants a look. The report is `tile_count`, `bytes`,
   `build_seconds` and per-zoom `zooms[]` (`tiles`, `max_tile_bytes`);
   there is no drop guard. Then screenshots as in step 4: check the low
   zooms read as cover density and cells stay sharp at the max zoom.

## 1. Inspect

```sh
docker compose run --rm --build --entrypoint inspect.sh pipeline <path/in/data/raw>
```

Add `--json` for the full detail, `--layer <name>` for a multi-layer
source, `--no-checks` if the polygon checks are too slow. Note: feature
count, geometry type, CRS, WGS84 extent, encoding, fields (values of
low-cardinality ones), id candidates, the checks and every warning.

## 2. Propose the configs

Pick a layer name (`^[a-z0-9][a-z0-9_-]*$`). Infer, do not ask:

- `LAYER_INPUT`: the path relative to `data/raw/` (`x.zip/dir/x.shp` for a
  file inside a zip). `LAYER_SOURCE_LAYER` for a multi-layer source.
- `LAYER_SOURCE_SRS` only if inspect says there is no CRS (ask the user
  which CRS if nothing hints at it); `LAYER_ENCODING` only if none is
  declared and text looks wrong.
- `LAYER_FIELDS`: the fields the style and pop-up need, plus the id;
  rename cut shapefile names (`habitat_ty:habitat_type`) and use clear
  lower-case names. `LAYER_FEATURE_ID`: an id candidate from inspect (if
  there is none, stop and ask).
- Zooms: `LAYER_MIN_ZOOM=0`; `LAYER_MAX_ZOOM` where the smallest features
  are a few hundred pixels across (about 10 for regional polygons, 12 to 14
  for small parcels; points 10 to 12).
- `LAYER_PROFILE=coverage` when inspect says coverage-like; otherwise no
  profile and `LAYER_TIPPECANOE_FLAGS=(--drop-densest-as-needed)` for
  polygons, `(--drop-rate=1)` for a modest number of points.

Ask the user only what the data cannot answer: usually the attribute to
colour by, the title, and which fields go in the pop-up. Then write the
style: `symbology` with `categorical` for a text attribute with few values
(one colour per inspect value), `stepped` with `breaks` (quantile or equal)
for a numeric one, `single` otherwise; a `popup` with a title attribute,
the `featureId` and the chosen stats; an `order` relative to the other
layers (higher draws on top). Use colour-blind-safe palettes.

## 3. Build and read the report

```sh
docker compose run --rm --build pipeline <name>
```

A failure names the problem (style config, drop guard, input); fix and
rerun. Then read the layer's entry in `data/tiles/manifest.json`:
`zooms[]` (per zoom: `present` of `input`, `required` equal to
`required_present`, `max_tile_bytes`), `bounds` and `display.legend`.
Flag tiles over about 500 kB, and features missing at zooms where users
will look; the log lists smaller features left out (allowed).

## 4. Screenshot and iterate

Pick three or four views from `bounds` (`zoom/lat/lon`): the whole layer,
a mid zoom, and `LAYER_MAX_ZOOM` on the densest area.

```sh
scripts/screenshot.sh -n <name> <z/lat/lon> <z/lat/lon> ...
```

It runs both basemaps (light and dark) on a spare port (8090 up) and
writes `tmp/screenshots/<name>-<basemap>-z<view>.png`; read each image and
any `page error` or `console error` lines. Check: colours readable on both
basemaps, legend right, outlines not swamping small features, no gaps
along shared borders, draw order against other layers. Adjust the configs
and repeat steps 3 and 4 until it looks right. Show the user the final
screenshots.

## 5. Draft PR

Branch from `main` (`feat/layer-<name>`), commit only the two files in
`pipeline/layers/` (Conventional Commit, for example
`feat(layers): add <name>`), push, and open a DRAFT PR saying where the
source data comes from, what inspect reported, the build report summary
and that screenshots were checked. Never mark it ready: ready PRs merge
themselves. Check `git status` first: nothing under `data/` or `tmp/` is
staged.
