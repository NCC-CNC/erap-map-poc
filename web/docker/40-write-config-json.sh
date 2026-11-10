#!/bin/sh
# Writes the runtime config the web app fetches from /config.json before it
# creates the map (ADR 0005). Runs at container start from nginx's
# /docker-entrypoint.d/, so the CARTO API key is never baked into the image.
#
# The file goes to /tmp/erap-web, which is writable whatever uid the
# container runs as; nginx.conf serves /config.json from there.
set -eu

out_dir=/tmp/erap-web
out_file="$out_dir/config.json"
key=${CARTO_API_KEY:-}

# A JSON string cannot hold raw control characters, and a real API key never
# contains them, so refuse to start rather than guess (a stray CR from a
# Windows-edited .env is the likely cause).
cleaned=$(printf '%s' "$key" | tr -d '\000-\037\177')
if [ "$cleaned" != "$key" ]; then
  echo "$0: error: CARTO_API_KEY contains control characters (check for a trailing CR or newline)" >&2
  exit 1
fi

# Escape backslashes and double quotes for a JSON string literal.
escaped=$(printf '%s' "$key" | sed -e 's/[\]/&&/g' -e 's/"/\\"/g')

mkdir -p "$out_dir"
tmp_file="$out_file.tmp"
printf '{"cartoApiKey": "%s"}\n' "$escaped" > "$tmp_file"
mv "$tmp_file" "$out_file"

if [ -n "$key" ]; then
  echo "$0: info: wrote $out_file with CARTO_API_KEY set"
else
  echo "$0: info: wrote $out_file with an empty cartoApiKey (CARTO_API_KEY is unset)"
fi
