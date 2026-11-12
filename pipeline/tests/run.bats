#!/usr/bin/env bats
# End-to-end tests for bin/run.sh on the synthetic fixture.
# Run in the test image:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  # The synthetic test layers (read only); a test that edits configs makes
  # its own layers dir with make_layers_dir or copy_layers.
  export PIPELINE_LAYERS_DIR="${PIPELINE_ROOT}/tests/layers"
  mkdir -p "$PIPELINE_INPUT_DIR"
}

# A layers dir holding copies of sample.env and sample.style.json under the
# given names.
make_layers_dir() {
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_LAYERS_DIR"
  local name
  for name in "$@"; do
    cp "${PIPELINE_ROOT}/tests/layers/sample.env" "${PIPELINE_LAYERS_DIR}/${name}.env"
    cp "${PIPELINE_ROOT}/tests/layers/sample.style.json" "${PIPELINE_LAYERS_DIR}/${name}.style.json"
  done
}

# A layers dir holding the test layer configs (tests/layers/) of the given
# layers, as they are.
copy_layers() {
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_LAYERS_DIR"
  local name
  for name in "$@"; do
    cp "${PIPELINE_ROOT}/tests/layers/${name}.env" "${PIPELINE_ROOT}/tests/layers/${name}.style.json" \
      "$PIPELINE_LAYERS_DIR"
  done
}

# No temp files left in the output dir.
assert_no_temp_files() {
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fixture matches its generator" {
  run diff <("${PIPELINE_ROOT}/tests/fixtures/make_sample.sh") \
    "${PIPELINE_ROOT}/tests/fixtures/sample.geojson"
  [ "$status" -eq 0 ]
}

@test "builds sample.pmtiles with the layer and zooms" {
  run "$RUN" sample
  [ "$status" -eq 0 ]
  [ -s "${PIPELINE_OUTPUT_DIR}/sample.pmtiles" ]
  assert_no_temp_files

  run pmtiles show "${PIPELINE_OUTPUT_DIR}/sample.pmtiles"
  [ "$status" -eq 0 ]
  [[ $output == *"min zoom: 0"* ]]
  [[ $output == *"max zoom: 8"* ]]

  run bash -c "pmtiles show --metadata '${PIPELINE_OUTPUT_DIR}/sample.pmtiles' | jq -r '.vector_layers[].id'"
  [ "$status" -eq 0 ]
  [ "$output" = "sample" ]
}

@test "keeps, renames and drops attributes per the config" {
  run "$RUN" sample
  [ "$status" -eq 0 ]

  run bash -c "pmtiles show --metadata '${PIPELINE_OUTPUT_DIR}/sample.pmtiles' \
    | jq -r '.vector_layers[0].fields | keys | join(\",\")'"
  [ "$status" -eq 0 ]
  # id is the tile feature id, so it is not repeated as a property.
  [ "$output" = "area_ha,name,score,v2020,v2021,v2022,v2023,v2024" ]

  run bash -c "pmtiles show --metadata '${PIPELINE_OUTPUT_DIR}/sample.pmtiles' \
    | jq -r '.tilestats.layers[0].count'"
  [ "$output" = "15" ]

  # Feature ids survive into the tiles.
  run bash -c "tippecanoe-decode '${PIPELINE_OUTPUT_DIR}/sample.pmtiles' 0 0 0 \
    | jq -r '[.features[].features[].id] | sort | map(tostring) | join(\",\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15" ]
}

@test "writes a valid manifest.json listing the layer" {
  run "$RUN" sample
  [ "$status" -eq 0 ]

  local manifest="${PIPELINE_OUTPUT_DIR}/manifest.json"
  run jq -e '
    (.updated_at | type == "string")
    and (.layers | length == 1)
    and (.layers[0] | .name == "sample" and .file == "sample.pmtiles"
         and .minzoom == 0 and .maxzoom == 8 and .feature_count == 15
         and (.built_at | type == "string")
         and .bounds == [-125, 46, -66, 56]
         and .profile == null and .min_visible_px == 1
         and ([.zooms[].zoom] == [range(9)])
         and all(.zooms[]; .input == 15 and .present == 15
                 and .required == 15 and .required_present == 15)
         and .max_tile_bytes == ([.zooms[].max_tile_bytes] | max))' "$manifest"
  [ "$status" -eq 0 ]
}

@test "no arguments builds every layer config and merges the manifest" {
  make_layers_dir alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ -s "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]

  # Rebuilding one layer keeps the other's manifest entry.
  run "$RUN" beta
  [ "$status" -eq 0 ]
  run jq -r '[.layers[].name] | join(",")' "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$output" = "alpha,beta" ]
}

@test "points fixture matches its generator" {
  run diff <("${PIPELINE_ROOT}/tests/fixtures/make_sample_points.sh") \
    "${PIPELINE_ROOT}/tests/fixtures/sample_points.geojson"
  [ "$status" -eq 0 ]
}

@test "builds sample_points.pmtiles with the layer, zooms and attributes" {
  run "$RUN" sample_points
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/sample_points.pmtiles"
  [ -s "$archive" ]
  assert_no_temp_files

  run pmtiles show "$archive"
  [ "$status" -eq 0 ]
  [[ $output == *"min zoom: 0"* ]]
  [[ $output == *"max zoom: 10"* ]]

  local metadata
  metadata=$(pmtiles show --metadata "$archive")

  run jq -r '.vector_layers[].id' <<<"$metadata"
  [ "$status" -eq 0 ]
  [ "$output" = "sample_points" ]

  # id is the tile feature id, so it is not repeated as a property.
  run jq -r '.vector_layers[0].fields | to_entries
    | map("\(.key):\(.value)") | join(",")' <<<"$metadata"
  [ "$status" -eq 0 ]
  [ "$output" = "category:String,count:Number,name:String" ]

  run jq -r '.tilestats.layers[0].count' <<<"$metadata"
  [ "$output" = "30" ]

  # Categories are exactly alpha, beta and gamma; count stays in 1 to 500.
  run jq -r '.tilestats.layers[0].attributes[] | select(.attribute == "category")
    | .values | sort | join(",")' <<<"$metadata"
  [ "$output" = "alpha,beta,gamma" ]
  run jq -e '.tilestats.layers[0].attributes[] | select(.attribute == "count")
    | .type == "number" and .min >= 1 and .max <= 500' <<<"$metadata"
  [ "$status" -eq 0 ]
}

@test "sample_points keeps every point, with its feature id, at every zoom" {
  run "$RUN" sample_points
  [ "$status" -eq 0 ]

  # Distinct feature ids per zoom across the whole archive: all 30 at each of
  # z0 to z10, so no point is dropped at low zooms.
  local decoded
  decoded=$(tippecanoe-decode "${PIPELINE_OUTPUT_DIR}/sample_points.pmtiles")
  run jq -r '[.features[] | {z: .properties.zoom, ids: [.features[].features[].id]}]
    | group_by(.z)[]
    | "\(.[0].z) \([.[].ids[]] | unique | map(tostring) | join(","))"' <<<"$decoded"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  local z expected
  expected=$(seq -s, 1 30)
  for z in $(seq 0 10); do
    [ "${lines[$z]}" = "$z $expected" ]
  done
}

@test "no arguments builds sample and sample_points into one manifest" {
  # The two synthetic test layers (tests/layers/).
  copy_layers sample sample_points
  run "$RUN"
  [ "$status" -eq 0 ]
  [ -s "${PIPELINE_OUTPUT_DIR}/sample.pmtiles" ]
  [ -s "${PIPELINE_OUTPUT_DIR}/sample_points.pmtiles" ]

  run jq -e '
    ([.layers[].name] == ["sample", "sample_points"])
    and (.layers[1] | .file == "sample_points.pmtiles"
         and .minzoom == 0 and .maxzoom == 10 and .feature_count == 30)' \
    "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "missing input fails and leaves no partial pmtiles" {
  make_layers_dir
  printf '%s\n' 'LAYER_INPUT=missing.geojson' 'LAYER_FIELDS=(id)' \
    'LAYER_FEATURE_ID=id' 'LAYER_MIN_ZOOM=0' 'LAYER_MAX_ZOOM=4' \
    >"${PIPELINE_LAYERS_DIR}/broken.env"

  run "$RUN" broken
  [ "$status" -eq 1 ]
  [[ $output == *"input not found: ${PIPELINE_INPUT_DIR}/missing.geojson"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/broken.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/manifest.json" ]
  assert_no_temp_files
}

@test "one failed layer fails the run but the others still build" {
  make_layers_dir good
  printf '%s\n' 'LAYER_INPUT=missing.geojson' 'LAYER_FIELDS=(id)' \
    'LAYER_FEATURE_ID=id' 'LAYER_MIN_ZOOM=0' 'LAYER_MAX_ZOOM=4' \
    >"${PIPELINE_LAYERS_DIR}/broken.env"

  run "$RUN"
  [ "$status" -eq 1 ]
  [[ $output == *"layer(s) failed: broken"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/good.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/broken.pmtiles" ]
}

@test "a failed tile build keeps the previous pmtiles untouched" {
  make_layers_dir sample
  run "$RUN" sample
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "${PIPELINE_OUTPUT_DIR}/sample.pmtiles")

  # Make tippecanoe itself fail, after normalising has succeeded.
  echo 'LAYER_TIPPECANOE_FLAGS=(--no-such-flag)' >>"${PIPELINE_LAYERS_DIR}/sample.env"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"tippecanoe failed"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/sample.pmtiles")" = "$before" ]
  assert_no_temp_files
}

@test "unknown layer is a usage error and builds nothing" {
  run "$RUN" sample nope
  [ "$status" -eq 2 ]
  [[ $output == *"no config for layer 'nope'"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/sample.pmtiles" ]
}

@test "--help prints usage" {
  run "$RUN" --help
  [ "$status" -eq 0 ]
  [[ $output == *"Usage: run.sh"* ]]
  [[ $output != *shellcheck* ]]
}
