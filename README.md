# ERAP Map PoC

A proof of concept for processing spatial data into vector tiles and viewing
them in an interactive web map.

![The web map on the Light basemap with the ERAP ecoregions coloured by
percent protected over the forest and protected area layers, the layer
panel with its "Colour by" choice and legends on the left, and the click
modal of the Mid-Boreal Lowland ecoregion showing its summary, a habitat
table and a grouped bar chart](docs/images/map-modal.png)

- **Pipeline** (`pipeline/`): bash scripts using GDAL, tippecanoe, and the
  `pmtiles` CLI turn source data in `data/raw/` into one `.pmtiles` file per
  layer in `data/tiles/`, plus a `manifest.json` that tells the map how to
  draw each layer.
- **Web map** (`web/`): a React + MapLibre GL JS app that loads those layers
  straight from the `.pmtiles` files and opens pop-ups with summary stats and
  Chart.js charts when a feature is clicked.

Both run in their own Docker containers, tied together by
`docker-compose.yml`.

Status: M1 skeleton. Two synthetic layers (made-up polygons and points, no
real data) run from raw file to clickable feature; the source data, styling,
and pop-up content are still to be confirmed. Setup, checks and the pull
request process are in `CONTRIBUTING.md`. See `docs/design/` for the brief,
architecture, and milestones, and `docs/decisions/` for the ADRs.

## Getting started

For a new user on Windows 11. You need two things, both from IT (each
needs admin rights to install):

- **Git for Windows** (also at <https://git-scm.com>), which gives you Git
  Bash. Use Git Bash for every command here, not PowerShell.
- **Docker Desktop**, with the WSL 2 engine. After it is installed,
  restart Windows and start Docker Desktop once.

The source data stays outside the repo, in a folder such as
`C:/data/ERAP_play_data`. Then, in Git Bash:

```sh
git clone https://github.com/NCC-CNC/erap-map-poc.git
cd erap-map-poc
scripts/setup.sh --init
```

`--init` checks the machine (Git Bash, Docker Desktop running in Linux
containers mode, WSL 2, Docker memory, CPUs and disk, the ports), asks
for the data folder and ports (Enter keeps the default) and writes
`.env`, builds the images and every layer whose source data it finds,
starts the map and prints its address, <http://localhost:8080> by
default. Each problem it finds comes with a one-line fix. The first run
takes about 5 minutes plus the layers (a raster layer takes about 10
minutes); it is safe to stop and rerun. `scripts/setup.sh` on its own
only checks, changing nothing, and `--help` lists the options, such as
`--raw-dir`, `--yes` and `--skip-layers`.

### With Claude Code (optional)

Claude Code is never needed, but if you have it, ask it to "clone
NCC-CNC/erap-map-poc and set it up". Once the repo is cloned, its
`setup` skill runs the same script, explains each problem in plain
language, helps write `.env` and opens the map.

## Project map

- `pipeline/`: the tile builder image. `bin/run.sh` is the entry point
  (builds, `--status`, `--style-only`, `--remove`) and `bin/inspect.sh`
  summarises source data. `lib/` holds the build steps (layer and map
  config, normalise, calculated fields and action rules, low-zoom
  generalisation, vector tiles, raster COGs, drop guard, display config,
  manifest, status). `layers/` has one `<layer>.env` and
  `<layer>.style.json` per layer, plus any `<table>.rules.json` action
  rules table. `schema/` has the JSON Schemas for display configs, the
  map config and rules tables. `style/` is the Node tool that checks
  them, resolves display configs and parses calculated field
  expressions. `tests/` has the bats tests, the `sample` test layers
  and synthetic fixtures.
- `web/`: the map app (`src/map/` the map, layer panel, "Colour by" and
  click wiring, `src/layers/` the manifest reader and colour themes,
  `src/popup/` pop-up content and number formats, `src/modal/` the click
  modal template and dialog, `src/chart/` the Chart.js charts) and the
  nginx image that serves it along with `data/tiles/`.
- `map.config.example.json`: a starting point for your own git-ignored
  `map.config.json` (Your map config, below).
- `data/`: `raw/` for source data, `tiles/` for pipeline output. Neither is
  committed.
- `docs/`: design notes (`design/`), ADRs (`decisions/`), session handoffs
  (`handoffs/`) and images.
- `.github/`: CI (`ci.yml`), auto-merge, branch update and cache warming
  workflows, Dependabot config, issue forms and the PR template.
- `scripts/`: `setup.sh` (first-time setup and machine check, Getting
  started), `screenshot.sh` (map screenshots, optionally with a feature
  clicked or a colour theme chosen), `check-tiles-cache.sh` (the web
  smoke test's check that a rebuild reaches the browser on reload) and
  `bootstrap-repo-settings.sh` (one-time repo settings: branch
  protection, auto-merge, labels); `tests/` holds their bats tests.
- `.claude/skills/`: optional Claude Code skills for common tasks (Using
  Claude Code, below); each calls the plain commands documented here.

## Usage

Requires Docker with Docker Compose v2. Nothing else (no Node, GDAL or
tippecanoe) is needed on the host. Compose builds two local images,
`natureconservancy/erap-map-pipeline` and `natureconservancy/erap-map-web`;
they are not pushed anywhere.

```sh
# Build tiles into data/tiles/: every layer in pipeline/layers/, or only
# the ones named. The layers (`ecoregions`, `protected_areas`, `forest`,
# `agriculture`) read their source from RAW_DIR, here the folder holding
# the November 2026 play data (see .env.example).
RAW_DIR=C:/data/ERAP_play_data docker compose run --rm --build pipeline forest
RAW_DIR=C:/data/ERAP_play_data docker compose run --rm pipeline   # every enabled layer

# Demo tiles without any data: the synthetic test layers `sample` and
# `sample_points` (pipeline/tests/layers/, baked into the image) are not
# built by default; point the layers dir at them. Remove them again with
# `--remove sample` and `--remove sample_points`. If your map config names
# other layers, add `-e PIPELINE_MAP_CONFIG=` to leave it out.
docker compose run --rm -e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline

# After editing only a layer's .style.json (colours, legend, pop-up, title,
# order): update its display in seconds, no re-tiling. No names: every
# built layer.
docker compose run --rm pipeline --style-only forest

# What is configured and built, which builds are stale (the .env or the
# source data changed since) and which need only --style-only (`restyle`);
# --json for detail. Read only.
docker compose run --rm pipeline --status

# Run the web map at http://localhost:8080 (WEB_PORT changes the port).
docker compose up -d --build web
docker compose logs -f web
docker compose down
```

`docker compose run` and `up` reuse an existing image, so after pulling or
changing code in `pipeline/` or `web/`, rebuild it: with `--build` as above,
or `docker compose build`. The first pipeline build takes about 4 minutes
(it compiles tippecanoe); later ones take seconds. A rebuilt layer needs no
restart: nginx serves `data/tiles/` straight from the host folder, so
reload the page.

### Where data goes

- `data/raw/`: source data, mounted read-only into the pipeline at
  `/data/raw`. Layer configs in `pipeline/layers/` name their inputs there.
  Set `RAW_DIR` (in `.env` or the shell) to mount another folder there
  instead, for example data kept outside the repo; compose mounts
  `${RAW_DIR:-./data/raw}` read-only, so the pipeline never writes to it.
- `data/tiles/`: pipeline output, one file per layer (`<layer>.pmtiles`
  for a vector layer, `<layer>.cog.tif` for a raster layer, see Tile
  formats) plus `manifest.json` (which the map reads its layers from) and
  `style.json` (a standalone MapLibre style of the data layers, for other
  tools). The `web` service serves it read-only at `/tiles/`.
- `data/work/`: the pipeline's cache, mounted at `/data/work`. A raster
  layer's source is prepared once (a tiled 0/255 GeoTIFF: 0.14 GB for
  agriculture, 0.69 GB for forest) into `data/work/raster/`, reused by later
  builds until the source file changes; delete the folder to reclaim the
  space. Other intermediates stay in the container and are removed. Also
  fine for manual trials.

These folders are git-ignored apart from `.gitkeep`, and so are raster and
other source formats anywhere in the repo (`*.tif`, `*.tiff`, `*.vrt`,
`*.gdb/`): real data and `.pmtiles` never go in git.

### Tile formats

Each layer is one static file in `data/tiles/`, which nginx serves with
range requests, so the browser fetches only the parts it needs for the
view. There is no tile server.

| Layer type | File | Built with | In the map |
| --- | --- | --- | --- |
| Vector (polygons, points), `LAYER_TYPE=vector` (the default) | `<layer>.pmtiles`: vector tiles in a PMTiles archive | tippecanoe (ADR 0002) | drawn from the tiles; click a feature for its pop-up |
| Raster, `LAYER_TYPE=raster` | `<layer>.cog.tif`: one Cloud Optimized GeoTIFF in Web Mercator, with an overview per zoom | GDAL: prepare, warp, overviews, COG (ADR 0008, 0010) | coloured in the browser; display only, no pop-up |

Raster layers support **binary rasters only**: one band holding 0, 1 and
nodata (any data type, any CRS). The COG holds the share of each pixel
covered by 1 cells (0 to 255), not a colour. Categorical, continuous and
multiband rasters are not supported yet: they would need a raster-kind
setting (mode or nearest resampling for classes, average for continuous
values, one layer per band for multiband) and are left for later.

A full-Canada 30 m raster at z2 to z12 takes about 9 to 10 minutes on a
16-CPU laptop the first time (ADR 0010), and 5 to 8 minutes once its
source is prepared and cached in `data/work/raster/`; the COGs are 0.4 GB
(agriculture) and 2.3 GB (forest). Give Docker Desktop all the CPUs you
can (the steps are multithreaded and the time scales with them), at least
8 GB of memory (a build peaks at about 5 GB) and about 10 GB of free disk
for the container's scratch files.

### Basemap and settings

The basemap is OpenFreeMap's keyless Positron (Light, the default) or Dark
style (ADR 0006). It needs no key or other setup, but the browser must reach
`tiles.openfreemap.org`.

The optional settings (host ports, Linux UIDs, dev server polling, the
source data folder `RAW_DIR`, the map config file `MAP_CONFIG`) can go in
a git-ignored `.env` in the repo root; copy `.env.example` to start.

### Linux file ownership

The pipeline runs as uid 10001 by default. On Linux that means the files it
writes to `data/tiles/` and `data/work/` belong to uid 10001, and the
container needs write access to both folders. Run it as yourself instead by setting, in `.env` or the
shell:

```sh
PIPELINE_UID=$(id -u) PIPELINE_GID=$(id -g) docker compose run --rm pipeline
```

Docker Desktop on Windows and macOS maps bind mount ownership itself, so
nothing is needed there.

### Frontend development

The `web-dev` service (profile `dev`) runs the Vite dev server with hot
reload in the pinned Node image, with `web/` bind-mounted and its Linux
`node_modules` in a named volume, so no Node install is needed on the host.
It serves `data/tiles/` at `/tiles/`.

```sh
docker compose --profile dev up web-dev   # http://localhost:5173
docker compose --profile dev down
```

The first start runs `npm ci` into the volume; later starts skip it until
`package-lock.json` changes. Vite polls for file changes because file events
do not reach the container from Windows bind mounts; on Linux set
`VITE_USE_POLLING=0` to use events instead. The web checks run the same way;
see Checks in `CONTRIBUTING.md`. With Node 26 on the host,
`cd web && npm ci && npm run dev` works too.

## Using the map

Open <http://localhost:8080> once the pipeline has built `data/tiles/`. The
panel at the top left, "Map layers", holds the map controls (click its
heading to collapse it; it starts collapsed on narrow screens):

- **Basemap**: Light or Dark. Switching keeps the data layers and their
  visibility.
- **Layers**: a checkbox per data layer, with its legend underneath, listed
  with the layer drawn on top first. Each starts on or off as its display
  config says. A layer with colour themes has a **Colour by** list above
  its legend, which recolours the layer and its legend at once. If
  `manifest.json` is missing or not valid, the panel says so.

Click a feature of a visible layer to open its pop-up: a title, summary
stats, and any charts. Where features overlap, the layer drawn on top wins
(a sample point over a sample polygon). Missing values show as "Not
available". A layer with a modal opens a dialog instead, with a tab for each
section of values, tables and charts (arrow keys move between tabs); close
it with Escape, its close button or a click outside. Hiding a layer
closes its pop-up or dialog.

## Adding a layer

A layer is two files in `pipeline/layers/`, and nothing in `web/`: the map
reads every layer from `data/tiles/manifest.json` at startup (ADR 0007).
`forest.env` and `forest.style.json` (raster), `protected_areas` (a
single-colour polygon layer), `ecoregions` (colour themes, a click modal,
calculated fields and action rules) and the test layers in
`pipeline/tests/layers/` (`sample.env` and `sample.style.json`) are
worked examples, and
`docs/design/02_data_layers_and_popups.md` is the full data contract.

1. Put the source data in `data/raw/` (or `RAW_DIR`): a shapefile (with
   its sidecar files), a zipped shapefile, a GeoPackage, GeoJSON, or
   anything else GDAL reads; or, for a raster layer, a single-band binary
   GeoTIFF (0, 1 and nodata; see Tile formats).
2. Write `pipeline/layers/<layer>.env`, a bash file (every variable is
   described at the top of `pipeline/lib/config.sh`). The layer name
   (lower case letters, digits, `_` and `-`) names the output files and
   the tile layer.
   - `LAYER_INPUT`: path relative to `data/raw/`. A `.zip` is read in
     place: `boundaries.zip`, or `boundaries.zip/folder/file.shp` for one
     file in it. `LAYER_SOURCE_LAYER` picks a layer in a multi-layer source.
   - `LAYER_SOURCE_SRS` (for example `EPSG:3347`) for an input with no
     usable CRS, such as a shapefile without a `.prj`; `LAYER_ENCODING`
     (for example `ISO-8859-1`) for a shapefile without a `.cpg`.
   - `LAYER_FIELDS`: the attributes to keep, as `src` or `src:dest`. Use
     `src:dest` to restore names cut to 10 characters by shapefile, for
     example `descriptio:description`. Everything else is dropped.
   - `LAYER_FEATURE_ID`: an integer attribute (after renames) used as the
     feature id.
   - `LAYER_MIN_ZOOM`, `LAYER_MAX_ZOOM`: the zoom range of the tiles.
   - `LAYER_PROFILE=coverage` for a contiguous polygon coverage (shared
     borders, no overlaps), so no gaps open along borders when tiles are
     simplified; `LAYER_TIPPECANOE_FLAGS` adds tippecanoe flags after it.
   - `LAYER_MIN_VISIBLE_PX` (default 1): the drop guard threshold. The
     build fails if tippecanoe drops a polygon at a zoom where it would
     cover at least this many pixels.
   - `LAYER_GENERALISE_MAX_ZOOM` (optional) for polygons with many small
     parts, such as islands: up to this zoom, parts under
     `LAYER_GENERALISE_MIN_PART_PX` (default 4) pixels are dropped (each
     feature keeps its largest) and borders are simplified as a coverage
     by `LAYER_GENERALISE_SIMPLIFY_PX` (default 1) pixels; higher zooms
     keep full detail. See design note 02, Low-zoom generalisation.
   - `LAYER_CALCULATED` (optional): calculated fields, as
     `name=expression` on the kept attributes, for example
     `'unprotected_intact_pcnt=round(intact_pcnt - protected_intact_pcnt, 2)'`,
     evaluated at build time and tiled like any attribute; the app never
     calculates. `LAYER_RULES` (optional) names an action rules table,
     `pipeline/layers/<table>.rules.json` (such as `ecoregions.rules.json`):
     each action's condition, for example `protected_pcnt < 30`, becomes
     the attributes `action_<id>` (1 or 0), `action_<id>_reason` and
     `actions_<type>_count`. New rules are a change to the table only. See
     design note 02, Calculated fields and action rules, for the
     expression language, and ADR 0011.

   A raster layer needs only `LAYER_TYPE=raster`, `LAYER_INPUT`, the zooms
   (up to z14; z12 is about 30 m) and, if the GeoTIFF does not declare
   them, `LAYER_SOURCE_SRS` and `LAYER_NODATA`. `forest.env` is an example.
3. Write `pipeline/layers/<layer>.style.json`, starting with
   `"$schema": "../schema/layer-style.schema.json"` for completion and
   checking in an editor: `title`, `defaultVisible`, `order` (draw order),
   either the `symbology` shorthand (single, categorical, stepped or
   gradient colours, with stepped breaks fixed or computed from the data,
   or several colour `themes` to switch between in the map) or raw
   MapLibre style-spec `layers`, an optional `legend` (derived when left
   out), and either an optional `popup` (title, stats, bar or line charts)
   or a `modal` (a dialog of sections with values, tables, charts, text
   and lists, from one template; see
   `pipeline/layers/ecoregions.style.json`); without
   either the layer is not clickable. Number formats can be presets
   (`percent`, `hectares`, `km`, `count`). Design note 02 (Display
   config) has the details. A raster layer uses `"symbology": {"geometry":
   "raster", "color", "opacity", "label"}` (see `forest.style.json`) and
   has no pop-up. Check display configs (and rules tables) without
   building:

   ```sh
   docker compose run --rm --entrypoint sh pipeline -c \
     'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/*.json'
   ```

4. Build it with `docker compose run --rm pipeline <layer>` and reload the
   map. Compose mounts `pipeline/layers/`, so neither image needs a
   rebuild. A layer that fails (bad config, missing input, the drop guard)
   keeps its previous archive and manifest entry, and the run exits 1. A
   raster layer's first build prepares its source once (a Canada-wide
   30 m raster takes about 9 to 10 minutes in all) and caches it in
   `data/work/raster/`; later builds of it skip that step.
5. Check the build report in the layer's `data/tiles/manifest.json` entry.
   A vector layer: `feature_count`, and per zoom in `zooms` the features
   `input`, `present`, `required` by the drop guard and
   `required_present`, and the largest tile in bytes. A raster layer:
   `format` `cog`, the COG's `width` and `height` in pixels at the max
   zoom, `block_size` (256), `overview_count` (one per lower zoom), and
   `zooms`, each zoom's `width` and `height`; `bytes` is the file size.
   With calculated fields or rules, `calculated_fields` (each one's
   expression and value range) and `rules` (how many features each
   action is recommended for) too; `--status` lists them under the layer.

To change how a layer looks, see Styling a layer below: no rebuild.

To see a dataset without adding a layer, run the inspect helper on it
(path relative to `data/raw/`; `--json` for every field's stats, `--help`
for the options):

```sh
docker compose run --rm --entrypoint inspect.sh pipeline my/data.gpkg
```

`--config <layer>` instead of a path shows a configured layer's data as
its build sees it: the kept attributes, its calculated fields with their
expressions and values, and how many features each rule recommends an
action for, so expressions can be checked before a build.

When a layer's source data is replaced, inspect the new file and compare
its fields, CRS and feature count with the layer's `.env`, then rebuild
the layer. A build that fails (a field gone, say) keeps the previous
tiles. `--status` shows the new feature count, and lists the layer as
`stale` until it is rebuilt.

### Removing a layer

Delete its two configs, then its build (its `.pmtiles` or `.cog.tif` and
its `manifest.json` entry; `style.json` is rewritten). The source data in
`data/raw/` is left alone, and so is a raster's cached prepared source in
`data/work/raster/` (delete that folder to reclaim the space).

```sh
git rm pipeline/layers/<layer>.env pipeline/layers/<layer>.style.json
docker compose run --rm pipeline --remove <layer>
```

After pulling a change that removed a layer, `--status` lists your local
build of it as `orphan`; the same `--remove` command clears it.

## Styling a layer

> **Styling never needs a rebuild.** How a layer looks lives in its
> `pipeline/layers/<layer>.style.json`, not in its tiles. Edit the file,
> run `docker compose run --rm pipeline --style-only <layer>`, and reload
> the map: it takes seconds.

What the `.style.json` sets:

- `title` (the layer list and legend), `order` (draw order: higher on
  top) and `defaultVisible` (on or off when the map opens), for every
  layer.
- A vector layer's colours (single, by category, stepped by a number,
  with breaks fixed or computed from the data, or a gradient), colour
  themes to switch between, outline, opacity, legend, and its pop-up
  (title, stats and charts) or modal (sections of values, tables, charts,
  text and lists). See Adding a layer, step 3.
- A raster layer's `color`, `opacity` and legend `label`. The COG holds
  only the share of each pixel covered (0 to 255), and the browser turns
  that into the colour as it draws: none is transparent, full cover is the
  colour at the layer's opacity, and part cover in between at lower zooms.

`--style-only` checks the config as a build does, replaces the `display`
block of the layer's `manifest.json` entry (the build report stays) and
rewrites `style.json`; the tiles or COG are not touched. With no layer
names it updates every built layer. A bad config fails with one line per
problem and changes nothing. `--status` lists a layer whose `.style.json`
changed since as `restyle`. A stepped colour with `breaks` computed from
the data, or a gradient whose range comes from the data, re-reads the
source data (not the tiles), and fails if the source or `.env` changed
since the build. A change that needs a field the tiles
do not have (`LAYER_FIELDS`) or any `.env` change still needs a full
build.

To change the look on your own map only, without touching the committed
file, put a `style` patch for the layer in your `map.config.json` (Your
map config, below) and run the same `--style-only` command.

## Your map config

The layers in `pipeline/layers/` are shared: changing them means a pull
request. To change your own map only, write a map config:
`map.config.json` in the repo root, git-ignored (ADR 0009). Copy
`map.config.example.json` to start; its `$schema` line gives completion
and checking in an editor. With no map config the pipeline builds every
committed layer as it is. `MAP_CONFIG` in `.env` picks another file,
relative to the repo root, so you can keep several and switch.

```json
{
  "$schema": "./pipeline/schema/map-config.schema.json",
  "map": { "center": [-79.4, 44.1], "zoom": 7, "basemap": "dark" },
  "enabled": ["forest", "wetlands"],
  "overrides": {
    "forest": {
      "input": "forest_2025/forest.tif",
      "title": "Forest (2025)",
      "style": { "symbology": { "color": "#00441b", "opacity": 0.5 } }
    }
  },
  "localLayers": {
    "wetlands": {
      "env": { "LAYER_TYPE": "raster", "LAYER_INPUT": "wetlands.tif",
               "LAYER_MIN_ZOOM": 2, "LAYER_MAX_ZOOM": 12 },
      "style": { "title": "Wetlands", "defaultVisible": true,
                 "symbology": { "geometry": "raster", "color": "#2c7fb8",
                                "opacity": 0.7 } }
    }
  }
}
```

- `enabled` lists the layers to build and show (default: all of them);
  `disabled` leaves some out. A layer you built before and then leave out
  stays on disk but is hidden from the map.
- `overrides` change a layer by name. `input` (the source data, relative
  to `RAW_DIR`) and `env` (any other `.env` setting, such as
  `LAYER_MAX_ZOOM` or `LAYER_FIELDS`) change the tiles: rebuild the
  layer. So do `calculated` (calculated fields to add or change by name,
  `null` to remove one, on top of the layer's `LAYER_CALCULATED`) and
  `rules` (another action rules table, relative to this file, or `null`
  for none; ADR 0011). `title`, `order`, `defaultVisible` and `style`
  change only how it looks. `style` is merged over the layer's `.style.json`: objects key by
  key, anything else (lists too) replaced, and `null` removes a key.
- `localLayers` are layers only you have, written inline in the same
  shape as a `.env` (`env`) and `.style.json` (`style`). Or keep them as
  files in a folder such as `pipeline/layers.local/` (git-ignored) and
  list it in `layerDirs`, relative to the config file. A local layer
  needs its own name.
- `map` sets where the map opens (`center` as `[longitude, latitude]`,
  `zoom`) and on which basemap. A view in the page URL wins.

Apply a change with the commands you already use:

```sh
docker compose run --rm pipeline --status       # what needs what
docker compose run --rm pipeline --style-only   # display, selection, map view
docker compose run --rm pipeline                # input or env changes, new layers
```

The pipeline checks the whole config before it builds anything and stops
with one line per problem (an unknown layer name, a missing folder, a
style that is no longer valid). `--status` shows `stale` for a layer
whose input or settings changed, `restyle` for a display change,
`disabled` for one you left out, and `source missing` for one whose data
you do not have: a full build skips those with a warning, and fails only
if it could build nothing. Each layer's `manifest.json` entry records
its source file (size and date) and the overrides applied under
`provenance`, so two maps can be compared.

## Using Claude Code (optional)

Everything in this README works with the plain commands above; Claude
Code is never required. For those who use it, the repo has project
skills: short step-by-step procedures in `.claude/skills/<name>/SKILL.md`
that Claude Code follows when a request matches, or when you type
`/<name>`. They call only the documented commands below, so the logic
lives in the pipeline and scripts, not in the skills.
`.claude/settings.json` lets read-only and build commands run without a
prompt; removing a layer always asks first.

| Task | Plain command | Ask Claude Code |
| --- | --- | --- |
| Set up or check this machine | `scripts/setup.sh --init` (or `--check`) | "Set up the map on this machine" (`/setup`) |
| See what is built or stale | `docker compose run --rm pipeline --status` | "Which layers are out of date?" (`/layer-status`) |
| Look at a dataset | `docker compose run --rm --entrypoint inspect.sh pipeline <path>` | "What is in data/raw/parcels.gpkg?" (`/inspect-data`) |
| Add a layer | Adding a layer, above | "Add data/raw/parcels.gpkg as a layer", "Add wetlands.tif as a raster layer" (`/add-layer`) |
| Restyle a layer (colours, themes, legend) | Styling a layer, above | "Colour parcels by habitat type", "Make forest dark green" (`/restyle-layer`) |
| Change what a pop-up or modal shows | Styling a layer, above (`popup` or `modal` in the `.style.json`, then `--style-only`; a field not in the tiles needs `LAYER_FIELDS` and a rebuild) | "Add a threats table to the ecoregion modal", "Show area in hectares in the parcels pop-up" (`/edit-popup`) |
| Build layers, explain failures | `docker compose run --rm pipeline [layer ...]` | "Rebuild the stale layers" (`/build-layers`) |
| Refresh a layer's source data | Adding a layer, above (inspect, compare, build) | "The parcels data was updated, refresh it" (`/update-layer-data`) |
| Remove a layer | Removing a layer, above | "Remove the parcels layer" (`/remove-layer`) |
| Run, stop or screenshot the map | Usage, above; `scripts/screenshot.sh --help` | "Start the map", "Screenshot parcels" (`/run-map`) |
| Change your own map only | Your map config, above | "Hide agriculture on my map", "Use my copy of the forest data" (`/restyle-layer`, `/build-layers`) |
| Run the CI checks locally | `CONTRIBUTING.md` (Checks) | "Run the checks" (`/run-checks`) |

Skills that change files (add, restyle, edit pop-up, update, remove) work on a branch
and open a draft pull request with the configs only; data never goes in
git. Adding or changing a skill is described in `CONTRIBUTING.md`.

## Maintainers

Repo automation (auto-merge, branch updates, cache warming) and its
one-time setup are in `CONTRIBUTING.md` (Repo automation).

## License

GNU General Public License v3.0. Replace with your own choice if different.
