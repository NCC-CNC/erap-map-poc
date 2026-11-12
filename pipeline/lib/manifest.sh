#!/usr/bin/env bash
# manifest.json: one entry per built layer, read by the web app. Shape:
#
#   {
#     "updated_at": "2026-01-01T00:00:00Z",
#     "layers": [
#       { "name": "sample", "file": "sample.pmtiles",
#         "type": "vector", "format": "mvt",
#         "minzoom": 0, "maxzoom": 8,
#         "bounds": [west, south, east, north], "center": [lon, lat, zoom],
#         "built_at": "2026-01-01T00:00:00Z",
#         "display": { "title": ..., "defaultVisible": true, "order": 10,
#                      "popup": {...}, "layers": [...], "legend": {...} },
#         "build_seconds": 3, "bytes": 12345,
#         ...the build report of the layer type (below)... }
#     ]
#   }
#
# `type` is the layer's LAYER_TYPE (`vector` or `raster`) and `format` the
# archive's tile type from its PMTiles header (`mvt` or `png`). The fields
# up to display are the ones the web app reads (display is the resolved
# <layer>.style.json, lib/display.sh). The rest is the build report:
#
#   vector: "feature_count": 15, "profile": null, "min_visible_px": 1,
#           "max_tile_bytes": 1234,
#           "zooms": [ { "zoom": 0, "input": 15, "present": 15,
#                        "required": 15, "required_present": 15,
#                        "max_tile_bytes": 1234 }, ... ]
#           (from the drop guard, lib/guard.sh)
#   raster: "tile_count": 2745, "max_tile_bytes": 15000,
#           "zooms": [ { "zoom": 3, "tiles": 1, "max_tile_bytes": 1621 }, ... ]
#           (lib/raster.sh)
#
# Updating one layer keeps the other entries. Written via a temp file and
# `mv`, like the tiles.

# manifest_update OUT_DIR LAYER TYPE DISPLAY_FILE REPORT_JSON BUILD_SECONDS
# DISPLAY_FILE is the resolved display block from resolve_display (null when
# empty); REPORT_JSON is a JSON object holding the layer type's build report,
# added to the entry as it is.
manifest_update() {
  local out_dir=$1 layer=$2 type=$3 display_file=$4 report=${5:-'{}'} seconds=${6:-null}
  local manifest="${out_dir}/manifest.json"
  local pmtiles_file="${out_dir}/${layer}.pmtiles"
  local now header current bytes
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  header=$(pmtiles show --header-json "$pmtiles_file") \
    || die "cannot read header of $pmtiles_file"
  bytes=$(stat -c %s "$pmtiles_file") || die "cannot read the size of $pmtiles_file"

  local display=null
  if [[ -n $display_file ]]; then
    display=$(jq -c '.' "$display_file") || die "cannot read $display_file"
  fi

  current='{"layers": []}'
  if [[ -s $manifest ]]; then
    if jq -e '.layers | type == "array"' "$manifest" >/dev/null 2>&1; then
      current=$(cat "$manifest")
    else
      log_warn "ignoring unreadable $manifest; starting a new one"
    fi
  fi

  local tmp="${manifest}.$$.tmp"
  jq -n \
    --argjson current "$current" \
    --argjson header "$header" \
    --arg name "$layer" \
    --arg file "${layer}.pmtiles" \
    --arg type "$type" \
    --arg now "$now" \
    --argjson display "$display" \
    --argjson report "$report" \
    --argjson seconds "$seconds" \
    --argjson bytes "$bytes" \
    '{updated_at: $now} + ($current | del(.updated_at))
     | .layers = ([.layers[] | select(.name != $name)]
         + [{
             name: $name,
             file: $file,
             type: $type,
             format: $header.tile_type,
             minzoom: $header.minzoom,
             maxzoom: $header.maxzoom,
             bounds: $header.bounds,
             center: $header.center,
             built_at: $now,
             display: $display,
             build_seconds: $seconds,
             bytes: $bytes
           } + $report]
         | sort_by(.name))' >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "updated $manifest"
}

# vector_report FEATURE_COUNT STATS_FILE PROFILE MIN_PX: print a vector
# layer's build report (see above) as compact JSON. STATS_FILE is the drop
# guard's per-zoom JSON array.
vector_report() {
  local count=$1 stats_file=$2 profile=$3 min_px=$4
  jq -c \
    --argjson count "$count" \
    --arg profile "$profile" \
    --arg min_px "$min_px" \
    '{
       feature_count: $count,
       profile: (if $profile == "" then null else $profile end),
       min_visible_px: (if $min_px == "" then null else ($min_px | tonumber) end),
       max_tile_bytes: ([.[].max_tile_bytes] | max),
       zooms: .
     }' "$stats_file" || die "cannot read $stats_file"
}

# manifest_remove OUT_DIR LAYER: drop LAYER's entry from OUT_DIR/manifest.json
# (atomically, like manifest_update) and keep the others. Nothing to do if
# there is no manifest or no entry.
manifest_remove() {
  local out_dir=$1 layer=$2
  local manifest="${out_dir}/manifest.json"
  [[ -s $manifest ]] || return 0
  jq -e '.layers | type == "array"' "$manifest" >/dev/null 2>&1 \
    || die "cannot read $manifest"
  jq -e --arg name "$layer" 'any(.layers[]; .name == $name)' "$manifest" >/dev/null \
    || return 0

  local now tmp="${manifest}.$$.tmp"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg name "$layer" --arg now "$now" \
    '.updated_at = $now | .layers |= map(select(.name != $name))' \
    "$manifest" >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "removed $layer from $manifest"
}
