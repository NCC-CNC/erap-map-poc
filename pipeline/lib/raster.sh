#!/usr/bin/env bash
# Raster layers (LAYER_TYPE=raster, ADR 0008 and 0010): a binary raster (0,
# 1 and nodata, one band) as one Cloud Optimized GeoTIFF (COG) in Web
# Mercator, <layer>.cog.tif, whose pixel value is the share of it covered by
# 1 cells as a grey level (0 none, 255 all). nginx serves it with range
# requests like the .pmtiles archives; the web map reads it through the
# `cog://` protocol (@geomatico/maplibre-cog-protocol) as a `raster-dem`
# source and colours it with a `color-relief` layer, so the colour and
# opacity live in the style (from <layer>.style.json) and changing them
# needs no rebuild. Display only: no pop-up. Categorical, continuous and
# multiband rasters are not supported.
#
#   1. prepare (once per source, cached): the source as an internally
#      tiled, compressed Byte GeoTIFF in its own CRS and grid, 255 where
#      the source is 1 and 0 for 0 and nodata (the source is expected to
#      hold only 0, 1 and nodata), with no nodata value: the grey level of
#      full cover, so later steps need no scaling. One read of the source,
#      in order, which is what a strip-layout source (1-row blocks, often
#      Float32) needs: warping it directly re-decodes each strip for every
#      warp window and took over 2 hours for a Canada-wide 30 m file. The
#      prepared file is kept in the work dir (PIPELINE_WORK_DIR/raster),
#      keyed by the source's path, size and modification time and the
#      layer's LAYER_SOURCE_SRS and LAYER_NODATA, so a rebuild (another zoom
#      range, a code change) skips it. See raster_source.
#   2. warp: gdalwarp the prepared file to EPSG:3857 at the max zoom's
#      resolution, multithreaded (-multi and NUM_THREADS; a tiled input
#      reads fast in any order), over an extent snapped to a coarse pixel
#      grid (raster_snap_zoom), so each overview below is exactly one
#      zoom's grid and the 256 px blocks of the top zooms are map tiles.
#   3. overviews: gdaladdo -r average, multithreaded, one per lower zoom,
#      each averaging 2 x 2 pixels of the one above: the share covered, in
#      256 grey levels.
#   4. COG: gdal_translate -of COG copies the raster and its overviews into
#      the COG layout (256 px blocks, ZSTD with a predictor, empty blocks
#      not written), checked (raster_check_cog), then moved into place.
#
# Averaging in overviews with no nodata keeps the share. Each overview
# rounds to a whole grey level, so a low zoom can be a level or two off the
# exact share, which does not show. The values stay grey levels, not 0 to
# 1: the map's `cog://...#dem` source encodes them as Terrain-RGB heights
# in 0.1 m steps, so 0 to 1 would keep only 11 levels.
#
# The intermediates are ZSTD level 1: the default (9) made the warp four
# times slower. Full-Canada timings are in ADR 0010.
#
# Intermediates of steps 2 and 3 live in the per-run scratch dir (under
# TMPDIR) and go once the COG is written. The COG is written to a hidden
# temp file in the output dir and renamed into place, so a failed build
# keeps the previous one. Prepared sources (step 1) are written the same
# way (temp file, then rename) and stay in the work dir until their source
# changes; delete PIPELINE_WORK_DIR/raster to reclaim the space.

# Width of the z0 tile in EPSG:3857 metres (2 * pi * 6378137).
RASTER_WORLD_M=40075016.68557849

# Bump when the prepare step's output changes, so cached files are remade.
RASTER_PREPARE_VERSION=1

# raster_resolution ZOOM: EPSG:3857 metres per pixel of a 256 px tile at ZOOM.
raster_resolution() {
  awk -v z="$1" -v w="$RASTER_WORLD_M" 'BEGIN { printf "%.10f\n", w / 256 / 2 ^ z }'
}

# raster_source_file DATASET: the local file behind DATASET (the zip for a
# /vsizip/ path), whose size and modification time key the cache. Prints
# nothing for other /vsi paths, which are not cached.
raster_source_file() {
  local dataset=$1
  if [[ $dataset =~ ^/vsizip/(.*[.][Zz][Ii][Pp])(/.*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $dataset != /vsi* ]]; then
    printf '%s\n' "$dataset"
  fi
}

# raster_source_key DATASET SOURCE_SRS NODATA: print the cache key of a
# prepared source as compact JSON: the prepare version, the dataset path,
# the size and modification time (seconds) of its file, and the settings
# that change the prepared values. Returns 1 for a dataset that cannot be
# cached (a /vsi path other than /vsizip/).
raster_source_key() {
  local dataset=$1 src_srs=$2 nodata=$3 file size mtime
  file=$(raster_source_file "$dataset")
  [[ -n $file ]] || return 1
  read -r size mtime < <(stat -c '%s %Y' "$file") || return 1
  jq -nc --argjson v "$RASTER_PREPARE_VERSION" --arg path "$dataset" \
    --argjson size "$size" --argjson mtime "$mtime" \
    --arg srs "$src_srs" --arg nodata "$nodata" \
    '{version: $v, path: $path, size: $size, mtime: $mtime, source_srs: $srs, nodata: $nodata}'
}

# _raster_hash TEXT: the first 16 hex digits of TEXT's SHA-256.
_raster_hash() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

# raster_source DATASET SOURCE_SRS NODATA CACHE_DIR SCRATCH: print the path
# of DATASET prepared (step 1 at the top of this file), making it if needed.
# The file is CACHE_DIR/<path hash>-<key hash>.tif, with its key beside it
# as .json; older files for the same path are removed once the new one is
# in place. An empty CACHE_DIR, or a dataset that cannot be keyed, prepares
# into SCRATCH instead (not kept). SOURCE_SRS and NODATA may be empty to
# use what the source declares.
raster_source() {
  local dataset=$1 src_srs=$2 nodata=$3 cache=$4 scratch=$5
  local key="" dir=$scratch stem=prepared
  if [[ -n $cache ]] && key=$(raster_source_key "$dataset" "$src_srs" "$nodata"); then
    dir=$cache
    stem="$(_raster_hash "$dataset")-$(_raster_hash "$key")"
    if [[ -f "${dir}/${stem}.tif" ]]; then
      log_info "prepared source cached: ${dir}/${stem}.tif"
      printf '%s\n' "${dir}/${stem}.tif"
      return 0
    fi
    mkdir -p "$dir" || die "cannot create $dir"
    [[ -w $dir ]] || die "work dir not writable: $dir"
  else
    key=""
  fi

  # A ComplexSource with the source's nodata (or LAYER_NODATA) under a VRT
  # band with none: nodata cells are not written, so they read as 0.
  local vrt="${scratch}/${stem}.vrt" opts=(-vrtnodata None)
  [[ -z $src_srs ]] || opts+=(-a_srs "$src_srs")
  [[ -z $nodata ]] || opts+=(-srcnodata "$nodata")
  gdalbuildvrt -q "${opts[@]}" "$vrt" "$dataset" >/dev/null \
    || die "cannot read $dataset"

  log_info "preparing $dataset (tiled 0/255 Byte, once per source)"
  _RASTER_SOURCE_TMP="${dir}/.${stem}.$$.tmp.tif"
  trap 'rm -f "${_RASTER_SOURCE_TMP:-}"' EXIT
  # GDAL_NUM_THREADS decodes the source's blocks in parallel. 1 becomes 255
  # (scaling in a VRT at the warp instead made the warp 16% slower).
  GDAL_NUM_THREADS=ALL_CPUS gdal_translate -q -ot Byte -scale 0 1 0 255 \
    -a_nodata none \
    -co TILED=YES -co BLOCKXSIZE=512 -co BLOCKYSIZE=512 \
    -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$vrt" "$_RASTER_SOURCE_TMP" >/dev/null \
    || die "cannot prepare $dataset"
  rm -f "$vrt"

  local final="${dir}/${stem}.tif"
  [[ -z $key ]] || printf '%s\n' "$key" >"${dir}/${stem}.json"
  mv -f "$_RASTER_SOURCE_TMP" "$final" || die "cannot write $final"
  _RASTER_SOURCE_TMP=""
  if [[ -n $key ]]; then
    local old
    for old in "${dir}/${stem%%-*}"-*; do
      [[ -e $old && $old != "${dir}/${stem}".* ]] || continue
      rm -f "$old"
    done
  fi
  printf '%s\n' "$final"
}

# raster_warp PREPARED SNAP_ZOOM MAX_ZOOM OUT: write OUT, PREPARED (0/255,
# no nodata) in EPSG:3857 at MAX_ZOOM's resolution, Byte, no nodata. The
# extent is snapped outwards to SNAP_ZOOM's pixel grid (on the tile grid;
# raster_snap_zoom), so its width and height are multiples of
# 2^(MAX_ZOOM - SNAP_ZOOM) and every overview raster_overviews builds down
# to SNAP_ZOOM is exactly one zoom's pixel grid.
raster_warp() {
  local input=$1 snapzoom=$2 maxzoom=$3 out=$4
  local res coarse grid="${out%.*}.grid.vrt" te
  res=$(raster_resolution "$maxzoom")
  coarse=$(raster_resolution "$snapzoom")
  # The EPSG:3857 extent on SNAP_ZOOM's grid: -tap snaps to multiples of the
  # resolution, and the tile grid's origin is a whole number of pixels
  # from 0 at every zoom. A VRT, so no pixels are computed.
  gdalwarp -q -overwrite -of VRT -t_srs EPSG:3857 -tr "$coarse" "$coarse" -tap \
    "$input" "$grid" >/dev/null || die "cannot read the extent of $input"
  te=$(gdalinfo -json "$grid" | jq -er '.cornerCoordinates
    | "\(.upperLeft[0]) \(.lowerRight[1]) \(.lowerRight[0]) \(.upperLeft[1])"') \
    || die "cannot read the extent of $input"
  rm -f "$grid"

  # -r near: no new values. Cells outside the source keep INIT_DEST=0, and
  # -dstnodata None leaves 0 a value, which the overviews average. ZSTD
  # level 1 and SPARSE_OK (empty blocks not written): the default level 9
  # took four times as long as the warp itself.
  log_info "warping to EPSG:3857 (z${maxzoom} resolution)"
  # shellcheck disable=SC2086 # te is four numbers.
  gdalwarp -q -overwrite -srcnodata None -t_srs EPSG:3857 -te $te -tr "$res" "$res" \
    -r near -ot Byte -dstnodata None -wo INIT_DEST=0 \
    -multi -wo NUM_THREADS=ALL_CPUS -wm 1024 \
    -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 \
    -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co SPARSE_OK=TRUE \
    -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$input" "$out" \
    || die "gdalwarp failed for $input"
}

# raster_overviews RASTER LEVELS: add LEVELS overviews to RASTER (factors 2,
# 4, ...), each the average of the one above, so a pixel's grey level is
# the share of it covered. No nodata, so 0 counts in the average.
raster_overviews() {
  local raster=$1 levels=$2 factors=() i
  ((levels > 0)) || return 0
  for ((i = 1; i <= levels; i++)); do factors+=($((1 << i))); done
  GDAL_NUM_THREADS=ALL_CPUS COMPRESS_OVERVIEW=ZSTD ZSTD_LEVEL_OVERVIEW=1 \
    SPARSE_OK_OVERVIEW=YES BIGTIFF_OVERVIEW=IF_SAFER \
    gdaladdo -q -r average "$raster" "${factors[@]}" >/dev/null \
    || die "cannot build the overviews of $raster"
}


# raster_snap_zoom MIN_ZOOM MAX_ZOOM: the zoom whose pixel grid the warped
# extent is snapped to: at most MIN_ZOOM, so every overview down to it is
# exactly one zoom's grid, and at most MAX_ZOOM - 14, so the 256 px blocks
# of the max zoom and the 6 zooms below it are the map's tiles (a block at
# zoom z is one pixel at z - 8). Below that a map tile reads a few blocks.
raster_snap_zoom() {
  local minzoom=$1 snap=$(($2 - 14))
  if ((minzoom < snap)); then snap=$minzoom; fi
  printf '%s\n' "$snap"
}

# raster_cog RASTER OUT: copy RASTER and its overviews to OUT as a COG: 256
# px blocks, ZSTD with the horizontal predictor (level 9: the COG is written
# once and read many times), empty blocks not written, no statistics.
raster_cog() {
  local raster=$1 out=$2
  GDAL_NUM_THREADS=ALL_CPUS gdal_translate -q -of COG \
    -co BLOCKSIZE=256 -co COMPRESS=ZSTD -co LEVEL=9 -co PREDICTOR=2 \
    -co OVERVIEWS=FORCE_USE_EXISTING -co SPARSE_OK=TRUE -co NUM_THREADS=ALL_CPUS \
    -co BIGTIFF=IF_SAFER -co STATISTICS=NO \
    "$raster" "$out" >/dev/null \
    || die "cannot write the COG $out"
}

# raster_check_cog COG LEVELS: fail unless COG is a COG (GDAL's LAYOUT=COG)
# in EPSG:3857, one Byte band in 256 px blocks, with LEVELS overviews.
raster_check_cog() {
  local cog=$1 levels=$2
  gdalinfo -json "$cog" | jq -e --argjson levels "$levels" '
    .metadata.IMAGE_STRUCTURE.LAYOUT == "COG"
    and (.stac["proj:epsg"] == 3857 or .stac["proj:code"] == "EPSG:3857")
    and (.bands | length) == 1
    and .bands[0].type == "Byte" and .bands[0].block == [256, 256]
    and ((.bands[0].overviews // []) | length) == $levels' >/dev/null \
    || die "not a valid COG: $cog"
}

# raster_has_cover RASTER LEVELS PREPARED: succeed if there is any cover. The
# smallest overview (LEVELS, of RASTER) answers it quickly; when that is all
# 0, which a few covered cells can round to, the full-resolution PREPARED
# source is read to be sure.
raster_has_cover() {
  local raster=$1 levels=$2 prepared=$3 info opts=()
  ((levels == 0)) || opts=(-oo "OVERVIEW_LEVEL=$((levels - 1))")
  info=$(gdalinfo -json -mm "${opts[@]}" "$raster") || die "cannot read $raster"
  jq -e '(.bands[0].computedMax // 0) > 0' <<<"$info" >/dev/null && return 0
  info=$(gdalinfo -json -mm "$prepared") || die "cannot read $prepared"
  jq -e '(.bands[0].computedMax // 0) > 0' <<<"$info" >/dev/null
}

# raster_report COG MIN_ZOOM MAX_ZOOM: print the raster build report as
# compact JSON: {width, height, block_size, overview_count, zooms: [{zoom,
# width, height}]}, one zoom per level from the max zoom down.
raster_report() {
  local cog=$1 minzoom=$2 maxzoom=$3
  gdalinfo -json "$cog" | jq -c --argjson max "$maxzoom" --argjson min "$minzoom" '
    ([{size: .size}] + (.bands[0].overviews // [])) as $levels
    | {width: .size[0], height: .size[1], block_size: .bands[0].block[0],
       overview_count: (($levels | length) - 1),
       zooms: [range(0; $max - $min + 1) as $i
               | {zoom: ($max - $i), width: $levels[$i].size[0], height: $levels[$i].size[1]}]}' \
    || die "cannot read $cog"
}

# raster_header PREPARED MIN_ZOOM MAX_ZOOM: print the archive fields of a
# raster layer's manifest entry (the ones a PMTiles header gives a vector
# layer) as compact JSON: {tile_type: "cog", minzoom, maxzoom, bounds,
# center}. bounds are the PREPARED source's extent in EPSG:4326 (the COG's
# own extent is padded to the snapping grid); center is its middle at
# MIN_ZOOM.
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
# the build report (raster_report) to REPORT and the manifest's archive
# fields (raster_header) to HEADER. CACHE_DIR holds prepared sources
# (raster_source); empty or absent, nothing is cached.
build_raster_tiles() {
  local layer=$1 input=$2 src_srs=$3 nodata=$4 minzoom=$5 maxzoom=$6
  local out_dir=$7 tmp=$8 report=$9 header=${10} cache=${11:-}
  local dataset step=$SECONDS
  dataset=$(gdal_input_path "$input") || exit 1

  local levels=$((maxzoom - minzoom)) warped="${tmp}/${layer}.z${maxzoom}.tif"
  local source
  source=$(raster_source "$dataset" "$src_srs" "$nodata" "$cache" "$tmp") || exit 1
  log_info "prepare: $((SECONDS - step)) s"
  raster_header "$source" "$minzoom" "$maxzoom" >"$header"

  step=$SECONDS
  raster_warp "$source" "$(raster_snap_zoom "$minzoom" "$maxzoom")" "$maxzoom" "$warped"
  log_info "warp: $((SECONDS - step)) s"

  step=$SECONDS
  raster_overviews "$warped" "$levels"
  log_info "overviews: $((SECONDS - step)) s"

  raster_has_cover "$warped" "$levels" "$source" \
    || die "no cover: no 1 cells in $input"
  [[ -n $cache && $source == "${cache}"/* ]] || rm -f "$source"

  step=$SECONDS
  local final="${out_dir}/${layer}.cog.tif"
  _BUILD_TILES_TMP="${out_dir}/.${layer}.$$.tmp.cog.tif"
  trap 'rm -f "${_BUILD_TILES_TMP:-}"' EXIT
  rm -f "$_BUILD_TILES_TMP"
  raster_cog "$warped" "$_BUILD_TILES_TMP"
  rm -f "$warped"
  raster_check_cog "$_BUILD_TILES_TMP" "$levels"
  raster_report "$_BUILD_TILES_TMP" "$minzoom" "$maxzoom" >"$report"
  mv -f "$_BUILD_TILES_TMP" "$final"
  _BUILD_TILES_TMP=""
  log_info "cog: $((SECONDS - step)) s"
  log_info "wrote $final"
}
