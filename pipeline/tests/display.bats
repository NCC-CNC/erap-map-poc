#!/usr/bin/env bats
# Display config tests (lib/display.sh, style/): <layer>.style.json is
# checked, resolved into the manifest's `display` block, and combined into
# style.json. Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  TOOL="${PIPELINE_ROOT}/style/cli.mjs"
  EXPECTED="${PIPELINE_ROOT}/tests/fixtures/expected_display.json"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# use_layer NAME [AS]: copy a test layer's .env and .style.json from
# tests/layers/.
use_layer() {
  local name=$1 as=${2:-$1}
  cp "${PIPELINE_ROOT}/tests/layers/${name}.env" "${PIPELINE_LAYERS_DIR}/${as}.env"
  cp "${PIPELINE_ROOT}/tests/layers/${name}.style.json" "${PIPELINE_LAYERS_DIR}/${as}.style.json"
}

# write_style NAME JSON: set a layer's display config.
write_style() {
  printf '%s\n' "$2" >"${PIPELINE_LAYERS_DIR}/$1.style.json"
}

# display_of NAME: the layer's manifest display block, compact.
display_of() {
  jq -c --arg name "$1" '.layers[] | select(.name == $name) | .display' "$MANIFEST"
}

# A stepped polygon config on `score` with computed breaks.
breaks_style() {
  cat <<EOF
{
  "title": "Scores",
  "defaultVisible": true,
  "symbology": {
    "geometry": "polygon",
    "color": {
      "type": "stepped",
      "attribute": "score",
      "breaks": { "method": "$1", "classes": 4 },
      "colors": ["#111111", "#222222", "#333333", "#444444"],
      "fallback": { "color": "#999999" }
    },
    "fillOpacity": 0.5,
    "outline": { "color": "#ffffff", "width": 1 }
  }
}
EOF
}

@test "display tool unit tests pass" {
  cd "${PIPELINE_ROOT}/style"
  run node --test
  [ "$status" -eq 0 ]
  [[ $output == *"# fail 0"* || $output == *"fail 0"* ]]
}

@test "the repo's layer configs and the test layers pass the pre-check" {
  run node "$TOOL" check "${PIPELINE_ROOT}"/layers/*.style.json \
    "${PIPELINE_ROOT}"/tests/layers/*.style.json
  [ "$status" -eq 0 ]
  [[ $output == *"forest.style.json: ok"* ]]
  [[ $output == *"sample.style.json: ok"* ]]
  [[ $output == *"sample_points.style.json: ok"* ]]
}

@test "no layer in layers/ reads the synthetic fixtures: they are test layers (#17)" {
  run grep -l 'tests/fixtures' "${PIPELINE_ROOT}"/layers/*.env
  [ "$status" -eq 1 ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample.env" ]
  [ ! -e "${PIPELINE_ROOT}/layers/sample_points.env" ]
}

@test "a valid config is resolved into the manifest's display block" {
  use_layer sample
  use_layer sample_points
  run "$RUN"
  [ "$status" -eq 0 ]
  [[ $output == *"sample: display config ok"* ]]

  run jq -e --slurpfile want "$EXPECTED" \
    '[.layers[] | {key: .name, value: .display}] | from_entries == $want[0]' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "style.json is a standalone style of every layer, in display order" {
  use_layer sample
  use_layer sample_points
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
  run jq -e --slurpfile want "$EXPECTED" \
    '.layers[0].paint == $want[0].sample.layers[0].paint' "$STYLE"
  [ "$status" -eq 0 ]

  # A higher order on sample draws it on top.
  jq '.order = 30' "${PIPELINE_ROOT}/tests/layers/sample.style.json" >"${PIPELINE_LAYERS_DIR}/sample.style.json"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  run jq -r '[.layers[].id] | join(",")' "$STYLE"
  [ "$output" = "sample_points-circle,sample-fill,sample-outline" ]
}

@test "a schema failure fails the layer and keeps the previous archive and entry" {
  use_layer sample
  run "$RUN" sample
  [ "$status" -eq 0 ]
  local archive before_archive before_entry before_style
  archive="${PIPELINE_OUTPUT_DIR}/sample.pmtiles"
  before_archive=$(sha256sum "$archive")
  before_entry=$(jq -c '.layers[0]' "$MANIFEST")
  before_style=$(sha256sum "$STYLE")

  write_style sample '{"title": "", "defaultVisible": "yes", "symbology": {"geometry": "line"}}'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"/title must NOT have fewer than 1 characters"* ]]
  [[ $output == *"/defaultVisible must be boolean"* ]]
  [[ $output == *"/symbology/geometry must be equal to one of the allowed values: polygon, point"* ]]
  [[ $output == *"invalid display config"*"keeping the previous archive and manifest entry"* ]]
  [[ $output != *"building tiles"* ]]

  [ "$(sha256sum "$archive")" = "$before_archive" ]
  [ "$(jq -c '.layers[0]' "$MANIFEST")" = "$before_entry" ]
  [ "$(sha256sum "$STYLE")" = "$before_style" ]
}

@test "invalid JSON and a missing config fail the layer" {
  use_layer sample
  write_style sample '{"title": "Sample",'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"is not valid JSON"* ]]

  rm "${PIPELINE_LAYERS_DIR}/sample.style.json"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"display config not found: ${PIPELINE_LAYERS_DIR}/sample.style.json"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/sample.pmtiles" ]
}

@test "a MapLibre style error fails the layer" {
  use_layer sample
  write_style sample '{"title": "Sample", "defaultVisible": true,
    "layers": [{"id": "fill", "type": "fill", "paint": {"fill-color": "#000000", "fill-opacity": "lots"}}]}'
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"MapLibre style: layers[0].paint.fill-opacity: number expected, string found"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/sample.pmtiles" ]
}

@test "raw style layers are kept as given, with a derived legend" {
  use_layer sample
  write_style sample '{
    "title": "Scores", "defaultVisible": false, "order": 3,
    "layers": [
      {"id": "fill", "type": "fill", "paint": {
        "fill-color": ["step", ["get", "score"], "#eeeeee", 50, "#333333"],
        "fill-opacity": 0.8}},
      {"id": "edge", "type": "line", "minzoom": 4, "paint": {"line-color": "#000000"}},
      {"id": "label", "type": "symbol", "layout": {"text-field": ["get", "name"]}}
    ]}'
  run "$RUN" sample
  [ "$status" -eq 0 ]

  run jq -e '.layers[0].display | .order == 3 and .defaultVisible == false
    and ([.layers[].id] == ["fill", "edge", "label"])
    and .layers[1].minzoom == 4
    and .legend == {kind: "ramp", shape: "square", border: "#000000", opacity: 0.8,
      items: [{color: "#eeeeee", label: "Below 50"}, {color: "#333333", label: "50 or more"}]}
    and (has("popup") | not)' "$MANIFEST"
  [ "$status" -eq 0 ]

  # Prefixed ids, hidden by default, and glyphs for the text.
  run jq -e '([.layers[].id] == ["sample-fill", "sample-edge", "sample-label"])
    and all(.layers[]; .layout.visibility == "none")
    and (.glyphs | startswith("https://"))' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "raw layers without a derivable legend need an explicit one" {
  use_layer sample
  local layers='[{"id": "fill", "type": "fill", "paint": {"fill-color":
    ["interpolate", ["linear"], ["get", "score"], 0, "#ffffff", 100, "#000000"]}}]'
  write_style sample "{\"title\": \"Scores\", \"defaultVisible\": true, \"layers\": ${layers}}"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"cannot derive a legend"*"add an explicit \"legend\""* ]]

  write_style sample "{\"title\": \"Scores\", \"defaultVisible\": true, \"layers\": ${layers},
    \"legend\": {\"kind\": \"ramp\", \"items\": [{\"color\": \"#ffffff\", \"label\": \"0\"},
      {\"color\": \"#000000\", \"label\": \"100\"}]}}"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  run jq -c '.layers[0].display.legend | [.kind, .shape, [.items[].label]]' "$MANIFEST"
  [ "$output" = '["ramp","square",["0","100"]]' ]
}

@test "quantile breaks are resolved from the data" {
  # Scores in the fixture, sorted: 3 10 13 20 30 37 40 47 50 57 67 74 77 84 94.
  # Quantile, 4 classes: ranks floor(i * 15 / 4) = 0, 3, 7, 11.
  use_layer sample
  write_style sample "$(breaks_style quantile)"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  run jq -c '.layers[0].display | [.layers[0].paint["fill-color"][2], [.legend.items[].label]]' "$MANIFEST"
  [ "$output" = '[["step",["get","score"],"#111111",20,"#222222",47,"#333333",74,"#444444"],["3 to 20","20 to 47","47 to 74","74 to 94"]]' ]
}

@test "equal interval breaks are resolved from the data" {
  # 3 to 94 in four equal classes of 22.75.
  use_layer sample
  write_style sample "$(breaks_style equal)"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  run jq -c '.layers[0].display | [.layers[0].paint["fill-color"][2], [.legend.items[].label]]' "$MANIFEST"
  [ "$output" = '[["step",["get","score"],"#111111",25.75,"#222222",48.5,"#333333",71.25,"#444444"],["3 to 25.75","25.75 to 48.5","48.5 to 71.25","71.25 to 94"]]' ]
}

@test "breaks on an attribute with no numbers fail the layer" {
  use_layer sample
  write_style sample "$(breaks_style quantile | sed 's/"score"/"name"/')"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"breaks: no numeric values in the data"* ]]
}

@test "colour themes and a click modal are resolved into the display block (ADR 0011)" {
  use_layer sample
  cp "${PIPELINE_ROOT}/tests/fixtures/sample_modal.style.json" "${PIPELINE_LAYERS_DIR}/sample.style.json"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  local want="${PIPELINE_ROOT}/tests/fixtures/expected_modal_display.json"
  run jq -e --slurpfile want "$want" '.layers[0].display == $want[0]' "$MANIFEST"
  [ "$status" -eq 0 ]

  # style.json draws the default theme.
  run jq -e --slurpfile want "$want" '.layers[0].paint == $want[0].layers[0].paint' "$STYLE"
  [ "$status" -eq 0 ]

  # A pop-up and a modal together fail the layer.
  jq '.popup = {title: {attribute: "name"}, stats: []}' \
    "${PIPELINE_ROOT}/tests/fixtures/sample_modal.style.json" >"${PIPELINE_LAYERS_DIR}/sample.style.json"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *"a layer has a \"popup\" or a \"modal\" for click details, not both"* ]]
}

@test "the ecoregions example config passes the pre-check" {
  run node "$TOOL" check "${PIPELINE_ROOT}/tests/fixtures/ecoregions.example.style.json"
  [ "$status" -eq 0 ]
  [[ $output == *"ecoregions.example.style.json: ok"* ]]
}

@test "the pre-check reports a bad config without building" {
  write_style bad '{"title": "Bad", "defaultVisible": true}'
  run node "$TOOL" check "${PIPELINE_LAYERS_DIR}/bad.style.json"
  [ "$status" -eq 1 ]
  [[ $output == *"bad.style.json: (top level) must have required property 'symbology'"* ]]
}
