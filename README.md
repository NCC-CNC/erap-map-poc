# ERAP Map PoC

A proof of concept that turns spatial data into vector tiles (PMTiles) and
binary rasters into Cloud Optimized GeoTIFFs (COGs), and shows them in a
web map where clicking a feature opens a pop-up with summary stats and
charts.

![The web map on the Light basemap with the ERAP ecoregions coloured by
percent protected and the protected areas, the layer panel with
its "Colour by" choice and legends on the left, and the dialog of the
Mid-Boreal Lowland ecoregion open on its Habitat tab, with a habitat
table and a grouped bar chart](docs/images/map-modal.png)

- **Pipeline** (`pipeline/`): bash with GDAL, tippecanoe and the
  `pmtiles` CLI. It reads one YAML file per layer and writes a
  `.pmtiles` or `.cog.tif` per layer and a MapLibre `style.json` into
  `data/tiles/`.
- **Web map** (`web/`): React and MapLibre GL JS. It reads `style.json`,
  draws the layers over an OpenFreeMap basemap and opens pop-ups and
  dialogs with Chart.js charts.

Both run in Docker, tied together by `docker-compose.yml`. Only Docker is
needed on your machine. [How it works](docs/how-it-works.md) has the
whole picture.

Status: the four ERAP layers (`ecoregions`, `protected_areas`, `forest`
and `agriculture`) are configured. The code on `dev` has been refactored
to one file per layer and a standard `style.json` (ADR 0015); a full
build from the real data on that code is still to do before it merges
into `main`.

## Getting started

On Windows 11 you need **Git for Windows** (for Git Bash; use it for every
command here) and **Docker Desktop** with the WSL 2 engine. Keep the
source data outside the repo, in a folder such as
`C:/data/ERAP_play_data`. Then, in Git Bash:

```sh
git clone https://github.com/NCC-CNC/erap-map-poc.git
cd erap-map-poc
scripts/setup.sh --init
```

`--init` checks the machine, asks for the data folder and ports, writes
`.env`, builds the images and every layer whose data it finds, and starts
the map at <http://localhost:8080>. Each problem comes with a one-line
fix. The first run takes about 5 minutes plus the layers (about 10
minutes per raster layer); it is safe to stop and rerun.
`scripts/setup.sh` alone only checks.

On Linux or macOS, or by hand: copy `.env.example` to `.env`, set
`RAW_DIR` to your data folder, then build and run as below.

## Everyday commands

```sh
docker compose run --rm pipeline                    # build every layer into data/tiles/
docker compose run --rm pipeline forest             # build one layer
docker compose run --rm pipeline --status           # what is built, stale or invalid
docker compose run --rm pipeline --style-only       # apply display changes, no re-tiling
docker compose up -d --build web                    # the map at http://localhost:8080
docker compose down                                 # stop it
```

A rebuilt layer shows on a page reload. After pulling changes to
`pipeline/` or `web/`, add `--build` to rebuild the image (the first
pipeline image takes about 4 minutes; it compiles tippecanoe).

Without any data, build the synthetic test layers:

```sh
MSYS_NO_PATHCONV=1 docker compose run --rm -e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline
```

Every task (add a layer, change its look or pop-up, update its data,
remove it, your own layers, screenshots, the GitHub Pages copy) is in
the [guide](docs/guide.md).

## Layers

A layer is one file, `pipeline/layers/<layer>.yaml`:

```yaml
title: Protected areas (CPCAD)
visible: true
order: 30
source:
  path: protected_areas.gdb          # under RAW_DIR
  layer: cpcad_ncc_dslv_2025
  id: OBJECTID
processing:
  profile: default                   # or coverage, points, raster
  maxzoom: 12
display:
  layers:                            # MapLibre style layers
    - id: fill
      type: fill
      paint: { fill-color: "#c51b7d", fill-opacity: 0.6 }
```

`fields` picks and calculates attributes, `display.themes` adds "Colour
by" choices and `display.popup` a pop-up or dialog. Every key is in the
[layer file reference](docs/layer-file.md). Nothing about a layer is in
`web/`.

Changes just for you go in git-ignored files: `map.config.yaml` (copy
`map.config.example.yaml`) picks the layers, overrides a source or zoom,
and sets the view, title and number locale; `pipeline/layers.local/`
holds your own layers.

## Data

- `RAW_DIR` (default `data/raw/`): source data, mounted read-only.
  Anything GDAL opens, or a single-band binary GeoTIFF (0, 1 and nodata)
  for a raster layer. Categorical, continuous and multiband rasters are
  not supported yet.
- `data/tiles/`: the pipeline's output, served by nginx with range
  requests. No tile server.
- `data/work/`: the prepared raster sources, cached between builds
  (delete it to reclaim the space).
- `data/pages/`: the GitHub Pages copy.

Real data, `.pmtiles`, `.cog.tif` and screenshots never go in git. On
Linux, set `PIPELINE_UID` and `PIPELINE_GID` in `.env` to your own (`id
-u`, `id -g`) so the files the pipeline writes are yours. Settings are
listed in `.env.example`.

The basemap is OpenFreeMap's keyless Light or Dark style (ADR 0006); the
browser must reach `tiles.openfreemap.org`.

## Using Claude Code (optional)

Everything above works with plain commands; Claude Code is never
needed. If you use it, the project skills in `.claude/skills/` run the
same commands as the guide:

| Task | Guide section | Skill |
| --- | --- | --- |
| Set up or check this machine | [Set up](docs/guide.md#set-up) | `/setup` |
| Run, stop or screenshot the map | [Run the map](docs/guide.md#run-the-map) | `/run-map` |
| Look at a dataset | [Look at a dataset](docs/guide.md#look-at-a-dataset) | `/inspect-data` |
| Add a layer | [Add a layer](docs/guide.md#add-a-layer) | `/add-layer` |
| Build layers, status, failures | [Build layers](docs/guide.md#build-layers-and-check-their-status) | `/build-layers` |
| Change a layer's look or pop-up | [Change how a layer looks](docs/guide.md#change-how-a-layer-looks) | `/edit-layer` |
| Refresh a layer's data | [Update a layer's data](docs/guide.md#update-a-layers-data) | `/update-layer-data` |
| Remove a layer | [Remove a layer](docs/guide.md#remove-a-layer) | `/remove-layer` |
| Run the CI checks | `CONTRIBUTING.md` (Checks) | `/run-checks` |

Skills that change a layer ask whether the change is for you only (your
map config or `layers.local/`) or for everyone (a pull request with the
layer file only).

## More

- [How it works](docs/how-it-works.md), the [guide](docs/guide.md) and
  the [layer file reference](docs/layer-file.md).
- `pipeline/README.md`, `scripts/README.md` and `web/README.md` for the
  code.
- `CONTRIBUTING.md`: development setup, checks and pull requests.
- `docs/design/`: the brief, milestones and the refactor plan;
  `docs/decisions/`: the ADRs.

## License

GNU General Public License v3.0.
