# Bash pipeline with GDAL, tippecanoe and PMTiles

## Status

Accepted

## Context

Source spatial data needs to be cleaned, reprojected, enriched with summary
stats, and turned into vector tiles the web map can load quickly. The steps
are mostly calls to mature command-line tools, and the pipeline runs on
demand rather than as a service.

## Decision

- Write the pipeline as bash scripts (`set -euo pipefail`), linted with
  shellcheck and tested with bats.
- Use GDAL/OGR (`ogr2ogr`, OGR SQL) for validation, reprojection, attribute
  selection, and simple stats.
- Use tippecanoe (felt/tippecanoe) to build vector tiles, writing `.pmtiles`
  directly.
- Install the `pmtiles` CLI (protomaps/go-pmtiles) for inspection and for
  converting `.mbtiles` if needed.
- Do not install `mb-util` until a step needs a tile directory; tippecanoe and
  the `pmtiles` CLI cover the planned steps.
- Run everything inside a custom image based on a pinned `ghcr.io/osgeo/gdal`
  tag, with tool versions pinned.
- Drive the pipeline from per-layer config files rather than hard-coded
  paths.

## Consequences

- Thin glue over well-known tools; no language runtime to manage.
- Bash gets awkward for complex stats or plot data. If a step outgrows OGR
  SQL, add a small Python (or similar) helper inside the same image and record
  it in a new ADR.
- PMTiles output means no tile server is needed (see ADR 0004).
