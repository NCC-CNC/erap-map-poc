# Data-driven layer styles

## Status

Accepted. Amends 0003-react-vite-maplibre-chartjs-web-app.md on where
layers are defined: no longer in the web app's code. Extended by
0012-click-modal-template-and-colour-themes.md (click modal, colour themes,
gradients, number format presets).

## Context

Until now each data layer was a TypeScript file in `web/src/layers/` (its
symbology, pop-up and default visibility) listed in a registry array, so
changing a colour or adding a layer meant changing and rebuilding the web
app. The repo owner wants full control of styles (the whole MapLibre style
spec, not only a shorthand), no styling by hand in an editor such as
Maputnik, and to change or add layers without touching the core app code
(issue #39).

## Decision

- Each layer is two files in `pipeline/layers/`: `<layer>.env` (processing,
  as before) and `<layer>.style.json` (display): `title`, `defaultVisible`,
  optional `order`, an optional `popup` (the existing pop-up shape), and
  either the `symbology` shorthand or raw MapLibre style-spec `layers`
  (any vector layer type, expressions, zoom functions, labels; no `source`
  or `source-layer`), plus an optional explicit `legend`. A stepped colour
  may give `breaks` (`quantile` or `equal`, with a colour per class) instead
  of explicit stops; the pipeline computes the stops from the layer's data.
- One JSON Schema, `pipeline/schema/layer-style.schema.json` (draft
  2020-12), describes the file and, under `$defs/display`, the resolved
  block the app reads. It lives in the pipeline's build context, so the
  pipeline image carries it; the web app's tests read it from the repo.
- The pipeline validates and resolves each config before tiling, with a
  small Node tool in `pipeline/style/` (ajv for the schema,
  `@maplibre/maplibre-gl-style-spec` for MapLibre's own style validator,
  both pinned by a committed lockfile; Node copied from the same pinned
  image the web build uses). It checks the schema, resolves `breaks`,
  expands the shorthand into style layers, derives the legend (from the
  shorthand, or from a constant, `match` or `step` colour in raw layers)
  or requires an explicit one, and runs the MapLibre validator on the
  result. Any problem fails the layer before tiling, keeping the previous
  archive and manifest entry.
- `manifest.json` is the runtime contract: each entry gains `display`, the
  resolved config (style layers with their configured ids, a complete
  legend, the pop-up, the order). The pipeline also writes
  `data/tiles/style.json`, a standalone MapLibre style of the data layers
  (`pmtiles://` sources relative to that folder, no basemap) for other
  tools.
- The web app is a generic renderer: it fetches `manifest.json` (no-cache)
  at startup, checks each entry by hand against the same rules (kept in
  step with the schema by a test), and builds the layer list, style
  layers, legends, pop-ups and draw order from it. No layer is defined in
  `web/src/`.
- Draw order: ascending `order` (default 0), ties broken by layer name;
  the highest is drawn on top and listed first.
- Style layer ids: unique within the file, prefixed with `<layer>-` on the
  map and in `style.json`, so ids never clash between layers. The
  shorthand's ids are `fill` and `outline` (polygons) and `circle`
  (points), so `sample-fill` and the other existing ids are unchanged.

## Consequences

- Restyling or adding a layer is a change to `pipeline/layers/` and a
  pipeline run; the map picks it up on reload, with no web rebuild. Compose
  mounts `pipeline/layers/` into the pipeline container, so no pipeline
  image rebuild either.
- Mistakes are caught at build time, by the same MapLibre validator the
  map uses, instead of showing as a broken map.
- The symbology generator and legend derivation now live in one place,
  the pipeline tool, written once in plain JavaScript; the app only
  renders their output. Legend derivation for raw layers is deliberately
  simple (the first fill, circle or line colour); anything richer needs an
  explicit `legend`.
- The pipeline image gains Node (about 150 MB) and two npm packages, a
  second place to keep `@maplibre/maplibre-gl-style-spec` up to date
  (Dependabot watches both). Validating in CI only, with the web tooling,
  was the lighter alternative, but it would not have covered configs
  edited outside a PR, would have duplicated the generator, and could not
  have written `style.json`.
- The app shows nothing but the basemap until `manifest.json` has loaded,
  and a clear message if it is missing or invalid.
