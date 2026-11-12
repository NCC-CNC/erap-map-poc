#!/usr/bin/env bash
# Generate sample.geojson: a small synthetic test layer (made-up features, no
# real data). Output is deterministic, so rerunning it gives the same file.
#
# 15 rectangles laid out on a 5 x 3 grid over southern Canada. Attributes:
#   id          integer, stable feature id (1..15)
#   NAME_EN     string, renamed to `name` by pipeline/tests/layers/sample.env
#   area_ha     number, made-up area in hectares
#   score       number, 0 to 100
#   v2020..v2024 integers, a short series for a pop-up chart
#   notes       string, dropped by the layer config (tests attribute selection)
#
# Feature 7 is a self-intersecting "bow tie" so the pipeline's make-valid step
# has something to fix.
#
# Usage: pipeline/tests/fixtures/make_sample.sh > pipeline/tests/fixtures/sample.geojson
set -euo pipefail

awk 'BEGIN {
  names = "Alder,Birch,Cedar,Dogwood,Elm,Fir,Garry Oak,Hemlock,Ironwood,Juniper,Larch,Maple,Nannyberry,Oak,Pine"
  split(names, name, ",")
  printf "{\n\"type\": \"FeatureCollection\",\n\"name\": \"sample\",\n\"features\": [\n"
  n = 0
  for (row = 0; row < 3; row++) {
    for (col = 0; col < 5; col++) {
      n++
      w = -125 + col * 14; s = 46 + row * 4; e = w + 3; t = s + 2
      area = 1000 + (n * 7919) % 50000
      score = (n * 37) % 101
      base = 100 + (n * 53) % 400
      if (n == 7) {
        ring = sprintf("[[%d,%d],[%d,%d],[%d,%d],[%d,%d],[%d,%d]]", w, s, e, t, e, s, w, t, w, s)
      } else {
        ring = sprintf("[[%d,%d],[%d,%d],[%d,%d],[%d,%d],[%d,%d]]", w, s, e, s, e, t, w, t, w, s)
      }
      printf "{\"type\": \"Feature\", \"properties\": {\"id\": %d, \"NAME_EN\": \"%s\", \"area_ha\": %d.5, \"score\": %d, ", n, name[n], area, score
      printf "\"v2020\": %d, \"v2021\": %d, \"v2022\": %d, \"v2023\": %d, \"v2024\": %d, ", base, base + (n % 5) * 10, base + (n % 3) * 25, base - (n % 4) * 15, base + (n % 7) * 12
      printf "\"notes\": \"synthetic feature %d\"}, \"geometry\": {\"type\": \"Polygon\", \"coordinates\": [%s]}}", n, ring
      printf (n < 15 ? ",\n" : "\n")
    }
  }
  printf "]\n}\n"
}'
