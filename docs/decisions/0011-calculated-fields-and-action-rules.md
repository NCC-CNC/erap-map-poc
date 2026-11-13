# Calculated fields and action rules in the pipeline

## Status

Accepted. Extends 0002-bash-gdal-tippecanoe-pipeline.md (a new build step),
0007-data-driven-layer-styles.md (a new optional per-layer file) and
0009-local-map-config.md (two new override keys).

## Context

The stakeholders decided (issue #14) that all calculations happen in the
pipeline and the web app only displays tile attributes. The ecoregion
details need derived values, such as the unprotected intact and modified
shares for the Opportunities pie, and action recommendations: per
ecoregion, which conservation actions apply and why, from a reference
table the current ERAP app's owners hold (issue #60). Only one rule is
known so far: "Area-based conservation - 30x30 goals: recommended because
current protection is less than 30%" (`protected_pcnt < 30`). The rest
must arrive as a table change, with no code, and users must be able to
change both locally through the map config.

The expressions are user-editable configuration that the pipeline runs, so
they must not be a way to run anything else.

## Decision

- **Calculated fields** are a layer setting, `LAYER_CALCULATED` in the
  `.env`: `name=expression` entries, evaluated per feature at build time
  on the layer's attributes (the `LAYER_FIELDS` output names) and other
  calculated fields, and tiled like any attribute.
- **Action rules** are a committed JSON rules table,
  `pipeline/layers/<table>.rules.json`, with a JSON Schema
  (`pipeline/schema/action-rules.schema.json`), named by a layer's
  `LAYER_RULES`. It lists action types (`id`, `label`) and actions (`id`,
  `type`, `title`, `condition`, `reason`). The first is
  `ecoregions.rules.json` with the one known rule.
- Per feature the build writes `action_<id>` (1 when the condition is
  true, else 0; a null condition counts as false), `action_<id>_reason`
  (`"<title>: <reason>"` when recommended, no attribute otherwise) and per
  type `actions_<type>_count` (how many of its actions are recommended,
  for colour themes). The build report in `manifest.json` gains
  `calculated_fields` (expression, non-null count, min, max) and `rules`
  (per action the features it is recommended for, per type the features
  with at least one), and the provenance `rules_sha256`.
- **Mechanism: GDAL's SQLite SQL dialect**, one extra `ogr2ogr -dialect
  SQLite` pass over the normalised GeoJSONSeq (`SELECT *, <expr> AS
  "name", ... FROM "<layer>"`). It keeps every attribute and geometry as
  they are, needs no new tool and gives SQL semantics people know (NULL
  handling, `CASE`, `ROUND`, `COALESCE`). The alternatives were an
  evaluator of our own in Node (more code to write and test for the same
  language) and jq (no decimal rounding or NULL semantics, and an
  unfamiliar syntax for rule authors).
- **Safety: a small expression language, parsed, not passed through.** The
  display config tool (`pipeline/style/derive.mjs`) parses each
  expression into a tree and writes it back as SQL: literals, attribute
  names (always double quoted), arithmetic, comparison, `AND`, `OR`,
  `NOT`, `IS [NOT] NULL`, `[NOT] IN (...)`, `LIKE`, `BETWEEN`, `CASE`,
  `CAST` and an allow-list of scalar functions (`abs`, `round`, `min`,
  `max` with two or more arguments, `coalesce`, `ifnull`, `nullif`, `iif`,
  `length`, `lower`, `upper`, `substr`, `trim`, `replace`, `instr`). There
  are no statements, `;`, comments, subqueries or other functions, so a
  config cannot read or write files (SpatiaLite has functions that do) or
  run another query. Every operation is bracketed, division is always
  decimal, and unknown attributes, cycles and name clashes are reported
  with the field or rule they are in, before the source data is read.
- **Map config** (0009): an override's `calculated` (name to expression,
  null removes) is appended to `LAYER_CALCULATED`, a later entry for a
  name replacing the earlier one; `rules` is a rules table path relative
  to the map config file, or null for none. Both change the tiles.
- `--status` shows the calculated fields and rule counts of each build
  and reports `stale` when the `.env`, the map config's overrides or the
  rules table's content (by hash) change. `inspect.sh --config LAYER`
  shows a layer's data as its build sees it, calculated fields and rule
  counts included, before a build. `cli.mjs check` also checks
  `.rules.json` files.

## Consequences

- New rules from the ERAP app owners are a change to one JSON file,
  checked by its schema and the pre-check; new derived values are a line
  in a `.env`; neither touches code or the web app.
- An expression can only use attributes that are kept (`LAYER_FIELDS`),
  so an input used only for a calculation is tiled too.
- The reason text is repeated in every recommended feature; tippecanoe
  stores each distinct value once per tile, so the cost is small.
- Rule types with no actions yet still get a count attribute (always 0),
  so a colour theme can name it before the rules arrive.
- SQLite semantics apply: text compares case-sensitively, `NULL` in
  arithmetic gives `NULL`, and integer `%` stays integer.
- The language is deliberately small; a function outside the allow-list
  needs a code change, with a test, rather than a config change.
