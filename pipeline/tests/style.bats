#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR/..
# style.json (lib/style.sh): the MapLibre style of every built layer, with
# what MapLibre does not know about in `erap:` metadata (design note 04),
# and the layer file checks on `display`. Run in the test image with the
# other bats files:
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
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# yaml_json FILE: layer file FILE as compact JSON.
yaml_json() {
  yq -o json -I 0 '.' "$1"
}

@test "style.json is a MapLibre style of every built layer, in display order" {
  cp "${PIPELINE_ROOT}"/tests/layers/*.yaml "$PIPELINE_LAYERS_DIR"
  run "$RUN"
  [ "$status" -eq 0 ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/manifest.json" ]

  run jq -e '
    .version == 8 and (has("glyphs") | not) and (has("center") | not)
    and (.metadata | has("erap:basemap") | not)
    and .sources == {
      sample: {type: "vector", url: "pmtiles://sample.pmtiles"},
      sample_points: {type: "vector", url: "pmtiles://sample_points.pmtiles"}}
    and ([.layers[] | [.id, .source, .["source-layer"], .layout.visibility, .metadata["erap:layer"]]] == [
      ["sample-fill", "sample", "sample", "visible", "sample"],
      ["sample-outline", "sample", "sample", "visible", "sample"],
      ["sample_points-circle", "sample_points", "sample_points", "visible", "sample_points"]])' "$STYLE"
  [ "$status" -eq 0 ]

  # The paint and the metadata come straight from the layer file.
  local sample
  sample=$(yaml_json "${PIPELINE_LAYERS_DIR}/sample.yaml")
  run jq -e --argjson f "$sample" '
    .layers[0].paint == $f.display.layers[0].paint
    and .metadata["erap:layers"].sample == {title: $f.title, type: "vector", order: 10,
      visible: true, legend: $f.display.legend, popup: $f.display.popup}' "$STYLE"
  [ "$status" -eq 0 ]

  # build.json holds the build report, no display.
  run jq -e '[.layers[].name] == ["sample", "sample_points"]
    and all(.layers[]; has("display") | not) and all(.layers[]; .feature_count > 0)' "$BUILD"
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
  run jq -c '.metadata["erap:layers"].sample | [.order, .visible]' "$STYLE"
  [ "$output" = '[30,false]' ]
}

@test "style.json: colour themes and the click modal as the layer file has them" {
  cp "${FIXTURES}/sample_modal.yaml" "${PIPELINE_LAYERS_DIR}/sample.yaml"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  run jq -e --argjson f "$(yaml_json "${FIXTURES}/sample_modal.yaml")" '
    .metadata["erap:layers"].sample as $m
    | $m.themes == $f.display.themes and $m.modal == $f.display.modal
      and ($m.themes[0] | has("paint") | not) and ($m | has("legend") | not)' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "a display change reaches style.json through a build or --style-only only" {
  cp "${PIPELINE_ROOT}"/tests/layers/*.yaml "$PIPELINE_LAYERS_DIR"
  run "$RUN"
  [ "$status" -eq 0 ]

  # Building another layer keeps sample's part as it was.
  set_layer "${PIPELINE_LAYERS_DIR}/sample.yaml" '.title = "Renamed"'
  run "$RUN" sample_points
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata["erap:layers"].sample.title' "$STYLE")" = "Sample polygons" ]
  run "$RUN" --status --json
  [ "$(jq -r '.layers[] | select(.name == "sample") | .state' <<<"$output")" = restyle ]

  # A layer file with problems does not stop another layer's --style-only,
  # and keeps its own part.
  set_layer "${PIPELINE_LAYERS_DIR}/sample_points.yaml" '.display.layers[0].id = "-bad"'
  run "$RUN" --style-only sample
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata["erap:layers"].sample.title' "$STYLE")" = "Renamed" ]
  [ "$(jq -r '.sources | keys | join(",")' "$STYLE")" = "sample,sample_points" ]
  [ "$(jq '[.layers[] | select(.metadata["erap:layer"] == "sample_points")] | length' "$STYLE")" -eq 1 ]
  run "$RUN" --status --json
  [ "$(jq -r '.layers[] | select(.name == "sample") | .state' <<<"$output")" = current ]
}

@test "a layer left out by the map config leaves style.json; a manifest.json goes" {
  cp "${PIPELINE_ROOT}"/tests/layers/*.yaml "$PIPELINE_LAYERS_DIR"
  mkdir -p "$PIPELINE_OUTPUT_DIR"
  printf '{"layers": []}\n' >"${PIPELINE_OUTPUT_DIR}/manifest.json"
  run "$RUN"
  [ "$status" -eq 0 ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/manifest.json" ]

  printf 'layers: [sample_points]\n' >"${BATS_TEST_TMPDIR}/map.yaml"
  PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/map.yaml" run "$RUN" sample_points
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sources | keys | join(",")' "$STYLE")" = "sample_points" ]
  [ "$(jq -r '.metadata["erap:layers"] | keys | join(",")' "$STYLE")" = "sample_points" ]
  # Still built: back in the style, from its layer file, once enabled again.
  [ "$(jq -r '[.layers[].name] | join(",")' "$BUILD")" = "sample,sample_points" ]
  run "$RUN" sample_points
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sources | keys | join(",")' "$STYLE")" = "sample,sample_points" ]
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
  [ ! -e "$BUILD" ]
  [ ! -e "$STYLE" ]
}

@test "no layer in layers/ reads the synthetic fixtures: they are test layers (#17)" {
  run grep -l 'tests/fixtures' "${PIPELINE_ROOT}"/layers/*.yaml
  [ "$status" -eq 1 ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample.yaml" ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample_points.yaml" ]
}
