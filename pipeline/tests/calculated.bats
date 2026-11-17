#!/usr/bin/env bats
# Calculated fields (lib/calculated.sh): `fields.calculated` SQLite
# expressions, run by ogr2ogr -dialect SQLite, on a copy of the sample
# layer. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  INSPECT="${PIPELINE_ROOT}/bin/inspect.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  ARCHIVE="${PIPELINE_OUTPUT_DIR}/demo.pmtiles"
  LAYER="${PIPELINE_LAYERS_DIR}/demo.yaml"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# demo [EXPR...]: the sample layer as `demo`, z0 to z4, with calculated
# fields: one on a kept attribute, a comparison, and two that use the ones
# before them; then any yq EXPRs.
demo() {
  cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "$LAYER"
  set_layer "$LAYER" '.source.path = "sample.geojson"' '.processing.maxzoom = 4' \
    '.fields.calculated.score_gap = "100 - score"' \
    '.fields.calculated.low_score = "coalesce(score < 30, 0)"' \
    '.fields.calculated.half_gap = "round(score_gap / 2.0, 1)"' \
    '.fields.calculated.low_count = "low_score + 0"' "$@"
}

# props ID: the attributes of feature ID at z0 of the archive.
props() {
  tippecanoe-decode "$ARCHIVE" 0 0 0 \
    | jq -c --argjson id "$1" '.features[].features[] | select(.id == $id) | .properties'
}

@test "calculated fields become tile attributes, in file order, each using the ones before" {
  demo
  run "$RUN" demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"calculating score_gap low_score half_gap low_count"* ]]
  [[ $output == *"calculated: score_gap (15 non-null, 6 to 97), low_score (15 non-null, 0 to 1)"* ]]

  # Feature 3 has score 10, feature 1 score 37.
  run props 3
  [ "$(jq -c '[.score_gap, .low_score, .half_gap, .low_count]' <<<"$output")" = '[90,1,45,1]' ]
  run props 1
  [ "$(jq -c '[.score_gap, .low_score, .half_gap, .low_count]' <<<"$output")" = '[63,0,31.5,0]' ]

  # Numbers in the tiles, next to the kept attributes.
  run bash -c "pmtiles show --metadata '$ARCHIVE' | jq -c '.vector_layers[0].fields'"
  [ "$output" = '{"area_ha":"Number","half_gap":"Number","low_count":"Number","low_score":"Number","name":"String","score":"Number","score_gap":"Number","v2020":"Number","v2021":"Number","v2022":"Number","v2023":"Number","v2024":"Number"}' ]

  # The build report, and --status.
  run jq -c '.layers[0].calculated_fields | map([.name, .expression, .non_null, .min, .max])' "$MANIFEST"
  [ "$output" = '[["score_gap","100 - score",15,6,97],["low_score","coalesce(score < 30, 0)",15,0,1],["half_gap","round(score_gap / 2.0, 1)",15,3,48.5],["low_count","low_score + 0",15,0,1]]' ]
  run "$RUN" --status demo
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "  calculated: score_gap, low_score, half_gap, low_count" ]
}

@test "a field whose first value is NULL is still a number" {
  demo '.fields.calculated = {"maybe": "CASE WHEN score > 30 THEN score * 2 END"}'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run props 1
  [ "$(jq -c '.maybe' <<<"$output")" = 74 ]
  run props 3
  [ "$(jq -c '.maybe' <<<"$output")" = null ]
  run bash -c "pmtiles show --metadata '$ARCHIVE' | jq -r '.vector_layers[0].fields.maybe'"
  [ "$output" = Number ]
  run jq -c '.layers[0].calculated_fields[0] | [.non_null, .min, .max]' "$MANIFEST"
  [ "$output" = '[10,74,188]' ]

  # Text stays text.
  demo '.fields.calculated = {"label": "name || '"'"' ('"'"' || score || '"'"')'"'"'"}'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run props 3
  [ "$(jq -r '.label' <<<"$output")" = "Cedar (10)" ]
}

@test "a bad expression fails the layer, naming the field, and keeps the previous build" {
  demo
  run "$RUN" demo
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$ARCHIVE" "$MANIFEST")

  demo '.fields.calculated.bad = "score +"'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"demo: fields.calculated.bad: score +: near"*"syntax error"* ]]
  [[ $output != *"building tiles"* ]]
  [ "$(sha256sum "$ARCHIVE" "$MANIFEST")" = "$before" ]

  # An attribute that is not kept, and one calculated later in the file.
  demo '.fields.calculated = {"a": "notes || 1"}'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"fields.calculated.a: notes || 1: no such column: notes"* ]]
  demo '.fields.calculated = {"a": "b + 1", "b": "score"}'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"fields.calculated.a: b + 1: no such column: b"* ]]

  # A name already kept, or the feature id's.
  demo '.fields.calculated.score = "1"'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"demo.yaml: fields: score is named twice (in fields.keep or fields.calculated)"* ]]
  [[ $output != *normalising* ]]
  demo '.fields.calculated._feature_id = "1"'
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"fields: _feature_id is reserved for the feature id"* ]]
  [ "$(sha256sum "$ARCHIVE" "$MANIFEST")" = "$before" ]
}

@test "--status: a changed calculated field makes the build stale" {
  demo
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run "$RUN" --status --json demo
  [ "$(jq -r '.layers[0].state' <<<"$output")" = current ]
  set_layer "$LAYER" '.fields.calculated.score_gap = "101 - score"'
  run "$RUN" --status --json demo
  [ "$(jq -r '.layers[0].state' <<<"$output")" = stale ]
}

@test "generalised zooms keep the calculated attributes" {
  demo '.processing.profile = "coverage"'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  [[ $output == *"generalising z0-z3"* ]]
  run props 3
  [ "$(jq -c '[.score_gap, .low_count]' <<<"$output")" = '[90,1]' ]
}

@test "inspect.sh --config shows the calculated fields before a build" {
  demo
  local json
  json=$("$INSPECT" --json --no-checks --config demo 2>/dev/null)
  run jq -c '.config | [.layer, .input, [.calculated_fields[].name]]' <<<"$json"
  [ "$output" = '["demo","sample.geojson",["score_gap","low_score","half_gap","low_count"]]' ]
  run jq -c '.fields[] | select(.name == "score_gap") | [.calculated, .min, .max]' <<<"$json"
  [ "$output" = '["100 - score",6,97]' ]
  run jq -r '[.fields[].name] | join(",")' <<<"$json"
  [ "$output" = "_feature_id,name,area_ha,score,v2020,v2021,v2022,v2023,v2024,score_gap,low_score,half_gap,low_count" ]

  run "$INSPECT" --no-checks --config demo
  [ "$status" -eq 0 ]
  [[ $output == *"Config:     layer demo"* ]]
  [[ $output == *"    calculated: 100 - score"* ]]

  run "$INSPECT" --config demo sample.geojson
  [ "$status" -eq 2 ]
  run "$INSPECT" --config nope
  [ "$status" -eq 1 ]
  [[ $output == *"no layer named nope"* ]]

  demo '.fields.calculated.bad = "score +"'
  run "$INSPECT" --no-checks --config demo
  [ "$status" -eq 1 ]
  [[ $output == *"fields.calculated.bad: score +: near"* ]]
}
