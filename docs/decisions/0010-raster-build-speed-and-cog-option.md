# Full-Canada raster builds: prepare once, fast warp, overviews; COG option

## Status

Accepted. Changes how 0008-raster-layers.md builds raster layers (route C
and the tiles are unchanged). Records a static COG per layer as a measured
option, not adopted.

## Context

ADR 0008 (route C, cover-share PNG tiles in `.pmtiles`, coloured in the
map) estimated 40 to 45 minutes for the forest layer and over an hour for
agriculture, all of Canada at z2 to z12, and neither full build had been
run (issue 62). The stakeholders expect many more layers, so builds need to
be practical on a staff laptop.

The sources are Canada Albers, 30 m, LZW, stored as strips of one row with
no overviews: forest 200,792 x 131,690 Byte (nodata 255, 0.6 GB),
agriculture 235,461 x 137,833 Float32 (nodata NaN, 1.3 GB). Warping such a
file straight to Web Mercator re-decodes each strip for every warp window:
the agriculture warp ran over 2 hours before it was stopped.

It was also asked whether the rasters could be rendered on demand, since
their style is simple, but a tile server is out of scope (CLAUDE.md). The
alternative tried here is a static Cloud Optimized GeoTIFF (COG), served
by nginx with range requests like the `.pmtiles` archives and rendered in
the browser.

All timings: a 16-CPU laptop, Docker Desktop with 16 CPUs and about 23 GB,
GDAL 3.13.3, source data on a Windows bind mount, scratch inside the
container.

## What made it slow, and what fixed it

Measured on the agriculture layer, z2 to z12 (EPSG:3857 grid of 447,240 x
290,531 pixels at z12, 99,942 tiles):

| Step | ADR 0008 code | Measured fix | After |
| --- | --- | --- | --- |
| Read the strip source | warped directly: over 2 h, stopped | prepare once: `gdalbuildvrt` (nodata as 0) then `gdal_translate` to a tiled 512 x 512 ZSTD Byte GeoTIFF, `GDAL_NUM_THREADS=ALL_CPUS`; cached | 188 s, or 0 s from the cache |
| Warp to z12 | (from the prepared file) over 20 min, stopped, 1,460% CPU | the CPU went on ZSTD level 9 (GDAL's default) for the 130 gigapixel output: level 1 and `SPARSE_OK` | 258 s |
| Lower zooms | `gdalwarp -r average` to Float32, per zoom: 659 s | `gdaladdo -r average` on a 0/255 Byte z12 raster, multithreaded, its extent snapped to the min zoom's grid so each overview is one zoom's grid | 36 s |
| Tiles | 329 s (z12 alone 308 s), per zoom from each level | the same `gdal raster tile`, per zoom from each overview | 305 s |
| Pack | 12 s | unchanged | 12 s |

A small warp test (828 megapixels of the prairies, 16 threads) shows the
compression effect: ZSTD level 9 11.1 s, level 1 2.6 s, LZW 3.0 s, Deflate
level 1 3.2 s, no compression 4.1 s (the bigger writes cost more than
level 1 compression).

The overviews round each level to a whole grey level, so lower zooms
differ from the exact Float32 average by at most 2 grey levels (of 255) at
z4 to z8, mean 0.3: not visible. The z12 tiles match to within edge pixels
(the warp's approximate transformer picks a neighbouring cell for under
0.1% of pixels when the extent differs).

## Results

Full builds from the raw sources, one run, both layers (`docker run ...
erap-issue62 agriculture forest`, the same as `docker compose run --rm
pipeline agriculture forest`):

| Layer | Prepare | Warp | Overviews | Tiles | Pack | Total | Tiles | Archive |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| agriculture | 188 s | 258 s | 36 s | 305 s | 12 s | 13 min 19 s | 99,942 | 0.52 GB |
| forest | 143 s | 196 s | 36 s | 340 s | 71 s | 13 min 6 s | 340,758 | 3.24 GB |

With the prepared source cached (any rebuild until the source file
changes) a build is about 10 minutes for agriculture and 11 for forest.
The prepared files are 0.14 GB (agriculture) and 0.69 GB (forest) in
`data/work/raster/`. The container peaked at about 4.5 GB of memory
(`docker stats`) and a few GB of scratch. Both archives were checked in
the map at several zooms.

The tiles step is now the largest and the least parallel (about 170% CPU
for most of it, against 1,500% for the warp): `gdal raster tile` writes
one PNG per tile. It is the place to look if builds need to be faster
again, for example by tiling bands of rows in parallel.

## Option: one COG per layer, rendered in the browser

A prototype (not committed) wrote the warped z12 raster and its overviews
as one Web Mercator COG per layer (256 px blocks, ZSTD, scale 1/255 so
values are 0 to 1, as in the PNG tiles), served by nginx like the
`.pmtiles`, and drew it with `@geomatico/maplibre-cog-protocol` 0.10.0
through the same `raster-dem` source and `color-relief` layer.

| | PMTiles (this ADR) | COG |
| --- | --- | --- |
| Build from the prepared source, agriculture | 611 s | 330 s (warp 222, overviews 38, COG copy 70) |
| File size, agriculture / forest | 0.52 / 3.24 GB | 0.38 / 2.27 GB |
| First draw, pan, zoom (headless Chromium, local nginx, 3 views, 2 runs) | 0.2 to 0.25 s, 0.07 to 0.13 s, 0.33 to 0.37 s | 0.27 to 0.34 s, 0.02 to 0.12 s, 0.32 to 0.35 s |
| Requests for the first draw, agriculture z6 | 25 (1.4 MB) | 18 (1.3 MB) |
| Look | reference | the same at z3, z6 and z10 |

The COG builds in about half the time (no PNG per tile, no packing) and
is about 30% smaller, with no visible difference in the map at local
network speed. Against it: a second source type in the web app and the
data contract (`docs/design/02_data_layers_and_popups.md`), and a young
client library (`@geomatico/maplibre-cog-protocol`, pre-1.0) on the map's
critical path, where the PMTiles route needs nothing new. Remote network
speed was not measured.

## Decision

Keep route C (ADR 0008) and build it as above: prepare each raster source
once into a tiled 0/255 Byte GeoTIFF cached in `PIPELINE_WORK_DIR/raster`
(`data/work/raster/`, keyed by path, size, modification time,
`LAYER_SOURCE_SRS` and `LAYER_NODATA`), warp to z-max with ZSTD level 1
and `SPARSE_OK`, build lower zooms with `gdaladdo -r average`, then tile
and pack as before. Each step's time is logged.

Do not adopt the COG route now. Revisit it if raster builds become the
bottleneck with many layers, or if file size matters for hosting.

## Consequences

- A full-Canada 30 m raster at z2 to z12 builds in about 13 minutes on a
  16-CPU laptop (target: under 30), about 10 once its source is cached.
  Time scales with the CPUs given to Docker Desktop.
- `data/work/` is now a cache the pipeline writes (mounted by compose, at
  most one prepared file per source); deleting it costs one prepare step
  per raster layer on the next build.
- Lower zooms are rounded to whole grey levels per overview (at most 2 of
  255 from the exact share), not visible.
- The tiles step is the next thing to speed up if needed; the COG route
  roughly halves the build if a second source type becomes acceptable.
