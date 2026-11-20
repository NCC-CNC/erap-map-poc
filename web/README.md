# Web app

A read-only map: React, TypeScript, Vite, MapLibre GL JS, `pmtiles`,
`@geomatico/maplibre-cog-protocol` and Chart.js (ADR 0003), served by
nginx (ADR 0004). No layer is defined here: the app draws whatever the
pipeline wrote to `data/tiles/style.json` (ADR 0015).

## How it reads style.json

1. `src/map/MapView.tsx` creates the map on the basemap
   (`src/map/basemap.ts`, OpenFreeMap Light or Dark) and fetches
   `tiles/style.json` once.
2. `src/layers/style.ts` checks it is a version 8 style, groups the
   style layers by `metadata["erap:layer"]`, reads each layer's title,
   order, visibility, legend, themes and pop-up from
   `metadata["erap:layers"]`, and resolves the relative `pmtiles://` and
   `cog://` sources against the tiles URL. It also reads the view limits,
   basemap, title and locale.
3. `src/layers/spec.ts` turns a layer into MapLibre sources and style
   layers, which are added over the basemap, and added again after a
   basemap switch with their visibility (`visibility.ts`) and theme
   (`themes.ts`).
4. A source or style layer MapLibre will not load comes back as an error
   event; the panel shows that layer as not available and the others
   still draw.

The types of the metadata are generated from
`pipeline/schema/layer.schema.json` into `src/layers/layer.generated.ts`
(`npm run layer-types`, `vite/layerTypes.ts`); a test fails when it is
out of date. `src/layers/types.ts` names them for the app.

## src/

| Path | What |
| --- | --- |
| `main.tsx`, `App.tsx` | entry point |
| `locale.ts` | the locale numbers are formatted in, from `erap:locale` |
| `layers/` | reading `style.json` (`style.ts`, `spec.ts`), legends from colour expressions (`legend.ts`), the chosen theme and visibility per layer |
| `map/` | the map (`MapView.tsx`, `createMap.ts`, `view.ts`), basemaps, the `pmtiles://` and `cog://` protocols, the MapLibre worker, the panel (`MapPanel.tsx`, `BasemapToggle.tsx`, `LayerList.tsx`, `LegendView.tsx`) and click handling (`popups.ts`) |
| `popup/` | `content.ts` fills a pop-up from a clicked feature's attributes, `Sections.tsx` draws its blocks, `FeaturePopup.tsx` frames a small pop-up |
| `modal/` | `FeatureModal.tsx` frames a dialog pop-up: tabs, focus and keyboard handling |
| `chart/` | Chart.js bar, line, pie and doughnut charts, loaded on first use |
| `test/` | shared test fixtures |

Tests sit next to the code (`*.test.ts`, `*.test.tsx`, vitest). They also
check the pipeline's expected `style.json` fixtures in
`pipeline/tests/fixtures/` against the MapLibre style spec.

## Other files

- `nginx.conf`: serves the app, and `data/tiles/` at `/tiles/` with range
  requests and revalidation (a reload picks up a rebuild).
- `Dockerfile`: builds the app with Node and serves it with nginx.
- `vite.config.ts`, `vite/serveTiles.ts`: the dev server, which serves
  `data/tiles/` at `/tiles/` like nginx.

## Run and check

```sh
docker compose up -d --build web            # nginx image, http://localhost:8080
docker compose --profile dev up web-dev     # Vite with hot reload, http://localhost:5173
docker compose --profile dev run --rm --no-deps web-dev sh -c \
  'npm ci && npm run lint && npm run typecheck && npm test && npm run build'
```

With Node 26 on the host, `npm ci && npm run dev` in `web/` works too.
