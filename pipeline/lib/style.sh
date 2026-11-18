#!/usr/bin/env bash
# style.json: the MapLibre style (version 8) of every built layer, the one
# file the web app reads (design note 04). It holds no basemap: the app
# loads it over one.
#
#   { "version": 8, "name": "ERAP Map data layers",
#     "metadata": {
#       "erap:basemap": "light",                 (map config; else absent)
#       "erap:layers": { "<layer>": { "title": ..., "type": "vector",
#           "order": 10, "visible": true, "legend": {...},
#           "themes": [...], "popup": {...}, "modal": {...} } } },
#     "center": [lon, lat], "zoom": 3,           (map config's view)
#     "glyphs": "...",                           (only for text labels)
#     "sources": { "<layer>": { "type": "vector",
#                               "url": "pmtiles://<layer>.pmtiles" } },
#     "layers": [ { "id": "<layer>-<id>", "source": "<layer>",
#                   "source-layer": "<layer>", "layout": {"visibility": ...},
#                   "metadata": {"erap:layer": "<layer>"}, ... } ] }
#
# `erap:layers` holds what MapLibre does not know about, from the layer
# file: `title`, `order` (default 0), `visible` (default false), the
# build's `type` (vector or raster) and display's `legend`, `themes` (as in
# the layer file: the first theme is what the style layers draw), `popup`
# and `modal`, those set. The style layers are the layer file's
# `display.layers` with a prefixed id, the source, the source layer (vector
# only), `visibility` from `visible` and `erap:layer` naming the layer.
# Sources are relative to the output dir: pmtiles:// for a vector layer,
# cog://...#dem for a raster COG (ADR 0010; a raster built as PNG tiles
# before that is a raster pmtiles:// source). Layers draw in ascending
# `order`, then by name.

# Fonts for symbol layers with text, as the web app's basemaps use.
GLYPHS_URL='https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf'

# write_style OUT_DIR [LAYER...]: write OUT_DIR/style.json from
# OUT_DIR/build.json and the layer set (LAYERS_JSON): every built layer the
# map config enables. The named layers (built or restyled in this run), and
# any not in style.json yet, take their display from their layer file; the
# others keep their part of the style.json there was, so a display change
# reaches the map only through a build or --style-only (and --status shows
# it as restyle until then). A layer whose layer file has problems keeps
# its old part, or is left out with a warning if it has none. The view and
# basemap come from the map config. Each layer taken from its layer file
# has its display hash recorded in build.json (build_set_display). Atomic,
# like the archives. Nothing to do without a build.json. A manifest.json
# from before style.json and build.json is removed.
write_style() {
  local out_dir=$1
  shift
  local style="${out_dir}/style.json"
  if [[ -e "${out_dir}/manifest.json" ]]; then
    rm -f -- "${out_dir}/manifest.json"
    log_info "removed ${out_dir}/manifest.json (replaced by build.json and style.json)"
  fi
  [[ -s "${out_dir}/build.json" ]] || return 0

  local entries old='{}' configs='{}' shas='{}' enabled map name config wanted n
  local -A named=()
  for n in "$@"; do named[$n]=1; done
  entries=$(build_entries "$out_dir")
  if [[ -s $style ]] && jq -e '.version == 8' "$style" >/dev/null 2>&1; then
    old=$(jq -c '.' "$style")
  fi
  enabled=$(jq -c '[.layers[] | select(.enabled) | .name]' "$LAYERS_JSON") \
    || die "cannot read $LAYERS_JSON"
  map=$(jq -c '.map // {}' "$LAYERS_JSON") || die "cannot read $LAYERS_JSON"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    wanted=${named[$name]:-0}
    if ! jq -e --arg n "$name" '.metadata["erap:layers"][$n] != null' <<<"$old" >/dev/null; then
      wanted=1
    fi
    ((wanted)) || continue
    config=$(layer_get "$name" config)
    if [[ -z $config ]]; then
      log_warn "${name}.yaml has problems: its style is kept as it was"
      continue
    fi
    configs=$(jq -c --arg n "$name" --slurpfile c "$config" '.[$n] = $c[0]' <<<"$configs") \
      || die "cannot read $config"
    shas=$(jq -c --arg n "$name" --arg s "$(layer_get "$name" display_sha256)" \
      '.[$n] = $s' <<<"$shas") || die "cannot read the display hash of $name"
  done < <(jq -r --argjson enabled "$enabled" \
    '.[] | .name | select(. as $n | $enabled | index($n))' <<<"$entries")

  local tmp="${style}.$$.tmp"
  jq -n --argjson entries "$entries" --argjson old "$old" --argjson configs "$configs" \
    --argjson enabled "$enabled" --argjson map "$map" --arg glyphs "$GLYPHS_URL" '
    def source: if (.type // "vector") != "raster" then {type: "vector", url: "pmtiles://\(.file)"}
      elif (.file | endswith(".cog.tif")) then {type: "raster-dem", tileSize: 256, url: "cog://\(.file)#dem"}
      else {type: "raster", tileSize: 256, url: "pmtiles://\(.file)"} end;
    # fresh(config): a built layer (the input) from its layer file.
    def fresh($c): . as $e | ($e.type // "vector") as $type
      | {name: $e.name,
         meta: ({title: $c.title, type: $type, order: ($c.order // 0), visible: ($c.visible // false)}
           + ($c.display | with_entries(select(.key | IN("legend", "themes", "popup", "modal"))))),
         source: source,
         layers: [$c.display.layers[]
           | . + {id: "\($e.name)-\(.id)", source: $e.name}
           + (if $type == "raster" then {} else {"source-layer": $e.name} end)
           + {layout: ((.layout // {}) + {visibility: (if $c.visible then "visible" else "none" end)}),
              metadata: ((.metadata // {}) + {"erap:layer": $e.name})}]};
    # kept: a built layer (the input) as the old style.json had it, or null.
    def kept: .name as $n
      | if $old.metadata["erap:layers"][$n] == null then null
        else {name: $n, meta: $old.metadata["erap:layers"][$n], source: $old.sources[$n],
              layers: [$old.layers[] | select(.metadata["erap:layer"] == $n)]} end;
    [$entries[] | select(.name as $n | $enabled | index($n))
      | if $configs[.name] then fresh($configs[.name]) else kept end
      | select(. != null)]
    | sort_by(.meta.order, .name) as $parts
    | ($parts | map(.layers[])) as $layers
    | {version: 8, name: "ERAP Map data layers",
       metadata: ({"erap:layers": ($parts | map({key: .name, value: .meta}) | from_entries)}
         + (if $map.basemap then {"erap:basemap": $map.basemap} else {} end))}
      + (if $map.center then {center: $map.center} else {} end)
      + (if $map.zoom != null then {zoom: $map.zoom} else {} end)
      + (if any($layers[]; .type == "symbol" and .layout["text-field"] != null) then {glyphs: $glyphs} else {} end)
      + {sources: ($parts | map({key: .name, value: .source}) | from_entries), layers: $layers}' \
    >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $style"
    }
  mv -f "$tmp" "$style"
  log_info "updated $style"
  build_set_display "$out_dir" "$shas"
}
