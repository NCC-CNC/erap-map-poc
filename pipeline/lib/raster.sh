#!/usr/bin/env bash
# Raster layers (the raster profile, ADR 0008 and 0010): a binary raster (0,
# 1 and nodata, one band) as one Cloud Optimized GeoTIFF (COG) in Web
# Mercator, <layer>.cog.tif, whose pixel value is the share of it covered by
# 1 cells as a grey level (0 none, 255 all). nginx serves it with range
# requests like the .pmtiles archives; the web map reads it through the
# `cog://` protocol (@geomatico/maplibre-cog-protocol) as a `raster-dem`
# source and colours it with a `color-relief` layer, so the colour and
# opacity live in the style (from the layer file's display) and changing them
# needs no rebuild. Display only: no pop-up. Categorical, continuous and
# multiband rasters are not supported.
#
# Plain GDAL, in three steps (#140):
#
#   1. prepare (raster_source): the source as an internally tiled Byte
#      GeoTIFF in its own CRS, 255 where it is 1 and 0 for 0 and nodata,
#      with no nodata value. Why not warp the source directly: a
#      strip-layout source (1-row blocks, often Float32) is re-decoded for
#      every warp window, over 2 hours for a Canada-wide 30 m file, where
#      this one read in order takes about 3 minutes. 255 with no nodata is
#      what makes GDAL's average overviews the share covered (its average
#      skips nodata). The prepared file is kept in the work dir
#      (PIPELINE_WORK_DIR/raster), one per layer, with the source's path,
#      size and modification time and the layer's source.srs and
#      source.nodata beside it, so a rebuild (another zoom range, the
#      Pages copy) skips this step.
#   2. warp (raster_warp): gdalwarp to EPSG:3857 at the max zoom's
#      resolution, over GDAL's own suggested extent widened to whole map
#      tiles (raster_extent), multithreaded, ZSTD level 1. The method
#      (raster_method) is nearest when the max zoom's pixel is no larger
#      than the source's (GDAL's suggested EPSG:3857 resolution), so a z12
#      build of 30 m data is 0/255 like the source; mode (the majority)
#      when it is larger, so a z10 build is solid, on or off, past its max
#      zoom, without the dots nearest neighbour makes of thin lines. Why
#      not let the COG driver warp (TILING_SCHEME alone): its warp writes
#      a temporary file with ZSTD level 9, which cannot be changed, and
#      took about twice as long. On whole tiles the COG driver skips it.
#   3. COG (raster_cog): gdal_translate -of COG with
#      TILING_SCHEME=GoogleMapsCompatible at the max zoom, one overview per
#      lower zoom by GDAL's average resampling (the share covered, as grey
#      levels), ZSTD, empty blocks not written. No predictor: on these
#      values it made the COG about 14% larger. The temporary overviews are
#      LZW (COG_TMP_COMPRESSION), faster than the ZSTD default. Then a
#      cover check (raster_has_cover: GDAL writes an empty COG without
#      complaint), and the COG is moved into place.
#
# The values stay grey levels, not 0 to 1: the map's `cog://...#dem` source
# encodes them as Terrain-RGB heights in 0.1 m steps, so 0 to 1 would keep
# only 11 levels.
#
# The warped raster lives in the per-run scratch dir (under TMPDIR; also
# CPL_TMPDIR, for the COG driver's temporary files) and goes once the COG
# is written. The COG is written to a hidden temp file in the output dir
# and renamed into place, so a failed build keeps the previous one.
# Prepared sources are written the same way and stay in the work dir until
# their source changes; delete PIPELINE_WORK_DIR/raster to reclaim the
# space.

# Width of the z0 tile in EPSG:3857 metres (2 * pi * 6378137).
RASTER_WORLD_M=40075016.68557849

# Bump when the prepare step's output changes, so cached files are remade.
RASTER_PREPARE_VERSION=1

# raster_resolution ZOOM: EPSG:3857 metres per pixel of a 256 px tile at ZOOM.
raster_resolution() {
  awk -v z="$1" -v w="$RASTER_WORLD_M" 'BEGIN { printf "%.10f\n", w / 256 / 2 ^ z }'
}

# raster_source_key DATASET SOURCE_SRS NODATA: print the cache key of a
# prepared source as compact JSON: the prepare version, the dataset path,
# the size and modification time (seconds) of its file (the zip for a
# /vsizip/ path), and the settings that change the prepared values. Returns
# 1 for a dataset that cannot be keyed (another /vsi path).
raster_source_key() {
  local dataset=$1 src_srs=$2 nodata=$3 file=$1 size mtime
  if [[ $dataset =~ ^/vsizip/(.*[.][Zz][Ii][Pp])(/.*)?$ ]]; then
    file=${BASH_REMATCH[1]}
  elif [[ $dataset == /vsi* ]]; then
    return 1
  fi
  read -r size mtime < <(stat -c '%s %Y' "$file") || return 1
  jq -nc --argjson v "$RASTER_PREPARE_VERSION" --arg path "$dataset" \
    --argjson size "$size" --argjson mtime "$mtime" \
    --arg srs "$src_srs" --arg nodata "$nodata" \
    '{version: $v, path: $path, size: $size, mtime: $mtime, source_srs: $srs, nodata: $nodata}'
}

# raster_source LAYER DATASET SOURCE_SRS NODATA CACHE_DIR SCRATCH: print the
# path of DATASET prepared (step 1 at the top of this file), making it if
# needed. The file is CACHE_DIR/LAYER.tif, with its key (raster_source_key)
# beside it as LAYER.json; it is reused while the key is the same. An empty
# CACHE_DIR, or a dataset that cannot be keyed, prepares into SCRATCH
# instead (not kept). SOURCE_SRS and NODATA may be empty to use what the
# source declares.
raster_source() {
  local layer=$1 dataset=$2 src_srs=$3 nodata=$4 cache=$5 scratch=$6
  local key="" dir=$scratch
  if [[ -n $cache ]] && key=$(raster_source_key "$dataset" "$src_srs" "$nodata"); then
    dir=$cache
    if [[ -f "${dir}/${layer}.tif" && $(cat "${dir}/${layer}.json" 2>/dev/null) == "$key" ]]; then
      log_info "prepared source cached: ${dir}/${layer}.tif"
      printf '%s\n' "${dir}/${layer}.tif"
      return 0
    fi
    mkdir -p "$dir" || die "cannot create $dir"
    [[ -w $dir ]] || die "work dir not writable: $dir"
  else
    key=""
  fi

  # A ComplexSource with the source's nodata (or source.nodata) under a VRT
  # band with none: nodata cells are not written, so they read as 0.
  local vrt="${scratch}/${layer}.prepare.vrt" opts=(-vrtnodata None)
  [[ -z $src_srs ]] || opts+=(-a_srs "$src_srs")
  [[ -z $nodata ]] || opts+=(-srcnodata "$nodata")
  gdalbuildvrt -q "${opts[@]}" "$vrt" "$dataset" >/dev/null \
    || die "cannot read $dataset"

  log_info "preparing $dataset (tiled 0/255 Byte, once per source)"
  _RASTER_SOURCE_TMP="${dir}/.${layer}.$$.tmp.tif"
  trap 'rm -f "${_RASTER_SOURCE_TMP:-}"' EXIT
  # GDAL_NUM_THREADS decodes the source's blocks in parallel. 1 becomes 255.
  GDAL_NUM_THREADS=ALL_CPUS gdal_translate -q -ot Byte -scale 0 1 0 255 \
    -a_nodata none \
    -co TILED=YES -co BLOCKXSIZE=512 -co BLOCKYSIZE=512 \
    -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$vrt" "$_RASTER_SOURCE_TMP" >/dev/null \
    || die "cannot prepare $dataset"
  rm -f "$vrt"

  local final="${dir}/${layer}.tif"
  rm -f "${dir}/${layer}.json"
  mv -f "$_RASTER_SOURCE_TMP" "$final" || die "cannot write $final"
  _RASTER_SOURCE_TMP=""
  if [[ -n $key ]]; then printf '%s\n' "$key" >"${dir}/${layer}.json"; fi
  printf '%s\n' "$final"
}

# raster_suggested PREPARED SCRATCH: print GDAL's suggested EPSG:3857 grid
# for PREPARED (what gdalwarp makes with no -tr or -te) as `RES XMIN YMIN
# XMAX YMAX`: RES is the source's pixel size in EPSG:3857 metres. A VRT in
# SCRATCH, so no pixels are computed.
raster_suggested() {
  local vrt="${2}/suggested.vrt" grid
  gdalwarp -q -overwrite -of VRT -t_srs EPSG:3857 "$1" "$vrt" >/dev/null \
    || die "cannot read the extent of $1"
  grid=$(gdalinfo -json "$vrt" | jq -er '.geoTransform as $g | .size as $s
    | "\($g[1]) \($g[0]) \($g[3] + $s[1] * $g[5]) \($g[0] + $s[0] * $g[1]) \($g[3])"') \
    || die "cannot read the extent of $1"
  rm -f "$vrt"
  printf '%s\n' "$grid"
}

# raster_method SOURCE_RES MAX_ZOOM: print the warp's method: `near` when
# MAX_ZOOM's resolution is no coarser than SOURCE_RES (the source's pixel in
# EPSG:3857 metres, raster_suggested), `mode` when it is.
raster_method() {
  awk -v src="$1" -v res="$(raster_resolution "$2")" \
    'BEGIN { print (res > src ? "mode" : "near") }'
}

# raster_extent MAX_ZOOM XMIN YMIN XMAX YMAX: print the EPSG:3857 extent
# widened to whole map tiles (256 px) at MAX_ZOOM, as gdalwarp's -te: the
# grid of the COG's TILING_SCHEME, so the COG driver does not warp again.
raster_extent() {
  awk -v z="$1" -v w="$RASTER_WORLD_M" -v x0="$2" -v y0="$3" -v x1="$4" -v y1="$5" '
    function floor(v) { return (v == int(v) || v > 0) ? int(v) : int(v) - 1 }
    function ceil(v) { return -floor(-v) }
    BEGIN {
      o = w / 2; t = w / 2 ^ z; e = 1e-6
      printf "%.10f %.10f %.10f %.10f\n", floor((x0 + o) / t + e) * t - o,
        o - ceil((o - y0) / t - e) * t, ceil((x1 + o) / t - e) * t - o,
        o - floor((o - y1) / t + e) * t
    }'
}

# raster_warp PREPARED MAX_ZOOM METHOD OUT XMIN YMIN XMAX YMAX: write OUT,
# PREPARED (0/255, no nodata) in EPSG:3857 at MAX_ZOOM's resolution over
# the extent (raster_extent), Byte, no nodata, resampled with METHOD (near
# or mode; raster_method). Cells outside the source are 0. ZSTD level 1 and
# SPARSE_OK (empty blocks not written): level 9 took four times as long.
raster_warp() {
  local input=$1 maxzoom=$2 method=$3 out=$4 res
  shift 4
  res=$(raster_resolution "$maxzoom")
  log_info "warping to EPSG:3857 (z${maxzoom} resolution, -r ${method})"
  gdalwarp -q -overwrite -t_srs EPSG:3857 -te "$@" -tr "$res" "$res" \
    -r "$method" -ot Byte -dstnodata None -wo INIT_DEST=0 \
    -multi -wo NUM_THREADS=ALL_CPUS -wm 1024 \
    -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 \
    -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co SPARSE_OK=TRUE \
    -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$input" "$out" \
    || die "gdalwarp failed for $input"
}

# raster_cog RASTER MAX_ZOOM LEVELS OUT TMP_DIR: write RASTER (raster_warp)
# to OUT as a COG on the GoogleMapsCompatible tiling scheme at MAX_ZOOM,
# with LEVELS overviews averaged by GDAL (the share covered), ZSTD, empty
# blocks not written, no statistics. The COG driver's temporary files go
# in TMP_DIR.
raster_cog() {
  local raster=$1 maxzoom=$2 levels=$3 out=$4 tmp=$5
  CPL_TMPDIR=$tmp COG_TMP_COMPRESSION=LZW GDAL_NUM_THREADS=ALL_CPUS \
    gdal_translate -q -of COG \
    -co TILING_SCHEME=GoogleMapsCompatible -co ZOOM_LEVEL="$maxzoom" \
    -co OVERVIEW_RESAMPLING=AVERAGE -co OVERVIEW_COUNT="$levels" -co ADD_ALPHA=NO \
    -co COMPRESS=ZSTD -co SPARSE_OK=TRUE -co NUM_THREADS=ALL_CPUS \
    -co BIGTIFF=IF_SAFER -co STATISTICS=NO \
    "$raster" "$out" >/dev/null \
    || die "cannot write the COG $out"
}

# raster_has_cover COG PREPARED: succeed if there is any cover. COG's
# smallest overview answers it quickly; when that is all 0, which a few
# covered cells can round to, the full-resolution PREPARED source is read
# to be sure.
raster_has_cover() {
  local cog=$1 prepared=$2 info levels opts=()
  info=$(gdalinfo -json "$cog") || die "cannot read $cog"
  levels=$(jq '.bands[0].overviews // [] | length' <<<"$info")
  ((levels == 0)) || opts=(-oo "OVERVIEW_LEVEL=$((levels - 1))")
  info=$(gdalinfo -json -mm "${opts[@]}" "$cog") || die "cannot read $cog"
  jq -e '(.bands[0].computedMax // 0) > 0' <<<"$info" >/dev/null && return 0
  info=$(gdalinfo -json -mm "$prepared") || die "cannot read $prepared"
  jq -e '(.bands[0].computedMax // 0) > 0' <<<"$info" >/dev/null
}

# raster_report COG MAX_ZOOM RESAMPLING: print the raster build report as
# compact JSON: {width, height, block_size, overview_count, resampling,
# zooms: [{zoom, width, height}]}, one zoom per level from the max zoom
# down. RESAMPLING is the warp's method (near or mode).
raster_report() {
  local cog=$1 maxzoom=$2 resampling=$3
  gdalinfo -json "$cog" | jq -c --argjson max "$maxzoom" --arg resampling "$resampling" '
    ([{size: .size}] + (.bands[0].overviews // [])) as $levels
    | {width: .size[0], height: .size[1], block_size: .bands[0].block[0],
       overview_count: (($levels | length) - 1), resampling: $resampling,
       zooms: [range(0; $levels | length) as $i
               | {zoom: ($max - $i), width: $levels[$i].size[0], height: $levels[$i].size[1]}]}' \
    || die "cannot read $cog"
}

# raster_header PREPARED MIN_ZOOM MAX_ZOOM: print the archive fields of a
# raster layer's build.json entry (the ones a PMTiles header gives a vector
# layer) as compact JSON: {tile_type: "cog", minzoom, maxzoom, bounds,
# center}. bounds are the PREPARED source's extent in EPSG:4326 (the COG's
# own extent is padded to whole tiles); center is its middle at MIN_ZOOM.
raster_header() {
  local prepared=$1 minzoom=$2 maxzoom=$3
  gdalinfo -json "$prepared" | jq -c --argjson min "$minzoom" --argjson max "$maxzoom" '
    .wgs84Extent.coordinates[0]
    | [(map(.[0]) | min), (map(.[1]) | min), (map(.[0]) | max), (map(.[1]) | max)]
    | map(. * 1e7 | round / 1e7) as $b
    | {tile_type: "cog", minzoom: $min, maxzoom: $max, bounds: $b,
       center: [(($b[0] + $b[2]) / 2 * 1e7 | round / 1e7),
                (($b[1] + $b[3]) / 2 * 1e7 | round / 1e7), $min]}' \
    || die "cannot read the extent of $prepared"
}

# build_raster_tiles LAYER INPUT SOURCE_SRS NODATA MIN_ZOOM MAX_ZOOM OUT_DIR TMP_DIR REPORT HEADER [CACHE_DIR]
# Build OUT_DIR/LAYER.cog.tif from INPUT (see the top of this file), write
# the build report (raster_report) to REPORT and build.json's archive
# fields (raster_header) to HEADER. CACHE_DIR holds prepared sources
# (raster_source); empty or absent, nothing is cached.
build_raster_tiles() {
  local layer=$1 input=$2 src_srs=$3 nodata=$4 minzoom=$5 maxzoom=$6
  local out_dir=$7 tmp=$8 report=$9 header=${10} cache=${11:-}
  local dataset step=$SECONDS
  dataset=$(gdal_input_path "$input") || exit 1

  local source
  source=$(raster_source "$layer" "$dataset" "$src_srs" "$nodata" "$cache" "$tmp") || exit 1
  log_info "prepare: $((SECONDS - step)) s"
  raster_header "$source" "$minzoom" "$maxzoom" >"$header"

  local grid method extent
  grid=$(raster_suggested "$source" "$tmp") || exit 1
  read -r -a grid <<<"$grid"
  method=$(raster_method "${grid[0]}" "$maxzoom")
  extent=$(raster_extent "$maxzoom" "${grid[@]:1}")
  log_info "resampling ${method}: a z${maxzoom} pixel is $(raster_resolution "$maxzoom") m," \
    "a source pixel ${grid[0]} m (EPSG:3857)"

  step=$SECONDS
  local warped="${tmp}/${layer}.z${maxzoom}.tif"
  # shellcheck disable=SC2086 # extent is four numbers.
  raster_warp "$source" "$maxzoom" "$method" "$warped" $extent
  log_info "warp: $((SECONDS - step)) s"

  step=$SECONDS
  local final="${out_dir}/${layer}.cog.tif"
  _BUILD_TILES_TMP="${out_dir}/.${layer}.$$.tmp.cog.tif"
  trap 'rm -f "${_BUILD_TILES_TMP:-}"' EXIT
  rm -f "$_BUILD_TILES_TMP"
  raster_cog "$warped" "$maxzoom" "$((maxzoom - minzoom))" "$_BUILD_TILES_TMP" "$tmp"
  rm -f "$warped"
  raster_has_cover "$_BUILD_TILES_TMP" "$source" \
    || die "no cover: no 1 cells in $input"
  [[ -n $cache && $source == "${cache}"/* ]] || rm -f "$source"
  raster_report "$_BUILD_TILES_TMP" "$maxzoom" "$method" >"$report"
  mv -f "$_BUILD_TILES_TMP" "$final"
  _BUILD_TILES_TMP=""
  log_info "cog: $((SECONDS - step)) s"
  log_info "wrote $final"
}
