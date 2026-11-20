# Full detail at a vector layer's max zoom

## Status

Accepted. Extends 0002-bash-gdal-tippecanoe-pipeline.md (a tippecanoe
default for every vector layer) and 0009-local-map-config.md (a map config
setting can be `true` or `false`). Since ADR 0015 every vector profile
keeps the max zoom at full detail and `LAYER_SIMPLIFY_MAX_ZOOM` is gone.
Since #147 polygon layers are generalised gently at the max zoom by the
pipeline itself (`maxzoom_min_part_px`, `maxzoom_simplify_px`; 0 for full
detail); tippecanoe still leaves the max zoom unsimplified.

## Context

Zoomed in past a vector layer's max zoom, the map overzooms the max zoom's
tiles, so their geometry is all a user sees of the source. Tippecanoe
simplifies every zoom, the max zoom included, with a tolerance of about one
tile unit. On `ecoregions` (then z0 to z10) a small island in Georgian Bay
(#85, at 45.37 N, 80.09 W) with 33 vertices in the source came out as a
diamond of 6. Measured on a clip around it (island vertices):

| Variant | Vertices |
| --- | --- |
| z10 (as built) | 6 |
| z10, `--simplify-only-low-zooms` | 21 |
| z12 | 18 |
| z12, `--simplify-only-low-zooms` | 30 |
| z14 | 31 |

Two things lose the detail: simplification at the max zoom, and the max
zoom's tile grid (4096 units a tile: about 10 m in Web Mercator at z10,
2.4 m at z12).

## Decision

- Every vector layer is tiled with tippecanoe's `--simplify-only-low-zooms`
  (tippecanoe 2.79.0), added before the profile's and the layer's own
  flags: the lower zooms are simplified as before, the max zoom is not.
- A new vector setting, `LAYER_SIMPLIFY_MAX_ZOOM` (default `false`), opts
  out: `true` leaves the flag out, for smaller tiles. Anything but `true`
  or `false` fails the layer. It works in a layer's `.env` and in the map
  config's `overrides.<layer>.env`, whose settings may now be JSON `true`
  or `false` as well as text, numbers and lists. Like any setting it is in
  the layer's settings hash, so changing it makes the build stale. The
  build report records it as `simplify_max_zoom`.
- `ecoregions` goes from z10 to z12, like `protected_areas`, so its
  islands also get the finer grid.

## Consequences

- Zoomed in, polygons and lines follow the source, to the max zoom's grid.
  The coverage profile still holds: shared nodes are kept at every zoom,
  and unsimplified borders match in both neighbours. Low-zoom
  generalisation (`LAYER_GENERALISE_MAX_ZOOM`) is unaffected; it changes
  only the generalised zooms' input.
- Max zoom tiles are larger, and a higher max zoom adds tiles and build
  time: `ecoregions` at z12 has to be rebuilt and measured. A layer whose
  max zoom tiles grow too large can set `LAYER_SIMPLIFY_MAX_ZOOM=true` or
  lower its max zoom.
- The default is in code, not in each `.env`, so builds made before it
  stay `current` in `--status` until rebuilt; the vector layers need a
  rebuild to pick it up.
