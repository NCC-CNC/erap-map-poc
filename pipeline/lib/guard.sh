#!/usr/bin/env bash
# Visibility-aware drop guard: after tiling, check that no feature big enough
# to see at a zoom was dropped at that zoom, and gather per-zoom stats for
# manifest.json.
#
# Size: each feature's largest polygon part, measured once in Web Mercator
# (EPSG:3857, the tiles' own projection) from the normalised GeoJSONSeq.
# Points and lines have no area and are never required.
#
# Required: at zoom z a feature is required when that part covers at least
# MIN_PX screen pixels at 256 px tiles, that is
#   area_m2 * (256 * 2^z / C)^2 >= MIN_PX, C = 40075016.686 m
# (the equator's length, the width of the z0 tile). A required feature that
# is missing from every tile of its zoom fails the build; missing smaller
# features are only counted and logged. Tippecanoe's tiny polygon reduction
# only touches polygons under about 1/64 of a pixel, far below the default
# MIN_PX of 1, so it never trips the guard; dropping (for example
# --drop-smallest-as-needed, or a tile size limit) can.
#
# Cost: one GDAL pass over the input for the sizes, then each zoom of the
# archive is read once through GDAL's PMTiles driver (feature ids only, no
# output geometry) and once by `tippecanoe-decode --stats` for tile sizes.

# Width of the z0 tile in EPSG:3857 metres (2 * pi * 6378137).
GUARD_WORLD_M=40075016.68557849

# feature_sizes INPUT FEATURE_ID OUT: write OUT as `id<TAB>area_m2` lines,
# area_m2 being the EPSG:3857 area of the feature's largest polygon part.
# Features with no polygon part are left out.
feature_sizes() {
  local input=$1 id=$2 out=$3
  local layer
  layer=$(source_layer_name "$input") || die "cannot read layers from $input"

  local sql
  sql="SELECT $(ogr_quote "$id") AS fid, OGR_GEOM_AREA AS area FROM $(ogr_quote "$layer")"
  sql+=" WHERE OGR_GEOMETRY = 'POLYGON'"

  gdal vector pipeline \
    read "$input" \
    ! explode-collections \
    ! reproject --dst-crs EPSG:3857 \
    ! sql "$sql" \
    ! write -f CSV /vsistdout/ \
    | awk -F, 'NR > 1 && (!($1 in max) || $2 + 0 > max[$1]) { max[$1] = $2 + 0 }
      END { for (k in max) printf "%s\t%.3f\n", k, max[k] }' >"$out" \
    || die "cannot measure feature sizes in $input"
}

# drop_guard ARCHIVE LAYER SIZES INPUT_COUNT MIN_ZOOM MAX_ZOOM MIN_PX STATS_OUT
# Check ARCHIVE zoom by zoom against SIZES (from feature_sizes) and write
# STATS_OUT, a JSON array with one object per zoom:
#   {zoom, input, present, required, required_present, max_tile_bytes}
# Fails (after checking every zoom) if a required feature is missing.
drop_guard() {
  local archive=$1 layer=$2 sizes=$3 count=$4 minzoom=$5 maxzoom=$6 min_px=$7 out=$8

  # Largest stored (compressed) tile per zoom, as {"0": bytes, ...}.
  local tile_bytes
  tile_bytes=$(tippecanoe-decode --stats "$archive" \
    | jq -c 'group_by(.zoom) | map({key: (.[0].zoom | tostring),
        value: (map(.bytes) | max)}) | from_entries') \
    || die "cannot read tile sizes from $archive"

  local ids_file="${out}.ids"
  local sql z failed=0 lines=()
  sql="SELECT DISTINCT mvt_id FROM $(ogr_quote "$layer")"
  for ((z = minzoom; z <= maxzoom; z++)); do
    ogr2ogr -f CSV /vsistdout/ -oo "ZOOM_LEVEL=${z}" "$archive" -sql "$sql" >"$ids_file" \
      || die "cannot read feature ids at z${z} from $archive"

    # present required required_present missing_count missing_ids(first 20)
    local n_present n_req n_req_present n_missing missing
    read -r n_present n_req n_req_present n_missing missing < <(
      awk -F'\t' -v z="$z" -v min_px="$min_px" -v world="$GUARD_WORLD_M" '
        BEGIN { k = (256 * 2 ^ z / world) ^ 2 }
        FILENAME == ARGV[1] { if ($2 > 0 && $2 * k >= min_px) req[$1] = 1; next }
        FNR > 1 { seen[$1] = 1 }
        END {
          for (id in seen) n_present++
          for (id in req) {
            n_req++
            if (id in seen) { n_req_present++; continue }
            if (++n_missing <= 20) missing = missing (missing == "" ? "" : ",") id
          }
          printf "%d %d %d %d %s\n", n_present, n_req, n_req_present, n_missing, missing
        }' "$sizes" "$ids_file"
    ) || die "drop guard failed at z${z}"

    local small=$((count - n_req - (n_present - n_req_present)))
    ((small >= 0)) || small=0
    if ((n_missing > 0)); then
      log_error "z${z}: ${n_missing} of ${n_req} required feature(s) missing, ids include ${missing}"
      failed=1
    elif ((small > 0)); then
      log_info "z${z}: ${n_present} of ${count} features present, all ${n_req} required present; ${small} smaller ones not present (allowed)"
    fi

    lines+=("$(jq -cn --argjson z "$z" --argjson input "$count" \
      --argjson present "$n_present" --argjson required "$n_req" \
      --argjson required_present "$n_req_present" --argjson bytes "$tile_bytes" \
      '{zoom: $z, input: $input, present: $present, required: $required,
        required_present: $required_present,
        max_tile_bytes: ($bytes[$z | tostring] // 0)}')")
  done
  rm -f "$ids_file"

  printf '%s\n' "${lines[@]}" | jq -s '.' >"$out" || die "cannot write $out"
  ((failed == 0)) \
    || die "drop guard: required features missing (LAYER_MIN_VISIBLE_PX=${min_px}); keeping the previous archive"
  log_info "drop guard passed for z${minzoom}-z${maxzoom}"
}
