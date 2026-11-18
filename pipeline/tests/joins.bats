#!/usr/bin/env bats
# Non-spatial joins (lib/joins.sh): `source.joins` adds attributes from a
# table, here fixtures/sample_stats.csv (ids 1, 2, 3 and 5 of the sample
# layer, and 42, which no feature has), before `fields.keep` and the
# calculated fields. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_WORK_DIR=""
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  ARCHIVE="${PIPELINE_OUTPUT_DIR}/demo.pmtiles"
  LAYER="${PIPELINE_LAYERS_DIR}/demo.yaml"
  mkdir -p "$PIPELINE_INPUT_DIR/tables" "$PIPELINE_LAYERS_DIR"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample_stats.csv" "${PIPELINE_INPUT_DIR}/tables/stats.csv"
}

# demo [EXPR...]: the test layer as `demo`, joined to tables/stats.csv on
# id, keeping name, region (as area_name), budget and code; then any yq
# EXPRs.
demo() {
  layer_file "$LAYER" '.source.path = "sample.geojson"' \
    '.source.joins = [{"path": "tables/stats.csv", "on": "id"}]' \
    '.fields.keep = [{"NAME_EN": "name"}, {"region": "area_name"}, "budget", "code"]' "$@"
}

# props ID: the attributes of feature ID at z0 of the archive.
props() {
  tippecanoe-decode "$ARCHIVE" 0 0 0 \
    | jq -S -c --argjson id "$1" '.features[].features[] | select(.id == $id) | .properties'
}

# notes_of NAME: the layer's --status notes, joined with `;`.
notes_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .notes | join(";")'
}

# state_of NAME: the layer's --status state.
state_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .state'
}

@test "a join adds the table's attributes, typed, kept and renamed by fields.keep" {
  demo
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"joining tables/stats.csv"* ]]
  [[ $output == *"joins: tables/stats.csv on id (4 of 15 features matched, 5 rows)"* ]]

  # A number stays a number, a quoted code keeps its leading zeros, an
  # empty cell is no attribute.
  run props 1
  [ "$output" = '{"area_name":"West","budget":120.5,"code":"007","name":"Alder"}' ]
  run props 3
  [ "$output" = '{"area_name":"East","code":"100","name":"Cedar"}' ]
  # Every feature is kept: one with no row has only its own attributes.
  run props 4
  [ "$output" = '{"name":"Dogwood"}' ]
  run bash -c "tippecanoe-decode '$ARCHIVE' 0 0 0 | jq '[.features[].features[]] | length'"
  [ "$output" = 15 ]

  # The build report.
  run jq -c '.layers[0].joins' "$BUILD"
  [ "$output" = '[{"path":"tables/stats.csv","layer":"stats","on":"id","fields":["region","budget","code"],"rows":5,"matched":4}]' ]
  run jq -r '.layers[0].provenance.joins[0].path' "$BUILD"
  [ "$output" = tables/stats.csv ]
  [ "$(state_of demo)" = current ]
  assert_no_temp_files
}

@test "joins[].fields picks and renames the attributes; calculated fields can use them" {
  demo '.source.joins[0].fields = [{"budget": "money"}]' \
    '.fields.keep = ["money"]' \
    '.fields.calculated.double_money = "money * 2"'
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 0 ]
  run props 2
  [ "$output" = '{"double_money":160,"money":80}' ]
  run jq -c '.layers[0].joins[0].fields' "$BUILD"
  [ "$output" = '["money"]' ]
}

@test "keys match as text: a quoted key, or a whole real, matches an integer; two joins" {
  # A quoted key column is text; 2.0 makes a real column.
  printf 'id,quoted\n"1",a\n"2",b\n' >"${PIPELINE_INPUT_DIR}/tables/quoted.csv"
  printf 'id,real\n2.0,c\n3.5,d\n' >"${PIPELINE_INPUT_DIR}/tables/real.csv"
  demo '.source.joins = [{"path": "tables/quoted.csv", "on": "id"}, {"path": "tables/real.csv", "on": "id"}]' \
    '.fields.keep = ["quoted", "real"]'
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"joins: tables/quoted.csv on id (2 of 15 features matched, 2 rows), tables/real.csv on id (1 of 15 features matched, 2 rows)"* ]]
  [ "$(props 1)" = '{"quoted":"a"}' ]
  [ "$(props 2)" = '{"quoted":"b","real":"c"}' ]
  [ "$(props 3)" = '{}' ]
}

@test "a join that matches no feature warns" {
  printf 'id,x\n100,1\n' >"${PIPELINE_INPUT_DIR}/tables/none.csv"
  demo '.source.joins = [{"path": "tables/none.csv", "on": "id"}]' '.fields.keep = ["x"]'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  [[ $output == *"[WARN] demo: source.joins[0] (tables/none.csv): no feature has a row in the table; check the key"* ]]
}

@test "a key in more than one row fails the layer, naming it" {
  printf 'id,region\n1,West\n2,West\n2,East\n' >"${PIPELINE_INPUT_DIR}/tables/stats.csv"
  demo '.fields.keep = ["region"]'
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"source.joins[0] (tables/stats.csv): id 2 is in more than one row"* ]]
  [ ! -f "$ARCHIVE" ]
}

@test "a missing key, attribute or a name clash fails the layer" {
  demo '.source.joins[0].on = "code_x"'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"source.joins[0] (tables/stats.csv): no attribute code_x"* ]]

  demo '.source.joins[0].fields = ["nope"]'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"source.joins[0] (tables/stats.csv): no attribute nope"* ]]

  # region renamed to score, which the source already has.
  demo '.source.joins[0].fields = [{"region": "score"}]' '.fields.keep = ["score"]'
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"source.joins[0] (tables/stats.csv): score is also a source attribute; rename it in its fields"* ]]

  # The key is in the table but not the source.
  printf 'code,x\n007,1\n' >"${PIPELINE_INPUT_DIR}/tables/codes.csv"
  demo '.source.joins = [{"path": "tables/codes.csv", "on": "code"}]' '.fields.keep = ["x"]'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"source.joins[0] (tables/codes.csv): no attribute code in the source"* ]]
}

@test "a missing join table is like missing source data: skipped, or a named build fails" {
  demo
  layer_file "${PIPELINE_LAYERS_DIR}/other.yaml" '.source.path = "sample.geojson"'
  rm "${PIPELINE_INPUT_DIR}/tables/stats.csv"

  [ "$(state_of demo)" = "source missing" ]
  [ "$(notes_of demo)" = "join table not found: tables/stats.csv" ]

  run "$RUN"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"skipping demo: join table not found: tables/stats.csv"* ]]
  [ -f "${PIPELINE_OUTPUT_DIR}/other.pmtiles" ]
  [ ! -f "$ARCHIVE" ]

  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"input not found"*"tables/stats.csv"* ]]
}

@test "a changed join table or join setting makes the layer stale" {
  demo
  run "$RUN" demo
  [ "$status" -eq 0 ]
  [ "$(state_of demo)" = current ]

  touch -d '+1 minute' "${PIPELINE_INPUT_DIR}/tables/stats.csv"
  [ "$(state_of demo)" = stale ]
  [ "$(notes_of demo)" = "join table changed since the build" ]

  run "$RUN" demo
  [ "$status" -eq 0 ]
  touch -d '-1 minute' "${PIPELINE_INPUT_DIR}/tables/stats.csv"
  [ "$(state_of demo)" = current ]
  set_layer "$LAYER" '.source.joins[0].fields = ["region"]'
  [ "$(state_of demo)" = stale ]
  [[ "$(notes_of demo)" == "source, fields or processing changed since the build"* ]]
}
