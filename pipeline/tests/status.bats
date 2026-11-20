#!/usr/bin/env bats
# Tests for `run.sh --status` (lib/status.sh) and `run.sh --remove`
# (build_remove in lib/build.sh), on copies of the sample layer and a
# synthetic raster layer.
# Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
  # The fixture as source data in the input dir, so tests can touch it.
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# add_layer NAME...: copies of the sample layer, reading the input dir.
add_layer() {
  local name
  for name in "$@"; do
    cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "${PIPELINE_LAYERS_DIR}/${name}.yaml"
    set_layer "${PIPELINE_LAYERS_DIR}/${name}.yaml" '.source.path = "sample.geojson"'
  done
}

# state_of NAME: the layer's state from --status --json.
state_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .state'
}

# notes_of NAME: the layer's notes, joined with `;`.
notes_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .notes | join(";")'
}

# touch_later FILE...: set a modification time after any build in the test.
touch_later() {
  touch -d "@$(($(date +%s) + 120))" "$@"
}

@test "--status with nothing built lists configured layers as not built" {
  add_layer alpha beta
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -e '[.layers[] | [.name, .state, .configured, .built, .input]]
    == [["alpha", "not built", true, false, "sample.geojson"],
        ["beta", "not built", true, false, "sample.geojson"]]' <<<"$output"
  [ "$status" -eq 0 ]
  [ ! -e "$BUILD" ]

  run "$RUN" --status
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == LAYER*STATE*BUILT*SIZE*ZOOMS*FEATURES*"MAX TILE" ]]
  [[ ${lines[1]} == "alpha "*"not built"* ]]
  [[ ${lines[2]} == "beta "*"not built"* ]]
}

@test "--status reports a fresh build as current with its build report" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]

  run "$RUN" --status --json alpha
  [ "$status" -eq 0 ]
  local size
  size=$(stat -c %s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")
  run jq -e --argjson size "$size" '.layers | length == 1 and (.[0]
    | .state == "current" and .notes == [] and .built
      and (.built_at | type == "string") and .archive_bytes == $size
      and .minzoom == 0 and .maxzoom == 8 and .feature_count == 15
      and (.max_tile_bytes | type == "number"))' <<<"$output"
  [ "$status" -eq 0 ]

  run "$RUN" --list
  [ "$status" -eq 0 ]
  [[ ${lines[1]} =~ ^alpha\ +current\ +[0-9T:Z-]+\ +[0-9.]+\ (B|kB)\ +0-8\ +15\  ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "--status flags a build whose layer file or source data changed since" {
  add_layer alpha beta gamma delta epsilon
  run "$RUN"
  [ "$status" -eq 0 ]

  set_layer "${PIPELINE_LAYERS_DIR}/alpha.yaml" '.processing.maxzoom = 7'
  set_layer "${PIPELINE_LAYERS_DIR}/beta.yaml" '.display.layers[0].paint["fill-opacity"] = 0.5'
  rm "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles"
  set_layer "${PIPELINE_LAYERS_DIR}/epsilon.yaml" '.fields.keep += ["notes"]'
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "source, fields or processing changed since the build (alpha.yaml or the map config's overrides)" ]
  # The display needs no rebuild: every run writes style.json afresh.
  [ "$(state_of beta)" = current ]
  [ "$(state_of gamma)" = stale ]
  [ "$(notes_of gamma)" = "archive missing" ]
  [ "$(state_of delta)" = current ]
  [ "$(state_of epsilon)" = stale ]

  # Only the hashes count: touching a layer file, or a comment, changes
  # nothing.
  touch_later "${PIPELINE_LAYERS_DIR}/delta.yaml"
  echo '# a comment' >>"${PIPELINE_LAYERS_DIR}/delta.yaml"
  [ "$(state_of delta)" = current ]

  touch_later "${PIPELINE_INPUT_DIR}/sample.geojson"
  [ "$(state_of gamma)" = stale ]
  [ "$(notes_of epsilon)" = "source, fields or processing changed since the build (epsilon.yaml or the map config's overrides);source data changed since the build" ]

  # The table lists the notes under the layer.
  run "$RUN" --status beta
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "beta "*stale* ]]
  [ "${lines[2]}" = "  - source data changed since the build" ]
}

@test "--status: a build without a build hash is stale" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  jq '.layers[0].provenance |= (del(.build_sha256) | .env_sha256 = "x")' \
    "$BUILD" >"${BUILD}.new"
  mv "${BUILD}.new" "$BUILD"
  [ "$(state_of alpha)" = stale ]
  [[ "$(notes_of alpha)" == "source, fields or processing changed since the build"* ]]
}

@test "--status checks every file of a shapefile and the zip of a zipped input" {
  add_layer shp zipped
  ogr2ogr -f "ESRI Shapefile" "${PIPELINE_INPUT_DIR}/shp.shp" "${PIPELINE_INPUT_DIR}/sample.geojson"
  set_layer "${PIPELINE_LAYERS_DIR}/shp.yaml" '.source.path = "shp.shp"'
  ogr2ogr -f GeoJSON "/vsizip/${PIPELINE_INPUT_DIR}/z.zip/z/sample.geojson" \
    "${PIPELINE_INPUT_DIR}/sample.geojson"
  [ -s "${PIPELINE_INPUT_DIR}/z.zip" ]
  set_layer "${PIPELINE_LAYERS_DIR}/zipped.yaml" '.source.path = "z.zip/z/sample.geojson"'

  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -r '[.layers[] | "\(.name):\(.input)"] | join(",")' <<<"$output"
  [ "$output" = "shp:shp.shp,zipped:z.zip/z/sample.geojson" ]

  run "$RUN"
  [ "$status" -eq 0 ]
  touch -d @0 "${PIPELINE_INPUT_DIR}"/shp.* "${PIPELINE_INPUT_DIR}/z.zip"
  [ "$(state_of shp)" = current ]
  [ "$(state_of zipped)" = current ]

  touch_later "${PIPELINE_INPUT_DIR}/shp.dbf" "${PIPELINE_INPUT_DIR}/z.zip"
  [ "$(notes_of shp)" = "source data changed since the build" ]
  [ "$(notes_of zipped)" = "source data changed since the build" ]
}

@test "--status reports invalid layer files, missing source data and orphaned builds" {
  add_layer alpha broken dupid nodata
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  rm "${PIPELINE_LAYERS_DIR}/alpha.yaml"
  set_layer "${PIPELINE_LAYERS_DIR}/broken.yaml" '.processing.minzoom = "x"'
  set_layer "${PIPELINE_LAYERS_DIR}/dupid.yaml" '.display.layers[1].id = "fill"'
  set_layer "${PIPELINE_LAYERS_DIR}/nodata.yaml" '.source.path = "missing.gpkg"'

  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -r '.layers[] | "\(.name)|\(.state)|\(.notes | join(";"))"' <<<"$output"
  [ "${lines[0]}" = "alpha|invalid|no alpha.yaml: run.sh --remove removes the build" ]
  [[ ${lines[1]} == "broken|invalid|broken.yaml: at '/processing/minzoom': "* ]]
  [ "${lines[3]}" = "nodata|source missing|source data not found: missing.gpkg" ]
  [ "${lines[2]}" = "dupid|invalid|dupid.yaml: display.layers: id fill is used twice" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "--status of an unknown layer is a usage error" {
  add_layer alpha
  run "$RUN" --status nope
  [ "$status" -eq 2 ]
  [[ $output == *"no layer file or build for layer 'nope'"* ]]

  run "$RUN" --status ../x
  [ "$status" -eq 2 ]
  [[ $output == *"invalid layer name"* ]]
}

@test "--status with no layers at all says so" {
  run "$RUN" --status
  [ "$status" -eq 0 ]
  [ "$output" = "no layers configured or built" ]
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"layers":[]}' ]
}

@test "mode options are checked" {
  run "$RUN" --json
  [ "$status" -eq 2 ]
  [[ $output == *"--json works only with --status"* ]]
  run "$RUN" --status --remove alpha
  [ "$status" -eq 2 ]
  [[ $output == *"cannot be used together"* ]]
  run "$RUN" --remove
  [ "$status" -eq 2 ]
  [[ $output == *"needs at least one layer name"* ]]
}

@test "--remove drops the archive and build.json entry and rewrites style.json" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  rm "${PIPELINE_LAYERS_DIR}"/alpha.*

  run "$RUN" --remove alpha
  [ "$status" -eq 0 ]
  [[ $output != *"is still in"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ -s "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]
  run jq -r '[.layers[].name] | join(",")' "$BUILD"
  [ "$output" = beta ]
  run jq -r '[.sources | keys[]] | join(",")' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = beta ]
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ -z "$output" ]
  [ "$(state_of beta)" = current ]
}

@test "--remove warns when the layer file is still there" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  run "$RUN" --remove alpha
  [ "$status" -eq 0 ]
  [[ $output == *"alpha.yaml is still in"* ]]
  [ "$(state_of alpha)" = "not built" ]

  # The last layer gone: an empty build.json and a style with no layers.
  run jq -c '.layers' "$BUILD"
  [ "$output" = "[]" ]
  run jq -c '[.layers, .sources]' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = "[[],{}]" ]
}

@test "--remove of a layer that is not built changes nothing" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$BUILD")

  run "$RUN" --remove alpha nope
  [ "$status" -eq 2 ]
  [[ $output == *"nothing built for layer 'nope'"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ "$(sha256sum "$BUILD")" = "$before" ]
}

# add_raster NAME [EXPR...]: a raster layer on a synthetic binary GeoTIFF
# made now in the input dir (fixtures/make_raster.sh), z3 to z6, changed by
# any yq EXPRs.
add_raster() {
  local name=$1
  shift
  "${PIPELINE_ROOT}/tests/fixtures/make_raster.sh" byte "${PIPELINE_INPUT_DIR}/${name}.tif" 2>/dev/null
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.yaml" "${PIPELINE_LAYERS_DIR}/${name}.yaml"
  set_layer "${PIPELINE_LAYERS_DIR}/${name}.yaml" ".source.path = \"${name}.tif\"" \
    '.processing.maxzoom = 6' "$@"
}

@test "--status and --remove handle a raster layer next to a vector one" {
  add_layer alpha
  add_raster cover
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -e '.layers[] | select(.name == "cover")
    | .state == "not built" and .type == "raster" and .input == "cover.tif"' <<<"$output"
  [ "$status" -eq 0 ]

  run "$RUN"
  [ "$status" -eq 0 ]
  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -e '
    (.layers[] | select(.name == "cover")
      | .state == "current" and .type == "raster" and .format == "cog"
        and .archive_bytes > 0 and .width > 0 and .height > 0
        and .feature_count == null
        and .minzoom == 3 and .maxzoom == 6)
    and (.layers[] | select(.name == "alpha")
      | .type == "vector" and .format == "mvt" and .feature_count == 15
        and .width == null)' <<<"$output"
  [ "$status" -eq 0 ]
  run "$RUN" --status
  [ "$status" -eq 0 ]
  [[ $output == *"cover "*"current"*" px"* ]]

  # The source raster (under RAW_DIR) changing makes it stale.
  touch_later "${PIPELINE_INPUT_DIR}/cover.tif"
  [ "$(state_of cover)" = stale ]
  [[ "$(notes_of cover)" == *"source data changed since the build"* ]]
  rm "${PIPELINE_INPUT_DIR}/cover.tif"
  [ "$(state_of cover)" = "source missing" ]
  [[ "$(notes_of cover)" == *"source data not found: cover.tif"* ]]

  # --remove takes the raster archive, entry and style source; alpha stays.
  run "$RUN" --remove cover
  [ "$status" -eq 0 ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/cover.cog.tif" ]
  run jq -r '[.layers[].name] | join(",")' "$BUILD"
  [ "$output" = alpha ]
  run jq -r '[.sources | keys[]] | join(",")' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = alpha ]
}

@test "--status: a raster is stale when its max zoom changes in the map config" {
  export PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/map.config.yaml"
  add_raster cover
  echo 'overrides: { cover: { processing: { maxzoom: 7 } } }' >"$PIPELINE_MAP_CONFIG"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(jq '.layers[0].maxzoom' "$BUILD")" -eq 7 ]
  [ "$(state_of cover)" = current ]

  echo 'overrides: { cover: { processing: { maxzoom: 5 } } }' >"$PIPELINE_MAP_CONFIG"
  [ "$(state_of cover)" = stale ]
  [[ "$(notes_of cover)" == *"source, fields or processing changed since the build"* ]]
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(jq '.layers[0].maxzoom' "$BUILD")" -eq 5 ]
  [ "$(state_of cover)" = current ]
}
