#!/usr/bin/env bash
# Generate a synthetic polygon coverage with many small islands (made-up
# features, no real data) for the low-zoom generalisation tests. Output is
# deterministic. The tests generate it on the fly; it is not committed.
#
# Everything lies in -100..-97.6, 50..52, inside a single tile at z0 to z6.
#
#   id 1, 2  mainland: two blocks over 50..51 (-100..-99 and -99..-98)
#            sharing a zigzag border along -99 (a vertex every 0.01
#            degrees, 0.005 degrees either side), each a MultiPolygon with
#            12 islands to its north:
#              8 small squares, 0.02 degrees (about 1/12 px at z4, 1/3 at
#                z5, 1.3 at z6, measured in EPSG:3857 at 256 px tiles),
#              3 medium squares, 0.05 degrees (about 0.5 px at z4, 2 at z5,
#                8 at z6),
#              1 large square, 0.2 degrees (about 8 px at z4, 33 at z5).
#   id 3     islets: 5 squares of 0.02 down to 0.012 degrees and nothing
#            else, so its largest part is small.
#
# Attributes: id (integer), name.
#
# Usage: pipeline/tests/fixtures/make_islands.sh > islands.geojson
set -euo pipefail

LC_ALL=C awk 'BEGIN {
  printf "{\n\"type\": \"FeatureCollection\",\n\"name\": \"islands\",\n\"features\": [\n"
  for (f = 1; f <= 2; f++) {
    x0 = (f == 1) ? -99.95 : -98.95
    parts = mainland(f)
    for (i = 0; i < 8; i++) parts = parts ", " square(x0 + i * 0.1, 51.3, 0.02)
    for (i = 0; i < 3; i++) parts = parts ", " square(x0 + i * 0.25, 51.5, 0.05)
    parts = parts ", " square(x0 + 0.3, 51.7, 0.2)
    feature(f, "mainland " f, parts)
  }
  parts = ""
  for (i = 0; i < 5; i++)
    parts = parts (i ? ", " : "") square(-97.95 + i * 0.07, 51.3, 0.02 - i * 0.002)
  feature(3, "islets", parts)
  printf "]\n}\n"
}

function pt(x, y) { return sprintf("[%.4f, %.4f]", x, y) }

# The shared border from (-99, 50) to (-99, 51) going north (dir 1), or the
# same points in reverse (dir -1), so both blocks have the same vertices.
function border(dir,   n, i, k, s) {
  n = 100; s = ""
  for (i = 0; i <= n; i++) {
    k = (dir > 0) ? i : n - i
    s = s (i ? ", " : "") pt(-99 + ((k == 0 || k == n) ? 0 : ((k % 2) ? 0.005 : -0.005)), 50 + k / n)
  }
  return s
}

# Counter-clockwise outer rings.
function mainland(f) {
  if (f == 1)
    return "[[" pt(-100, 50) ", " border(1) ", " pt(-100, 51) ", " pt(-100, 50) "]]"
  return "[[" pt(-99, 50) ", " pt(-98, 50) ", " pt(-98, 51) ", " border(-1) "]]"
}

function square(x, y, d) {
  return "[[" pt(x, y) ", " pt(x + d, y) ", " pt(x + d, y + d) ", " pt(x, y + d) ", " pt(x, y) "]]"
}

function feature(id, name, parts) {
  printf "{ \"type\": \"Feature\", \"properties\": { \"id\": %d, \"name\": \"%s\" }, \"geometry\": { \"type\": \"MultiPolygon\", \"coordinates\": [%s] } }%s\n", id, name, parts, (id < 3) ? "," : ""
}'
