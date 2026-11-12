#!/usr/bin/env bash
# Make a small synthetic binary raster (made-up, no real data) for the raster
# layer tests. Written at test time, never committed (*.tif is git-ignored).
#
# 400 x 300 cells of 1 km in Canada Albers (WGS 84), like the real binary
# rasters but coarser, in the strip layout (1-row blocks) they come in. Cells
# are 1 inside four rectangles and a checkerboard block; the rest is 0 or
# nodata, in two styles:
#
#   byte    Byte, 1 only, nodata 255 elsewhere (like the forest raster).
#   float   Float32 0/1, nodata NaN in the left quarter (like the
#           agriculture raster).
#   empty   Byte, nodata everywhere (no 1 cells at all).
#
# Usage: make_raster.sh byte|float|empty OUT.tif
set -euo pipefail

kind=$1 out=$2
crs='+proj=aea +lat_0=40 +lon_0=-96 +lat_1=50 +lat_2=70 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs'
# Origin near Winnipeg; 400 km x 300 km.
west=100000 north=1500000
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case $kind in
  byte | empty) gdal_create -q -of GTiff -ot Byte -outsize 400 300 -bands 1 -burn 255 -a_nodata 255 \
    -a_srs "$crs" -a_ullr "$west" "$north" $((west + 400000)) $((north - 300000)) \
    -co BLOCKYSIZE=1 "${tmp}/base.tif" ;;
  float) gdal_create -q -of GTiff -ot Float32 -outsize 400 300 -bands 1 -burn 0 -a_nodata nan \
    -a_srs "$crs" -a_ullr "$west" "$north" $((west + 400000)) $((north - 300000)) \
    -co BLOCKYSIZE=1 "${tmp}/base.tif" ;;
  *)
    echo "usage: make_raster.sh byte|float|empty OUT.tif" >&2
    exit 2
    ;;
esac

if [[ $kind != empty ]]; then
  # Rectangles of 1 (Albers metres): two large, two small, and a 10 x 10
  # checkerboard of 2 km squares, which averages to half cover at low zooms.
  {
    printf 'id,wkt\n'
    printf '1,"POLYGON((120000 1480000,220000 1480000,220000 1380000,120000 1380000,120000 1480000))"\n'
    printf '2,"POLYGON((300000 1450000,480000 1450000,480000 1250000,300000 1250000,300000 1450000))"\n'
    printf '3,"POLYGON((250000 1300000,256000 1300000,256000 1294000,250000 1294000,250000 1300000))"\n'
    printf '4,"POLYGON((130000 1260000,133000 1260000,133000 1257000,130000 1257000,130000 1260000))"\n'
    local_id=5
    for ((i = 0; i < 10; i++)); do
      for ((j = 0; j < 10; j++)); do
        if (((i + j) % 2 == 0)); then
          x=$((140000 + i * 2000)) y=$((1340000 - j * 2000))
          printf '%d,"POLYGON((%d %d,%d %d,%d %d,%d %d,%d %d))"\n' "$local_id" \
            "$x" "$y" $((x + 2000)) "$y" $((x + 2000)) $((y - 2000)) "$x" $((y - 2000)) "$x" "$y"
          local_id=$((local_id + 1))
        fi
      done
    done
  } >"${tmp}/shapes.csv"
  # The CSV has no CRS; its coordinates are the raster's.
  gdal_rasterize -q -burn 1 -oo GEOM_POSSIBLE_NAMES=wkt \
    "${tmp}/shapes.csv" "${tmp}/base.tif"
fi

if [[ $kind == float ]]; then
  # Nodata (NaN) over the left quarter, over part of rectangle 1.
  printf 'id,wkt\n1,"POLYGON((100000 1500000,200000 1500000,200000 1200000,100000 1200000,100000 1500000))"\n' \
    >"${tmp}/nodata.csv"
  gdal_rasterize -q -burn nan -oo GEOM_POSSIBLE_NAMES=wkt \
    "${tmp}/nodata.csv" "${tmp}/base.tif"
fi

mv "${tmp}/base.tif" "$out"
