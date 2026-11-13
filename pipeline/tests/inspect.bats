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
  [[ $output == *"consider LAYER_PROFILE=coverage"* ]]
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

@test "a shapefile without .prj: no CRS, no WGS84 extent, a LAYER_SOURCE_SRS hint" {
  mkdir -p "${PIPELINE_INPUT_DIR}/noprj"
  ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:3347 "${PIPELINE_INPUT_DIR}/noprj/sample.shp" \
    "${FIXTURES}/sample.geojson"
  rm "${PIPELINE_INPUT_DIR}/noprj/sample.prj"

  json_of --no-checks noprj/sample.shp
  run jq -c '[.crs, .extent_wgs84]' <<<"$JSON"
  [ "$output" = '[null,null]' ]
  run jq -r '.warnings[]' <<<"$JSON"
  [[ $output == *"set LAYER_SOURCE_SRS"* ]]
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
