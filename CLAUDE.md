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

M1 (skeleton end to end) is nearly done: the pipeline, web app, CARTO
basemaps, feature pop-ups, docker-compose and CI are merged, and the
synthetic `sample` layer goes from raw file to clickable feature (the MapLibre
worker fix, #26, is merged; a hands-on browser check is pending). Next is M2, real
data, blocked on confirmed source datasets (#13); styling and pop-up content
are still TBC. Open GitHub issues are the live task tracker;
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

Only Docker with Compose is needed on the host. On Windows use Git Bash (the
`bash` in PowerShell may be WSL without `gh`); there, `docker run` with
container paths needs `MSYS_NO_PATHCONV=1` and host paths from `pwd -W` or
`cygpath -w`. `CONTRIBUTING.md` (Setup, Checks) has the full copy-paste
block; keep it in step with this section.

- Pipeline: `docker compose run --rm pipeline [layer ...]` (no names builds
  every layer into `data/tiles/`).
- Web map: `docker compose up -d --build web` (<http://localhost:8080>,
  `WEB_PORT`). Dev server: `docker compose --profile dev up web-dev` (Vite
  on :5173, `VITE_USE_POLLING`). `CARTO_API_KEY` comes from `.env`.

Gates: every CI job below feeds the one required status `checks`; a PR that
touches only `docs/` and `*.md` runs just `repo-hygiene`.

- `pipeline`: shellcheck 0.11.0 and hadolint 2.15.1 (file list in
  `ci.yml`), then `docker build --target test pipeline` and run it (bats),
  then the `runtime` image. Locally the first build takes about 4 minutes
  (tippecanoe compile), then seconds from cache. CI: about 4 min cold, under
  1 min warm.
- `web` (Node 26.13.0, in `web/`): `npm ci`, `npm run lint`,
  `npm run typecheck`, `npm test`, `npm run build`,
  `npm audit --omit=dev --audit-level=high`, hadolint, then the image and a
  smoke test. Locally without Node:
  `docker compose --profile dev run --rm --no-deps web-dev sh -c 'npm ci && npm run lint && npm run typecheck && npm test && npm run build'`
  (about 15 s). CI: about 2.5 min cold, under 1 min warm.
- `compose`: `docker compose config -q`, and again with
  `--profile pipeline --profile dev`.
- `repo-hygiene`: actionlint, markdownlint (`.markdownlint.json`), no em
  dashes. Run markdownlint locally in the Node image with
  `npx --yes markdownlint-cli '**/*.md' --ignore node_modules --ignore LICENSE`.

Ready PRs from branches in this repo merge themselves when `checks` passes
(auto-merge via the NCC ConsTech Automation app), so open a draft until the
change is ready.

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
