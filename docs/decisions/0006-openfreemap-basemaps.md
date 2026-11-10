# OpenFreeMap basemaps

## Status

Accepted

## Context

ADR 0005 chose CARTO's Positron and Dark Matter basemaps with an API key.
CARTO's keyless access now returns watermarked tiles, so CARTO only works
with a key. Supplying the key at runtime needed its own plumbing: a
`/config.json` written by an nginx entrypoint script, a Vite plugin to serve
it in development, a config fetch before the map is created, a `.env`
setting, and CI checks for all of it. The app already fell back to
OpenFreeMap's keyless Positron and Dark styles when no key was set, and they
suit the data layers just as well. On 2026-11-10 the repo owner chose
OpenFreeMap as the only basemap (#31).

## Decision

- Use OpenFreeMap's vector styles as the only basemaps: Positron
  (`https://tiles.openfreemap.org/styles/positron`) as the default and Dark
  (`https://tiles.openfreemap.org/styles/dark`) as an alternative, switchable
  in the UI.
- Remove the CARTO key and the runtime config path: no `CARTO_API_KEY`, no
  `/config.json`, no entrypoint script or dev server plugin for it. The map
  is created straight away with the light style.
- Keep MapLibre's attribution control on, so the OpenFreeMap and
  OpenStreetMap credit stays visible.
- Keep the basemap behind one small module, `web/src/map/basemap.ts`, so
  changing provider later touches one place.

## Consequences

- No key to obtain, restrict or rotate, and no runtime config: the image and
  the dev server need no basemap settings, and there is less code to test.
- The attribution stays visible as OpenFreeMap and OpenStreetMap require.
- OpenFreeMap is free and donation funded, with no SLA. It can be slow or
  unavailable, and its terms could change.
- If that matters later (wider rollout, offline use), the fallback is to
  self-host a Protomaps basemap PMTiles archive next to the data layers and
  point `basemap.ts` at a style that reads it.
