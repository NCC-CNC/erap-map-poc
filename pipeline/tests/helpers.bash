#!/usr/bin/env bash
# Shared by the bats files (`load helpers`).

# layer_file OUT [EXPR...]: write a layer file to OUT: fixtures/layer.yaml
# (a vector layer of fixtures/sample.geojson, one colour) with each yq EXPR
# applied in turn, such as '.processing.maxzoom = 6'.
layer_file() {
  local out=$1
  shift
  cp "${PIPELINE_ROOT}/tests/fixtures/layer.yaml" "$out"
  set_layer "$out" "$@"
}

# set_layer FILE [EXPR...]: apply each yq EXPR to the layer file FILE in
# place.
set_layer() {
  local file=$1 expr
  shift
  for expr in "$@"; do
    yq -i "$expr" "$file"
  done
}

# assert_no_temp_files: no temp files left in the output dir.
# shellcheck disable=SC2154 # status is set by bats' run.
assert_no_temp_files() {
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
