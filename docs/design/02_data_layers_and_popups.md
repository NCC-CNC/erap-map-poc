# 02 Data, Layers and Pop-ups

Status: first real layers in (#58). The four play data layers, their
styling and the ecoregion modal follow the decisions in #14 (Decisions
from #14, below); licences, provenance, update frequency and stable ids
are still TBC (#13, Open questions). This note is the data contract
between the pipeline and the web app; fill it in per layer as each is
confirmed, and change pipeline and web app together when it changes.

## Layer inventory

| Layer id | Source dataset | Format | Geometry | Approx. size | Feature id | Licence, provenance, updates | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sample` | Synthetic test fixture (`pipeline/tests/fixtures/sample.geojson`) | GeoJSON | Polygon | 15 features, about 5 KB | `id` | Made up | Test layer (`pipeline/tests/layers/`), not built by default |
| `sample_points` | Synthetic test fixture (`pipeline/tests/fixtures/sample_points.geojson`) | GeoJSON | Point | 30 features, about 5 KB | `id` | Made up | Test layer (`pipeline/tests/layers/`), not built by default |
| `forest` | Play data, `Forest_AAFC_LUTS_2020_NFIS_2022_30m.tif` (via `RAW_DIR`) | GeoTIFF | Binary raster | 200,792 x 131,690 cells, 620 MB | None (raster) | TBC | Built locally: `forest.cog.tif`, 2.27 GB, about 10 min (ADR 0010) |
| `agriculture` | Play data, `HM_CA_ag2022_r90_merged_prj_30_binary.tif` (via `RAW_DIR`) | GeoTIFF | Binary raster | 235,461 x 137,833 cells, 1.3 GB | None (raster) | TBC | Built locally: `agriculture.cog.tif`, 0.38 GB, about 9 min (ADR 0010) |
| `protected_areas` | Play data, `protected_areas.gdb`, layer `cpcad_ncc_dslv_2025` (CPCAD 2025, dissolved; via `RAW_DIR`) | File geodatabase | MultiPolygon, no attributes | 112,050 features, 130 MB | `OBJECTID` (stable id TBC) | TBC | Built locally: `protected_areas.pmtiles`, 70 MB, about 23 min |
| `ecoregions` | Play data, `ERAP_2026_ecoregions.gdb`, layer `ERAP_2026_ecoregions` (via `RAW_DIR`) | File geodatabase | MultiPolygon, a coverage | 149 features, 72 attributes, 43 MB | `OBJECTID` (`ECOREGION_ID` is text; stable id TBC) | TBC | Built locally: `ecoregions.pmtiles`, 21 MB, about 6 min |

## Per-layer contract

Copy this block for each layer.

### `{{layer_id}}`

- Source: {{where it comes from, licence, update frequency}}.
- Pipeline steps: {{filters, reprojection, simplification, joins}}.
- Tile settings: zoom range {{min to max}}, profile {{`coverage` for a
  contiguous polygon coverage, or none}}, tippecanoe flags
  {{e.g. `--drop-densest-as-needed`}}, drop guard threshold
  {{`LAYER_MIN_VISIBLE_PX`, default 1}}.
- Feature id: {{attribute used as a stable id, needed for sidecar lookups and
  feature state}}.
- Attributes kept in tiles: {{name, type, meaning}}.
- Display (`pipeline/layers/<layer>.style.json`): {{title, draw order,
  shorthand or raw style layers, colour ramp, classification breaks,
  labels, legend, shown by default or not}}.
- Pop-up:
  - Title: {{attribute or template}}.
  - Stats: {{list of stats and their formatting}}.
  - Plots: {{chart type, x and y, data source}}.

A layer is two files in `pipeline/layers/`: `<layer>.env` (processing, see
Input options) and `<layer>.style.json` (display, next section). Nothing
about a layer is written in `web/`: the app reads it all from
`manifest.json` at startup (ADR 0007).

## Display config (`<layer>.style.json`)

How the map shows a layer. The JSON Schema is
`pipeline/schema/layer-style.schema.json`; start a file with
`"$schema": "../schema/layer-style.schema.json"` for checking and completion
in an editor. Fields:

- `title` (required): the name in the layer list and legend.
- `defaultVisible` (required): whether the layer starts switched on.
- `order` (optional, integer, default 0): draw order. Layers are drawn in
  ascending `order`, ties broken by layer name; the highest is drawn on top,
  wins pop-up clicks where features overlap, and is listed first.
- `popup` (optional): the pop-up shown when a feature is clicked; without
  one the layer is not clickable. `title` and each stat `value` are a value
  source, `{"attribute": "name"}` or `{"featureId": true}` (the vector tile
  feature id); a missing title falls back to the layer title. `stats` is a
  list of `{label, value, format}`, where the optional `format` makes the
  value a number (Number formats, below). `charts` (optional)
  is a list of `{type: "bar" | "line", title, valueLabel, points}`, each
  point a `{label, attribute}`. Missing values show as "Not available".
- `modal` (optional, in place of `popup`): click details in a dialog,
  from one template per layer (Click modal, below). A layer has a `popup`
  or a `modal`, not both.
- Exactly one of:
  - `symbology`: the shorthand. Polygons (`geometry: "polygon"`, a fill at
    `fillOpacity` with an `outline`) or points (`geometry: "point"`, circles
    of `radius` with a `stroke`), coloured by `color`: `single`,
    `categorical` (MapLibre `match` on a text attribute, with a `fallback`),
    `stepped` (MapLibre `step` on a numeric attribute, guarded so
    features without a number take the `fallback`) or `interpolated` (a
    gradient, below). A stepped colour has
    either explicit `stops` (`from` ascending, the last class up to `max`,
    which is for the legend only) or `breaks` plus `colors` (below). In
    place of `color`, `themes` gives several colour rules to switch between
    in the map (Colour themes, below). The
    shorthand expands to style layers with ids `fill` and `outline`, or
    `circle`. A raster layer (`LAYER_TYPE=raster`) takes only the raster
    shorthand, `geometry: "raster"` with `color` (`#rrggbb`), `opacity` and
    an optional legend `label` (default the title); see Raster layers.
  - `layers`: raw MapLibre style-spec layers for a vector layer, in draw
    order, without `source` or `source-layer` (filled in from the layer).
    Any vector layer type (`fill`, `line`, `symbol`, `circle`, `heatmap`,
    `fill-extrusion`), with expressions, zoom functions, filters, labels and
    so on. Ids must be unique within the file.
- `legend` (optional): explicit legend `items` (`color`, `label`, and for
  a gradient a `position` from 0 to 1), with
  optional `kind` (`single`, `categories`, `ramp`, `gradient`), `shape` (`square`,
  `circle`, `line`), `border` and `opacity`. Without it the legend is
  derived: from the shorthand exactly as before; from raw `layers`, from the
  colour of the first fill, circle or line layer when it is a constant, a
  `match` or a `step` with constant colours (optionally inside a `case`
  guard, whose fallback is then left out). Anything else (for example an
  `interpolate`) fails the build asking for an explicit `legend`. Fields
  left out of an explicit legend come from the derived one when there is
  one.

Style layer ids are prefixed with `<layer>-` on the map and in `style.json`
(`sample-fill`, `sample_points-circle`), so ids never clash between layers.

Data-driven breaks: a `stepped` colour can give
`"breaks": {"method": "quantile" | "equal", "classes": N}` and `colors` (one
per class) in place of `stops` and `max`. The pipeline reads the numeric
values of the attribute from the normalised data (text and missing values
are left out) and resolves them into stops: `equal` splits min to max into N
equal ranges; `quantile` takes the value at rank `floor(i * n / N)` of the
sorted values as the lower bound of class i, so each class holds about n / N
features. `max` is the data maximum. Breaks that are not distinct (too few
different values for N) fail the build. For example:

```json
{
  "$schema": "../schema/layer-style.schema.json",
  "title": "Scores",
  "defaultVisible": true,
  "order": 10,
  "symbology": {
    "geometry": "polygon",
    "color": {
      "type": "stepped",
      "attribute": "score",
      "breaks": { "method": "quantile", "classes": 4 },
      "colors": ["#a1dab4", "#41b6c4", "#2c7fb8", "#253494"],
      "fallback": { "color": "#9e9e9e", "label": "No score" }
    },
    "fillOpacity": 0.7,
    "outline": { "color": "#ffffff", "width": 0.75 }
  }
}
```

and with raw style layers (a legend derived from the `match`, a label layer
from zoom 6):

```json
{
  "title": "Sites",
  "defaultVisible": false,
  "order": 20,
  "layers": [
    {
      "id": "circle",
      "type": "circle",
      "paint": {
        "circle-color": ["match", ["get", "kind"], "a", "#e69f00", "b", "#cc79a7", "#9e9e9e"],
        "circle-radius": ["interpolate", ["linear"], ["zoom"], 3, 3, 10, 8]
      }
    },
    {
      "id": "label",
      "type": "symbol",
      "minzoom": 6,
      "layout": { "text-field": ["get", "name"], "text-size": 12, "text-offset": [0, 1.2] }
    }
  ]
}
```

Checks: the pipeline (`lib/display.sh`, `pipeline/style/`) validates the
file against the schema, resolves `breaks`, expands the shorthand, fills in
the legend and runs the MapLibre style validator on the result, before
tiling. Any problem fails the layer with one line per problem (for example
`/symbology/fillOpacity must be <= 1` or
`MapLibre style: layers[0].paint.fill-opacity: number expected, string found`)
and keeps the previous archive and manifest entry. To check configs without
building:

```sh
docker compose run --rm --entrypoint sh pipeline -c \
  'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/*.json'
```

### Colour themes and gradients

ADR 0012. The polygon or point shorthand can give `themes` in place of
`color`: a list of `{id, label, color, legend}` (the `legend` optional,
as the top-level one is for a single `color`, which themes do not use)
and an optional `defaultTheme` (default: the first). The map opens on the
default; when there is more than one theme, a "Colour by" list under the
layer in the layer panel switches the colours and the legend in the
browser, with no rebuild, and the choice survives a basemap switch. Raw
`layers` have no themes.

An `interpolated` colour rule is a continuous gradient on a number
(MapLibre `interpolate`, linear, guarded like `stepped` so features
without a number take the `fallback`): either `stops` (`{value, color}`,
at least two, ascending) or `colors` (2 to 12) spread evenly from `min`
to `max`, each of which defaults to the data's minimum or maximum (read
from the data like `breaks`). Its legend is a `gradient`: a colour bar
with each stop's value under it at its `position`, then the fallback if
it has a label. For example (the `ecoregions` layer's themes are in
`pipeline/layers/ecoregions.style.json`):

```json
"symbology": {
  "geometry": "polygon",
  "themes": [
    {
      "id": "protected",
      "label": "Protected (%)",
      "color": {
        "type": "stepped",
        "attribute": "protected_pcnt",
        "stops": [
          { "from": 0, "color": "#deebf7" },
          { "from": 10, "color": "#9ecae1" },
          { "from": 17, "color": "#4292c6" },
          { "from": 30, "color": "#08519c" }
        ],
        "max": 100,
        "fallback": { "color": "#bdbdbd", "label": "No data" }
      }
    },
    {
      "id": "intact",
      "label": "Intact (%)",
      "color": {
        "type": "interpolated",
        "attribute": "intact_pcnt",
        "colors": ["#f7fbff", "#6baed6", "#08306b"],
        "min": 0,
        "max": 100,
        "fallback": { "color": "#bdbdbd", "label": "No data" }
      }
    }
  ],
  "defaultTheme": "protected",
  "fillOpacity": 0.45,
  "outline": { "color": "#08306b", "width": 1 }
}
```

In the manifest, `display.layers` and `display.legend` are the default
theme's (so `style.json` draws it), `display.themes` lists each theme as
`{id, label, paint, legend}`, where `paint` maps a style layer id to the
paint properties the theme sets (`{"fill": {"fill-color": [...]}}`), and
`display.defaultTheme` names the default.

### Number formats

A `format` (pop-up stats, modal items, table columns, charts) is a preset
name or an object. Presets: `number` and `count` (0 decimals, thousands
separators), `percent` (a value already 0 to 100: 1 decimal, then `%`),
`hectares` (0 decimals, `ha`) and `km` (1 decimal, `km`). An object has an
optional `preset` and any of `decimals` (default 0), `grouping` (thousands
separators, default true) and `suffix`, which change it:
`{"preset": "percent", "decimals": 2}`. A suffix follows the number after
a space, except `%`, which follows directly. Numbers use the `en-CA`
locale.

### Click modal

ADR 0012. A layer's `modal` opens a dialog on click instead of the small
pop-up: one template, filled from the clicked feature's tile attributes.
The app only shows attributes; derived values come from the pipeline
(calculated fields, #60). Fields:

- `title` and optional `subtitle`: text with placeholders. `{name}` is the
  attribute `name` as it is, `{area_ha:hectares}` the attribute in a
  format preset, `{$id}` the feature id.
- `sections`: in order, each a `heading`, an optional `description`
  (text with placeholders) and `blocks`:
  - `{"type": "attributes", "items": [...]}`: labelled values, each item
    a pop-up stat (`label`, `value`, `format`).
  - `{"type": "table", "caption", "rowHeader", "columns": [{label,
    format}], "rows": [{label, values}]}`: categories (rows) by attributes
    (columns); each row's `values` gives one attribute per column, or
    `null` for an empty cell.
  - `{"type": "chart", "chart": "bar" | "pie" | "doughnut", "title",
    "valueLabel", "format", "categories", "series": [{label, attributes,
    color}], "colors"}`: `attributes` gives one attribute (or `null`) per
    category. A bar chart with several series is a grouped bar chart with
    a series legend; a pie or doughnut takes one series, with optional
    slice `colors`. Default colours are the Okabe-Ito palette.
  - `{"type": "text", "text": "..."}`: a paragraph with placeholders.
  - `{"type": "list", "items": [{text, when}], "empty": "..."}`: a
    bulleted list, for example recommended actions with their reasons. An
    item shows when its `when` attribute (if given) is true (true, a
    number other than 0, or text other than empty, `0`, `false` or `no`)
    and its text has every placeholder value; `empty` is shown when none
    does.

What a feature lacks is hidden, not shown empty: a title with a missing
value falls back to the layer title; a subtitle, description, text or
list item with one is hidden; an attribute item without a value is left
out, a table cell shows n/a and a row with no values is left out; a chart
keeps gaps and is left out with no values; a list whose attributes are not
in the tiles at all is left out (with them but none true, it shows
`empty`); and a section whose blocks are all hidden (or, without blocks,
whose description is) is left out. The pipeline checks the template
beyond the schema: each table row has one value per column, each chart
series one attribute per category, a pie or doughnut one series, slice
colours one per category, and placeholders are well formed with known
presets.

The dialog is accessible: `role="dialog"` with `aria-modal`, labelled by
the title and described by the subtitle; focus moves to the close button
and stays in the dialog (Tab and Shift+Tab cycle) until it closes, then
returns; Escape, the close button or a click outside closes it; the body
scrolls, and on a narrow screen (600 px or less) the dialog fills it.
Hiding the layer closes it. Tables have a caption and row and column
headers; each chart has a text summary for screen readers.

The `ecoregions` layer (`pipeline/layers/ecoregions.env` and
`.style.json`, section `ecoregions` below) is the worked example: every
section of the #14 template, from the attributes the play data has now.
It started as a test fixture in #57 and became the committed layer in
issue #58; the display config tests and the web tests read the committed
file, so there is one copy.

### `sample`

The synthetic test layer. Made-up features only, no real data. It exercises
the pipeline end to end in tests and gives the web app a layer to build
against without real data. Its configs live in `pipeline/tests/layers/`, so
a default pipeline run does not build it (#17); the bats tests copy them
into a temporary layers dir, and a demo build points the layers dir at
them: `docker compose run --rm -e
PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline`.

- Source: `pipeline/tests/fixtures/sample.geojson`, generated by
  `make_sample.sh` in the same folder (deterministic; a test checks the
  committed file matches). EPSG:4326. Ships inside the pipeline image, so it
  needs nothing in `data/raw/`. Config: `pipeline/tests/layers/sample.env`.
- Pipeline steps: reproject to EPSG:4326, make geometries valid (feature 7 is
  a deliberate self-intersecting bow tie, which becomes a MultiPolygon),
  rename `NAME_EN` to `name`, drop `notes`.
- Tile settings: zoom range 0 to 8, no profile (the polygons do not touch,
  so it is not a coverage), tippecanoe flags `--drop-densest-as-needed`,
  default drop guard threshold (every polygon is required at every zoom).
  Output `data/tiles/sample.pmtiles`, vector layer `sample`.
- Feature id: `id` (integer 1 to 15). Written as the vector tile feature id
  (`--use-attribute-for-id`), so it is `feature.id` in MapLibre and is not
  repeated as a property.
- Attributes kept in tiles:
  - `name` (string): made-up tree name, for example `Cedar`.
  - `area_ha` (number): made-up area in hectares, about 4000 to 49000.
  - `score` (integer): a 0 to 100 score.
  - `v2020`, `v2021`, `v2022`, `v2023`, `v2024` (integer): a short yearly
    series, roughly 100 to 500, for a chart.
- Display (`pipeline/tests/layers/sample.style.json`, `order` 10, the `symbology`
  shorthand with explicit stops): fill at 70% opacity, stepped ramp on
  `score` in four classes, 0 to 25 `#a1dab4`, 25 to 50 `#41b6c4`, 50 to
  75 `#2c7fb8`, 75 to 100 `#253494` (ColorBrewer YlGnBu, the four darker
  classes of the five-class scheme; sequential and colour-blind safe), each
  class including its lower bound. A feature without a numeric `score` is
  grey `#9e9e9e` ("No score"). Thin white outline (0.75 px), which reads on
  both the Light and Dark basemaps. Shown by default.
- Pop-up:
  - Title: `name`.
  - Stats: feature id (label "ID"), `area_ha` (label "Area", thousands
    separator, one decimal, "ha"), `score` (label "Score",
    integer, "/ 100"). Missing values show as "Not available".
  - Plots: bar chart "Value by year", x = 2020 to 2024, y = `v2020` to `v2024`, read
    from tile attributes (five integers is small enough not to need sidecar
    JSON).
- Tests also use `pipeline/tests/fixtures/sample_modal.style.json`: the
  same layer with three colour themes (score in classes, score as a
  gradient, area as a gradient over the data's range) and a click modal
  with every block type. The pipeline's resolved display for it is
  `expected_modal_display.json`, which the web tests read too.

### `sample_points`

The second synthetic test layer. Made-up points only, no real data. It lets
the web app build the layer selector, draw order and overlapping pop-ups
against two layers without real data. Like `sample`, it is a test layer,
not built by default (#17).

- Source: `pipeline/tests/fixtures/sample_points.geojson`, generated by
  `make_sample_points.sh` in the same folder (deterministic; a test checks
  the committed file matches). EPSG:4326. Ships inside the pipeline image.
  Config: `pipeline/tests/layers/sample_points.env`. 30 points over Canada: points
  1 to 8 sit inside `sample` polygons 1, 3, 5, ..., 15, so the two layers
  overlap; points 9 to 30 are spread over the north, clear of the polygons.
- Pipeline steps: reproject to EPSG:4326, make geometries valid, keep `id`,
  `name`, `category` and `count` (no renames).
- Tile settings: zoom range 0 to 10, tippecanoe flag `--drop-rate=1`, so
  every point is kept at every zoom (no `--drop-densest-as-needed`; a test
  checks all 30 feature ids are present at each of z0 to z10). Output
  `data/tiles/sample_points.pmtiles`, vector layer `sample_points`.
- Feature id: `id` (integer 1 to 30). Written as the vector tile feature id
  (`--use-attribute-for-id`), so it is `feature.id` in MapLibre and is not
  repeated as a property.
- Attributes kept in tiles:
  - `name` (string): made-up bird name, for example `Heron`.
  - `category` (string): exactly one of `alpha`, `beta`, `gamma`.
  - `count` (integer): 1 to 500.
- Display (`pipeline/tests/layers/sample_points.style.json`, `order` 20, the
  `symbology` shorthand): circles of radius 6 px with a 1.5 px white stroke,
  coloured by `category`: `alpha` orange `#e69f00`, `beta` reddish purple
  `#cc79a7`, `gamma` vermillion `#d55e00` (Okabe-Ito, colour-blind safe;
  warm colours so they stand apart from the blue-green `sample` ramp
  underneath). Any other value is grey `#9e9e9e` ("Other").
  Drawn above `sample`, so a point inside a polygon wins the click. Shown
  by default.
- Pop-up:
  - Title: `name`.
  - Stats: feature id (label "ID"), `category` (label "Category"), `count`
    (label "Count", integer).
  - Plots: none.

### `forest`

- Source: play data (November 2026), `Forest_AAFC_LUTS_2020_NFIS_2022_30m.tif`
  (forest from AAFC land use 2020 and NFIS 2022). Canada Albers (WGS 84),
  30 m, Byte, 1 = forest, nodata 255, LZW in strips of one row. Not in the
  repo or the image: `RAW_DIR` points at its folder. Config:
  `pipeline/layers/forest.env`.
- Pipeline steps: the raster branch (Raster layers, below).
- Tile settings: z2 to z12, one COG of the cover share (`forest.cog.tif`).
- Licence, provenance and update frequency: TBC (#13).
- Display (`forest.style.json`, `order` 1, the bottom layer): dark
  green `#1b7837` at 70% opacity, legend "Forest (2020 to 2022)". Off by
  default (#14).
- Pop-up: none (display only).

### `agriculture`

- Source: play data (November 2026),
  `HM_CA_ag2022_r90_merged_prj_30_binary.tif` (agricultural land 2022).
  Canada Albers (WGS 84), 30 m, Float32 0/1, nodata NaN, LZW in strips of
  one row. Via `RAW_DIR`, like `forest`. Config:
  `pipeline/layers/agriculture.env`.
- Pipeline steps: the raster branch; 0 and nodata are both transparent.
- Tile settings: z2 to z12, one COG of the cover share
  (`agriculture.cog.tif`).
- Licence, provenance and update frequency: TBC (#13).
- Display (`agriculture.style.json`, `order` 2, above `forest`): orange
  `#d95f02` at 70% opacity, legend "Agricultural land (2022)". Off by
  default.
- Pop-up: none (display only).

### `protected_areas`

- Source: play data (November 2026), `protected_areas.gdb`, layer
  `cpcad_ncc_dslv_2025`: Canada's protected and conserved areas (CPCAD,
  2025), dissolved by NCC into 112,050 MultiPolygons with no attributes
  (only `Shape_Length` and `Shape_Area`). Canada Albers (WGS 84), file
  geodatabase of about 130 MB. Via `RAW_DIR`. Licence, provenance (CPCAD
  release, how and by whom it was dissolved) and update frequency: TBC
  (#13). Config: `pipeline/layers/protected_areas.env`.
- Pipeline steps: reproject to EPSG:4326, make valid; no attributes kept.
- Tile settings: z0 to z12, no profile (dissolved, so no overlaps, but not
  a contiguous coverage) and no tippecanoe flags, so nothing is dropped
  beyond what tiny polygon reduction and simplification collapse. Drop
  guard `LAYER_MIN_VISIBLE_PX=4`: every area whose largest part covers 4
  pixels at a zoom (4 x 4 CSS pixels on the map) is in that zoom's tiles.
  The default of 1 failed at z12 on one sliver, `OBJECTID` 66341 (399 m2,
  2.7 km of outline, under a metre wide), which simplification collapses
  to nothing; 4 px leaves room for such slivers and still keeps every
  area that can be seen. Build (November 2026): 70.3 MB, 1,363 s,
  largest tile 234 KB (z6); present at z0 1,284 of 112,050 (all 17
  required), at z12 110,440 (all 82,069 required).
- Feature id: `OBJECTID` as `id`, the geodatabase's row id, kept only for
  the drop guard; not stable across exports (Open questions).
- Attributes kept in tiles: none.
- Display (`protected_areas.style.json`, `order` 30, above the rasters,
  under `ecoregions`): the shorthand, one semi-transparent green fill
  `#41ab5d` at 60% opacity with a darker green outline `#006d2c` of
  0.5 px, legend "Protected and conserved areas", title "Protected areas
  (CPCAD)". Shown by default.
- Pop-up: none. CPCAD attributes in a pop-up (names, types, IUCN
  category) need the undissolved CPCAD and are deferred (#14).

### `ecoregions`

- Source: play data (November 2026), `ERAP_2026_ecoregions.gdb`, layer
  `ERAP_2026_ecoregions`: the 149 ERAP ecoregions (MultiPolygon, a
  contiguous coverage with about 90,000 polygon parts, mostly islands)
  with their ERAP metrics, 72 attributes. Canada Albers (WGS 84), file
  geodatabase of about 43 MB. Via `RAW_DIR`. Licence, provenance (which
  ERAP run produced the metrics) and update frequency: TBC (#13).
  Config: `pipeline/layers/ecoregions.env`.
- Pipeline steps: reproject to EPSG:4326, make valid, keep and rename the
  attributes below; calculated fields and action rules (Calculated fields
  and action rules, below); low-zoom generalisation to z7.
- Tile settings: z0 to z10, `LAYER_PROFILE=coverage`,
  `LAYER_GENERALISE_MAX_ZOOM=7` (parts under 4 px dropped, borders
  simplified at 1 px; z8 to z10 full detail), default drop guard (1 px).
  Build (November 2026): 21.4 MB, 358 s (36 s of it generalising),
  largest tile 6 to 28 KB at z0 to z7 and 59 KB at z8 to z10; every
  ecoregion at every zoom but one small one at z0 (all 112 required
  there present).
- Feature id: `OBJECTID` as `id`, the geodatabase's row id. Tippecanoe
  needs an integer id and `ECOREGION_ID` is text (for example `"100"`), so
  `ECOREGION_ID` is kept as the attribute `ecoregion_id` and shown in the
  modal. `OBJECTID` may change when the data is exported again; a stable
  integer id is TBC (Open questions).
- Attributes kept in tiles (English only; the French names are not
  tiled): `ecoregion_id`, `name` (`ECOREGION_NAME_EN`), `ecozone_id`,
  `ecozone` (`ECOZONE_NAME_EN`), `landscape_ha` (area), `protected_pcnt`,
  `wtw_percent` and `wtw_area_ha` (NCC Where To Work, % and ha),
  `intact_pcnt`, `modified_pcnt`, `protected_intact_pcnt`,
  `protected_modified_pcnt`; per habitat (forest, grassland, wetland,
  lakes) `pcnt_landscape_<habitat>_cover`, `pcnt_<habitat>_protected` and
  `pcnt_<habitat>_wtw`; `rivers_km` and `coastline_km` with
  `pcnt_<rivers|coastline>_protected` and `_wtw`; the direct threats
  `forestry_pcnt`, `agriculture_pcnt`, `transport_high_pcnt`,
  `transport_low_pcnt`, `energy_pcnt` and `builtup_pcnt`. Percentages are
  0 to 100. Calculated: `unprotected_intact_pcnt` and
  `unprotected_modified_pcnt` (intact or modified land outside protected
  areas, % of the ecoregion). Rules (`ecoregions.rules.json`):
  `action_area_based_30x30` and its `_reason` (122 of 149 ecoregions),
  `actions_area_based_conservation_count` and
  `actions_landscape_conservation_count` (0 everywhere until its rules
  arrive). Peatlands, the hectare columns other than area and Where To
  Work area, and the river and coast km breakdowns stay out.
- Display (`ecoregions.style.json`, `order` 40, on top): a light fill at
  35% opacity and a clear dark blue outline (`#08306b`, 1 px), so the
  layers underneath stay readable. Colour themes, blue sequential, in the
  "Colour by" list:
  - Protected (%), the default: stepped, under 10 `#deebf7`, 10 to 17
    `#9ecae1`, 17 to 30 `#4292c6`, 30 and over `#08519c`.
  - Where To Work (%): a gradient `#f7fbff` to `#6baed6` to `#08306b`
    from 0 to the data's maximum.
  - Where To Work (total area, ha): a gradient on `wtw_area_ha`, 0,
    1,000,000 and 2,500,000 ha.
  - Action recommendations: area-based conservation: stepped on
    `actions_area_based_conservation_count`, none, 1, 2 or more.
  - Each with grey `#bdbdbd` "No data" for a missing value. Title
    "ERAP ecoregions". Shown by default.
- Click: a modal (Click modal, above), title `{name}`, subtitle
  `{ecozone} ecozone`, sections:
  1. Summary: ecoregion ID, ecozone and its ID, area, protected (%),
     Where To Work (% and area), intact and modified (%).
  2. Habitat: a table of forest, grassland, wetland and lakes by cover in
     the ecoregion, protected and in Where To Work (%), the same as a
     grouped bar chart, and a table of rivers and shoreline by total
     length (km), protected and in Where To Work (%).
  3. Direct threats: a description, then forestry, agriculture, transport
     (high and low), energy and mining, and urban and built-up footprint
     (%).
  4. Opportunities: a description and a pie of unprotected intact and
     modified land (the calculated fields).
  5. Action recommendations: an introduction, then each recommended
     action with its reason, or "No actions recommended by the rules so
     far."

  The description texts and colours are placeholders until confirmed
  (Open questions).

### Decisions from #14

Recorded from issue #14 (2026-11-12); its later comments supersede the
earlier ones. The "sidebar" there described the current ERAP app (ERAP
Map Viewer, beta) and was never a requirement: the click opens a modal,
one standard template filled from each ecoregion's tile attributes
(#57, ADR 0012), so ERAP metrics and plots can be added later as
template changes.

- Order, bottom to top: `forest` (1), `agriculture` (2), `protected_areas`
  (30), `ecoregions` (40). Only `ecoregions` is clickable.
- On by default: `ecoregions` and `protected_areas`; the rasters are off.
- Forest, CPCAD and agriculture are display-only layers with no click.
  Many more layers may follow, so the general path (and full-Canada build
  times) must hold up.
- Ecoregions: light fill and clear outlines, on top; colour switchable in
  the map (themes, blue sequential) by % protected (default, classes
  under 10, 10 to 17, 17 to 30, 30 and over), Where To Work (%), Where To
  Work (total area), count of action recommendations: area-based
  conservation, and count of action recommendations: landscape
  conservation (not yet: no rule, so always 0). `wtw` is NCC's Where To
  Work and is labelled so. English only for now.
- Modal sections: Summary, Habitat, Direct threats, Opportunities, Action
  recommendations, as above. Peatlands are in the data but not shown.
- Calculations happen in the pipeline, not the app (ADR 0011): the
  unprotected intact and modified shares, and the action recommendations
  from the committed rules table.
- Protected areas: single semi-transparent green fill, darker outline, no
  pop-up, small drop guard threshold.
- Deferred: Indigenous territories (needs a dataset), CPCAD attributes
  in a pop-up (needs the undissolved CPCAD), peatlands, French text.

## Raster layers

A binary raster (cells of 1 on a background of 0 or nodata) can be a layer
too, display only (ADR 0008), stored as one Cloud Optimized GeoTIFF (ADR
0010). Only binary rasters are supported: one band holding 0, 1 and
nodata, of any data type and CRS. Categorical, continuous and multiband
rasters are not supported yet: they would need a raster-kind setting (mode
or nearest resampling for classes, average for continuous values, one
layer per band for multiband) and are left for later. In `<layer>.env`:

- `LAYER_TYPE=raster` (the default is `vector`).
- `LAYER_INPUT`: the raster, relative to `RAW_DIR` (`/data/raw` in the
  container) like any input.
- `LAYER_MIN_ZOOM`, `LAYER_MAX_ZOOM`: the zoom range; the max zoom (at most
  14) is also the resolution the raster is resampled to. z12 is about 38 m
  at the equator and 19 to 27 m across Canada, close to a 30 m source.
- `LAYER_NODATA` (optional): the source's nodata value, when the file does
  not declare it (or declares the wrong one).
- `LAYER_SOURCE_SRS` (optional): the source CRS, when the file has none.

The source is expected to hold only 0, 1 and nodata; 1 is drawn, 0 and
nodata are transparent. The pipeline (`lib/raster.sh`) first prepares the
source once into a tiled Byte GeoTIFF (255 for 1, 0 for 0 and nodata),
cached in `data/work/raster/` and reused until the source file,
`LAYER_SOURCE_SRS` or `LAYER_NODATA` changes. It warps that to EPSG:3857
at the max zoom's resolution, over an extent snapped to the tile grid,
adds one overview per lower zoom that averages the share of each pixel
covered by 1 cells, and copies the result into `<layer>.cog.tif`: a COG
with 256 px blocks (each one a map tile at the max zoom and the 6 zooms
below it), ZSTD compression and no empty blocks. A pixel's value is the
share covered as a grey level, 0 (none) to 255 (all). The COG is checked
(GDAL's `LAYOUT=COG`, EPSG:3857, one Byte band, one overview per lower
zoom) before it is moved into place; a raster with no 1 cells fails the
layer. nginx serves it with range requests, like a `.pmtiles` archive, and
the map reads only the blocks of the current view, from the overview that
matches the zoom.

The colour is not in the tiles. The display config's raster shorthand

```json
{
  "$schema": "../schema/layer-style.schema.json",
  "title": "Forest",
  "defaultVisible": true,
  "order": 1,
  "symbology": { "geometry": "raster", "color": "#1b7837", "opacity": 0.7 }
}
```

expands to one style layer, id `raster`, of type `color-relief`, on a
`raster-dem` source, `{"type": "raster-dem", "tileSize": 256, "url":
"cog://<url of the COG>#dem"}`. The web app registers the `cog://`
protocol (`@geomatico/maplibre-cog-protocol`), whose `#dem` mode hands each
pixel value, the grey level, to MapLibre as an "elevation" of 0 to 255.
The `color-relief-color` ramps from the colour fully transparent at 0 to
the colour at 255, so at lower zooms the share covered shows as
transparency; `color-relief-opacity` is `opacity`, and `resampling` is
`nearest`, so cells stay sharp past the max zoom. The legend is a single
square swatch in the colour at `opacity`. Changing the colour or opacity
changes only the manifest entry and `style.json`, not the COG
(`--style-only`). Raster layers cannot have a `popup` or raw `layers`, and
the raster shorthand is for raster layers only; the pipeline fails the
layer otherwise, before any raster work.

A raster built before COGs (ADR 0008: PNG tiles in `<layer>.pmtiles`,
manifest `format` `png`) still shows: the map reads its red channel as the
same grey level (`encoding: custom`, `redFactor` 1). `--status` lists it
as `stale`, and rebuilding it writes the COG and deletes the `.pmtiles`.

`pipeline/tests/raster.bats` covers the branch with synthetic rasters made
at test time by `tests/fixtures/make_raster.sh` (a Byte 1/255 raster and a
Float32 0/1/NaN one in the strip layout; nothing binary is committed): the
COG's layout and its alignment with the tile grid, full cover at the max
zoom and partial cover below, the manifest entry, `LAYER_NODATA`, an empty
raster, the colour staying out of the COG, building a raster layer next to
a vector one, replacing a build from before COGs, `--remove`, the prepare
cache and the config checks.

## Input options

Set per layer in `pipeline/layers/<layer>.env` (every variable is described
in `pipeline/lib/config.sh`). Real layers are expected to be shapefiles or
similar, so:

- `LAYER_INPUT` may be a `.zip` (for example a zipped shapefile), read in
  place through GDAL's `/vsizip/`: `boundaries.zip` for a zip holding one
  shapefile (or a GDAL `.shp.zip`), `boundaries.zip/folder/file.shp` for a
  file inside it. Paths that already start with `/vsi` go to GDAL unchanged.
- `LAYER_SOURCE_SRS` (for example `EPSG:3347`) sets the source CRS for inputs
  without a usable one, such as a shapefile with no `.prj`. It is passed to
  `ogr2ogr` as `-s_srs`. Without it such an input fails ("Use -s_srs to set
  one").
- `LAYER_ENCODING` (for example `ISO-8859-1`) sets the attribute encoding of
  a shapefile without a `.cpg` (passed as the open option `ENCODING`).
  Without it GDAL passes the bytes through unchanged, and tippecanoe rejects
  anything that is not valid UTF-8.
- Shapefile cuts field names to 10 characters. `LAYER_FIELDS` renames with
  `src:dest`, so `descriptio:description` restores the full name in the
  tiles.

## Calculated fields and action rules

All calculations happen in the pipeline (issue #14, ADR 0011): the app
only displays tile attributes. A vector layer can add attributes derived
from its own, evaluated per feature at build time and tiled like the rest.

- `LAYER_CALCULATED` in the `.env`: `name=expression` entries. An
  expression uses the layer's attributes (the `LAYER_FIELDS` output names,
  so keep any input it needs) and other calculated fields, in any order. A
  later entry for a name replaces an earlier one; an empty one removes it.
- `LAYER_RULES` in the `.env`: an action rules table,
  `pipeline/layers/<table>.rules.json` (a name, for that file next to the
  `.env`, or a path to a `.rules.json`). Schema:
  `pipeline/schema/action-rules.schema.json`. It lists the action `types`
  (`id`, `label`) and the `actions` (`id`, `type`, `title`, `condition`,
  `reason`, optional `source`). New rules are a change to this file only.

Example, from the ecoregion layer (`pipeline/layers/ecoregions.env`):

```sh
LAYER_FIELDS+=(protected_intact_pcnt protected_modified_pcnt)
# Opportunities pie: intact and modified land outside protected areas, as
# % of the ecoregion (the pie shows them as shares of unprotected land).
LAYER_CALCULATED=(
  'unprotected_intact_pcnt=round(intact_pcnt - protected_intact_pcnt, 2)'
  'unprotected_modified_pcnt=round(modified_pcnt - protected_modified_pcnt, 2)'
)
LAYER_RULES=ecoregions   # pipeline/layers/ecoregions.rules.json
```

`ecoregions.rules.json` holds the one rule known so far, area-based
conservation for 30x30 when `protected_pcnt < 30`, and the two action types
(area-based and landscape conservation). The rest come from the ERAP app's
action recommendation reference table.

Attributes written per feature:

| Attribute | Value |
| --- | --- |
| `<name>` | each calculated field |
| `action_<id>` | 1 when the action's condition is true, else 0 (a condition on a missing value is not true) |
| `action_<id>_reason` | `"<title>: <reason>"` when recommended, for example "Area-based conservation - 30x30 goals: recommended because current protection is less than 30%"; no attribute otherwise |
| `actions_<type>_count` | how many of the type's actions are recommended (0 for a type with no actions yet), for colour themes |

The expression language is a small, SQL-like one, evaluated by GDAL's
SQLite dialect: numbers, `'text'` (`''` for a quote), attribute names
(`"quoted"` if a name is also a keyword below or has other characters),
`+ - * / %` (division is always decimal), `||` (join text),
`= == != <> < <= > >=`, `AND OR NOT`, `IS [NOT] NULL`, `[NOT] IN (...)`,
`[NOT] LIKE`, `[NOT] BETWEEN ... AND ...`, `CASE [x] WHEN ... THEN ...
[ELSE ...] END`, `CAST(x AS integer|real|text|numeric)`, `TRUE`, `FALSE`,
`NULL` and the functions `abs`, `round`, `min` and `max` (two or more
arguments: per feature, not aggregates), `coalesce`, `ifnull`, `nullif`,
`iif`, `length`, `lower`, `upper`, `substr`, `trim`, `replace` and `instr`.
Nothing else is accepted (no `;`, comments, subqueries or other functions),
and each expression is rewritten with every name quoted, so a config cannot
run anything but the expression. Problems (syntax, unknown attributes,
cycles, name clashes, a bad rules table) fail the layer before its source
data is read, naming the field or rule, and keep the previous build.

The build report (`manifest.json`, Pipeline outputs) gains
`calculated_fields` (each with its expression, non-null count, min and
max) and `rules` (the table, each action with the features it is
recommended for, each type with the features with at least one of its
actions); the provenance gains `rules_sha256`. `--status` lists both under
each layer and calls a build `stale` when the `.env`, the map config's
overrides or the rules table's content changed since. `inspect.sh --config
<layer>` shows a layer's data as its build would (calculated fields with
their expressions and value ranges, and rule counts) without building it.
`cli.mjs check` also checks `.rules.json` files.

A local map config (ADR 0009) can change both for one user's map, with
no pull request: an override's `calculated` adds or changes fields by
name (`null` removes one) on top of the layer's, and `rules` points the
layer at another table (relative to the map config file, for example
`pipeline/layers.local/my-actions.rules.json`) or, as `null`, at none.
Both need a rebuild of the layer.

## Polygon coverages: tile profile and drop guard

Real layers are expected to be contiguous coverages: polygons that tile an
area with no overlaps and shared borders throughout. Requirements:

- No gaps or slivers along shared borders, at any zoom.
- Large features are never dropped or merged at a zoom where they are
  visible.
- Small features may be dropped or merged where they would not be visible
  (sub-pixel or close to it), and their removal must not open visible holes.

### `LAYER_PROFILE=coverage`

A named set of tippecanoe flags for coverage layers (defined in
`layer_profile_flags` in `pipeline/lib/config.sh`); a layer's own
`LAYER_TIPPECANOE_FLAGS` are added after them. Checked against tippecanoe
2.79.0 (its `--help` and README) and the gap test on the synthetic coverage
fixture (`pipeline/tests/coverage.bats`):

- `--no-simplification-of-shared-nodes`: keeps every node where rings meet
  or part, and simplifies each border between those nodes identically in
  both neighbours. Chosen over `--detect-shared-borders`, which the 2.79.0
  README marks DEPRECATED ("Use `no-simplification-of-shared-nodes` instead,
  which is faster and more correct"). On the fixture (z0 to z6, every tile
  clipped to its extent, in tile units of 1/16 pixel), this flag leaves no
  overlaps between visible polygons at any zoom and no gaps at all from z2
  up. Without it, independent simplification of each ring opens gaps and
  overlaps at every zoom (for example a gap of 193.5 and overlaps of 24.8 to
  122 tile units squared) and the check fails at 6 of 7 zooms.
  `--detect-shared-borders` passes six zooms but leaves a 13,670 unit squared
  (53 pixel squared) hole at z5.
- `--drop-smallest-as-needed`: when a tile is too big, drop the physically
  smallest polygons first. `--drop-densest-as-needed` is not used: it thins
  by spacing, so it can drop a large polygon in a dense area.
- Tiny polygon reduction (the tippecanoe default) stays on. It only touches
  rings under 4 square tile units, that is 1/64 of a screen pixel at the
  default detail, and the drop guard confirms nothing visible goes.
- No `--coalesce*`: merging changes feature ids and attributes, and
  `--coalesce` disables the shared-node handling.

Tile size is also kept down by keeping only the attributes needed (only
`LAYER_FIELDS` reach the tiles), a sensible per-layer `LAYER_MIN_ZOOM`, and
if needed a moderate `--maximum-tile-bytes` in `LAYER_TIPPECANOE_FLAGS`
(default 500 KB).

For detailed layers with many small parts (islands), generalise the low
zooms in GDAL before tiling (`LAYER_GENERALISE_MAX_ZOOM`; see Low-zoom
generalisation below). GDAL 3.13 also has `gdal vector check-coverage` and
`gdal vector clean-coverage` to check and repair an input coverage before
tiling. Do not pre-simplify with `ogr2ogr -simplify`: it works per feature
and opens gaps.

The `sample` layer does not use the profile: its polygons do not touch, so
it is not a coverage.

### Low-zoom generalisation

A detailed coverage can carry thousands of small parts (islands, skerries)
that read as clutter at low zooms: each draws its own outline, so a coast
with many islands turns into a dark smear. Every feature must still be
there (the drop guard), but its small parts and fine border detail need
not be. Three optional settings in the layer's `.env` (documented in
`pipeline/lib/config.sh`, code in `pipeline/lib/generalise.sh`):

- `LAYER_GENERALISE_MAX_ZOOM`: generalise from `LAYER_MIN_ZOOM` up to this
  zoom (below `LAYER_MAX_ZOOM`). Empty (the default) changes nothing.
- `LAYER_GENERALISE_MIN_PART_PX` (default 4): at each generalised zoom,
  drop polygon parts smaller than this many screen pixels, except each
  feature's largest part.
- `LAYER_GENERALISE_SIMPLIFY_PX` (default 1): coverage simplification
  tolerance, in screen pixels, at each generalised zoom. 0 skips it, for
  polygons that overlap (not a coverage).

Pixels are at 256 px tiles, the unit of `LAYER_MIN_VISIBLE_PX`, so the same
numbers suit any layer: at zoom z a pixel is `40075016.686 / (256 * 2^z)` m
in EPSG:3857. For each generalised zoom, from the highest down (each from
the one above, so only the first pass reads the full data), the pipeline:

1. explodes each multipolygon into parts in EPSG:3857, keeps the parts at
   least `MIN_PART_PX` pixels in area plus each feature's largest part, and
   collects them back into one multipolygon per feature (one GDAL SQLite
   dialect statement with a window function);
2. simplifies the result as a coverage, `gdal vector simplify-coverage`
   (GEOS CoverageSimplifier): each shared border is simplified once, the
   same in both neighbours, so no gaps or slivers open;
3. tags each feature for that zoom only (`"tippecanoe": {"minzoom": z,
   "maxzoom": z}`), and the full input follows from the next zoom up.

One tippecanoe run then reads it all, so there is no `tile-join` and no
second archive, the coverage profile's shared-node handling applies as
before, and the web app sees one source. The drop guard still measures each
feature's largest part in the full input; as that part is never dropped,
the guard holds at any threshold. Holes a dropped part leaves (a small
exclave inside a neighbour) are under `MIN_PART_PX` pixels.

Measured on the local `ecoregions` preview (149 ecoregions, 90,170 polygon
parts, 7.5 million vertices; 89,786 parts are under 1 pixel at z4 and
85,776 under 1 pixel even at z8), z0 to z10 with the coverage profile:

| | Before | Tippecanoe flags only | Generalised to z7 |
| --- | --- | --- | --- |
| Settings | (none) | `--tiny-polygon-size=16 --simplification=4` | `LAYER_GENERALISE_MAX_ZOOM=7`, defaults 4 px and 1 px |
| Parts at z7 (input to tippecanoe) | 90,170 | 90,170 | 1,013 (100,645 vertices) |
| Largest tile z0 to z7 | 25 to 52 KB | 13 to 25 KB (z0 to z8 build) | 5 to 16 KB |
| Largest tile z8 to z10 | 44 to 59 KB | n/a | 44 to 59 KB (unchanged) |
| Archive | 17.0 MB | 2.5 MB (z0 to z8 build) | 15.3 MB |
| Generalisation step | none | none | 37 s (z7 from the full data; z6 to z0 under 1 s each) |
| Whole build, wall clock | 325 s | 67 s (z0 to z8 build) | 407 s |
| Whole build, CPU | 226 s | not measured | 229 s |
| Drop guard | passes | passes (fails with size 32) | passes, every required feature at every zoom |

The full-detail zooms (z8 to z10) are untouched, so the archive stays near
its size: they hold most of it. The builds ran back to back in one
container on a busy shared machine, so wall clock is noisy; CPU time is the
same, as the generalisation step costs about what tippecanoe saves on the
low zooms. Screenshots at z2,
z4, z6 and z8 (Canada, the BC coast, Georgian Bay) show the islands along
the BC coast and in Georgian Bay as a solid outline smear before, and at
z4 and z6 after only the larger islands, cleanly outlined, with no gaps
along shared borders; z8 is identical (full detail).

Why not tippecanoe flags alone. Tiny polygon reduction does act on each
part of a multipolygon (tippecanoe 2.79.0, `reduce_tiny_poly` in
`clip.cpp`, ring by ring), but it is area-preserving: parts under the
threshold are summed per tile and drawn as a square of the threshold size
wherever the running sum passes it, so raising `--tiny-polygon-size` turns
the islands into a scatter of square dots rather than removing them, and
the threshold area grows as the square of the setting (16 is 1 pixel).
It also takes whole features whose largest part is under the threshold, so
a size of 32 (4 pixels) failed the guard at z0 to z3 (16 required features
missing at z0). `--simplification` has a single tolerance for every zoom
(`--simplify-only-low-zooms` exempts only the max zoom), so stronger low-
zoom simplification also coarsens the high zooms. Tippecanoe has no
zoom-dependent part threshold. The GDAL step costs one extra pass but
keeps every rule in screen pixels per zoom and leaves high zooms alone.

When to use it: a polygon layer with many small parts, set the max zoom a
little below where those parts matter (for `ecoregions`, 7 with a max zoom
of 10). Raise `LAYER_GENERALISE_MIN_PART_PX` for a cleaner map, lower it to
keep more islands. Generalisation needs polygons; with
`LAYER_GENERALISE_SIMPLIFY_PX` above 0 it also needs a valid coverage
(check with `inspect.sh` or `gdal vector check-coverage`).

### Drop guard and visibility threshold

Every layer goes through the drop guard (`pipeline/lib/guard.sh`) after
tiling and before the archive is moved into place:

- Size: each feature's largest polygon part is measured once, in EPSG:3857
  (the tiles' own projection), from the normalised GeoJSONSeq. The largest
  part rather than the total, because a feature made only of sub-pixel parts
  is not visible however many parts it has. Points and lines have no area
  and are never required.
- Required: at zoom z a feature is required when that part covers at least
  `LAYER_MIN_VISIBLE_PX` screen pixels at 256 px tiles, that is
  `area_m2 * (256 * 2^z / 40075016.686)^2 >= LAYER_MIN_VISIBLE_PX`.
- Check: for every zoom from the layer's min zoom to its max zoom, the
  feature ids in the archive are read (GDAL's PMTiles driver, `mvt_id` only).
  A required feature missing from every tile of a zoom fails the build, and
  the previous `<layer>.pmtiles` and manifest entry are kept. Missing smaller
  features are logged ("not present (allowed)") and counted in the manifest.

Default threshold: 1 pixel. Tippecanoe's own pixel is 1/256 of a tile, so
this is the same unit as its `--buffer`. MapLibre draws a vector tile of zoom
z across 512 CSS pixels (from its zoom z until z+1), so a 1 px feature here
is at least 2 x 2 CSS pixels on screen, and less than that is too small to
read as a shape or to show as a hole in a coverage. Tippecanoe's tiny
polygon reduction works far below this (1/64 px), so the default flags never
trip the guard; drop-as-needed under a tight tile size can, which is the
point. Raise it per layer (for example `LAYER_MIN_VISIBLE_PX=4`) to give
dropping more room, or set 0 to require every polygon at every zoom (which
then also fails on tiny polygon reduction).

Cost: one GDAL pass over the input for the sizes, then each zoom of the
archive is read once for ids and once by `tippecanoe-decode --stats` for tile
sizes. On the coverage fixture (1,058 polygons) the sizes take under 0.1 s and
the guard 0.3 s for z0 to z6; at z0 to z11 (15,600 tiles, 0.7 MB) the guard
takes 1.6 s against 1.3 s for tippecanoe itself, so expect it to roughly
double the tile step on real data.

### Tests

`pipeline/tests/coverage.bats` builds a synthetic coverage (made-up, no real
data) from `pipeline/tests/fixtures/make_coverage.sh`, generated at test time
and not a built layer: a jittered lattice over -120..-100, 50..60 cut into
18 large polygons, 40 medium ones and 1,000 tiny ones (about 1/100 pixel at
z0), all sharing exact vertices along their borders. The tests check:

- the gap check: every tile at z0 to z6, clipped to its extent, has no
  overlaps between visible polygons, and per zoom the gaps add up to no more
  than the area of the polygons too small to see (zero from z5, where every
  polygon is visible); and that it fails without
  `--no-simplification-of-shared-nodes`;
- every large polygon at every zoom, tiny ones absent at z0 and all present
  from z4;
- the per-zoom manifest stats;
- the guard failing the build, and keeping the previous archive, when
  `--maximum-tile-bytes=1500` makes tippecanoe drop large polygons, and when
  `LAYER_MIN_VISIBLE_PX=0` meets tiny polygon reduction.

`pipeline/tests/generalise.bats` covers low-zoom generalisation on a second
synthetic coverage, `pipeline/tests/fixtures/make_islands.sh`: two blocks
sharing a zigzag border, each a multipolygon with 12 islands of three sizes,
and a feature made only of small islets. It checks that without the
settings every island is tiled (today's behaviour); that with them each
generalised zoom keeps only the parts above the pixel threshold plus each
feature's largest, and the zoom above is full detail again; that a
generalised zoom is still a valid coverage with the zigzag simplified away
(and untouched with `LAYER_GENERALISE_SIMPLIFY_PX=0`); and that bad
settings are rejected.

`pipeline/tests/inputs.bats` covers the input options with shapefiles made
in the test by `ogr2ogr` (nothing binary is committed).

## Pipeline outputs

Besides one `<layer>.pmtiles` per vector layer and one `<layer>.cog.tif`
per raster layer, the pipeline writes
`data/tiles/manifest.json`, which the web app reads at startup to find and
draw the layers (the `display` block is shortened here; see Display config):

```json
{
  "updated_at": "2026-01-01T00:00:00Z",
  "map": { "center": [-96, 60], "zoom": 3, "basemap": "light" },
  "layers": [
    {
      "name": "sample",
      "file": "sample.pmtiles",
      "type": "vector",
      "format": "mvt",
      "minzoom": 0,
      "maxzoom": 8,
      "bounds": [-125, 46, -66, 56],
      "center": [-108.98, 51.18, 8],
      "built_at": "2026-01-01T00:00:00Z",
      "display_updated_at": "2026-01-01T00:00:00Z",
      "display": {
        "title": "Sample polygons",
        "defaultVisible": true,
        "order": 10,
        "popup": { "title": { "attribute": "name" }, "stats": [] },
        "layers": [
          { "id": "fill", "type": "fill", "paint": { "fill-opacity": 0.7 } },
          { "id": "outline", "type": "line", "paint": { "line-width": 0.75 } }
        ],
        "legend": {
          "kind": "ramp",
          "shape": "square",
          "border": "#ffffff",
          "opacity": 0.7,
          "items": [{ "color": "#a1dab4", "label": "0 to 25" }]
        }
      },
      "enabled": true,
      "build_seconds": 3,
      "bytes": 49824,
      "provenance": {
        "origin": "committed",
        "source": {
          "path": "sample.geojson",
          "bytes": 9876,
          "modified_at": "2026-01-01T00:00:00Z"
        },
        "overrides": { "title": "My sample" },
        "env_sha256": "3f1c...",
        "style_sha256": "9a0b..."
      },
      "feature_count": 15,
      "profile": null,
      "min_visible_px": 1,
      "max_tile_bytes": 833,
      "zooms": [
        {
          "zoom": 0,
          "input": 15,
          "present": 15,
          "required": 15,
          "required_present": 15,
          "max_tile_bytes": 813
        }
      ]
    }
  ]
}
```

`bounds` is `[west, south, east, north]` and `center` is `[lon, lat, zoom]`,
both from the PMTiles header for a vector layer; for a raster layer the
source's extent and its middle at the min zoom. Layers are sorted by name (draw order is
`display.order`). Rebuilding one layer replaces its entry and keeps the
others. `pipeline --style-only <layer>` (#53) replaces only the entry's
`display` and sets `display_updated_at`, with no re-tiling; `built_at` and
the build report stay as they were, and a build sets both times. `--status`
compares the `.env` and source data with `built_at` (`stale`) and the
`.style.json` with `display_updated_at` (`restyle`: `--style-only` is
enough). Both files are written to a temp file and moved into place, so a
failed run leaves the previous version. nginx serves them with
`Cache-Control: no-cache` and an ETag, so a reload picks up a change
(checked by `scripts/check-tiles-cache.sh` in CI).

The local map config (ADR 0009, `map.config.json`, schema
`pipeline/schema/map-config.schema.json`) adds three things. `map`, at the
top, is its opening view and basemap (`center` as `[lon, lat]`, `zoom`,
`basemap` `light` or `dark`), left out when it sets none; `style.json`
takes the `center` and `zoom` too. `enabled` is false on the entry of a
layer built before and since left out by the config: the archive and
entry are kept, but the map and `style.json` leave it out (an entry
without `enabled` is enabled). `provenance` says what the layer was built
from: `origin` (`committed`, `local` for a config in one of the map
config's `layerDirs`, or `config` for one of its `localLayers`), the
source data (`path` relative to `RAW_DIR`, total `bytes` of its files and
newest `modified_at`; null for a `/vsi` path), the map config `overrides`
as applied (null for none) and SHA-256 hashes of the effective settings
and display config (the `.env` and `.style.json` with the overrides
applied). `--status` compares the hashes too, so an `input` or `env`
override change shows as `stale` and a display override change as
`restyle`; `--style-only` updates the display part (`style_sha256` and the
display overrides). Older entries have none of these and read as before.

The manifest is the runtime contract with the web app (ADR 0007), which
reads `name` (also the source layer and style layer id prefix), `file`,
`type`, `display`, `enabled` and the top-level `map`. `type` is the
layer's `LAYER_TYPE`, `vector` or `raster` (ADR 0008); it decides the
MapLibre source (`vector`, or the
`raster-dem` source of Raster layers), and an entry without it, written
before raster layers, is read as vector. `file` is `<layer>.pmtiles` for a
vector layer and `<layer>.cog.tif` for a raster layer (ADR 0010; the map
also reads a raster `.pmtiles` from before COGs). `format` is the tile
type: `mvt` from the PMTiles header of a vector layer, `cog` for a raster
layer (`png` for one built before COGs). `display` is the resolved
`<layer>.style.json`, valid against
`$defs/display` in the schema: `title`, `defaultVisible`, `order` (0 when
not set), `popup` (when set), `layers` (the style layers in draw order,
with the shorthand expanded and `breaks` resolved, ids as configured) and
`legend` (every field filled in). The web app checks each entry again and
leaves out one that does not pass, saying so in the layer panel; an entry
written before display configs existed has no `display` and is left out
until the layer is rebuilt. The rest is the build report. Every entry has
`build_seconds` (the layer's build time) and `bytes` (the archive's size).
A vector layer adds the drop guard's report:

- `feature_count`: features in the normalised input.
- `profile`: the layer's `LAYER_PROFILE`, or `null` for none.
- `min_visible_px`: the layer's `LAYER_MIN_VISIBLE_PX`.
- `max_tile_bytes`: the largest stored (compressed) tile in the archive.
- `zooms`: one entry per zoom from `minzoom` to `maxzoom` (only z0 is shown
  above): `input` features in the normalised input, features `present` in at
  least one tile, features `required` at that zoom (see the drop guard) and
  how many of them are present (`required_present`, always equal to
  `required` in a built layer), and that zoom's largest tile in bytes.

A raster layer adds instead the COG's levels:

- `width`, `height`: the COG's size in pixels at the max zoom (its extent
  is padded to the tile grid, so it is mostly empty and costs nothing).
- `block_size`: 256, the COG's block (one map tile).
- `overview_count`: overviews, one per zoom below the max.
- `zooms`: one entry per zoom from `maxzoom` down to `minzoom`,
  `{"zoom": 12, "width": 447240, "height": 290531}`.

A raster built before COGs has `tile_count`, `max_tile_bytes` and per-zoom
tile counts instead, until it is rebuilt.

The pipeline also writes `data/tiles/style.json` after every run: a
standalone MapLibre style (version 8, no basemap) of every layer in the
manifest, in draw order, for use in other tools. Each vector layer is a
source `{"type": "vector", "url": "pmtiles://<layer>.pmtiles"}` and each
raster layer `{"type": "raster-dem", "tileSize": 256, "url":
"cog://<layer>.cog.tif#dem"}`, relative to the folder holding `style.json`
(tools that need absolute URLs, or that resolve them against the page
rather than the style, need them rewritten, and need the `pmtiles://` and
`cog://` protocols), with its style layers prefixed with `<layer>-`
and visible as `defaultVisible` says. `glyphs` (OpenFreeMap's) is set only
when a layer shows text. It is checked with the MapLibre style validator
before it is written.

## Where pop-up data lives

Two options, chosen per layer:

1. In tile attributes. Simple and needs no extra requests. Good for a handful
   of scalar stats. Watch tile size: tippecanoe drops or warns on large
   tiles, and arrays must be encoded as strings.
2. In sidecar JSON, `data/tiles/<layer>/<feature_id>.json` (or one JSON per
   layer if small), fetched on click. Good for time series or distributions
   behind a plot. Keeps tiles small.

Default: scalar stats in attributes, plot series in sidecar JSON. Revisit
once the real data is known, and record the choice as an ADR if it differs.

## Open questions

- All of the TBC fields above.
- Licence, provenance and update frequency of `forest`, `agriculture`,
  `protected_areas` and `ecoregions` (#13): who publishes each dataset,
  under what licence, which version or run it is, and how often it
  changes.
- Stable feature ids (#13): `ecoregions` and `protected_areas` use
  `OBJECTID`, the file geodatabase's row id, which may change when the
  data is exported again. `ECOREGION_ID` is stable but text; tippecanoe
  needs an integer. Options: an integer copy of `ECOREGION_ID` in the
  source, or a calculated field `CAST(ecoregion_id AS integer)` as the
  feature id (not tried yet). The dissolved CPCAD has no id of its
  own, which is fine while it has no pop-up.
- Ecoregion modal texts (#14): the section descriptions and the action
  recommendations introduction are placeholders.
- Ecoregion colours (#14): the blue ramps, the Opportunities pie colours
  and the outline are defaults until confirmed against the current ERAP
  app.
- Where To Work (total area) theme: uses `wtw_area_ha` from the data, on
  a gradient to 2,500,000 ha; confirm that this column is the total area
  meant in #14.
- Landscape conservation count theme (#14): left out until the rules
  table has a landscape conservation action (the count is 0 for every
  ecoregion now); then it is a theme on
  `actions_landscape_conservation_count`, a style-only change.
- More action rules from the ERAP app's reference table (#60): a change
  to `ecoregions.rules.json` only.
- Do any pop-ups aggregate across many features (for example, stats for
  everything inside a clicked boundary)? If so, precompute in the pipeline
  rather than in the browser.
