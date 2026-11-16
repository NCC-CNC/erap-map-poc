#!/usr/bin/env bash
# The local map config (ADR 0009): a git-ignored JSON file, map.config.json
# at the repo root by default (compose mounts the repo at /repo and sets
# PIPELINE_MAP_CONFIG from MAP_CONFIG in .env), on top of the committed
# layer configs. Schema: pipeline/schema/map-config.schema.json.
#
# resolve_layers runs the display tool's `layers` command, which checks the
# config and writes the effective layer set to layers.json (shape in
# style/cli.mjs): every layer from PIPELINE_LAYERS_DIR, the config's
# `layerDirs` and `localLayers`, whether it is enabled, the settings and
# display config files a build reads (the committed ones, or copies with
# the config's overrides applied) and the overrides. Without a config it is
# the committed layers, all enabled, as they are. Everything else reads the
# layer set through the functions here.
#
# Precedence, lowest first: the layer's <layer>.env and <layer>.style.json
# (committed, or local-only), then the config's overrides: `input` and
# `env` lines added after the .env (so they win), the `style` merge patch,
# then `title`, `order` and `defaultVisible`.

# Set by resolve_layers: the layers.json of this run.
LAYERS_JSON=""

# resolve_layers OUT_DIR: resolve the layer set into OUT_DIR and set
# LAYERS_JSON. A missing PIPELINE_MAP_CONFIG file means no map config.
# Returns 2 if the map config (or a layer dir it names) has a problem.
resolve_layers() {
  local out=$1 config=-
  if [[ -n ${PIPELINE_MAP_CONFIG:-} ]]; then
    if [[ -f $PIPELINE_MAP_CONFIG ]]; then
      config=$PIPELINE_MAP_CONFIG
      log_info "map config: $config"
    elif [[ -e $PIPELINE_MAP_CONFIG ]]; then
      log_error "map config is not a file: $PIPELINE_MAP_CONFIG"
      return 2
    fi
  fi
  if ! _display_tool layers "$config" "$PIPELINE_LAYERS_DIR" "$out"; then
    log_error "the map config has problems (above); nothing was changed"
    return 2
  fi
  LAYERS_JSON="${out}/layers.json"
}

# layer_names [enabled]: every layer name in the layer set, or only the
# enabled ones, one per line, in name order.
layer_names() {
  jq -r --arg only "${1:-}" '.layers[] | select($only != "enabled" or .enabled) | .name' \
    "$LAYERS_JSON"
}

# layer_get NAME FIELD: a field of NAME's layers.json entry (see
# style/cli.mjs); nothing for null or an unknown layer.
layer_get() {
  jq -r --arg n "$1" --arg f "$2" \
    'first(.layers[] | select(.name == $n)) | .[$f] // empty | tostring' "$LAYERS_JSON"
}

# layer_known NAME: whether NAME is in the layer set.
layer_known() {
  jq -e --arg n "$1" 'any(.layers[]; .name == $n)' "$LAYERS_JSON" >/dev/null
}

# layer_enabled NAME: whether NAME is in the layer set and enabled.
layer_enabled() {
  jq -e --arg n "$1" 'any(.layers[]; .name == $n and .enabled)' "$LAYERS_JSON" >/dev/null
}

# layer_where NAME: where NAME is configured, for messages.
layer_where() {
  local origin
  origin=$(layer_get "$1" origin)
  case $origin in
    config) printf 'localLayers in the map config' ;;
    *) layer_get "$1" envSource ;;
  esac
}

# layer_provenance NAME INPUT: NAME's `provenance` for its manifest entry, as
# compact JSON: where the layer comes from (`origin`), its source data
# (INPUT, the resolved LAYER_INPUT: path relative to the input dir, total
# size of its files, newest modification time; null fields for a /vsi
# path), the map config's overrides as applied (null for none) and the
# hashes of the settings and display config it was built from, which
# --status compares (lib/status.sh).
layer_provenance() {
  local name=$1 input=$2 bytes="" mtime=""
  if mtime=$(source_mtime "$input") && [[ -n $mtime ]]; then
    bytes=$(source_bytes "$input")
  fi
  jq -c --arg n "$name" --arg input "${input#"${PIPELINE_INPUT_DIR}"/}" \
    --arg bytes "$bytes" --arg mtime "$mtime" \
    'first(.layers[] | select(.name == $n))
     | {origin,
        source: {path: $input,
                 bytes: (if $bytes == "" then null else ($bytes | tonumber) end),
                 modified_at: (if $mtime == "" then null else ($mtime | tonumber | todate) end)},
        overrides,
        env_sha256: .envSha256,
        style_sha256: .styleSha256}' "$LAYERS_JSON"
}

# layer_display_provenance NAME: the display part of NAME's provenance, for
# a --style-only update: the display config's hash and the overrides.
layer_display_provenance() {
  jq -c --arg n "$1" 'first(.layers[] | select(.name == $n))
    | {overrides, style_sha256: .styleSha256}' "$LAYERS_JSON"
}

# required_input NAME: the source the map config's `requiredInputs` says
# NAME must be built from; nothing (and return 1) for none.
required_input() {
  jq -er --arg n "$1" '.requiredInputs[$n] // empty' "$LAYERS_JSON" 2>/dev/null
}

# check_required_inputs: the map config's `requiredInputs` guard, run before
# a build: every layer it names must be enabled and its LAYER_INPUT,
# resolved (with the config's overrides) and relative to the input dir,
# must be exactly the source given. For a copy that must not use some
# sources, such as map.config.pages.json (ADR 0014). Uses _config_input
# (lib/status.sh). Returns 2, after naming every problem, if one fails.
check_required_inputs() {
  local name want cfg input bad=0
  while IFS=$'\t' read -r name want; do
    if ! layer_enabled "$name"; then
      log_error "requiredInputs: layer '$name' must be enabled in the map config"
      bad=1
      continue
    fi
    cfg=$(_config_input "$(layer_get "$name" env)")
    if [[ ${cfg%%$'\t'*} != ok ]]; then
      log_error "requiredInputs: layer '$name': ${cfg#*$'\t'}"
      bad=1
      continue
    fi
    input=${cfg##*$'\t'}
    input=${input#"${PIPELINE_INPUT_DIR}"/}
    if [[ $input != "$want" ]]; then
      log_error "requiredInputs: layer '$name' must be built from ${want}, not ${input}"
      bad=1
    fi
  done < <(jq -r '(.requiredInputs // {}) | to_entries[] | [.key, .value] | @tsv' "$LAYERS_JSON")
  ((bad == 0)) || return 2
}
