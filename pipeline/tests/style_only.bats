#!/usr/bin/env bats
# Tests for `run.sh --style-only` (style_only_main in bin/run.sh,
# write_style in lib/style.sh), on copies of the sample layer and a
# synthetic raster layer. Run in the test image with the other bats files:
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
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
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

# add_raster NAME: a raster layer on a synthetic binary GeoTIFF, z3 to z6.
add_raster() {
  "${PIPELINE_ROOT}/tests/fixtures/make_raster.sh" byte "${PIPELINE_INPUT_DIR}/$1.tif" 2>/dev/null
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.yaml" "${PIPELINE_LAYERS_DIR}/$1.yaml"
  set_layer "${PIPELINE_LAYERS_DIR}/$1.yaml" ".source.path = \"$1.tif\"" '.processing.maxzoom = 6'
}

# restyle NAME EXPR...: edit the layer file with yq.
restyle() {
  local name=$1
  shift
  set_layer "${PIPELINE_LAYERS_DIR}/${name}.yaml" "$@"
}

# entry_without NAME FIELD...: the layer's manifest entry minus FIELDs.
entry_without() {
  local name=$1
  shift
  jq -c --arg n "$name" 'first(.layers[] | select(.name == $n))
    | delpaths([$ARGS.positional[] | [.]])' "$BUILD" --args "$@"
}

state_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .state'
}

notes_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .notes | join(";")'
}

@test "--style-only rewrites style.json only: tiles and build.json kept" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local tiles build
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)
  build=$(sha256sum "$BUILD")

  restyle alpha '.title = "Alpha restyled"' \
    '.display.layers[0].paint["fill-color"][2][2] = "#ff0000"' \
    '.display.popup.sections[0].blocks[0].items |= .[:1]'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output == *"style.json rewritten from the layer files, no tiles rebuilt"* ]]
  assert_no_temp_files

  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)" = "$tiles" ]
  [ "$(sha256sum "$BUILD")" = "$build" ]
  run jq -e '.metadata["erap:layers"].alpha
    | .title == "Alpha restyled" and (.popup.sections[0].blocks[0].items | length) == 1' "$STYLE"
  [ "$status" -eq 0 ]

  # style.json keeps the other layer.
  run jq -r '[.sources | keys[]] | join(",")' "$STYLE"
  [ "$output" = "alpha,beta" ]
  run jq -r '[.layers[] | select(.source == "alpha") | .paint["fill-color"]?
    | select(. != null) | .[2][2]] | first' "$STYLE"
  [ "$output" = "#ff0000" ]
}

@test "--style-only updates every built layer, skipping unbuilt ones" {
  add_layer alpha beta
  run "$RUN" alpha beta
  [ "$status" -eq 0 ]
  add_layer gamma
  restyle alpha '.title = "A2"'
  restyle beta '.title = "B2"'

  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  run jq -c '[.metadata["erap:layers"] | to_entries[] | [.key, .value.title]]' "$STYLE"
  [ "$output" = '[["alpha","A2"],["beta","B2"]]' ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles" ]
}

@test "--style-only fails on an invalid layer file, leaving it out of style.json" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local build
  build=$(sha256sum "$BUILD")

  # The bad layer fails the run and is left out; the good one is updated.
  restyle alpha '.visible = "yes"'
  restyle beta '.title = "B2"'
  run "$RUN" --style-only
  [ "$status" -eq 1 ]
  [[ $output == *"alpha.yaml: at '/visible'"* ]]
  [[ $output == *"layer alpha: left out of style.json until alpha.yaml is fixed"* ]]
  [ "$(sha256sum "$BUILD")" = "$build" ]
  run jq -c '[.metadata["erap:layers"][] | .title]' "$STYLE"
  [ "$output" = '["B2"]' ]
  assert_no_temp_files

  # Not YAML at all: the same.
  printf 'title: [unclosed\n' >"${PIPELINE_LAYERS_DIR}/alpha.yaml"
  run "$RUN" --style-only
  [ "$status" -eq 1 ]
  [ "$(sha256sum "$BUILD")" = "$build" ]

  # Fixed, it is back.
  add_layer alpha
  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  run jq -c '[.metadata["erap:layers"][] | .title]' "$STYLE"
  [ "$output" = '["Sample polygons","B2"]' ]
}

@test "--style-only of a layer with no built archive is an error and changes nothing" {
  add_layer alpha beta
  run "$RUN" --style-only alpha
  [ "$status" -eq 2 ]
  [[ $output == *"no layers built"* ]]
  [ ! -e "$BUILD" ]

  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$BUILD")
  run "$RUN" --style-only alpha beta
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'beta' is not built yet"* ]]
  [ "$(sha256sum "$BUILD")" = "$before" ]

  # An entry whose archive is gone needs a rebuild.
  rm "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles"
  run "$RUN" --style-only alpha
  [ "$status" -eq 2 ]
  [ "$(sha256sum "$BUILD")" = "$before" ]
}

@test "--style-only recolours a raster layer, leaving the archive byte-identical" {
  add_layer alpha
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.cog.tif" before report
  before=$(sha256sum "$archive")
  report=$(entry_without cover)

  restyle cover '.display.layers[0].paint["color-relief-color"][6] = "rgba(255, 0, 0, 1)"' \
    '.display.layers[0].paint["color-relief-opacity"] = 0.4'
  run "$RUN" --style-only cover
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$archive")" = "$before" ]
  [ "$(entry_without cover)" = "$report" ]
  run jq -r '.layers[] | select(.source == "cover") | .paint["color-relief-color"][6]' "$STYLE"
  [ "$output" = "rgba(255, 0, 0, 1)" ]
  run jq -r '.layers[] | select(.name == "cover") | .type' "$BUILD"
  [ "$output" = raster ]
}

@test "--style-only applies colour themes and a dialog pop-up (ADR 0012)" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")

  # The sample modal fixture: three themes and a dialog, the same source,
  # fields and processing.
  cp "${PIPELINE_ROOT}/tests/fixtures/sample_modal.yaml" "${PIPELINE_LAYERS_DIR}/alpha.yaml"
  restyle alpha '.source.path = "sample.geojson"'
  [ "$(state_of alpha)" = current ]
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")" = "$tiles" ]
  run jq -e --argjson f "$(yq -o json -I 0 . "${PIPELINE_LAYERS_DIR}/alpha.yaml")" \
    '.metadata["erap:layers"].alpha | .themes == $f.display.themes and .popup == $f.display.popup' "$STYLE"
  [ "$status" -eq 0 ]

  # The first theme is what the style layers draw.
  restyle alpha 'del(.display.themes[0])' \
    '.display.layers[0].paint["fill-color"] = .display.themes[0].paint.fill["fill-color"]' \
    'del(.display.themes[0].paint)'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  run jq -r '.metadata["erap:layers"].alpha.themes | [.[0].id, .[0].legend.kind, length] | join(",")' "$STYLE"
  [ "$output" = "score_gradient,gradient,2" ]
  run jq -r '.layers[0].paint["fill-color"][2][0]' "$STYLE"
  [ "$output" = interpolate ]
}

@test "--status: a changed display keeps a layer current; any run applies it" {
  add_layer alpha beta
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]

  restyle alpha '.order = 11'
  restyle cover '.display.layers[0].paint["color-relief-opacity"] = 0.5'
  [ "$(state_of alpha)" = current ]
  [ "$(state_of cover)" = current ]
  [ "$(notes_of alpha)" = "" ]

  # Building beta alone writes alpha's and cover's display too.
  run "$RUN" beta
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata["erap:layers"].alpha.order' "$STYLE")" = 11 ]
  run jq -r '.layers[] | select(.source == "cover") | .paint["color-relief-opacity"]' "$STYLE"
  [ "$output" = 0.5 ]
}

@test "--status: a style-only update does not hide a stale build" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]

  # Processing changed: stale, and still stale after --style-only.
  restyle alpha '.processing.maxzoom = 6'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "source, fields or processing changed since the build (alpha.yaml or the map config's overrides)" ]

  # Source data changed: stale.
  touch -d "@$(($(date +%s) + 120))" "${PIPELINE_INPUT_DIR}/sample.geojson"
  restyle beta '.title = "B2"'
  [ "$(state_of beta)" = stale ]
  [ "$(notes_of beta)" = "source data changed since the build" ]
}

@test "--style-only cannot be combined with another mode" {
  run "$RUN" --style-only --status
  [ "$status" -eq 2 ]
  [[ $output == *"cannot be used together"* ]]
  run "$RUN" --style-only --json
  [ "$status" -eq 2 ]
  [[ $output == *"--json works only with --status"* ]]
}
