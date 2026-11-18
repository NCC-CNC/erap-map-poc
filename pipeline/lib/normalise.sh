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
# are added after. The joins, with their row and matched counts, go to
# OUTPUT.joins.json.
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
  local joins=${LAYER_JOINS:-[]} prepared="" n=0 target=$output
  if [[ $joins != "[]" ]]; then
    local dir=${output%/*}
    [[ $dir != "$output" ]] || dir=.
    prepared="${output}.joins.prepared.json"
    target="${output}.unjoined"
    prepare_joins "$joins" "$dir" "$prepared"
    n=$(jq 'length' "$prepared")
    join_check "$prepared" "$(ogrinfo -json -so "${open[@]}" "$dataset" "$src_layer" \
      | jq -r '.layers[0].fields[].name')"
  fi

  local field src dest owner cols=() joined=() i
  for field in "$@"; do
    src=${field%%:*}
    dest=${field#*:}
    if [[ -n $prepared ]] && owner=$(join_owner "$prepared" "$src") && [[ -n $owner ]]; then
      joined+=("${owner}:${src}:${dest}")
      continue
    fi
    cols+=("$(ogr_quote "$src") AS $(ogr_quote "$dest")")
  done
  for ((i = 0; i < n; i++)); do
    cols+=("$(ogr_quote "$(jq -r --argjson i "$i" '.[$i].on' "$prepared")") AS \"_join_key${i}\"")
  done
  local select
  select=$(printf '%s, ' "${cols[@]}")
  local sql
  sql="SELECT ${select%, } FROM $(ogr_quote "$src_layer")"

  log_info "normalising $input (layer $src_layer)"
  ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -makevalid "${open[@]}" "${opts[@]}" \
    -sql "$sql" "$target" "$dataset" \
    || die "ogr2ogr failed for $input"

  if [[ -n $prepared ]]; then
    log_info "joining $(jq -r 'map(.path) | join(", ")' "$prepared")"
    join_rows "$prepared" "$target" "$output" "${output}.joins.json" "${joined[@]}"
    rm -f -- "$target" "$prepared" "${dir}"/join[0-9]*.json
  fi
}
