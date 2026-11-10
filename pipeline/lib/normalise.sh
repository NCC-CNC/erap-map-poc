#!/usr/bin/env bash
# Normalise a source dataset with ogr2ogr: reproject to EPSG:4326, make
# geometries valid, and keep only the configured attributes (renamed as
# configured). Output is GeoJSONSeq, which tippecanoe reads directly.

# ogr_quote NAME: quote an identifier for OGR SQL.
ogr_quote() {
  printf '"%s"' "${1//\"/\"\"}"
}

# source_layer_name DATASET: name of the first layer in DATASET.
source_layer_name() {
  ogrinfo -json -so "$1" | jq -er '.layers[0].name'
}

# normalise INPUT SOURCE_LAYER OUTPUT FIELD...
# FIELD is `src` or `src:dest`. SOURCE_LAYER may be empty (first layer).
normalise() {
  local input=$1 src_layer=$2 output=$3
  shift 3

  [[ -e $input ]] || die "input not found: $input"
  if [[ -z $src_layer ]]; then
    src_layer=$(source_layer_name "$input") || die "cannot read layers from $input"
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

  log_info "normalising $input (layer $src_layer)"
  ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -makevalid \
    -sql "$sql" "$output" "$input" \
    || die "ogr2ogr failed for $input"
}
