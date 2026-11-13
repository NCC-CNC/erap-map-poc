# Click modal template and colour themes

## Status

Accepted. Extends 0007-data-driven-layer-styles.md: the display config
gains a click modal, switchable colour themes, a gradient colour rule and
number format presets; the app stays a generic renderer of the manifest.

## Context

The ERAP ecoregions need more on click than the small map pop-up holds
(issue #57; decisions in #14): a summary, tables of habitats by measure,
charts and, later, ERAP metrics and recommended actions, one standard
layout filled from each ecoregion's tile attributes. Stakeholders also want
to colour the ecoregions by one of a few attributes (protected, Where To
Work, intact) and switch between them in the map, on a blue sequential
gradient. More layers may follow, so none of this may be ecoregion
specific, and adding a section or a theme must be a config change, not
code. Calculations stay in the pipeline (#60, ADR 0011): the app only shows what the
tiles hold.

## Decision

- **Modal**: a layer's `.style.json` may have a `modal` instead of a
  `popup` (not both): a `title` and optional `subtitle` with attribute
  placeholders (`{attribute}`, `{attribute:preset}`, `{$id}`), then
  `sections`, each a heading, optional description and blocks: an
  attribute list, a table (rows of categories by columns of attributes),
  a chart (bar with one or more series, grouped with a legend when
  several; pie; doughnut), a text paragraph and a list of items from
  attributes with a message for none. Anything a feature has no value for
  is hidden: an item, a row, a block, a whole section. The pipeline copies
  the template into the manifest after checking it (schema, plus table
  and series lengths and placeholders); the app fills it at click time.
- The modal is an accessible dialog: `role="dialog"` and `aria-modal`,
  labelled by its title, focus on the close button and trapped while open,
  returned on close, closed by Escape, the close button or the backdrop,
  scrolling inside, full screen on narrow screens, and closed when its
  layer is hidden. The small pop-up stays for simple layers.
- **Colour themes**: the polygon and point shorthand may give `themes`
  (each an id, label, colour rule and optional legend) and a
  `defaultTheme` in place of one `color`. The pipeline resolves every
  theme (breaks and gradient ranges from the data) into the paint property
  it sets and its legend; the display's `layers` and `legend` are the
  default theme's, so `style.json` and older apps still draw it. A "Colour
  by" choice under the layer in the layer panel switches the paint and
  legend in the browser, with no rebuild, and survives a basemap switch.
  Raw `layers` have no themes (one style, as before).
- **Gradient**: an `interpolated` colour rule (MapLibre `interpolate`,
  linear), with explicit `stops` or `colors` spread from `min` to `max`
  (each from the data when left out), and a `gradient` legend: a colour
  bar with positioned stop labels.
- **Formats**: a format may be a preset name, `number`, `count`,
  `percent` (values already 0 to 100), `hectares` or `km`, or an object
  with a `preset` changed by `decimals`, `grouping` and `suffix`. `%`
  follows the number with no space.
- Charts use Chart.js as before (ADR 0003), now with pie, doughnut and
  legend support and loaded on first use, so it is not in the initial
  bundle. Default series colours are the Okabe-Ito palette.
- The modal's DOM tests use jsdom (a pinned dev dependency, tests only).

## Consequences

- A new section, table, chart or theme is a `.style.json` change and
  `pipeline --style-only`, as for any display change; a value not in the
  tiles still needs `LAYER_FIELDS` (or a calculated field, #60) and a
  rebuild. The `edit-popup` skill covers both routes.
- The manifest grows by the template and the themes' paint and legends,
  a few kilobytes per layer.
- The app checks the new blocks by hand, like the rest of the display
  block, kept in step with the schema by `schema.test.ts`.
- Colours, the description texts and the exact sections for the ecoregions
  are defaults until confirmed against the current ERAP app (#58); the
  ecoregion template lives as an example
  (`pipeline/tests/fixtures/ecoregions.example.*`) until #58 commits the
  layer. (#58 did: it is now `pipeline/layers/ecoregions.*`, and the tests
  read that.)
- Not done: themes for raw `layers`, a theme choice in the map config, a
  gradient legend derived from a raw `interpolate`, French text.
