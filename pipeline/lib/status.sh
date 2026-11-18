#!/usr/bin/env bash
# Layer status, for `run.sh --status`: which layers are configured, which are
# built, and which builds are out of date. Read only: nothing is written.
#
# Every layer with a layer file (lib/layerfile.sh), a build.json entry
# or an archive (<layer>.pmtiles for a vector layer, <layer>.cog.tif for a
# raster one) is listed, in one of these states:
#
#   current    built from the layer file's source, fields and processing
#              as they are now, after its source data last changed, and its
#              display updated from the layer file's display as it is now.
#   stale      built, but the layer file's `source`, `fields` or
#              `processing` (or the map config's overrides of them) differ
#              from the build's (the hash in the entry's provenance), its
#              source data or a join table has changed since (file
#              modification time against build.json's built_at), or its
#              archive is missing. Rebuild it.
#   restyle    built and not stale, but the layer file's `display`,
#              `title`, `visible` or `order` differ from the display last
#              written (by a build or by `run.sh --style-only`, which
#              updates it, no tiling).
#   not built  configured, but not built yet (or every build failed).
#   source missing
#              configured, but its source data or a join table is not
#              found (for example RAW_DIR not set). A full build skips it.
#              A previous build, if any, is still served.
#   invalid    the layer file has problems (its schema, or the checks in
#              lib/layerfile.sh). A previous build, if any, is still
#              served.
#   disabled   configured, but left out by the map config's `layers`: not
#              built, and hidden from the map if built before.
#   orphan     built, but its layer file is gone. `run.sh --remove`
#              removes it.
#
# `notes` says why. A change to the pipeline itself does not make a layer
# stale. The JSON (layer_status_json) is:
#
#   { "layers": [ { "name": "sample", "state": "current", "notes": [],
#       "configured": true, "enabled": true, "origin": "committed",
#       "built": true, "type": "vector", "format": "mvt",
#       "input": "...",
#       "built_at": "2026-01-01T00:00:00Z",
#       "display_updated_at": "2026-01-01T00:00:00Z", "archive_bytes": 12345,
#       "minzoom": 0, "maxzoom": 8, "feature_count": 15, "width": null,
#       "height": null,
#       "max_tile_bytes": 1234,
#       "calculated_fields": ["x"] },
#     ... ] }
#
# `calculated_fields` are the names of the build's calculated fields; null
# when it had none, or the layer is not built.
#
# Fields from build.json are null when the layer is not built. `type` is
# build.json's (vector when an older entry has none), or the layer
# file's when not built. A raster layer (ADR 0010) has `width` and
# `height` (of its COG, in pixels) and no `feature_count`; a vector layer
# the other way round. `origin` (committed, or local for a
# layer in layers.local/) and `enabled`
# are from the layer files, null when not configured.

# _newest_mtime FILE...: the newest modification time (epoch seconds) of the
# FILEs that exist; nothing if none does.
_newest_mtime() {
  local f times=()
  for f in "$@"; do
    if [[ -e $f ]]; then times+=("$(stat -c %Y "$f")"); fi
  done
  ((${#times[@]} > 0)) || return 0
  printf '%s\n' "${times[@]}" | sort -n | tail -n 1
}

# source_mtime INPUT: the newest modification time of a layer's source data
# (its source path, resolved): a file with its sidecars (a shapefile's .dbf,
# .prj, ...), every file in a directory (a FileGDB), or the zip for a path
# inside one. Prints nothing for a /vsi path; returns 1 if the data is not
# found.
source_mtime() {
  local files
  files=$(_source_files "$1") || return 1
  [[ -n $files ]] || return 0
  xargs -d '\n' stat -c %Y <<<"$files" | sort -n | tail -n 1
}

# source_bytes INPUT: the total size in bytes of a layer's source data, the
# same files as source_mtime. Prints nothing for a /vsi path; returns 1 if
# the data is not found.
source_bytes() {
  local files
  files=$(_source_files "$1") || return 1
  [[ -n $files ]] || return 0
  xargs -d '\n' stat -c %s <<<"$files" | awk '{ s += $1 } END { printf "%d\n", s }'
}

# _source_files INPUT: the files of a layer's source data, one per line (see
# source_mtime). Nothing for a /vsi path or an empty directory; returns 1
# if the data is not found.
_source_files() {
  local input=$1 path
  [[ $input != /vsi* ]] || return 0
  if [[ $input =~ ^(.*[.][Zz][Ii][Pp])(/.*)?$ ]]; then
    path=${BASH_REMATCH[1]}
  else
    path=$input
  fi
  if [[ -d $path ]]; then
    find "$path" -type f
  elif [[ -f $path ]]; then
    local base=${path##*/} f
    printf '%s\n' "$path"
    if [[ $base == ?*.* ]]; then
      for f in "${path%.*}".*; do
        if [[ -f $f && $f != "$path" ]]; then printf '%s\n' "$f"; fi
      done
    fi
  else
    return 1
  fi
}

# _layer_status NAME OUT_DIR ENTRIES: one layer's status object. ENTRIES is
# build.json's layers array; the layer set is LAYERS_JSON.
_layer_status() {
  local name=$1 out_dir=$2 entries=$3
  local archive=""
  local entry layer built_at=0 configured=false built=false state input="" type=""
  local notes=() restyle="" enabled=true

  entry=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // null' <<<"$entries")
  if [[ $entry != null ]]; then
    built=true
    # The archive the entry names.
    archive=$(jq -r '.file // ""' <<<"$entry")
    if [[ -n $archive ]]; then
      archive="${out_dir}/${archive}"
    else
      archive=$(layer_archives "$out_dir" "$name" | head -n 1) || archive=""
    fi
    built_at=$(jq -r '(.built_at | fromdateiso8601?) // 0' <<<"$entry")
  else
    archive=$(layer_archives "$out_dir" "$name" | head -n 1) || archive=""
  fi
  layer=$(jq -c --arg n "$name" 'first(.layers[] | select(.name == $n)) // null' "$LAYERS_JSON")
  if [[ $layer != null ]]; then
    configured=true
    enabled=$(jq -r '.enabled' <<<"$layer")
    input=$(jq -r '.input // ""' <<<"$layer")
    type=$(jq -r '.type // ""' <<<"$layer")
  fi

  if [[ $configured == false ]]; then
    state=orphan
    notes+=("no ${name}.yaml: remove the build with --remove")
    if [[ $built == false ]]; then notes+=("archive with no build.json entry"); fi
  elif [[ $enabled == false ]]; then
    state=disabled
    notes+=("not in the map config's layers")
    if [[ $built == true ]]; then notes+=("built before: hidden from the map, --remove removes it"); fi
  else
    local problems=()
    mapfile -t problems < <(jq -r '.problems[]' <<<"$layer")

    # The modification times of the source data and of its newest join table.
    local src="" joined="" missing="" join join_mtime
    if [[ -n $input ]] && ! src=$(source_mtime "$input"); then
      missing="source data not found: ${input#"${PIPELINE_INPUT_DIR}"/}"
    fi
    while IFS= read -r join; do
      [[ -z $missing && -n $join ]] || continue
      if ! join_mtime=$(source_mtime "$join"); then
        missing="join table not found: ${join#"${PIPELINE_INPUT_DIR}"/}"
      elif ((${join_mtime:-0} > ${joined:-0})); then
        joined=$join_mtime
      fi
    done < <(jq -r '(.joins // [])[]' <<<"$layer")

    if ((${#problems[@]} > 0)); then
      state=invalid
      notes=("${problems[@]/#/${name}.yaml: }")
    elif [[ -n $missing ]]; then
      state="source missing"
      notes=("$missing")
    elif [[ $built == false ]]; then
      state="not built"
      if [[ -n $archive && -f $archive ]]; then notes+=("archive with no build.json entry"); fi
    else
      local recorded_build recorded_display current_build current_display
      read -r recorded_build recorded_display < <(jq -r \
        '"\(.provenance.build_sha256 // "-") \(.provenance.display_sha256 // "-")"' <<<"$entry")
      read -r current_build current_display < <(jq -r '"\(.build_sha256) \(.display_sha256)"' <<<"$layer")
      [[ -f $archive ]] || notes+=("archive missing")
      if [[ $recorded_build != "$current_build" ]]; then
        notes+=("source, fields or processing changed since the build (${name}.yaml or the map config's overrides)")
      fi
      if ((${src:-0} > built_at)); then notes+=("source data changed since the build"); fi
      if ((${joined:-0} > built_at)); then notes+=("join table changed since the build"); fi
      if [[ $recorded_display != "$current_display" ]]; then
        restyle="display changed since it was last updated (${name}.yaml; --style-only updates it)"
      fi
      if ((${#notes[@]} > 0)); then
        state=stale
      elif [[ -n $restyle ]]; then
        state=restyle
      else
        state=current
      fi
      if [[ -n $restyle ]]; then notes+=("$restyle"); fi
    fi
  fi

  local bytes=""
  if [[ -n $archive && -f $archive ]]; then bytes=$(stat -c %s "$archive"); fi
  if [[ -n $input ]]; then input=${input#"${PIPELINE_INPUT_DIR}"/}; fi

  jq -n -c \
    --arg name "$name" --arg state "$state" \
    --argjson configured "$configured" --argjson built "$built" \
    --arg input "$input" --arg bytes "$bytes" --argjson entry "$entry" \
    --arg type "$type" --argjson layer "$layer" \
    '{name: $name, state: $state, notes: $ARGS.positional,
      configured: $configured, enabled: $layer.enabled,
      origin: (if $layer == null then null else ($layer.origin // "committed") end),
      built: $built,
      type: (if $entry != null then ($entry.type // "vector")
             elif $type != "" then $type else null end),
      format: $entry.format,
      input: (if $input == "" then null else $input end),
      built_at: $entry.built_at,
      display_updated_at: ($entry.display_updated_at // $entry.built_at),
      archive_bytes: (if $bytes == "" then null else ($bytes | tonumber) end),
      minzoom: $entry.minzoom, maxzoom: $entry.maxzoom,
      feature_count: $entry.feature_count,
      width: $entry.width, height: $entry.height,
      max_tile_bytes: $entry.max_tile_bytes,
      calculated_fields: (if $entry.calculated_fields == null then null
                          else [$entry.calculated_fields[].name] end)}' \
    --args "${notes[@]}"
}

# layer_status_json OUT_DIR [NAME...]: the status of the named layers, or of
# every layer in the layer set (LAYERS_JSON) or built, as JSON on stdout.
layer_status_json() {
  local out_dir=$1
  shift
  local entries
  entries=$(build_entries "$out_dir")

  local names=("$@")
  if ((${#names[@]} == 0)); then
    local found=() f
    for f in "$out_dir"/*.pmtiles "$out_dir"/*.cog.tif; do
      [[ -e $f ]] || continue
      f=${f##*/}
      f=${f%.pmtiles}
      found+=("${f%.cog.tif}")
    done
    mapfile -t -O "${#found[@]}" found < <(jq -r '.[].name' <<<"$entries")
    mapfile -t -O "${#found[@]}" found < <(layer_names)
    names=()
    if ((${#found[@]} > 0)); then
      mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -u)
      for f in "${found[@]}"; do
        if layer_name_valid "$f"; then names+=("$f"); fi
      done
    fi
  fi

  local name rows=()
  for name in "${names[@]}"; do
    rows+=("$(_layer_status "$name" "$out_dir" "$entries")")
  done
  if ((${#rows[@]} == 0)); then
    echo '{"layers": []}'
    return
  fi
  printf '%s\n' "${rows[@]}" | jq -s '{layers: .}'
}

# print_layer_status: the JSON from layer_status_json, on stdin, as a table
# with each layer's calculated fields (from its build) and its notes under
# it.
print_layer_status() {
  jq -r '
    def size: if . == null then "-"
      elif . < 1024 then "\(.) B"
      elif . < 1048576 then "\((. / 1024 * 10 | round) / 10) kB"
      else "\((. / 1048576 * 10 | round) / 10) MB" end;
    .layers[]
    | [.name, .state, (.built_at // "-"), (.archive_bytes | size),
       (if .minzoom == null then "-" else "\(.minzoom)-\(.maxzoom)" end),
       (if .feature_count != null then (.feature_count | tostring)
        elif .width != null then "\(.width)x\(.height) px"
        else "-" end),
       (.max_tile_bytes | size),
       (.notes | join("\u001f")),
       (if .calculated_fields then "calculated: \(.calculated_fields | join(", "))" else "" end)]
    | @tsv' | awk -F'\t' '
    # cell(i, s): column i padded to its width, or ending the line.
    function cell(i, s) { if (i < 7) printf("%-" w[i] "s  ", s); else printf("%s\n", s) }
    BEGIN { split("LAYER STATE BUILT SIZE ZOOMS FEATURES MAX_TILE", head, " "); head[7] = "MAX TILE"
            for (i = 1; i <= 7; i++) w[i] = length(head[i]) }
    { n++; for (i = 1; i <= 9; i++) row[n, i] = $i
      for (i = 1; i <= 7; i++) if (length($i) > w[i]) w[i] = length($i) }
    END {
      if (n == 0) { print "no layers configured or built"; exit }
      for (i = 1; i <= 7; i++) cell(i, head[i])
      for (r = 1; r <= n; r++) {
        for (i = 1; i <= 7; i++) cell(i, row[r, i])
        if (row[r, 9] != "") {
          k = split(row[r, 9], info, "\037")
          for (j = 1; j <= k; j++) printf "  %s\n", info[j]
        }
        if (row[r, 8] != "") {
          k = split(row[r, 8], notes, "\037")
          for (j = 1; j <= k; j++) printf "  - %s\n", notes[j]
        }
      }
    }'
}
