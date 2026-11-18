#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Summarise a source dataset before writing a layer config for it: layers,
# feature count, geometry type, CRS, extent, encoding, fields with simple
# stats, feature id candidates and, for polygons, geometry and coverage
# checks. Read only; GDAL/OGR based.
#
# Usage: inspect.sh [-h|--help] [--json | --starter] [--layer NAME] [--no-checks]
#                   [--gap-width METRES] INPUT
#        inspect.sh [-h|--help] [--json] [--no-checks] [--gap-width METRES]
#                   --config LAYER
#
#   INPUT        source dataset. Relative paths are resolved against
#                PIPELINE_INPUT_DIR (default /data/raw), like a layer's source. A
#                `.zip`, or a file inside one (`data.zip/dir/file.shp`), is
#                read in place.
#   --json       print JSON instead of the human-readable summary.
#   --starter    print a starter layer file (<layer>.yaml) for the dataset
#                instead: source, every field (renamed to lower case where
#                needed), a profile and zooms from the geometry and extent,
#                one colour and a pop-up listing the fields. It is valid as
#                printed; check every value before building.
#   --layer      layer inside the dataset (default: the first one).
#   --no-checks  skip the geometry and coverage checks (slow on big data).
#   --gap-width  narrowest gap between neighbours that is not flagged by
#                the coverage check, in Web Mercator metres (default 100).
#   --config     inspect layer LAYER as its build sees it, instead of an
#                INPUT: its source data (source.path and source.layer in
#                its layer file) normalised (fields.keep kept, renamed, in
#                EPSG:4326, made valid; the feature id as _feature_id) with
#                its calculated fields added, with the map config's
#                overrides, if any. Each calculated field shows its
#                expression. Checks the expressions before a build.
#
# Fields: per scalar field the non-null count, distinct count, min and max,
# and the values with their counts when there are at most 12 distinct ones.
# Polygon checks: invalid geometries (the pipeline fixes them with
# -makevalid), the union of all polygons (parts, holes, overlap as a share of
# the summed area) and GDAL's coverage check (edges of neighbours that
# overlap or leave a gap narrower than --gap-width). A contiguous coverage
# (touching polygons, no overlaps) suits the coverage processing profile.
#
# Exit status: 0 on success, 1 if the dataset cannot be read, 2 for a usage
# error.
set -euo pipefail

PIPELINE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=lib/log.sh
source "${PIPELINE_ROOT}/lib/log.sh"
# shellcheck source=lib/normalise.sh
source "${PIPELINE_ROOT}/lib/normalise.sh"
# For --config: the layer files and the calculated fields.
# shellcheck source=lib/layerfile.sh
source "${PIPELINE_ROOT}/lib/layerfile.sh"
# shellcheck source=lib/joins.sh
source "${PIPELINE_ROOT}/lib/joins.sh"
# shellcheck source=lib/calculated.sh
source "${PIPELINE_ROOT}/lib/calculated.sh"

PIPELINE_INPUT_DIR=${PIPELINE_INPUT_DIR:-/data/raw}
PIPELINE_LAYERS_DIR=${PIPELINE_LAYERS_DIR:-${PIPELINE_ROOT}/layers}
PIPELINE_LOCAL_LAYERS_DIR=${PIPELINE_LOCAL_LAYERS_DIR-${PIPELINE_ROOT}/layers.local}

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

# geometry_column INFO: the layer's geometry column, quoted for SQL. A
# shapefile has no name for it (SQL calls it geometry); FileGDB calls it
# SHAPE and GeoPackage geom, and SQL must use that name.
geometry_column() {
  ogr_quote "$(jq -r '.geometryFields[0].name // "" | if . == "" then "geometry" else . end' <<<"$1")"
}

# wgs84_extent DATASET LAYER GEOM: [west, south, east, north] of every
# feature reprojected to EPSG:4326 (exact, unlike a reprojected bounding
# box). GEOM is the quoted geometry column (geometry_column).
wgs84_extent() {
  local g=$3
  gdal vector pipeline read --layer "$2" "$1" \
    ! reproject --dst-crs EPSG:4326 \
    ! sql --dialect SQLite "SELECT Min(MbrMinX($g)) AS w, Min(MbrMinY($g)) AS s,
        Max(MbrMaxX($g)) AS e, Max(MbrMaxY($g)) AS n FROM $(ogr_quote "$2")" \
    ! write -f GeoJSON /vsistdout/ \
    | jq -c '.features[0].properties | [.w, .s, .e, .n]'
}

# polygon_checks DATASET LAYER GAP_WIDTH GEOM: invalid geometries, the
# union of every (made valid) polygon, and GDAL's coverage check, as one
# JSON object. GEOM is the quoted geometry column (geometry_column).
polygon_checks() {
  local dataset=$1 layer=$2 gap=$3 g=$4
  local invalid union edges
  invalid=$(gdal vector pipeline read --layer "$layer" "$dataset" ! check-geometry \
    ! write -f GeoJSON /vsistdout/ | jq '.features | length')

  # NumInteriorRings per part of the union, through a recursive CTE.
  union=$(ogr2ogr -f GeoJSON /vsistdout/ "$dataset" -dialect SQLite -sql "
    WITH RECURSIVE u AS (
      SELECT ST_Union(MakeValid($g)) AS g, SUM(ST_Area(MakeValid($g))) AS total
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

  local geom_type has_crs geom extent=null polygon=false checks_json=null
  geom_type=$(jq -r '.geometryFields[0].type // "None"' <<<"$info")
  has_crs=$(jq -r '.geometryFields[0].coordinateSystem != null' <<<"$info")
  geom=$(geometry_column "$info")
  if [[ $has_crs == true && $geom_type != None ]]; then
    extent=$(wgs84_extent "$dataset" "$layer" "$geom") || extent=null
  fi
  [[ $geom_type == *Polygon* ]] && polygon=true
  if [[ $checks == 1 && $polygon == true ]]; then
    checks_json=$(polygon_checks "$dataset" "$layer" "$gap" "$geom") || die "geometry checks failed for $input"
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
          "no CRS: set source.srs in the layer file (for example EPSG:3347)" else empty end),
        (if .encoding != null and .encoding.source == null then
          "no encoding declared (.cpg or DBF language id): if text looks wrong, set source.encoding in the layer file (for example ISO-8859-1)" else empty end),
        (if $driver == "ESRI Shapefile" then
          (.fields[] | select(.name | length == 10)
           | "field \(.name) is 10 characters long, maybe cut short by the shapefile format: rename it with {source_name: output_name} in fields.keep")
         else empty end),
        (if (.id_candidates | length) == 0 then
          "no unique non-null integer field for source.id" else empty end),
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

# config_data NAME OUT_DIR: for --config, write layer NAME's data as its
# build sees it to OUT_DIR/NAME.geojsonl: normalised, with its calculated
# fields added (lib/calculated.sh), and their report to
# OUT_DIR/calculated.json if it has any. Prints its source path, resolved.
# Run in a subshell: it loads the layer's settings.
config_data() {
  local name=$1 out=$2
  layer_known "$name" || die "no layer named $name (layers: $(layer_names | paste -sd ' '))"
  PIPELINE_LOG_PREFIX=$name
  load_layer "$name"
  [[ $LAYER_TYPE == vector ]] || die "$name is a $LAYER_TYPE layer: inspect its source ($LAYER_INPUT) instead"
  local data="${out}/${name}.geojsonl"
  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" "$LAYER_ENCODING" \
    "$data" "${LAYER_FIELDS[@]}"
  if ((${#LAYER_CALCULATED_NAMES[@]} > 0)); then
    add_calculated_fields "$data" "${out}/calculated.geojsonl" "${out}/calculated.json"
    mv -f -- "${out}/calculated.geojsonl" "$data"
  fi
  printf '%s\n' "$LAYER_INPUT"
}

# with_config SUMMARY OUT_DIR NAME INPUT: SUMMARY (the JSON from inspect on
# config_data's output) with `config`: the layer, its input and its
# calculated fields with their counts, and each calculated field's
# `calculated` expression.
with_config() {
  local summary=$1 out=$2 name=$3 input=$4 calculated=null
  if [[ -s "${out}/calculated.json" ]]; then
    calculated=$(jq -c '.' "${out}/calculated.json")
  fi
  jq -c --arg name "$name" --arg input "$input" --argjson c "$calculated" '
    .driver = "as built" | .config = {layer: $name, input: $input, calculated_fields: $c}
    | .fields |= map(.name as $n
        | ([($c // [])[] | select(.name == $n) | .expression] | first) as $e
        | if $e then . + {calculated: $e} else . end)' <<<"$summary"
}

# starter JSON: a starter layer file (YAML) from the summary JSON, valid
# against schema/layer.schema.json as printed. `source` with the path
# (relative to PIPELINE_INPUT_DIR when under it), the layer and an id (a
# unique integer field, preferring id, objectid or fid); `fields.keep` with
# every other scalar field, renamed to a lower case output name where
# needed (OwnerType: owner_type); the profile from the geometry type (and
# the coverage check), the max zoom from the extent (z where the extent
# fills one tile, plus 10, kept to 8 to 14: 12 for Canada); one style
# layer per geometry type with a one-colour legend and a pop-up listing the
# fields.
starter() {
  local layer_file
  layer_file=$(jq --arg dir "${PIPELINE_INPUT_DIR%/}/" '
    def snake:
      gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)")
      | gsub("(?<a>[A-Z])(?<b>[A-Z][a-z])"; "\(.a)_\(.b)")
      | ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; "")
      | if . == "" then "field" elif test("^[0-9]") then "f_" + . else . end;
    def nice: gsub("_"; " ") | (.[0:1] | ascii_upcase) + .[1:];
    def scalar: .type | test("^(Integer|Integer64|Real|String|Date|DateTime|Time)$");

    (.layer | nice) as $title
    | (.geometry_type // "None") as $g
    | (if $g | test("Point") then "point" elif $g | test("Line|Curve") then "line"
       elif $g | test("Polygon|Surface") then "polygon" else "mixed" end) as $kind
    | ([.id_candidates[] | select(test("^(id|objectid|fid)$"; "i"))] + .id_candidates
       + [.fields[] | select(.type | test("^Integer")) | .name]
       + [.fields[] | select(scalar) | .name] | first) as $id
    # Output names unique: a later clash gets _2, _3, ...
    | (reduce (.fields[] | select(scalar and .name != $id)) as $f ([];
         [.[].out] as $used | ($f.name | snake) as $n
         | . + [$f + {out: (first(range(1; 1000)
             | if . == 1 then $n else "\($n)_\(.)" end
             | select(. as $c | $used | index($c) | not)))}])) as $keep
    | (.extent_wgs84 // null) as $e
    | (if $e == null then 12
       else ([($e[2] - $e[0]), ($e[3] - $e[1])] | max) as $span
         | if $span <= 0 then 14
           else ((360 / $span | log2 | floor) + 10) | if . < 8 then 8 elif . > 14 then 14 else . end
           end
       end) as $maxzoom
    | {color: "#3182bd", dark: "#08519c"} as $c
    | {
        title: $title,
        visible: true,
        order: 0,
        source: ({path: (if .input | startswith($dir) then .input[($dir | length):] else .input end),
                  layer: .layer}
                 + (if $id then {id: $id} else {} end)),
      }
      + (if ($keep | length) > 0 then
          {fields: {keep: [$keep[] | if .out == .name then .name else {(.name): .out} end]}}
         else {} end)
      + {
        processing: {
          profile: (if $kind == "point" then "points"
                    elif $kind == "polygon" and .coverage_like == true then "coverage"
                    else "default" end),
          minzoom: 0,
          maxzoom: $maxzoom
        },
        display: {
          layers: (
            [ {id: "fill", type: "fill", geom: ["Polygon", "MultiPolygon"],
               paint: {"fill-color": $c.color, "fill-opacity": 0.6}},
              {id: "outline", type: "line", geom: ["Polygon", "MultiPolygon"],
               paint: {"line-color": $c.dark, "line-width": 0.5}},
              {id: "line", type: "line", geom: ["LineString", "MultiLineString"],
               paint: {"line-color": $c.color, "line-width": 1.5}},
              {id: "circle", type: "circle", geom: ["Point", "MultiPoint"],
               paint: {"circle-color": $c.color, "circle-radius": 5,
                       "circle-stroke-color": "#ffffff", "circle-stroke-width": 1}} ]
            | map(select(.id as $l
                | {polygon: ["fill", "outline"], line: ["line"], point: ["circle"],
                   mixed: ["fill", "outline", "line", "circle"]}[$kind] | index($l)))
            | map((if $kind == "mixed" then
                    {id, type, filter: ["match", ["geometry-type"], .geom, true, false], paint}
                   else {id, type, paint} end))),
          legend: {
            kind: "single",
            shape: ({polygon: "square", line: "line", point: "circle", mixed: "square"}[$kind]),
            items: [{color: $c.color, label: $title}]
          },
          popup: {
            title: ([$keep[] | select(.type == "String") | {attribute: .out}] | first // {featureId: true}),
            stats: ([{label: "ID", value: {featureId: true}}]
              + [$keep[] | {label: (.out | nice), value: {attribute: .out}}
                  + (if .type | test("^(Integer|Integer64|Real)$") then {format: {}} else {} end)])
          }
        }
      }' <<<"$1") || die "cannot write a starter layer file"
  [[ $(jq -r '.source.id // ""' <<<"$layer_file") != "" ]] \
    || die "no attribute for source.id (the feature id): a vector layer needs a unique integer field"

  # Comments: how it was made and what to check, the summary's warnings,
  # and notes on the settings that are guesses.
  local name
  name=$(jq -r '.layer | ascii_downcase | gsub("[^a-z0-9_-]+"; "_")' <<<"$1")
  printf '%s\n' "# yaml-language-server: \$schema=../schema/layer.schema.json" "#" \
    "# A starter layer file printed by inspect.sh --starter: check every value" \
    "# (title, id, fields, zooms, colours, pop-up). Save it as" \
    "# pipeline/layers/${name}.yaml, or pipeline/layers.local/ for your own map."
  jq -r 'if (.warnings | length) > 0 then "#", "# inspect.sh warnings:", (.warnings[] | "# - \(.)") else empty end' <<<"$1"
  printf '\n'
  local id_note profile_note zoom_note
  id_note=$(jq -r 'if (.id_candidates | length) == 0
    then "not unique and non-null in every feature: check, or add an id to the source"
    else "" end' <<<"$1")
  profile_note=$(jq -r '
    if .geometry_type == null or (.geometry_type | test("Point|Line|Curve|Polygon|Surface") | not)
      then "mixed or unknown geometry: one style layer per geometry type"
    elif (.geometry_type | test("Polygon|Surface")) and .coverage_like == null
      then "coverage not checked (--no-checks): use coverage if the polygons tile the land"
    else "" end' <<<"$1")
  zoom_note=$(jq -r 'if .extent_wgs84 == null then "no extent in EPSG:4326 (no CRS?): check" else "from the extent: lower it for a large or dense layer" end' <<<"$1")
  ID_NOTE=$id_note PROFILE_NOTE=$profile_note ZOOM_NOTE=$zoom_note \
    yq -p json -o yaml '
      ... style = ""
      | .source.id line_comment = strenv(ID_NOTE)
      | .processing.profile line_comment = strenv(PROFILE_NOTE)
      | .processing.maxzoom line_comment = strenv(ZOOM_NOTE)
      | .display.layers head_comment = "One colour: colour by an attribute with a MapLibre expression."
      | (.display.legend.items[], .display.popup.stats[],
         (.display.layers[] | select(has("filter")) | .filter)) style = "flow"
      | (.. | select(tag == "!!str" and test("^#"))) style = "double"
    ' <<<"$layer_file"
}

# human JSON: the summary as text.
human() {
  jq -r '
    def num: if type == "number" and . != floor then (. * 1000 | round / 1000) else . end;
    def v: if . == null then "-" else (num | tostring) end;
    (if .config then
      "Config:     layer \(.config.layer), as built (fields.keep and calculated fields) from \(.config.input)"
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
    (if .checks then
      "",
      "Checks:",
      "  invalid geometries:      \(.checks.invalid_geometries)",
      "  union:                   \(.checks.union_parts) part(s), \(.checks.union_holes) hole(s)",
      "  overlap:                 \(.checks.overlap_pct | v)% of summed area",
      "  coverage invalid edges:  \(.checks.coverage_invalid_edges) (gaps under \(.checks.gap_width_m) m)",
      "  coverage-like:           \(if .coverage_like then "yes (touching, no overlaps): consider processing.profile: coverage" else "no" end)"
     else empty end),
    (if (.warnings | length) > 0 then "", "Warnings:", (.warnings[] | "  - \(.)") else empty end)
  '
}

main() {
  local json=0 starter=0 layer="" checks=1 gap=100 input="" config=""
  while (($# > 0)); do
    case $1 in
      -h | --help)
        usage
        return 0
        ;;
      --json) json=1 ;;
      --starter) starter=1 ;;
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
  if ((json && starter)); then
    log_error "--json and --starter: give one"
    return 2
  fi
  if [[ -n $config ]] && ((starter)); then
    log_error "--starter is for a dataset, not --config: the layer already has a file"
    return 2
  fi
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
  if ((starter)); then
    starter "$summary"
  elif ((json)); then
    printf '%s\n' "$summary"
  else
    human <<<"$summary"
  fi
}

main "$@"
