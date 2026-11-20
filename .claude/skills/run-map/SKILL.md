---
name: run-map
description: Start, stop, rebuild or open the web map locally (the nginx web image, or the Vite dev server with hot reload), check that it is healthy and serving the layers, take screenshots, and fix common failures (stale image, port in use, no layers). Use when asked to run, start, stop, restart, open, view or screenshot the map or app.
---

# Run the map

Guide: `docs/guide.md`, Run the map and Take screenshots. From the repo
root in Git Bash. The map reads `data/tiles/style.json`: if
`docker compose run --rm pipeline --status` shows nothing built, build
first (build-layers skill).

```sh
docker compose up -d --build web               # nginx, http://localhost:8080
docker compose --profile dev up -d web-dev     # Vite with hot reload, http://localhost:5173
docker compose ps                              # web should become (healthy)
curl -fsS http://localhost:8080/tiles/style.json | head -c 300
docker compose logs --tail 50 web
docker compose stop web                        # or: docker compose down
```

Give the user the URL (`start <url>` in Git Bash). A rebuilt layer needs
no restart: reload the page. Never add `-v` to `down` unless asked (it
deletes the dev server's `node_modules` volume).

Screenshots (a private web container on port 8090 up; works whether or
not the map runs; files in `tmp/screenshots/`, never committed):

```sh
scripts/screenshot.sh -n <prefix> <z/lat/lon> ...
scripts/screenshot.sh -c -n <prefix> [--tab LABEL] [--colour-by LAYER=THEME] <z/lat/lon>
```

A layer's `center` is in `data/tiles/build.json`. Read the images and
report any `page error` lines.

Common failures:

- Port in use: `docker ps --format '{{.Names}} {{.Ports}}'`; if not this
  map, set `WEB_PORT` (or `WEB_DEV_PORT`) in `.env`.
- Old app after a pull: rerun with `--build`; hard reload the browser.
- No layers in the panel: `style.json` missing or not valid; build.
- A layer shown as not available: its archive is missing or unreadable;
  check `--status` for it. A raster needs range requests: `curl -fsSI -r
  0-99 http://localhost:8080/tiles/<name>.cog.tif` should answer `206`.
- A layer not clickable after a pull: run
  `docker compose run --rm pipeline --style-only`.
