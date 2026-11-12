#!/usr/bin/env bats
# Tests for `run.sh --status` (lib/status.sh) and `run.sh --remove`
# (manifest_remove in lib/manifest.sh), on copies of the sample layer and a
# synthetic raster layer.
# Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
  # The fixture as source data in the input dir, so tests can touch it.
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# add_layer NAME...: copies of the sample layer, reading data/raw.
add_layer() {
  local name
  for name in "$@"; do
    sed 's|^LAYER_INPUT=.*|LAYER_INPUT=sample.geojson|' \
      "${PIPELINE_ROOT}/layers/sample.env" >"${PIPELINE_LAYERS_DIR}/${name}.env"
    cp "${PIPELINE_ROOT}/layers/sample.style.json" "${PIPELINE_LAYERS_DIR}/${name}.style.json"
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
  [ ! -e "$MANIFEST" ]

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

@test "--status flags a build older than its configs or source data" {
  add_layer alpha beta gamma delta
  run "$RUN"
  [ "$status" -eq 0 ]

  touch_later "${PIPELINE_LAYERS_DIR}/alpha.env"
  touch_later "${PIPELINE_LAYERS_DIR}/beta.style.json"
  rm "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles"
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "alpha.env changed since the build" ]
  [ "$(state_of beta)" = restyle ]
  [ "$(notes_of beta)" = "beta.style.json changed since the display was last updated (--style-only updates it)" ]
  [ "$(state_of gamma)" = stale ]
  [ "$(notes_of gamma)" = "archive missing" ]
  [ "$(state_of delta)" = current ]

  touch_later "${PIPELINE_INPUT_DIR}/sample.geojson"
  [ "$(state_of delta)" = stale ]
  [ "$(notes_of delta)" = "source data changed since the build" ]

  # The table lists the notes under the layer.
  run "$RUN" --status beta
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "beta "*stale* ]]
  [ "${lines[2]}" = "  - source data changed since the build" ]
  [ "${lines[3]}" = "  - beta.style.json changed since the display was last updated (--style-only updates it)" ]
}

@test "--status checks every file of a shapefile and the zip of a zipped input" {
  add_layer shp zipped
  ogr2ogr -f "ESRI Shapefile" "${PIPELINE_INPUT_DIR}/shp.shp" "${PIPELINE_INPUT_DIR}/sample.geojson"
  sed -i 's|^LAYER_INPUT=.*|LAYER_INPUT=shp.shp|' "${PIPELINE_LAYERS_DIR}/shp.env"
  ogr2ogr -f GeoJSON "/vsizip/${PIPELINE_INPUT_DIR}/z.zip/z/sample.geojson" \
    "${PIPELINE_INPUT_DIR}/sample.geojson"
  [ -s "${PIPELINE_INPUT_DIR}/z.zip" ]
  sed -i 's|^LAYER_INPUT=.*|LAYER_INPUT=z.zip/z/sample.geojson|' "${PIPELINE_LAYERS_DIR}/zipped.env"

  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -r '[.layers[] | "\(.name):\(.input)"] | join(",")' <<<"$output"
  [ "$output" = "shp:shp.shp,zipped:z.zip/z/sample.geojson" ]

  # Fake builds: a manifest entry built now.
  mkdir -p "$PIPELINE_OUTPUT_DIR"
  jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{layers: [{name: "shp", built_at: $now}, {name: "zipped", built_at: $now}]}' >"$MANIFEST"
  touch "${PIPELINE_OUTPUT_DIR}/shp.pmtiles" "${PIPELINE_OUTPUT_DIR}/zipped.pmtiles"
  touch -d @0 "${PIPELINE_LAYERS_DIR}"/* "${PIPELINE_INPUT_DIR}"/shp.* "${PIPELINE_INPUT_DIR}/z.zip"
  [ "$(state_of shp)" = current ]
  [ "$(state_of zipped)" = current ]

  touch_later "${PIPELINE_INPUT_DIR}/shp.dbf" "${PIPELINE_INPUT_DIR}/z.zip"
  [ "$(notes_of shp)" = "source data changed since the build" ]
  [ "$(notes_of zipped)" = "source data changed since the build" ]
}

@test "--status reports invalid configs and orphaned builds" {
  add_layer alpha broken nostyle nodata
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  rm "${PIPELINE_LAYERS_DIR}/alpha.env" "${PIPELINE_LAYERS_DIR}/alpha.style.json"
  echo 'LAYER_MIN_ZOOM=x' >>"${PIPELINE_LAYERS_DIR}/broken.env"
  rm "${PIPELINE_LAYERS_DIR}/nostyle.style.json"
  sed -i 's|^LAYER_INPUT=.*|LAYER_INPUT=missing.gpkg|' "${PIPELINE_LAYERS_DIR}/nodata.env"

  run "$RUN" --status --json
  [ "$status" -eq 0 ]
  run jq -r '.layers[] | "\(.name)|\(.state)|\(.notes | join(";"))"' <<<"$output"
  [ "${lines[0]}" = "alpha|orphan|no alpha.env: remove the build with --remove" ]
  [[ ${lines[1]} == "broken|invalid|LAYER_MIN_ZOOM must be an integer in "* ]]
  [ "${lines[2]}" = "nodata|invalid|source data not found: missing.gpkg" ]
  [ "${lines[3]}" = "nostyle|invalid|no nostyle.style.json" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "--status of an unknown layer is a usage error" {
  add_layer alpha
  run "$RUN" --status nope
  [ "$status" -eq 2 ]
  [[ $output == *"no config or build for layer 'nope'"* ]]

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

@test "--remove drops the archive and manifest entry and rewrites style.json" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  rm "${PIPELINE_LAYERS_DIR}"/alpha.*

  run "$RUN" --remove alpha
  [ "$status" -eq 0 ]
  [[ $output != *"is still in"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ -s "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]
  run jq -r '[.layers[].name] | join(",")' "$MANIFEST"
  [ "$output" = beta ]
  run jq -r '[.sources | keys[]] | join(",")' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = beta ]
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ -z "$output" ]
  [ "$(state_of beta)" = current ]
}

@test "--remove warns when the config is still there" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  run "$RUN" --remove alpha
  [ "$status" -eq 0 ]
  [[ $output == *"alpha.env is still in"* ]]
  [ "$(state_of alpha)" = "not built" ]

  # The last layer gone: an empty manifest and a style with no layers.
  run jq -c '.layers' "$MANIFEST"
  [ "$output" = "[]" ]
  run jq -c '[.layers, .sources]' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = "[[],{}]" ]
}

@test "--remove of a layer that is not built changes nothing" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$MANIFEST")

  run "$RUN" --remove alpha nope
  [ "$status" -eq 2 ]
  [[ $output == *"nothing built for layer 'nope'"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]
}

# add_raster NAME: a raster layer on a synthetic binary GeoTIFF made now in
# the input dir (fixtures/make_raster.sh), z3 to z6.
add_raster() {
  "${PIPELINE_ROOT}/tests/fixtures/make_raster.sh" byte "${PIPELINE_INPUT_DIR}/$1.tif" 2>/dev/null
  printf '%s\n' 'LAYER_TYPE=raster' "LAYER_INPUT=$1.tif" 'LAYER_MIN_ZOOM=3' 'LAYER_MAX_ZOOM=6' \
    >"${PIPELINE_LAYERS_DIR}/$1.env"
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" "${PIPELINE_LAYERS_DIR}/$1.style.json"
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
      | .state == "current" and .type == "raster" and .format == "png"
        and .archive_bytes > 0 and .tile_count > 0 and .feature_count == null
        and .minzoom == 3 and .maxzoom == 6)
    and (.layers[] | select(.name == "alpha")
      | .type == "vector" and .format == "mvt" and .feature_count == 15
        and .tile_count == null)' <<<"$output"
  [ "$status" -eq 0 ]
  run "$RUN" --status
  [ "$status" -eq 0 ]
  [[ $output == *"cover "*"current"*" tiles"* ]]

  # The source raster (under RAW_DIR) changing makes it stale.
  touch_later "${PIPELINE_INPUT_DIR}/cover.tif"
  [ "$(state_of cover)" = stale ]
  [[ "$(notes_of cover)" == *"source data changed since the build"* ]]
  rm "${PIPELINE_INPUT_DIR}/cover.tif"
  [ "$(state_of cover)" = invalid ]
  [[ "$(notes_of cover)" == *"source data not found: cover.tif"* ]]

  # --remove takes the raster archive, entry and style source; alpha stays.
  run "$RUN" --remove cover
  [ "$status" -eq 0 ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/cover.pmtiles" ]
  run jq -r '[.layers[].name] | join(",")' "$MANIFEST"
  [ "$output" = alpha ]
  run jq -r '[.sources | keys[]] | join(",")' "${PIPELINE_OUTPUT_DIR}/style.json"
  [ "$output" = alpha ]
}
