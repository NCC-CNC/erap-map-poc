#!/usr/bin/env bash
# Calculated fields (design note 04): `fields.calculated` in a layer file
# maps a new attribute to a SQLite expression on the kept attributes (their
# output names), such as
#
#   unprotected_intact_pcnt: round(intact_pcnt - protected_intact_pcnt, 2)
#   action_area_based_30x30: coalesce(protected_pcnt < 30, 0)
#
# GDAL's SQLite dialect evaluates them on the normalised GeoJSONSeq, in one
# ogr2ogr pass that keeps every attribute and the geometry as they are. The
# layer files are committed and trusted, so the expressions go to SQLite as
# they are; there is no parser of our own. A comparison gives 1 or 0 (NULL
# when an attribute is NULL, hence coalesce).
#
# A field may use the fields above it in the file: each one is a nested
# query on the one before,
#
#   SELECT *, (expr2) AS "b" FROM (SELECT *, (expr1) AS "a" FROM "layer")
#
# so `b` can read `a`. A bad expression fails the layer, naming the field.
#
# The type of a new attribute is read by GDAL from its first value, so one
# that is NULL there would come out as text: the values of a field whose
# expression gives numbers only are written back as numbers.

# _calculated_query TABLE N: the nested query adding the first N calculated
# fields (LAYER_CALCULATED_NAMES and LAYER_CALCULATED_EXPRESSIONS) to TABLE.
_calculated_query() {
  local table=$1 n=$2 i query
  query="SELECT * FROM $(ogr_quote "$table")"
  for ((i = 0; i < n; i++)); do
    query="SELECT *, (${LAYER_CALCULATED_EXPRESSIONS[i]}) AS $(ogr_quote "${LAYER_CALCULATED_NAMES[i]}") FROM (${query})"
  done
  printf '%s\n' "$query"
}

# _sqlite_rows DATASET SQL: the rows of a SQLite dialect query on DATASET as
# GeoJSON features, one per line, on stdout. GDAL's errors go to stderr.
_sqlite_rows() {
  ogr2ogr -f GeoJSONSeq /vsistdout/ -dialect SQLite -sql "$2" "$1"
}

# _calculated_diagnose DATASET TABLE: find the first calculated field whose
# expression fails, and fail the layer naming it and the error from SQLite.
_calculated_diagnose() {
  local dataset=$1 table=$2 i n=${#LAYER_CALCULATED_NAMES[@]} error name
  for ((i = 1; i <= n; i++)); do
    name=${LAYER_CALCULATED_NAMES[i - 1]}
    if ! error=$(_sqlite_rows "$dataset" \
      "SELECT $(ogr_quote "$name") FROM ($(_calculated_query "$table" "$i")) LIMIT 1" 2>&1 >/dev/null) \
      || [[ $error == *ERROR* ]]; then
      error=$(grep -m 1 -E 'ERROR' <<<"$error" | sed -E 's/^ERROR [0-9]+: //; s/^In ExecuteSQL\(\): //; s/^sqlite3_prepare_v2\(\): //')
      die "fields.calculated.${name}: ${LAYER_CALCULATED_EXPRESSIONS[i - 1]}: ${error:-SQLite cannot evaluate it}"
    fi
  done
  die "fields.calculated: SQLite cannot evaluate the calculated fields"
}

# add_calculated_fields INPUT OUTPUT REPORT: write OUTPUT, the normalised
# GeoJSONSeq INPUT with the loaded layer's calculated fields added
# (load_layer), and REPORT, a JSON array with, per field, its name,
# expression and the non-null count, minimum and maximum of its values.
add_calculated_fields() {
  local input=$1 output=$2 report=$3 n=${#LAYER_CALCULATED_NAMES[@]}
  ((n > 0)) || die "no calculated fields"
  local table
  table=$(source_layer_name "$input") || die "cannot read layers from $input"

  local query i name q stats_sql=""
  query=$(_calculated_query "$table" "$n")
  for ((i = 0; i < n; i++)); do
    q=$(ogr_quote "${LAYER_CALCULATED_NAMES[i]}")
    stats_sql+="${stats_sql:+, }count(${q}) AS n_${i}, min(${q}) AS min_${i}, max(${q}) AS max_${i},"
    stats_sql+=" max(typeof(${q}) = 'text' OR typeof(${q}) = 'blob') AS text_${i},"
    stats_sql+=" max(typeof(${q}) IN ('integer', 'real')) AS number_${i}"
  done

  log_info "calculating ${LAYER_CALCULATED_NAMES[*]}"
  local stats
  if ! stats=$(_sqlite_rows "$input" "SELECT ${stats_sql} FROM (${query})" 2>/dev/null) \
    || [[ -z $stats ]]; then
    _calculated_diagnose "$input" "$table"
  fi

  rm -f "$output"
  ogr2ogr -f GeoJSONSeq -dialect SQLite -sql "$query" "$output" "$input" \
    || _calculated_diagnose "$input" "$table"

  # Numbers that GDAL typed as text (a first value of NULL) back to numbers.
  local numeric=() types
  types=$(ogrinfo -json -so "$output" | jq -c '.layers[0].fields | map({key: .name, value: .type}) | from_entries') \
    || die "cannot read the fields of $output"
  for ((i = 0; i < n; i++)); do
    name=${LAYER_CALCULATED_NAMES[i]}
    if jq -e --arg f "$name" --argjson i "$i" --argjson t "$types" \
      '.properties["text_\($i)"] == 0 and .properties["number_\($i)"] == 1 and $t[$f] == "String"' \
      <<<"$stats" >/dev/null; then
      numeric+=("$name")
    fi
  done
  if ((${#numeric[@]} > 0)); then
    jq -c 'reduce $ARGS.positional[] as $f (.;
        if (.properties[$f] | type) == "string" then .properties[$f] |= tonumber else . end)' \
      --args "${numeric[@]}" <"$output" >"${output}.tmp" || die "cannot write $output"
    mv -f -- "${output}.tmp" "$output"
  fi

  # Numbers as numbers (`+ 0`: 3, not 3.0 as GDAL writes a real).
  jq -c --args 'def num: if type == "string" then (tonumber? // .) else . end
      | if type == "number" then . + 0 else . end;
    .properties as $p
    | [$ARGS.positional as $a | range(0; $a | length / 2) as $i
       | {name: $a[$i], expression: $a[($a | length / 2) + $i],
          non_null: $p["n_\($i)"], min: ($p["min_\($i)"] | num), max: ($p["max_\($i)"] | num)}]' \
    "${LAYER_CALCULATED_NAMES[@]}" "${LAYER_CALCULATED_EXPRESSIONS[@]}" <<<"$stats" >"$report" \
    || die "cannot write $report"
}

# calculated_summary REPORT: one line on the calculated fields in REPORT.
calculated_summary() {
  jq -r '"calculated: " + (map("\(.name) (\(.non_null) non-null, \(.min) to \(.max))") | join(", "))' "$1"
}
