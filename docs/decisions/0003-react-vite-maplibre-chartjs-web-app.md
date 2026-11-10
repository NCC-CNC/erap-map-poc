# React, Vite, MapLibre and Chart.js web app

## Status

Accepted. Amended by 0007-data-driven-layer-styles.md: layers are no longer
defined in the app's code but read from the pipeline's manifest.json.

## Context

The web map displays the PMTiles layers and opens pop-ups with summary stats
and plots when a feature is clicked. Data, styling, and pop-up content are not
yet known, so the app needs to make adding layers and pop-up types cheap.

## Decision

- React with TypeScript, built with Vite.
- MapLibre GL JS for rendering, with the `pmtiles` JS library registered as a
  MapLibre protocol.
- Chart.js for charts inside pop-ups, with only the needed chart types
  registered.
- ESLint, `tsc --noEmit` and vitest as the checks.
- npm as the package manager, with a committed lockfile.

## Consequences

- React gives a clear component model for pop-ups, legends, and layer
  controls as the UI grows; it costs some boilerplate for MapLibre
  integration (the map lives outside React's render tree, pop-ups render into
  MapLibre's container).
- Chart.js is small, canvas-based, and covers the likely pop-up charts (bar,
  line, doughnut). It is less interactive out of the box than heavier
  libraries; if pop-ups need richer interaction (zoom, pan, linked
  selection), revisit in a new ADR.
- Charts live in short-lived pop-ups, so chart instances must be destroyed on
  close to avoid leaks.
- Choosing npm means Dependabot can track web dependencies.
