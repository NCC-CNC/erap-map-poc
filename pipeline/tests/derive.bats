#!/usr/bin/env bats
# Tests for calculated fields and action recommendation rules (ADR 0011;
# lib/derive.sh, style/derive.mjs and their use in bin/run.sh, --status,
# bin/inspect.sh and the map config), on a copy of the sample layer. The
# sample scores are 37, 74, 10, 47, 84, 20, 57, 94, 30, 67, 3, 40, 77, 13 and
# 50 (ids 1 to 15): 4 under 30, 8 under 50. Run in the test image with the
# other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  INSPECT="${PIPELINE_ROOT}/bin/inspect.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  export PIPELINE_MAP_CONFIG="${BATS_TEST_TMPDIR}/repo/map.config.json"
  CONFIG=$PIPELINE_MAP_CONFIG
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  ENV="${PIPELINE_LAYERS_DIR}/demo.env"
  RULES="${PIPELINE_LAYERS_DIR}/demo.rules.json"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR" "${BATS_TEST_TMPDIR}/repo"
  cp "${PIPELINE_ROOT}/tests/fixtures/sample.geojson" "${PIPELINE_INPUT_DIR}/"
  sed -e 's|^LAYER_INPUT=.*|LAYER_INPUT=sample.geojson|' \
    -e 's|^LAYER_MAX_ZOOM=.*|LAYER_MAX_ZOOM=4|' \
    "${PIPELINE_ROOT}/tests/layers/sample.env" >"$ENV"
  cp "${PIPELINE_ROOT}/tests/layers/sample.style.json" "${PIPELINE_LAYERS_DIR}/demo.style.json"
  cat >"$RULES" <<'EOF'
{
  "types": [
    { "id": "review", "label": "Review" },
    { "id": "other", "label": "Other" }
  ],
  "actions": [
    { "id": "low_score", "type": "review", "title": "Review - low score",
      "condition": "score < 30", "reason": "recommended because the score is under 30" },
    { "id": "mid_score", "type": "review", "title": "Review - middling score",
      "condition": "score_gap > 50", "reason": "recommended because the score is under 50" }
  ]
}
EOF
}

# with_rules ENTRY...: add LAYER_CALCULATED entries (name=expression) and
# LAYER_RULES=demo to demo.env.
with_rules() {
  {
    echo 'LAYER_CALCULATED=('
    printf '  %q\n' "$@"
    echo ')'
    echo 'LAYER_RULES=demo'
  } >>"$ENV"
}

# entry JQ: a jq filter on demo's manifest entry.
entry() {
  jq -c "first(.layers[] | select(.name == \"demo\")) | $1" "$MANIFEST"
}

# feature ID: demo's feature ID at z4 (every attribute), as JSON.
feature() {
  local tile
  for tile in $(tippecanoe-decode --stats "${PIPELINE_OUTPUT_DIR}/demo.pmtiles" \
    | jq -r '.[] | select(.zoom == 4) | "\(.x)/\(.y)"'); do
    tippecanoe-decode "${PIPELINE_OUTPUT_DIR}/demo.pmtiles" 4 "${tile%/*}" "${tile#*/}"
  done | jq -c -s --argjson id "$1" \
    'first(.[].features[].features[] | select(.id == $id)) | .properties'
}

state_of() {
  "$RUN" --status --json 2>/dev/null | jq -r '.layers[] | select(.name == "demo") | .state'
}

notes_of() {
  "$RUN" --status --json 2>/dev/null | jq -r '.layers[] | select(.name == "demo") | .notes | join(";")'
}

@test "calculated fields and rules become tile attributes, with counts in the build report" {
  with_rules 'score_gap=100 - score' 'score_share=score / 200'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  [[ $output == *"derived attributes ok: score_gap, score_share, action_low_score, action_low_score_reason, action_mid_score, action_mid_score_reason, actions_review_count, actions_other_count"* ]]
  [[ $output == *"calculated: score_gap, score_share; rules demo.rules.json: review 8, other 0 feature(s) with an action"* ]]

  # id 3, score 10: both actions; division is decimal.
  run feature 3
  [ "$(jq -c '[.score_gap, .score_share, .action_low_score, .action_mid_score, .actions_review_count, .actions_other_count]' <<<"$output")" = '[90,0.05,1,1,2,0]' ]
  [ "$(jq -r '.action_low_score_reason' <<<"$output")" = "Review - low score: recommended because the score is under 30" ]
  # id 1, score 37: the second action only; no reason attribute for the first.
  run feature 1
  [ "$(jq -c '[.action_low_score, .action_mid_score, .actions_review_count, has("action_low_score_reason")]' <<<"$output")" = '[0,1,1,false]' ]
  # id 2, score 74: none.
  run feature 2
  [ "$(jq -c '[.action_low_score, .action_mid_score, .actions_review_count]' <<<"$output")" = '[0,0,0]' ]

  run entry '[.calculated_fields[] | [.name, .expression, .non_null, .min, .max]]'
  [ "$output" = '[["score_gap","100 - score",15,6,97],["score_share","score / 200",15,0.015,0.47]]' ]
  run entry '[.rules.actions[] | [.id, .recommended]], [.rules.types[] | [.id, .features]]'
  [ "${lines[0]}" = '[["low_score",4],["mid_score",8]]' ]
  [ "${lines[1]}" = '[["review",8],["other",0]]' ]
  run jq -e --arg sha "$(sha256sum "$RULES" | cut -d ' ' -f 1)" \
    'first(.layers[] | select(.name == "demo")) | .provenance.rules_sha256 == $sha' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "a layer without calculated fields or rules is built as before" {
  run "$RUN" demo
  [ "$status" -eq 0 ]
  [[ $output != *"derived attributes"* ]]
  run entry '[has("calculated_fields"), has("rules"), .provenance.rules_sha256]'
  [ "$output" = '[false,false,null]' ]
}

@test "a bad expression fails before the source is read and keeps the previous build" {
  run "$RUN" demo
  [ "$status" -eq 0 ]
  local built
  built=$(entry '.built_at')
  echo 'LAYER_CALCULATED=("gap=100 - scor" "half=max(score)" "ok=gap + 1")' >>"$ENV"
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"calculated field gap: uses the attribute scor, which the layer does not have"* ]]
  [[ $output == *"calculated field half: calls max with 1 argument(s) at character 1; it takes 2 or more"* ]]
  [[ $output == *"calculated field ok: uses gap, which has a problem"* ]]
  [[ $output != *"normalising"* ]]
  [ "$(entry '.built_at')" = "$built" ]
}

@test "expressions cannot run statements, subqueries or other functions" {
  local expr
  for expr in "score; DROP TABLE demo" "score -- x" "(SELECT 1)" "load_extension('x')" \
    "BlobToFile(name, '/tmp/x')" "score IN (SELECT id FROM demo)"; do
    printf '%s\n' "LAYER_CALCULATED=($(printf '%q' "bad=${expr}"))" >>"$ENV"
    run "$RUN" demo
    [ "$status" -eq 1 ]
    [[ $output == *"calculated field bad: "* ]]
    [ ! -e /tmp/x ]
    sed -i '$d' "$ENV"
  done
}

@test "a bad entry, rules table or missing table is reported clearly" {
  echo 'LAYER_CALCULATED=("Bad=1")' >>"$ENV"
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_CALCULATED entry 'Bad=1' must be name=expression"* ]]

  sed -i '$d' "$ENV"
  echo 'LAYER_RULES=nope' >>"$ENV"
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"rules table not found: ${PIPELINE_LAYERS_DIR}/nope.rules.json"* ]]
  run state_of
  [ "$output" = invalid ]

  sed -i '$d' "$ENV"
  echo 'LAYER_RULES=demo' >>"$ENV"
  jq '.actions[0].type = "nope" | .actions[1].condition = "score <" | .actions[1].colour = "red"' \
    "$RULES" >"${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"demo.rules.json: /actions/1 must NOT have additional properties: colour"* ]]
  run node "${PIPELINE_ROOT}/style/cli.mjs" check "$RULES"
  [ "$status" -eq 1 ]
  jq 'del(.actions[1].colour)' "$RULES" >"${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
  run "$RUN" demo
  [ "$status" -eq 1 ]
  [[ $output == *"actions[0] (low_score): type nope is not one of types (review, other)"* ]]
  [[ $output == *"actions[1] (mid_score): condition expected a value"* ]]
}

@test "--status: a changed rules table or calculated field makes the build stale" {
  with_rules 'score_gap=100 - score'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run state_of
  [ "$output" = current ]
  run "$RUN" --status
  [[ $output == *"  calculated: score_gap"* ]]
  [[ $output == *"  rules demo.rules.json, 2 action(s); features with an action: review 8, other 0"* ]]
  run "$RUN" --status --json
  [ "$(jq -c '.layers[0] | [.calculated_fields, .rules.actions, .rules.types]' <<<"$output")" = '[["score_gap"],2,{"review":8,"other":0}]' ]

  # The table's content, not its time: the hash.
  local mtime
  mtime=$(stat -c %Y "$RULES")
  jq '.actions[0].condition = "score < 20"' "$RULES" >"${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
  touch -d "@${mtime}" "$RULES"
  run state_of
  [ "$output" = stale ]
  run notes_of
  [[ $output == *"rules table changed since the build (${RULES})"* ]]
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run state_of
  [ "$output" = current ]

  # A calculated field in the .env: the .env changed.
  sleep 1
  echo 'LAYER_CALCULATED+=("more=score * 2")' >>"$ENV"
  run state_of
  [ "$output" = stale ]
}

@test "the map config adds, changes and removes calculated fields and swaps the rules table" {
  with_rules 'score_gap=100 - score' 'score_share=score / 200'
  run "$RUN" demo
  [ "$status" -eq 0 ]

  mkdir -p "${BATS_TEST_TMPDIR}/repo/mine"
  jq '.actions = [.actions[0] | .condition = "score_double > 150"]' "$RULES" \
    >"${BATS_TEST_TMPDIR}/repo/mine/local.rules.json"
  printf '%s\n' '{"overrides": {"demo": {"calculated": {"score_gap": "50 - score", "score_share": null, "score_double": "score * 2"}, "rules": "mine/local.rules.json"}}}' >"$CONFIG"
  run state_of
  [ "$output" = stale ]
  run notes_of
  [[ $output == *"settings changed since the build"* ]]

  run "$RUN" demo
  [ "$status" -eq 0 ]
  run entry '[.calculated_fields[] | .name], .provenance.overrides.calculated.score_gap, .rules.file, [.rules.actions[] | .recommended]'
  [ "${lines[0]}" = '["score_gap","score_double"]' ]
  [ "${lines[1]}" = '"50 - score"' ]
  [ "${lines[2]}" = "\"${BATS_TEST_TMPDIR}/repo/mine/local.rules.json\"" ]
  # score_double > 150: scores 77, 84 and 94.
  [ "${lines[3]}" = '[3]' ]
  run feature 3
  [ "$(jq -c '[.score_gap, has("score_share"), .score_double, .action_low_score]' <<<"$output")" = '[40,false,20,0]' ]

  # A missing table is a map config problem, found before anything is built.
  printf '%s\n' '{"overrides": {"demo": {"rules": "mine/nope.rules.json"}}}' >"$CONFIG"
  run "$RUN" demo
  [ "$status" -eq 2 ]
  [[ $output == *"overrides.demo.rules: file not found: mine/nope.rules.json"* ]]

  # null: no rules table.
  printf '%s\n' '{"overrides": {"demo": {"rules": null}}}' >"$CONFIG"
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run entry '[(.calculated_fields | length), .rules, .provenance.rules_sha256]'
  [ "$output" = '[2,null,null]' ]
}

@test "generalised zooms keep the derived attributes" {
  with_rules 'score_gap=100 - score'
  printf '%s\n' 'LAYER_GENERALISE_MAX_ZOOM=1' 'LAYER_GENERALISE_SIMPLIFY_PX=0' >>"$ENV"
  run "$RUN" demo
  [ "$status" -eq 0 ]
  run bash -c "tippecanoe-decode '${PIPELINE_OUTPUT_DIR}/demo.pmtiles' 0 0 0 \
    | jq -c '[.features[].features[] | select(.id == 3) | .properties
              | [.score_gap, .action_low_score, .actions_review_count]] | first'"
  [ "$output" = '[90,1,2]' ]
}

@test "--style-only reads breaks on a calculated field as built" {
  with_rules 'score_gap=100 - score'
  run "$RUN" demo
  [ "$status" -eq 0 ]
  jq '.symbology.color = {type: "stepped", attribute: "score_gap",
        breaks: {method: "equal", classes: 2}, colors: ["#eeeeee", "#333333"],
        fallback: {color: "#999999"}}' \
    "${PIPELINE_LAYERS_DIR}/demo.style.json" >"${BATS_TEST_TMPDIR}/s.json"
  mv "${BATS_TEST_TMPDIR}/s.json" "${PIPELINE_LAYERS_DIR}/demo.style.json"
  run "$RUN" --style-only demo
  [ "$status" -eq 0 ]
  [[ $output == *"reading the source data for breaks (no tiling)"* ]]
  # score_gap runs from 6 to 97: equal breaks at 6 and 51.5.
  run jq -c '.layers[0].display.layers[0].paint["fill-color"][2]' "$MANIFEST"
  [ "$output" = '["step",["get","score_gap"],"#eeeeee",51.5,"#333333"]' ]
}

@test "colour themes and a click modal read calculated fields and rule attributes (ADR 0012)" {
  with_rules 'score_gap=100 - score'
  # Themes on the action count (stepped, with an explicit legend) and on a
  # calculated field (a gradient over its range in the data), and a modal
  # listing the recommended actions' reasons.
  jq 'del(.popup) | .symbology = (.symbology | del(.color)) + {
        themes: [
          {id: "actions", label: "Review actions",
           color: {type: "stepped", attribute: "actions_review_count",
             stops: [{from: 0, color: "#eff3ff"}, {from: 1, color: "#6baed6"}, {from: 2, color: "#08519c"}],
             max: 2, fallback: {color: "#999999", label: "No data"}},
           legend: {items: [{color: "#eff3ff", label: "None"}, {color: "#6baed6", label: "1"},
             {color: "#08519c", label: "2 or more"}]}},
          {id: "gap", label: "Score gap",
           color: {type: "interpolated", attribute: "score_gap",
             colors: ["#eff3ff", "#08519c"], fallback: {color: "#999999"}}}],
        defaultTheme: "actions"}
      | .modal = {title: "{name}", sections: [
          {heading: "Gap", blocks: [{type: "attributes", items: [
            {label: "Score gap", value: {attribute: "score_gap"}, format: "count"}]}]},
          {heading: "Recommended actions", blocks: [{type: "list", items: [
            {text: "{action_low_score_reason}", when: "action_low_score"},
            {text: "{action_mid_score_reason}", when: "action_mid_score"}],
            empty: "No actions recommended."}]}]}' \
    "${PIPELINE_LAYERS_DIR}/demo.style.json" >"${BATS_TEST_TMPDIR}/s.json"
  mv "${BATS_TEST_TMPDIR}/s.json" "${PIPELINE_LAYERS_DIR}/demo.style.json"
  run "$RUN" demo
  [ "$status" -eq 0 ]

  # The default theme colours by the count; the gradient spans score_gap's
  # range in the data, 6 to 97.
  run entry '.display.layers[0].paint["fill-color"][2]'
  [ "$output" = '["step",["get","actions_review_count"],"#eff3ff",1,"#6baed6",2,"#08519c"]' ]
  run entry '[.display.legend.items[].label]'
  [ "$output" = '["None","1","2 or more"]' ]
  run entry '.display.themes[1].paint.fill["fill-color"][2]'
  [ "$output" = '["interpolate",["linear"],["get","score_gap"],6,"#eff3ff",97,"#08519c"]' ]
  run entry '.display.modal.sections[1].blocks[0].items[0].when'
  [ "$output" = '"action_low_score"' ]
  # The attributes the modal names are in the tiles: id 3 has both reasons.
  run feature 3
  [ "$(jq -c '[.action_low_score, .action_mid_score, .actions_review_count, .score_gap]' <<<"$output")" = '[1,1,2,90]' ]
  [ "$(jq -r '.action_mid_score_reason' <<<"$output")" = "Review - middling score: recommended because the score is under 50" ]

  # --style-only reads the derived data for the gradient as built.
  run "$RUN" --style-only demo
  [ "$status" -eq 0 ]
  [[ $output == *"reading the source data for breaks (no tiling)"* ]]
  run entry '.display.themes[1].paint.fill["fill-color"][2][3]'
  [ "$output" = '6' ]
}

@test "inspect.sh --config shows the calculated fields and rule counts before a build" {
  with_rules 'score_gap=100 - score'
  local json
  json=$("$INSPECT" --json --no-checks --config demo 2>/dev/null)
  run jq -c '.config | [.layer, .input, [.calculated_fields[].name], [.rules.actions[] | [.id, .recommended]]]' <<<"$json"
  [ "$output" = '["demo","sample.geojson",["score_gap"],[["low_score",4],["mid_score",8]]]' ]
  run jq -c '.fields[] | select(.name == "score_gap") | [.calculated, .min, .max]' <<<"$json"
  [ "$output" = '["100 - score",6,97]' ]
  run jq -r '[.fields[].name] | join(",")' <<<"$json"
  [[ $output == *"name,area_ha,score,"*"action_low_score_reason"* ]]
  [[ $output != *"notes"* ]]

  run "$INSPECT" --no-checks --config demo
  [ "$status" -eq 0 ]
  [[ $output == *"Config:     layer demo"* ]]
  [[ $output == *"    calculated: 100 - score"* ]]
  [[ $output == *"  low_score (review): score < 30"* ]]
  [[ $output == *"    recommended for 4 feature(s): action_low_score, action_low_score_reason"* ]]

  run "$INSPECT" --config demo sample.geojson
  [ "$status" -eq 2 ]
  run "$INSPECT" --config nope
  [ "$status" -eq 1 ]
  [[ $output == *"no layer named nope"* ]]
}
