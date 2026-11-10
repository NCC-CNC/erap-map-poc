#!/usr/bin/env bash
# Generate a synthetic polygon coverage (made-up features, no real data) for
# the coverage tile profile tests. Output is deterministic, so rerunning it
# gives the same file. The tests generate it on the fly; it is not committed.
#
# A 200 x 100 lattice of 0.1 degree squares over -120..-100, 50..60. Every
# inner lattice point is jittered by up to 0.03 degrees (a fixed hash, not a
# random generator), so every border is an irregular zigzag with a vertex
# every 0.1 degrees. The outer edge stays a straight rectangle. Features are
# unions of lattice squares, so neighbours share exactly the same vertices
# along their common border and nothing overlaps:
#
#   large   18 cells of 40 x 25 squares (5 x 4 grid, less two cells), ids 1..20 except 7, 14
#   medium  cell (3, 2) cut into 40 blocks of 5 x 5 squares, ids 101..140
#   tiny    cell (1, 1) cut into its 1000 single squares, ids 1001..2000
#
# Attributes: id (integer), kind (large, medium or tiny).
#
# Usage: pipeline/tests/fixtures/make_coverage.sh > coverage.geojson
set -euo pipefail

LC_ALL=C awk 'BEGIN {
  W = -120; S = 50; D = 0.1; NX = 200; NY = 100; J = 0.3
  CW = 40; CH = 25
  printf "{\n\"type\": \"FeatureCollection\",\n\"name\": \"coverage\",\n\"features\": [\n"
  first = 1
  for (r = 0; r < 4; r++) {
    for (c = 0; c < 5; c++) {
      i0 = c * CW; j0 = r * CH
      if (c == 1 && r == 1) {
        n = 1000
        for (j = j0; j < j0 + CH; j++)
          for (i = i0; i < i0 + CW; i++)
            feature(++n, "tiny", i, j, i + 1, j + 1)
      } else if (c == 3 && r == 2) {
        n = 100
        for (j = j0; j < j0 + CH; j += 5)
          for (i = i0; i < i0 + CW; i += 5)
            feature(++n, "medium", i, j, i + 5, j + 5)
      } else {
        feature(r * 5 + c + 1, "large", i0, j0, i0 + CW, j0 + CH)
      }
    }
  }
  printf "\n]\n}\n"
}

# Fractional part of a sine hash: a fixed value in [0, 1) per (i, j, k).
function hash(i, j, k,   v) {
  v = sin(i * 12.9898 + j * 78.233 + k * 37.719) * 43758.5453
  return v - int(v) + (v < 0 ? 1 : 0)
}

# Lattice point (i, j) as "[x,y]", jittered unless it is on the outer edge.
function pt(i, j,   x, y) {
  x = W + i * D; y = S + j * D
  if (i > 0 && i < NX) x += (hash(i, j, 1) - 0.5) * 2 * J * D
  if (j > 0 && j < NY) y += (hash(i, j, 2) - 0.5) * 2 * J * D
  return sprintf("[%.5f,%.5f]", x, y)
}

# One feature: the lattice rectangle i0..i1, j0..j1 as a counter-clockwise
# ring through every lattice point on its edge.
function feature(id, kind, i0, j0, i1, j1,   ring, i, j) {
  ring = pt(i0, j0)
  for (i = i0 + 1; i <= i1; i++) ring = ring "," pt(i, j0)
  for (j = j0 + 1; j <= j1; j++) ring = ring "," pt(i1, j)
  for (i = i1 - 1; i >= i0; i--) ring = ring "," pt(i, j1)
  for (j = j1 - 1; j >= j0; j--) ring = ring "," pt(i0, j)
  if (!first) printf ",\n"
  first = 0
  printf "{\"type\": \"Feature\", \"properties\": {\"id\": %d, \"kind\": \"%s\"}, ", id, kind
  printf "\"geometry\": {\"type\": \"Polygon\", \"coordinates\": [[%s]]}}", ring
}'
