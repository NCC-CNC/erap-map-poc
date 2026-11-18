#!/usr/bin/env bats
# Reading the layer files (lib/layerfile.sh): every <layer>.yaml is checked
# with jv against schema/layer.schema.json, and by the pipeline for what a
# schema cannot say, before any data is read; then the processing preset
# sets the tippecanoe flags. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# generator_options NAME: the tippecanoe options recorded in NAME's archive.
generator_options() {
  pmtiles show --metadata "${PIPELINE_OUTPUT_DIR}/$1.pmtiles" | jq -r .generator_options
}

@test "the committed and test layer files read without problems" {
  PIPELINE_LAYERS_DIR="${PIPELINE_ROOT}/layers" run "$RUN" --status --json
  echo "$output"
  [ "$status" -eq 0 ]
  # No source data here, so each is `source missing`, none invalid.
  run jq -c '[.layers[] | [.name, .state, .type]]' <<<"$output"
  [ "$output" = '[["agriculture","source missing","raster"],["ecoregions","source missing","vector"],["forest","source missing","raster"],["protected_areas","source missing","vector"]]' ]

  PIPELINE_LAYERS_DIR="${PIPELINE_ROOT}/tests/layers" run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -c '[.layers[] | [.name, .state]]' <<<"$output"
  [ "$output" = '[["sample","not built"],["sample_points","not built"]]' ]
}

@test "a layer file that fails its schema fails the layer before any data is read" {
  layer_file "${PIPELINE_LAYERS_DIR}/bad.yaml" 'del(.title)' '.processing.max_zoom = 3' \
    '.display.layers[0].type = "polygon"'
  layer_file "${PIPELINE_LAYERS_DIR}/good.yaml"
  run "$RUN"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"bad: bad.yaml: at '': missing property 'title'"* ]]
  [[ $output == *"bad.yaml: at '/processing': additional properties 'max_zoom' not allowed"* ]]
  [[ $output == *"bad.yaml: at '/display/layers/0/type': value must be one of"* ]]
  [[ $output == *"bad.yaml has problems (above); keeping the previous build"* ]]
  [[ $output != *"bad: normalising"* ]]
  [[ $output == *"layer(s) failed: bad"* ]]
  # The other layer still builds.
  [ -s "${PIPELINE_OUTPUT_DIR}/good.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/bad.pmtiles" ]
}

@test "a file that is not YAML, and checks beyond the schema, are reported" {
  printf 'title: [unclosed\nsource: x\n' >"${PIPELINE_LAYERS_DIR}/broken.yaml"
  layer_file "${PIPELINE_LAYERS_DIR}/zooms.yaml" '.processing.minzoom = 5'
  layer_file "${PIPELINE_LAYERS_DIR}/twice.yaml" '.fields.keep = ["score", {"area_ha": "score"}]'
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -r '.layers[] | "\(.name)|\(.state)|\(.notes | join(";"))"' <<<"$output"
  [[ ${lines[0]} == "broken|invalid|broken.yaml: "* ]]
  [ "${lines[1]}" = "twice|invalid|twice.yaml: fields: score is named twice (in fields.keep or fields.calculated)" ]
  [ "${lines[2]}" = "zooms|invalid|zooms.yaml: processing: minzoom (5) is above maxzoom (4)" ]

  run "$RUN" zooms
  [ "$status" -eq 1 ]
  [[ $output == *"zooms.yaml: processing: minzoom (5) is above maxzoom (4)"* ]]
}

@test "a file name that is not a layer name is left out, with a warning" {
  layer_file "${PIPELINE_LAYERS_DIR}/Bad Name.yaml"
  layer_file "${PIPELINE_LAYERS_DIR}/good.yaml"
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  [[ $output == *"ignoring Bad Name.yaml: a layer name has lower case letters, digits, _ and - only"* ]]
  [ "$("$RUN" --status --json 2>/dev/null | jq -c '[.layers[].name]')" = '["good"]' ]
}

@test "a missing feature id or kept attribute fails when the data is read" {
  layer_file "${PIPELINE_LAYERS_DIR}/noid.yaml" '.source.id = "nope"'
  run "$RUN" noid
  [ "$status" -eq 1 ]
  [[ $output == *"ogr2ogr failed for"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/noid.pmtiles" ]
}

@test "presets: the tippecanoe flags of default, coverage and points" {
  layer_file "${PIPELINE_LAYERS_DIR}/default.yaml"
  layer_file "${PIPELINE_LAYERS_DIR}/coverage.yaml" '.processing.profile = "coverage"'
  layer_file "${PIPELINE_LAYERS_DIR}/points.yaml" '.processing.profile = "points"' \
    '.source.path = "/opt/pipeline/tests/fixtures/sample_points.geojson"'
  # No profile is the default.
  layer_file "${PIPELINE_LAYERS_DIR}/none.yaml" 'del(.processing.profile)' 'del(.processing.minzoom)'
  run "$RUN"
  echo "$output"
  [ "$status" -eq 0 ]

  [[ $output == *"default: building tiles z0-z4 with --simplify-only-low-zooms"$'\n'* ]]
  [[ $output == *"coverage: building tiles z0-z4 with --simplify-only-low-zooms --no-simplification-of-shared-nodes --drop-smallest-as-needed"* ]]
  [[ $output == *"points: building tiles z0-z4 with --simplify-only-low-zooms --drop-rate=1"* ]]
  [[ $output == *"none: building tiles z0-z4 with --simplify-only-low-zooms"$'\n'* ]]
  # Only coverage generalises, below the max zoom.
  [[ $output == *"coverage: generalising z0-z3"* ]]
  [[ $output != *"default: generalising"* ]]
  run generator_options coverage
  [[ $output == *"--no-simplification-of-shared-nodes"* ]]
  run generator_options points
  [[ $output == *"--drop-rate=1"* ]]
  [[ $output != *"--drop-smallest-as-needed"* ]]
  run jq -c '[.layers[] | [.name, .profile, .min_visible_px, .minzoom]]' "$BUILD"
  [ "$output" = '[["coverage","coverage",1,0],["default","default",1,0],["none","default",1,0],["points","points",1,0]]' ]
}
