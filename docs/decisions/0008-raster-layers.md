# Binary raster layers as cover-share PNG tiles, coloured in the map

## Status

Accepted. Adds raster layers alongside the vector ones of
0002-bash-gdal-tippecanoe-pipeline.md and 0007-data-driven-layer-styles.md.
The build steps and full-Canada timings are revised by
0010-raster-build-speed-and-cog-option.md.

## Context

The first play data (November 2026) includes two binary rasters (issue 50):
forest cover (Byte, 1 only, nodata 255, 620 MB) and agricultural land
(Float32 0/1, nodata NaN, 1.3 GB). Both are Canada-wide at 30 m in Canada
Albers, 200,792 x 131,690 and 235,461 x 137,833 cells, LZW in strips of one
row, with no overviews. They are display only: no clicks or pop-ups (raster
summaries for polygon pop-ups are #14).

Requirements: one `.pmtiles` per layer, like the vector layers, built by the
same bash pipeline, per layer (building one layer must not rebuild others);
lower zooms should show how much of each pixel is covered, not just whether
any of it is; and changing a layer's colour should ideally need no
re-tiling (a later `--style-only` mode will update a layer's display
without rebuilding its tiles).

GDAL's PMTiles driver writes vector tiles only, so raster tiles have to be
made some other way and packed with the `pmtiles` CLI.

## Trial

A 300 km square clip of the forest raster (10,001 x 10,001 cells around
Algonquin Park and Ottawa), z3 to z12, on 16 cores, all routes from the
same prepared raster (gdalwarp to EPSG:3857 at the z12 resolution, aligned
to the tile grid, tiled Byte 0/1: 3.3 s):

| Route | Steps | Build | Archive | Tiles | Low zooms | Colour |
| --- | --- | --- | --- | --- | --- | --- |
| A | RGBA colour VRT, `gdal raster tile` (average overviews), PNG dir, sqlite3 MBTiles, `pmtiles convert` | 7.7 s | 27.8 MB | 2,745 (z3 to z12) | cover share as alpha (256 levels) | in the tiles |
| B | RGBA colour VRT, `gdal_translate -of MBTiles`, `gdaladdo -r average`, `pmtiles convert` | 26.5 s | 15.4 MB | 2,741 (z6 to z12 only) | any cover drawn solid (alpha 0 or 255) | in the tiles |
| C | cover share per zoom (gdalwarp `-r average`, Float32), grey PNG via `gdal raster tile` per zoom, sqlite3 MBTiles, `pmtiles convert`; MapLibre `raster-dem` source and `color-relief` layer | 6.0 s | 23.3 MB | 2,745 (z3 to z12) | cover share, mapped to alpha by the style | in the style |

- B is three to four times slower (the MBTiles writer is single-threaded),
  its overviews stop at z6 for this extent, and its average over the alpha
  band leaves alpha at 0 or 255, so at z8 the clip reads as almost solid
  forest. Its archive is smallest because those overviews carry so little.
- A and C look the same at every zoom in the browser (screenshots at z6, z9
  and z14 on MapLibre GL JS 6.16.0). At z14, past the max zoom, C with
  `resampling: nearest` keeps the 38 m cells as sharp squares, exactly like
  A with `raster-resampling: nearest`; `linear` softens the edges.
- C's tiles are one grey band plus alpha (0 is transparent, so blank tiles
  are skipped and nodata and 0 render transparent), 16% smaller than A's
  RGBA, and slightly faster to build.
- `gdal raster tile --overview-resampling average` cannot build C's
  overviews: its average skips nodata (or alpha 0), so every partly covered
  pixel comes out fully covered. C averages the share per zoom with
  gdalwarp instead (Float32, no nodata), each level exactly aligned to the
  tile grid, and tiles each level at its own zoom.

Full Canada, from the trial and two measurements on the real files (a
full-width stripe of 3,000 rows of the forest raster warped to z12 in
39.7 s; a coarse warp counting 251,931 z12 tiles with forest, 126 times the
clip's 2,000):

| Layer | Prepare | Tile and pack | Total | Archive |
| --- | --- | --- | --- | --- |
| `forest`, route C | about 29 min | about 10 to 15 min | about 40 to 45 min | about 2 to 3 GB |
| `forest`, route A | about 29 min | about 16 min | about 45 min | about 3.5 GB |
| `forest`, route B | about 29 min | about 56 min | about 85 min | about 2 GB |
| `agriculture`, route C | over 50 min | about 10 to 20 min | over 1 hour | about 2 to 4 GB |

The agriculture figures are rougher: a single pass over its Float32 file
did not finish in 22 minutes (sampling every 20th row, nearest) or 25
minutes (a coarse `-r max` warp), against 4 minutes for the same pass over
the Byte forest file, so decoding the Float32 strips (about 130 GB
uncompressed, single-threaded) adds at least 20 minutes to the forest's
prepare time. Its tile count could not be measured; similar coverage to
forest is assumed. Neither full build was run (both estimates are over 30
minutes).

## Decision

Route C.

- `LAYER_TYPE=raster` in `<layer>.env` selects the raster branch
  (`pipeline/lib/raster.sh`), with `LAYER_MIN_ZOOM`, `LAYER_MAX_ZOOM` (at
  most 14) and an optional `LAYER_NODATA` and `LAYER_SOURCE_SRS`. It goes
  through the same per-layer path as a vector layer: the display config is
  checked first, the archive is written to a temp file and moved into
  place, and only that layer's manifest entry is replaced.
- Prepare: gdalwarp to EPSG:3857 at the max zoom's resolution, aligned to
  the tile grid, internally tiled (ZSTD), Byte: 1 stays 1, 0 and nodata
  become 0. Levels: for each lower zoom, the share covered, averaged from
  the level above. Tiles: each level as grey PNG (0 to 255, 0 transparent)
  by `gdal raster tile` at its own zoom, multithreaded, blank tiles skipped.
  Pack: an MBTiles file written with the `sqlite3` CLI (added to the image),
  then `pmtiles convert` and `pmtiles verify`. Intermediates live in the
  run's scratch dir and are removed as each step finishes.
- Display: `<layer>.style.json` uses the raster shorthand,
  `{"geometry": "raster", "color": "#rrggbb", "opacity": 0.7, "label": ...}`.
  The pipeline expands it into one `color-relief` style layer whose colour
  ramp goes from transparent at no cover to the colour at full cover, with
  `color-relief-opacity` and `resampling: nearest`, and a single-swatch
  legend. Raster layers cannot have a pop-up or raw `layers`.
- Source: a `raster-dem` source with `encoding: custom`
  (`redFactor` 1/255, the other factors and `baseShift` 0, tile size 256),
  so the "elevation" MapLibre decodes is the cover share from 0 to 1. The
  pipeline (`style.json`) and the web app (`RASTER_SOURCE` in
  `web/src/layers/spec.ts`) use the same source.
- Manifest: every entry gains `type` (`vector` or `raster`), `format` (the
  archive's tile type, `mvt` or `png`), `build_seconds` and `bytes`; a
  raster entry has `tile_count`, `max_tile_bytes` and per-zoom `zooms`
  (`tiles`, `max_tile_bytes`) in place of the vector drop guard report. An
  entry without `type` is read as vector.

## Consequences

- Colour and opacity are in the style only: recolouring a raster layer
  changes its manifest entry and `style.json`, never its tiles (a test
  checks this), so the coming `--style-only` mode applies to rasters as
  well as vectors.
- The colour ramp can do more than one colour later (for example a
  stepped ramp on cover share) with no pipeline change to the tiles.
- Raster layers need MapLibre GL JS 5.6 or later for `color-relief` and
  custom `raster-dem` encodings; the app pins 6.16.0. Other tools reading
  `style.json` need the same.
- A full-Canada build is slow (tens of minutes per layer, dominated by the
  warp of the strip-layout source) and needs a few GB of scratch space in
  the container; it is on demand, per layer, like every build. Running the
  prepare step in parallel chunks, or caching the prepared raster between
  runs that change only the zoom range, are possible follow-ups.
- The prepare step reads a strip-layout source in one pass; keeping the
  scratch dir inside the container (not a Windows bind mount) matters:
  route A's tiling took 19.7 s against 6.1 s when its tiles went to a
  bind-mounted folder.
- A source is expected to hold only 0, 1 and nodata. Other values are not
  rejected; they count as covered.
