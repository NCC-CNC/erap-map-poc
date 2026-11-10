# CLAUDE.md

Working rules and durable context for this project. This file is loaded into
context automatically, so keep it to direction and rules, not a task list.

## Project name

ERAP Map PoC

## Project purpose

A proof of concept that turns input spatial data into vector tiles (PMTiles)
with a bash pipeline, and displays them in a web map where clicking a feature
opens a pop-up with summary stats and plots. The aim is to prove the pattern
end to end so a decision can be made on building it out. Internal use for
now; conservation planning staff more widely if it continues. See
`docs/design/00_project_brief.md` for the full brief.

## Project status

Design / pre-build. The next milestone is M1, a skeleton that takes one sample
layer from raw file to clickable feature. Source data, styling, and pop-up
content are TBC. Open GitHub issues are the live task tracker;
`docs/design/03_milestones.md` is the shape of the plan.

## Scope

In scope: an on-demand pipeline that builds `.pmtiles` per layer, a read-only
web map with pop-ups (stats and Chart.js charts), and a docker-compose setup to
run both locally.

Not in scope: production hosting, authentication, a tile server or database,
in-browser editing, scheduled pipeline runs. Do not expand scope without a
design note in `docs/design/` or an ADR in `docs/decisions/`.

## Stack

- Pipeline (`pipeline/`): bash, GDAL/OGR, tippecanoe, `pmtiles` CLI, in a
  custom image on a pinned `ghcr.io/osgeo/gdal` base. shellcheck and bats.
  See ADR 0002.
- Web app (`web/`): React, TypeScript, Vite, MapLibre GL JS, `pmtiles`,
  Chart.js, CARTO basemaps (ADR 0005); served by nginx. ESLint, `tsc`,
  vitest. See ADR 0003.
- Runtime: one Dockerfile per component and a root `docker-compose.yml`; the
  pipeline writes `data/tiles/`, nginx serves it as static files with range
  requests. See ADR 0004.
- Hard constraints: pin every tool and base image version; the web app reads
  only `data/tiles/` and the data contract in
  `docs/design/02_data_layers_and_popups.md`, never `data/raw/`; secrets such
  as `CARTO_API_KEY` come from `.env` at runtime, never committed or baked
  into images; pipeline writes are atomic (temp file then move).

## Commands

Planned for M1, not yet working. Fill in real commands, gates, and timings
once they exist, and keep `CONTRIBUTING.md` Setup in step.

- Run the web map: `docker compose up web` (then <http://localhost:8080>).
- Run the pipeline: `docker compose run --rm pipeline [layer ...]`.
- Web checks (gates): `npm run lint`, `npm run typecheck`, `npm test`,
  `npm run build` in `web/`.
- Pipeline checks (gates): shellcheck and bats.

## Repo structure

Planned layout is in `docs/design/01_architecture.md`. In short: `pipeline/`
and `web/` are independent components; `data/raw/` and `data/tiles/` are not
committed; real data and `.pmtiles` never go in git. CI uses a synthetic
test case in `pipeline/tests/fixtures/`. `web/` never reads `data/raw/`.

## Working rules

- Branch from `main`; one short-lived branch per change. Open a pull request
  into `main`; CI must pass before merge.
- Conventional Commits (for example `feat: ...`, `fix: ...`, `chore: ...`,
  `docs: ...`).
- No em dashes in code, comments, docs, commit messages, or user-facing text.
- Significant technical or design decisions get an ADR in `docs/decisions/`.
- Design notes live in `docs/design/`; session handoffs in `docs/handoffs/`.
- Keep changes small and focused; update docs when behaviour or design changes.
