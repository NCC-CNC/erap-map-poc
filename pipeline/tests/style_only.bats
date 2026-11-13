#!/usr/bin/env bats
# Tests for `run.sh --style-only` (restyle_layer in bin/run.sh,
# manifest_set_display in lib/manifest.sh) and how --status reads a display
# update (lib/status.sh), on copies of the sample layer and a synthetic
# raster layer. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
}

# add_layer NAME...: copies of the sample layer, reading the input dir.
add_layer() {
  local name
  for name in "$@"; do
    sed 's|^LAYER_INPUT=.*|LAYER_INPUT=sample.geojson|' \
      "${PIPELINE_ROOT}/tests/layers/sample.env" >"${PIPELINE_LAYERS_DIR}/${name}.env"
    cp "${PIPELINE_ROOT}/tests/layers/sample.style.json" "${PIPELINE_LAYERS_DIR}/${name}.style.json"
  done
}

# add_raster NAME: a raster layer on a synthetic binary GeoTIFF, z3 to z6.
add_raster() {
  "${PIPELINE_ROOT}/tests/fixtures/make_raster.sh" byte "${PIPELINE_INPUT_DIR}/$1.tif" 2>/dev/null
  printf '%s\n' 'LAYER_TYPE=raster' "LAYER_INPUT=$1.tif" 'LAYER_MIN_ZOOM=3' 'LAYER_MAX_ZOOM=6' \
    >"${PIPELINE_LAYERS_DIR}/$1.env"
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" "${PIPELINE_LAYERS_DIR}/$1.style.json"
}

# restyle NAME JQ: edit the layer's .style.json with a jq filter.
restyle() {
  local file="${PIPELINE_LAYERS_DIR}/$1.style.json"
  jq "$2" "$file" >"${file}.new" && mv "${file}.new" "$file"
}

# entry_without NAME FIELD...: the layer's manifest entry minus FIELDs.
entry_without() {
  local name=$1
  shift
  jq -c --arg n "$name" 'first(.layers[] | select(.name == $n))
    | delpaths([$ARGS.positional[] | [.]])' "$MANIFEST" --args "$@"
}

state_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .state'
}

notes_of() {
  "$RUN" --status --json | jq -r --arg n "$1" '.layers[] | select(.name == $n) | .notes | join(";")'
}

# age_build NAME...: move the layers' build into the past (built_at and
# display_updated_at 5 minutes ago) and their configs and source data
# further back, so a test can then change a file between the build and now.
age_build() {
  local past name
  past=$(date -u -d "@$(($(date +%s) - 300))" +%Y-%m-%dT%H:%M:%SZ)
  for name in "$@"; do
    jq --arg n "$name" --arg t "$past" \
      '.layers |= map(if .name == $n then .built_at = $t | .display_updated_at = $t else . end)' \
      "$MANIFEST" >"${MANIFEST}.new" && mv "${MANIFEST}.new" "$MANIFEST"
    touch -d "@$(($(date +%s) - 600))" "${PIPELINE_LAYERS_DIR}/${name}".*
  done
  touch -d "@$(($(date +%s) - 600))" "$PIPELINE_INPUT_DIR"/*
}

# touch_between FILE...: a modification time after the aged build, before now.
touch_between() {
  touch -d "@$(($(date +%s) - 100))" "$@"
}

assert_no_temp_files() {
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--style-only replaces the display only: tiles, build report and other layers kept" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local tiles beta_entry alpha_report built_from
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)
  beta_entry=$(entry_without beta)
  alpha_report=$(entry_without alpha display display_updated_at provenance)
  built_from=$(entry_without alpha | jq -c ".provenance | del(.style_sha256)")

  restyle alpha '.title = "Alpha restyled"
    | .symbology.color.stops[0].color = "#ff0000"
    | .popup.stats |= .[:1]'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output == *"display updated for 1 layer(s), no tiles rebuilt"* ]]
  assert_no_temp_files

  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}"/*.pmtiles)" = "$tiles" ]
  [ "$(entry_without beta)" = "$beta_entry" ]
  [ "$(entry_without alpha display display_updated_at provenance)" = "$alpha_report" ]
  # The provenance keeps what the tiles were built from; only the display
  # hash moves.
  [ "$(entry_without alpha | jq -c ".provenance | del(.style_sha256)")" = "$built_from" ]
  run jq -e '.layers[] | select(.name == "alpha")
    | .display.title == "Alpha restyled"
      and (.display.popup.stats | length) == 1
      and .display.layers[0].paint["fill-color"][2][2] == "#ff0000"
      and (.display_updated_at | type == "string")' "$MANIFEST"
  [ "$status" -eq 0 ]

  # style.json is rewritten from the whole manifest.
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
  run jq -c '[.layers[] | [.name, .display.title]]' "$MANIFEST"
  [ "$output" = '[["alpha","A2"],["beta","B2"]]' ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/gamma.pmtiles" ]
}

@test "--style-only rejects an invalid style without changing the manifest" {
  add_layer alpha beta
  run "$RUN"
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$MANIFEST")

  restyle alpha '.defaultVisible = "yes"'
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [[ $output == *"invalid display config"* ]]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]
  assert_no_temp_files

  # Not JSON at all: the same.
  printf '{ not json\n' >"${PIPELINE_LAYERS_DIR}/alpha.style.json"
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]

  # The bad layer fails; the good one is still updated.
  restyle beta '.title = "B2"'
  run "$RUN" --style-only alpha beta
  [ "$status" -eq 1 ]
  [[ $output == *"1 of 2 layer(s) failed: alpha"* ]]
  run jq -c '[.layers[] | .display.title]' "$MANIFEST"
  [ "$output" = '["Sample polygons","B2"]' ]
}

@test "--style-only of a layer with no built archive is an error and changes nothing" {
  add_layer alpha beta
  run "$RUN" --style-only alpha
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'alpha' is not built yet"* ]]
  [ ! -e "$MANIFEST" ]

  run "$RUN" --style-only
  [ "$status" -eq 2 ]
  [[ $output == *"no layers built"* ]]

  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$MANIFEST")
  run "$RUN" --style-only alpha beta
  [ "$status" -eq 2 ]
  [[ $output == *"layer 'beta' is not built yet"* ]]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]

  # An entry whose archive is gone needs a rebuild.
  rm "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles"
  run "$RUN" --style-only alpha
  [ "$status" -eq 2 ]
  run "$RUN" --style-only
  [ "$status" -eq 2 ]
  [[ $output == *"skipping alpha: archive missing"* ]]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]
}

@test "--style-only recolours a raster layer, leaving the archive byte-identical" {
  add_layer alpha
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.cog.tif" before report
  before=$(sha256sum "$archive")
  report=$(entry_without cover display display_updated_at provenance)

  restyle cover '.symbology.color = "#ff0000" | .symbology.opacity = 0.4'
  run "$RUN" --style-only cover
  [ "$status" -eq 0 ]
  [[ $output != *"reading the source data"* ]]
  [ "$(sha256sum "$archive")" = "$before" ]
  [ "$(entry_without cover display display_updated_at provenance)" = "$report" ]
  run jq -r '.layers[] | select(.source == "cover") | .paint["color-relief-color"][6]' "$STYLE"
  [ "$output" = "rgba(255, 0, 0, 1)" ]
  run jq -r '.layers[] | select(.name == "cover") | .type' "$MANIFEST"
  [ "$output" = raster ]

  # The raster shorthand on the vector layer is still refused.
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" "${PIPELINE_LAYERS_DIR}/alpha.style.json"
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [[ $output == *'"geometry": "raster" is for raster layers only'* ]]
}

@test "--style-only resolves breaks from the source data, unless it changed since the build" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")

  # As in display.bats: quantile breaks on score, 4 classes.
  restyle alpha '.symbology.color = {type: "stepped", attribute: "score",
    breaks: {method: "quantile", classes: 4},
    colors: ["#111111", "#222222", "#333333", "#444444"],
    fallback: {color: "#999999"}}'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output == *"reading the source data for breaks (no tiling)"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")" = "$tiles" ]
  run jq -c '.layers[0].display.layers[0].paint["fill-color"][2]' "$MANIFEST"
  [ "$output" = '["step",["get","score"],"#111111",20,"#222222",47,"#333333",74,"#444444"]' ]

  # Breaks from data the tiles were not built from would not match them.
  touch -d "@$(($(date +%s) + 120))" "${PIPELINE_INPUT_DIR}/sample.geojson"
  local before
  before=$(sha256sum "$MANIFEST")
  run "$RUN" --style-only alpha
  [ "$status" -eq 1 ]
  [[ $output == *"changed since the build: rebuild the layer"* ]]
  [ "$(sha256sum "$MANIFEST")" = "$before" ]
}

@test "--style-only applies colour themes and a click modal, re-reading the data for a gradient range" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  local tiles
  tiles=$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")

  # The sample modal fixture: three themes, one of them a gradient over the
  # data's range of area_ha, so the source data is read (not the tiles).
  cp "${PIPELINE_ROOT}/tests/fixtures/sample_modal.style.json" "${PIPELINE_LAYERS_DIR}/alpha.style.json"
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output == *"reading the source data for breaks (no tiling)"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/alpha.pmtiles")" = "$tiles" ]
  run jq -e --slurpfile want "${PIPELINE_ROOT}/tests/fixtures/expected_modal_display.json" \
    '.layers[0].display == $want[0]' "$MANIFEST"
  [ "$status" -eq 0 ]

  # Themes with fixed ranges only need no data.
  restyle alpha 'del(.symbology.themes[2]) | .symbology.defaultTheme = "score_gradient"'
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [[ $output != *"reading the source data"* ]]
  run jq -r '.layers[0].display | [.defaultTheme, .legend.kind, (.themes | length)] | join(",")' "$MANIFEST"
  [ "$output" = "score_gradient,gradient,2" ]
}

@test "--status: a changed .style.json needs --style-only, which makes it current" {
  add_layer alpha beta
  add_raster cover
  run "$RUN"
  [ "$status" -eq 0 ]
  age_build alpha beta cover
  [ "$(state_of alpha)" = current ]

  touch_between "${PIPELINE_LAYERS_DIR}/alpha.style.json" "${PIPELINE_LAYERS_DIR}/cover.style.json"
  [ "$(state_of alpha)" = restyle ]
  [ "$(notes_of alpha)" = "alpha.style.json changed since the display was last updated (--style-only updates it)" ]
  [ "$(state_of cover)" = restyle ]
  run "$RUN" --status alpha
  [[ ${lines[1]} == "alpha "*restyle* ]]
  [[ ${lines[2]} == "  - alpha.style.json changed since the display was last updated"* ]]

  local built_at
  built_at=$(jq -r '.layers[] | select(.name == "alpha") | .built_at' "$MANIFEST")
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
  age_build alpha beta

  # .env changed: stale, and still stale after --style-only.
  touch_between "${PIPELINE_LAYERS_DIR}/alpha.env"
  run "$RUN" --style-only alpha
  [ "$status" -eq 0 ]
  [ "$(state_of alpha)" = stale ]
  [ "$(notes_of alpha)" = "alpha.env changed since the build" ]

  # Source data and .style.json changed: stale (a rebuild covers both),
  # with both notes.
  touch_between "${PIPELINE_INPUT_DIR}/sample.geojson" "${PIPELINE_LAYERS_DIR}/beta.style.json"
  [ "$(state_of beta)" = stale ]
  [ "$(notes_of beta)" = "source data changed since the build;beta.style.json changed since the display was last updated (--style-only updates it)" ]
}

@test "--status reads an entry without display_updated_at by its built_at" {
  add_layer alpha
  run "$RUN" alpha
  [ "$status" -eq 0 ]
  age_build alpha
  jq '.layers[0] |= del(.display_updated_at)' "$MANIFEST" >"${MANIFEST}.new"
  mv "${MANIFEST}.new" "$MANIFEST"
  [ "$(state_of alpha)" = current ]
  run "$RUN" --status --json
  run jq -e '.layers[0] | .display_updated_at == .built_at' <<<"$output"
  [ "$status" -eq 0 ]
  touch_between "${PIPELINE_LAYERS_DIR}/alpha.style.json"
  [ "$(state_of alpha)" = restyle ]
}

@test "--style-only cannot be combined with another mode" {
  run "$RUN" --style-only --status
  [ "$status" -eq 2 ]
  [[ $output == *"cannot be used together"* ]]
  run "$RUN" --style-only --json
  [ "$status" -eq 2 ]
  [[ $output == *"--json works only with --status"* ]]
}
