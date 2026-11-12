#!/usr/bin/env bash
# Raster layers (LAYER_TYPE=raster, ADR 0008): a binary raster as grey PNG
# tiles in a .pmtiles archive, where a pixel's grey level is the share of it
# covered by 1 cells (0 none, 255 all). The web map reads them through a
# MapLibre `raster-dem` source and colours them with a `color-relief` layer,
# so the colour and opacity live in the style (from <layer>.style.json) and
# changing them needs no re-tiling. Display only: no pop-up.
#
#   1. prepare (once per source, cached): the source as an internally
#      tiled, compressed Byte GeoTIFF in its own CRS and grid, 1 where the
#      source is 1 and 0 for 0 and nodata (the source is expected to hold
#      only 0, 1 and nodata), with no nodata value. One read of the source,
#      in order, which is what a strip-layout source (1-row blocks, often
#      Float32) needs: warping it directly re-decodes each strip for every
#      warp window and took over 2 hours for a Canada-wide 30 m file. The
#      prepared file is kept in the work dir (PIPELINE_WORK_DIR/raster),
#      keyed by the source's path, size and modification time and the
#      layer's LAYER_SOURCE_SRS and LAYER_NODATA, so a rebuild (another zoom
#      range, a code change) skips it. See raster_source.
#   2. warp: gdalwarp the prepared file to EPSG:3857 at the max zoom's
#      resolution, aligned to the tile grid, multithreaded (-multi and
#      NUM_THREADS; a tiled input reads fast in any order).
#   3. levels: for each lower zoom, the share covered, averaged (Float32,
#      gdalwarp -r average) from the zoom above. Each level aligns with the
#      tile grid, so tiling it copies pixels.
#   4. tile: each level through `gdal raster tile` (multithreaded) at its own
#      zoom, scaled to grey 0 to 255 with 0 as nodata, so --skip-blank leaves
#      out empty tiles and empty pixels are transparent.
#   5. pack: the tiles into an MBTiles file with sqlite3, then
#      `pmtiles convert`, verified, then moved into place. GDAL's PMTiles
#      driver writes vector tiles only.
#
# Averaging the share per zoom, rather than letting `gdal raster tile` build
# the overviews, keeps the levels exact: its average skips nodata, so it
# would make every partly covered pixel fully covered.
#
# Intermediates of steps 2 to 5 live in the per-run scratch dir (under
# TMPDIR) and go as soon as they are packed. The archive is written to a
# hidden temp file in the output dir and renamed into place, so a failed
# build keeps the previous archive. Prepared sources (step 1) are written
# the same way (temp file, then rename) and stay in the work dir until their
# source changes; delete PIPELINE_WORK_DIR/raster to reclaim the space.

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

  log_info "preparing $dataset (tiled 0/1 Byte, once per source)"
  _RASTER_SOURCE_TMP="${dir}/.${stem}.$$.tmp.tif"
  trap 'rm -f "${_RASTER_SOURCE_TMP:-}"' EXIT
  # GDAL_NUM_THREADS decodes the source's blocks in parallel.
  GDAL_NUM_THREADS=ALL_CPUS gdal_translate -q -ot Byte -a_nodata none \
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

# raster_warp PREPARED MAX_ZOOM OUT: write OUT, PREPARED (0/1, no nodata) in
# EPSG:3857 at MAX_ZOOM's resolution, aligned to the tile grid, Byte.
raster_warp() {
  local input=$1 maxzoom=$2 out=$3
  local res
  res=$(raster_resolution "$maxzoom")
  # -r near: no new values. Cells outside the source keep INIT_DEST=0, and
  # -dstnodata None leaves 0 a value, which the levels average.
  log_info "warping to EPSG:3857 (z${maxzoom} resolution)"
  gdalwarp -q -overwrite -srcnodata None -t_srs EPSG:3857 -tr "$res" "$res" -tap \
    -r near -ot Byte -dstnodata None -wo INIT_DEST=0 \
    -multi -wo NUM_THREADS=ALL_CPUS -wm 1024 \
    -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 \
    -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co SPARSE_OK=TRUE -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$input" "$out" \
    || die "gdalwarp failed for $input"
}

# raster_level SRC ZOOM OUT: write OUT, the share of each ZOOM pixel covered,
# averaged from SRC (the level above), Float32 0 to 1.
raster_level() {
  local src=$1 zoom=$2 out=$3
  local res
  res=$(raster_resolution "$zoom")
  gdalwarp -q -overwrite -srcnodata None -dstnodata None -wo INIT_DEST=0 \
    -tr "$res" "$res" -tap -r average -ot Float32 \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co TILED=YES -co COMPRESS=ZSTD -co ZSTD_LEVEL=1 -co PREDICTOR=3 -co NUM_THREADS=ALL_CPUS -co BIGTIFF=IF_SAFER \
    "$src" "$out" \
    || die "cannot average $src to z${zoom}"
}

# raster_tile LEVEL ZOOM OUT_DIR: write LEVEL's tiles at ZOOM to
# OUT_DIR/z/x/y.png (XYZ numbering) as grey 0 to 255 with transparent 0;
# blank tiles are left out.
raster_tile() {
  local level=$1 zoom=$2 out=$3
  local grey="${level%.*}.grey.vrt"
  # Rounded to the nearest grey level; 0 (nothing covered) is nodata.
  gdal_translate -q -of VRT -ot Byte -scale 0 1 0 255 -a_nodata 0 "$level" "$grey" \
    || die "cannot scale $level"
  gdal raster tile --quiet \
    --min-zoom "$zoom" --max-zoom "$zoom" --resampling nearest \
    --skip-blank --webviewer none --num-threads ALL_CPUS \
    "$grey" "$out" \
    || die "gdal raster tile failed at z${zoom}"
}

# raster_tile_report TILE_DIR: print the raster build report as compact
# JSON: {tile_count, max_tile_bytes, zooms: [{zoom, tiles, max_tile_bytes}]}.
raster_tile_report() {
  local dir=$1
  (cd "$dir" && find . -name '*.png' -printf '%P\t%s\n') \
    | awk -F'\t' '{ split($1, p, "/"); z = p[1] + 0; n[z]++; if ($2 > m[z]) m[z] = $2 }
        END { for (z in n) printf "%d\t%d\t%d\n", z, n[z], m[z] }' \
    | sort -n \
    | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | map(tonumber)
        | {zoom: .[0], tiles: .[1], max_tile_bytes: .[2]}]
        | {tile_count: (map(.tiles) | add // 0),
           max_tile_bytes: (map(.max_tile_bytes) | max // 0),
           zooms: .}' \
    || die "cannot read tiles in $dir"
}

# raster_mbtiles TILE_DIR NAME MIN_ZOOM MAX_ZOOM BOUNDS OUT: pack the PNG
# tiles into an MBTiles file (rows flipped to TMS numbering), with the
# metadata `pmtiles convert` needs. BOUNDS is `west,south,east,north`.
raster_mbtiles() {
  local dir=$1 name=$2 minzoom=$3 maxzoom=$4 bounds=$5 out=$6
  local center
  center=$(awk -F, -v z="$minzoom" '{ printf "%.7f,%.7f,%d\n", ($1 + $3) / 2, ($2 + $4) / 2, z }' <<<"$bounds")
  rm -f "$out"
  {
    printf '%s\n' \
      'PRAGMA journal_mode = OFF;' 'PRAGMA synchronous = OFF;' \
      'CREATE TABLE metadata (name TEXT, value TEXT);' \
      'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);' \
      'BEGIN;'
    printf "INSERT INTO metadata VALUES ('%s', '%s');\n" \
      name "$name" format png type overlay \
      minzoom "$minzoom" maxzoom "$maxzoom" bounds "$bounds" center "$center"
    # Paths are digits and slashes only (z/x/y.png), safe to quote as is.
    (cd "$dir" && find . -name '*.png' -printf '%P\n') \
      | awk -F/ -v dir="$dir" '{
          z = $1; x = $2; y = $3; sub(/[.]png$/, "", y)
          printf "INSERT INTO tiles VALUES (%d, %d, %d, readfile(\047%s/%s\047));\n",
            z, x, 2 ^ z - 1 - y, dir, $0
        }'
    printf '%s\n' 'COMMIT;' \
      'CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);'
  } | sqlite3 -bail "$out" >/dev/null || die "cannot write $out"
}

# raster_bounds RASTER: `west,south,east,north` of RASTER in EPSG:4326.
raster_bounds() {
  gdalinfo -json "$1" \
    | jq -er '.wgs84Extent.coordinates[0]
        | [(map(.[0]) | min), (map(.[1]) | min), (map(.[0]) | max), (map(.[1]) | max)]
        | map(. * 1e7 | round / 1e7) | join(",")'
}

# build_raster_tiles LAYER INPUT SOURCE_SRS NODATA MIN_ZOOM MAX_ZOOM OUT_DIR TMP_DIR REPORT [CACHE_DIR]
# Build OUT_DIR/LAYER.pmtiles from INPUT (see the top of this file) and
# write the build report (raster_tile_report) to REPORT. CACHE_DIR holds
# prepared sources (raster_source); empty or absent, nothing is cached.
build_raster_tiles() {
  local layer=$1 input=$2 src_srs=$3 nodata=$4 minzoom=$5 maxzoom=$6
  local out_dir=$7 tmp=$8 report=$9 cache=${10:-}
  local dataset step=$SECONDS
  dataset=$(gdal_input_path "$input") || exit 1

  local levels="${tmp}/levels" tiles="${tmp}/tiles" mbtiles="${tmp}/${layer}.mbtiles"
  mkdir -p "$levels"
  local source
  source=$(raster_source "$dataset" "$src_srs" "$nodata" "$cache" "$tmp") || exit 1
  log_info "prepare: $((SECONDS - step)) s"

  step=$SECONDS
  local warped="${levels}/${maxzoom}.tif"
  raster_warp "$source" "$maxzoom" "$warped"
  [[ $source == "${cache}"/* && -n $cache ]] || rm -f "$source"
  log_info "warp: $((SECONDS - step)) s"
  local bounds
  bounds=$(raster_bounds "$warped") || die "cannot read the extent of $warped"

  step=$SECONDS
  log_info "tiling z${minzoom}-z${maxzoom}"
  local z level=$warped next
  for ((z = maxzoom; z >= minzoom; z--)); do
    if ((z < maxzoom)); then
      next="${levels}/${z}.tif"
      raster_level "$level" "$z" "$next"
      # The level above is no longer needed.
      rm -f "$level" "${level%.*}.grey.vrt"
      level=$next
    fi
    raster_tile "$level" "$z" "$tiles"
  done
  rm -rf "$levels"
  log_info "levels and tiles: $((SECONDS - step)) s"

  [[ -d $tiles ]] || mkdir -p "$tiles"
  raster_tile_report "$tiles" >"$report"
  local count
  count=$(jq -r '.tile_count' "$report")
  ((count > 0)) || die "no tiles: no 1 cells in $input at z${minzoom}-z${maxzoom}"
  log_info "${count} tiles"

  step=$SECONDS
  raster_mbtiles "$tiles" "$layer" "$minzoom" "$maxzoom" "$bounds" "$mbtiles"
  rm -rf "$tiles"

  local final="${out_dir}/${layer}.pmtiles"
  _BUILD_TILES_TMP="${out_dir}/.${layer}.$$.tmp.pmtiles"
  trap 'rm -f "${_BUILD_TILES_TMP:-}"' EXIT
  rm -f "$_BUILD_TILES_TMP"
  pmtiles convert "$mbtiles" "$_BUILD_TILES_TMP" >/dev/null 2>&1 \
    || die "pmtiles convert failed"
  rm -f "$mbtiles"
  pmtiles verify "$_BUILD_TILES_TMP" >/dev/null 2>&1 \
    || die "pmtiles verify failed for the new archive"

  mv -f "$_BUILD_TILES_TMP" "$final"
  _BUILD_TILES_TMP=""
  log_info "pack: $((SECONDS - step)) s"
  log_info "wrote $final"
}
