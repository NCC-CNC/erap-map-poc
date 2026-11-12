#!/usr/bin/env bash
# Layer display configs (ADR 0007): pipeline/layers/<layer>.style.json says
# how the web map shows the layer (title, default visibility, draw order,
# pop-up, and either the `symbology` shorthand or raw MapLibre `layers`, plus
# an optional legend). The schema is pipeline/schema/layer-style.schema.json.
#
# The checks run in style/cli.mjs (Node, in the image): the JSON Schema, a
# derivable or explicit legend, `breaks` resolved from the normalised data,
# and the MapLibre style validator on the expanded style layers. The result
# is the `display` block of the layer's manifest.json entry. style.json, the
# combined MapLibre style of every built layer, is written from the manifest.

DISPLAY_TOOL="${PIPELINE_ROOT}/style/cli.mjs"

# _display_tool ARGS...: run the tool, logging each problem it reports. The
# exit status is the tool's.
_display_tool() {
  local output status=0
  output=$(node "$DISPLAY_TOOL" "$@" 2>&1) || status=$?
  if [[ -n $output ]]; then
    local line
    while IFS= read -r line; do
      if ((status == 0)); then log_info "$line"; else log_error "$line"; fi
    done <<<"$output"
  fi
  return "$status"
}

# resolve_display LAYER CONFIG DATA OUT [TYPE]: check LAYER's display config
# CONFIG and write its resolved `display` block to OUT. DATA is the
# normalised GeoJSONSeq, read for `breaks` (`-` for a raster layer). TYPE is
# the LAYER_TYPE, vector (default) or raster. Fails the layer on any
# problem, before any tiles are built, so the previous archive and manifest
# entry are kept.
resolve_display() {
  local layer=$1 config=$2 data=$3 out=$4 type=${5:-vector}
  [[ -r $config ]] || die "display config not found: $config"
  _display_tool resolve "$layer" "$config" "$data" "$out" "$type" \
    || die "invalid display config $config; keeping the previous archive and manifest entry"
  log_info "display config ok"
}

# write_style OUT_DIR: write OUT_DIR/style.json, a standalone MapLibre style
# of every layer in OUT_DIR/manifest.json (pmtiles:// sources relative to
# OUT_DIR, no basemap), checked with the MapLibre style validator.
write_style() {
  local out_dir=$1
  local manifest="${out_dir}/manifest.json"
  [[ -s $manifest ]] || return 0
  _display_tool style "$manifest" "${out_dir}/style.json" \
    || die "cannot write ${out_dir}/style.json"
  log_info "updated ${out_dir}/style.json"
}
