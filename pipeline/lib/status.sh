#!/usr/bin/env bash
# Layer status, for `run.sh --status`: which layers are configured, which are
# built, and which builds are out of date. Read only: nothing is written.
#
# Every layer with a config (<layer>.env in the layers dir), a manifest.json
# entry or an archive (<layer>.pmtiles) is listed, in one of these states:
#
#   current    built after its configs and source data last changed.
#   stale      built, but its .env, its .style.json or its source data has
#              changed since (file modification time against the manifest's
#              built_at), or its archive is missing. Rebuild it.
#   not built  configured, but not built yet (or every build failed).
#   invalid    the config cannot be built as it is: the .env does not load,
#              the .style.json is missing, or the source data is not found.
#              A previous build, if any, is still served.
#   orphan     built, but its .env is gone. `run.sh --remove` removes it.
#
# `notes` says why. A change to the pipeline itself does not make a layer
# stale. The JSON (layer_status_json) is:
#
#   { "layers": [ { "name": "sample", "state": "current", "notes": [],
#       "configured": true, "built": true, "type": "vector", "format": "mvt",
#       "input": "...",
#       "built_at": "2026-01-01T00:00:00Z", "archive_bytes": 12345,
#       "minzoom": 0, "maxzoom": 8, "feature_count": 15, "tile_count": null,
#       "max_tile_bytes": 1234 }, ... ] }
#
# Fields from the manifest are null when the layer is not built. `type` is
# the manifest's (vector when an older entry has none), or the config's
# LAYER_TYPE when not built. A raster layer (ADR 0008) has `tile_count` and
# no `feature_count`; a vector layer the other way round. A raster's
# LAYER_INPUT is relative to RAW_DIR (/data/raw) like any input, so its
# source data is checked the same way.

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
  local input=$1 path
  [[ $input != /vsi* ]] || return 0
  if [[ $input =~ ^(.*[.][Zz][Ii][Pp])(/.*)?$ ]]; then
    path=${BASH_REMATCH[1]}
  else
    path=$input
  fi
  if [[ -d $path ]]; then
    find "$path" -type f -printf '%T@\n' | sort -n | tail -n 1 | cut -d. -f1
  elif [[ -f $path ]]; then
    local files=("$path") base=${path##*/} f
    if [[ $base == ?*.* ]]; then
      for f in "${path%.*}".*; do
        if [[ -f $f ]]; then files+=("$f"); fi
      done
    fi
    _newest_mtime "${files[@]}"
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

# _layer_status NAME OUT_DIR LAYERS_DIR ENTRIES: one layer's status object.
# ENTRIES is the manifest's layers array.
_layer_status() {
  local name=$1 out_dir=$2 layers_dir=$3 entries=$4
  local env="${layers_dir}/${name}.env" style="${layers_dir}/${name}.style.json"
  local archive="${out_dir}/${name}.pmtiles"
  local entry built_at=0 configured=false built=false state input="" type="" notes=()

  entry=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // null' <<<"$entries")
  if [[ $entry != null ]]; then
    built=true
    built_at=$(jq -r '(.built_at | fromdateiso8601?) // 0' <<<"$entry")
  fi
  [[ ! -f $env ]] || configured=true

  if [[ $configured == false ]]; then
    state=orphan
    notes+=("no ${name}.env: remove the build with --remove")
    if [[ $built == false ]]; then notes+=("archive with no manifest entry"); fi
  else
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

    local src=""
    if [[ -n $input ]] && ! src=$(source_mtime "$input"); then
      problems+=("source data not found: ${input#"${PIPELINE_INPUT_DIR}"/}")
    fi

    if ((${#problems[@]} > 0)); then
      state=invalid
      notes=("${problems[@]}")
    elif [[ $built == false ]]; then
      state="not built"
      if [[ -f $archive ]]; then notes+=("archive with no manifest entry"); fi
    else
      [[ -f $archive ]] || notes+=("archive missing")
      local mtime
      mtime=$(_newest_mtime "$env")
      if ((${mtime:-0} > built_at)); then notes+=("${name}.env changed since the build"); fi
      mtime=$(_newest_mtime "$style")
      if ((${mtime:-0} > built_at)); then notes+=("${name}.style.json changed since the build"); fi
      if ((${src:-0} > built_at)); then notes+=("source data changed since the build"); fi
      if ((${#notes[@]} > 0)); then state=stale; else state=current; fi
    fi
  fi

  local bytes=""
  if [[ -f $archive ]]; then bytes=$(stat -c %s "$archive"); fi
  if [[ -n $input ]]; then input=${input#"${PIPELINE_INPUT_DIR}"/}; fi

  jq -n -c \
    --arg name "$name" --arg state "$state" \
    --argjson configured "$configured" --argjson built "$built" \
    --arg input "$input" --arg bytes "$bytes" --argjson entry "$entry" \
    --arg type "$type" \
    '{name: $name, state: $state, notes: $ARGS.positional,
      configured: $configured, built: $built,
      type: (if $entry != null then ($entry.type // "vector")
             elif $type != "" then $type else null end),
      format: $entry.format,
      input: (if $input == "" then null else $input end),
      built_at: $entry.built_at,
      archive_bytes: (if $bytes == "" then null else ($bytes | tonumber) end),
      minzoom: $entry.minzoom, maxzoom: $entry.maxzoom,
      feature_count: $entry.feature_count,
      tile_count: $entry.tile_count,
      max_tile_bytes: $entry.max_tile_bytes}' \
    --args "${notes[@]}"
}

# layer_status_json OUT_DIR LAYERS_DIR [NAME...]: the status of the named
# layers, or of every configured or built layer, as JSON on stdout.
layer_status_json() {
  local out_dir=$1 layers_dir=$2
  shift 2
  local manifest="${out_dir}/manifest.json" entries='[]'
  if [[ -s $manifest ]]; then
    entries=$(jq -c '.layers // []' "$manifest") || die "cannot read $manifest"
  fi

  local names=("$@")
  if ((${#names[@]} == 0)); then
    local found=() f
    for f in "$layers_dir"/*.env "$out_dir"/*.pmtiles; do
      [[ -e $f ]] || continue
      f=${f##*/}
      found+=("${f%.*}")
    done
    mapfile -t -O "${#found[@]}" found < <(jq -r '.[].name' <<<"$entries")
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
    rows+=("$(_layer_status "$name" "$out_dir" "$layers_dir" "$entries")")
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
