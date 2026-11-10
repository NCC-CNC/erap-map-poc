#!/usr/bin/env bash
# manifest.json: one entry per built layer, read by the web app. Shape:
#
#   {
#     "updated_at": "2026-01-01T00:00:00Z",
#     "layers": [
#       { "name": "sample", "file": "sample.pmtiles",
#         "minzoom": 0, "maxzoom": 8,
#         "bounds": [west, south, east, north], "center": [lon, lat, zoom],
#         "feature_count": 15, "built_at": "2026-01-01T00:00:00Z",
#         "display": { "title": ..., "defaultVisible": true, "order": 10,
#                      "popup": {...}, "layers": [...], "legend": {...} },
#         "profile": null, "min_visible_px": 1, "max_tile_bytes": 1234,
#         "zooms": [
#           { "zoom": 0, "input": 15, "present": 15, "required": 15,
#             "required_present": 15, "max_tile_bytes": 1234 }, ...
#         ] }
#     ]
#   }
#
# The fields up to display are the ones the web app reads (display is the
# resolved <layer>.style.json, lib/display.sh); the rest is the
# build report from the drop guard (lib/guard.sh). Updating one layer keeps
# the other entries. Written via a temp file and `mv`, like the tiles.

# manifest_update OUT_DIR LAYER FEATURE_COUNT [STATS_FILE [PROFILE [MIN_PX [DISPLAY_FILE]]]]
# STATS_FILE is drop_guard's per-zoom JSON array; DISPLAY_FILE is the
# resolved display block from resolve_display (null when not given).
manifest_update() {
  local out_dir=$1 layer=$2 count=$3 stats_file=${4:-} profile=${5:-} min_px=${6:-} display_file=${7:-}
  local manifest="${out_dir}/manifest.json"
  local pmtiles_file="${out_dir}/${layer}.pmtiles"
  local now header current
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  header=$(pmtiles show --header-json "$pmtiles_file") \
    || die "cannot read header of $pmtiles_file"

  local zooms='[]'
  if [[ -n $stats_file ]]; then
    zooms=$(jq -c '.' "$stats_file") || die "cannot read $stats_file"
  fi

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
    --argjson count "$count" \
    --arg now "$now" \
    --arg profile "$profile" \
    --arg min_px "$min_px" \
    --argjson zooms "$zooms" \
    --argjson display "$display" \
    '{updated_at: $now} + ($current | del(.updated_at))
     | .layers = ([.layers[] | select(.name != $name)]
         + [{
             name: $name,
             file: $file,
             minzoom: $header.minzoom,
             maxzoom: $header.maxzoom,
             bounds: $header.bounds,
             center: $header.center,
             feature_count: $count,
             built_at: $now,
             display: $display,
             profile: (if $profile == "" then null else $profile end),
             min_visible_px: (if $min_px == "" then null else ($min_px | tonumber) end),
             max_tile_bytes: ([$zooms[].max_tile_bytes] | max),
             zooms: $zooms
           }]
         | sort_by(.name))' >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "updated $manifest"
}
