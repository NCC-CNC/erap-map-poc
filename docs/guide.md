# Guide

Each task as plain commands, run from the repo root in Git Bash (on
Windows) or any bash. Only Docker with Compose is needed. Claude Code
skills do the same tasks with the same commands; they are optional
(README, Using Claude Code).

Where a command passes a container path such as `/opt/...` on Windows,
put `MSYS_NO_PATHCONV=1` in front of it, or Git Bash rewrites the path.

Contents:

- [Set up](#set-up)
- [Run the map](#run-the-map)
- [Look at a dataset](#look-at-a-dataset)
- [Add a layer](#add-a-layer)
- [Build layers and check their status](#build-layers-and-check-their-status)
- [Change how a layer looks](#change-how-a-layer-looks)
- [Change a pop-up](#change-a-pop-up)
- [Update a layer's data](#update-a-layers-data)
- [Remove a layer](#remove-a-layer)
- [Your own map and layers](#your-own-map-and-layers)
- [Take screenshots](#take-screenshots)
- [Publish the GitHub Pages copy](#publish-the-github-pages-copy)
- [Run the checks](#run-the-checks)

## Set up

```sh
scripts/setup.sh --init   # checks, writes .env, builds images and layers, starts the map
scripts/setup.sh          # checks only, changes nothing
scripts/setup.sh --help   # options: --raw-dir, --yes, --skip-layers, ports
```

`--init` checks Git Bash, Docker Desktop (running, Linux containers, WSL
2, memory, CPUs, disk), `.env`, `RAW_DIR` and the ports, with a one-line
fix for each problem. It asks for the data folder (`RAW_DIR`) and the
ports, writes `.env`, builds the images and every layer whose source it
finds, and starts the map. It is safe to stop and rerun.

By hand: copy `.env.example` to `.env` and set `RAW_DIR` to the folder
holding the source data (such as `C:/data/ERAP_play_data`), then build
the layers and start the map as below.

## Run the map

```sh
docker compose up -d --build web   # http://localhost:8080 (WEB_PORT)
docker compose logs -f web
docker compose down
```

nginx serves `data/tiles/` straight from the folder, so a rebuilt layer
shows on a page reload. After pulling changes to `pipeline/` or `web/`,
add `--build` to rebuild the image.

For app development, the Vite dev server with hot reload:

```sh
docker compose --profile dev up web-dev   # http://localhost:5173 (WEB_DEV_PORT)
```

A blank panel or "no layers" usually means nothing is built yet: run the
pipeline. A port in use: set `WEB_PORT` in `.env`.

## Look at a dataset

```sh
docker compose run --rm --entrypoint inspect.sh pipeline parcels.gpkg
docker compose run --rm --entrypoint inspect.sh pipeline --layer ERAP_2026_ecoregions ERAP_2026_ecoregions.gdb
docker compose run --rm --entrypoint inspect.sh pipeline --help
```

Paths are relative to `RAW_DIR`. It prints the layers, feature count,
geometry type, CRS, extent, encoding, each field with its range and
values, feature id candidates and, for polygons, validity and coverage
checks (`--no-checks` skips them on big data). `--json` gives more
detail.

`inspect.sh` is for vector data. For a GeoTIFF use `gdalinfo` in the
same image: first the header (bands, data type, nodata, CRS, size), then
the values, which reads the whole file (about 5 minutes for a
Canada-wide 30 m raster):

```sh
MSYS_NO_PATHCONV=1 docker compose run --rm --entrypoint gdalinfo pipeline -json /data/raw/forest.tif
MSYS_NO_PATHCONV=1 docker compose run --rm --entrypoint gdalinfo pipeline -json -approx_stats -hist /data/raw/forest.tif
```

Only a single-band binary raster (values 0, 1 and nodata, any data type
and CRS) can be a layer: its histogram has counts only in the first and
last buckets. Categorical, continuous and multiband rasters are not
supported yet.

## Add a layer

1. Put the data in `RAW_DIR`: anything GDAL opens, or a single-band
   binary GeoTIFF (0, 1 and nodata) for a raster layer.
2. Print a starter layer file and save it. The name of the file is the
   layer name (lower case letters, digits, `_` and `-`):

   ```sh
   docker compose run --rm -T --entrypoint inspect.sh pipeline --starter parcels.gpkg \
     > pipeline/layers/parcels.yaml
   ```

   The starter has the source and a feature id, every field (renamed to
   lower case where needed), a profile and zooms from the geometry and
   extent, one colour and a pop-up listing the fields. For a raster,
   copy `pipeline/layers/forest.yaml` instead and change `source.path`,
   `title` and the colour.
3. Edit it: check the id, keep only the fields you need, set `title`,
   `order` and the colours, and trim the pop-up. Every key is in
   [layer-file.md](layer-file.md).
4. Build it and look at it:

   ```sh
   docker compose run --rm pipeline --status parcels   # problems in the file, if any
   docker compose run --rm pipeline parcels
   docker compose up -d web                            # then reload the page
   ```

5. For everyone: commit the layer file only (never data) on a branch and
   open a pull request. For you only: put the file in
   `pipeline/layers.local/` instead (see [Your own map and
   layers](#your-own-map-and-layers)).

## Build layers and check their status

```sh
docker compose run --rm pipeline                    # every layer (the map config's choice)
docker compose run --rm pipeline forest ecoregions  # only these
docker compose run --rm pipeline --status           # what is built, stale or invalid; read only
docker compose run --rm pipeline --status --json    # with every detail
```

`--status` gives each layer a state: `current`, `stale` (its source,
fields, processing or source data changed: rebuild it), `not built`, `source
missing` or `invalid` (with the problems in its file, or built but its
layer file is gone), with notes, such as for a layer the map config
leaves out. It
also shows build time, archive size, zooms, feature count and the
largest tile.

A full build skips a layer whose source is missing, with a warning; a
named one fails. A failed build keeps the previous files and says why.
A drop guard failure means a visible polygon was lost at a zoom: raise
`processing.min_visible_px`, lower `min_part_px`, or add tippecanoe
options in `processing.tippecanoe`. `data/tiles/build.json` has the
details of each build.

Times: a vector layer takes seconds to minutes; a Canada-wide 30 m
raster about 10 minutes the first time and less once its prepared
source is cached in `data/work/`. Give Docker Desktop as many CPUs as
you can and at least 8 GB of memory. The first image build takes about 4
minutes (it compiles tippecanoe).

Demo layers without any data, from the synthetic test layers:

```sh
MSYS_NO_PATHCONV=1 docker compose run --rm -e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline
docker compose run --rm pipeline --remove sample sample_points   # when done
```

## Change how a layer looks

Edit `display` (and `title`, `visible`, `order`) in the layer file:
colours and class breaks in `display.layers`, "Colour by" choices in
`display.themes`, and `legend` (see [layer-file.md](layer-file.md#display)).
Then apply it without re-tiling, in seconds, and reload the page:

```sh
docker compose run --rm pipeline --style-only forest
```

Colouring by an attribute that is not in the tiles needs it in
`fields.keep` (or `fields.calculated`) first, and a rebuild.

## Change a pop-up

Edit `display.popup` in the layer file: its `title`, `size` (`small` or
`dialog`) and `sections` of `attributes`, `table`, `chart`, `text` and
`list` blocks, with number formats (see
[layer-file.md](layer-file.md#popup)). Then:

```sh
docker compose run --rm pipeline --style-only ecoregions
```

To see which attributes the tiles have, look at the layer's
`fields.keep` and `fields.calculated`, or at the source with
`inspect.sh`. An attribute not in the tiles needs adding to `fields` and
a rebuild:

```sh
docker compose run --rm --entrypoint inspect.sh pipeline --config ecoregions   # as the build sees it
docker compose run --rm pipeline ecoregions
```

## Update a layer's data

When a source file is replaced:

1. Inspect the new file ([Look at a dataset](#look-at-a-dataset)) and
   compare it with the layer file: the fields in `fields.keep` and
   `joins`, the id, CRS, geometry type and feature count (for a raster:
   bands, values, nodata, extent).
2. Fix the layer file for any renamed or missing field.
3. `docker compose run --rm pipeline --status <layer>` shows it `stale`;
   rebuild it with `docker compose run --rm pipeline <layer>`.

A build that fails (a field gone, say) keeps the previous tiles.

## Remove a layer

```sh
git rm pipeline/layers/<layer>.yaml                    # or delete it from layers.local/
docker compose run --rm pipeline --remove <layer>      # its archive, build.json entry and style.json part
```

The source data is left alone, and so is a raster's prepared source in
`data/work/raster/` (delete it to reclaim the space). After pulling a
change that removed a layer, `--status` shows your build of it as
`invalid` (no layer file); the same `--remove` clears it.

## Your own map and layers

Changes for your map only, with no pull request:

- **Map config**: copy `map.config.example.yaml` to `map.config.yaml`
  (git-ignored) to pick the layers to build, use your own copy of a
  source, lower a max zoom, or set the opening view, zoom limits,
  basemap, page title and number locale. See
  [layer-file.md](layer-file.md#map-config).
- **Your own layers**: put layer files in `pipeline/layers.local/`
  (git-ignored). They are built like the committed ones; a name that
  repeats a committed layer is an error.

Then build (for `overrides` or new layers) or apply with `--style-only`
(for the view, basemap, title or locale).

## Take screenshots

```sh
scripts/screenshot.sh -n forest 4/55/-110 8/53.9/-114.2       # light and dark, into tmp/screenshots/
scripts/screenshot.sh -c -n ecoregions --tab Habitat 5/55/-100 # click, then a dialog tab
scripts/screenshot.sh --help
```

Views are `zoom/lat/lon`. It runs a private copy of the web image on a
spare port and removes it after; the map on :8080 is not touched.
Screenshots never go in git.

## Publish the GitHub Pages copy

For maintainers, after checking the data may be public. Everything
published is public (ADR 0014). One-off setup: the repo's Settings,
Pages, Source: GitHub Actions; and `gh` signed in (`gh auth login`).

The copy is built from the committed layers with `map.pages.yaml`: max
zoom 10, 8 grey levels for the rasters, and protected areas from the
public CPCAD (`ProtectedConservedArea_2025.gdb`, which must be in
`RAW_DIR`; `require` stops the build without it).

```sh
docker compose run --rm --build pipeline-pages   # into data/pages/ (never data/tiles/)
docker compose --profile pages up -d web-pages   # look at it on :8081 (WEB_PAGES_PORT)
scripts/publish-pages.sh --dry-run               # checks only, changes nothing
scripts/publish-pages.sh                         # upload to the pages-data release, deploy
```

The site is at <https://ncc-cnc.github.io/erap-map-poc/> once the
workflow finishes. The script refuses layers from `layers.local/` and a
copy over the 1 GB Pages limit (lower a max zoom in `map.pages.yaml`).
`gh workflow run pages.yml --ref main` redeploys the app with the same
data.

## Run the checks

The CI checks, all in Docker, are in `CONTRIBUTING.md` (Checks).
