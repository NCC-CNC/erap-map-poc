#!/usr/bin/env bash
# Per-zoom generalisation of a polygon layer (the coverage and default
# processing profiles, lib/layerfile.sh; ADR 0016).
#
# For each zoom z from the layer's min zoom up to its max, a generalised
# copy of the normalised input is made with GDAL, in EPSG:3857 (the tiles'
# own projection, as the drop guard measures):
#
#   1. Explode multipolygons into parts and drop every part smaller than
#      MIN_PART_PX screen pixels at z, except each feature's largest part, so
#      every feature keeps its id, attributes and the part the drop guard
#      measures.
#   2. Collect the parts left back into one multipolygon per feature.
#   3. Simplify with a tolerance of SIMPLIFY_PX screen pixels at z; 0 skips
#      this step. `coverage`: as a coverage (`gdal vector
#      simplify-coverage`, GEOS CoverageSimplifier), so each shared border is
#      simplified once, the same in both neighbours, and no gaps or slivers
#      open. `feature`: each feature on its own (`gdal vector simplify`,
#      topology preserving), for polygons that may overlap.
#
# The max zoom uses its own, gentler settings (processing.maxzoom_min_part_px
# and maxzoom_simplify_px); both 0 keep it at full detail. Zooms are done
# from the highest down, each from the one above it, so only the first pass
# reads the full input. Each zoom's features are tagged for tippecanoe with
# {"tippecanoe": {"minzoom": z, "maxzoom": z}}, so one tippecanoe run builds
# the whole archive: no tile-join, and the drop guard and the shared node
# handling of the coverage profile work as before. The drop guard measures
# the normalised input, not this one: each feature keeps a part at every
# zoom, though simplification can still thin a narrow one away (the
# protected_areas border slivers), which the guard then reports.
#
# Why GDAL and not tippecanoe's own options: tippecanoe has no part
# threshold that keeps each feature's largest part, and simplifying in
# tippecanoe instead leaves every zoom's copy at full detail, several times
# slower to tile. Measured in ADR 0016 (#141).
#
# Pixels are at 256 px tiles, as for min_visible_px: at zoom z one
# pixel is 40075016.686 / (256 * 2^z) m wide in EPSG:3857.

# _generalise_px_m Z: the width of one screen pixel at zoom Z in EPSG:3857 m.
_generalise_px_m() {
  awk -v z="$1" -v world="$GUARD_WORLD_M" 'BEGIN { printf "%.6f", world / (256 * 2 ^ z) }'
}

# _positive N: succeed if the number N is above 0.
_positive() {
  awk -v n="$1" 'BEGIN { exit !(n > 0) }'
}

# generalise_zoom INPUT OUTPUT Z FEATURE_ID MIN_PART_PX SIMPLIFY_PX SIMPLIFIER
#   FIELD...
# Write OUTPUT (GeoJSONSeq, EPSG:4326): INPUT generalised for zoom Z as
# described above, SIMPLIFIER being `coverage` or `feature`. FIELD is an
# attribute name or a `src:dest` pair; the dest names are the attributes
# kept.
generalise_zoom() {
  local input=$1 output=$2 z=$3 id=$4 min_part_px=$5 simplify_px=$6 simplifier=$7
  shift 7

  local layer
  layer=$(source_layer_name "$input") || die "cannot read layers from $input"

  local px min_area tolerance
  px=$(_generalise_px_m "$z")
  min_area=$(awk -v px="$px" -v n="$min_part_px" 'BEGIN { printf "%.6f", n * px * px }')
  tolerance=$(awk -v px="$px" -v n="$simplify_px" 'BEGIN { printf "%.6f", n * px }')

  local field cols=()
  for field in "$@"; do
    cols+=("$(ogr_quote "${field#*:}")")
  done
  local select
  select=$(printf '%s, ' "${cols[@]}")

  # Parts at least min_area, or the feature's largest, regrouped by id.
  local qid sql
  qid=$(ogr_quote "$id")
  sql="SELECT ${select} ST_Multi(ST_Collect(geometry)) AS geometry FROM ("
  sql+="SELECT *, ST_Area(geometry) AS _part_area,"
  sql+=" MAX(ST_Area(geometry)) OVER (PARTITION BY ${qid}) AS _max_area"
  sql+=" FROM $(ogr_quote "$layer"))"
  sql+=" WHERE _part_area >= ${min_area} OR _part_area = _max_area GROUP BY ${qid}"

  local simplify=()
  if _positive "$tolerance"; then
    case $simplifier in
      coverage) simplify=(! simplify-coverage --tolerance "$tolerance") ;;
      feature) simplify=(! simplify --tolerance "$tolerance") ;;
      *) die "unknown simplifier: $simplifier" ;;
    esac
  fi

  gdal vector pipeline --quiet \
    read "$input" \
    ! reproject --dst-crs EPSG:3857 \
    ! explode-collections \
    ! sql --dialect SQLITE --sql "$sql" --output-layer "$layer" \
    "${simplify[@]}" \
    ! reproject --dst-crs EPSG:4326 \
    ! write -f GeoJSONSeq --overwrite "$output" \
    || die "cannot generalise $input for z${z}"
}

# _tag_zooms INPUT MIN_ZOOM MAX_ZOOM: print INPUT (GeoJSONSeq, one feature
# per line) with each feature limited to MIN_ZOOM..MAX_ZOOM for tippecanoe.
_tag_zooms() {
  sed "s/^{/{ \"tippecanoe\": { \"minzoom\": $2, \"maxzoom\": $3 }, /" "$1"
}

# generalised_input INPUT OUTPUT MIN_ZOOM MAX_ZOOM FEATURE_ID SIMPLIFIER
#   MIN_PART_PX SIMPLIFY_PX MAX_MIN_PART_PX MAX_SIMPLIFY_PX TMP_DIR FIELD...
# Write OUTPUT, the tippecanoe input for a generalised layer: INPUT
# generalised for each zoom MIN_ZOOM..MAX_ZOOM (that zoom only), with
# MIN_PART_PX and SIMPLIFY_PX below MAX_ZOOM and MAX_MIN_PART_PX and
# MAX_SIMPLIFY_PX at it. A zoom whose two settings are 0 is its input as is.
generalised_input() {
  local input=$1 output=$2 minzoom=$3 maxzoom=$4 id=$5 simplifier=$6
  local low_part=$7 low_simplify=$8 max_part=$9 max_simplify=${10} tmp=${11}
  shift 11

  local below=""
  ((minzoom == maxzoom)) \
    || below="below z${maxzoom} parts under ${low_part} px dropped, simplified at ${low_simplify} px; "
  log_info "generalising z${minzoom}-z${maxzoom} (${simplifier}): ${below}at z${maxzoom} parts under ${max_part} px dropped, simplified at ${max_simplify} px; each feature keeps its largest part"

  local z part simplify from=$input zoom_file started=$SECONDS
  : >"$output"
  for ((z = maxzoom; z >= minzoom; z--)); do
    part=$low_part simplify=$low_simplify
    ((z < maxzoom)) || part=$max_part simplify=$max_simplify
    if _positive "$part" || _positive "$simplify"; then
      zoom_file="${tmp}/generalised_z${z}.geojsonl"
      generalise_zoom "$from" "$zoom_file" "$z" "$id" "$part" "$simplify" "$simplifier" "$@"
      [[ $from == "$input" ]] || rm -f "$from"
      from=$zoom_file
    fi
    _tag_zooms "$from" "$z" "$z" >>"$output" || die "cannot write $output"
  done
  [[ $from == "$input" ]] || rm -f "$from"
  log_info "generalised in $((SECONDS - started)) s"
}
