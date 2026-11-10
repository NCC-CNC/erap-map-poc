# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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

- ADR 0001 names files `NNNN-short-title.md`, matching the ADR README.
- `ci.yml` runs on pull requests only; `bootstrap-repo-settings.sh` gates on
  `checks` by default.
