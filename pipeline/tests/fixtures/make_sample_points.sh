#!/usr/bin/env bash
# Generate sample_points.geojson: a second small synthetic test layer
# (made-up points, no real data). Output is deterministic, so rerunning it
# gives the same file.
#
# 30 points over Canada. Points 1 to 8 sit inside `sample` polygons 1, 3, 5,
# ..., 15 (see make_sample.sh), so the two layers overlap; points 9 to 30 are
# spread over the north, clear of the polygons. Attributes:
#   id        integer, stable feature id (1..30)
#   name      string, made-up bird name
#   category  string, exactly one of alpha, beta, gamma (cycling)
#   count     integer, 1 to 500
#
# Usage: pipeline/tests/fixtures/make_sample_points.sh > pipeline/tests/fixtures/sample_points.geojson
set -euo pipefail

awk 'BEGIN {
  names = "Auk,Bittern,Crane,Dunlin,Eider,Finch,Grebe,Heron,Ibis,Jay,Kestrel,Loon,Merlin,Nuthatch,Osprey,Plover,Quail,Raven,Sandpiper,Tern,Vireo,Warbler,Wren,Avocet,Bunting,Curlew,Dipper,Egret,Flicker,Godwit"
  split(names, name, ",")
  split("alpha,beta,gamma", category, ",")
  printf "{\n\"type\": \"FeatureCollection\",\n\"name\": \"sample_points\",\n\"features\": [\n"
  for (n = 1; n <= 30; n++) {
    if (n <= 8) {
      # Inside sample polygon p: west edge -125 + col * 14, south edge
      # 46 + row * 4, 3 by 2 degrees. Left of centre, so it also lands in
      # the valid part of the bow tie (polygon 7).
      p = 2 * n - 1
      col = (p - 1) % 5; row = int((p - 1) / 5)
      x = -125 + col * 14 + 0.75; y = 46 + row * 4 + 1
    } else {
      k = n - 9
      col = k % 11; row = int(k / 11)
      x = -135 + col * 7 + 0.5; y = 59 + row * 6 + (col % 3)
    }
    count = 1 + (n * 97) % 500
    printf "{\"type\": \"Feature\", \"properties\": {\"id\": %d, \"name\": \"%s\", \"category\": \"%s\", \"count\": %d}, ", n, name[n], category[(n - 1) % 3 + 1], count
    printf "\"geometry\": {\"type\": \"Point\", \"coordinates\": [%.2f, %.2f]}}", x, y
    printf (n < 30 ? ",\n" : "\n")
  }
  printf "]\n}\n"
}'
