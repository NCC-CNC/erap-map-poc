#!/usr/bin/env bats
# Tests for `run.sh --style-only` (restyle_layer in bin/run.sh,
# write_style in lib/style.sh) and how --status reads a display
# update (lib/status.sh), on copies of the sample layer and a synthetic
# raster layer. Run in the test image with the other bats files:
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

@test "--style-only replaces the display only: tiles, build report and other layers kept" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local tiles beta_entry alpha_report built_from
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)
  beta_entry=$(entry_without beta)
  alpha_report=$(entry_without alpha display_updated_at provenance)
  built_from=$(entry_without alpha | jq -c ".provenance | del(.display_sha256)")

  restyle alpha '.title = "Alpha restyled"' \
    '.display.layers[0].paint["fill-color"][2][2] = "#ff0000"' \
    '.display.popup.sections[0].blocks[0].items |= .[:1]'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output == *"display updated for 1 layer(s), no tiles rebuilt"* ]]
  assert_no_temp_files

  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)" = "$tiles" ]
  [ "$(entry_without beta)" = "$beta_entry" ]
  [ "$(entry_without alpha display_updated_at provenance)" = "$alpha_report" ]
  # The provenance keeps what the tiles were built from; only the display
  # hash moves.
  [ "$(entry_without alpha | jq -c ".provenance | del(.display_sha256)")" = "$built_from" ]
  run jq -e '.layers[] | select(.name == "alpha") | .display_updated_at | type == "string"' "$BUILD"
  [ "$status" -eq 0 ]
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

@test "--style-only with no names updates every built layer, skipping unbuilt ones" {
  add_layer alpha beta
  run "$RUN" alpha beta
  [ "$status" -eq 0 ]
  add_layer gamma
  restyle alpha '.title = "A2"'
  restyle beta '.title = "B2"'

  run "$RUN" --style-only
  [ "$status" -eq 0 ]
  [[ $output == *"display updated for 2 layer(s)"* ]]
  run jq -c '[.metadata["erap:layers"] | to_entries[] | [.key, .value.title]]' "$STYLE"
  [ "$output" = '[["alpha","A2"],["beta","B2"]]' ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles" ]
}

@test "--style-only rejects an invalid layer file without changing build.json or style.json" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$BUILD" "$STYLE")

  restyle alpha '.visible = "yes"'
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [[ $output == *"alpha.yaml: at '/visible'"* ]]
  [[ $output == *"alpha.yaml has problems (above); keeping the previous build"* ]]
  [ "$(sha256sum "$BUILD" "$STYLE")" = "$before" ]
  assert_no_temp_files

  # Not YAML at all: the same.
  printf 'title: [unclosed\n' >"${PIPELINE_LAYERS_DIR}/alpha.yaml"
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [ "$(sha256sum "$BUILD" "$STYLE")" = "$before" ]

  # The bad layer fails; the good one is still updated.
  restyle beta '.title = "B2"'
  run "$RUN" --style-only alpha beta
  [ "$status" -eq 1 ]
  [[ $output == *"1 of 2 layer(s) failed: alpha"* ]]
  run jq -c '[.metadata["erap:layers"][] | .title]' "$STYLE"
  [ "$output" = '["Sample polygons","B2"]' ]
}

@test "--style-only of a layer with no built archive is an error and changes nothing" {
  add_layer alpha beta
  run "$RUN" --style-only alpha
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'alpha' is not built yet"* ]]
  [ ! -e "$BUILD" ]

  run "$RUN" --style-only
  [ "$status" -eq 2 ]
  [[ $output == *"no layers built"* ]]

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
  run "$RUN" --style-only
  [ "$status" -eq 2 ]
  [[ $output == *"skipping alpha: archive missing"* ]]
  [ "$(sha256sum "$BUILD")" = "$before" ]
}

@test "--style-only recolours a raster layer, leaving the archive byte-identical" {
  add_layer alpha
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.cog.tif" before report
  before=$(sha256sum "$archive")
  report=$(entry_without cover display_updated_at provenance)

  restyle cover '.display.layers[0].paint["color-relief-color"][6] = "rgba(255, 0, 0, 1)"' \
    '.display.layers[0].paint["color-relief-opacity"] = 0.4'
  run "$RUN" --style-only cover
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$archive")" = "$before" ]
  [ "$(entry_without cover display_updated_at provenance)" = "$report" ]
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
  [ "$(state_of alpha)" = restyle ]
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")" = "$tiles" ]
  run jq -e --argjson f "$(yq -o json -I 0 . "${PIPELINE_LAYERS_DIR}/alpha.yaml")" \
    '.metadata["erap:layers"].alpha | .themes == .display.themes and .popup == .display.popup' "$STYLE"
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

@test "--status: a changed display needs --style-only, which makes it current" {
  add_layer alpha beta
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(state_of alpha)" = current ]

  restyle alpha '.order = 11'
  restyle cover '.display.layers[0].paint["color-relief-opacity"] = 0.5'
  [ "$(state_of alpha)" = restyle ]
  [ "$(notes_of alpha)" = "display changed since it was last updated (alpha.yaml; --style-only updates it)" ]
  [ "$(state_of cover)" = restyle ]
  run "$RUN" --status alpha
  [[ ${lines[1]} == "alpha "*restyle* ]]
  [[ ${lines[2]} == "  - display changed since it was last updated"* ]]

  local built_at
  built_at=$(jq -r '.layers[] | select(.name == "alpha") | .built_at' "$BUILD")
  sleep 1
  run "$RUN" --style-only alpha cover
  [ "$status" -eq 0 ]
  [ "$(state_of alpha)" = current ]
  [ "$(state_of cover)" = current ]
  [ "$(state_of beta)" = current ]
  run "$RUN" --status --json alpha
  run jq -e --arg b "$built_at" '.layers[0]
    | .built_at == $b and .display_updated_at > .built_at' <<<"$output"
  [ "$status" -eq 0 ]
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

  # Source data and display changed: stale (a rebuild covers both), with
  # both notes.
  touch -d "@$(($(date +%s) + 120))" "${PIPELINE_INPUT_DIR}/sample.geojson"
  restyle beta '.title = "B2"'
  [ "$(state_of beta)" = stale ]
  [ "$(notes_of beta)" = "source data changed since the build;display changed since it was last updated (beta.yaml; --style-only updates it)" ]
}

@test "--status reads an entry without display_updated_at by its built_at" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  jq '.layers[0] |= del(.display_updated_at)' "$BUILD" >"${BUILD}.new"
  mv "${BUILD}.new" "$BUILD"
  [ "$(state_of alpha)" = current ]
  run "$RUN" --status --json
  run jq -e '.layers[0] | .display_updated_at == .built_at' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--style-only cannot be combined with another mode" {
  run "$RUN" --style-only --status
  [ "$status" -eq 2 ]
  [[ $output == *"cannot be used together"* ]]
  run "$RUN" --style-only --json
  [ "$status" -eq 2 ]
  [[ $output == *"--json works only with --status"* ]]
}
