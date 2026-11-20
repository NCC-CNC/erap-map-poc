#!/usr/bin/env bash
# Non-spatial joins (design note 04): `source.joins` adds attributes from a
# table (a CSV, or a table in any dataset GDAL opens) to the source
# features, matched by a key attribute of the same name in both:
#
#   source:
#     path: ecoregions.gdb
#     id: OBJECTID
#     joins:
#       - path: ecoregion_stats.csv
#         on: ECOREGION_ID
#         fields: [budget, {REGION_NAME: region}]   # default all but `on`
#
# The join comes before field selection: a joined attribute is kept, and can
# be renamed, by `fields.keep` like a source attribute (by its name after
# `joins[].fields`), and calculated fields can use it.
#
# How it runs: prepare_joins reads each table once with ogr2ogr into a JSON
# object from key to row (a CSV with its types detected, a quoted value
# kept as text, an empty one NULL). normalise (lib/normalise.sh) reads the
# source as without joins, plus each key, and join_rows adds the rows with
# jq in one pass, so the time grows with the number of features plus rows,
# not their product.
#
#   - Keys match as text, so an integer key in the source matches the same
#     digits in a CSV; a real that is a whole number counts as that integer
#     (7.0 matches 7). A key with leading zeros ("007") must be text on
#     both sides (quoted in a CSV). An integer key beyond 2^53 is not exact.
#   - Every feature is kept: one with no matching row gets no attribute
#     from that table (NULL for calculated fields).
#   - A key repeated in a table (one-to-many) fails the layer, naming the
#     key: a feature gets one row, and picking one would hide a data error.
#   - A joined attribute whose name the source or another join already has
#     fails the layer: rename it in `joins[].fields`.
#   - A missing table is handled like missing source data: a full build
#     skips the layer, a named build fails, --status says `source missing`.
#
# The join settings are part of `source`, so they are in the layer's
# build_sha256, and a table modified after the build makes the layer stale
# (lib/status.sh).

# JOIN_KEY_JQ: jq function `join_key`, a key as text (null stays null, a
# whole number has no decimals).
JOIN_KEY_JQ='def join_key: if . == null then null
  elif type == "number" and . == floor then floor | tostring else tostring end;'

# prepare_joins JOINS SOURCE_FIELDS TABLES: read each table of JOINS (the
# layer's source.joins as JSON, paths resolved, as load_layer sets
# LAYER_JOINS) into TABLES, one object per line from key to the row's added
# attributes. SOURCE_FIELDS is the source's attribute names, one per line.
# Sets the _JOIN_* globals join_rows and normalise read; _JOIN_ADDED holds
# the names the joins add (after joins[].fields). Fails on a missing table,
# key or attribute, a key in more than one row, or a name added twice.
prepare_joins() {
  local joins=$1 tables=$3 n i name
  declare -ga _JOIN_LABELS=() _JOIN_PATHS=() _JOIN_ONS=() _JOIN_ROWS=()
  declare -gA _JOIN_ADDED=()
  local -A in_source=()
  while IFS= read -r name; do
    [[ -z $name ]] || in_source[$name]=1
  done <<<"$2"
  : >"$tables" || die "cannot write $tables"

  n=$(jq 'length' <<<"$joins")
  for ((i = 0; i < n; i++)); do
    # path, layer, on, then the attributes to add as src:dest.
    local spec=() path layer on label dataset opts=()
    mapfile -t spec < <(jq -r --argjson i "$i" '.[$i] | .path, (.layer // ""), .on,
      ((.fields // [])[] | if type == "string" then "\(.):\(.)"
        else to_entries[0] | "\(.key):\(.value)" end)' <<<"$joins")
    path=${spec[0]} layer=${spec[1]} on=${spec[2]}
    label="source.joins[${i}] (${path#"${PIPELINE_INPUT_DIR}"/})"
    dataset=$(gdal_input_path "$path") || exit 1
    [[ -n $layer ]] || layer=$(source_layer_name "$dataset") || die "${label}: cannot read layers"
    [[ ${dataset,,} != *.csv ]] \
      || opts=(-oo AUTODETECT_TYPE=YES -oo QUOTED_FIELDS_AS_STRING=YES -oo EMPTY_STRING_AS_NULL=YES)

    local available=() field fields=("${spec[@]:3}") cols=()
    local -A in_table=()
    mapfile -t available < <(ogrinfo -json -so "${opts[@]}" "$dataset" "$layer" \
      | jq -r '.layers[0].fields[].name')
    for field in "${available[@]}"; do
      in_table[$field]=1
      # By default every attribute but the key.
      ((${#spec[@]} > 3)) || [[ $field == "$on" ]] || fields+=("${field}:${field}")
    done
    ((${#fields[@]} > 0)) || die "${label}: no attributes to add"
    for field in "$on" "${fields[@]%%:*}"; do
      [[ -n ${in_table[$field]+x} ]] || die "${label}: no attribute $field (attributes: ${available[*]})"
    done
    [[ -n ${in_source[$on]+x} ]] \
      || die "${label}: no attribute $on in the source (attributes: ${2//$'\n'/ })"
    for field in "${fields[@]}"; do
      name=${field#*:}
      [[ -z ${in_source[$name]+x} ]] || die "${label}: $name is also a source attribute; rename it in its fields"
      [[ -z ${_JOIN_ADDED[$name]+x} ]] || die "${label}: $name is also added by ${_JOIN_ADDED[$name]}; rename it in its fields"
      _JOIN_ADDED[$name]=$label
      cols+=(", $(ogr_quote "${field%%:*}") AS $(ogr_quote "$name")")
    done

    # The keyed rows go to TABLES (on stderr), the row count and the first
    # repeated key to stdout. `_Key` cannot clash with an added name.
    local stats rows repeated
    stats=$(ogr2ogr -f GeoJSONSeq /vsistdout/ "${opts[@]}" \
      -sql "SELECT $(ogr_quote "$on") AS \"_Key\"${cols[*]} FROM $(ogr_quote "$layer")" \
      "$dataset" 2>/dev/null \
      | jq -n -r "${JOIN_KEY_JQ}"'
          reduce (inputs | .properties) as $p ({rows: 0, keys: {}, repeated: null};
            .rows += 1
            | ($p._Key | join_key) as $k
            | if $k == null then .
              elif .keys | has($k) then .repeated //= $k
              else .keys[$k] = ($p | del(._Key)) end)
          | (.keys | tojson + "\n" | stderr) as $_ | "\(.rows) \(.repeated // "")"' 2>>"$tables") \
      || die "${label}: cannot read the table"
    read -r rows repeated <<<"$stats"
    [[ -z $repeated ]] \
      || die "${label}: $on ${repeated} is in more than one row; a feature gets one row, so each key must be in the table once"
    _JOIN_LABELS+=("$label") _JOIN_PATHS+=("${path#"${PIPELINE_INPUT_DIR}"/}")
    _JOIN_ONS+=("$on") _JOIN_ROWS+=("$rows")
  done
}

# join_rows TABLES INPUT OUTPUT FIELD...: add the rows of the joins
# (prepare_joins) to the features of INPUT (GeoJSONSeq with the key of
# join i in `_join_key<i>`) and write OUTPUT without the keys. Each FIELD,
# `src:dest`, keeps the joined attribute src as dest. Logs each join's
# rows and features matched, and warns for a join that matched no feature
# (most likely the wrong key).
join_rows() {
  local tables=$1 input=$2 output=$3 counts
  shift 3
  log_info "joining $(printf '%s, ' "${_JOIN_PATHS[@]}" | sed 's/, $//')"
  # The feature and matched counts go to stderr once the features are done.
  counts=$(jq -n -c --slurpfile t "$tables" "${JOIN_KEY_JQ}"'
    [$ARGS.positional[] | index(":") as $c | [.[:$c], .[$c + 1:]]] as $keep
    | ($t | length) as $n
    | foreach (inputs, null) as $f ({features: 0, matched: [range($n) | 0]};
        if $f then
          .rows = [range($n) as $i | $t[$i][$f.properties["_join_key\($i)"] | join_key // ""]]
          | .features += 1
          | .matched = [range($n) as $i | .matched[$i] + (if .rows[$i] then 1 else 0 end)]
        else . end;
        if $f then
          ([.rows[] | . // {}] | add) as $row
          | $f | .properties |= (del(.["_join_key\(range($n))"])
              + (reduce $keep[] as $k ({}; .[$k[1]] = $row[$k[0]])))
        else {features, matched} | tojson + "\n" | stderr | empty end)' \
    --args "$@" <"$input" 2>&1 >"$output") \
    || die "cannot add the joined rows to $input: ${counts:0:500}"

  local features matched=() i summary=()
  features=$(jq '.features' <<<"$counts")
  mapfile -t matched < <(jq '.matched[]' <<<"$counts")
  for i in "${!_JOIN_PATHS[@]}"; do
    ((matched[i] > 0)) || log_warn "${_JOIN_LABELS[i]}: no feature has a row in the table; check the key"
    summary+=("${_JOIN_PATHS[i]} on ${_JOIN_ONS[i]} (${matched[i]} of ${features} features matched, ${_JOIN_ROWS[i]} rows)")
  done
  log_info "joins: $(printf '%s, ' "${summary[@]}" | sed 's/, $//')"
}
