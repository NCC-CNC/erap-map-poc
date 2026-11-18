#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters in single quotes, passed to _build_write
# build.json: the build report, one entry per built layer, read by
# `run.sh --status`, `--style-only` and `--remove` (and by
# scripts/publish-pages.sh). The web app reads style.json (lib/style.sh),
# not this file (design note 04). Shape:
#
#   {
#     "updated_at": "2026-01-01T00:00:00Z",
#     "layers": [
#       { "name": "sample", "file": "sample.pmtiles",   (or forest.cog.tif)
#         "type": "vector", "format": "mvt",
#         "minzoom": 0, "maxzoom": 8,
#         "bounds": [west, south, east, north], "center": [lon, lat, zoom],
#         "built_at": "2026-01-01T00:00:00Z",
#         "display_updated_at": "2026-01-01T00:00:00Z",
#         "build_seconds": 3, "bytes": 12345,
#         "provenance": {...},
#         ...the build report of the layer type (below)... }
#     ]
#   }
#
# `type` is `raster` for a layer with the raster profile, else `vector`.
# `file` is the archive: `<layer>.pmtiles` for a vector layer,
# `<layer>.cog.tif` for a raster one (ADR 0010). `format` is the tile type:
# from the PMTiles header for a vector layer (`mvt`), `cog` for a raster,
# whose zooms, bounds and center come
# from the build (raster_header). `display_updated_at` is when the layer's
# part of style.json was last written from its layer file: by a build or
# by `run.sh --style-only` (build_set_display, which changes nothing else
# in the entry but the display hash in `provenance`). `provenance` says
# what the layer was built from (lib/layerfile.sh, layer_provenance):
#
#   "provenance": { "origin": "committed",
#     "source": { "path": "sample.geojson", "bytes": 12345,
#                 "modified_at": "2026-01-01T00:00:00Z" },
#     "overrides": { "source": ..., "processing": ... } or null,
#     "build_sha256": "...", "display_sha256": "..." }
#
# The rest is the build report:
#
#   vector: "feature_count": 15, "profile": "default", "min_visible_px": 1,
#           "max_tile_bytes": 1234,
#           "zooms": [ { "zoom": 0, "input": 15, "present": 15,
#                        "required": 15, "required_present": 15,
#                        "max_tile_bytes": 1234 }, ... ]
#           (from the drop guard, lib/guard.sh), and for a layer with
#           calculated fields (lib/calculated.sh):
#           "calculated_fields": [ { "name": "x", "expression": "a - b",
#                                    "non_null": 15, "min": 0, "max": 9 } ]
#   raster: "width": 447240, "height": 290531, "block_size": 256,
#           "resampling": "near" (the warp's method: "average" when the
#           max zoom is coarser than the source; lib/raster.sh),
#           "max_zoom_values": "near" (how the max zoom's 0/255 values
#           are made: "near" from the source as is, with -r near;
#           "majority" with -r average: 255 where at least half is
#           covered),
#           "grey_levels": 256 (processing.grey_levels: the grey levels
#           the COG holds, 256 for the full share; only in the overviews
#           when "majority"; lib/raster.sh),
#           "overview_count": 10,
#           "zooms": [ { "zoom": 12, "width": 447240, "height": 290531 }, ... ]
#           (the COG's levels, max zoom first; lib/raster.sh).
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
# its build.json entry names, or else the first of layer_archives. Prints
# nothing and returns 1 if there is none.
layer_archive() {
  local out_dir=$1 layer=$2 file=""
  if [[ -s "${out_dir}/build.json" ]]; then
    file=$(jq -r --arg n "$layer" 'first(.layers[]? | select(.name == $n)) | .file // empty' \
      "${out_dir}/build.json" 2>/dev/null) || file=""
  fi
  if [[ -n $file && -f "${out_dir}/${file}" ]]; then
    printf '%s\n' "${out_dir}/${file}"
    return 0
  fi
  layer_archives "$out_dir" "$layer" | head -n 1 | grep .
}

# build_entries OUT_DIR: the layers array of OUT_DIR/build.json as compact
# JSON, `[]` when there is none.
build_entries() {
  local file="${1}/build.json"
  if [[ -s $file ]]; then
    jq -c '.layers // []' "$file" || die "cannot read $file"
  else
    printf '[]\n'
  fi
}

# build_has OUT_DIR LAYER: whether OUT_DIR/build.json has an entry for LAYER.
build_has() {
  jq -e --arg n "$2" 'any(.layers[]?; .name == $n)' "${1}/build.json" >/dev/null 2>&1
}

# _build_write OUT_DIR JQ [JQ_ARGS...]: rewrite OUT_DIR/build.json with the
# jq filter JQ (given $now, plus JQ_ARGS), atomically. A missing or
# unreadable file starts as {"layers": []}.
_build_write() {
  local out_dir=$1 filter=$2
  shift 2
  local file="${out_dir}/build.json" current='{"layers": []}'
  if [[ -s $file ]]; then
    if jq -e '.layers | type == "array"' "$file" >/dev/null 2>&1; then
      current=$(cat "$file")
    else
      log_warn "ignoring unreadable $file; starting a new one"
    fi
  fi
  local tmp="${file}.$$.tmp"
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" \
    "{updated_at: \$now} + del(.updated_at) | $filter" <<<"$current" >"$tmp" \
    || {
      rm -f "$tmp"
      die "cannot write $file"
    }
  mv -f "$tmp" "$file"
}

# build_update OUT_DIR LAYER TYPE REPORT_JSON BUILD_SECONDS [PROVENANCE_JSON]
# [HEADER_JSON]: record LAYER's build in OUT_DIR/build.json. REPORT_JSON is
# a JSON object holding the layer type's build report, added to the entry
# as it is; PROVENANCE_JSON is the layer's provenance (null when not
# given). HEADER_JSON, {tile_type, minzoom, maxzoom, bounds, center}, gives
# the archive fields of a raster layer (raster_header); a vector layer's
# come from its PMTiles header. The archive is layer_archive_file's.
build_update() {
  local out_dir=$1 layer=$2 type=$3 report=${4:-'{}'} seconds=${5:-null}
  local provenance=${6:-null} header=${7:-}
  local file bytes
  file=$(layer_archive_file "$layer" "$type")
  local archive="${out_dir}/${file}"

  if [[ -z $header ]]; then
    header=$(pmtiles show --header-json "$archive") \
      || die "cannot read header of $archive"
  fi
  bytes=$(stat -c %s "$archive") || die "cannot read the size of $archive"

  _build_write "$out_dir" '
    .layers = ([.layers[] | select(.name != $name)]
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
          build_seconds: $seconds,
          bytes: $bytes,
          provenance: $provenance
        } + $report]
      | sort_by(.name))' \
    --argjson header "$header" --arg name "$layer" --arg file "$file" \
    --arg type "$type" --argjson report "$report" --argjson seconds "$seconds" \
    --argjson bytes "$bytes" --argjson provenance "$provenance"
  log_info "updated ${out_dir}/build.json"
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

# build_set_display OUT_DIR SHAS_JSON: after style.json took these layers'
# display from their layer files (write_style), record the display hash in
# the provenance of each whose hash changed, and set its
# display_updated_at. SHAS_JSON is an object of layer name to
# display_sha256. A build records the hash itself (build_update), so
# build.json is rewritten only after --style-only of a changed display (or
# a layer back in the map config with a changed one).
build_set_display() {
  local out_dir=$1 shas=$2
  jq -e --argjson shas "$shas" \
    'any(.layers[]?; $shas[.name] != null and .provenance.display_sha256 != $shas[.name])' \
    "${out_dir}/build.json" >/dev/null 2>&1 || return 0
  _build_write "$out_dir" '
    .layers |= map($shas[.name] as $sha
      | if $sha == null or .provenance.display_sha256 == $sha then .
        else .display_updated_at = $now
          | .provenance = ((.provenance // {}) | .display_sha256 = $sha) end)' \
    --argjson shas "$shas"
}

# build_remove OUT_DIR LAYER: drop LAYER's entry from OUT_DIR/build.json
# (atomically) and keep the others. Nothing to do if there is no build.json
# or no entry.
build_remove() {
  local out_dir=$1 layer=$2
  local file="${out_dir}/build.json"
  [[ -s $file ]] || return 0
  jq -e '.layers | type == "array"' "$file" >/dev/null 2>&1 || die "cannot read $file"
  build_has "$out_dir" "$layer" || return 0
  _build_write "$out_dir" '.layers |= map(select(.name != $name))' --arg name "$layer"
  log_info "removed $layer from $file"
}
