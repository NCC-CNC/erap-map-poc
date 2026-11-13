#!/usr/bin/env bash
# manifest.json: one entry per built layer, read by the web app. Shape:
#
#   {
#     "updated_at": "2026-01-01T00:00:00Z",
#     "map": { "center": [lon, lat], "zoom": 3, "basemap": "light" },
#     "layers": [
#       { "name": "sample", "file": "sample.pmtiles",   (or forest.cog.tif)
#         "type": "vector", "format": "mvt",
#         "minzoom": 0, "maxzoom": 8,
#         "bounds": [west, south, east, north], "center": [lon, lat, zoom],
#         "built_at": "2026-01-01T00:00:00Z",
#         "display_updated_at": "2026-01-01T00:00:00Z",
#         "display": { "title": ..., "defaultVisible": true, "order": 10,
#                      "popup": {...}, "layers": [...], "legend": {...} },
#         "enabled": true,
#         "build_seconds": 3, "bytes": 12345,
#         "provenance": {...},
#         ...the build report of the layer type (below)... }
#     ]
#   }
#
# `map` is the local map config's opening view and basemap (ADR 0009), left
# out when it sets none. `type` is the layer's LAYER_TYPE (`vector` or
# `raster`). `file` is the archive: `<layer>.pmtiles` for a vector layer,
# `<layer>.cog.tif` for a raster one (ADR 0010; a raster built before that
# is a `.pmtiles` of PNG tiles until rebuilt). `format` is the tile type:
# from the PMTiles header for a vector layer (`mvt`), `cog` for a raster
# (`png` for an older raster build), whose zooms, bounds and center come
# from the build (raster_header). The fields up to `enabled` are the ones the web app
# reads (display is the resolved <layer>.style.json, lib/display.sh).
# `enabled` is false for a layer built before but left out by the map
# config: the map does not show it (manifest_apply_config); an entry
# without it is enabled. `display_updated_at` is when display was last
# written: by a build (then equal to built_at) or by `run.sh --style-only`
# (manifest_set_display), which changes nothing else in the entry but the
# display part of `provenance`. An entry from before it existed has none;
# read it as built_at. `provenance` says what the layer was built from
# (lib/mapconfig.sh, layer_provenance), so two maps can be compared:
#
#   "provenance": { "origin": "committed",
#     "source": { "path": "sample.geojson", "bytes": 12345,
#                 "modified_at": "2026-01-01T00:00:00Z" },
#     "overrides": { "input": ..., "title": ... } or null,
#     "env_sha256": "...", "style_sha256": "..." }
#
# The rest is the build report:
#
#   vector: "feature_count": 15, "profile": null, "min_visible_px": 1,
#           "max_tile_bytes": 1234,
#           "zooms": [ { "zoom": 0, "input": 15, "present": 15,
#                        "required": 15, "required_present": 15,
#                        "max_tile_bytes": 1234 }, ... ]
#           (from the drop guard, lib/guard.sh)
#   raster: "width": 447240, "height": 290531, "block_size": 256,
#           "overview_count": 10,
#           "zooms": [ { "zoom": 12, "width": 447240, "height": 290531 }, ... ]
#           (the COG's levels, max zoom first; lib/raster.sh). An older
#           raster build has "tile_count" and "max_tile_bytes" instead.
#
# Updating one layer keeps the other entries. Written via a temp file and
# `mv`, like the tiles.

# layer_archive_file LAYER TYPE: the archive file name a build of TYPE
# writes: LAYER.cog.tif for a raster layer, LAYER.pmtiles otherwise.
layer_archive_file() {
  if [[ $2 == raster ]]; then
    printf '%s.cog.tif\n' "$1"
  else
    printf '%s.pmtiles\n' "$1"
  fi
}

# layer_archives OUT_DIR LAYER: the paths of LAYER's archives in OUT_DIR
# that exist (.cog.tif first, then .pmtiles), one per line; returns 1 if
# there is none.
layer_archives() {
  local out_dir=$1 layer=$2 f found=1
  for f in "${out_dir}/${layer}.cog.tif" "${out_dir}/${layer}.pmtiles"; do
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      found=0
    fi
  done
  return "$found"
}

# layer_archive OUT_DIR LAYER: the path of LAYER's built archive: the file
# its manifest entry names, or else the first of layer_archives. Prints
# nothing and returns 1 if there is none.
layer_archive() {
  local out_dir=$1 layer=$2 file=""
  if [[ -s "${out_dir}/manifest.json" ]]; then
    file=$(jq -r --arg n "$layer" 'first(.layers[]? | select(.name == $n)) | .file // empty' \
      "${out_dir}/manifest.json" 2>/dev/null) || file=""
  fi
  if [[ -n $file && -f "${out_dir}/${file}" ]]; then
    printf '%s\n' "${out_dir}/${file}"
    return 0
  fi
  layer_archives "$out_dir" "$layer" | head -n 1 | grep .
}

# manifest_update OUT_DIR LAYER TYPE DISPLAY_FILE REPORT_JSON BUILD_SECONDS
# [PROVENANCE_JSON] [HEADER_JSON]
# DISPLAY_FILE is the resolved display block from resolve_display (null when
# empty); REPORT_JSON is a JSON object holding the layer type's build report,
# added to the entry as it is; PROVENANCE_JSON is the layer's provenance
# (null when not given). HEADER_JSON, {tile_type, minzoom, maxzoom, bounds,
# center}, gives the archive fields of a raster layer (raster_header); a
# vector layer's come from its PMTiles header. The archive is
# layer_archive_file's. The new entry is enabled.
manifest_update() {
  local out_dir=$1 layer=$2 type=$3 display_file=$4 report=${5:-'{}'} seconds=${6:-null}
  local provenance=${7:-null} header=${8:-}
  local manifest="${out_dir}/manifest.json" file
  file=$(layer_archive_file "$layer" "$type")
  local archive="${out_dir}/${file}"
  local now current bytes
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ -z $header ]]; then
    header=$(pmtiles show --header-json "$archive") \
      || die "cannot read header of $archive"
  fi
  bytes=$(stat -c %s "$archive") || die "cannot read the size of $archive"

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
    --arg file "$file" \
    --arg type "$type" \
    --arg now "$now" \
    --argjson display "$display" \
    --argjson report "$report" \
    --argjson seconds "$seconds" \
    --argjson bytes "$bytes" \
    --argjson provenance "$provenance" \
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
             display_updated_at: $now,
             display: $display,
             enabled: true,
             build_seconds: $seconds,
             bytes: $bytes,
             provenance: $provenance
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

# manifest_set_display OUT_DIR LAYER DISPLAY_FILE [DISPLAY_PROVENANCE]:
# replace the `display` block of LAYER's entry in OUT_DIR/manifest.json with
# the resolved one in DISPLAY_FILE and set its display_updated_at, for
# `run.sh --style-only`. DISPLAY_PROVENANCE, `{overrides, style_sha256}`
# (layer_display_provenance), updates the display part of the provenance:
# the display config's hash and the display overrides (the build ones,
# input and env, stay as built). built_at and the build report are kept.
# Atomic, like manifest_update.
manifest_set_display() {
  local out_dir=$1 layer=$2 display_file=$3 prov=${4:-null}
  local manifest="${out_dir}/manifest.json"
  jq -e --arg name "$layer" '.layers | type == "array" and any(.[]; .name == $name)' \
    "$manifest" >/dev/null 2>&1 || die "no entry for $layer in $manifest"

  local now display tmp="${manifest}.$$.tmp"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  display=$(jq -c '.' "$display_file") || die "cannot read $display_file"
  jq --arg name "$layer" --arg now "$now" --argjson display "$display" --argjson prov "$prov" \
    'def build_key: .key == "input" or .key == "env";
     .updated_at = $now
     | .layers |= map(if .name == $name
         then .display = $display | .display_updated_at = $now
           | if $prov == null then . else
               .provenance = ((.provenance // {})
                 | .style_sha256 = $prov.style_sha256
                 | .overrides = (((.overrides // {}) | with_entries(select(build_key)))
                     + (($prov.overrides // {}) | with_entries(select(build_key | not))))
                 | if .overrides == {} then .overrides = null else . end)
             end
         else . end)' \
    "$manifest" >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "updated the display of $layer in $manifest"
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

# manifest_apply_config OUT_DIR LAYERS_JSON: apply the layer set
# (lib/mapconfig.sh) to OUT_DIR/manifest.json: `map` from the map config
# (removed when it sets none) and `enabled` on the entry of every layer in
# the set. Entries of layers not in the set (orphans) are left as they are.
# Rewritten (atomically) only when something changes; nothing to do if
# there is no manifest.
manifest_apply_config() {
  local out_dir=$1 layers_json=$2
  local manifest="${out_dir}/manifest.json"
  [[ -s $manifest ]] || return 0
  jq -e '.layers | type == "array"' "$manifest" >/dev/null 2>&1 \
    || die "cannot read $manifest"

  local set changed tmp="${manifest}.$$.tmp"
  set=$(jq -c '{map, enabled: (.layers | map({key: .name, value: .enabled}) | from_entries)}' \
    "$layers_json") || die "cannot read $layers_json"
  changed=$(jq --argjson set "$set" '
    (if $set.map == null then del(.map) else .map = $set.map end)
    | .layers |= map(if $set.enabled[.name] == null then .
        else .enabled = $set.enabled[.name] end)' "$manifest") \
    || die "cannot update $manifest"
  if jq -e --argjson new "$changed" 'del(.updated_at) == ($new | del(.updated_at))' \
    "$manifest" >/dev/null; then
    return 0
  fi
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated_at = $now' <<<"$changed" >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $manifest"
    }
  mv -f "$tmp" "$manifest"
  log_info "applied the map config's layer selection and map view to $manifest"
}
