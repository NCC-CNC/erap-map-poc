#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Summarise a source dataset before writing a layer config for it: layers,
# feature count, geometry type, CRS, extent, encoding, fields with simple
# stats, feature id candidates and, for polygons, geometry and coverage
# checks. Read only; GDAL/OGR based.
#
# Usage: inspect.sh [-h|--help] [--json] [--layer NAME] [--no-checks]
#                   [--gap-width METRES] INPUT
#        inspect.sh [-h|--help] [--json] [--no-checks] [--gap-width METRES]
#                   --config LAYER
#
#   INPUT        source dataset. Relative paths are resolved against
#                PIPELINE_INPUT_DIR (default /data/raw), like LAYER_INPUT. A
#                `.zip`, or a file inside one (`data.zip/dir/file.shp`), is
#                read in place.
#   --json       print JSON instead of the human-readable summary.
#   --layer      layer inside the dataset (default: the first one).
#   --no-checks  skip the geometry and coverage checks (slow on big data).
#   --gap-width  narrowest gap between neighbours that is not flagged by
#                the coverage check, in Web Mercator metres (default 100).
#   --config     inspect configured layer LAYER as its build sees it, instead
#                of an INPUT: its source data (LAYER_INPUT and
#                LAYER_SOURCE_LAYER) normalised (the LAYER_FIELDS kept,
#                renamed, in EPSG:4326, made valid) with its calculated
#                fields and rule attributes added (ADR 0011), with the map
#                config's overrides, if any. Each calculated field shows its
#                expression; the rules table, how many features each action
#                is recommended for. Checks expressions before a build.
#
# Fields: per scalar field the non-null count, distinct count, min and max,
# and the values with their counts when there are at most 12 distinct ones.
# Polygon checks: invalid geometries (the pipeline fixes them with
# -makevalid), the union of all polygons (parts, holes, overlap as a share of
# the summed area) and GDAL's coverage check (edges of neighbours that
# overlap or leave a gap narrower than --gap-width). A contiguous coverage
# (touching polygons, no overlaps) suits LAYER_PROFILE=coverage.
#
# Exit status: 0 on success, 1 if the dataset cannot be read, 2 for a usage
# error.
set -euo pipefail

PIPELINE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=lib/log.sh
source "${PIPELINE_ROOT}/lib/log.sh"
# shellcheck source=lib/normalise.sh
source "${PIPELINE_ROOT}/lib/normalise.sh"
# For --config: the layer set, its settings and the derived attributes.
# shellcheck source=lib/config.sh
source "${PIPELINE_ROOT}/lib/config.sh"
# shellcheck source=lib/display.sh
source "${PIPELINE_ROOT}/lib/display.sh"
# shellcheck source=lib/mapconfig.sh
source "${PIPELINE_ROOT}/lib/mapconfig.sh"
# shellcheck source=lib/derive.sh
source "${PIPELINE_ROOT}/lib/derive.sh"

PIPELINE_INPUT_DIR=${PIPELINE_INPUT_DIR:-/data/raw}
PIPELINE_LAYERS_DIR=${PIPELINE_LAYERS_DIR:-${PIPELINE_ROOT}/layers}

# Fields with at most this many distinct values get their values listed.
INSPECT_MAX_VALUES=12

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# layer_info DATASET LAYER: ogrinfo's JSON summary of one layer, without the
# CRS WKT and PROJJSON bulk (the CRS name and id are kept).
layer_info() {
  ogrinfo -json -so "$1" "$2" | jq -c '.layers[0]
    | .geometryFields |= map(.coordinateSystem |= (
        if .projjson then {name: .projjson.name, id: .projjson.id} else null end))'
}

# field_stats DATASET LAYER INFO: one OGR SQL pass with min, max, distinct
# and non-null counts of every scalar field, as {"field": {...}, ...}.
field_stats() {
  local dataset=$1 layer=$2 info=$3
  local names=() name
  mapfile -t names < <(jq -r '.fields[]
    | select(.type | test("^(Integer|Integer64|Real|String|Date|DateTime|Time)$")) | .name' <<<"$info")
  if ((${#names[@]} == 0)); then
    echo '{}'
    return
  fi

  local cols=() i=0
  for name in "${names[@]}"; do
    local q
    q=$(ogr_quote "$name")
    cols+=("COUNT(${q}) AS n${i}" "COUNT(DISTINCT ${q}) AS d${i}" "MIN(${q}) AS lo${i}" "MAX(${q}) AS hi${i}")
    i=$((i + 1))
  done
  local select
  select=$(printf '%s, ' "${cols[@]}")

  ogr2ogr -f GeoJSON /vsistdout/ "$dataset" \
    -sql "SELECT ${select%, } FROM $(ogr_quote "$layer")" \
    | jq -c --args '.features[0].properties as $p
      | [$ARGS.positional | to_entries[] | (.key | tostring) as $i
         | {key: .value, value: {non_null: $p["n" + $i], distinct: $p["d" + $i],
                                 min: $p["lo" + $i], max: $p["hi" + $i]}}]
      | from_entries' "${names[@]}"
}

# field_values DATASET LAYER FIELD: the values of FIELD with their counts,
# most common first, as [{"value": ..., "count": n}, ...].
field_values() {
  local q
  q=$(ogr_quote "$3")
  ogr2ogr -f GeoJSON /vsistdout/ "$1" -dialect SQLite \
    -sql "SELECT ${q} AS value, COUNT(*) AS count FROM $(ogr_quote "$2") GROUP BY ${q} ORDER BY count DESC, value" \
    | jq -c '[.features[].properties]'
}

# wgs84_extent DATASET LAYER: [west, south, east, north] of every feature
# reprojected to EPSG:4326 (exact, unlike a reprojected bounding box).
wgs84_extent() {
  gdal vector pipeline read --layer "$2" "$1" \
    ! reproject --dst-crs EPSG:4326 \
    ! sql --dialect SQLite "SELECT Min(MbrMinX(geometry)) AS w, Min(MbrMinY(geometry)) AS s,
        Max(MbrMaxX(geometry)) AS e, Max(MbrMaxY(geometry)) AS n FROM $(ogr_quote "$2")" \
    ! write -f GeoJSON /vsistdout/ \
    | jq -c '.features[0].properties | [.w, .s, .e, .n]'
}

# polygon_checks DATASET LAYER GAP_WIDTH: invalid geometries, the union of
# every (made valid) polygon, and GDAL's coverage check, as one JSON object.
polygon_checks() {
  local dataset=$1 layer=$2 gap=$3
  local invalid union edges
  invalid=$(gdal vector pipeline read --layer "$layer" "$dataset" ! check-geometry \
    ! write -f GeoJSON /vsistdout/ | jq '.features | length')

  # NumInteriorRings per part of the union, through a recursive CTE.
  union=$(ogr2ogr -f GeoJSON /vsistdout/ "$dataset" -dialect SQLite -sql "
    WITH RECURSIVE u AS (
      SELECT ST_Union(MakeValid(geometry)) AS g, SUM(ST_Area(MakeValid(geometry))) AS total
      FROM $(ogr_quote "$layer")),
    n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n, u WHERE i < ST_NumGeometries(u.g))
    SELECT ST_NumGeometries(u.g) AS parts, SUM(NumInteriorRings(ST_GeometryN(u.g, n.i))) AS holes,
      u.total AS total, ST_Area(u.g) AS union_area FROM n, u" \
    | jq -c '.features[0].properties')

  edges=$(gdal vector pipeline read --layer "$layer" "$dataset" \
    ! reproject --dst-crs EPSG:3857 \
    ! check-coverage --maximum-gap-width "$gap" \
    ! write -f GeoJSON /vsistdout/ | jq '.features | length')

  jq -cn --argjson invalid "$invalid" --argjson u "$union" --argjson edges "$edges" \
    --argjson gap "$gap" '{
      invalid_geometries: $invalid,
      union_parts: $u.parts,
      union_holes: $u.holes,
      overlap_pct: (if ($u.total // 0) > 0
        then (((($u.total - $u.union_area) / $u.total * 100) * 1000 | round) / 1000)
        else null end),
      coverage_invalid_edges: $edges,
      gap_width_m: $gap
    }'
}

# inspect DATASET INPUT LAYER CHECKS GAP_WIDTH: the JSON summary.
inspect() {
  local dataset=$1 input=$2 layer=$3 checks=$4 gap=$5
  local all_layers info driver
  all_layers=$(ogrinfo -json -so "$dataset" | jq -c '{driver: .driverShortName, layers: [.layers[].name]}') \
    || die "cannot read $input"
  driver=$(jq -r .driver <<<"$all_layers")
  if [[ -z $layer ]]; then
    layer=$(jq -r '.layers[0] // empty' <<<"$all_layers")
    [[ -n $layer ]] || die "no layers in $input"
  elif ! jq -e --arg l "$layer" '.layers | index($l)' <<<"$all_layers" >/dev/null; then
    die "no layer '$layer' in $input (layers: $(jq -r '.layers | join(", ")' <<<"$all_layers"))"
  fi
  info=$(layer_info "$dataset" "$layer") || die "cannot read layer $layer of $input"

  local stats
  stats=$(field_stats "$dataset" "$layer" "$info") || die "cannot compute field stats for $input"

  # Values of low-cardinality fields.
  local values='{}' name
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    values=$(jq -c --arg k "$name" --argjson v "$(field_values "$dataset" "$layer" "$name")" \
      '. + {($k): $v}' <<<"$values")
  done < <(jq -r --argjson max "$INSPECT_MAX_VALUES" \
    'to_entries[] | select(.value.distinct > 0 and .value.distinct <= $max) | .key' <<<"$stats")

  local geom_type has_crs extent=null polygon=false checks_json=null
  geom_type=$(jq -r '.geometryFields[0].type // "None"' <<<"$info")
  has_crs=$(jq -r '.geometryFields[0].coordinateSystem != null' <<<"$info")
  if [[ $has_crs == true && $geom_type != None ]]; then
    extent=$(wgs84_extent "$dataset" "$layer") || extent=null
  fi
  [[ $geom_type == *Polygon* ]] && polygon=true
  if [[ $checks == 1 && $polygon == true ]]; then
    checks_json=$(polygon_checks "$dataset" "$layer" "$gap") || die "geometry checks failed for $input"
  fi

  jq -n --arg input "$input" --arg driver "$driver" --argjson all "$all_layers" \
    --argjson info "$info" --argjson stats "$stats" --argjson values "$values" \
    --argjson extent "$extent" --argjson checks "$checks_json" '
    ($info.metadata.SHAPEFILE // {}) as $shp
    | ($info.featureCount) as $count
    | {
        input: $input,
        driver: $driver,
        layers: $all.layers,
        layer: $info.name,
        feature_count: $count,
        geometry_type: ($info.geometryFields[0].type // null),
        crs: ($info.geometryFields[0].coordinateSystem // null),
        extent: ($info.geometryFields[0].extent // null),
        extent_wgs84: $extent,
        encoding: (if $driver == "ESRI Shapefile" then {
            source: ($shp.SOURCE_ENCODING // null),
            declared_by: (if $shp.ENCODING_FROM_CPG then "cpg"
              elif $shp.ENCODING_FROM_LDID then "ldid" else null end)
          } else null end),
        fields: [$info.fields[] | {name, type} + (if .width then {width} else {} end)
          + ($stats[.name] // {})
          + (if $values[.name] then {values: $values[.name]} else {} end)],
        id_candidates: [$info.fields[]
          | select(.type == "Integer" or .type == "Integer64")
          | select($stats[.name].non_null == $count and $stats[.name].distinct == $count)
          | .name],
        checks: $checks
      }
    | .warnings = ([
        (if .crs == null and .geometry_type != null then
          "no CRS: set LAYER_SOURCE_SRS (for example EPSG:3347)" else empty end),
        (if .encoding != null and .encoding.source == null then
          "no encoding declared (.cpg or DBF language id): if text looks wrong, set LAYER_ENCODING (for example ISO-8859-1)" else empty end),
        (if $driver == "ESRI Shapefile" then
          (.fields[] | select(.name | length == 10)
           | "field \(.name) is 10 characters long, maybe cut short by the shapefile format: rename with src:dest in LAYER_FIELDS")
         else empty end),
        (if (.id_candidates | length) == 0 then
          "no unique non-null integer field for LAYER_FEATURE_ID" else empty end),
        (if $checks != null and $checks.invalid_geometries > 0 then
          "\($checks.invalid_geometries) invalid geometry location(s): the pipeline makes them valid, but check the source" else empty end),
        (if $checks != null and ($checks.overlap_pct // 0) > 0.001 then
          "polygons overlap (\($checks.overlap_pct)% of the summed area)" else empty end),
        (if $checks != null and $checks.coverage_invalid_edges > 0 then
          "\($checks.coverage_invalid_edges) coverage edge(s) overlap or leave gaps narrower than \($checks.gap_width_m) m" else empty end)
      ])
    | .coverage_like = (if $checks == null then null else
        ($checks.union_parts < $count and ($checks.overlap_pct // 0) <= 0.001) end)'
}

# config_data NAME OUT_DIR: for --config, write configured layer NAME's data
# as its build sees it to OUT_DIR/NAME.geojsonl: normalised, with its
# calculated fields and rule attributes added (lib/derive.sh), and its plan
# to OUT_DIR/derive.json if it has any. Prints LAYER_INPUT. Run in a
# subshell: it loads the layer's settings.
config_data() {
  local name=$1 out=$2
  layer_known "$name" || die "no layer named $name (layers: $(layer_names | paste -sd ' '))"
  PIPELINE_LOG_PREFIX=$name
  load_layer_config "$(layer_get "$name" env)"
  [[ $LAYER_TYPE == vector ]] || die "$name is a $LAYER_TYPE layer: inspect its LAYER_INPUT instead"
  local data="${out}/${name}.geojsonl" plan=""
  if layer_derives; then
    plan="${out}/derive.json"
    derive_plan "$name" "$name" "$plan"
  fi
  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" "$LAYER_ENCODING" \
    "$data" "${LAYER_FIELDS[@]}"
  if [[ -n $plan ]]; then derive_apply "$data" "$plan"; fi
  printf '%s\n' "$LAYER_INPUT"
}

# with_config SUMMARY OUT_DIR NAME INPUT: SUMMARY (the JSON from inspect on
# config_data's output) with `config`: the layer, its input, and its
# calculated fields and rules with their counts (derive_report), and each
# calculated field's `calculated` expression.
with_config() {
  local summary=$1 out=$2 name=$3 input=$4 plan='{"calculated": [], "rules": null}'
  local derived='{"calculated_fields": null, "rules": null}'
  if [[ -s "${out}/derive.json" ]]; then
    plan=$(jq -c '.' "${out}/derive.json")
    derived=$(derive_report "${out}/${name}.geojsonl" "${out}/derive.json")
  fi
  jq -c --arg name "$name" --arg input "$input" --argjson plan "$plan" --argjson d "$derived" '
    .driver = "as built" | .config = {layer: $name, input: $input,
               calculated_fields: $d.calculated_fields, rules: $d.rules}
    | .fields |= map(.name as $n
        | ([$plan.calculated[] | select(.name == $n) | .expression] | first) as $e
        | if $e then . + {calculated: $e} else . end)' <<<"$summary"
}

# human JSON: the summary as text.
human() {
  jq -r '
    def num: if type == "number" and . != floor then (. * 1000 | round / 1000) else . end;
    def v: if . == null then "-" else (num | tostring) end;
    (if .config then
      "Config:     layer \(.config.layer), as built (LAYER_FIELDS, calculated fields, rules) from \(.config.input)"
     else empty end),
    "Input:      \(.input) (\(.driver))",
    (if (.layers | length) > 1 then "Layers:     \(.layers | join(", ")) (showing \(.layer))" else empty end),
    "Layer:      \(.layer)",
    "Features:   \(.feature_count)",
    "Geometry:   \(.geometry_type // "none")",
    "CRS:        \(if .crs then "\(.crs.name)\(if .crs.id then " (\(.crs.id.authority):\(.crs.id.code))" else "" end)" else "none" end)",
    "Extent:     \(if .extent then (.extent | map(num | tostring) | join(", ")) else "-" end)",
    "WGS84:      \(if .extent_wgs84 then (.extent_wgs84 | map(. * 100000 | round / 100000 | tostring) | join(", ")) else "-" end)",
    (if .encoding then "Encoding:   \(.encoding.source // "not declared")\(if .encoding.declared_by then " (from \(.encoding.declared_by))" else "" end)" else empty end),
    "ID fields:  \(if (.id_candidates | length) > 0 then (.id_candidates | join(", ")) else "none" end)",
    "",
    "Fields:",
    (.fields[] | "  \(.name) \(.type)\(if .width then "(\(.width))" else "" end): non-null \(.non_null | v), distinct \(.distinct | v), min \(.min | v), max \(.max | v)"
      + (if .calculated then "\n    calculated: \(.calculated)" else "" end)
      + (if .values then "\n    values: " + ([.values[] | "\(.value | v) (\(.count))"] | join(", ")) else "" end)),
    (if .config.rules then
      "",
      "Rules:      \(.config.rules.file)",
      (.config.rules.actions[] | "  \(.id) (\(.type)): \(.condition)\n    recommended for \(.recommended) feature(s): \(.attribute), \(.reason_attribute)"),
      (.config.rules.types[] | "  type \(.id): \(.features) feature(s) with an action (\(.attribute))")
     else empty end),
    (if .checks then
      "",
      "Checks:",
      "  invalid geometries:      \(.checks.invalid_geometries)",
      "  union:                   \(.checks.union_parts) part(s), \(.checks.union_holes) hole(s)",
      "  overlap:                 \(.checks.overlap_pct | v)% of summed area",
      "  coverage invalid edges:  \(.checks.coverage_invalid_edges) (gaps under \(.checks.gap_width_m) m)",
      "  coverage-like:           \(if .coverage_like then "yes (touching, no overlaps): consider LAYER_PROFILE=coverage" else "no" end)"
     else empty end),
    (if (.warnings | length) > 0 then "", "Warnings:", (.warnings[] | "  - \(.)") else empty end)
  '
}

main() {
  local json=0 layer="" checks=1 gap=100 input="" config=""
  while (($# > 0)); do
    case $1 in
      -h | --help)
        usage
        return 0
        ;;
      --json) json=1 ;;
      --no-checks) checks=0 ;;
      --layer | --gap-width | --config)
        if (($# < 2)); then
          log_error "$1 needs a value"
          return 2
        fi
        case $1 in
          --layer) layer=$2 ;;
          --config) config=$2 ;;
          *) gap=$2 ;;
        esac
        shift
        ;;
      -*)
        log_error "unknown option: $1"
        usage >&2
        return 2
        ;;
      *)
        if [[ -n $input ]]; then
          log_error "one input only (got $input and $1)"
          return 2
        fi
        input=$1
        ;;
    esac
    shift
  done
  if [[ -n $config && ( -n $input || -n $layer ) ]]; then
    log_error "--config takes the input and layer from the layer's config: give no INPUT or --layer"
    return 2
  fi
  if [[ -z $input && -z $config ]]; then
    log_error "no input given"
    usage >&2
    return 2
  fi
  if ! [[ $gap =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_error "--gap-width must be a non-negative number: $gap"
    return 2
  fi

  local dataset summary
  if [[ -n $config ]]; then
    local scratch
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/inspect.XXXXXX")
    # shellcheck disable=SC2064 # expand now: scratch is local to main.
    trap "rm -rf '${scratch}'" EXIT
    resolve_layers "${scratch}/resolved" || return 2
    input=$(config_data "$config" "$scratch") || return 1
    summary=$(inspect "${scratch}/${config}.geojsonl" "$input" "" "$checks" "$gap")
    summary=$(with_config "$summary" "$scratch" "$config" "${input#"${PIPELINE_INPUT_DIR}"/}")
  else
    [[ $input == /* ]] || input="${PIPELINE_INPUT_DIR}/${input}"
    dataset=$(gdal_input_path "$input") || return 1
    summary=$(inspect "$dataset" "$input" "$layer" "$checks" "$gap")
  fi
  if ((json)); then
    printf '%s\n' "$summary"
  else
    human <<<"$summary"
  fi
}

main "$@"
