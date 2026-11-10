# Docker Compose and static PMTiles serving

## Status

Accepted

## Context

The pipeline and the web app have different toolchains (GDAL and tippecanoe
versus Node). Both need to run the same way on any machine and in CI, the web
app must run locally, and the pipeline must run on demand.

## Decision

- Each component has its own Dockerfile: `pipeline/Dockerfile` and
  `web/Dockerfile` (multi-stage: Node build, nginx runtime).
- A root `docker-compose.yml` defines a `web` service that starts by default
  and a `pipeline` service under the `pipeline` profile, run with
  `docker compose run --rm pipeline`.
- The two share data through a bind-mounted `data/tiles/` folder: the
  pipeline writes it, nginx serves it read-only.
- Tiles are served as static `.pmtiles` files over HTTP range requests. No
  tile server or database.

## Consequences

- Only Docker is needed locally.
- No running service between pipeline and app; rebuilding a layer is just
  replacing a file.
- Moving to hosted deployment later is mostly copying static files to any
  host that supports range requests.
- Bind mounts on Windows and macOS can be slow for large inputs; if that
  bites, switch `data/raw/` to a named volume.
