---
name: edit-popup
description: Change what a map layer shows when a feature is clicked - its small pop-up (title, stats, charts) or its modal dialog (title, subtitle, sections of attribute lists, tables, bar, grouped bar, pie and doughnut charts, text and lists, number formats) - by editing the `popup` or `modal` in pipeline/layers/<name>.style.json. Lists the attributes in the built tiles and in the source, applies a display-only change with `pipeline --style-only`, or adds the fields to LAYER_FIELDS and rebuilds when they are not tiled yet, with before and after screenshots of a clicked feature and a draft PR. Use when asked to add, remove or change what a pop-up or modal shows, add a section, table or chart to it, or change its number formats.
---

# Edit a pop-up or modal

What a layer shows on click lives in `pipeline/layers/<name>.style.json`:
a `popup` (small map pop-up) or a `modal` (a dialog of sections), never
both. Colours, colour themes and legends are the restyle-layer skill.
Reference: `docs/design/02_data_layers_and_popups.md` (Display config,
Number formats, Click modal), `pipeline/schema/layer-style.schema.json`
and ADR 0012; `pipeline/layers/ecoregions.style.json` is a worked modal
(the web and display config tests read it, so run the web checks after
changing it). Never commit data or screenshots.

The map only shows tile attributes: no sums, shares or rules in the app.
A derived value has to be an attribute in the tiles, from the source or
from the pipeline (ADR 0011; design note 02, Calculated fields and action
rules):

- a calculated field, `LAYER_CALCULATED=('name=expression' ...)` in
  `<name>.env` (for example unprotected intact land);
- a rule attribute from the layer's rules table (`LAYER_RULES`,
  `pipeline/layers/<table>.rules.json`): `action_<id>` (1 or 0),
  `action_<id>_reason` (only when recommended) and `actions_<type>_count`.
  A modal `list` block shows the reasons (an item
  `{"text": "{action_<id>_reason}", "when": "action_<id>"}` per action);
  a colour theme can use the counts.

Both are computed at build time: adding or changing one needs a rebuild,
and new rules are a change to the rules table only. Say so if asked for a
value that is none of these; do not invent rules.

First ask, unless the user already said: is this change just for them,
or for everyone? Just for them: put it in their git-ignored
`map.config.json` (README, Your map config; ADR 0009) as a `style` patch
under `overrides.<name>` (a list such as `sections` is replaced whole, so
copy it and edit the copy), apply it as in step 4, take the screenshots,
and stop: no branch, no PR. For everyone: the steps below.

## 1. Attributes available

In the built tiles (the names to use in the config):

```sh
docker compose run --rm --entrypoint sh pipeline -c \
  'pmtiles show --metadata /data/tiles/<name>.pmtiles | jq .vector_layers[0].fields'
```

plus the feature id (`LAYER_FEATURE_ID`, shown with `{"featureId": true}`
or `{$id}`). `LAYER_FIELDS` in `<name>.env` lists the source ones as
`src:dest`, `LAYER_CALCULATED` the calculated fields and `LAYER_RULES`
the rules table. The layer's data as its build would make it, with the
calculated fields, their value ranges and the rule counts, without
building:

```sh
docker compose run --rm --build --entrypoint inspect.sh pipeline --config <name>
```

and the source alone (names before the renames, with value ranges):

```sh
docker compose run --rm --build --entrypoint inspect.sh pipeline <LAYER_INPUT>
```

Say which of the wanted values are tiled and which are not.

## 2. Before

Make sure the layer is built and current
(`docker compose run --rm pipeline --status <name>`). Pick a view centred
on a feature with typical values (`zoom/lat/lon`; the entry's `center` in
`data/tiles/manifest.json` is a start) and take the before shot with the
feature clicked:

```sh
scripts/screenshot.sh -b light --click -n <name>-before <z/lat/lon>
```

Check the file shows the pop-up or modal; if it says `nothing to show at
the centre`, pick a view whose centre is on a feature.

## 3. Edit

Change only the `popup` or `modal` of `<name>.style.json`:

- Pop-up: `title` (value source), `stats` (`label`, `value`, `format`),
  `charts` (`bar` or `line`, `points`).
- Modal: `title` and `subtitle` with placeholders (`{attr}`,
  `{attr:percent}`, `{$id}`), an optional `layout` (`tabs`, the default:
  one tab per section, labelled by its `heading` or a shorter `tab`, which
  must not repeat; or `scroll`: all sections in one scroll), then
  `sections` (`heading`, `tab`, `description`,
  `blocks`). Blocks: `attributes`, `table` (one attribute per column in
  each row's `values`, `null` for an empty cell), `chart` (`bar` with one
  or more `series`, `pie` or `doughnut` with one; one attribute per
  category), `text`, `list` (`items` with `text` and an optional `when`
  flag attribute, and an `empty` message). A section is a config change
  only: no code.
- Formats: a preset (`percent` for values already 0 to 100, `hectares`,
  `km`, `count`, `number`) or `{"preset": ..., "decimals": ...}`.
- Switching a layer from `popup` to `modal` (or back): remove the other.

Anything a feature has no value for is hidden, so a template can name
attributes some features lack. Check the config without building:

```sh
docker compose run --rm --entrypoint sh pipeline -c \
  'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/<name>.style.json'
```

## 4. Apply

Every value already in the tiles (the usual case): display only, seconds,
no re-tiling.

```sh
docker compose run --rm pipeline --style-only <name>
```

A value not in the tiles: add it to `LAYER_FIELDS` in `<name>.env` (as
`src` or `src:dest`), or as a calculated field (`LAYER_CALCULATED`; the
fields it reads must be in `LAYER_FIELDS`), or point `LAYER_RULES` at a
rules table for rule attributes; then rebuild the layer, and tell the user
it is a rebuild (minutes for a large layer):

```sh
docker compose run --rm --build pipeline <name>
```

Either fails with one line per problem and changes nothing; fix and
rerun. Afterwards `--status <name>` should say `current`.

## 5. After

```sh
scripts/screenshot.sh -b light --click -n <name>-after <same view>
```

Compare before and after (files in `tmp/screenshots/`, ending in
`-click.png`): every new section or value shows, numbers are formatted as
intended, nothing says n/a or is hidden unexpectedly, and there are no
`page error` lines. Add `--size 390x844` for a phone-sized check of a
modal. A modal in the `tabs` layout opens on its first tab: add `--tab
<label>` (repeatable, the label as shown) for one more screenshot of each
tab you changed (`-click-tab-<label>.png`), before and after. Iterate
(edit, apply, screenshot) and show the user the final pair.

## 6. Draft PR

Branch from `main` (`feat/popup-<name>`), commit only the `.style.json`
(plus the `.env` if step 4 needed a rebuild; say so in the PR, for
example `feat(layers): add a threats section to the <name> modal`), push
and open a DRAFT PR describing the change and that before and after
screenshots of a clicked feature were checked. Never mark it ready: ready
PRs merge themselves.
