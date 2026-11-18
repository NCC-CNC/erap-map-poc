#!/usr/bin/env bash
# Publish the GitHub Pages copy of the map (ADR 0014): upload the pipeline
# output in data/pages/ (built with `docker compose run --rm
# pipeline-pages`) to a fixed GitHub release, then start the Pages
# workflow (.github/workflows/pages.yml), which builds the app and serves
# it with those files. Run from Git Bash on Windows, or any bash, with the
# GitHub CLI (`gh`) signed in (`gh auth login`) to an account that can
# write to the repo.
#
# Usage: scripts/publish-pages.sh [options] [DIR]
#
#   DIR             the folder to publish (default data/pages). Never
#                   data/tiles/ or data/raw/: those are refused.
#   -n, --dry-run   run every check and list what would be uploaded and
#                   removed, but change nothing (reads the release only).
#   --no-deploy     upload, but do not start the Pages workflow.
#   --tag TAG       the release that holds the files (default pages-data;
#                   created if missing, not marked as the latest release).
#   -R, --repo OWNER/REPO
#                   the GitHub repo (default: the one this checkout's
#                   remote points to, as `gh repo view` finds it).
#   -h, --help      this help.
#
# Checks before anything is uploaded, each one fatal:
#   - DIR holds manifest.json and style.json, and every archive the
#     manifest names (<layer>.pmtiles, <layer>.cog.tif);
#   - every layer is a committed one (provenance origin `committed`): no
#     local-only layer from a map config;
#   - each layer in REQUIRED_SOURCES below was built from that source
#     (provenance.source.path), so a non-public source is never published;
#   - the files total at most 1 GB, the Pages site limit (a warning over
#     800 MB).
# Only manifest.json, style.json and those archives are uploaded (with
# --clobber); release assets not among them are removed. Exit status: 0 on
# success, 1 when a check or step failed, 2 for a usage error.
set -euo pipefail

# Layers that must come from a given source, as the manifest records it
# (provenance.source.path, relative to RAW_DIR). Keep in step with the
# source overrides and `require` in map.pages.yaml (scripts/tests checks this).
REQUIRED_SOURCES=(
  protected_areas=ProtectedConservedArea_2025.gdb
)

# The Pages site limit is 1 GB; warn before it.
MAX_BYTES=1000000000
WARN_BYTES=800000000
WORKFLOW=pages.yml

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

log() { printf 'publish-pages: %s\n' "$*" >&2; }
fail() {
  log "$*"
  exit 1
}

# mb BYTES: BYTES in MB, one decimal.
mb() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1000000 }'; }

# manifest_layers MANIFEST: one line per layer entry,
# NAME|FILE|ORIGIN|SOURCE_PATH, from the pipeline's manifest.json. It is
# written by jq (two-space indent, one key per line; pipeline/lib/manifest.sh),
# so the layer keys are at six spaces, the provenance keys at eight and the
# source keys at ten. A field not found is empty, which the checks refuse.
manifest_layers() {
  awk '
    function val(s) { sub(/^[^:]*: "/, "", s); sub(/",?[[:space:]]*$/, "", s); return s }
    /^    \{[[:space:]]*$/ { name = ""; file = ""; origin = ""; path = ""; prov = 0; src = 0; inl = 1; next }
    inl && /^    \},?[[:space:]]*$/ { print name "|" file "|" origin "|" path; inl = 0; next }
    !inl { next }
    /^      "name": "/ { name = val($0) }
    /^      "file": "/ { file = val($0) }
    /^      "provenance": \{/ { prov = 1; next }
    prov && /^      [^ ]/ { prov = 0; src = 0 }
    prov && /^        "origin": "/ { origin = val($0) }
    prov && /^        "source": \{/ { src = 1; next }
    src && /^        [^ ]/ { src = 0 }
    src && /^          "path": "/ { path = val($0) }
  ' "$1"
}

# inside PATH DIR: whether PATH is DIR or inside it (both absolute).
inside() {
  case "${1%/}/" in
    "${2%/}/"*) return 0 ;;
  esac
  return 1
}

main() {
  local root
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

  local dir="" dry_run=0 deploy=1 tag=pages-data repo=""
  while (($# > 0)); do
    case $1 in
      -h | --help)
        usage
        return 0
        ;;
      -n | --dry-run) dry_run=1 ;;
      --no-deploy) deploy=0 ;;
      --tag | -R | --repo)
        if (($# < 2)); then
          log "$1 needs a value"
          return 2
        fi
        case $1 in
          --tag) tag=$2 ;;
          *) repo=$2 ;;
        esac
        shift
        ;;
      -*)
        log "unknown option: $1"
        return 2
        ;;
      *)
        if [[ -n $dir ]]; then
          log "one folder only (got $dir and $1)"
          return 2
        fi
        dir=$1
        ;;
    esac
    shift
  done
  [[ $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { log "bad tag: $tag"; return 2; }
  if [[ -n $repo && ! $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    log "bad repo: $repo (OWNER/REPO)"
    return 2
  fi

  # The folder, never the local build or the source data.
  [[ -n $dir ]] || dir="${root}/data/pages"
  [[ -d $dir ]] || fail "no folder $dir: build it first with docker compose run --rm pipeline-pages"
  dir=$(cd "$dir" && pwd -P)
  local banned
  for banned in "${root}/data/tiles" "${root}/data/raw"; do
    if inside "$dir" "$banned"; then
      fail "refusing to publish ${dir}: only the Pages build (data/pages/) is published, never data/tiles/ or data/raw/"
    fi
  done

  local manifest="${dir}/manifest.json"
  [[ -s $manifest ]] || fail "no manifest.json in ${dir}: build it first with docker compose run --rm pipeline-pages"
  [[ -s ${dir}/style.json ]] || fail "no style.json in ${dir}: build it first with docker compose run --rm pipeline-pages"

  # The layers: committed ones only, each archive present.
  local files=(manifest.json style.json) problems=() name file origin path
  local -A source_of=()
  while IFS='|' read -r name file origin path; do
    [[ -n $name ]] || { problems+=("a manifest entry with no name"); continue; }
    source_of[$name]=$path
    if [[ $origin != committed ]]; then
      problems+=("${name}: not a committed layer (origin '${origin}'): the Pages copy has committed layers only")
    fi
    if [[ ! $file =~ ^[a-z0-9][a-z0-9_-]*\.(pmtiles|cog\.tif)$ ]]; then
      problems+=("${name}: unexpected archive name '${file}'")
    elif [[ ! -f ${dir}/${file} ]]; then
      problems+=("${name}: archive ${file} not found in ${dir}")
    else
      files+=("$file")
    fi
  done < <(manifest_layers "$manifest")
  ((${#source_of[@]} > 0)) || problems+=("no layers in ${manifest}")

  # The sources that must be used (and nothing else for those layers).
  local required want
  for required in "${REQUIRED_SOURCES[@]}"; do
    name=${required%%=*}
    want=${required#*=}
    if [[ -z ${source_of[$name]+set} ]]; then
      problems+=("${name}: not in the manifest; the Pages copy needs it, built from ${want}")
    elif [[ ${source_of[$name]} != "$want" ]]; then
      problems+=("${name}: built from '${source_of[$name]}', not ${want}: rebuild with docker compose run --rm pipeline-pages")
    fi
  done

  if ((${#problems[@]} > 0)); then
    local p
    for p in "${problems[@]}"; do log "$p"; done
    fail "nothing was published"
  fi

  # Size: the Pages site limit.
  local total=0 bytes
  for file in "${files[@]}"; do
    bytes=$(wc -c <"${dir}/${file}")
    total=$((total + bytes))
  done
  if ((total > MAX_BYTES)); then
    fail "the files total $(mb "$total"), over the 1 GB GitHub Pages limit: lower a layer's max zoom in map.pages.yaml (ADR 0014)"
  fi
  if ((total > WARN_BYTES)); then
    log "warning: the files total $(mb "$total"), close to the 1 GB GitHub Pages limit"
  fi

  # GitHub: gh, signed in.
  command -v gh >/dev/null 2>&1 \
    || fail "the GitHub CLI (gh) is not installed: https://cli.github.com, then gh auth login"
  gh auth status >/dev/null 2>&1 \
    || fail "gh is not signed in: run gh auth login (an account that can write to the repo)"
  if [[ -z $repo ]]; then
    repo=$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner) \
      || fail "cannot tell the GitHub repo: pass --repo OWNER/REPO"
  fi

  local existing=() release=0 names
  if gh release view "$tag" --repo "$repo" --json tagName >/dev/null 2>&1; then
    release=1
    names=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name') \
      || fail "cannot list the files in release ${tag}"
    mapfile -t existing <<<"$names"
  fi
  local stale=() asset keep
  for asset in "${existing[@]}"; do
    [[ -n $asset ]] || continue
    keep=0
    for file in "${files[@]}"; do
      [[ $asset == "$file" ]] && keep=1
    done
    ((keep)) || stale+=("$asset")
  done

  log "folder ${dir}: ${#files[@]} files, $(mb "$total")"
  for file in "${files[@]}"; do
    log "  upload ${file} ($(mb "$(wc -c <"${dir}/${file}")"))"
  done
  for asset in "${stale[@]}"; do log "  remove ${asset} (no longer built)"; done
  ((release)) || log "release ${tag} not found in ${repo}: it will be created"

  if ((dry_run)); then
    log "dry run: nothing was changed (release ${tag} in ${repo})"
    return 0
  fi

  if ((!release)); then
    gh release create "$tag" --repo "$repo" --latest=false --title "GitHub Pages data" \
      --notes "Map data for the GitHub Pages copy of the map (ADR 0014), uploaded by scripts/publish-pages.sh. Not a software release." \
      >/dev/null || fail "cannot create release ${tag} in ${repo}"
    log "created release ${tag}"
  fi
  # Bare file names from inside the folder: no path conversion in Git Bash.
  (cd "$dir" && gh release upload "$tag" "${files[@]}" --repo "$repo" --clobber) \
    || fail "upload to release ${tag} failed: rerun to try again"
  log "uploaded ${#files[@]} files to release ${tag}"
  for asset in "${stale[@]}"; do
    gh release delete-asset "$tag" "$asset" --repo "$repo" --yes >/dev/null \
      || fail "cannot remove ${asset} from release ${tag}"
    log "removed ${asset}"
  done

  if ((deploy)); then
    gh workflow run "$WORKFLOW" --repo "$repo" --ref main \
      || fail "cannot start ${WORKFLOW}: is GitHub Pages set to GitHub Actions (README)?"
    log "started ${WORKFLOW}; follow it with: gh run watch --repo ${repo} \$(gh run list --repo ${repo} --workflow ${WORKFLOW} --limit 1 --json databaseId --jq '.[0].databaseId')"
  else
    log "not deployed (--no-deploy): gh workflow run ${WORKFLOW} --repo ${repo} --ref main"
  fi
}

main "$@"
