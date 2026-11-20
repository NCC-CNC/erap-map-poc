---
name: inspect-data
description: Summarise a spatial dataset in RAW_DIR (data/raw/) without adding a layer (shapefile, zipped shapefile, GeoPackage, GeoJSON, FileGDB, ..., or a GeoTIFF - bands, data type, values, nodata, and whether it is a binary raster that can be a layer) - layers, feature count, geometry type, CRS, extent, encoding, fields with value counts, id candidates and polygon validity and coverage checks. Use when asked what is in a dataset, to look at, describe or check source data, or whether a file is usable.
---

# Inspect a dataset

Guide: `docs/guide.md`, Look at a dataset. Read only. The data must be in
`RAW_DIR` (`.env`; default `data/raw/`), mounted read-only; give the path
relative to it. A file in a zip is `name.zip/folder/file.shp`. If the
user names a file elsewhere, ask them to put it in `RAW_DIR` (never in
git).

Vector data:

```sh
docker compose run --rm --entrypoint inspect.sh pipeline [--layer NAME] [--json] [--no-checks] <path>
```

`--layer` picks a layer of a GeoPackage or FileGDB (the summary lists
them all); `--no-checks` skips the slow polygon checks on big data;
`--gap-width METRES` tunes the coverage check.

A GeoTIFF: the two `gdalinfo` commands in the guide (header first; the
values read the whole file, about 5 minutes for a Canada-wide 30 m
raster, so run it in the background). Only a single-band binary raster
(0, 1 and nodata) can be a layer; categorical, continuous and multiband
rasters are not supported yet.

## Report

In plain words: what the data is (geometry, count, extent, CRS), fields
worth styling or showing in a pop-up, a unique integer id (or that there
is none: a vector layer needs one), and every warning (no CRS or
encoding, invalid geometries, overlaps or gaps; a coverage-like polygon
set suits `processing.profile: coverage`). If the user wants it on the
map, continue with the add-layer skill.
