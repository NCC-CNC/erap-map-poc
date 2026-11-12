---
name: add-layer
description: Add a new map layer from a source dataset in data/raw/ (shapefile, zipped shapefile, GeoPackage, GeoJSON, ...). Inspects the data, writes pipeline/layers/<name>.env and <name>.style.json, builds the tiles, checks the build report and screenshots, and opens a draft PR with the configs only. Use when asked to add, load or publish a dataset as a layer.
---

# Add a layer

A layer is `pipeline/layers/<name>.env` (input, fields, zooms, tiling) plus
`pipeline/layers/<name>.style.json` (title, order, style, legend, pop-up).
Nothing in `web/` changes. Reference: `pipeline/lib/config.sh` (every `.env`
setting), `docs/design/02_data_layers_and_popups.md` and
`pipeline/schema/layer-style.schema.json` (display config), and the
existing `sample*` layers as worked examples.

Never commit data: `data/raw/`, `data/tiles/`, `.pmtiles` and screenshots
stay out of git. Commands below run from the repo root in Git Bash; give
paths relative to `data/raw/` (no leading `/`).

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
