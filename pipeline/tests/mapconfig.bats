#!/usr/bin/env bats
# Tests for the local map config (ADR 0009; lib/mapconfig.sh, the display
# tool's `layers` command and their use in bin/run.sh): layer selection,
# overrides, local-only layers, missing sources, provenance and the map
# view, on copies of the sample layer. Run in the test image with the other
# bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/repo/map.config.json"
  CONFIG=$PIPELINE_MAP_CONFIG
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR" "${BATS_TEST_TMPDIR}/repo"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
  # The sample layer's configs (in tests/layers/ once they move there,
  # #17). Small and quick: z0 to z4 is enough here.
  SAMPLE_DIR="${PIPELINE_ROOT}/tests/layers"
  [[ -f "${SAMPLE_DIR}/sample.env" ]] || SAMPLE_DIR="${PIPELINE_ROOT}/layers"
  SAMPLE_ENV=$(sed -e 's|^LAYER_INPUT=.*|LAYER_INPUT=sample.geojson|' \
    -e 's|^LAYER_MAX_ZOOM=.*|LAYER_MAX_ZOOM=4|' "${SAMPLE_DIR}/sample.env")
}

# add_layer NAME...: copies of the sample layer in DIR (default the layers
# dir), reading sample.geojson in the input dir.
add_layer() {
  local dir=$PIPELINE_LAYERS_DIR name
  if [[ $1 == --dir ]]; then
    dir=$2
    shift 2
    mkdir -p "$dir"
  fi
  for name in "$@"; do
    printf '%s\n' "$SAMPLE_ENV" >"${dir}/${name}.env"
    cp "${SAMPLE_DIR}/sample.style.json" "${dir}/${name}.style.json"
  done
}

# config JSON: write the map config.
config() {
  printf '%s\n' "$1" >"$CONFIG"
}

# entry NAME JQ: a jq filter on NAME's manifest entry.
entry() {
  jq -c --arg n "$1" "first(.layers[] | select(.name == \$n)) | $2" "$MANIFEST"
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

@test "no map config file: every committed layer, as it is" {
  add_layer alpha
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output != *"map config:"* ]]
  run entry alpha '[.enabled, .provenance.origin, .provenance.overrides, .display.title]'
  [ "$output" = '[true,"committed",null,"Sample polygons"]' ]
  run jq -e 'has("map") | not' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "enabled and disabled select the layers to build" {
  add_layer alpha beta gamma
  config '{"enabled": ["alpha", "beta"], "disabled": ["beta"]}'
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output == *"map config: $CONFIG"* ]]
  [ -s "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/beta.pmtiles" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles" ]
  [ "$(state_of beta)" = disabled ]
  [ "$(notes_of gamma)" = "not enabled in the map config" ]
  run status_json
  run jq -c '[.layers[] | [.name, .enabled, .origin]]' <<<"$output"
  [ "$output" = '[["alpha",true,"committed"],["beta",false,"committed"],["gamma",false,"committed"]]' ]

  # Naming a disabled layer is a usage error.
  run "$RUN" beta
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'beta' is not enabled in the map config"* ]]
}

@test "disabling a built layer hides it from the map; --style-only applies it, no rebuild" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)

  config '{"disabled": ["beta"]}'
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  [[ $output == *"skipping beta: not enabled in the map config"* ]]
  [ "$(entry beta .enabled)" = false ]
  [ "$(entry alpha .enabled)" = true ]
  run jq -r '[.sources | keys[]] | join(",")' "$STYLE"
  [ "$output" = "alpha" ]
  [ "$(state_of beta)" = disabled ]
  [[ "$(notes_of beta)" == *"built before: hidden from the map"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)" = "$tiles" ]

  rm "$CONFIG"
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  [ "$(entry beta .enabled)" = true ]
  run jq -r '[.sources | keys[]] | join(",")' "$STYLE"
  [ "$output" = "alpha,beta" ]
}

@test "display overrides are merged over the .style.json and applied by --style-only" {
  add_layer alpha
  local committed
  committed=$(cat "${PIPELINE_LAYERS_DIR}/alpha.style.json")
  config '{"overrides": {"alpha": {"title": "My alpha", "order": 3,
    "style": {"symbology": {"outline": {"color": "#000000"}}, "popup": {"charts": null}}}}}'
  run "$RUN"
  [ "$status" -eq 0 ]
  run entry alpha '[.display.title, .display.order, (.display.popup | has("charts")),
    (.display.layers[] | select(.id == "outline") | .paint["line-color"], .paint["line-width"])]'
  [ "$output" = '["My alpha",3,false,"#000000",0.75]' ]
  run entry alpha '.provenance.overrides.title'
  [ "$output" = '"My alpha"' ]
  # The committed file is not touched.
  [ "$(cat "${PIPELINE_LAYERS_DIR}/alpha.style.json")" = "$committed" ]
  [ "$(state_of alpha)" = current ]

  # A display override change needs --style-only only.
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")
  config '{"overrides": {"alpha": {"title": "Renamed"}}}'
  [ "$(state_of alpha)" = restyle ]
  [[ "$(notes_of alpha)" == *"display config changed since the display was last updated"* ]]
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [ "$(entry alpha .display.title)" = '"Renamed"' ]
  [ "$(entry alpha .provenance.overrides)" = '{"title":"Renamed"}' ]
  [ "$(state_of alpha)" = current ]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")" = "$tiles" ]
}

@test "input and env overrides change the tiles: stale until rebuilt" {
  add_layer alpha
  cp "${PIPELINE_INPUT_DIR}/sample.geojson" "${PIPELINE_INPUT_DIR}/other.geojson"
  config '{"overrides": {"alpha": {"input": "other.geojson"}}}'
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(entry alpha .provenance.source.path)" = '"other.geojson"' ]
  [ "$(entry alpha .maxzoom)" = 4 ]
  [ "$(state_of alpha)" = current ]

  config '{"overrides": {"alpha": {"input": "other.geojson", "env": {"LAYER_MAX_ZOOM": 3,
    "LAYER_FIELDS": ["id", "NAME_EN:name", "area_ha", "score", "v2020", "v2021", "v2022", "v2023", "v2024"]}}}}'
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "settings changed since the build (alpha.env or the map config's input, env, calculated or rules)" ]
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  [ "$(entry alpha .maxzoom)" = 3 ]
  [ "$(entry alpha '.provenance.overrides.env.LAYER_MAX_ZOOM')" = 3 ]
  [ "$(state_of alpha)" = current ]
}

@test "a bad map config stops every mode before anything changes" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(cat "$MANIFEST")

  config '{"layer": []}'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"map.config.json: (top level) must NOT have additional properties: layer"* ]]
  run "$RUN" --status
  [ "$status" -eq 2 ]
  run "$RUN" --style-only
  [ "$status" -eq 2 ]

  config '{"overrides": {"nope": {"title": "x"}}}'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"overrides: no layer named nope (layers: alpha)"* ]]

  config '{"overrides": {"alpha": {"style": {"symbology": {"geometry": "triangle"}}}}}'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"overrides.alpha: /symbology/geometry must be equal to one of the allowed values"* ]]

  config '{"layerDirs": ["nowhere"]}'
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"layerDirs: folder not found: nowhere"* ]]

  config '{"enabled": ['
  run "$RUN"
  [ "$status" -eq 2 ]
  [[ $output == *"is not valid JSON"* ]]

  [ "$(cat "$MANIFEST")" = "$before" ]
}

@test "local-only layers, in the config and in a layer dir, build like committed ones" {
  add_layer alpha
  add_layer --dir "${BATS_TEST_TMPDIR}/repo/layers.local" delta
  local style
  style=$(cat "${SAMPLE_DIR}/sample.style.json")
  config "{\"layerDirs\": [\"layers.local\"],
    \"localLayers\": {\"gamma\": {
      \"env\": {\"LAYER_INPUT\": \"sample.geojson\", \"LAYER_FIELDS\": [\"id\", \"NAME_EN:name\", \"score\"],
                \"LAYER_FEATURE_ID\": \"id\", \"LAYER_MIN_ZOOM\": 0, \"LAYER_MAX_ZOOM\": 3},
      \"style\": $(jq '.title = "Gamma" | .popup.stats |= .[:1] | del(.popup.charts)
        | .popup.title = {"attribute": "name"}' <<<"$style")}}}"
  run "$RUN"
  [ "$status" -eq 0 ]
  run jq -c '[.layers[] | [.name, .provenance.origin, .display.title, .maxzoom]]' "$MANIFEST"
  [ "$output" = '[["alpha","committed","Sample polygons",4],["delta","local","Sample polygons",4],["gamma","config","Gamma",3]]' ]
  run status_json
  run jq -c '[.layers[] | [.name, .state, .origin]]' <<<"$output"
  [ "$output" = '[["alpha","current","committed"],["delta","current","local"],["gamma","current","config"]]' ]

  # An inline layer's settings are tracked through their hash.
  config "$(jq '.localLayers.gamma.env.LAYER_MAX_ZOOM = 2' "$CONFIG")"
  [ "$(state_of gamma)" = stale ]

  # A local-only layer may not take a committed name.
  add_layer --dir "${BATS_TEST_TMPDIR}/repo/layers.local" alpha
  run "$RUN" --status
  [ "$status" -eq 2 ]
  [[ $output == *"layer alpha is in both"* ]]
}

@test "a full build skips layers with no source data; a named one fails" {
  add_layer alpha beta
  sed -i 's|^LAYER_INPUT=.*|LAYER_INPUT=not_here.gpkg|' "${PIPELINE_LAYERS_DIR}/beta.env"
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
  config '{"enabled": ["beta"]}'
  run "$RUN"
  [ "$status" -eq 1 ]
  [[ $output == *"nothing to build"* ]]
}

@test "provenance records the source data and the overrides applied" {
  add_layer alpha
  config '{"overrides": {"alpha": {"defaultVisible": false}}}'
  run "$RUN"
  [ "$status" -eq 0 ]
  local src="${PIPELINE_INPUT_DIR}/sample.geojson" mtime
  mtime=$(date -u -d "@$(stat -c %Y "$src")" +%Y-%m-%dT%H:%M:%SZ)
  run entry alpha '.provenance | [.origin, .source.path, .source.bytes, .source.modified_at, .overrides]'
  [ "$output" = "[\"committed\",\"sample.geojson\",$(stat -c %s "$src"),\"${mtime}\",{\"defaultVisible\":false}]" ]
  run entry alpha '.provenance | [.env_sha256, .style_sha256] | map(test("^[0-9a-f]{64}$"))'
  [ "$output" = "[true,true]" ]
  [ "$(entry alpha .provenance.env_sha256)" = "\"$(sha256sum "${PIPELINE_LAYERS_DIR}/alpha.env" | cut -d' ' -f1)\"" ]
}

@test "the map view goes into the manifest and style.json, and goes when removed" {
  add_layer alpha
  config '{"map": {"center": [-80.5, 45.25], "zoom": 5.5, "basemap": "dark"}}'
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq -c .map "$MANIFEST")" = '{"center":[-80.5,45.25],"zoom":5.5,"basemap":"dark"}' ]
  [ "$(jq -c '[.center, .zoom]' "$STYLE")" = '[[-80.5,45.25],5.5]' ]

  config '{}'
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  run jq -e 'has("map") | not' "$MANIFEST"
  [ "$status" -eq 0 ]
  run jq -e 'has("center") | not' "$STYLE"
  [ "$status" -eq 0 ]
}
