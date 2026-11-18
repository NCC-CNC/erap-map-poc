#!/usr/bin/env bash
# Layer files and the map config (design note 04).
#
# A layer is one file, <layer>.yaml in PIPELINE_LAYERS_DIR (committed) or
# PIPELINE_LOCAL_LAYERS_DIR (layers.local/, git-ignored: your own layers,
# built the same way), with `source`, `fields`, `processing` and `display`
# (schema/layer.schema.json). The layer name is the file name; a local
# layer with the name of a committed one is an error. The map config
# (PIPELINE_MAP_CONFIG: your map.config.yaml, or map.pages.yaml for the
# GitHub Pages copy; schema/map.schema.json) picks the layers to build,
# overrides their `source` and `processing`, and sets the map's view,
# basemap, title and number locale.
#
# resolve_layers reads them all once per run, before any data: each file is
# checked with jv against its schema, then by layer_problems for what a
# schema cannot say, and written as JSON with the map config's overrides
# applied. The result, LAYERS_JSON, is:
#
#   { "map": {"center": [lon, lat], "zoom": 3, "minzoom": 2, "maxzoom": 14,
#             "bounds": [w, s, e, n], "basemap": "light", "title": "...",
#             "locale": "en-CA"} (those the map config sets) or null,
#     "require": ["protected_areas"],
#     "layers": [ { "name": "ecoregions", "file": ".../ecoregions.yaml",
#         "origin": "committed" (PIPELINE_LAYERS_DIR) or "local",
#         "config": ".../ecoregions.json" (the effective layer, or null when
#                   the file is not valid),
#         "enabled": true, "problems": [],
#         "overrides": {...} or null,
#         "type": "vector", "input": "/data/raw/ERAP_2026_ecoregions.gdb",
#         "joins": [] (source.joins paths, resolved),
#         "build_sha256": "...", "display_sha256": "..." } ] }
#
# `build_sha256` is the hash of the effective `source`, `fields` and
# `processing`, `display_sha256` that of `title`, `visible`, `order` and
# `display`: a build records both, so --status tells a change that needs a
# rebuild from one that needs only --style-only (lib/status.sh).
#
# load_layer then sets the LAYER_* variables of one layer for a build, in
# its subshell.

LAYER_SCHEMA="${PIPELINE_ROOT}/schema/layer.schema.json"
MAP_SCHEMA="${PIPELINE_ROOT}/schema/map.schema.json"

# The attribute the feature id (`source.id`) is read into. tippecanoe
# writes it as the tile feature id and drops it from the attributes, so it
# never reaches the tiles under this name.
FEATURE_ID_ATTRIBUTE=_feature_id


# Set by resolve_layers: the layers.json of this run.
LAYERS_JSON=""

# layer_name_valid NAME: layer names become file names and URL paths, so keep
# them to lower case letters, digits, `_` and `-`.
layer_name_valid() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# _check_schema SCHEMA FILE: check FILE (YAML or JSON) against SCHEMA with
# jv. On failure print jv's findings, one per line, without its header,
# and return 1.
_check_schema() {
  local output
  if output=$(jv "$1" "$2" 2>&1); then
    return 0
  fi
  # jv prints a header naming the schema, then `- at '/path': message`
  # lines (indented when nested); keep those.
  grep -E "^[[:space:]]*- " <<<"$output" | sed -E 's/^[[:space:]]*- //' \
    || printf '%s\n' "$output"
  return 1
}

# _sha256 FILE: the SHA-256 of FILE, or of stdin for `-`.
_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

# resolve_input PATH: a source path as GDAL and the status checks read it:
# /vsi paths and absolute paths as they are, anything else relative to
# PIPELINE_INPUT_DIR.
resolve_input() {
  if [[ $1 == /* ]]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "$PIPELINE_INPUT_DIR" "$1"
  fi
}

# layer_problems: the problems in a layer (effective JSON on stdin) that
# the schema cannot express, one per line: zooms in order, attribute names
# unique, style layer and theme ids unique, theme paint on a style layer of
# the layer, no tippecanoe option the pipeline sets itself. A legend is
# optional: the web app builds one from the colour expression (design
# note 04).
layer_problems() {
  jq -r --arg fid "$FEATURE_ID_ATTRIBUTE" --argjson reserved "$TIPPECANOE_RESERVED" '
    ((.processing.minzoom // 0) as $min | .processing.maxzoom as $max
      | if $min > $max then "processing: minzoom (\($min)) is above maxzoom (\($max))" else empty end),
    ([(.fields.keep // [])[] | if type == "string" then . else to_entries[0].value end]
      + ((.fields.calculated // {}) | keys_unsorted)) as $names
    | ($names | group_by(.) | map(select(length > 1) | .[0])[]
        | "fields: \(.) is named twice (in fields.keep or fields.calculated)"),
      ($names[] | select(. == $fid) | "fields: \(.) is reserved for the feature id"),
    ([.display.layers[].id] as $ids
      | ($ids | group_by(.) | map(select(length > 1) | .[0])[]
          | "display.layers: id \(.) is used twice"),
        ((.display.themes // []) | to_entries[] | .key as $i | .value.paint // {} | keys[]
          | select(. as $id | $ids | index($id) | not)
          | "display.themes[\($i)].paint: \(.) is not an id in display.layers")),
    ((.display.themes // []) | [.[].id] | group_by(.) | map(select(length > 1) | .[0])[]
      | "display.themes: id \(.) is used twice"),
    ((.processing.tippecanoe // [])[] | select(split("=")[0] | IN($reserved[]))
      | "processing.tippecanoe: \(split("=")[0]) is set by the pipeline")'
}

# The tippecanoe options the pipeline sets itself (lib/tiles.sh), which
# processing.tippecanoe cannot pass.
TIPPECANOE_RESERVED='["--output", "--output-to-directory", "--force", "--layer", "--name",
  "--minimum-zoom", "--maximum-zoom", "--use-attribute-for-id",
  "--temporary-directory", "--quiet", "--read-parallel"]'

# _map_config OUT: check the map config, if any, and write it as JSON to
# OUT ({} for none). Returns 2, after logging why, if it has a problem.
_map_config() {
  local out=$1 config=${PIPELINE_MAP_CONFIG:-} problems
  if [[ -z $config || ! -e $config ]]; then
    # The JSON map config (ADR 0009) is not read any more: say so, rather
    # than build every layer as if there were none.
    local old="${config%/*}/map.config.json"
    if [[ -n $config && $config == */* && -f $old ]]; then
      log_warn "${old} is no longer read: write your map config as ${config##*/} (see map.config.example.yaml)"
    fi
    echo '{}' >"$out"
    return 0
  fi
  if [[ ! -f $config ]]; then
    log_error "map config is not a file: $config"
    return 2
  fi
  if [[ $config == *.json ]]; then
    log_error "map config $config is in the old JSON format, which is no longer read: write it as YAML (see map.config.example.yaml)"
    return 2
  fi
  log_info "map config: $config"
  if ! problems=$(_check_schema "$MAP_SCHEMA" "$config"); then
    local line
    while IFS= read -r line; do log_error "map config: $line"; done <<<"$problems"
    log_error "the map config has problems (above); nothing was changed"
    return 2
  fi
  yq -o json '.' "$config" >"$out" || {
    log_error "cannot read the map config $config"
    return 2
  }
  # What the schema cannot say: the zoom limits and the bounds in order.
  problems=$(jq -r '.view // {}
    | (if .minzoom != null and .maxzoom != null and .minzoom > .maxzoom
       then "view: minzoom (\(.minzoom)) is above maxzoom (\(.maxzoom))" else empty end),
      (if .bounds != null and (.bounds[0] >= .bounds[2] or .bounds[1] >= .bounds[3])
       then "view: bounds are not [west, south, east, north] with west below east and south below north"
       else empty end)' "$out")
  if [[ -n $problems ]]; then
    local line
    while IFS= read -r line; do log_error "map config: $line"; done <<<"$problems"
    log_error "the map config has problems (above); nothing was changed"
    return 2
  fi
}

# resolve_layers OUT_DIR: read every layer file and the map config into
# OUT_DIR and set LAYERS_JSON. A layer file with problems is kept, with its
# problems, so --status can report it and a build of it fails; a problem
# in the map config (or a layer it names that does not exist) returns 2.
resolve_layers() {
  local out=$1 map
  mkdir -p "$out"
  map="${out}/map.json"
  _map_config "$map" || return 2

  local file name origin dir rows=() problems overrides config sha_build sha_display input type joins
  local -A seen=()
  local clashes=() files=()
  # Committed layers first, then your own in layers.local/ (if any).
  for file in "$PIPELINE_LAYERS_DIR"/*.yaml; do files+=("committed|$file"); done
  dir=${PIPELINE_LOCAL_LAYERS_DIR:-}
  if [[ -n $dir && -d $dir ]]; then
    for file in "$dir"/*.yaml; do files+=("local|$file"); done
  fi
  for file in "${files[@]}"; do
    origin=${file%%|*}
    file=${file#*|}
    [[ -f $file ]] || continue
    name=${file##*/}
    name=${name%.yaml}
    if ! layer_name_valid "$name"; then
      log_warn "ignoring ${file##*/}: a layer name has lower case letters, digits, _ and - only"
      continue
    fi
    if [[ -n ${seen[$name]:-} ]]; then
      clashes+=("$file")
      continue
    fi
    seen[$name]=1
    overrides=$(jq -c --arg n "$name" '.overrides[$n] // null' "$map")
    config="" sha_build="" sha_display="" input="" type="" joins="[]"
    # On a schema problem, `problems` holds jv's findings.
    if problems=$(_check_schema "$LAYER_SCHEMA" "$file"); then
      config="${out}/${name}.json"
      yq -o json '.' "$file" | jq --argjson o "$overrides" '
        if $o == null then . else
          .source = ((.source // {}) + ($o.source // {}))
          | .processing = ((.processing // {}) + ($o.processing // {}))
        end' >"$config" || problems="cannot read $file"
      if [[ -z $problems && $overrides != null ]]; then
        problems=$(_check_schema "$LAYER_SCHEMA" "$config" | sed 's/^/with the map config overrides: /') || true
      fi
      if [[ -z $problems ]]; then
        problems=$(layer_problems <"$config")
      fi
      if [[ -n $problems ]]; then
        config=""
      else
        sha_build=$(jq -S -c '{source, fields, processing}' "$config" | _sha256 -)
        sha_display=$(jq -S -c '{title, visible, order, display}' "$config" | _sha256 -)
        input=$(resolve_input "$(jq -r '.source.path' "$config")")
        joins=$(jq -c --arg dir "$PIPELINE_INPUT_DIR" \
          '[(.source.joins // [])[].path | if startswith("/") then . else "\($dir)/\(.)" end]' "$config")
        type=$(jq -r 'if .processing.profile == "raster" then "raster" else "vector" end' "$config")
      fi
    fi
    rows+=("$(jq -n -c --arg name "$name" --arg file "$file" --arg origin "$origin" \
      --arg config "$config" \
      --arg problems "$problems" --argjson overrides "$overrides" \
      --arg build "$sha_build" --arg display "$sha_display" \
      --arg input "$input" --arg type "$type" --argjson joins "$joins" \
      '{name: $name, file: $file, origin: $origin,
        config: (if $config == "" then null else $config end),
        problems: ($problems | split("\n") | map(select(. != ""))),
        overrides: $overrides,
        type: (if $type == "" then null else $type end),
        input: (if $input == "" then null else $input end),
        joins: $joins,
        build_sha256: (if $build == "" then null else $build end),
        display_sha256: (if $display == "" then null else $display end)}')")
  done
  if ((${#clashes[@]} > 0)); then
    for file in "${clashes[@]}"; do
      name=${file##*/}
      log_error "${file}: there is a committed layer called ${name%.yaml} (${PIPELINE_LAYERS_DIR}/${name}): give your layer another name"
    done
    log_error "the local layers have problems (above); nothing was changed"
    return 2
  fi

  LAYERS_JSON="${out}/layers.json"
  printf '%s\n' "${rows[@]}" | jq -s --slurpfile m "$map" '
    $m[0] as $map
    | {map: (($map.view // {})
             + ($map | with_entries(select(.key | IN("basemap", "title", "locale"))))
             | if . == {} then null else . end),
       require: ($map.require // []),
       layers: map(select(. != null) | .enabled = ($map.layers == null
                   or (.name as $n | $map.layers | index($n) != null)))}' >"$LAYERS_JSON" \
    || {
      log_error "cannot resolve the layer files in $(layer_dirs)"
      return 2
    }

  # Every layer the map config names must exist.
  local unknown
  unknown=$(jq -r --slurpfile m "$map" '[.layers[].name] as $known | $m[0] as $map
    | (($map.layers // [])[] | select(. as $n | $known | index($n) | not) | "layers: \(.)"),
      (($map.overrides // {}) | keys[] | select(. as $n | $known | index($n) | not) | "overrides: \(.)"),
      (($map.require // [])[] | select(. as $n | $known | index($n) | not) | "require: \(.)")' \
    "$LAYERS_JSON")
  if [[ -n $unknown ]]; then
    local line
    while IFS= read -r line; do
      log_error "map config: ${line%%: *} names layer '${line#*: }', which has no ${line#*: }.yaml in $(layer_dirs)"
    done <<<"$unknown"
    log_error "the map config has problems (above); nothing was changed"
    return 2
  fi
  local name_off
  name_off=$(jq -r '.layers[] | select(.enabled | not) | .name' "$LAYERS_JSON")
  for name in $(jq -r '.require[]' "$LAYERS_JSON"); do
    if grep -qxF "$name" <<<"$name_off"; then
      log_error "map config: require names layer '$name', which its layers list leaves out"
      log_error "the map config has problems (above); nothing was changed"
      return 2
    fi
  done
}

# layer_dirs: where the layer files are read from, for messages.
layer_dirs() {
  if [[ -n ${PIPELINE_LOCAL_LAYERS_DIR:-} && -d $PIPELINE_LOCAL_LAYERS_DIR ]]; then
    printf '%s or %s\n' "$PIPELINE_LAYERS_DIR" "$PIPELINE_LOCAL_LAYERS_DIR"
  else
    printf '%s\n' "$PIPELINE_LAYERS_DIR"
  fi
}

# layer_names [enabled]: every layer name in the layer set, or only the
# enabled ones, one per line, in name order.
layer_names() {
  jq -r --arg only "${1:-}" '.layers[] | select($only != "enabled" or .enabled) | .name' \
    "$LAYERS_JSON"
}

# layer_get NAME FIELD: a field of NAME's layers.json entry; nothing for
# null or an unknown layer.
layer_get() {
  jq -r --arg n "$1" --arg f "$2" \
    'first(.layers[] | select(.name == $n)) | .[$f] // empty | tostring' "$LAYERS_JSON"
}

# layer_joins NAME: the resolved paths of NAME's source.joins, one per line.
layer_joins() {
  jq -r --arg n "$1" 'first(.layers[] | select(.name == $n)) | (.joins // [])[]' "$LAYERS_JSON"
}

# layer_known NAME: whether NAME has a layer file.
layer_known() {
  jq -e --arg n "$1" 'any(.layers[]; .name == $n)' "$LAYERS_JSON" >/dev/null
}

# layer_enabled NAME: whether NAME has a layer file and the map config
# builds it.
layer_enabled() {
  jq -e --arg n "$1" 'any(.layers[]; .name == $n and .enabled)' "$LAYERS_JSON" >/dev/null
}

# layer_required NAME: whether the map config's `require` names NAME.
layer_required() {
  jq -e --arg n "$1" '.require | index($n) != null' "$LAYERS_JSON" >/dev/null
}

# layer_check NAME: fail (die) with NAME's problems, if any.
layer_check() {
  local name=$1 problems line
  problems=$(jq -r --arg n "$name" 'first(.layers[] | select(.name == $n)) | .problems[]' \
    "$LAYERS_JSON")
  [[ -n $problems ]] || return 0
  while IFS= read -r line; do log_error "${name}.yaml: $line"; done <<<"$problems"
  die "${name}.yaml has problems (above); keeping the previous build"
}

# layer_provenance NAME INPUT: NAME's `provenance` for its build.json entry, as
# compact JSON: where the layer comes from (`origin`: committed, the layers
# dir, or local, layers.local/), its source data (INPUT, the resolved source path: path relative to
# the input dir, total size of its files, newest modification time; null
# fields for a /vsi path), the same for each join table (`joins`, only
# for a layer with joins), the map config's overrides as applied (null for
# none) and the hashes of what it was built from, which --status compares
# (lib/status.sh).
layer_provenance() {
  local name=$1 input=$2 path files=()
  while IFS= read -r path; do
    files+=("$(_provenance_file "$path")")
  done < <(printf '%s\n' "$input"; layer_joins "$name")
  jq -c --arg n "$name" --args \
    'first(.layers[] | select(.name == $n))
     | ($ARGS.positional | map(fromjson)) as $files
     | {origin, source: $files[0]}
       + (if ($files | length) > 1 then {joins: $files[1:]} else {} end)
       + {overrides, build_sha256, display_sha256}' "${files[@]}" <"$LAYERS_JSON"
}

# _provenance_file PATH: PATH (resolved) as {path, bytes, modified_at}, the
# path relative to the input dir; null fields for a /vsi path.
_provenance_file() {
  local input=$1 bytes="" mtime=""
  if mtime=$(source_mtime "$input") && [[ -n $mtime ]]; then
    bytes=$(source_bytes "$input")
  fi
  jq -n -c --arg input "${input#"${PIPELINE_INPUT_DIR}"/}" --arg bytes "$bytes" --arg mtime "$mtime" \
    '{path: $input,
      bytes: (if $bytes == "" then null else ($bytes | tonumber) end),
      modified_at: (if $mtime == "" then null else ($mtime | tonumber | todate) end)}'
}

# load_layer NAME: set the LAYER_* variables from NAME's effective layer
# file (resolve_layers), with the processing preset's defaults. Call only
# inside the per-layer subshell so one layer's settings cannot leak into
# the next. Fails on a layer with problems.
#
#   LAYER_TYPE            vector, or raster for the `raster` profile
#   LAYER_PROFILE         default, coverage, points or raster
#   LAYER_INPUT           source.path, resolved (resolve_input)
#   LAYER_SOURCE_LAYER    source.layer; empty for the first
#   LAYER_SOURCE_SRS      source.srs
#   LAYER_ENCODING        source.encoding
#   LAYER_NODATA          source.nodata
#   LAYER_FEATURE_ID      the attribute holding source.id after normalising
#   LAYER_FIELDS          `src:dest` per attribute read from the source, the
#                         feature id first, then fields.keep
#   LAYER_JOINS           source.joins as JSON, paths resolved; [] for none
#                         (lib/joins.sh)
#   LAYER_CALCULATED_NAMES, LAYER_CALCULATED_EXPRESSIONS
#                         fields.calculated, in file order (lib/calculated.sh)
#   LAYER_MIN_ZOOM, LAYER_MAX_ZOOM
#                         processing.minzoom (default 0) and maxzoom
#   LAYER_MIN_VISIBLE_PX  processing.min_visible_px, default 1 (lib/guard.sh)
#   LAYER_GENERALISE_MAX_ZOOM
#                         coverage: maxzoom - 1, so every zoom below the max
#                         is generalised (lib/generalise.sh); empty otherwise
#   LAYER_GENERALISE_MIN_PART_PX, LAYER_GENERALISE_SIMPLIFY_PX
#                         processing.min_part_px (default 4) and
#                         simplify_px (default 1)
#   LAYER_GREY_LEVELS     processing.grey_levels, default 256 (lib/raster.sh)
#   LAYER_TIPPECANOE_FLAGS
#                         the preset's tippecanoe flags (preset_flags), then
#                         processing.tippecanoe's
# shellcheck disable=SC2034 # the LAYER_* variables are read by bin/run.sh.
load_layer() {
  local name=$1 config
  layer_check "$name"
  config=$(layer_get "$name" config)
  [[ -n $config && -r $config ]] || die "no layer file for $name"

  local settings
  settings=$(jq -r --arg fid "$FEATURE_ID_ATTRIBUTE" '
    [ (.processing.profile // "default"),
      .source.path,
      (.source.layer // ""), (.source.srs // ""), (.source.encoding // ""),
      (.source.nodata // "" | tostring),
      (.processing.minzoom // 0), .processing.maxzoom,
      (.processing.min_visible_px // 1),
      (.processing.min_part_px // 4), (.processing.simplify_px // 1),
      (.processing.grey_levels // 256) ] | map(tostring) | join("\u001f")' "$config") \
    || die "cannot read $config"
  IFS=$'\x1f' read -r LAYER_PROFILE LAYER_INPUT LAYER_SOURCE_LAYER LAYER_SOURCE_SRS \
    LAYER_ENCODING LAYER_NODATA LAYER_MIN_ZOOM LAYER_MAX_ZOOM LAYER_MIN_VISIBLE_PX \
    LAYER_GENERALISE_MIN_PART_PX LAYER_GENERALISE_SIMPLIFY_PX LAYER_GREY_LEVELS <<<"$settings"
  LAYER_INPUT=$(resolve_input "$LAYER_INPUT")

  LAYER_TYPE=vector
  [[ $LAYER_PROFILE != raster ]] || LAYER_TYPE=raster
  LAYER_FEATURE_ID=$FEATURE_ID_ATTRIBUTE
  LAYER_FIELDS=()
  LAYER_CALCULATED_NAMES=()
  LAYER_CALCULATED_EXPRESSIONS=()
  LAYER_JOINS='[]'
  LAYER_GENERALISE_MAX_ZOOM=""
  LAYER_TIPPECANOE_FLAGS=()
  if [[ $LAYER_TYPE == vector ]]; then
    mapfile -t LAYER_FIELDS < <(jq -r --arg fid "$FEATURE_ID_ATTRIBUTE" '
      "\(.source.id):\($fid)",
      ((.fields.keep // [])[] | if type == "string" then "\(.):\(.)"
        else to_entries[0] | "\(.key):\(.value)" end)' "$config")
    # NUL-separated: an expression may span lines.
    mapfile -t LAYER_CALCULATED_NAMES < <(jq -r '(.fields.calculated // {}) | keys_unsorted[]' "$config")
    mapfile -d '' -t LAYER_CALCULATED_EXPRESSIONS < <(jq -j '(.fields.calculated // {})[] | . + "\u0000"' "$config")
    LAYER_JOINS=$(jq -c --arg dir "$PIPELINE_INPUT_DIR" \
      '[(.source.joins // [])[] | .path |= (if startswith("/") then . else "\($dir)/\(.)" end)]' \
      "$config")
    if [[ $LAYER_PROFILE == coverage ]] && ((LAYER_MIN_ZOOM < LAYER_MAX_ZOOM)); then
      LAYER_GENERALISE_MAX_ZOOM=$((LAYER_MAX_ZOOM - 1))
    fi
    # The preset's flags, then processing.tippecanoe's (advanced).
    mapfile -t LAYER_TIPPECANOE_FLAGS < <(preset_flags "$LAYER_PROFILE"
      jq -r '(.processing.tippecanoe // [])[]' "$config")
  fi
}

# preset_flags PROFILE: the tippecanoe flags of a vector processing preset,
# one per line. Every preset keeps the full detail of the source at the max
# zoom (--simplify-only-low-zooms, ADR 0013): lines and polygons are
# simplified at the lower zooms only.
#
#   default   lines and polygons: nothing else, so tippecanoe drops only
#             what its tiny polygon reduction and simplification collapse.
#   coverage  polygons that tile the land without overlaps (shared
#             borders): --no-simplification-of-shared-nodes simplifies each
#             shared border once, identically in both neighbours, so no gaps
#             or slivers open along it; --drop-smallest-as-needed drops the
#             physically smallest polygons first when a tile is too big,
#             never large ones for being in a dense area. The zooms below the
#             max are also generalised first (lib/generalise.sh).
#   points    every point at every zoom: a drop rate of 1 turns off
#             tippecanoe's point thinning below the base zoom.
preset_flags() {
  printf '%s\n' --simplify-only-low-zooms
  case $1 in
    coverage) printf '%s\n' --no-simplification-of-shared-nodes --drop-smallest-as-needed ;;
    points) printf '%s\n' --drop-rate=1 ;;
  esac
}
