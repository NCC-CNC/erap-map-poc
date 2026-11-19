# Coverage profile and drop guard

## Status

Accepted. Records decisions first made in design note 02 (removed in the
refactor, ADR 0015), now the `coverage` profile and the drop guard in
`pipeline/lib/`. Builds on 0002-bash-gdal-tippecanoe-pipeline.md and
0013-full-detail-at-vector-max-zoom.md. Since #147 the per-zoom
generalisation also covers the max zoom (more gently) and `default`
polygon layers (each feature simplified on its own, no shared borders).
Reviewed after the first Canada-wide build (#141): the design stays, for
the reasons in "Why not tippecanoe alone" below; the archive is now
built and checked on the container's own disk.

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
- **Per-zoom generalisation** (`lib/generalise.sh`): for each zoom from
  `minzoom` to `maxzoom`, GDAL makes a copy of the polygons in Web
  Mercator that drops parts under `min_part_px` screen pixels (each
  feature keeps its largest part) and simplifies them by `simplify_px`:
  as a coverage (`gdal vector simplify-coverage`) for `coverage`, each
  feature on its own for `default`. The max zoom uses the gentler
  `maxzoom_min_part_px` and `maxzoom_simplify_px` (ADR 0013, #147). No
  `ogr2ogr -simplify`: it works per feature and opens gaps.
- **The drop guard** (`lib/guard.sh`) runs after tiling on every vector
  layer, before the archive is moved into place. A polygon is required at
  zoom z when its largest part covers at least `min_visible_px` screen
  pixels at 256 px tiles (default 1). A required feature missing from
  every tile of its zoom fails the build and the previous archive is
  kept; smaller missing features are counted in `build.json`. One pixel
  here is at least 2 by 2 CSS pixels on screen, too small to read as a
  shape or a hole.
- **Built off the bind mount** (#141): tippecanoe writes the archive in
  the layer's scratch dir, where `pmtiles verify` and the guard read it;
  only the finished archive is copied to `data/tiles/` and renamed into
  place. The guard reads feature ids with the geometry ignored.

## Why not tippecanoe alone

Checked in #141 with tippecanoe 2.79.0 on real-data clips: two
ecoregions around Georgian Bay's islands (z0 to z12), 9 around the
Strait of Georgia, and protected areas around Suffield (1,474 areas) and
the BC and Alberta border near 54.4 N, 120 W (83 areas).

| Georgian Bay, ecoregions | Parts at z6 / z8 / z12 | Archive | Generalise, tile and guard |
| --- | --- | --- | --- |
| Now (generalised, current flags) | 15 / 100 / 9,311 | 0.80 MB | 8 s, 8 s |
| tippecanoe only, its defaults | 1,080 / 6,212 / 18,917 | 2.19 MB | none, 40 s |
| tippecanoe only, `--simplification=8` (0.5 px, every zoom) | 458 / 3,537 / 18,768 | 1.07 MB | none, 41 s |
| tippecanoe only, `--simplification=16` (1 px) | 435 / 3,421 / 18,551 | 0.93 MB | none, 33 s |
| tippecanoe only, `--tiny-polygon-size=22` (2 px) | archive failed `pmtiles verify` | | |
| GDAL part filter only, `--simplification=8` | 17 / 99 / 9,230 | 0.67 MB | 56 s, 54 s |

(Times ran beside other containers and before the archive was built off
the bind mount, so compare rows, not absolute times.)

- Simplification does not drop small parts. With tippecanoe alone, each
  island down to its tiny polygon threshold (1/64 px) is drawn at every
  zoom, so the coast at z7 is a smear of outlines again, as before #68.
  Tippecanoe has no part threshold per zoom that keeps each feature's
  largest part. `--tiny-polygon-size` is area preserving: it turns small
  parts into a scatter of squares and takes whole features whose largest
  part is under it (#68), and at 22 the archive was broken.
- `--simplification` and `--simplification-at-maximum-zoom` could now
  give the two tolerances in screen pixels (16 is 1 px at 4096 units a
  tile), but only with the parts left in full detail: each zoom's copy
  then carries every vertex of the large polygons, and generalising and
  tiling each took about seven times as long. GDAL's
  simplification is what keeps the per-zoom copies small.
- Tippecanoe's simplification keeps at least four points of a ring, so
  it kept the protected areas border sliver (id 54416) that GDAL's half
  pixel simplification takes at z11 and z12: on the border clip,
  `min_visible_px: 1` passes with tippecanoe simplifying and fails with
  GDAL. It also tiled the Suffield clip in 6 s against 1 s, so
  `protected_areas` keeps `min_visible_px: 10` instead.
- `--coalesce*` still changes ids and attributes, `--detect-shared-borders`
  is deprecated, and `--gamma` thins points only.
- Nothing in tippecanoe promises a visible polygon survives: its
  simplification, tiny polygon reduction and `--drop-smallest-as-needed`
  can each remove one, and so can the generalisation. The guard stays.

Where the first Canada-wide build's time went (`ecoregions`, z0 to z12,
about 48 minutes from tiling to the guard passing): tippecanoe wrote its
archive straight onto `data/tiles/`, a Docker Desktop bind mount. On the
Strait of Georgia clip that took 32 s against 4 s on the container's
disk, and the whole tile and guard step 34 s against 5 s, with the same
tiles and guard counts. The guard's id reads of the full ecoregions
archive took about 9 minutes from the bind mount (z12 alone 6 minutes),
about 3.5 minutes on the container's disk with the geometry ignored
(z12 2.3 minutes), the same rows at z9 and z11.

## Consequences

- Shared borders stay closed at every zoom, and a layer cannot silently
  lose a visible polygon.
- The guard reads every zoom of the archive once for ids and once for
  tile sizes: minutes for a Canada-wide layer at z12, most of it at the
  max zoom.
- The scratch dir needs room for the archive while it is checked (72 MB
  for the ecoregions); `data/tiles/` gets one sequential copy.
- A layer with many small parts, such as islands, may need a higher
  `min_visible_px` (`protected_areas` uses 10) or a lower `min_part_px`.
