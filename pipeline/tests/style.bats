#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR/..
# The display block and style.json (lib/style.sh): a layer file's display
# becomes its manifest entry's `display` block, as the web app reads it,
# and style.json combines every built layer. The expected display fixtures
# are read by the web app's tests too (web/src/test/fixtures.ts), so both
# sides are tested against what the pipeline writes. Run in the test image
# with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  FIXTURES="${PIPELINE_ROOT}/tests/fixtures"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# display_of FILE: the display block of layer file FILE, sorted JSON.
display_of() {
  (
    # shellcheck source=lib/log.sh
    source "${PIPELINE_ROOT}/lib/log.sh"
    # shellcheck source=lib/style.sh
    source "${PIPELINE_ROOT}/lib/style.sh"
    yq -o json '.' "$1" >"${BATS_TEST_TMPDIR}/layer.json"
    display_block "${BATS_TEST_TMPDIR}/layer.json" | jq -S .
  )
}

@test "the test layers' display blocks are the expected fixtures" {
  cp "${PIPELINE_ROOT}"/tests/layers/*.yaml "$PIPELINE_LAYERS_DIR"
  run "$RUN"
  [ "$status" -eq 0 ]
  run jq -e --slurpfile want "${FIXTURES}/expected_display.json" \
    '[.layers[] | {key: .name, value: .display}] | from_entries == $want[0]' "$MANIFEST"
  [ "$status" -eq 0 ]

  [ "$(display_of "${FIXTURES}/sample_modal.yaml")" = "$(jq -S . "${FIXTURES}/expected_modal_display.json")" ]
  [ "$(display_of "${FIXTURES}/raster.yaml")" = "$(jq -S . "${FIXTURES}/expected_raster_display.json")" ]
}

@test "the ecoregions display block is the web app's fixture" {
  # web/src/test/fixtures.ts reads it for the modal and theme tests.
  run diff <(display_of "${PIPELINE_ROOT}/layers/ecoregions.yaml") \
    <(jq -S . "${FIXTURES}/ecoregions_display.json")
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "themes: the first draws display.layers; its paint is what the others change" {
  run display_of "${FIXTURES}/sample_modal.yaml"
  run jq -c '[.defaultTheme, (.themes | map(.id)), (.legend == .themes[0].legend),
    (.themes[0].paint | keys), (.themes[0].paint.fill | keys)]' <<<"$output"
  [ "$output" = '["score",["score","score_gradient","area"],true,["fill"],["fill-color"]]' ]

  # A theme that changes the outline too: the first theme gets the
  # outline's paint as display.layers set it.
  yq '.display.themes[1].paint.outline = {"line-width": 2}' "${FIXTURES}/sample_modal.yaml" \
    >"${BATS_TEST_TMPDIR}/m.yaml"
  run display_of "${BATS_TEST_TMPDIR}/m.yaml"
  run jq -c '.themes[0].paint | [keys, .outline]' <<<"$output"
  [ "$output" = '[["fill","outline"],{"line-width":0.75}]' ]
}

@test "display checks: legend, unique ids and theme paint on a style layer" {
  cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "$PIPELINE_LAYERS_DIR"
  local file="${PIPELINE_LAYERS_DIR}/sample.yaml"

  set_layer "$file" 'del(.display.legend.kind)'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"sample.yaml: display.legend: needed, with kind, shape, border and opacity"* ]]

  cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "$file"
  set_layer "$file" '.display.layers[1].id = "fill"'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"sample.yaml: display.layers: id fill is used twice"* ]]

  cp "${FIXTURES}/sample_modal.yaml" "$file"
  set_layer "$file" '.display.themes[1].paint.halo = {"line-width": 1}' 'del(.display.themes[2].legend)'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"sample.yaml: display.themes[1].paint: halo is not an id in display.layers"* ]]
  [[ $output == *"sample.yaml: display.themes[2].legend: needed"* ]]
  [ ! -e "$MANIFEST" ]
}

@test "style.json is a standalone style of every layer, in display order" {
  cp "${PIPELINE_ROOT}"/tests/layers/*.yaml "$PIPELINE_LAYERS_DIR"
  run "$RUN"
  [ "$status" -eq 0 ]

  run jq -e '
    .version == 8 and (has("glyphs") | not)
    and .sources == {
      sample: {type: "vector", url: "pmtiles://sample.pmtiles"},
      sample_points: {type: "vector", url: "pmtiles://sample_points.pmtiles"}}
    and ([.layers[] | [.id, .source, .["source-layer"], .layout.visibility]] == [
      ["sample-fill", "sample", "sample", "visible"],
      ["sample-outline", "sample", "sample", "visible"],
      ["sample_points-circle", "sample_points", "sample_points", "visible"]])' "$STYLE"
  [ "$status" -eq 0 ]

  # The paint comes straight from the display blocks.
  run jq -e --slurpfile want "${FIXTURES}/expected_display.json" \
    '.layers[0].paint == $want[0].sample.layers[0].paint' "$STYLE"
  [ "$status" -eq 0 ]

  # A higher order on sample draws it on top, a hidden layer is hidden, and
  # text needs the glyphs.
  set_layer "${PIPELINE_LAYERS_DIR}/sample.yaml" '.order = 30' '.visible = false' \
    '.display.layers += [{"id": "label", "type": "symbol", "layout": {"text-field": ["get", "name"]}}]'
  run "$RUN" --style-only sample
  [ "$status" -eq 0 ]
  run jq -r '[.layers[] | "\(.id):\(.layout.visibility)"] | join(",")' "$STYLE"
  [ "$output" = "sample_points-circle:visible,sample-fill:none,sample-outline:none,sample-label:none" ]
  run jq -r '.glyphs' "$STYLE"
  [[ $output == "https://tiles.openfreemap.org/fonts/"* ]]
}

@test "no layer in layers/ reads the synthetic fixtures: they are test layers (#17)" {
  run grep -l 'tests/fixtures' "${PIPELINE_ROOT}"/layers/*.yaml
  [ "$status" -eq 1 ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample.yaml" ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample_points.yaml" ]
}
