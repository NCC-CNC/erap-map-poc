# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Second synthetic pipeline layer `sample_points` (#32): 30 made-up points
  over Canada (`id` as the tile feature id; `name`, `category` of `alpha`,
  `beta` or `gamma`, `count` 1 to 500), 8 of them inside `sample` polygons so
  the layers overlap. Deterministic generator
  `pipeline/tests/fixtures/make_sample_points.sh` and committed
  `sample_points.geojson`, config `pipeline/layers/sample_points.env` (zooms
  0 to 10, `--drop-rate=1` so every point is kept at every zoom), bats tests
  for the fixture, layer, zooms, attributes, feature ids at every zoom and a
  default run building both layers into one manifest, and a contract entry
  in `docs/design/02_data_layers_and_popups.md`. The CI shellcheck step
  and its `CONTRIBUTING.md` equivalent now lint every
  `pipeline/tests/fixtures/*.sh`.
- `CONTRIBUTING.md` Setup: prerequisites (Git, Docker with Compose v2, Git
  Bash on Windows), a run block, a Checks block with Docker-only local
  equivalents of every CI job (`pipeline`, `web`, `compose`,
  `repo-hygiene`) and their timings, and how auto-merge treats PRs. The
  `CLAUDE.md` Commands section now lists the real run commands, the CI gates
  and their local and CI timings, and Project status reflects M1 nearly done
  and M2 blocked on #13. The README status line is updated to match.
- CI stack jobs in `ci.yml`, gated on non-docs changes and required through
  `checks`: `pipeline` (shellcheck 0.11.0 and hadolint 2.15.1 from
  checksum-verified release binaries, the bats tests in the `test` image,
  then the `runtime` image), `web` (Node 26.13.0 with npm cache: `npm ci`,
  lint, typecheck, test, build, `npm audit --omit=dev --audit-level=high`,
  hadolint, the web image and a smoke test of `/config.json` and `/`) and
  `compose` (`docker compose config -q`, with and without the `pipeline` and
  `dev` profiles); Docker builds use Buildx with the GitHub Actions cache
  (`mode=max`, scopes `pipeline` and `web`).
- `warm-cache.yml` moved from `workflows-optional/` into `workflows/` and
  filled in: on pushes to `main` that touch `pipeline/` or `web/`, twice a
  week and by hand, it saves the `pipeline` and `web` Docker layer caches and
  the `web/` npm cache from `main`, so new PRs start warm.
- Dependabot entries for npm (`/web`, grouped minor and patch updates for
  runtime and dev dependencies, TypeScript majors ignored while
  typescript-eslint needs `<6.1.0`), docker (`/pipeline`, `/web`) and
  docker-compose (`/`).
- Feature pop-ups in the web app: clicking a feature of a layer with a
  `popup` definition opens a MapLibre pop-up rendered by a React component,
  with a title, labelled and formatted stats, and Chart.js charts built from
  tile attributes and the feature id. Pop-up content is declared per layer in
  `src/layers/` (typed `PopupDefinition`); the `sample` layer shows its name,
  ID, area, score and a bar chart of its yearly values. Pointer cursor over
  clickable features, one pop-up at a time, closes on a click elsewhere, and
  keeps working after a basemap switch. Adds `chart.js` 4.6.1 with only the
  bar, line, scale and tooltip components registered; charts are destroyed
  when the pop-up closes.
- `docker-compose.yml` (ADR 0004): `web` (nginx image
  `natureconservancy/erap-map-web`, port `WEB_PORT` default 8080, tiles
  mounted read-only, `CARTO_API_KEY` from `.env`, read-only root with a tmpfs
  `/tmp`, healthcheck), `pipeline` under the `pipeline` profile (image
  `natureconservancy/erap-map-pipeline`, `data/raw` read-only, `data/tiles`
  read-write, uid overridable with `PIPELINE_UID`/`PIPELINE_GID`), and
  `web-dev` under the `dev` profile (Vite with hot reload in the pinned Node
  image, `node_modules` in a named volume, port `WEB_DEV_PORT` default
  5173); `VITE_USE_POLLING` turns on Vite's polling watcher for Windows bind
  mounts; README usage and `.env.example` updated.
- Web image (`web/Dockerfile`): Node 26.13.0 build stage and unprivileged
  nginx 1.30.6 runtime, both pinned by digest, listening on 8080;
  `web/nginx.conf` serves the app with an `index.html` fallback for app
  routes, `/tiles/` from `/srv/tiles` with range requests,
  `application/vnd.pmtiles`, `no-cache` revalidation and plain 404s, and
  year-long caching for `/assets/`; an entrypoint script writes
  `/config.json` from `CARTO_API_KEY` at start, JSON-escaped.
- CARTO basemaps in the web app (ADR 0005): `src/map/basemap.ts` picks CARTO
  Positron (default) or Dark Matter with the key from the runtime
  `/config.json` (`src/config.ts`), or keyless OpenFreeMap Positron and Dark
  with a console warning when there is no key; a light/dark basemap toggle;
  data layers are re-added after a basemap switch; the Vite dev and preview
  servers serve `/config.json` from `CARTO_API_KEY`.
- Web app scaffold (`web/`): React, TypeScript and Vite, MapLibre GL JS with
  the `pmtiles` protocol, a placeholder OpenFreeMap basemap in `src/map/`, and
  a layer registry in `src/layers/` with the `sample` layer from
  `/tiles/sample.pmtiles`; the Vite dev and preview servers serve
  `data/tiles/` at `/tiles/` with range requests; ESLint, `tsc --noEmit` and
  vitest wired to npm scripts.
- Pipeline entry script `pipeline/bin/run.sh` with shared functions in
  `pipeline/lib/` (logging, layer config, ogr2ogr normalise, atomic
  tippecanoe build, `manifest.json`), the `sample` layer config, a synthetic
  fixture with its generator, and bats tests. The pipeline image now runs
  `run.sh` by default and has a `test` target with bats-core 1.14.0.
- Pipeline image (`pipeline/Dockerfile`): GDAL 3.13.3 base pinned by digest,
  tippecanoe 2.79.0 built from a commit-checked tag, pmtiles CLI 1.31.2
  checksum-verified, non-root user; repo-wide `.hadolint.yaml`.
- Project plan for ERAP Map PoC: project brief, architecture, data contract
  skeleton and milestones in `docs/design/`, and ADRs 0002 to 0004 for the
  pipeline, web app, and Docker Compose stack choices.
- ADR 0005: CARTO Positron and Dark Matter basemaps, with the API key
  supplied at runtime; `.env.example` documents `CARTO_API_KEY`.
- CI: `changes` job so docs-only PRs skip stack jobs, a single required
  `checks` job, a commented cache example, and an opt-in `warm-cache.yml`.
- Hints in `CLAUDE.md`, `CONTRIBUTING.md`, `.gitignore` and the handoff
  template.
- Initial project harness: issue and PR templates, contribution and security
  policies, docs structure (design, decisions, handoffs), and Claude Code
  working rules.

### Changed

- Auto-merge and branch updates run from `.github/workflows/` through the NCC
  ConsTech Automation GitHub App (org-level `AUTOMATION_APP_CLIENT_ID`
  variable and `AUTOMATION_APP_PRIVATE_KEY` secret) instead of the template's
  opt-in PAT-based workflows, which are removed from `workflows-optional/`.
  Squash auto-merge is armed on PRs into `main` from branches in this repo,
  never on forks or Dependabot.
- ADR 0001 names files `NNNN-short-title.md`, matching the ADR README.
- `ci.yml` runs on pull requests only; `bootstrap-repo-settings.sh` gates on
  `checks` by default.
- Basemaps are OpenFreeMap Positron (light, the default) and Dark only, with
  no key (ADR 0006, superseding ADR 0005, #31). The map is created straight
  away with the light style; the Light/Dark toggle, the data layers re-added
  after a style switch, and MapLibre's attribution control are unchanged.
- The `web` compose healthcheck fetches `/` instead of `/config.json`.
- The CI web smoke test checks that `/` returns HTML and that the hashed
  MapLibre worker named in the app bundle is served from `/assets/` as
  `application/javascript`, instead of checking `/config.json`.

### Removed

- The CARTO basemap option and its runtime config: `CARTO_API_KEY` (compose
  `web` and `web-dev`, `.env.example`, CI), `/config.json` and the code that
  served or read it (`web/src/config.ts`, `web/vite/serveConfig.ts`, their
  tests, `web/docker/40-write-config-json.sh` and its Dockerfile `COPY`, and
  the `/config.json` location in `web/nginx.conf`), and the console warning
  about the keyless fallback.

### Fixed

- MapLibre worker failed to load ("Worker failed to load") in the built app
  (#26): maplibre-gl builds its worker URL at runtime, so Vite never emitted
  `maplibre-gl-worker.mjs`. `src/map/worker.ts` now imports it with `?url`
  (emitted as a hashed file under `assets/`) and calls `setWorkerUrl` before
  any map is created, and `web/nginx.conf` serves `.mjs` under `/assets/` as
  `application/javascript` with the same cache and `nosniff` headers.
