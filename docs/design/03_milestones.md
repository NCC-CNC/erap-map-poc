# 03 Milestones

The shape of the plan. Open GitHub issues are the live task tracker; each
milestone below should become a GitHub milestone with issues under it.

## M0: Project setup (this PR and follow-ups)

- Fill in the brief, CLAUDE.md, architecture note, and the stack ADRs.
- Run `scripts/bootstrap-repo-settings.sh` once (branch protection,
  auto-merge, labels). Needs a GitHub admin on `NCC-CNC/erap-map-poc`.
- Decide on solo-maintainer auto-merge (see Repo automation in CONTRIBUTING.md).

## M1: Skeleton end to end

Goal: a placeholder layer goes from raw file to clickable feature on the map.

- `pipeline/`: Dockerfile with pinned GDAL, tippecanoe, pmtiles CLI;
  `bin/run.sh` with one layer config and a small synthetic test case
  (no real data) committed under `pipeline/tests/fixtures/`.
- `web/`: React + Vite + TypeScript app with MapLibre, the pmtiles protocol,
  the OpenFreeMap basemaps (Positron default, Dark toggle, no key; ADR
  0006), and the sample layer; multi-stage Dockerfile and nginx
  config.
- `docker-compose.yml` with `web` and `pipeline` (profile) services and the
  shared `data/` mounts; decide the frontend dev workflow.
- A basic pop-up showing raw attributes.
- CI: add stack jobs to `ci.yml` (shellcheck, hadolint, bats, web lint,
  typecheck, test, build, and `docker build` of both images); Dependabot
  entries for npm (`/web`) and Docker (`/pipeline`, `/web`).
- Fill in `CONTRIBUTING.md` Setup and the Commands section of `CLAUDE.md`.

## M2: Real data in

Blocked on: confirmed source datasets.

- Add the confirmed layers to `02_data_layers_and_popups.md` and as pipeline
  layer configs.
- Tune tippecanoe settings per layer (zooms, simplification, dropping).
- Write `manifest.json` and have the web app build its layer list from it.

## M3: Styling and pop-ups

Blocked on: confirmed styling and pop-up content.

- Per-layer styles and a legend / layer toggle. The mechanism is in place
  (#33): a layer panel with the basemap radio group and one checkbox per
  layer, topmost first, with an inline legend generated from the same
  `symbology` as the MapLibre paint; visibility survives a basemap switch.
  The two sample layers use it. Real layers still need their confirmed
  styling.
- Pop-ups with summary stats and Chart.js charts.
- Sidecar JSON for plot data where needed.

## M4: PoC review

- Short demo and write-up of what worked, limits found, and the
  recommendation (build out, change approach, or stop).
- Decide the deployment target if the PoC continues.
