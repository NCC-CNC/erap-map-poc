# ERAP Map PoC

A proof of concept for processing spatial data into vector tiles and viewing
them in an interactive web map.

- **Pipeline** (`pipeline/`): bash scripts using GDAL, tippecanoe, and the
  `pmtiles` CLI turn source data in `data/raw/` into one `.pmtiles` file per
  layer in `data/tiles/`, plus any summary stats the pop-ups need.
- **Web map** (`web/`): a React + MapLibre GL JS app that loads those layers
  straight from the `.pmtiles` files and opens pop-ups with summary stats and
  Chart.js charts when a feature is clicked.

Both run in their own Docker containers, tied together by
`docker-compose.yml`.

Status: M1 skeleton. A synthetic sample layer runs from raw file to clickable
feature; the source data, styling, and pop-up content are still to be
confirmed. Setup and checks are in `CONTRIBUTING.md`. See `docs/design/` for the brief, architecture, and
milestones, and `docs/decisions/` for the ADRs.

## Usage

Requires Docker with Docker Compose v2. Nothing else (no Node, GDAL or
tippecanoe) is needed on the host. Compose builds two local images,
`natureconservancy/erap-map-pipeline` and `natureconservancy/erap-map-web`;
they are not pushed anywhere.

```sh
# Build tiles into data/tiles/: every layer, or only the ones named.
# The synthetic `sample` layer is baked into the image, so this works with
# an empty data/raw/.
docker compose run --rm pipeline
docker compose run --rm pipeline sample

# Run the web map at http://localhost:8080 (WEB_PORT changes the port).
docker compose up -d web
docker compose logs -f web
docker compose down
```

Rebuild the images after changing `pipeline/` or `web/` with
`docker compose build` (or `docker compose up -d --build web`). A rebuilt
layer needs no restart: nginx serves `data/tiles/` straight from the host
folder, so reload the page.

### Where data goes

- `data/raw/`: source data, mounted read-only into the pipeline at
  `/data/raw`. Layer configs in `pipeline/layers/` name their inputs there.
- `data/tiles/`: pipeline output, one `.pmtiles` per layer plus
  `manifest.json`. The `web` service serves it read-only at `/tiles/`.

Both folders are git-ignored apart from `.gitkeep`.

### Basemap and settings

The basemap is OpenFreeMap's keyless Positron (light, the default) or Dark
style, switchable in the map (ADR 0006). It needs no key or other setup, but
the browser must reach `tiles.openfreemap.org`.

The optional settings (host ports, Linux UIDs, dev server polling) can go in
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
`VITE_USE_POLLING=0` to use events instead. Once the volume is populated, the
web checks run the same way:
`docker compose --profile dev run --rm --no-deps web-dev npm test` (or
`npm run lint`, `npm run typecheck`). With Node 26 on the host,
`cd web && npm ci && npm run dev` works too.

## Auto-merge and branch updates

Two workflows in `.github/workflows/` make green PRs merge themselves. Both
act through the NCC ConsTech Automation GitHub App, owned by the `NCC-CNC`
org, so there is no personal access token to create or rotate.

- `auto-merge.yml` arms squash auto-merge on every PR into `main` opened from
  a branch in this repo (pushing one needs write access, so this covers the
  owner and maintainers) and brings the PR level with `main`. PRs from forks
  and from Dependabot are never armed and merge by hand. A draft is armed
  when it is marked ready for review.
- `update-branches.yml` updates every armed PR after each push to `main`, so
  strict "up to date" branch protection does not leave them stuck BEHIND.

One-time setup (org or repo admin):

- Install the NCC ConsTech Automation app on this repo.
- Give this repo access to the org-level `AUTOMATION_APP_CLIENT_ID` variable
  (the app's Client ID, not its App ID) and the org-level
  `AUTOMATION_APP_PRIVATE_KEY` secret; both are shared with selected
  repositories.
- Turn on "Allow auto-merge" in the repo settings
  (`scripts/bootstrap-repo-settings.sh` does this).

`GITHUB_TOKEN` cannot be used because GitHub starts no workflows for pushes or
merges made with it: "Closes #N" would not close issues, and the PR's checks
would never run on an updated branch. `ci.yml` runs on PRs only: with strict
protection every PR is tested against current `main` before it merges.

## Cache warming

`.github/workflows/warm-cache.yml` saves the CI caches from `main`, because a
PR can read caches saved on `main` but not caches saved by another PR. It
builds the pipeline `test` image and the web image with the same Docker
layer cache scopes as `ci.yml` (`pipeline`, `web`), so a new PR does not
rebuild tippecanoe from source, and fills the npm cache for `web/`. It runs
on pushes to `main` that touch `pipeline/` or `web/`, twice a week (unused
caches expire after 7 days), and by hand. If you change a cache scope or
build setting in `ci.yml`, change it here too.

## What's included

- `CLAUDE.md`: working rules and durable context, loaded automatically by
  Claude Code.
- `.claude/settings.json`: default tool permissions for Claude Code sessions
  in this repo.
- `docs/design/`: design notes, starting with a project brief template.
- `docs/decisions/`: Architecture Decision Records (ADRs).
- `docs/handoffs/`: session handoff template for continuity between work
  sessions.
- `.github/`: issue forms, PR template, Dependabot config, a stack-neutral CI
  workflow (docs-only PRs skip stack jobs, one required `checks` status),
  app-based auto-merge and branch-update workflows, and a cache-warming
  workflow.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE`.
- `scripts/bootstrap-repo-settings.sh`: one-time repo settings setup (branch
  protection, auto-merge, labels) that a template cannot carry over on its
  own.

## License

GNU General Public License v3.0. Replace with your own choice if different.
