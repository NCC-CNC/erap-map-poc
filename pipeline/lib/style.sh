#!/usr/bin/env bash
# style.json: the MapLibre style (version 8) of every built layer, the one
# file the web app reads (design note 04). It holds no basemap: the app
# loads it over one.
#
#   { "version": 8, "name": "ERAP Map data layers",
#     "metadata": {
#       "erap:basemap": "light",                 (map config; else absent)
#       "erap:view": {"minzoom": 2, "maxzoom": 14,
#                     "bounds": [w, s, e, n]},   (map config's view, those set)
#       "erap:title": "ERAP Map",                (map config; else absent)
#       "erap:locale": "en-CA",                  (map config; else absent)
#       "erap:layers": { "<layer>": { "title": ..., "type": "vector",
#           "order": 10, "visible": true, "legend": {...},
#           "themes": [...], "popup": {...} } } },
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
# the layer file: the first theme is what the style layers draw) and
# `popup`, those set. The style layers are the layer file's
# `display.layers` with a prefixed id, the source, the source layer (vector
# only), `visibility` from `visible` and `erap:layer` naming the layer.
# Sources are relative to the output dir: pmtiles:// for a vector layer,
# cog://...#dem for a raster COG (ADR 0010). Layers draw in ascending
# `order`, then by name.

# Fonts for symbol layers with text, as the web app's basemaps use.
GLYPHS_URL='https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf'

# write_style OUT_DIR: write OUT_DIR/style.json from OUT_DIR/build.json
# and the layer set (LAYERS_JSON): every built layer the map config
# enables, its display from its layer file as it is now. The view,
# basemap, title and locale come from the map config. A layer whose layer
# file has problems, or that was built as another type, is left out with
# an error and the function returns 1 once style.json is written. Atomic,
# like the archives. Nothing to do without a build.json.
write_style() {
  local out_dir=$1
  local style="${out_dir}/style.json"
  [[ -s "${out_dir}/build.json" ]] || return 0

  local entries configs='{}' map name built config type problem status=0
  entries=$(build_entries "$out_dir")
  map=$(jq -c '.map // {}' "$LAYERS_JSON") || die "cannot read $LAYERS_JSON"

  while IFS=$'\t' read -r name built; do
    [[ -n $name ]] || continue
    config=$(layer_get "$name" config)
    type=$(layer_get "$name" type)
    if [[ -z $config ]]; then
      while IFS= read -r problem; do log_error "${name}.yaml: $problem"; done < <(jq -r \
        --arg n "$name" 'first(.layers[] | select(.name == $n)) | .problems[]' "$LAYERS_JSON")
      log_error "layer $name: left out of style.json until ${name}.yaml is fixed"
      status=1
    elif [[ $type != "$built" ]]; then
      log_error "layer $name: left out of style.json: built as a $built layer, but ${name}.yaml is a $type layer now: rebuild it"
      status=1
    else
      configs=$(jq -c --arg n "$name" --slurpfile c "$config" '.[$n] = $c[0]' <<<"$configs") \
        || die "cannot read $config"
    fi
  done < <(jq -r --slurpfile set "$LAYERS_JSON" \
    '([$set[0].layers[] | select(.enabled) | .name]) as $enabled
     | .[] | select(.name as $n | $enabled | index($n)) | "\(.name)\t\(.type // "vector")"' <<<"$entries")

  local tmp="${style}.$$.tmp"
  jq -n --argjson entries "$entries" --argjson configs "$configs" \
    --argjson map "$map" --arg glyphs "$GLYPHS_URL" '
    def source: if (.type // "vector") != "raster" then {type: "vector", url: "pmtiles://\(.file)"}
      else {type: "raster-dem", tileSize: 256, url: "cog://\(.file)#dem"} end;
    # fresh(config): a built layer (the input) from its layer file.
    def fresh($c): . as $e | ($e.type // "vector") as $type
      | {name: $e.name,
         meta: ({title: $c.title, type: $type, order: ($c.order // 0), visible: ($c.visible // false)}
           + ($c.display | with_entries(select(.key | IN("legend", "themes", "popup"))))),
         source: source,
         layers: [$c.display.layers[]
           | . + {id: "\($e.name)-\(.id)", source: $e.name}
           + (if $type == "raster" then {} else {"source-layer": $e.name} end)
           + {layout: ((.layout // {}) + {visibility: (if $c.visible then "visible" else "none" end)}),
              metadata: ((.metadata // {}) + {"erap:layer": $e.name})}]};
    [$entries[] | select($configs[.name]) | fresh($configs[.name])]
    | sort_by(.meta.order, .name) as $parts
    | ($parts | map(.layers[])) as $layers
    | {version: 8, name: "ERAP Map data layers",
       metadata: ({"erap:layers": ($parts | map({key: .name, value: .meta}) | from_entries)}
         + (if $map.basemap then {"erap:basemap": $map.basemap} else {} end)
         + ($map | with_entries(select(.key | IN("minzoom", "maxzoom", "bounds")))
            | if . == {} then {} else {"erap:view": .} end)
         + (if $map.title then {"erap:title": $map.title} else {} end)
         + (if $map.locale then {"erap:locale": $map.locale} else {} end))}
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
  return "$status"
}
