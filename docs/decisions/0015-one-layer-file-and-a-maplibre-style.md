# One layer file and a MapLibre style

## Status

Accepted. Supersedes 0007-data-driven-layer-styles.md,
0009-local-map-config.md, 0011-calculated-fields-and-action-rules.md and
0012-click-modal-template-and-colour-themes.md. Amends
0002-bash-gdal-tippecanoe-pipeline.md (no Node in the pipeline) and
0003-react-vite-maplibre-chartjs-web-app.md (the app reads `style.json`).
The full plan and what each step settled are in
`docs/design/04_refactor.md`.

## Context

The PoC worked, but it was hard to follow. One layer was spread over up
to five files (`<layer>.env`, `<layer>.style.json`, `<table>.rules.json`,
`map.config.json` and the root `.env`). The same display rules existed
three times: a long JSON Schema, a Node resolver in `pipeline/style/` and
hand-written checks in the app. The pipeline switched between bash and
Node, and the app read a custom `manifest.json`.

## Decision

- **One file per layer**, `pipeline/layers/<layer>.yaml`, with `source`,
  `fields`, `processing` and `display`, checked against one schema,
  `pipeline/schema/layer.schema.json`. Your own layers go in the
  git-ignored `pipeline/layers.local/`, in the same format; a name that
  repeats a committed layer is an error.
- **The output is a standard MapLibre style.** The pipeline writes
  `data/tiles/style.json` (sources and style layers in draw order) and
  the app loads it over the basemap. What MapLibre does not know about
  (title, order, visibility, legend, themes, pop-up, view limits, title,
  locale) goes in the style's `metadata` under `erap:` keys.
  `manifest.json` is gone; the build report is `data/tiles/build.json`,
  read only by the pipeline and `scripts/`.
- **`display` is plain MapLibre**: style layers with `paint`, `layout`
  and expressions, written as they appear in `style.json`. The pipeline
  adds the source, the source layer and a `<layer>-` id prefix. Colour
  themes are other `paint` blocks. Class breaks are written in the file.
  The app builds legends from `step`, `match` and `interpolate`
  expressions; a layer can give an explicit `legend`.
- **The pipeline stays bash, without Node.** `yq` and `jq` read the
  files; `jv` checks them against the schema. The style is checked
  against the MapLibre style spec in the web app's tests.
- **Sources are anything GDAL opens**, plus `source.joins`: attributes
  from a CSV or table, matched by key.
- **Calculated fields are SQLite expressions** (`fields.calculated`, run
  by `ogr2ogr -dialect SQLite`). An action recommendation is a calculated
  field that is 1 or 0; its title and reason are a `list` item in the
  pop-up. There is no rules file.
- **Processing uses presets**: `processing.profile` is `default`,
  `coverage`, `points` or `raster`. A layer sets its zooms and a few
  tuning values; `processing.tippecanoe` adds tippecanoe options for
  layers the presets do not fit.
- **One click display**, `display.popup`: a `small` pop-up at the click
  or a `dialog`, with sections of blocks (`attributes`, `table`, `chart`,
  `text`, `list`). Number formats are `number`, `integer` and `percent`,
  with units in `suffix`, in the map's locale.
- **One map config format**, `pipeline/schema/map.schema.json`: your
  git-ignored `map.config.yaml` and the committed `map.pages.yaml` for
  the GitHub Pages copy. Keys: `view` (with zoom limits and bounds),
  `basemap`, `title`, `locale`, `layers`, `overrides` (of `source` and
  `processing` only) and `require`.
- **Staleness is by hash**: `build.json` keeps a hash of each layer's
  `source`, `fields` and `processing` and one of its display; a change to
  the display alone is `restyle`, applied with `--style-only`.

## Consequences

- Adding a layer means adding one file; nothing about a layer is in the
  app. `docker compose run --rm --entrypoint inspect.sh pipeline --starter
  <data>` prints a valid starting file.
- `style.json` can be opened by other MapLibre tools, though only this
  app reads its `erap:` metadata.
- Display overrides in a map config, provenance tracking, computed class
  breaks and the separate click modal are gone. An old `map.config.json`
  is not read; the pipeline says so, and it is rewritten by hand as
  `map.config.yaml`.
- The pipeline image is smaller and has one language. The layer schema
  is the only description of the format; the app's TypeScript types are
  generated from it.
