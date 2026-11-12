#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR/..
# Low-zoom generalisation tests (LAYER_GENERALISE_*, lib/generalise.sh), on
# the synthetic island coverage from fixtures/make_islands.sh (generated
# here, not committed). Run in the test image with the other bats files.

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
}

# write_config [LINE...]: the islands layer, z0 to z6 with the coverage
# profile, plus any extra lines, and a minimal display config.
write_config() {
  printf '%s\n' 'LAYER_INPUT=islands.geojson' 'LAYER_FIELDS=(id name)' \
    'LAYER_FEATURE_ID=id' 'LAYER_MIN_ZOOM=0' 'LAYER_MAX_ZOOM=6' \
    'LAYER_PROFILE=coverage' "$@" >"${PIPELINE_LAYERS_DIR}/islands.env"
  cp "${PIPELINE_ROOT}/tests/fixtures/minimal.style.json" "${PIPELINE_LAYERS_DIR}/islands.style.json"
}

# parts_at_zoom Z: `id parts` per feature at zoom Z of the archive (the
# fixture is in one tile at every zoom, so parts are not split by tiles).
parts_at_zoom() {
  ogr2ogr -f CSV /vsistdout/ -oo "ZOOM_LEVEL=$1" -explodecollections "$ARCHIVE" \
    -sql 'SELECT mvt_id FROM islands' | tail -n +2 | sort -n | uniq -c | awk '{ print $2, $1 }'
}

# generalise FILE Z MIN_PART_PX SIMPLIFY_PX: the fixture generalised for one
# zoom by generalise_zoom, written to FILE.
generalise() {
  (
    # shellcheck source=lib/log.sh
    source "${PIPELINE_ROOT}/lib/log.sh"
    # shellcheck source=lib/normalise.sh
    source "${PIPELINE_ROOT}/lib/normalise.sh"
    # shellcheck source=lib/guard.sh
    source "${PIPELINE_ROOT}/lib/guard.sh"
    # shellcheck source=lib/generalise.sh
    source "${PIPELINE_ROOT}/lib/generalise.sh"
    generalise_zoom "${ISLANDS_RAW}/islands.geojson" "$1" "$2" id "$3" "$4" id name
  )
}

# vertices FILE ID: number of vertices of feature ID in FILE.
vertices() {
  ogr2ogr -f CSV /vsistdout/ "$1" -dialect SQLITE \
    -sql "SELECT ST_NPoints(geometry) AS n FROM \"$(ogrinfo -json -so "$1" | jq -r '.layers[0].name')\" WHERE id = $2" \
    | tail -n 1
}

@test "island fixture is a valid coverage of multipolygons" {
  local input="${ISLANDS_RAW}/islands.geojson"
  run diff <("${PIPELINE_ROOT}/tests/fixtures/make_islands.sh") "$input"
  [ "$status" -eq 0 ]
  gdal vector check-coverage --quiet --maximum-gap-width 0.001 "$input" "${BATS_TEST_TMPDIR}/edges.geojson"
  run jq '.features | length' "${BATS_TEST_TMPDIR}/edges.geojson"
  [ "$output" = "0" ]
  gdal vector check-geometry --quiet "$input" "${BATS_TEST_TMPDIR}/invalid.geojson"
  run jq '.features | length' "${BATS_TEST_TMPDIR}/invalid.geojson"
  [ "$output" = "0" ]
  run jq -c '[.features[].geometry.coordinates | length]' "$input"
  [ "$output" = "[13,13,5]" ]
}

@test "without LAYER_GENERALISE_MAX_ZOOM every island is tiled at low zooms (today's behaviour)" {
  write_config
  run "$RUN" islands
  [ "$status" -eq 0 ]
  [[ $output != *generalis* ]]
  run parts_at_zoom 4
  [ "$output" = $'1 13\n2 13\n3 5' ]
}

@test "generalised zooms drop small parts but keep each feature's largest; full detail above" {
  write_config 'LAYER_GENERALISE_MAX_ZOOM=5'
  run "$RUN" islands
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"generalising z0-z5"* ]]
  [[ $output == *"drop guard passed for z0-z6"* ]]

  # Default 4 px: at z4 and z5 only the large island (8 and 33 px) stays
  # with each block; at z3 (2 px) it goes too. The islets keep their
  # largest part only (below z4 that part is under 1/64 px, so tippecanoe's
  # own tiny polygon reduction takes it, which the guard allows).
  run parts_at_zoom 5
  [ "$output" = $'1 2\n2 2\n3 1' ]
  run parts_at_zoom 4
  [ "$output" = $'1 2\n2 2\n3 1' ]
  run parts_at_zoom 3
  [ "$output" = $'1 1\n2 1' ]
  # z6 is not generalised: every part is back.
  run parts_at_zoom 6
  [ "$output" = $'1 13\n2 13\n3 5' ]

  # Every feature at every zoom where it is not sub-pixel dust.
  run jq -c '[.layers[0].zooms[].present]' "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$output" = "[2,2,2,2,3,3,3]" ]
}

@test "LAYER_GENERALISE_MIN_PART_PX sets the part threshold in screen pixels" {
  # 1 px: the medium islands (2 px at z5) stay at z5, not at z4 (0.5 px).
  write_config 'LAYER_GENERALISE_MAX_ZOOM=5' 'LAYER_GENERALISE_MIN_PART_PX=1'
  run "$RUN" islands
  [ "$status" -eq 0 ]
  run parts_at_zoom 5
  [ "$output" = $'1 5\n2 5\n3 1' ]
  run parts_at_zoom 4
  [ "$output" = $'1 2\n2 2\n3 1' ]
}

@test "generalised zoom is still a coverage, with shared borders simplified" {
  local out="${BATS_TEST_TMPDIR}/z5.geojsonl"
  generalise "$out" 5 4 1
  gdal vector check-coverage --quiet "$out" "${BATS_TEST_TMPDIR}/edges.geojson"
  run jq '.features | length' "${BATS_TEST_TMPDIR}/edges.geojson"
  [ "$output" = "0" ]

  # The zigzag (0.005 degrees, under a pixel at z5) is simplified away,
  # identically in both blocks (the coverage check above).
  local before after
  before=$(vertices "${ISLANDS_RAW}/islands.geojson" 1)
  after=$(vertices "$out" 1)
  echo "vertices $before -> $after"
  ((after < 20 && before > 100))

  # 0 skips simplification: only parts are dropped.
  generalise "$out" 5 4 0
  run vertices "$out" 1
  [ "$output" -eq $((before - 11 * 5)) ]
}

@test "bad LAYER_GENERALISE_* settings are rejected" {
  write_config 'LAYER_GENERALISE_MAX_ZOOM=6'
  run "$RUN" islands
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_GENERALISE_MAX_ZOOM must be from LAYER_MIN_ZOOM to below LAYER_MAX_ZOOM"* ]]

  write_config 'LAYER_GENERALISE_MAX_ZOOM=low'
  run "$RUN" islands
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_GENERALISE_MAX_ZOOM must be an integer"* ]]

  write_config 'LAYER_GENERALISE_MAX_ZOOM=4' 'LAYER_GENERALISE_MIN_PART_PX=-1'
  run "$RUN" islands
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_GENERALISE_MIN_PART_PX must be a non-negative number"* ]]

  write_config 'LAYER_GENERALISE_MAX_ZOOM=4' 'LAYER_GENERALISE_SIMPLIFY_PX=x'
  run "$RUN" islands
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_GENERALISE_SIMPLIFY_PX must be a non-negative number"* ]]
}
