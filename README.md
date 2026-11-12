# ERAP Map PoC

A proof of concept for processing spatial data into vector tiles and viewing
them in an interactive web map.

![The web map with the two synthetic layers on the Light basemap, the layer
panel with legends on the left, and the pop-up of a clicked polygon showing
its stats and a bar chart](docs/images/map-popup.png)

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
takes about 5 minutes plus the layers (a raster layer takes tens of
minutes); it is safe to stop and rerun. `scripts/setup.sh` on its own
only checks, changing nothing, and `--help` lists the options, such as
`--raw-dir`, `--yes` and `--skip-layers`.

### With Claude Code (optional)

Claude Code is never needed, but if you have it, ask it to "clone
NCC-CNC/erap-map-poc and set it up". Once the repo is cloned, its
`setup` skill runs the same script, explains each problem in plain
language, helps write `.env` and opens the map.

## Project map

- `pipeline/`: the tile builder image. `bin/run.sh` is the entry point,
  `lib/` the build steps (normalise, display config, tiles, drop guard,
  manifest), `layers/` one `<layer>.env` and `<layer>.style.json` per layer,
  `schema/` the JSON Schema for display configs, `style/` the Node tool that
  checks them, and `tests/` the bats tests and synthetic fixtures.
- `web/`: the map app (`src/map/` the map, layer panel and pop-up wiring,
  `src/layers/` the manifest reader, `src/popup/` pop-up content and charts)
  and the nginx image that serves it along with `data/tiles/`.
- `data/`: `raw/` for source data, `tiles/` for pipeline output. Neither is
  committed.
- `docs/`: design notes (`design/`), ADRs (`decisions/`), session handoffs
  (`handoffs/`) and images.
- `.github/`: CI (`ci.yml`), auto-merge, branch update and cache warming
  workflows, Dependabot config, issue forms and the PR template.
- `scripts/`: `setup.sh` (first-time setup and machine check, Getting
  started), `screenshot.sh` (map screenshots) and
  `bootstrap-repo-settings.sh` (one-time repo settings: branch
  protection, auto-merge, labels).

## Usage

Requires Docker with Docker Compose v2. Nothing else (no Node, GDAL or
tippecanoe) is needed on the host. Compose builds two local images,
`natureconservancy/erap-map-pipeline` and `natureconservancy/erap-map-web`;
they are not pushed anywhere.

```sh
# Build tiles into data/tiles/: every layer in pipeline/layers/, or only
# the ones named. The layers (`forest`, `agriculture`) read their source
# from RAW_DIR, here the folder holding the November 2026 play data (see
# .env.example).
RAW_DIR=C:/data/ERAP_play_data docker compose run --rm --build pipeline forest
RAW_DIR=C:/data/ERAP_play_data docker compose run --rm pipeline   # every layer

# Demo tiles without any data: the synthetic test layers `sample` and
# `sample_points` (pipeline/tests/layers/, baked into the image) are not
# built by default; point the layers dir at them. Remove them again with
# `--remove sample` and `--remove sample_points`.
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
- `data/tiles/`: pipeline output, one `.pmtiles` per layer plus
  `manifest.json` (which the map reads its layers from) and `style.json` (a
  standalone MapLibre style of the data layers, for other tools). The `web`
  service serves it read-only at `/tiles/`.
- `data/work/`: scratch space for manual trials. The pipeline keeps its own
  intermediates in the container and removes them.

These folders are git-ignored apart from `.gitkeep`, and so are raster and
other source formats anywhere in the repo (`*.tif`, `*.tiff`, `*.vrt`,
`*.gdb/`): real data and `.pmtiles` never go in git.

Layers are vector (polygons, points) or binary rasters (`LAYER_TYPE=raster`,
display only, ADR 0008). A raster layer's colour and opacity are applied by
the map, not stored in its tiles, so changing them is a `--style-only`
update with no re-tiling. A full-Canada raster takes tens of minutes and a
few GB to build.

### Basemap and settings

The basemap is OpenFreeMap's keyless Positron (Light, the default) or Dark
style (ADR 0006). It needs no key or other setup, but the browser must reach
`tiles.openfreemap.org`.

The optional settings (host ports, Linux UIDs, dev server polling, the
source data folder `RAW_DIR`) can go in
a git-ignored `.env` in the repo root; copy `.env.example` to start.

### Linux file ownership

The pipeline runs as uid 10001 by default. On Linux that means the files it
writes to `data/tiles/` belong to uid 10001, and the container needs write
access to the folder. Run it as yourself instead by setting, in `.env` or the
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
  config says. If `manifest.json` is missing or not valid, the panel says
  so.

Click a feature of a visible layer to open its pop-up: a title, summary
stats, and any charts. Where features overlap, the layer drawn on top wins
(a sample point over a sample polygon). Missing values show as "Not
available". Hiding a layer closes its pop-up.

## Adding a layer

A layer is two files in `pipeline/layers/`, and nothing in `web/`: the map
reads every layer from `data/tiles/manifest.json` at startup (ADR 0007).
`forest.env` and `forest.style.json` (raster) and the test layers in
`pipeline/tests/layers/` (`sample.env` and `sample.style.json`, vector) are
worked examples, and
`docs/design/02_data_layers_and_popups.md` is the full data contract.

1. Put the source data in `data/raw/`: a shapefile (with its sidecar
   files), a zipped shapefile, a GeoPackage, GeoJSON, or anything else
   GDAL reads.
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
3. Write `pipeline/layers/<layer>.style.json`, starting with
   `"$schema": "../schema/layer-style.schema.json"` for completion and
   checking in an editor: `title`, `defaultVisible`, `order` (draw order),
   either the `symbology` shorthand (single, categorical or stepped colours,
   with stepped breaks fixed or computed from the data) or raw MapLibre
   style-spec `layers`, an optional `legend` (derived when left out), and
   an optional `popup` (title, stats, bar or line charts; without one the
   layer is not clickable). Check display configs without building:

   ```sh
   docker compose run --rm --entrypoint sh pipeline -c \
     'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/*.style.json'
   ```

4. Build it with `docker compose run --rm pipeline <layer>` and reload the
   map. Compose mounts `pipeline/layers/`, so neither image needs a
   rebuild. A layer that fails (bad config, missing input, the drop guard)
   keeps its previous archive and manifest entry, and the run exits 1.
5. Check the build report in the layer's `data/tiles/manifest.json` entry:
   `feature_count`, and per zoom in `zooms` the features `input`,
   `present`, `required` by the drop guard and `required_present`, and the
   largest tile in bytes.

Restyling a layer needs no rebuild: edit its `.style.json`, then

```sh
docker compose run --rm pipeline --style-only <layer>
```

and reload the map. This checks the config as a build does, replaces the
`display` block of the layer's `manifest.json` entry (the build report
stays as it was) and rewrites `style.json`; the tiles are not touched. A
bad config fails with one line per problem and changes nothing. It works
for vector and raster layers; a stepped colour with `breaks` computed from
the data re-reads the source data (not the tiles), and fails if the
source or `.env` changed since the build. A change that needs a field the
tiles do not have (`LAYER_FIELDS`) or any `.env` change still needs a
full build.

To see a dataset without adding a layer, run the inspect helper on it
(path relative to `data/raw/`; `--json` for every field's stats, `--help`
for the options):

```sh
docker compose run --rm --entrypoint inspect.sh pipeline my/data.gpkg
```

When a layer's source data is replaced, inspect the new file and compare
its fields, CRS and feature count with the layer's `.env`, then rebuild
the layer. A build that fails (a field gone, say) keeps the previous
tiles. `--status` shows the new feature count, and lists the layer as
`stale` until it is rebuilt.

### Removing a layer

Delete its two configs, then its build (archive and `manifest.json`
entry; `style.json` is rewritten). The source data in `data/raw/` is left
alone.

```sh
git rm pipeline/layers/<layer>.env pipeline/layers/<layer>.style.json
docker compose run --rm pipeline --remove <layer>
```

After pulling a change that removed a layer, `--status` lists your local
build of it as `orphan`; the same `--remove` command clears it.

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
| Add a layer | Adding a layer, above | "Add data/raw/parcels.gpkg as a layer" (`/add-layer`) |
| Restyle a layer or its pop-up | Edit `<layer>.style.json`, then `docker compose run --rm pipeline --style-only <layer>` | "Colour parcels by habitat type" (`/restyle-layer`) |
| Build layers, explain failures | `docker compose run --rm pipeline [layer ...]` | "Rebuild the stale layers" (`/build-layers`) |
| Refresh a layer's source data | Adding a layer, above (inspect, compare, build) | "The parcels data was updated, refresh it" (`/update-layer-data`) |
| Remove a layer | Removing a layer, above | "Remove the parcels layer" (`/remove-layer`) |
| Run, stop or screenshot the map | Usage, above; `scripts/screenshot.sh --help` | "Start the map", "Screenshot parcels" (`/run-map`) |
| Run the CI checks locally | `CONTRIBUTING.md` (Checks) | "Run the checks" (`/run-checks`) |

Skills that change files (add, restyle, update, remove) work on a branch
and open a draft pull request with the configs only; data never goes in
git. Adding or changing a skill is described in `CONTRIBUTING.md`.

## Maintainers

Repo automation (auto-merge, branch updates, cache warming) and its
one-time setup are in `CONTRIBUTING.md` (Repo automation).

## License

GNU General Public License v3.0. Replace with your own choice if different.
