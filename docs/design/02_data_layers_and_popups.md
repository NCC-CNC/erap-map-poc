# 02 Data, Layers and Pop-ups

Status: skeleton. The data, styling, and pop-up content are TBC. This note is
the data contract between the pipeline and the web app; fill it in per layer
as each is confirmed, and change pipeline and web app together when it
changes.

## Layer inventory

| Layer id | Source dataset | Format | Geometry | Approx. size | Status |
| --- | --- | --- | --- | --- | --- |
| `example` | TBC | TBC | TBC | TBC | Placeholder |

## Per-layer contract

Copy this block for each layer.

### `{{layer_id}}`

- Source: {{where it comes from, licence, update frequency}}.
- Pipeline steps: {{filters, reprojection, simplification, joins}}.
- Tile settings: zoom range {{min to max}}, tippecanoe flags
  {{e.g. `--drop-densest-as-needed`}}.
- Feature id: {{attribute used as a stable id, needed for sidecar lookups and
  feature state}}.
- Attributes kept in tiles: {{name, type, meaning}}.
- Styling: {{fill/line/circle, colour ramp, classification breaks, labels}}.
- Pop-up:
  - Title: {{attribute or template}}.
  - Stats: {{list of stats and their formatting}}.
  - Plots: {{chart type, x and y, data source}}.

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
- Do any pop-ups aggregate across many features (for example, stats for
  everything inside a clicked boundary)? If so, precompute in the pipeline
  rather than in the browser.
