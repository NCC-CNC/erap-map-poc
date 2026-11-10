# CARTO Positron and Dark Matter basemaps

## Status

Superseded by 0006-openfreemap-basemaps

## Context

The map needs a basemap that sits quietly under thematic conservation layers.
The team already has a CARTO API key. MapLibre can use any vector style that
follows the MapLibre style spec.

Since late 2026 CARTO requires an API key for its basemaps. Requests without a
key still return tiles, but stamped with an "API KEY REQUIRED" watermark
(seen first on raster tiles, for example in Leaflet). CARTO's FAQ says vector
styles still load without a key for now, but its style repo says a key is
required for all basemaps, so we should not rely on keyless access. The key
goes on the style URL as a query parameter, for example
`https://basemaps.cartocdn.com/gl/positron-gl-style/style.json?key=KEY`.

## Decision

- Use CARTO's vector basemaps: Positron (light) as the default and Dark
  Matter (dark) as an alternative, switchable in the UI.
- Supply the CARTO API key to the web app at container start, not at build
  time. The `web` container reads `CARTO_API_KEY` from the environment and
  writes it into a small runtime config file that nginx serves (for example
  `/config.json`), which the app loads before creating the map. Locally the
  value comes from a git-ignored `.env` file; `.env.example` documents it.
- If no key is set (for example in CI builds or a fresh checkout), fall back
  to a keyless basemap that needs no sign-up (OpenFreeMap Positron) rather
  than a watermarked CARTO one, and log a console warning.
- Keep MapLibre's attribution control on. CARTO's terms require its and
  OpenStreetMap's attribution to stay visible.
- Keep the basemap behind one small module in `web/src/map/`, so changing
  provider later (for example to self-hosted Protomaps PMTiles) touches one
  place.

## Consequences

- Light, muted styles keep the data layers readable, and a dark option comes
  for free.
- The image does not contain the key, so the same image works in any
  environment.
- A key used in the browser is visible to anyone who opens the app. Restrict
  it by allowed domain in CARTO, and never reuse a key that has other powers.
- The basemap depends on CARTO's service and terms, which have just changed
  and may change again. CARTO can rate-limit or revoke keys without notice.
  The free tiers have monthly tile-request caps; CARTO's pages disagree on
  the exact figures (1M or 5M) and on what counts as commercial use, so
  confirm which tier our key is on before wider rollout.
- If the key was issued before 23 September 2026 and our use counts as
  commercial, a transition period under the old terms ends on
  30 November 2026. Check this with whoever owns the key.
- If CARTO's terms stop fitting, the fallback design (one basemap module,
  OpenFreeMap or self-hosted Protomaps) keeps switching cheap.
