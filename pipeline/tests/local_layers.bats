#!/usr/bin/env bats
# Tests for your own layers in layers.local/ (design note 04;
# PIPELINE_LOCAL_LAYERS_DIR, lib/layerfile.sh): built like committed
# layers, recorded as local, picked and overridden by the map config, and a
# name that repeats a committed layer is an error. Run in the test image
# with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_LOCAL_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers.local"
  export PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/map.config.yaml"
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR" "$PIPELINE_LOCAL_LAYERS_DIR"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# add_layer DIR NAME: a copy of the sample layer, z0 to z3, in DIR.
add_layer() {
  cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "${1}/${2}.yaml"
  set_layer "${1}/${2}.yaml" '.source.path = "sample.geojson"' '.processing.maxzoom = 3'
}

status_of() {
  "$RUN" --status --json 2>/dev/null \
    | jq -r --arg n "$1" '.layers[] | select(.name == $n) | [.state, .origin] | join(" ")'
}

@test "a local layer is built with the committed ones and recorded as local" {
  add_layer "$PIPELINE_LAYERS_DIR" alpha
  add_layer "$PIPELINE_LOCAL_LAYERS_DIR" mine
  run "$RUN"
  [ "$status" -eq 0 ]
  [ -s "${PIPELINE_OUTPUT_DIR}/mine.pmtiles" ]
  [ "$(jq -c '[.layers[] | [.name, .provenance.origin]]' "$BUILD")" = '[["alpha","committed"],["mine","local"]]' ]
  [ "$(jq -c '.metadata["erap:layers"] | keys' "$STYLE")" = '["alpha","mine"]' ]
  [ "$(status_of mine)" = "current local" ]
  [ "$(status_of alpha)" = "current committed" ]

  # A change to it is seen like any other.
  set_layer "${PIPELINE_LOCAL_LAYERS_DIR}/mine.yaml" '.title = "Mine, renamed"'
  [ "$(status_of mine)" = "restyle local" ]
  run "$RUN" --style-only mine
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata["erap:layers"].mine.title' "$STYLE")" = 'Mine, renamed' ]
}

@test "the map config picks and overrides a local layer" {
  add_layer "$PIPELINE_LAYERS_DIR" alpha
  add_layer "$PIPELINE_LOCAL_LAYERS_DIR" mine
  printf '%s\n' 'layers: [mine]' 'overrides: { mine: { processing: { maxzoom: 2 } } }' \
    >"$PIPELINE_MAP_CONFIG"
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.layers[] | [.name, .maxzoom]]' "$BUILD")" = '[["mine",2]]' ]
  [ "$(status_of alpha)" = "disabled committed" ]
}

@test "a local layer with the name of a committed one is an error, in every mode" {
  add_layer "$PIPELINE_LAYERS_DIR" alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(cat "$BUILD")
  add_layer "$PIPELINE_LOCAL_LAYERS_DIR" alpha
  local args
  for args in "" "--status" "--style-only"; do
    run "$RUN" ${args:+"$args"}
    [ "$status" -eq 2 ]
    [[ $output == *"${PIPELINE_LOCAL_LAYERS_DIR}/alpha.yaml: there is a committed layer called alpha (${PIPELINE_LAYERS_DIR}/alpha.yaml): give your layer another name"* ]]
    [[ $output == *"the local layers have problems (above); nothing was changed"* ]]
  done
  [ "$(cat "$BUILD")" = "$before" ]
}

@test "no layers.local folder, or an empty PIPELINE_LOCAL_LAYERS_DIR, means committed layers only" {
  add_layer "$PIPELINE_LAYERS_DIR" alpha
  add_layer "$PIPELINE_LOCAL_LAYERS_DIR" mine
  PIPELINE_LOCAL_LAYERS_DIR="" run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.layers[].name]' "$BUILD")" = '["alpha"]' ]

  rm -rf "$PIPELINE_LOCAL_LAYERS_DIR"
  run "$RUN" --status
  [ "$status" -eq 0 ]
  [[ $output != *mine* ]]
}

@test "a message about a missing layer names both folders" {
  add_layer "$PIPELINE_LAYERS_DIR" alpha
  run "$RUN" nope
  [ "$status" -eq 2 ]
  [[ $output == *"no layer file for layer 'nope' in ${PIPELINE_LAYERS_DIR} or ${PIPELINE_LOCAL_LAYERS_DIR}"* ]]
}
