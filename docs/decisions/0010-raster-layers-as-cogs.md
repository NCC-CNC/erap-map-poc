# Raster layers as one COG each, built in minutes

## Status

Accepted. Supersedes the storage and build steps of
0008-raster-layers.md: a raster layer is one Cloud Optimized GeoTIFF
(COG), `<layer>.cog.tif`, read by the browser, not PNG tiles in a
`.pmtiles` archive. The rest of 0008 stands: binary rasters only, the share
of each pixel covered as a grey level, coloured in the map by a
`color-relief` layer on a `raster-dem` source, display only. Vector layers
stay PMTiles (0002). The `LAYER_*` settings named below are now layer
file keys (`processing.minzoom`, `maxzoom` and `grey_levels`,
`source.srs` and `nodata`; ADR 0015).

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
their style is simple. A tile server is out of scope (CLAUDE.md), but a
static COG is not a server: nginx serves it with range requests like a
`.pmtiles` archive, and the browser reads the blocks of the current view
from the overview that matches the zoom.

All timings: a 16-CPU laptop, Docker Desktop with 16 CPUs and about 23 GB,
GDAL 3.13.3, source data on a Windows bind mount, scratch inside the
container.

## What made the build slow, and what fixed it

Measured on the agriculture layer, z2 to z12 (EPSG:3857 grid of 447,240 x
290,531 pixels at z12), first with the ADR 0008 steps kept:

| Step | ADR 0008 code | Measured fix | After |
| --- | --- | --- | --- |
| Read the strip source | warped directly: over 2 h, stopped | prepare once: `gdalbuildvrt` (nodata as 0) then `gdal_translate` to a tiled 512 x 512 ZSTD Byte GeoTIFF, `GDAL_NUM_THREADS=ALL_CPUS`; cached | 188 s, or 0 s from the cache |
| Warp to z12 | (from the prepared file) over 20 min, stopped, 1,460% CPU | the CPU went on ZSTD level 9 (GDAL's default) for the 130 gigapixel output: level 1 and `SPARSE_OK` | 258 s |
| Lower zooms | `gdalwarp -r average` to Float32, per zoom: 659 s | `gdaladdo -r average` on a 0/255 Byte z12 raster, multithreaded, its extent snapped to a coarse grid so each overview is one zoom's grid | 36 s |
| Tiles | 329 s (z12 alone 308 s), per zoom from each level | the same `gdal raster tile`, per zoom from each overview | 305 s |
| Pack | 12 s | unchanged | 12 s |

That gave 13 min 19 s for agriculture and 13 min 6 s for forest (0.52 and
3.24 GB of `.pmtiles`, 99,942 and 340,758 tiles). The tiles step was then
the largest and the least parallel (about 170% CPU, one PNG per tile).

A small warp test (828 megapixels of the prairies, 16 threads) shows the
compression effect: ZSTD level 9 11.1 s, level 1 2.6 s, LZW 3.0 s, Deflate
level 1 3.2 s, no compression 4.1 s (the bigger writes cost more than
level 1 compression).

The overviews round each level to a whole grey level, so lower zooms
differ from the exact Float32 average by at most 2 grey levels (of 255) at
z4 to z8, mean 0.3: not visible.

## PNG tiles or one COG

A prototype wrote the warped z12 raster and its overviews as one Web
Mercator COG per layer, served by nginx like the `.pmtiles`, and drew it
with `@geomatico/maplibre-cog-protocol` 0.10.0 through the same
`raster-dem` source and `color-relief` layer:

| | PMTiles (PNG tiles) | COG |
| --- | --- | --- |
| Build from the prepared source, agriculture | 611 s | 330 s (warp 222, overviews 38, COG copy 70) |
| File size, agriculture / forest | 0.52 / 3.24 GB | 0.38 / 2.27 GB |
| First draw, pan, zoom (headless Chromium, local nginx, 3 views, 2 runs) | 0.2 to 0.25 s, 0.07 to 0.13 s, 0.33 to 0.37 s | 0.27 to 0.34 s, 0.02 to 0.12 s, 0.32 to 0.35 s |
| Requests for the first draw, agriculture z6 | 25 (1.4 MB) | 18 (1.3 MB) |
| Look | reference | the same at z3, z6 and z10 |

The COG builds in about half the time (no PNG per tile, no packing), is
about 30% smaller, and draws the same at local network speed. The project
lead has used COGs for rasters before and chose them.

## Decision

Vector layers stay PMTiles. A raster layer is one COG,
`data/tiles/<layer>.cog.tif`, built by `pipeline/lib/raster.sh`:

1. Prepare each raster source once into a tiled 0/255 Byte GeoTIFF (255
   for 1, 0 for 0 and nodata, no nodata value) cached in
   `PIPELINE_WORK_DIR/raster` (`data/work/raster/`, keyed by the source's
   path, size and modification time, `LAYER_SOURCE_SRS` and
   `LAYER_NODATA`; an older file for the same source is removed).
2. Warp to EPSG:3857 at the max zoom's resolution with ZSTD level 1 and
   `SPARSE_OK`, over an extent snapped to the pixel grid of zoom
   `min(LAYER_MIN_ZOOM, LAYER_MAX_ZOOM - 14)`: each overview is then
   exactly one zoom's grid, and the COG's 256 px blocks are the map's
   tiles at the max zoom and the 6 below it. The padding is empty and
   costs nothing (empty blocks are not written). Amended (#83): the warp
   uses `-r near` only when the max zoom's pixel is no coarser on the
   ground than the source's, and `-r average` when it is (see Amendment
   below).
3. `gdaladdo -r average`, one overview per lower zoom.
4. `gdal_translate -of COG` (256 px blocks, ZSTD level 9 with
   `PREDICTOR=2`, the existing overviews, `SPARSE_OK`), checked (GDAL's
   `LAYOUT=COG`, EPSG:3857, one Byte band, one overview per lower zoom),
   then moved into place. A raster with no 1 cells fails the layer.

Pixel values stay grey levels, 0 to 255, with no scale: the protocol's
`#dem` mode encodes each value as a Terrain-RGB height in 0.1 m steps, so
values scaled to 0 to 1 would keep only 11 levels. The `color-relief`
ramp runs from transparent at 0 to the colour at 255.

The web app registers the `cog://` protocol and draws a raster entry as
`{"type": "raster-dem", "tileSize": 256, "url": "cog://<url>#dem"}`; the
library (pinned, 0.10.0) and its GeoTIFF decoders are a separate chunk,
loaded only when a COG layer exists. nginx and the dev server serve `.tif`
as `image/tiff` with range requests. The manifest entry has `format`
`cog` and a COG build report (`width`, `height`, `block_size`,
`overview_count`, per-zoom sizes) in place of tile counts.

A raster built before this (`.pmtiles`, `format` `png`) still shows (its
red channel read as the grey level), is `stale` in `--status`, and is
replaced, `.pmtiles` deleted, by its next build. `--remove` deletes both.

### Amendment: average when the max zoom is coarser than the source (#83)

The warp first used `-r near` at every max zoom. Lowering a raster's max
zoom to make a smaller COG (z10 for a web demo, say) then took one of
about 10 to 16 source cells per pixel, and thin features such as roads
and field edges broke into scattered dots, where the overviews of a z12
build (`-r average`) keep them as lighter lines. Now the warp averages
when the max zoom's pixel is coarser on the ground than the source's,
and keeps `-r near` otherwise. The ground size of the max zoom's pixel is
its EPSG:3857 resolution times the cosine of the latitude at the middle
of the source's extent; the source's pixel is read in its own CRS's units
(metres, or another linear unit converted; degrees for a geographic CRS
are converted on the WGS 84 equatorial radius), the larger side. A z12
build of 30 m Canada data (about 18 m on the ground) is unchanged: crisp
and 0/255, comparable with the source. A z10 forest build with averaging
matched the z10 overview of the z12 build near Ottawa and kept the
forest share (19.21% against 19.14% at full resolution; `near` gave
19.36%). Averaging at z12 instead would have added about 12% grey edge
pixels, which is why the method depends on the zoom.

The method is logged and recorded in the manifest entry (`resampling`).
A raster built before that has no `resampling`, was warped with `near`,
and is `stale` in `--status` if its max zoom would now average (the
source's header is read to tell); a z12 build of 30 m data stays
`current`.

### Amendment: optional fewer grey levels (#92)

Averaged shares compress much worse than 0/255: at z10 the forest COG was
757 MB and agriculture 143 MB, close to the 1 GB Pages limit (ADR 0014).
A raster setting, `LAYER_GREY_LEVELS` (2 to 256, default 256), reduces
every level of the COG, the max zoom and each overview, to that many
evenly spaced values, `round(k * 255 / (levels - 1))`. Each pixel takes
the nearest level, but any cover takes at least the first level above 0,
so sparse cover does not vanish at low zooms. The overviews are still
averaged from the full shares; only the COG copy is reduced, through a
VRT whose one ComplexSource has a `<LUT>` (bash and GDAL, no new
language). Its `<NODATA>0` skips the lookup for 0 pixels, most of a
sparse raster: the extra time was 1.1 s on a sparse 1.4 billion pixel
test raster with overviews, against about 8 ns a pixel for a plain LUT
(roughly 100 s at Canada z10) and about 200 s for the base level alone
with `gdal raster calc`. With 8 levels agriculture's z10 level went from
94 MB to 49 MB. 256 skips the step, so default builds are unchanged. The
manifest entry records `grey_levels`.

### Amendment: binary by majority at an averaged max zoom (#94)

With the warp averaging (#83), the max zoom level held the share of each
pixel covered. Zoomed in past the max zoom, where each pixel shows as a
square, partial shares were semi-transparent squares, which looked wrong:
at high zooms a pixel should be solid, on or off. Now, only when the warp
averages, the max zoom level of the COG is binary by majority: 255 where
the averaged share is at least half (128 of 255), else 0. This is stable
and has none of the speckle of nearest neighbour; thin features such as
roads are dropped at that level only. The overviews are unchanged: still
averaged by `gdaladdo` from the full-precision averaged max zoom, not
from the binary one, so roads and field edges stay as lighter lines when
zoomed out, and `LAYER_GREY_LEVELS` still reduces them (the max zoom is
binary anyway). A max zoom no coarser than the source (`-r near`) is
unchanged, byte for byte.

The COG copy reads a VRT: its base is a ComplexSource with a threshold
`<LUT>` and `<NODATA>0` (as #92), and each overview is an explicit
`<Overview>`, a VRT of the averaged raster opened at that overview level
(`OVERVIEW_LEVEL`), with the grey-level `<LUT>` if any. No extra file
and no extra pass: the COG copy reads each level once, as before. On a
sparse 32,768 x 32,768 test raster with 7 overviews the copy took 1.6 s
against 0.6 s without the VRT (the #92 VRT took 2.1 s); on a dense
16,384 px one it was no slower (3.2 s against 4.0 s: the binary base
compresses better). That suggests roughly 10 s extra at Canada z10
(about 9e9 pixels at the max zoom). The cover check before the copy
reads the averaged raster, so a layer whose cover is never half a max
zoom pixel still builds, with an all-0 max zoom and its cover in the
overviews.

The manifest entry records `max_zoom_values`: `majority` with
`resampling` `average`, `near` with `near`. A build with `resampling`
`average` and no `max_zoom_values` (built between #83 and this) has grey
levels at its max zoom and is `stale` in `--status`.

## Results

Full builds from the raw sources, both layers, with the prepared sources
already cached (`docker compose run --rm pipeline agriculture forest`):

| Layer | Warp | Overviews | COG | Total | COG size | Size at z12 |
| --- | --- | --- | --- | --- | --- | --- |
| agriculture | 221 s | 39 s | 71 s | 5 min 32 s | 0.38 GB | 458,752 x 311,296 px |
| forest | 196 s | 39 s | 211 s | 7 min 27 s | 2.27 GB | 409,600 x 262,144 px |

The first build of a source adds its prepare step, 188 s for agriculture
and 143 s for forest: about 8 min 40 s and 9 min 50 s in all, against 13
min 19 s and 13 min 6 s with PNG tiles and over an hour before. The
prepared files are 0.14 GB (agriculture) and 0.69 GB (forest) in
`data/work/raster/`. The container peaked at about 4.7 GiB of memory
(`docker stats`, during the warp). Both layers were checked in the map
(nginx, `206 Partial Content`, `image/tiff`) at z3, z6 and z10 on both
basemaps, and a `--style-only` colour change showed without touching the
COG.

## Consequences

- Only binary rasters are supported: one band holding 0, 1 and nodata.
  Categorical, continuous and multiband rasters are not supported yet:
  they would need a raster-kind setting (mode or nearest resampling for
  classes, average for continuous values, one layer per band for
  multiband) and are left for later.
- A full-Canada 30 m raster at z2 to z12 builds in about 9 to 10 minutes
  on a 16-CPU laptop the first time and 5 to 8 minutes after (target:
  well under 30), and time scales with the CPUs given to Docker Desktop.
  The warp is now the largest step; the forest COG copy (211 s, ZSTD level
  9) is next and could use a lower level if needed, at some size cost.
- The web app depends on `@geomatico/maplibre-cog-protocol`, a pre-1.0
  library, for raster layers. If it breaks with a MapLibre upgrade, the
  PNG route (0008) still works from the same warped raster and overviews.
- Two source types in the map and the data contract (PMTiles for vector,
  COG for raster), chosen from the manifest entry's `file`.
- `data/work/` is a cache the pipeline writes (mounted by compose, at
  most one prepared file per source); deleting it costs one prepare step
  per raster layer on the next build.
- Colour and opacity stay in the style: `--style-only`, no rebuild.
- `sqlite3` is no longer needed in the pipeline image.
