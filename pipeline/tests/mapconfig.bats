#!/usr/bin/env bats
# Tests for the map config (design note 04; lib/layerfile.sh and its use in
# bin/run.sh): layer selection, overrides of source and processing,
# `require`, missing sources, provenance and the map view, on copies of the
# sample layer. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/repo/map.config.yaml"
  CONFIG=$PIPELINE_MAP_CONFIG
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR" "${BATS_TEST_TMPDIR}/repo"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# add_layer NAME...: copies of the sample layer, z0 to z4, reading
# sample.geojson in the input dir.
add_layer() {
  local name
  for name in "$@"; do
    cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "${PIPELINE_LAYERS_DIR}/${name}.yaml"
    set_layer "${PIPELINE_LAYERS_DIR}/${name}.yaml" '.source.path = "sample.geojson"' \
      '.processing.maxzoom = 4'
  done
}

# config YAML: write the map config.
config() {
  printf '%s\n' "$1" >"$CONFIG"
}

# entry NAME JQ: a jq filter on NAME's build.json entry.
entry() {
  jq -c --arg n "$1" "first(.layers[] | select(.name == \$n)) | $2" "$BUILD"
}

status_json() {
  "$RUN" --status --json 2>/dev/null
}

state_of() {
  status_json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .state'
}

notes_of() {
  status_json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .notes | join(";")'
}

@test "no map config file: every layer, as it is" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output != *"map config:"* ]]
  run jq -c '[.layers[] | [.name, .provenance.overrides]]' "$BUILD"
  [ "$output" = '[["alpha",null],["beta",null]]' ]
  run jq -e 'has("center") or has("zoom") or (.metadata | has("erap:basemap")) | not' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "the old map.config.json is not read, and says so" {
  add_layer alpha
  echo '{"disabled": ["alpha"]}' >"${BATS_TEST_TMPDIR}/repo/map.config.json"
  run "$RUN" --status
  [ "$status" -eq 0 ]
  [[ $output == *"map.config.json is no longer read: write your map config as map.config.yaml (see map.config.example.yaml)"* ]]

  # Named as the map config, it stops every mode.
  PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/repo/map.config.json" run "$RUN" --status
  [ "$status" -eq 2 ]
  [[ $output == *"is in the old JSON format, which is no longer read"* ]]
}

@test "layers selects the layers to build; the others are disabled" {
  add_layer alpha beta gamma
  config 'layers: [alpha, gamma]'
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output == *"map config: ${CONFIG}"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]
  [ "$(state_of beta)" = disabled ]
  [ "$(notes_of beta)" = "not in the map config's layers" ]

  run "$RUN" beta
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'beta' is not enabled in the map config: add it to its layers to build it"* ]]
}

@test "leaving out a built layer hides it from the map; --style-only applies it, no rebuild" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)

  config 'layers: [alpha]'
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  [[ $output == *"skipping beta: not enabled in the map config"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)" = "$tiles" ]
  run jq -r '[.sources | keys[]] | join(",")' "$STYLE"
  [ "$output" = alpha ]
  [ "$(state_of beta)" = disabled ]
  [[ "$(notes_of beta)" == *"built before: hidden from the map, --remove removes it"* ]]

  rm "$CONFIG"
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  run jq -r '[.sources | keys[]] | join(",")' "$STYLE"
  [ "$output" = alpha,beta ]
}

@test "source and processing overrides change the build: stale until rebuilt" {
  add_layer alpha
  cp "${PIPELINE_INPUT_DIR}/sample.geojson" "${PIPELINE_INPUT_DIR}/other.geojson"
  run "$RUN"
  [ "$status" -eq 0 ]

  config 'overrides: { alpha: { processing: { maxzoom: 3 } } }'
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "source, fields or processing changed since the build (alpha.yaml or the map config's overrides)" ]
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(entry alpha .maxzoom)" = 3 ]
  [ "$(entry alpha .provenance.overrides)" = '{"processing":{"maxzoom":3}}' ]
  [ "$(state_of alpha)" = current ]

  # A source override replaces only the keys it sets.
  config 'overrides: { alpha: { source: { path: other.geojson }, processing: { maxzoom: 3 } } }'
  [ "$(state_of alpha)" = stale ]
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(entry alpha .provenance.source.path)" = '"other.geojson"' ]
  [ "$(entry alpha .feature_count)" = 15 ]
}

@test "an override that makes the layer invalid fails it, naming the override" {
  add_layer alpha
  config 'overrides: { alpha: { processing: { grey_levels: 8 } } }'
  run "$RUN" alpha
  [ "$status" -eq 1 ]
  [[ $output == *"alpha.yaml: with the map config overrides: at '/processing/grey_levels'"* ]]
  [ ! -e "$BUILD" ]
}

@test "a bad map config stops every mode before anything changes" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(cat "$BUILD")

  config 'layer: []'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"map config: at '': additional properties 'layer' not allowed"* ]]
  [[ $output == *"the map config has problems (above); nothing was changed"* ]]
  run "$RUN" --status
  [ "$status" -eq 2 ]
  run "$RUN" --style-only
  [ "$status" -eq 2 ]

  # Display and fields are not overrides.
  config 'overrides: { alpha: { display: { layers: [] } } }'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"additional properties 'display' not allowed"* ]]

  # Every layer it names must have a layer file.
  config $'layers: [alpha, nope]\noverrides: { gone: { processing: { maxzoom: 3 } } }\nrequire: [none]'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"map config: layers names layer 'nope', which has no nope.yaml in ${PIPELINE_LAYERS_DIR}"* ]]
  [[ $output == *"map config: overrides names layer 'gone'"* ]]
  [[ $output == *"map config: require names layer 'none'"* ]]

  config 'layers: [alpha'
  run "$RUN"
  [ "$status" -eq 2 ]

  [ "$(cat "$BUILD")" = "$before" ]
}

@test "a full build skips layers with no source data; a named one fails" {
  add_layer alpha beta
  set_layer "${PIPELINE_LAYERS_DIR}/beta.yaml" '.source.path = "not_here.gpkg"'
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output == *"skipping beta: source data not found: not_here.gpkg"* ]]
  [[ $output == *"1 layer(s) skipped, source data not found: beta"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]
  [ "$(state_of beta)" = "source missing" ]
  [ "$(notes_of beta)" = "source data not found: not_here.gpkg" ]

  run "$RUN" beta
  [ "$status" -eq 1 ]
  [[ $output == *"input not found: ${PIPELINE_INPUT_DIR}/not_here.gpkg"* ]]

  # Nothing to build at all is a failure.
  config 'layers: [beta]'
  run "$RUN"
  [ "$status" -eq 1 ]
  [[ $output == *"nothing to build"* ]]
}

@test "require: a required layer with no source data stops the build before anything is built" {
  add_layer alpha beta
  cp "${PIPELINE_INPUT_DIR}/sample.geojson" "${PIPELINE_INPUT_DIR}/public.geojson"

  # The Pages pattern: an override to the public source, required.
  config $'overrides: { alpha: { source: { path: public.geojson } } }\nrequire: [alpha]'
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(entry alpha .provenance.source.path)" = '"public.geojson"' ]

  # Without it, a full build stops instead of skipping it, and a build of
  # another layer stops too.
  rm "$BUILD" "${PIPELINE_INPUT_DIR}/public.geojson"
  run "$RUN"
  [ "$status" -eq 1 ]
  [[ $output == *"alpha: source data not found: public.geojson, and the map config requires it (require): nothing was built"* ]]
  [ ! -e "$BUILD" ]
  run "$RUN" beta
  [ "$status" -eq 1 ]
  [ ! -e "$BUILD" ]

  # A required layer must be among the layers built.
  config $'layers: [beta]\nrequire: [alpha]'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"require names layer 'alpha', which its layers list leaves out"* ]]
}

@test "provenance records the source data, the overrides and the hashes" {
  add_layer alpha
  config 'overrides: { alpha: { processing: { min_visible_px: 2 } } }'
  run "$RUN"
  [ "$status" -eq 0 ]
  local src="${PIPELINE_INPUT_DIR}/sample.geojson" mtime
  mtime=$(date -u -d "@$(stat -c %Y "$src")" +%Y-%m-%dT%H:%M:%SZ)
  run entry alpha '.provenance | [.origin, .source.path, .source.bytes, .source.modified_at, .overrides]'
  [ "$output" = "[\"committed\",\"sample.geojson\",$(stat -c %s "$src"),\"${mtime}\",{\"processing\":{\"min_visible_px\":2}}]" ]
  run entry alpha '.provenance | [.build_sha256, .display_sha256] | map(test("^[0-9a-f]{64}$"))'
  [ "$output" = "[true,true]" ]
  # The build hash is of the effective source, fields and processing.
  local want
  want=$(yq -o json '.processing.min_visible_px = 2 | {"source": .source, "fields": .fields, "processing": .processing}' \
    "${PIPELINE_LAYERS_DIR}/alpha.yaml" | jq -S -c . | sha256sum | cut -d' ' -f1)
  [ "$(entry alpha .provenance.build_sha256)" = "\"${want}\"" ]
  [ "$(entry alpha .min_visible_px)" = 2 ]
}

@test "the map view goes into style.json, and goes when removed" {
  add_layer alpha
  config $'view: { center: [-80.5, 45.25], zoom: 5.5 }\nbasemap: dark'
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata["erap:basemap"]' "$STYLE")" = dark ]
  run jq -e 'has("map") | not' "$BUILD"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.center, .zoom]' "$STYLE")" = '[[-80.5,45.25],5.5]' ]

  config '{}'
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  run jq -e '(has("center") or (.metadata | has("erap:basemap"))) | not' "$STYLE"
  [ "$status" -eq 0 ]
  run jq -e 'has("center") | not' "$STYLE"
  [ "$status" -eq 0 ]
}
