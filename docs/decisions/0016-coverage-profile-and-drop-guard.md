# Coverage profile and drop guard

## Status

Accepted. Records decisions first made in design note 02 (removed in the
refactor, ADR 0015), now the `coverage` profile and the drop guard in
`pipeline/lib/`. Builds on 0002-bash-gdal-tippecanoe-pipeline.md and
0013-full-detail-at-vector-max-zoom.md.

## Context

Real layers such as the ecoregions are contiguous coverages: polygons
that tile an area with no overlaps and shared borders. They need no gaps
or slivers along shared borders at any zoom, no large feature dropped
where it is visible, and only features too small to see dropped or
merged.

## Decision

- **The `coverage` profile** adds, after the tippecanoe options every
  vector layer has:
  - `--no-simplification-of-shared-nodes`: every border between two
    nodes is simplified the same in both neighbours. On the synthetic
    coverage fixture it leaves no overlaps and no gaps from z2 up;
    `--detect-shared-borders` (deprecated in tippecanoe 2.79.0) left a
    53 pixel hole at z5, and no flag opened gaps at every zoom.
  - `--drop-smallest-as-needed`: a full tile drops the smallest polygons
    first. `--drop-densest-as-needed` thins by spacing, so it can drop a
    large polygon in a dense area. No `--coalesce*`: it changes ids and
    attributes and turns off the shared node handling.
- **Low-zoom generalisation** (`lib/generalise.sh`): for each zoom below
  `maxzoom`, GDAL makes a copy of the polygons in Web Mercator that drops
  parts under `min_part_px` screen pixels (each feature keeps its largest
  part) and simplifies them as a coverage (`gdal vector
  simplify-coverage`) by `simplify_px`. The max zoom is full detail (ADR
  0013). No `ogr2ogr -simplify`: it works per feature and opens gaps.
- **The drop guard** (`lib/guard.sh`) runs after tiling on every vector
  layer, before the archive is moved into place. A polygon is required at
  zoom z when its largest part covers at least `min_visible_px` screen
  pixels at 256 px tiles (default 1). A required feature missing from
  every tile of its zoom fails the build and the previous archive is
  kept; smaller missing features are counted in `build.json`. One pixel
  here is at least 2 by 2 CSS pixels on screen, too small to read as a
  shape or a hole.

## Consequences

- Shared borders stay closed at every zoom, and a layer cannot silently
  lose a visible polygon.
- The guard roughly doubles the tiling time (it reads every zoom of the
  archive once for ids and once for tile sizes).
- A layer with many small parts, such as islands, may need a higher
  `min_visible_px` (`protected_areas` uses 4) or a lower `min_part_px`.
