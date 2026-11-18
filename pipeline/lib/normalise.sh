#!/usr/bin/env bash
# Normalise a source dataset with ogr2ogr: reproject to EPSG:4326, make
# geometries valid, and keep only the configured attributes (renamed as
# configured). Output is GeoJSONSeq, which tippecanoe reads directly (and in
# parallel, with --read-parallel) and which lib/guard.sh measures.
#
# No simplification here: ogr2ogr -simplify works per feature, so it would
# open gaps between neighbours. Shared borders are simplified by tippecanoe
# (see the coverage profile in lib/layerfile.sh).

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
#
# With joins (LAYER_JOINS, a JSON array set by load_layer; lib/joins.sh),
# a FIELD may also be an attribute a join adds: the tables are read next
# to OUTPUT first, the source is read with each join's key, and the rows
# are added after, logging each join's rows and features matched.
normalise() {
  local input=$1 src_layer=$2 src_srs=$3 encoding=$4 output=$5
  shift 5

  local dataset
  dataset=$(gdal_input_path "$input") || exit 1
  if [[ -z $src_layer ]]; then
    src_layer=$(source_layer_name "$dataset") || die "cannot read layers from $input"
  fi

  local opts=() open=()
  [[ -z $encoding ]] || open+=(-oo "ENCODING=${encoding}")
  [[ -z $src_srs ]] || opts+=(-s_srs "$src_srs")

  # Joins: read the tables and check them against the source.
  local joins=${LAYER_JOINS:-[]} tables="" target=$output
  if [[ $joins != "[]" ]]; then
    tables="${output}.joins.json"
    target="${output}.unjoined"
    prepare_joins "$joins" "$(ogrinfo -json -so "${open[@]}" "$dataset" "$src_layer" \
      | jq -r '.layers[0].fields[].name')" "$tables"
  fi

  local field src cols=() joined=() i
  for field in "$@"; do
    src=${field%%:*}
    if [[ -n $tables && -n ${_JOIN_ADDED[$src]+x} ]]; then
      joined+=("${src}:${field#*:}")
    else
      cols+=("$(ogr_quote "$src") AS $(ogr_quote "${field#*:}")")
    fi
  done
  if [[ -n $tables ]]; then
    for i in "${!_JOIN_ONS[@]}"; do
      cols+=("$(ogr_quote "${_JOIN_ONS[i]}") AS \"_join_key${i}\"")
    done
  fi
  local select
  select=$(printf '%s, ' "${cols[@]}")
  local sql
  sql="SELECT ${select%, } FROM $(ogr_quote "$src_layer")"

  log_info "normalising $input (layer $src_layer)"
  ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -makevalid "${open[@]}" "${opts[@]}" \
    -sql "$sql" "$target" "$dataset" \
    || die "ogr2ogr failed for $input"

  if [[ -n $tables ]]; then
    join_rows "$tables" "$target" "$output" "${joined[@]}"
    rm -f -- "$target" "$tables"
  fi
}
