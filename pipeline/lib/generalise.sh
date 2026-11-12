#!/usr/bin/env bash
# Low-zoom generalisation of a polygon layer (LAYER_GENERALISE_MAX_ZOOM; see
# lib/config.sh and docs/design/02_data_layers_and_popups.md).
#
# For each zoom z from the layer's min zoom up to LAYER_GENERALISE_MAX_ZOOM,
# a generalised copy of the normalised input is made with GDAL, in EPSG:3857
# (the tiles' own projection, as the drop guard measures):
#
#   1. Explode multipolygons into parts and drop every part smaller than
#      MIN_PART_PX screen pixels at z, except each feature's largest part, so
#      every feature keeps its id, attributes and the part the drop guard
#      measures.
#   2. Collect the parts left back into one multipolygon per feature.
#   3. Simplify the result as a coverage (`gdal vector simplify-coverage`,
#      GEOS CoverageSimplifier) with a tolerance of SIMPLIFY_PX screen pixels
#      at z: each shared border is simplified once, the same in both
#      neighbours, so no gaps or slivers open. 0 skips this step (for
#      polygons that overlap, which are not a coverage).
#
# Zooms are done from the highest down, each from the one above it, so only
# the first pass reads the full input. Each zoom's features are tagged for
# tippecanoe with {"tippecanoe": {"minzoom": z, "maxzoom": z}}, and the full
# input follows from LAYER_GENERALISE_MAX_ZOOM + 1, so one tippecanoe run
# builds the whole archive: no tile-join, and the drop guard and the shared
# node handling of the coverage profile work as before.
#
# Pixels are at 256 px tiles, as for LAYER_MIN_VISIBLE_PX: at zoom z one
# pixel is 40075016.686 / (256 * 2^z) m wide in EPSG:3857.

# _generalise_px_m Z: the width of one screen pixel at zoom Z in EPSG:3857 m.
_generalise_px_m() {
  awk -v z="$1" -v world="$GUARD_WORLD_M" 'BEGIN { printf "%.6f", world / (256 * 2 ^ z) }'
}

# generalise_zoom INPUT OUTPUT Z FEATURE_ID MIN_PART_PX SIMPLIFY_PX FIELD...
# Write OUTPUT (GeoJSONSeq, EPSG:4326): INPUT generalised for zoom Z as
# described above. FIELD is a `src` or `src:dest` from LAYER_FIELDS; the
# dest names are the attributes kept.
generalise_zoom() {
  local input=$1 output=$2 z=$3 id=$4 min_part_px=$5 simplify_px=$6
  shift 6

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
  if awk -v t="$tolerance" 'BEGIN { exit !(t > 0) }'; then
    simplify=(! simplify-coverage --tolerance "$tolerance")
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

# _tag_zooms INPUT MIN_ZOOM [MAX_ZOOM]: print INPUT (GeoJSONSeq, one feature
# per line) with each feature limited to MIN_ZOOM..MAX_ZOOM for tippecanoe.
_tag_zooms() {
  local input=$1 minzoom=$2 maxzoom=${3:-} range
  range="\"minzoom\": ${minzoom}${maxzoom:+, \"maxzoom\": ${maxzoom}}"
  sed "s/^{/{ \"tippecanoe\": { ${range} }, /" "$input"
}

# generalised_input INPUT OUTPUT MIN_ZOOM GEN_MAX_ZOOM FEATURE_ID MIN_PART_PX
#   SIMPLIFY_PX TMP_DIR FIELD...
# Write OUTPUT, the tippecanoe input for a generalised layer: INPUT
# generalised for each zoom MIN_ZOOM..GEN_MAX_ZOOM (that zoom only), then
# INPUT itself from GEN_MAX_ZOOM + 1.
generalised_input() {
  local input=$1 output=$2 minzoom=$3 gen_max=$4 id=$5 min_part_px=$6 simplify_px=$7 tmp=$8
  shift 8

  log_info "generalising z${minzoom}-z${gen_max}: parts under ${min_part_px} px dropped (each feature keeps its largest), coverage simplified at ${simplify_px} px"
  local z from=$input zoom_file started=$SECONDS
  : >"$output"
  for ((z = gen_max; z >= minzoom; z--)); do
    zoom_file="${tmp}/generalised_z${z}.geojsonl"
    generalise_zoom "$from" "$zoom_file" "$z" "$id" "$min_part_px" "$simplify_px" "$@"
    _tag_zooms "$zoom_file" "$z" "$z" >>"$output" || die "cannot write $output"
    [[ $from == "$input" ]] || rm -f "$from"
    from=$zoom_file
  done
  rm -f "$from"
  _tag_zooms "$input" "$((gen_max + 1))" >>"$output" || die "cannot write $output"
  log_info "generalised in $((SECONDS - started)) s"
}
