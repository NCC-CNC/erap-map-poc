#!/usr/bin/env bash
# manifest.json: one entry per built layer, read by the web app. Shape:
#
#   {
#     "updated_at": "2026-01-01T00:00:00Z",
#     "layers": [
#       { "name": "sample", "file": "sample.pmtiles",
#         "minzoom": 0, "maxzoom": 8,
#         "bounds": [west, south, east, north], "center": [lon, lat, zoom],
#         "feature_count": 15, "built_at": "2026-01-01T00:00:00Z" }
#     ]
#   }
#
# Updating one layer keeps the other entries. Written via a temp file and
# `mv`, like the tiles.

# manifest_update OUT_DIR LAYER FEATURE_COUNT
manifest_update() {
  local out_dir=$1 layer=$2 count=$3
  local manifest="${out_dir}/manifest.json"
  local pmtiles_file="${out_dir}/${layer}.pmtiles"
  local now header current
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  header=$(pmtiles show --header-json "$pmtiles_file") \
    || die "cannot read header of $pmtiles_file"

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
             built_at: $now
           }]
         | sort_by(.name))' >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "updated $manifest"
}
