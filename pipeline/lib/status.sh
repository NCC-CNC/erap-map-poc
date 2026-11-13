#!/usr/bin/env bash
# Layer status, for `run.sh --status`: which layers are configured, which are
# built, and which builds are out of date. Read only: nothing is written.
#
# Every layer in the layer set (lib/mapconfig.sh: the layers dir plus the
# local map config, if any), with a manifest.json entry or with an archive
# (<layer>.pmtiles for a vector layer, <layer>.cog.tif for a raster one) is
# listed, in one of these states:
#
#   current    built after its .env and source data last changed, and its
#              display updated after its .style.json last changed.
#   stale      built, but its .env or its source data has changed since
#              (file modification time against the manifest's built_at),
#              the settings it is built from differ (the map config's
#              `input` or `env`: the hash in the entry's provenance), or
#              its archive is missing. Rebuild it.
#   restyle    built and not stale, but its .style.json has changed since
#              the display was last updated (the manifest's
#              display_updated_at, set by a build or by `run.sh
#              --style-only`), or the map config's display overrides have.
#              `run.sh --style-only` updates it, no tiling.
#   not built  configured, but not built yet (or every build failed).
#   source missing
#              configured, but its source data is not found (for example
#              RAW_DIR not set). A full build skips it. A previous build, if
#              any, is still served.
#   invalid    the config cannot be built as it is: the .env does not load
#              or the .style.json is missing. A previous build, if any, is
#              still served.
#   disabled   configured, but not enabled in the map config: not built,
#              and hidden from the map if built before.
#   orphan     built, but its config is gone. `run.sh --remove` removes it.
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
#       "height": null, "tile_count": null,
#       "max_tile_bytes": 1234 }, ... ] }
#
# Fields from the manifest are null when the layer is not built. `type` is
# the manifest's (vector when an older entry has none), or the config's
# LAYER_TYPE when not built. A raster layer (ADR 0010) has `width` and
# `height` (of its COG, in pixels) and no `feature_count`; a vector layer
# the other way round. A raster built as PNG tiles before COGs has
# `tile_count` instead and is stale. A raster's
# LAYER_INPUT is relative to RAW_DIR (/data/raw) like any input, so its
# source data is checked the same way. `origin` (committed, local or
# config) and `enabled` are from the layer set, null when not configured.

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
# (LAYER_INPUT, resolved): a file with its sidecars (a shapefile's .dbf,
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

# _config_input CONFIG: load CONFIG in a subshell and print
# `ok<TAB>TYPE<TAB>INPUT` (LAYER_TYPE and LAYER_INPUT, resolved), or
# `invalid<TAB>REASON` if it does not load.
_config_input() {
  local result
  result=$(
    # Report a config error instead of exiting with it. Called by
    # load_layer_config.
    # shellcheck disable=SC2329
    die() {
      printf 'invalid\t%s\n' "$*"
      exit 0
    }
    load_layer_config "$1" 2>/dev/null
    printf 'ok\t%s\t%s\n' "$LAYER_TYPE" "$LAYER_INPUT"
  ) || true
  printf '%s\n' "${result:-$(printf 'invalid\t%s does not load' "${1##*/}")}"
}

# _layer_status NAME OUT_DIR ENTRIES: one layer's status object. ENTRIES is
# the manifest's layers array; the layer set is LAYERS_JSON.
_layer_status() {
  local name=$1 out_dir=$2 entries=$3
  local archive="" legacy=false
  local entry layer built_at=0 display_at=0 configured=false built=false state input="" type=""
  local notes=() restyle="" enabled=true

  entry=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // null' <<<"$entries")
  if [[ $entry != null ]]; then
    built=true
    # The archive the entry names (an entry from before COGs names its
    # .pmtiles); a raster built as PNG tiles needs a rebuild (ADR 0010).
    archive=$(jq -r '.file // ""' <<<"$entry")
    if [[ -n $archive ]]; then
      archive="${out_dir}/${archive}"
    else
      archive=$(layer_archives "$out_dir" "$name" | head -n 1) || archive=""
    fi
    if jq -e '.type == "raster" and .format != "cog"' <<<"$entry" >/dev/null; then
      legacy=true
    fi
    # An entry from before display_updated_at: the display is the build's.
    read -r built_at display_at < <(jq -r '((.built_at | fromdateiso8601?) // 0) as $b
      | "\($b) \((.display_updated_at | fromdateiso8601?) // $b)"' <<<"$entry")
  else
    archive=$(layer_archives "$out_dir" "$name" | head -n 1) || archive=""
  fi
  layer=$(jq -c --arg n "$name" 'first(.layers[] | select(.name == $n)) // null' "$LAYERS_JSON")
  if [[ $layer != null ]]; then
    configured=true
    enabled=$(jq -r '.enabled' <<<"$layer")
  fi

  if [[ $configured == false ]]; then
    state=orphan
    notes+=("no ${name}.env: remove the build with --remove")
    if [[ $built == false ]]; then notes+=("archive with no manifest entry"); fi
  elif [[ $enabled == false ]]; then
    state=disabled
    notes+=("not enabled in the map config")
    if [[ $built == true ]]; then notes+=("built before: hidden from the map, --remove removes it"); fi
  else
    local env style env_source style_source env_sha style_sha
    {
      IFS= read -r env
      IFS= read -r style
      IFS= read -r env_source
      IFS= read -r style_source
      IFS= read -r env_sha
      IFS= read -r style_sha
    } < <(jq -r '.env, (.style // ""), (.envSource // ""), (.styleSource // ""),
      .envSha256, (.styleSha256 // "")' <<<"$layer")

    local cfg problems=()
    cfg=$(_config_input "$env")
    if [[ ${cfg%%$'\t'*} == ok ]]; then
      cfg=${cfg#*$'\t'}
      type=${cfg%%$'\t'*}
      input=${cfg#*$'\t'}
    else
      problems+=("${cfg#*$'\t'}")
    fi
    [[ -f $style ]] || problems+=("no ${name}.style.json")

    local src="" missing=""
    if [[ -n $input ]] && ! src=$(source_mtime "$input"); then
      missing="source data not found: ${input#"${PIPELINE_INPUT_DIR}"/}"
    fi

    if ((${#problems[@]} > 0)); then
      state=invalid
      notes=("${problems[@]}")
      if [[ -n $missing ]]; then notes+=("$missing"); fi
    elif [[ -n $missing ]]; then
      state="source missing"
      notes=("$missing")
    elif [[ $built == false ]]; then
      state="not built"
      if [[ -n $archive && -f $archive ]]; then notes+=("archive with no manifest entry"); fi
    else
      local recorded_env recorded_style
      read -r recorded_env recorded_style < <(jq -r \
        '"\(.provenance.env_sha256 // "-") \(.provenance.style_sha256 // "-")"' <<<"$entry")
      [[ -f $archive ]] || notes+=("archive missing")
      if [[ $legacy == true ]]; then
        notes+=("built as PNG tiles in ${name}.pmtiles: rebuild it as a COG (ADR 0010)")
      fi
      local mtime
      mtime=$(_newest_mtime "$env_source")
      if ((${mtime:-0} > built_at)); then
        notes+=("${name}.env changed since the build")
      elif [[ $recorded_env != - && $recorded_env != "$env_sha" ]]; then
        notes+=("settings changed since the build (${name}.env or the map config's input or env)")
      fi
      if ((${src:-0} > built_at)); then notes+=("source data changed since the build"); fi
      # The display config against the last display update, so a
      # style-only update neither hides nor fakes a stale build.
      mtime=$(_newest_mtime "$style_source")
      if ((${mtime:-0} > display_at)); then
        restyle="${name}.style.json changed since the display was last updated (--style-only updates it)"
      elif [[ $recorded_style != - && $recorded_style != "$style_sha" ]]; then
        restyle="display config changed since the display was last updated (${name}.style.json or the map config; --style-only updates it)"
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
      configured: $configured, enabled: $layer.enabled, origin: $layer.origin,
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
      tile_count: $entry.tile_count,
      max_tile_bytes: $entry.max_tile_bytes}' \
    --args "${notes[@]}"
}

# layer_status_json OUT_DIR [NAME...]: the status of the named layers, or of
# every layer in the layer set (LAYERS_JSON) or built, as JSON on stdout.
layer_status_json() {
  local out_dir=$1
  shift
  local manifest="${out_dir}/manifest.json" entries='[]'
  if [[ -s $manifest ]]; then
    entries=$(jq -c '.layers // []' "$manifest") || die "cannot read $manifest"
  fi

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
# with each layer's notes under it.
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
        elif .tile_count != null then "\(.tile_count) tiles" else "-" end),
       (.max_tile_bytes | size),
       (.notes | join("\u001f"))]
    | @tsv' | awk -F'\t' '
    # cell(i, s): column i padded to its width, or ending the line.
    function cell(i, s) { if (i < 7) printf("%-" w[i] "s  ", s); else printf("%s\n", s) }
    BEGIN { split("LAYER STATE BUILT SIZE ZOOMS FEATURES MAX_TILE", head, " "); head[7] = "MAX TILE"
            for (i = 1; i <= 7; i++) w[i] = length(head[i]) }
    { n++; for (i = 1; i <= 8; i++) row[n, i] = $i
      for (i = 1; i <= 7; i++) if (length($i) > w[i]) w[i] = length($i) }
    END {
      if (n == 0) { print "no layers configured or built"; exit }
      for (i = 1; i <= 7; i++) cell(i, head[i])
      for (r = 1; r <= n; r++) {
        for (i = 1; i <= 7; i++) cell(i, row[r, i])
        if (row[r, 8] != "") {
          k = split(row[r, 8], notes, "\037")
          for (j = 1; j <= k; j++) printf "  - %s\n", notes[j]
        }
      }
    }'
}
