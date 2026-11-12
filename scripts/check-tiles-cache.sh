#!/usr/bin/env bash
# Check that the web server makes the browser revalidate manifest.json and
# style.json, so a page reload picks up a rebuild or `pipeline --style-only`
# (#53): each is served with `Cache-Control: no-cache` and an ETag, answers
# 304 to that ETag while unchanged, and 200 with the new content once the
# file changes. Run by the web smoke test in CI.
#
# Usage: scripts/check-tiles-cache.sh BASE_URL TILES_DIR
#   BASE_URL   the web app, for example http://127.0.0.1:8080
#   TILES_DIR  a scratch host directory, not data/tiles, mounted as the
#              web container's /srv/tiles. The script writes a test
#              manifest.json and style.json into it.
set -euo pipefail

if (($# != 2)); then
  echo "usage: scripts/check-tiles-cache.sh BASE_URL TILES_DIR" >&2
  exit 2
fi
base=${1%/} tiles=$2

fail() {
  echo "check-tiles-cache: $*" >&2
  exit 1
}

# put FILE CONTENT: write TILES_DIR/FILE atomically, readable by nginx.
put() {
  printf '%s\n' "$2" >"$tiles/$1.tmp"
  chmod a+r "$tiles/$1.tmp"
  mv -f "$tiles/$1.tmp" "$tiles/$1"
}

# fetch FILE [ETAG]: the response to a GET of /tiles/FILE (revalidating
# ETAG if given), headers and body, with CRs removed. Everything goes
# through stdout, so it works with a native Windows curl in Git Bash too.
fetch() {
  local args=(-sS -i)
  [[ -z ${2:-} ]] || args+=(-H "If-None-Match: $2")
  curl "${args[@]}" "$base/tiles/$1" | tr -d '\r'
}

# status_of RESPONSE: its HTTP status code.
status_of() {
  awk 'NR == 1 { print $2; exit }' <<<"$1"
}

# header_of RESPONSE NAME: the value of header NAME (lower case).
header_of() {
  awk -v name="$2" 'NF == 0 { exit } tolower($0) ~ "^" name ":" { sub(/^[^:]*: */, ""); print; exit }' <<<"$1"
}

# etag_of FILE: check FILE's headers and print its ETag.
etag_of() {
  local response etag
  response=$(fetch "$1") || fail "cannot fetch /tiles/$1"
  [[ $(status_of "$response") == 200 ]] || fail "/tiles/$1: HTTP $(status_of "$response")"
  [[ $(header_of "$response" cache-control) == no-cache ]] \
    || fail "/tiles/$1 is not served with Cache-Control: no-cache"
  etag=$(header_of "$response" etag)
  [[ -n $etag ]] || fail "/tiles/$1 has no ETag"
  printf '%s\n' "$etag"
}

put manifest.json '{"layers": []}'
put style.json '{"version": 8, "sources": {}, "layers": []}'

manifest_etag=$(etag_of manifest.json)
style_etag=$(etag_of style.json)
[[ $(status_of "$(fetch manifest.json "$manifest_etag")") == 304 ]] \
  || fail "manifest.json: no 304 while unchanged"
[[ $(status_of "$(fetch style.json "$style_etag")") == 304 ]] \
  || fail "style.json: no 304 while unchanged"

# A changed manifest is served in full; the unchanged style still gets 304.
put manifest.json '{"layers": [], "updated_at": "changed by check-tiles-cache"}'
response=$(fetch manifest.json "$manifest_etag")
[[ $(status_of "$response") == 200 ]] || fail "manifest.json: a change was not served on revalidation"
[[ $response == *'changed by check-tiles-cache'* ]] || fail "manifest.json: served stale after a change"
[[ $(status_of "$(fetch style.json "$style_etag")") == 304 ]] \
  || fail "style.json: no 304 while unchanged"
echo "manifest.json and style.json: no-cache, revalidated, changes served"
