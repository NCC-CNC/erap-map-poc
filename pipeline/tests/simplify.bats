#!/usr/bin/env bats
# Full detail at a vector layer's max zoom (LAYER_SIMPLIFY_MAX_ZOOM, ADR
# 0013): tippecanoe's --simplify-only-low-zooms by default, on the synthetic
# island coverage from fixtures/make_islands.sh (generated here, not
# committed). Run in the test image with the other bats files.

setup_file() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  export PIPELINE_ROOT
  export ISLANDS_RAW="${BATS_FILE_TMPDIR}/raw"
  mkdir -p "$ISLANDS_RAW"
  "${PIPELINE_ROOT}/tests/fixtures/make_islands.sh" >"${ISLANDS_RAW}/islands.geojson"
}

setup() {
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR=$ISLANDS_RAW
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_LAYERS_DIR"
  ARCHIVE="${PIPELINE_OUTPUT_DIR}/islands.pmtiles"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
}

# write_config [LINE...]: the islands layer, z0 to z4 with the coverage
# profile, plus any extra lines, and a minimal display config. At z4 the
# zigzag shared border (0.005 degrees either side of -99) is under a tile
# unit, so tippecanoe's simplification takes it out.
write_config() {
  printf '%s\n' 'LAYER_INPUT=islands.geojson' 'LAYER_FIELDS=(id name)' \
    'LAYER_FEATURE_ID=id' 'LAYER_MIN_ZOOM=0' 'LAYER_MAX_ZOOM=4' \
    'LAYER_PROFILE=coverage' "$@" >"${PIPELINE_LAYERS_DIR}/islands.env"
  cp "${PIPELINE_ROOT}/tests/fixtures/minimal.style.json" "${PIPELINE_LAYERS_DIR}/islands.style.json"
}

# generator_options: the tippecanoe options recorded in the archive.
generator_options() {
  pmtiles show --metadata "$ARCHIVE" | jq -r .generator_options
}

# vertices_at_zoom Z ID: vertices of feature ID at zoom Z of the archive (the
# fixture is in one tile at every zoom).
vertices_at_zoom() {
  ogr2ogr -f CSV /vsistdout/ -oo "ZOOM_LEVEL=$1" "$ARCHIVE" -dialect SQLITE \
    -sql "SELECT SUM(ST_NPoints(geometry)) AS n FROM islands WHERE mvt_id = $2" | tail -n 1
}

@test "by default the max zoom is not simplified: --simplify-only-low-zooms" {
  write_config
  run "$RUN" islands
  echo "$output"
  [ "$status" -eq 0 ]
  run generator_options
  [[ $output == *"--simplify-only-low-zooms"* ]]
  # With the coverage profile's flags.
  [[ $output == *"--no-simplification-of-shared-nodes"* ]]
  [[ $output == *"--drop-smallest-as-needed"* ]]
  run jq -r '.layers[0].simplify_max_zoom' "$MANIFEST"
  [ "$output" = false ]
}

@test "full detail keeps more vertices at the max zoom; lower zooms are simplified either way" {
  write_config
  run "$RUN" islands
  [ "$status" -eq 0 ]
  local full_max full_low
  full_max=$(vertices_at_zoom 4 1)
  full_low=$(vertices_at_zoom 3 1)

  write_config 'LAYER_SIMPLIFY_MAX_ZOOM=true'
  run "$RUN" islands
  [ "$status" -eq 0 ]
  local simple_max simple_low
  simple_max=$(vertices_at_zoom 4 1)
  simple_low=$(vertices_at_zoom 3 1)

  echo "z4: full $full_max, simplified $simple_max; z3: $full_low, $simple_low"
  # The zigzag border (101 vertices) stays at z4 only without simplification.
  ((full_max > simple_max + 50))
  ((full_low == simple_low))
}

@test "LAYER_SIMPLIFY_MAX_ZOOM=true omits the flag and is recorded" {
  write_config 'LAYER_SIMPLIFY_MAX_ZOOM=true'
  run "$RUN" islands
  [ "$status" -eq 0 ]
  run generator_options
  [[ $output != *"--simplify-only-low-zooms"* ]]
  [[ $output == *"--no-simplification-of-shared-nodes"* ]]
  run jq -r '.layers[0].simplify_max_zoom' "$MANIFEST"
  [ "$output" = true ]
}

@test "full detail at the max zoom works with low-zoom generalisation" {
  write_config 'LAYER_GENERALISE_MAX_ZOOM=2'
  run "$RUN" islands
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"generalising z0-z2"* ]]
  run generator_options
  [[ $output == *"--simplify-only-low-zooms"* ]]
}

@test "LAYER_SIMPLIFY_MAX_ZOOM other than true or false is rejected" {
  local value
  for value in yes TRUE 1 ''; do
    write_config "LAYER_SIMPLIFY_MAX_ZOOM='$value'"
    run "$RUN" islands
    [ "$status" -eq 1 ]
    [[ $output == *"LAYER_SIMPLIFY_MAX_ZOOM must be true or false"* ]]
  done
  [ ! -e "$ARCHIVE" ]
}
