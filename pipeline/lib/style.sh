#!/usr/bin/env bash
# The `display` block of a layer's manifest.json entry, and style.json, the
# standalone MapLibre style of every built layer, both with jq from the
# layer files (design note 04). Until style.json replaces manifest.json
# (step 3 of the refactor), the web app reads the display block, so it
# keeps the shape it had:
#
#   { "title": ..., "defaultVisible": false, "order": 0,
#     "layers": [MapLibre style layers, as in the layer file],
#     "legend": {...},
#     "popup": {...} or "modal": {...},
#     "themes": [ {"id", "label", "paint", "legend"} ], "defaultTheme": "..." }
#
# `defaultVisible` and `order` are the layer file's `visible` and `order`.
# With colour themes, `legend` is the first theme's, which is the default,
# and the first theme's `paint` (which the layer file leaves out: it is
# what `display.layers` draw) is the paint the other themes change, as
# `display.layers` set it.

# Fonts for symbol layers with text, as the web app's basemaps use.
GLYPHS_URL='https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf'

# display_block CONFIG: print the display block of CONFIG, a layer file as
# JSON (resolve_layers), as compact JSON.
display_block() {
  jq -c '
    .display as $d
    | {title, defaultVisible: (.visible // false), order: (.order // 0)}
      + (if $d.popup then {popup: $d.popup} else {} end)
      + (if $d.modal then {modal: $d.modal} else {} end)
      + {layers: $d.layers}
      + if $d.themes then
          ($d.themes[1:] | map(.paint // {} | to_entries[] | {id: .key, props: (.value | keys)})
            | group_by(.id) | map({key: .[0].id, value: (map(.props[]) | unique)})
            | from_entries) as $changed
          | ($changed | with_entries(.key as $id
              | (([$d.layers[] | select(.id == $id)][0].paint) // {}) as $p
              | .value |= (. as $props
                  | reduce $props[] as $k ({}; if $p[$k] == null then . else .[$k] = $p[$k] end)))
            | with_entries(select(.value != {}))) as $first
          | {legend: $d.themes[0].legend,
             themes: [$d.themes | to_entries[] | .value
               | {id, label, paint: (if .paint then .paint else $first end), legend}],
             defaultTheme: $d.themes[0].id}
        else {legend: $d.legend} end' "$1"
}

# write_style OUT_DIR: write OUT_DIR/style.json, a standalone MapLibre style
# of every enabled layer in OUT_DIR/manifest.json, in draw order (ascending
# `order`, then name): sources relative to OUT_DIR (pmtiles:// for a vector
# layer, cog://...#dem for a raster COG, ADR 0010), the style layers with
# ids `<layer>-<id>` and their visibility, the opening view from the
# manifest's `map`, and no basemap. Atomic, like the manifest.
write_style() {
  local out_dir=$1
  local manifest="${out_dir}/manifest.json" style="${out_dir}/style.json"
  [[ -s $manifest ]] || return 0
  local tmp="${style}.$$.tmp"
  jq --arg glyphs "$GLYPHS_URL" '
    def source: if (.type // "vector") != "raster" then {type: "vector", url: "pmtiles://\(.file)"}
      elif (.file | endswith(".cog.tif")) then {type: "raster-dem", tileSize: 256, url: "cog://\(.file)#dem"}
      else {type: "raster", tileSize: 256, url: "pmtiles://\(.file)"} end;
    [.layers[] | select(.enabled != false and .display != null)]
      | sort_by(.display.order, .name) as $entries
    | ($entries | map(. as $e | .display.layers[]
        | . + {id: "\($e.name)-\(.id)", source: $e.name}
        + (if ($e.type // "vector") == "raster" then {} else {"source-layer": $e.name} end)
        + {layout: ((.layout // {}) + {visibility: (if $e.display.defaultVisible then "visible" else "none" end)})})) as $layers
    | {version: 8, name: "ERAP Map data layers"}
      + (if $map.center then {center: $map.center} else {} end)
      + (if $map.zoom != null then {zoom: $map.zoom} else {} end)
      + (if any($layers[]; .type == "symbol" and .layout["text-field"] != null) then {glyphs: $glyphs} else {} end)
      + {sources: ($entries | map({key: .name, value: source}) | from_entries), layers: $layers}' \
    --argjson map "$(jq -c '.map // {}' "$manifest")" "$manifest" >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $style"
    }
  mv -f "$tmp" "$style"
  log_info "updated $style"
}
