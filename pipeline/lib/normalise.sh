#!/usr/bin/env bash
# Normalise a source dataset with ogr2ogr: reproject to EPSG:4326, make
# geometries valid, and keep only the configured attributes (renamed as
# configured). Output is GeoJSONSeq, which tippecanoe reads directly (and in
# parallel, with --read-parallel) and which lib/guard.sh measures.
#
# No simplification here: ogr2ogr -simplify works per feature, so it would
# open gaps between neighbours. Shared borders are simplified by tippecanoe
# (see the coverage profile in lib/config.sh).

# ogr_quote NAME: quote an identifier for OGR SQL.
ogr_quote() {
  printf '"%s"' "${1//\"/\"\"}"
}

# source_layer_name DATASET: name of the first layer in DATASET.
source_layer_name() {
  ogrinfo -json -so "$1" | jq -er '.layers[0].name'
}

# gdal_input_path INPUT: print the path to give GDAL for INPUT, after checking
# that it exists. A `.zip`, or a path inside one (`data.zip/dir/file.shp`), is
# read in place through /vsizip/. Other /vsi paths are passed through as is.
gdal_input_path() {
  local input=$1
  if [[ $input == /vsi* ]]; then
    printf '%s\n' "$input"
  elif [[ $input =~ ^(.*[.][Zz][Ii][Pp])(/.*)?$ ]]; then
    [[ -f ${BASH_REMATCH[1]} ]] || die "input not found: ${BASH_REMATCH[1]}"
    printf '/vsizip/%s\n' "$input"
  else
    [[ -e $input ]] || die "input not found: $input"
    printf '%s\n' "$input"
  fi
}

# normalise INPUT SOURCE_LAYER SOURCE_SRS ENCODING OUTPUT FIELD...
# FIELD is `src` or `src:dest`. SOURCE_LAYER may be empty (first layer).
# SOURCE_SRS (ogr2ogr -s_srs) and ENCODING (open option ENCODING, for
# shapefiles) may be empty to use what the dataset declares.
normalise() {
  local input=$1 src_layer=$2 src_srs=$3 encoding=$4 output=$5
  shift 5

  local dataset
  dataset=$(gdal_input_path "$input") || exit 1
  if [[ -z $src_layer ]]; then
    src_layer=$(source_layer_name "$dataset") || die "cannot read layers from $input"
  fi

  local field src dest cols=()
  for field in "$@"; do
    src=${field%%:*}
    dest=${field#*:}
    cols+=("$(ogr_quote "$src") AS $(ogr_quote "$dest")")
  done
  local select
  select=$(printf '%s, ' "${cols[@]}")
  local sql
  sql="SELECT ${select%, } FROM $(ogr_quote "$src_layer")"

  local opts=()
  [[ -z $src_srs ]] || opts+=(-s_srs "$src_srs")
  [[ -z $encoding ]] || opts+=(-oo "ENCODING=${encoding}")

  log_info "normalising $input (layer $src_layer)"
  ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -makevalid "${opts[@]}" \
    -sql "$sql" "$output" "$dataset" \
    || die "ogr2ogr failed for $input"
}
