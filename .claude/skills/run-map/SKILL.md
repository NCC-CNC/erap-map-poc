---
name: run-map
description: Start, stop, rebuild or open the web map locally (the nginx web image, or the Vite dev server with hot reload), check that it is healthy and serving the layers, take screenshots, and fix common failures (stale image, port in use, no layers). Use when asked to run, start, stop, restart, open, view or screenshot the map or app.
---

# Run the map

Commands run from the repo root in Git Bash. The map reads its layers
from `data/tiles/manifest.json`, so build layers first if
`docker compose run --rm --build pipeline --status` shows none built
(build-layers skill).

## Start

Web image (nginx, like production), at <http://localhost:8080>:

```sh
docker compose up -d --build web
```

`--build` picks up any change in `web/`; it is quick when nothing
changed. For frontend work, the Vite dev server with hot reload, at
<http://localhost:5173> (first start runs `npm ci`, about a minute):

```sh
docker compose --profile dev up -d web-dev
```

## Check

```sh
docker compose ps                              # web should become (healthy)
curl -fsS http://localhost:8080/tiles/manifest.json | head -c 300
docker compose logs --tail 50 web              # or web-dev
```

Then give the user the URL (Git Bash `start <url>` opens it; macOS
`open`, Linux `xdg-open`). A rebuilt layer needs no restart: reload the
page.

## Screenshot

`scripts/screenshot.sh` runs its own private web container on a spare
port (8090 up), so it works whether or not the map is running:

```sh
scripts/screenshot.sh -n <prefix> <z/lat/lon> [<z/lat/lon> ...]
```

Views come from a layer's `center` (lon, lat, zoom) or `bounds` in the
manifest. Images go to `tmp/screenshots/<prefix>-<light|dark>-z....png`;
read them and report any `page error` or `console error` lines. Never
commit them.

## Common failures

- Port in use (`port is already allocated`, `address already in use`):
  see what holds it with `docker ps --format '{{.Names}} {{.Ports}}'`;
  if it is not this map, pick a free port with `WEB_PORT=8081` (or
  `WEB_DEV_PORT=5174`) before the command, or in `.env`.
- Old app after a pull or code change: the image is stale; rerun with
  `--build`. Browser cache: hard reload.
- Panel says data layers are not available: `manifest.json` is missing
  or not valid; build the layers, then reload.
- A layer missing or wrong: check `--status` for it, and the browser
  console (or screenshot `page error` lines). `Layer "<name>" skipped:
  could not read ...` names the file the map could not open: a vector
  layer's `.pmtiles` or a raster layer's `.cog.tif` (missing, or not
  built yet). A raster is read with range requests through the `cog://`
  protocol: `curl -fsSI -r 0-99 http://localhost:8080/tiles/<name>.cog.tif`
  should answer `206` with `image/tiff`; if not, the web image is stale
  (rerun with `--build`). A raster drawn but nearly transparent was built
  before COGs with an older colour ramp: `--status` says `stale`;
  rebuild it.

## Stop

```sh
docker compose stop web           # or web-dev; `start` resumes it
docker compose down               # stop and remove this project's containers
```

Never add `-v` to `down` unless the user asks: it deletes the dev server's
`node_modules` volume.
