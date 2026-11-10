# 00 Project Brief

## What this is

ERAP Map PoC is a proof of concept for turning input spatial data into fast,
interactive web map layers. It has two parts: a repeatable data pipeline that
processes source data into vector tiles (PMTiles), and a web map that displays
those tiles and shows summary statistics and plots when a user clicks a
feature.

It is a proof of concept, not a production service. The goal is to show that
the pipeline and map pattern works end to end for ERAP data, so a decision can
be made about building it out further.

## Who it is for

- Now: internal use by the project team evaluating the approach.
- Later, if the PoC continues: conservation planning staff more widely, using
  the map to explore the data.

Assumptions: map users are comfortable with web maps but not necessarily GIS
specialists, so pop-ups should be readable without knowing the underlying
attribute names. Whoever runs the pipeline and the app locally has Docker and
Docker Compose installed and is comfortable with a terminal. No other local
toolchain (GDAL, Node, tippecanoe) should be needed.

## The core idea (one screen)

1. A person drops source spatial data into `data/raw/` and runs the pipeline
   on demand (`docker compose run --rm pipeline`).
2. The pipeline, a set of bash scripts in its own container, cleans and
   reprojects the data with GDAL/OGR, computes any per-feature summary stats
   the pop-ups need, and builds one `.pmtiles` file per layer with tippecanoe.
3. The web map container serves the React app and the `.pmtiles` files. The
   app reads the tiles directly over HTTP range requests, so there is no tile
   server.
4. The user opens the map in a browser, toggles layers, and clicks a feature.
   A pop-up shows that feature's summary stats and one or more charts (Chart.js).

## MVP scope

The smallest version that proves the core idea:

1. A pipeline container (GDAL, tippecanoe, pmtiles CLI) with an entry script
   that turns at least one sample input layer into a `.pmtiles` file, driven
   by a per-layer config rather than hard-coded paths.
2. A web map container (React, Vite, MapLibre GL JS, pmtiles protocol) that
   displays that layer over an OpenFreeMap basemap (Positron, with Dark as
   an option) with basic styling.
3. Click a feature to open a pop-up with summary stats and at least one
   Chart.js chart, using data produced by the pipeline.
4. A `docker-compose.yml` that runs the web map locally and runs the pipeline
   on demand, sharing the tile output through a mounted folder.
5. CI that lints the shell scripts and Dockerfiles, checks and builds the web
   app, and builds both images.

See `docs/design/03_milestones.md` for the phased plan.

## Explicit non-goals (for now)

- Production hosting, authentication, or multi-user concerns. The PoC runs
  locally; a deployment target is an open question.
- A tile server or database (PostGIS, Martin, TileServer GL). PMTiles over
  static HTTP is the point of the design.
- Editing data in the browser. The map is read-only.
- Scheduled or automatic pipeline runs. The pipeline runs on demand.
- Raster processing, unless the TBC data requires it.

## Design principles

1. Reproducible by default: every tool runs inside a pinned container image,
   so a run on one laptop matches a run on another and in CI.
2. Config over code: adding or changing a layer should mean editing a layer
   config (and style), not rewriting pipeline scripts or React components.
3. Static over services: precompute in the pipeline whatever the browser
   needs, and serve files. Fewer moving parts suits a PoC.
4. Keep the data contract explicit: the attributes and sidecar files the
   pipeline produces are the interface the web app reads. Document them in
   `docs/design/02_data_layers_and_popups.md` and change both sides together.

## Open questions

- Which source datasets, formats, and sizes? (Drives pipeline steps and
  tippecanoe settings.)
- Styling for each layer.
- What each pop-up shows: which stats, which plots, and whether stats are
  precomputed per feature or aggregated across features.
- Does the plot data fit in tile attributes, or does it need sidecar JSON
  files keyed by feature id? See `02_data_layers_and_popups.md`.
- Is `mb-util` needed? Tippecanoe writes `.pmtiles` directly and the
  `pmtiles` CLI converts `.mbtiles`, so `mb-util` only earns a place if a
  tile directory step is needed.
- Deployment target beyond local, if any (static host, cloud bucket plus CDN,
  internal server).

## Data handling

- Real source data and generated `.pmtiles` are never committed. They live in
  the git-ignored `data/raw/` and `data/tiles/` folders.
- CI uses a small synthetic test case generated for the purpose (a handful of
  made-up features with the attributes the pipeline and pop-ups expect),
  committed under `pipeline/tests/fixtures/`. It must contain no real data.
