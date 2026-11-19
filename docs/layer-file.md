# Layer file and map config reference

A layer is one YAML file, `pipeline/layers/<layer>.yaml` (committed) or
`pipeline/layers.local/<layer>.yaml` (your own, git-ignored). The file
name is the layer name: lower case letters, digits, `_` and `-`. The
schema is `pipeline/schema/layer.schema.json`; editors with the YAML
language server check a file as you type, from its first line:

```yaml
# yaml-language-server: $schema=../schema/layer.schema.json
```

`docker compose run --rm pipeline --status` lists every problem in every
layer file without building. For a first draft from a dataset, run
`docker compose run --rm --entrypoint inspect.sh pipeline --starter
<data>` ([guide](guide.md#add-a-layer)).

Worked examples: `pipeline/layers/ecoregions.yaml` (themes, a dialog,
calculated fields), `protected_areas.yaml` (one colour, no pop-up),
`forest.yaml` (a raster) and `pipeline/tests/layers/sample.yaml` (a
small pop-up with a chart).

## Top level

| Key | Required | What |
| --- | --- | --- |
| `title` | yes | name in the layer panel |
| `visible` | no | on when the map opens (default `false`) |
| `order` | no | draw order, higher on top and first in the panel (default 0; ties by name) |
| `source` | yes | where the data comes from |
| `fields` | no | vector only: the attributes in the tiles |
| `processing` | yes | how the tiles or the COG are made |
| `display` | yes | how it is drawn and what a click shows |

`source`, `fields` and `processing` decide the build: a change to them
makes the layer `stale` (rebuild it). `title`, `visible`, `order` and
`display` are display only: the next run applies them (`--style-only`
rewrites `style.json` in seconds, no re-tiling).

## source

```yaml
source:
  path: ERAP_2026_ecoregions.gdb   # under RAW_DIR, or absolute
  layer: ERAP_2026_ecoregions      # inside a geodatabase or GeoPackage
  id: OBJECTID                     # unique integer, the feature id
```

| Key | What |
| --- | --- |
| `path` | required. A path under `RAW_DIR`, an absolute path or a GDAL `/vsi` path. A `.zip` is read in place: `data.zip`, or `data.zip/dir/file.shp` for one file in it. |
| `layer` | vector: the layer inside the dataset (default the first) |
| `id` | vector, required: the source attribute holding a unique integer. It becomes the tile feature id and is not repeated as an attribute. |
| `srs` | the source CRS, such as `EPSG:3347`, for data without a usable one |
| `encoding` | vector: attribute encoding, such as `ISO-8859-1`, for a shapefile without a `.cpg` |
| `nodata` | raster: the nodata value, when the file declares none or the wrong one (a number, or `nan`) |
| `joins` | vector: tables to add attributes from (below) |

### joins

Adds attributes from a CSV, or a table in any dataset GDAL opens, matched
by a key attribute with the same name in the source and the table:

```yaml
source:
  path: ecoregions.gdb
  id: OBJECTID
  joins:
    - path: ecoregion_stats.csv
      on: ECOREGION_ID
      fields: [budget, {REGION_NAME: region}]   # default every attribute but the key
```

- A joined attribute is then kept by `fields.keep` by its name after
  `joins[].fields`, and calculated fields can use it.
- Keys match as text: an integer `7` matches `7` and `7.0`. A quoted CSV
  value stays text, so `"007"` keeps its zeros.
- A key found in more than one row, or a joined name the source already
  has, fails the layer. A feature with no row keeps its own attributes.
- A missing table is like missing source data (`source missing`); a
  changed table makes the layer stale.

## fields

Vector only. Everything not listed is dropped, which keeps tiles small.

```yaml
fields:
  keep:
    - ECOREGION_NAME_EN: name     # rename: {source: output}
    - protected_pcnt              # keep as it is
  calculated:
    unprotected_intact_pcnt: round(intact_pcnt - protected_intact_pcnt, 2)
    action_area_based_30x30: coalesce(protected_pcnt < 30, 0)
```

- `keep`: source attributes, in order. Output names are lower case
  letters, digits and `_`; rename anything else.
- `calculated`: new attribute name to a SQLite expression on the kept
  attributes (their output names), run by `ogr2ogr -dialect SQLite`. A
  field can use the ones above it. A comparison gives 1 or 0 (NULL when
  an attribute is NULL, hence `coalesce`), which is how an action
  recommendation is written. Build that one layer (`docker compose run
  --rm pipeline <layer>`) to check them: the log names a failing
  expression, and `--status` lists the calculated fields.

## processing

```yaml
processing:
  profile: coverage
  minzoom: 0
  maxzoom: 12
```

| Key | Applies to | What |
| --- | --- | --- |
| `profile` | all | `default`, `coverage`, `points` or `raster` (default `default`) |
| `minzoom` | all | lowest zoom built (default 0) |
| `maxzoom` | all | required. Highest zoom built; the map overzooms past it up to the map's max zoom (the highest layer max zoom, unless the map config's `view` sets one). Lines and points keep full detail there; polygons are generalised gently (`maxzoom_min_part_px`, `maxzoom_simplify_px`). A raster's resolution too (z12 is about 20 to 27 m across Canada), at most 14. |
| `min_part_px` | polygons (`coverage`, `default`) | below `maxzoom`, drop polygon parts under this many screen pixels; each feature keeps its largest (default 4; 0 for none) |
| `simplify_px` | polygons (`coverage`, `default`) | below `maxzoom`, simplify borders by this many pixels (default 1; 0 for none) |
| `maxzoom_min_part_px` | polygons (`coverage`, `default`) | as `min_part_px`, at `maxzoom` (default 1) |
| `maxzoom_simplify_px` | polygons (`coverage`, `default`) | as `simplify_px`, at `maxzoom` (default 0.5); with `maxzoom_min_part_px: 0` too, `maxzoom` keeps full detail |
| `min_visible_px` | vector | the drop guard fails the build if a polygon this many pixels or larger is missing from a zoom (default 1) |
| `grey_levels` | `raster` | how many shares of cover the COG keeps, 2 to 256 (default 256); fewer compress better |
| `tippecanoe` | vector | advanced: extra tippecanoe options, one per item, such as `--drop-densest-as-needed` or `--maximum-tile-bytes=1000000` |

The profiles:

- `default`: lines and polygons. Lines are simplified below the max zoom
  only; polygons are generalised at every zoom, each on its own, as they
  may overlap (small parts dropped, each feature keeping its largest).
- `coverage`: polygons that tile the land without overlaps, such as
  ecoregions. Shared borders stay identical, the smallest polygons go
  first when a tile is full, and every zoom is generalised as a coverage
  (ADR 0016).
- `points`: every point at every zoom.
- `raster`: a binary raster (one band of 0, 1 and nodata) as one Web
  Mercator COG of the share covered. Display only: no `fields`, no
  pop-up.

`processing.tippecanoe` cannot set what the pipeline sets itself (output,
layer name, zooms, feature id); such an option makes the layer `invalid`.

## display

```yaml
display:
  layers: [...]   # MapLibre style layers
  themes: [...]   # optional "Colour by" choices
  legend: {...}   # optional, not with themes
  popup: {...}    # optional: without one the layer is not clickable
```

### layers

MapLibre style layers, in draw order (last on top), written as they
appear in `style.json` ([MapLibre style spec](https://maplibre.org/maplibre-style-spec/layers/)).
Each has an `id` (short, unique in the layer, such as `fill`) and a
`type`; optional `filter`, `minzoom`, `maxzoom`, `layout`, `paint` and
`metadata`. Leave out `source` and `source-layer`: the pipeline adds them
and prefixes the id with `<layer>-`.

```yaml
layers:
  - id: fill
    type: fill
    paint:
      fill-color:
        [case, ["==", [typeof, [get, protected_pcnt]], number],
         [step, [get, protected_pcnt], "#deebf7", 10, "#9ecae1", 17, "#4292c6", 30, "#08519c"],
         "#bdbdbd"]
      fill-opacity: 0.6
  - id: outline
    type: line
    paint:
      line-color: "#08306b"
      line-width: [interpolate, [linear], [zoom], 0, 0.3, 8, 0.6, 14, 1]
```

Class breaks are written in the expression (`inspect.sh` shows each
field's range). A raster layer is one `color-relief` layer whose colour
is an `interpolate` on `[elevation]`, the share covered from 0 to 255
(see `forest.yaml`).

### themes

"Colour by" choices in the layer panel, at least two. The first is what
`layers` draw and has no `paint`; each other one replaces paint
properties of some style layers, by style layer id. Each can have its
own `legend`.

```yaml
themes:
  - id: protected
    label: Protected (%)
  - id: wtw
    label: Where To Work (%)
    paint:
      fill:
        fill-color: [step, [get, wtw_percent], "#deebf7", 5, "#9ecae1", 20, "#4292c6"]
```

### legend

The app builds a legend from the first fill, line, circle,
fill-extrusion or color-relief layer's colour: one colour (`single`),
`match` (`categories`), `step` (`ramp`) or `interpolate` (`gradient`),
also inside a `case` guard. Give a `legend` (or a theme's `legend`) when
that is not enough, for example to label "No data":

| Key | What |
| --- | --- |
| `items` | required: `{color, label}` swatches in order; in a `gradient`, `position` 0 to 1 places one on the bar |
| `kind` | `single`, `categories`, `ramp` or `gradient` |
| `shape` | `square` (fills), `circle` (points) or `line` |
| `border` | swatch border colour |
| `opacity` | swatch opacity, 0 to 1 |

Parts left out are taken from the derived legend.

### popup

What a click on a feature shows, filled from its tile attributes. Vector
layers only.

| Key | What |
| --- | --- |
| `title` | required: a template, such as `"{name}"`; the layer title when a placeholder has no value |
| `subtitle` | a template line under the title; hidden when a placeholder has no value |
| `size` | `small` (default): one section in a pop-up at the click; `dialog`: sections in a dialog over the map |
| `layout` | dialog only: `tabs` (default), one section at a time, or `scroll` |
| `sections` | required: each with an optional `heading` (required in a dialog), `tab` (a shorter tab label), `description` (a template) and `blocks` |

Templates: `{attribute}` as it is, `{attribute:percent}` in a format
preset, `{$id}` the feature id.

Blocks, each with a `type`:

- `attributes`: `items` of `{label, value, format}`, where `value` is
  `{attribute: name}` or `{featureId: true}`. Items without a value are
  hidden.
- `table`: `columns` (`{label, format}`) and `rows` (`{label, values}`,
  one attribute or `null` per column); optional `caption` and
  `rowHeader`.
- `chart`: `chart` (`bar`, `line`, `pie` or `doughnut`), `title`,
  `valueLabel` (for the accessible summary), `categories`, and `series`
  (`{label, attributes, color}`, one attribute per category). `bar` and
  `line` take several series; `pie` and `doughnut` one, with `colors`
  per slice. Optional `format`.
- `text`: a template paragraph.
- `list`: `items` of `{text, when}`, each shown when its `when`
  attribute is true (not 0, empty, false or no), and `empty` shown when
  none is.

A small pop-up from `sample.yaml`:

```yaml
popup:
  title: "{name}"
  sections:
    - blocks:
        - type: attributes
          items:
            - { label: ID, value: { featureId: true } }
            - { label: Area, value: { attribute: area_ha }, format: { decimals: 1, suffix: ha } }
        - type: chart
          chart: bar
          title: Value by year
          valueLabel: Value
          format: integer
          categories: ["2020", "2021", "2022"]
          series:
            - { label: Value, attributes: [v2020, v2021, v2022] }
```

A dialog: `size: dialog` and a `heading` on every section (see
`ecoregions.yaml`).

### Number formats

A `format` is a preset name or an object:

- `number`: decimals as the value has them, up to 3.
- `integer`: no decimals.
- `percent`: a value from 0 to 100, with 1 decimal and `%`.

An object takes `preset` (default `number`), `decimals`, `grouping`
(thousands separators, on by default) and `suffix` (a unit, after a
space): `{preset: integer, suffix: ha}`, `{decimals: 1, suffix: km}`.
Numbers are formatted in the map's `locale`.

## Map config

Your own, optional `map.config.yaml` at the repo root (git-ignored; copy
`map.config.example.yaml`). `MAP_CONFIG` in `.env` picks another file.
The GitHub Pages copy uses the committed `map.pages.yaml`. Schema:
`pipeline/schema/map.schema.json`. Every key is optional.

```yaml
view: { center: [-96, 60], zoom: 3, minzoom: 2, maxzoom: 14, bounds: [-150, 35, -45, 85] }
basemap: light
title: ERAP Map
locale: fr-CA
layers: [ecoregions, protected_areas, forest]
overrides:
  forest: { processing: { maxzoom: 10 } }
  protected_areas:
    source: { path: ProtectedConservedArea_2025.gdb, layer: ProtectedConservedArea_2025 }
require: [protected_areas]
```

| Key | What |
| --- | --- |
| `view` | the opening `center` (`[lon, lat]`) and `zoom` (unless the URL has a view), and optional `minzoom`, `maxzoom` and `bounds` (`[west, south, east, north]`) the map cannot go past. Without `maxzoom`, the map zooms in as far as the highest `processing.maxzoom` of the layers built |
| `basemap` | `light` or `dark` |
| `title` | the page title (default ERAP Map) |
| `locale` | the locale numbers are shown in, such as `en-CA` (default) or `fr-CA`; the app's own text stays English |
| `layers` | the layers to build (default every layer) |
| `overrides` | per layer, `source` and `processing` keys that replace the layer file's |
| `require` | layers whose source must exist: the build fails rather than skip them |

A change to `view`, `basemap`, `title` or `locale`, or a layer taken out
of `layers`, is applied with `--style-only`; a layer added to `layers`
needs a build, and a change to `overrides` makes the layer stale.
