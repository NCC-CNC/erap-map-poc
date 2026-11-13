#!/usr/bin/env bash
# Calculated fields and action recommendation rules (ADR 0011): attributes
# derived at build time from a vector layer's own attributes, so the web app
# only displays tile attributes.
#
#   LAYER_CALCULATED  `name=expression` entries (lib/config.sh): each adds
#                     the attribute `name`.
#   LAYER_RULES       a rules table, <table>.rules.json (schema
#                     schema/action-rules.schema.json). Per action it adds
#                     action_<id> (1 when its condition is true, else 0) and
#                     action_<id>_reason ("<title>: <reason>" when
#                     recommended, else none), and per action type
#                     actions_<type>_count (how many of its actions are
#                     recommended).
#
# The expressions are checked and turned into SQL by the display config
# tool (style/derive.mjs): only the expression language is accepted, every
# attribute name is quoted and nothing else is passed through, so a config
# cannot run a statement, a subquery or an arbitrary function. GDAL's
# SQLite dialect then evaluates them on the normalised GeoJSONSeq, in one
# ogr2ogr pass that keeps every attribute and the geometry as they are.
# The plan is checked before the source data is read, so a bad expression
# or rules table costs nothing and keeps the previous build.

# layer_derives: whether the loaded layer config (load_layer_config) has
# calculated fields or a rules table.
layer_derives() {
  ((${#LAYER_CALCULATED[@]} > 0)) || [[ -n $LAYER_RULES ]]
}

# layer_config_dir NAME: the folder LAYER_RULES names are relative to: that
# of NAME's .env (layer set, lib/mapconfig.sh), or of the map config for a
# layer defined in it.
layer_config_dir() {
  local source config
  source=$(layer_get "$1" envSource)
  if [[ -n $source ]]; then
    dirname -- "$source"
    return
  fi
  config=$(jq -r '.config // empty' "$LAYERS_JSON")
  if [[ -n $config ]]; then dirname -- "$config"; else printf '%s\n' "$PIPELINE_LAYERS_DIR"; fi
}

# rules_file VALUE DIR: the path of the rules table LAYER_RULES VALUE names,
# relative to DIR: <VALUE>.rules.json for a bare name, else VALUE as a path.
# Nothing for an empty VALUE.
rules_file() {
  local value=$1 dir=$2
  if [[ -z $value ]]; then
    return 0
  elif [[ $value =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    printf '%s/%s.rules.json\n' "$dir" "$value"
  elif [[ $value == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$dir" "$value"
  fi
}

# file_sha256 FILE: the SHA-256 of FILE's content.
file_sha256() {
  sha256sum -- "$1" | cut -d ' ' -f 1
}

# derive_plan NAME TABLE OUT: check the loaded layer config's calculated
# fields and rules table against its attributes and write the plan (the SQL
# on the data's table TABLE and what it adds; style/derive.mjs) to OUT.
derive_plan() {
  local name=$1 table=$2 out=$3
  local dir="${out%/*}" rules="" field dests=()
  rules=$(rules_file "$LAYER_RULES" "$(layer_config_dir "$name")")
  if [[ -n $rules && ! -f $rules ]]; then
    die "rules table not found: $rules (LAYER_RULES=$LAYER_RULES)"
  fi
  for field in "${LAYER_FIELDS[@]}"; do dests+=("${field#*:}"); done
  jq -n '$ARGS.positional' --args "${dests[@]}" >"${dir}/derive_fields.json"
  jq -n '$ARGS.positional' --args "${LAYER_CALCULATED[@]}" >"${dir}/derive_calculated.json"
  _display_tool derive "$out" "$table" "${dir}/derive_fields.json" \
    "${dir}/derive_calculated.json" "${rules:--}" \
    || die "invalid calculated fields or rules table (above); keeping the previous archive and manifest entry"
  if [[ -n $rules ]]; then
    jq --arg file "$rules" --arg sha "$(file_sha256 "$rules")" \
      '.rules += {file: $file, sha256: $sha}' "$out" >"${out}.tmp" && mv "${out}.tmp" "$out"
  fi
  local added
  added=$(jq -r '.attributes | join(", ")' "$out")
  log_info "derived attributes ok: ${added}"
}

# derive_apply DATA PLAN: add the plan's attributes to DATA (GeoJSONSeq, the
# normalised layer, table name = file name without extension) in place.
derive_apply() {
  local data=$1 plan=$2 tmp="${1%.geojsonl}.derived.geojsonl"
  ogr2ogr -f GeoJSONSeq -dialect SQLite -sql "$(jq -r '.sql' "$plan")" "$tmp" "$data" \
    || die "cannot evaluate the calculated fields and rules"
  mv -- "$tmp" "$data"
}

# derive_report DATA PLAN: the build report part (JSON, on stdout) for the
# derived attributes in DATA: per calculated field its expression, non-null
# count, min and max; for the rules table, its file and hash, each action
# with the features it is recommended for and each type with the features
# with at least one of its actions. Empty object when there is no plan.
derive_report() {
  local data=$1 plan=$2
  jq -n -c --slurpfile plan "$plan" '
    $plan[0] as $p
    | ([$p.calculated[].name]) as $calc
    | ([$p.rules.actions[]?.attribute]) as $acts
    | ([$p.rules.types[]?.attribute]) as $types
    | reduce (inputs | .properties) as $f (
        {calc: {}, acts: {}, types: {}};
        reduce $calc[] as $n (.;
          $f[$n] as $v
          | if $v == null then . else
              .calc[$n] |= (.non_null = ((.non_null // 0) + 1)
                | if ($v | type) == "number"
                  then .min = ([.min // $v, $v] | min) | .max = ([.max // $v, $v] | max)
                  else . end)
            end)
        | reduce $acts[] as $a (.; .acts[$a] += (if $f[$a] == 1 then 1 else 0 end))
        | reduce $types[] as $t (.; .types[$t] += (if ($f[$t] // 0) > 0 then 1 else 0 end)))
    | . as $s
    | {calculated_fields: (if ($calc | length) == 0 then null else
         [$p.calculated[] | . + {non_null: ($s.calc[.name].non_null // 0),
                                min: $s.calc[.name].min, max: $s.calc[.name].max}] end),
       rules: (if $p.rules == null then null else
         $p.rules
         | .actions |= map(. + {recommended: ($s.acts[.attribute] // 0)})
         | .types |= map(. + {features: ($s.types[.attribute] // 0)}) end)}
  ' "$data" || die "cannot count the derived attributes in $data"
}

# derive_summary REPORT: one log line for the build report part.
derive_summary() {
  jq -r '[
      (if .calculated_fields then "calculated: \([.calculated_fields[].name] | join(", "))" else empty end),
      (if .rules then "rules \(.rules.file | split("/") | last): "
         + ([.rules.types[] | "\(.id) \(.features)"] | join(", "))
         + " feature(s) with an action" else empty end)
    ] | join("; ")' <<<"$1"
}
