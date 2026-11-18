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
# How it runs: each table is read once with ogr2ogr into a JSON object
# from key to row (prepare_joins; a CSV with its types detected, a quoted
# value kept as text, an empty one NULL). normalise (lib/normalise.sh)
# reads the source as without joins, plus each key, and join_rows adds the
# rows to the features with jq in one pass, so the time grows with the
# number of features plus rows, not their product.
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

# JOIN_KEY_JQ: jq function `join_key`, a key as text, as the tables are
# keyed: null stays null, a whole number has no decimals.
JOIN_KEY_JQ='def join_key: if . == null then null
  elif type == "number" and . == floor then (floor | tostring)
  elif type == "string" then . else tostring end;'

# _join_open_opts DATASET: ogr2ogr open options for a join table, one per
# line: a CSV with its types detected and empty values as NULL.
_join_open_opts() {
  local lower=${1,,}
  if [[ $lower == *.csv ]]; then
    printf '%s\n' -oo AUTODETECT_TYPE=YES -oo QUOTED_FIELDS_AS_STRING=YES \
      -oo EMPTY_STRING_AS_NULL=YES
  fi
}

# _join_has NAME VALUE...: whether NAME is one of the VALUEs.
_join_has() {
  local name=$1 value
  shift
  for value in "$@"; do
    [[ $value != "$name" ]] || return 0
  done
  return 1
}

# prepare_joins JOINS DIR OUT: read each join table of JOINS (the layer's
# source.joins as JSON, paths resolved, as load_layer sets LAYER_JOINS)
# into DIR/join<i>.json, an object from key (as text) to the row's added
# attributes. Writes OUT, the joins as join_rows reads them:
# [{label, path, layer, on, table, rows, fields}], `fields` the names the
# join adds (after joins[].fields). Fails on a missing table, key or
# attribute, or a key in more than one row.
prepare_joins() {
  local joins=$1 dir=$2 out=$3 n i
  n=$(jq 'length' <<<"$joins")
  local rows=()
  for ((i = 0; i < n; i++)); do
    local join path layer on label dataset table="${dir}/join${i}.json"
    join=$(jq -c --argjson i "$i" '.[$i]' <<<"$joins")
    path=$(jq -r '.path' <<<"$join")
    layer=$(jq -r '.layer // ""' <<<"$join")
    on=$(jq -r '.on' <<<"$join")
    label="source.joins[${i}] (${path#"${PIPELINE_INPUT_DIR}"/})"
    dataset=$(gdal_input_path "$path") || exit 1
    if [[ -z $layer ]]; then
      layer=$(source_layer_name "$dataset") || die "${label}: cannot read layers"
    fi

    local available=() opts=()
    mapfile -t opts < <(_join_open_opts "$dataset")
    mapfile -t available < <(ogrinfo -json -so "${opts[@]}" "$dataset" "$layer" \
      | jq -r '.layers[0].fields[].name')
    ((${#available[@]} > 0)) || die "${label}: cannot read the attributes of layer $layer"
    _join_has "$on" "${available[@]}" \
      || die "${label}: no attribute $on (attributes: ${available[*]})"

    # The attributes it adds: joins[].fields, or every one but the key.
    local fields=() field cols=()
    mapfile -t fields < <(jq -r '
      (.fields // [])[] | if type == "string" then "\(.):\(.)"
                          else to_entries[0] | "\(.key):\(.value)" end' <<<"$join")
    if ((${#fields[@]} == 0)); then
      for field in "${available[@]}"; do
        [[ $field == "$on" ]] || fields+=("${field}:${field}")
      done
    fi
    ((${#fields[@]} > 0)) || die "${label}: no attributes to add"
    for field in "${fields[@]}"; do
      _join_has "${field%%:*}" "${available[@]}" \
        || die "${label}: no attribute ${field%%:*} (attributes: ${available[*]})"
      cols+=("$(ogr_quote "${field%%:*}") AS $(ogr_quote "${field#*:}")")
    done

    # The rows, keyed (on stderr, into the table file), and their count.
    # `_Key` cannot clash with an added name (lower case only).
    local select stats
    select=$(printf ', %s' "${cols[@]}")
    stats=$(ogr2ogr -f GeoJSONSeq /vsistdout/ "${opts[@]}" \
      -sql "SELECT $(ogr_quote "$on") AS \"_Key\"${select} FROM $(ogr_quote "$layer")" \
      "$dataset" 2>/dev/null \
      | jq -n -c "${JOIN_KEY_JQ}"'
          reduce (inputs | .properties) as $p ({rows: 0, keys: {}, repeated: null};
            .rows += 1
            | ($p._Key | join_key) as $k
            | if $k == null then .
              elif .keys | has($k) then .repeated //= $k
              else .keys[$k] = ($p | del(._Key)) end)
          | (.keys | tojson | stderr) as $_ | {rows, repeated}' 2>"$table") \
      || die "${label}: cannot read the table"
    [[ -n $stats ]] || die "${label}: cannot read the table"

    local repeated
    repeated=$(jq -r '.repeated // ""' <<<"$stats")
    if [[ -n $repeated ]]; then
      die "${label}: $on ${repeated} is in more than one row; a feature gets one row, so each key must be in the table once"
    fi

    rows+=("$(jq -n -c --arg label "$label" --arg table "$table" --arg on "$on" \
      --arg path "${path#"${PIPELINE_INPUT_DIR}"/}" --arg layer "$layer" \
      --argjson stats "$stats" '
      {label: $label, path: $path, layer: $layer, on: $on, table: $table,
       rows: $stats.rows, fields: $ARGS.positional}' --args "${fields[@]#*:}")")
  done
  printf '%s\n' "${rows[@]}" | jq -s '.' >"$out" || die "cannot write $out"
}

# join_check JOINS SOURCE_FIELDS: check the joins (prepare_joins) against
# the source's attributes (SOURCE_FIELDS, one name per line): the source
# has each key, and no joined name is a source attribute or added twice.
join_check() {
  local joins=$1 source_fields=$2 problem bad=0
  while IFS= read -r problem; do
    log_error "$problem"
    bad=1
  done < <(jq -r --arg s "$source_fields" '
    ($s | split("\n") | map(select(. != ""))) as $src
    | (.[] | select(.on as $on | $src | index($on) | not)
        | "\(.label): no attribute \(.on) in the source (attributes: \($src | join(" ")))"),
      ([.[] as $j | $j.fields[] | {name: ., label: $j.label}]
       | (.[] | select(.name as $n | $src | index($n))
            | "\(.label): \(.name) is also a source attribute; rename it in its fields"),
         (group_by(.name)[] | select(length > 1)
            | "\(.[1].label): \(.[0].name) is also added by \(.[0].label); rename it in its fields"))' \
    "$joins")
  ((bad == 0)) || die "source.joins has problems (above)"
}

# join_owner JOINS NAME: the index of the join that adds NAME, or nothing.
join_owner() {
  jq -r --arg n "$2" 'to_entries | map(select(.value.fields | index($n))) | first | .key // empty' "$1"
}

# join_rows JOINS INPUT OUTPUT REPORT FIELD...: add the joined rows to the
# features of INPUT (GeoJSONSeq with the key of join i in `_join_key<i>`)
# and write OUTPUT without the keys. Each FIELD, `i:src:dest`, keeps the
# attribute src of join i as dest. Writes REPORT, the joins with
# `matched`, the number of features with a row in each table.
join_rows() {
  local joins=$1 input=$2 output=$3 report=$4
  shift 4
  local keep
  keep=$(jq -n -c '[$ARGS.positional[] | (index(":")) as $a | .[$a + 1:] as $r
      | ($r | index(":")) as $b | [(.[:$a] | tonumber), $r[:$b], $r[$b + 1:]]]' --args "$@")
  local slurp=() refs="" i n
  n=$(jq 'length' "$joins")
  for ((i = 0; i < n; i++)); do
    slurp+=(--slurpfile "t${i}" "$(jq -r --argjson i "$i" '.[$i].table' "$joins")")
    refs+="${refs:+, }\$t${i}[0]"
  done
  # The matched counts go to stderr once the features are done.
  jq -n -c "${slurp[@]}" --argjson keep "$keep" --argjson n "$n" "${JOIN_KEY_JQ}
    [${refs}] as \$tables
    | foreach (inputs, null) as \$f ({m: [range(\$n) | 0], out: null};
        if \$f == null then .out = null
        else
          [range(\$n) as \$i | \$tables[\$i][\$f.properties[\"_join_key\(\$i)\"] | join_key // \"\"]] as \$rows
          | .m = [range(\$n) as \$i | .m[\$i] + (if \$rows[\$i] then 1 else 0 end)]
          | .out = (\$f | .properties |= (reduce range(\$n) as \$i (.; del(.[\"_join_key\(\$i)\"]))
              + (reduce \$keep[] as \$k ({}; .[\$k[2]] = (\$rows[\$k[0]] // {})[\$k[1]]))))
        end;
        if \$f == null then (.m | tojson | stderr | empty) else .out end)" \
    <"$input" >"$output" 2>"${report}.matched" \
    || die "cannot add the joined rows to $input: $(head -c 500 "${report}.matched")"
  jq --slurpfile m "${report}.matched" 'to_entries | map(.value + {matched: $m[0][.key]})' \
    "$joins" >"$report" || die "cannot write $report"
  rm -f -- "${report}.matched"
}

# join_summary JOINS COUNT: one line on the joins (join_rows' REPORT) of a
# layer of COUNT features. Warns for a join that matched no feature (most
# likely the wrong key).
join_summary() {
  local joins=$1 count=$2 label
  while IFS= read -r label; do
    [[ -z $label ]] || log_warn "${label}: no feature has a row in the table; check the key"
  done < <(jq -r '.[] | select(.matched == 0) | .label' "$joins")
  jq -r --argjson n "$count" '"joins: " + (map("\(.path) on \(.on) (\(.matched) of \($n) features matched, \(.rows) rows)") | join(", "))' "$joins"
}
