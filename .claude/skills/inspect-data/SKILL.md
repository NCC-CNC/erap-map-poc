---
name: inspect-data
description: Summarise a spatial dataset in data/raw/ without adding a layer (shapefile, zipped shapefile, GeoPackage, GeoJSON, FileGDB, ..., or a GeoTIFF - bands, data type, values, nodata, and whether it is a binary raster that can be a layer) - layers, feature count, geometry type, CRS, extent, encoding, fields with value counts, id candidates and polygon validity and coverage checks. Use when asked what is in a dataset, to look at, describe or check source data, or whether a file is usable.
---

# Inspect a dataset

Read only: nothing is written and nothing changes in the repo. The data
must be under `data/raw/` (mounted read-only into the pipeline); give the
path relative to it, without a leading `/`. A file inside a zip is
`name.zip/folder/file.shp`. If the user names a file elsewhere, ask them
to copy it into `data/raw/` (never commit it).

```sh
ls data/raw/                     # what is there
docker compose run --rm --build --entrypoint inspect.sh pipeline <path>
```

`inspect.sh` is for vector data. For a raster (GeoTIFF), run `gdalinfo`
in the pipeline image instead, as in the add-layer skill (Raster sources,
steps 1 and 2: band count, data type, nodata, min and max, histogram, CRS,
block layout), and say whether it can be a raster layer: only single-band
binary rasters (0, 1 and nodata) are supported; categorical, continuous
and multiband rasters are not yet.

Options (all in `pipeline/bin/inspect.sh --help`):

- `--layer <name>`: a layer of a multi-layer source (GeoPackage, FileGDB);
  without it, the first. The summary lists every layer.
- `--json`: full detail (every field's stats and values).
- `--no-checks`: skip the polygon checks, which are slow on large data.
- `--gap-width <metres>`: the narrowest gap between neighbours that the
  coverage check does not flag (default 100).

## Report

Summarise in plain words: what the data is (geometry, count, extent in
WGS84, CRS), the fields worth styling or showing in a pop-up (text fields
with few values, numeric ranges), a stable integer id (or that there is
none: a layer needs one), and every warning (no CRS, no encoding,
invalid geometries, overlaps or gaps, a coverage-like polygon set that
suits `LAYER_PROFILE=coverage`). Say what a layer config would need. If
the user then wants it on the map, continue with the add-layer skill.
