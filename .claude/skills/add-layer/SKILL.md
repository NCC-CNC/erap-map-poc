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

Never commit data: `data/raw/`, `data/tiles/`, `data/work/`, `.pmtiles`,
`.cog.tif` and screenshots stay out of git. Commands below run from the repo root in Git Bash; give
paths relative to `data/raw/` (no leading `/`).

First ask, unless the user already said: is the layer just for them, or
for everyone? Just for them (data only they have, a trial): write the
same two files in the git-ignored `pipeline/layers.local/` and make sure
their `map.config.json` lists it in `layerDirs` (README, Your map config;
ADR 0009), or put the settings inline under `localLayers`. Build and check
as below, and skip the draft PR. For everyone: the steps below.

## Raster sources (GeoTIFF)

A binary raster (cells of 1 on 0 or nodata, for example a forest or
cropland mask) is a raster layer: one Cloud Optimized GeoTIFF in
`data/tiles/<name>.cog.tif`, display only, no pop-up (ADR 0008 and 0010,
`docs/design/02_data_layers_and_popups.md`, Raster layers; README, Tile
formats). Large source rasters usually live outside the repo: `RAW_DIR`
in `.env` points at their folder, mounted read-only at `/data/raw`. Never
copy them into the repo. For a raster, follow this section in place of
steps 1 to 4, then step 5.

1. Inspect with GDAL (`inspect.sh` is for vector data), in two steps.
   First the header, which takes seconds:

   ```sh
   MSYS_NO_PATHCONV=1 docker compose run --rm --build --entrypoint gdalinfo pipeline \
     -json /data/raw/<file.tif>
   ```

   Note the band count (`bands | length`), the data type
   (`bands[0].type`), the nodata value (`bands[0].noDataValue`), the CRS
   (`coordinateSystem`, or none), size and pixel size, and the block
   layout (`bands[0].block`; `[width, 1]` is a strip layout, which the
   first build handles). More than one band: stop here (step 2). Then the
   values, which reads the whole file: about 5 minutes for a Canada-wide 30 m
   raster in strips (say so, and run it in the background):

   ```sh
   MSYS_NO_PATHCONV=1 docker compose run --rm --entrypoint gdalinfo pipeline \
     -json -approx_stats -hist /data/raw/<file.tif>
   ```

   Note the min and max (`bands[0].minimum`, `maximum`) and which
   histogram buckets have counts (`bands[0].histogram`: 256 buckets from
   `min` to `max`; a binary raster has counts only in the first and last).
   Nothing is written: `RAW_DIR` is mounted read-only, so GDAL may warn
   that it cannot save the statistics.
2. Stop and explain, without writing any config, unless it is a
   single-band binary raster: only binary rasters are supported (one band,
   values 0, 1 and nodata).
   - More than one band (an RGB image, a stack of indicators):
     multiband rasters are not supported yet; each band would be its own
     layer.
   - Values other than 0, 1 and nodata (class codes such as land cover, or
     a continuous value such as a probability or density): categorical
     and continuous rasters are not supported yet. The build would draw
     every non-zero value as covered and average it at lower zooms, which
     is wrong for both. Supporting them needs a raster-kind setting
     (mode or nearest resampling for classes, average for continuous
     values), which is left for later.
   - Values 0 and 1 plus one other value with no nodata declared (often
     255, or -9999): that value is probably nodata; confirm with the user
     and set `LAYER_NODATA` to it.
3. `<name>.env` (copy the layout of `pipeline/layers/forest.env`):
   `LAYER_TYPE=raster`, `LAYER_INPUT=<file.tif>` (relative to `RAW_DIR`),
   `LAYER_MIN_ZOOM` (2 for Canada-wide, higher for a region),
   `LAYER_MAX_ZOOM` close to the source resolution (12 for 30 m, 13 for
   10 to 20 m, at most 14). `LAYER_NODATA` only when step 2 found an
   undeclared or wrong nodata value; `LAYER_SOURCE_SRS` only when there is
   no CRS (ask which). No `LAYER_FIELDS`, feature id, profile or
   tippecanoe flags.
4. `<name>.style.json` (copy `pipeline/layers/forest.style.json`): `title`,
   `defaultVisible`, an `order` below the vector layers (they are drawn
   over it), and the raster shorthand only, no `popup`:
   `"symbology": {"geometry": "raster", "color": "#rrggbb", "opacity": 0.7,
   "label": "..."}`. Ask the user for the colour if they have one in mind;
   pick one that differs from the other raster layers. The colour is
   applied by the map, not stored in the COG, so it can change later with
   `--style-only` (restyle-layer).
5. Build:

   ```sh
   docker compose run --rm --build pipeline <name>
   ```

   Say before starting: a Canada-wide 30 m raster takes about 9 to 10
   minutes on a 16-CPU laptop the first time, because the source is
   prepared once into `data/work/raster/` (a cache of about 0.1 to 0.7 GB
   per source, kept until the source file changes); later builds of it
   skip that and take 5 to 8 minutes. The log times each step
   (`prepare`, `warp`, `overviews`, `cog`). Offer a regional clip first if
   the user only wants a look. A raster with no 1 cells fails with
   `no cover`.
6. Read the layer's entry in `data/tiles/manifest.json`: `file`
   `<name>.cog.tif`, `format` `cog`, `bytes` (the COG's size), `width` and
   `height` (pixels at the max zoom; padded to the tile grid, mostly
   empty), `block_size` 256, `overview_count` (one per zoom below the
   max), `zooms[]` (each zoom's `width` and `height`), `bounds` and
   `build_seconds`. There is no drop guard and no tile count.
7. Screenshot as in step 4 below, at the whole extent (the min zoom), a
   mid zoom (about 6) and the max zoom on an area with data: check the low
   zooms read as cover density (paler where partly covered), cells stay
   sharp at the max zoom, the colour reads on both basemaps, and the
   vector layers draw over it. Then the draft PR (step 5 below), saying
   the layer is a binary raster and giving the build time and COG size.

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
- Many small polygon parts (inspect's union has thousands of parts, such
  as coastal islands): `LAYER_GENERALISE_MAX_ZOOM` about 3 below
  `LAYER_MAX_ZOOM` (7 for a max of 10), so low zooms drop small parts and
  simplify borders; check the low-zoom screenshots.

Ask the user only what the data cannot answer: usually the attribute to
colour by, the title, and which fields go in the pop-up. Then write the
style: `symbology` with `categorical` for a text attribute with few values
(one colour per inspect value), `stepped` with `breaks` (quantile or equal)
for a numeric one, `single` otherwise; a `popup` with a title attribute,
the `featureId` and the chosen stats; an `order` relative to the other
layers (higher draws on top). Use colour-blind-safe palettes. If the user
wants several attributes to colour by, use colour `themes`; for click
details with sections, tables or several charts, a `modal` instead of the
`popup` (design note 02, Click modal; the edit-popup skill fills it in).
Values a modal or pop-up shows must be in `LAYER_FIELDS` (or calculated
fields, once #60 lands).

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
