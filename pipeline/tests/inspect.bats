#!/usr/bin/env bats
# bin/inspect.sh, the source dataset summary, on the synthetic fixtures. The
# shapefiles are made here with ogr2ogr, so no binaries are committed. Run in
# the test image with the other bats files.

setup_file() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  export PIPELINE_ROOT
  export PIPELINE_INPUT_DIR="${BATS_FILE_TMPDIR}/raw"
  mkdir -p "${PIPELINE_INPUT_DIR}/shp"
  local coverage="${BATS_FILE_TMPDIR}/coverage.geojson"
  "${PIPELINE_ROOT}/tests/fixtures/make_coverage.sh" >"$coverage"

  # The coverage as a Latin-1 shapefile in Statistics Canada Lambert, with a
  # non-ASCII value and two field names cut to 10 characters.
  ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:3347 -lco ENCODING=ISO-8859-1 \
    "${PIPELINE_INPUT_DIR}/shp/coverage.shp" "$coverage" -dialect SQLite -sql \
    "SELECT geometry, id, kind,
       CASE kind WHEN 'large' THEN 'Forêt' ELSE 'Prairie' END AS habitat_type,
       (id * 37) % 100 AS score_value FROM coverage" 2>/dev/null

  # The same coverage with feature 1 grown by 0.05 degrees: it overlaps its
  # neighbours.
  ogr2ogr -f GeoJSON "${PIPELINE_INPUT_DIR}/overlap.geojson" "$coverage" -dialect SQLite -sql \
    "SELECT CASE id WHEN 1 THEN ST_Buffer(geometry, 0.05) ELSE geometry END AS geometry, id, kind
     FROM coverage"
}

setup() {
  INSPECT="${PIPELINE_ROOT}/bin/inspect.sh"
  FIXTURES="${PIPELINE_ROOT}/tests/fixtures"
}

# json_of ARGS...: run inspect.sh --json ARGS and keep its stdout in $JSON.
json_of() {
  JSON=$("$INSPECT" --json "$@")
}

@test "summarises a shapefile: CRS, extent, encoding, fields, id candidates" {
  json_of shp/coverage.shp
  run jq -r '"\(.driver)|\(.layer)|\(.feature_count)|\(.geometry_type)|\(.crs.id.code)|\(.encoding.source)|\(.encoding.declared_by)|\(.id_candidates | join(","))"' <<<"$JSON"
  [ "$output" = "ESRI Shapefile|coverage|1058|Polygon|3347|ISO-8859-1|cpg|id" ]

  # The extent in WGS84 is the fixture's rectangle, -120..-100, 50..60.
  run jq -e '.extent_wgs84 as $b | [-120, 50, -100, 60] as $want
    | all(range(4); ($b[.] - $want[.]) | fabs < 0.001)' <<<"$JSON"
  [ "$status" -eq 0 ]

  run jq -c '.fields[] | select(.name == "kind") | [.non_null, .distinct, .values]' <<<"$JSON"
  [ "$output" = '[1058,3,[{"value":"tiny","count":1000},{"value":"medium","count":40},{"value":"large","count":18}]]' ]
  run jq -c '.fields[] | select(.name == "habitat_ty") | [.values[].value]' <<<"$JSON"
  [ "$output" = '["Prairie","Forêt"]' ]
  # Too many distinct values to list.
  run jq -c '.fields[] | select(.name == "score_valu") | [.min, .max, .distinct, has("values")]' <<<"$JSON"
  [ "$output" = '[0,99,100,false]' ]

  run jq -r '.warnings[]' <<<"$JSON"
  [[ $output == *"field habitat_ty is 10 characters long"* ]]
  [[ $output == *"field score_valu is 10 characters long"* ]]
}

@test "a contiguous coverage is reported as coverage-like" {
  json_of shp/coverage.shp
  run jq -c '[.checks.invalid_geometries, .checks.union_parts, .checks.union_holes,
    .checks.overlap_pct, .checks.coverage_invalid_edges, .coverage_like]' <<<"$JSON"
  [ "$output" = '[0,1,0,0,0,true]' ]

  run "$INSPECT" shp/coverage.shp
  [ "$status" -eq 0 ]
  [[ $output == *"CRS:        NAD83 / Statistics Canada Lambert (EPSG:3347)"* ]]
  [[ $output == *"Encoding:   ISO-8859-1 (from cpg)"* ]]
  [[ $output == *"consider processing.profile: coverage"* ]]
}

@test "overlapping polygons are flagged and not coverage-like" {
  json_of overlap.geojson
  run jq -e '.checks.overlap_pct > 0 and .checks.coverage_invalid_edges > 0
    and .coverage_like == false' <<<"$JSON"
  [ "$status" -eq 0 ]
  run jq -r '.warnings[]' <<<"$JSON"
  [[ $output == *"polygons overlap"* ]]
  [[ $output == *"coverage edge(s) overlap or leave gaps"* ]]
}

@test "separate polygons with an invalid geometry: not coverage-like, invalid counted" {
  json_of "${FIXTURES}/sample.geojson"
  run jq -c '[.encoding, .checks.invalid_geometries > 0, .coverage_like, .id_candidates]' <<<"$JSON"
  [ "$output" = '[null,true,false,["id","score","v2020","v2021","v2022","v2023","v2024"]]' ]
}

@test "points: values listed, no polygon checks; --no-checks skips them for polygons" {
  json_of "${FIXTURES}/sample_points.geojson"
  run jq -c '[.geometry_type, .checks, .coverage_like,
    (.fields[] | select(.name == "category") | [.values[].count] | add)]' <<<"$JSON"
  [ "$output" = '["Point",null,null,30]' ]

  json_of --no-checks shp/coverage.shp
  run jq -c '[.checks, .coverage_like]' <<<"$JSON"
  [ "$output" = '[null,null]' ]
}

@test "a file geodatabase and a GeoPackage: extent and checks read their geometry column" {
  # FileGDB names the geometry column SHAPE and GeoPackage geom, not
  # geometry as in a shapefile; the SQL in the checks must use that name.
  local gdb="${PIPELINE_INPUT_DIR}/coverage.gdb" gpkg="${PIPELINE_INPUT_DIR}/coverage.gpkg"
  ogr2ogr -f OpenFileGDB "$gdb" "${PIPELINE_INPUT_DIR}/shp/coverage.shp" -nln coverage
  ogr2ogr -f GPKG "$gpkg" "${PIPELINE_INPUT_DIR}/shp/coverage.shp" -nln coverage
  local input
  for input in "$gdb" "$gpkg"; do
    json_of "$input"
    run jq -e '.extent_wgs84 as $b | [-120, 50, -100, 60] as $want
      | all(range(4); ($b[.] - $want[.]) | fabs < 0.001)' <<<"$JSON"
    [ "$status" -eq 0 ]
    run jq -c '[.checks.invalid_geometries, .checks.union_parts, .checks.union_holes,
      .checks.overlap_pct, .checks.coverage_invalid_edges, .coverage_like]' <<<"$JSON"
    [ "$output" = '[0,1,0,0,0,true]' ]
  done
}

@test "a shapefile without .prj: no CRS, no WGS84 extent, a source.srs hint" {
  mkdir -p "${PIPELINE_INPUT_DIR}/noprj"
  ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:3347 "${PIPELINE_INPUT_DIR}/noprj/sample.shp" \
    "${FIXTURES}/sample.geojson"
  rm "${PIPELINE_INPUT_DIR}/noprj/sample.prj"

  json_of --no-checks noprj/sample.shp
  run jq -c '[.crs, .extent_wgs84]' <<<"$JSON"
  [ "$output" = '[null,null]' ]
  run jq -r '.warnings[]' <<<"$JSON"
  [[ $output == *"set source.srs in the layer file"* ]]
}

@test "reads a zipped shapefile in place and picks a layer with --layer" {
  ogr2ogr -f "ESRI Shapefile" "${PIPELINE_INPUT_DIR}/sample.shp.zip" "${FIXTURES}/sample.geojson"
  json_of --no-checks sample.shp.zip
  run jq -r '"\(.input)|\(.layer)|\(.feature_count)"' <<<"$JSON"
  [ "$output" = "${PIPELINE_INPUT_DIR}/sample.shp.zip|sample|15" ]

  local gpkg="${BATS_TEST_TMPDIR}/two.gpkg"
  ogr2ogr -f GPKG "$gpkg" "${FIXTURES}/sample.geojson" -nln polys
  ogr2ogr -f GPKG -update "$gpkg" "${FIXTURES}/sample_points.geojson" -nln points
  json_of --no-checks --layer points "$gpkg"
  run jq -c '[.layers, .layer, .feature_count]' <<<"$JSON"
  [ "$output" = '[["polys","points"],"points",30]' ]

  run "$INSPECT" --layer nope "$gpkg"
  [ "$status" -eq 1 ]
  [[ $output == *"no layer 'nope'"* ]]
}

@test "usage errors exit 2; a missing input exits 1" {
  run "$INSPECT"
  [ "$status" -eq 2 ]
  run "$INSPECT" --bogus x.shp
  [ "$status" -eq 2 ]
  run "$INSPECT" --gap-width abc x.shp
  [ "$status" -eq 2 ]
  run "$INSPECT" a.shp b.shp
  [ "$status" -eq 2 ]
  run "$INSPECT" --help
  [ "$status" -eq 0 ]
  [[ $output == *"Usage: inspect.sh"* ]]

  run "$INSPECT" missing.shp
  [ "$status" -eq 1 ]
  [[ $output == *"input not found: ${PIPELINE_INPUT_DIR}/missing.shp"* ]]
}

# starter_of NAME ARGS...: run inspect.sh --starter ARGS and save the
# starter as NAME.yaml in a layers dir of its own; then check it the way the
# pipeline reads layer files (jv against the schema, then its own checks,
# through run.sh --status): its state must not be `invalid`.
starter_of() {
  local name=$1
  shift
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  mkdir -p "$PIPELINE_LAYERS_DIR"
  STARTER="${PIPELINE_LAYERS_DIR}/${name}.yaml"
  "$INSPECT" --starter "$@" >"$STARTER"
  STATUS=$("${PIPELINE_ROOT}/bin/run.sh" --status --json)
  jq -e --arg n "$name" '.layers[] | select(.name == $n) | .state != "invalid"' <<<"$STATUS" \
    || { echo "$STATUS" >&2; cat "$STARTER" >&2; return 1; }
}

# set_starter EXPR: apply the yq EXPR to the starter in place.
set_starter() {
  yq -i "$1" "$STARTER"
}

@test "--starter: polygons, renamed fields, a pop-up; valid and builds" {
  starter_of sample "${FIXTURES}/sample.geojson"
  run yq -o json -I0 '[.source, .fields.keep[0], .processing.profile,
    [.display.layers[] | .type], .display.legend.items[0].label,
    .display.popup.title, .display.popup.sections[0].blocks[0].items[1]]' "$STARTER"
  [ "$output" = "[{\"path\":\"${FIXTURES}/sample.geojson\",\"layer\":\"sample\",\"id\":\"id\"},{\"NAME_EN\":\"name_en\"},\"default\",[\"fill\",\"line\"],\"Sample\",\"{name_en}\",{\"label\":\"Name en\",\"value\":{\"attribute\":\"name_en\"}}]" ]
  # Every field but the id, numbers with a number format.
  run yq -o json -I0 '[.fields.keep | length, (.display.popup.sections[0].blocks[0].items[] | select(.value.attribute == "score") | .format)]' "$STARTER"
  [ "$output" = '[9,"integer"]' ]
  # The warnings and notes are comments.
  run cat "$STARTER"
  [[ ${lines[0]} == "# yaml-language-server: \$schema=../schema/layer.schema.json" ]]
  [[ $output == *"# - 1 invalid geometry location(s)"* ]]
  [[ $output == *"maxzoom: 12 # from the extent"* ]]

  # It builds (at a lower max zoom, to be quick), with the renamed field.
  set_starter '.processing.maxzoom = 4'
  run "${PIPELINE_ROOT}/bin/run.sh" sample
  echo "$output"
  [ "$status" -eq 0 ]
  run bash -c "pmtiles show --metadata '${PIPELINE_OUTPUT_DIR}/sample.pmtiles' | jq -c '.vector_layers[0].fields | keys'"
  [ "$output" = '["area_ha","name_en","notes","score","v2020","v2021","v2022","v2023","v2024"]' ]
}

@test "--starter: points and a coverage get their profiles and zooms" {
  starter_of points "${FIXTURES}/sample_points.geojson"
  run yq -o json -I0 '[.processing, [.display.layers[] | .type], .display.legend.shape]' "$STARTER"
  [ "$output" = '[{"profile":"points","minzoom":0,"maxzoom":12},["circle"],"circle"]' ]

  # The coverage fixture is coverage-like, 20 degrees wide: z4 fits it in a
  # tile, so z14.
  starter_of coverage shp/coverage.shp
  run yq -o json -I0 '[.source.path, .source.id, .processing.profile, .processing.maxzoom]' "$STARTER"
  [ "$output" = '["shp/coverage.shp","id","coverage",14]' ]
  # Without the checks, coverage is not known: default, with a note.
  starter_of nochecks --no-checks shp/coverage.shp
  run yq -r '.processing.profile' "$STARTER"
  [ "$output" = default ]
  run cat "$STARTER"
  [[ $output == *"profile: default # coverage not checked (--no-checks)"* ]]
}

@test "--starter: lower case names, without clashes; no unique id is a note" {
  # Mixed case and odd names, a clash once lower cased, no unique integer.
  ogr2ogr -f GeoJSON "${PIPELINE_INPUT_DIR}/names.geojson" "${FIXTURES}/sample_points.geojson" \
    -dialect SQLite -sql "SELECT geometry, id % 3 AS code, name AS OwnerType,
      category AS owner_type, count % 7 AS \"2020 Value\", name AS HTMLName FROM sample_points"
  starter_of names names.geojson
  run yq -o json -I0 '[.source.id, .fields.keep]' "$STARTER"
  [ "$output" = '["code",[{"OwnerType":"owner_type"},{"owner_type":"owner_type_2"},{"2020 Value":"f_2020_value"},{"HTMLName":"html_name"}]]' ]
  run cat "$STARTER"
  [[ $output == *"id: code # not unique and non-null in every feature"* ]]
}

@test "--starter usage errors" {
  run "$INSPECT" --starter --json "${FIXTURES}/sample.geojson"
  [ "$status" -eq 2 ]
}
