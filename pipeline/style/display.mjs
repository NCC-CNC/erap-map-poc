// Resolves a layer display config (pipeline/layers/<layer>.style.json) into
// the `display` block of its manifest.json entry, and builds the combined
// style.json. ADR 0007; docs/design/02_data_layers_and_popups.md.
//
// Everything here is pure (no file or process access) so it is easy to
// test; cli.mjs does the I/O.

import { readFileSync } from 'node:fs';
import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec';
import Ajv2020 from 'ajv/dist/2020.js';

/** The shared JSON Schema, also read by the web app's tests. */
export const SCHEMA_URL = new URL('../schema/layer-style.schema.json', import.meta.url);

/** Default draw order of a layer without `order`. */
export const DEFAULT_ORDER = 0;

/** Glyphs for symbol layers with text in the standalone style.json. */
export const GLYPHS_URL = 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';

/** An error in a layer's display config, with every problem found. */
export class DisplayError extends Error {
  /** @param {string[]} problems */
  constructor(problems) {
    super(problems.join('\n'));
    this.name = 'DisplayError';
    this.problems = problems;
  }
}

let validators;

/** Compiled schema validators for the config file and the resolved block. */
function schemaValidators() {
  if (!validators) {
    const schema = JSON.parse(readFileSync(SCHEMA_URL, 'utf8'));
    const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
    ajv.addSchema(schema);
    validators = {
      config: ajv.getSchema(schema.$id),
      display: ajv.getSchema(`${schema.$id}#/$defs/display`),
    };
  }
  return validators;
}

/** Readable schema errors, without the noise of failed `if` branches. */
function schemaProblems(errors) {
  const seen = new Set();
  for (const e of errors ?? []) {
    if (e.keyword === 'if') continue;
    const where = e.instancePath || '(top level)';
    let detail = e.message ?? 'is invalid';
    if (e.keyword === 'additionalProperties') detail += `: ${e.params.additionalProperty}`;
    if (e.keyword === 'false schema') detail = 'is not allowed here';
    if (e.keyword === 'enum') detail += `: ${e.params.allowedValues.join(', ')}`;
    seen.add(`${where} ${detail}`);
  }
  return [...seen];
}

/** Checks a config against the JSON Schema; throws DisplayError. */
export function validateConfig(config) {
  const { config: validate } = schemaValidators();
  if (!validate(config)) throw new DisplayError(schemaProblems(validate.errors));
}

/** Checks a resolved display block against the schema; throws DisplayError. */
export function validateDisplay(display) {
  const { display: validate } = schemaValidators();
  if (!validate(display)) throw new DisplayError(schemaProblems(validate.errors));
}

// ---------------------------------------------------------------------------
// Breaks

/** Rounds away floating point noise such as 33.333333333333336. */
function tidy(value) {
  return Number(value.toPrecision(12));
}

/**
 * Class lower bounds for `classes` classes over `values` (finite numbers),
 * plus the maximum for the legend.
 *
 *   equal:    min + i * (max - min) / classes
 *   quantile: the value at rank floor(i * n / classes) of the sorted
 *             values, so each class holds about n / classes features.
 *
 * The first bound is always the minimum. Throws when there are no values
 * or the bounds are not strictly ascending (too few distinct values).
 */
export function computeBreaks(values, method, classes) {
  const sorted = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (sorted.length === 0) throw new DisplayError(['breaks: no numeric values in the data']);
  const min = sorted[0];
  const max = sorted[sorted.length - 1];
  const bounds = [];
  for (let i = 0; i < classes; i++) {
    if (method === 'equal') bounds.push(tidy(min + (i * (max - min)) / classes));
    else bounds.push(sorted[Math.floor((i * sorted.length) / classes)]);
  }
  for (let i = 1; i < bounds.length; i++) {
    if (!(bounds[i] > bounds[i - 1])) {
      throw new DisplayError([
        `breaks: ${method} breaks with ${classes} classes are not distinct (${bounds.join(', ')}); use fewer classes or another method`,
      ]);
    }
  }
  return { bounds, max };
}

/** Numeric values of `attribute` in GeoJSONSeq text (one feature per line). */
export function attributeValues(geojsonl, attribute) {
  const values = [];
  for (const line of geojsonl.split('\n')) {
    const text = line.replace(/^\x1e/, '').trim();
    if (!text) continue;
    const value = JSON.parse(text).properties?.[attribute];
    if (typeof value === 'number' && Number.isFinite(value)) values.push(value);
  }
  return values;
}

/**
 * The colour rule with `breaks` resolved into `stops` and `max`.
 * `valuesOf(attribute)` returns the attribute's numeric values from the data.
 */
function resolveRule(rule, valuesOf) {
  if (rule.type !== 'stepped' || !rule.breaks) return rule;
  const { method, classes } = rule.breaks;
  if (rule.colors.length !== classes) {
    throw new DisplayError([
      `symbology.color: breaks.classes is ${classes} but there are ${rule.colors.length} colors`,
    ]);
  }
  const { bounds, max } = computeBreaks(valuesOf(rule.attribute), method, classes);
  return {
    type: 'stepped',
    attribute: rule.attribute,
    stops: bounds.map((from, i) => ({ from, color: rule.colors[i] })),
    max,
    fallback: rule.fallback,
  };
}

// ---------------------------------------------------------------------------
// Symbology shorthand: style layers and legend

/** The MapLibre colour value (a constant or an expression) for a rule. */
export function colorValue(rule) {
  switch (rule.type) {
    case 'single':
      return rule.color;
    case 'categorical':
      return [
        'match',
        ['to-string', ['get', rule.attribute]],
        ...rule.categories.flatMap((c) => [c.value, c.color]),
        rule.fallback.color,
      ];
    case 'stepped': {
      const [first, ...rest] = rule.stops;
      const value = ['get', rule.attribute];
      const step = ['step', value, first.color, ...rest.flatMap((s) => [s.from, s.color])];
      return ['case', ['==', ['typeof', value], 'number'], step, rule.fallback.color];
    }
  }
  throw new DisplayError([`unknown colour type ${rule.type}`]);
}

/** Style layers for the shorthand, in draw order, with un-prefixed ids. */
export function symbologyLayers(symbology) {
  const color = colorValue(symbology.color);
  if (symbology.geometry === 'polygon') {
    return [
      {
        id: 'fill',
        type: 'fill',
        paint: { 'fill-color': color, 'fill-opacity': symbology.fillOpacity },
      },
      {
        id: 'outline',
        type: 'line',
        paint: { 'line-color': symbology.outline.color, 'line-width': symbology.outline.width },
      },
    ];
  }
  return [
    {
      id: 'circle',
      type: 'circle',
      paint: {
        'circle-color': color,
        'circle-radius': symbology.radius,
        'circle-stroke-color': symbology.stroke.color,
        'circle-stroke-width': symbology.stroke.width,
      },
    },
  ];
}

/** A number in a legend label, with thousands separators. */
export function formatBound(value) {
  return new Intl.NumberFormat('en-CA').format(value);
}

function fallbackItems(fallback) {
  return fallback?.label ? [{ color: fallback.color, label: fallback.label }] : [];
}

/** The legend for the shorthand, from the same rule as its style layers. */
export function symbologyLegend(symbology, title) {
  const rule = symbology.color;
  const polygon = symbology.geometry === 'polygon';
  let kind;
  let items;
  switch (rule.type) {
    case 'single':
      kind = 'single';
      items = [{ color: rule.color, label: rule.label ?? title }];
      break;
    case 'categorical':
      kind = 'categories';
      items = [
        ...rule.categories.map((c) => ({ color: c.color, label: c.label })),
        ...fallbackItems(rule.fallback),
      ];
      break;
    case 'stepped':
      kind = 'ramp';
      items = [
        ...rule.stops.map((stop, i) => ({
          color: stop.color,
          label: `${formatBound(stop.from)} to ${formatBound(rule.stops[i + 1]?.from ?? rule.max)}`,
        })),
        ...fallbackItems(rule.fallback),
      ];
      break;
  }
  return {
    kind,
    shape: polygon ? 'square' : 'circle',
    border: polygon ? symbology.outline.color : symbology.stroke.color,
    opacity: polygon ? symbology.fillOpacity : 1,
    items,
  };
}

// ---------------------------------------------------------------------------
// Legend derivation for raw style layers

/** Paint properties read for a derived legend, per layer type. */
const COLOR_PAINT = {
  fill: 'fill-color',
  'fill-extrusion': 'fill-extrusion-color',
  circle: 'circle-color',
  line: 'line-color',
};
const OPACITY_PAINT = {
  fill: 'fill-opacity',
  'fill-extrusion': 'fill-extrusion-opacity',
  circle: 'circle-opacity',
  line: 'line-opacity',
};
const SHAPE = { fill: 'square', 'fill-extrusion': 'square', circle: 'circle', line: 'line' };

const isColor = (v) => typeof v === 'string' && v.length > 0;

/** Legend kind and items from a colour value, or null if not simple enough. */
function colorItems(value, title) {
  if (isColor(value)) return { kind: 'single', items: [{ color: value, label: title }] };
  if (!Array.isArray(value)) return null;
  const [op, ...args] = value;
  // ['case', condition, <match or step>, fallbackColour]: the shorthand's
  // guard for missing values. The fallback has no label, so it is left out.
  if (op === 'case' && args.length === 3 && isColor(args[2])) return colorItems(args[1], title);
  if (op === 'match') {
    // ['match', input, label1, colour1, ..., fallback]
    const pairs = args.slice(1, -1);
    if (pairs.length < 2 || pairs.length % 2 !== 0) return null;
    const items = [];
    for (let i = 0; i < pairs.length; i += 2) {
      const label = pairs[i];
      const color = pairs[i + 1];
      if (!isColor(color)) return null;
      items.push({ color, label: Array.isArray(label) ? label.join(', ') : String(label) });
    }
    return { kind: 'categories', items };
  }
  if (op === 'step') {
    // ['step', input, colour0, stop1, colour1, ..., stopN, colourN]
    const [, base, ...rest] = args;
    if (!isColor(base) || rest.length < 2 || rest.length % 2 !== 0) return null;
    const stops = [];
    for (let i = 0; i < rest.length; i += 2) {
      if (typeof rest[i] !== 'number' || !isColor(rest[i + 1])) return null;
      stops.push({ from: rest[i], color: rest[i + 1] });
    }
    const items = [{ color: base, label: `Below ${formatBound(stops[0].from)}` }];
    stops.forEach((stop, i) => {
      const next = stops[i + 1];
      items.push({
        color: stop.color,
        label: next
          ? `${formatBound(stop.from)} to ${formatBound(next.from)}`
          : `${formatBound(stop.from)} or more`,
      });
    });
    return { kind: 'ramp', items };
  }
  return null;
}

/**
 * Derives a legend from raw style layers: the colour of the first fill,
 * fill-extrusion, circle or line layer, when it is a constant, a `match` or
 * a `step` with constant colours (optionally inside the shorthand's
 * `case` guard). Returns null when it cannot.
 */
export function deriveLegend(layers, title) {
  const main = layers.find((l) => COLOR_PAINT[l.type]);
  if (!main) return null;
  const derived = colorItems(main.paint?.[COLOR_PAINT[main.type]], title);
  if (!derived) return null;
  const opacity = main.paint?.[OPACITY_PAINT[main.type]];
  let border = 'transparent';
  if (main.type === 'circle' && isColor(main.paint?.['circle-stroke-color'])) {
    border = main.paint['circle-stroke-color'];
  } else if (main.type === 'fill') {
    const outline = layers.find((l) => l.type === 'line' && isColor(l.paint?.['line-color']));
    if (outline) border = outline.paint['line-color'];
    else if (isColor(main.paint?.['fill-outline-color'])) border = main.paint['fill-outline-color'];
  }
  return {
    kind: derived.kind,
    shape: SHAPE[main.type],
    border,
    opacity: typeof opacity === 'number' ? opacity : 1,
    items: derived.items,
  };
}

/** The explicit legend, with missing fields from the derived one or defaults. */
function explicitLegend(legend, derived, layers) {
  const first = layers[0];
  return {
    kind: legend.kind ?? derived?.kind ?? 'categories',
    shape: legend.shape ?? derived?.shape ?? SHAPE[first.type] ?? 'square',
    border: legend.border ?? derived?.border ?? 'transparent',
    opacity: legend.opacity ?? derived?.opacity ?? 1,
    items: legend.items,
  };
}

// ---------------------------------------------------------------------------
// Style layers in a full style: ids, sources, validation

/** The id of a style layer on the map: prefixed with the layer name. */
export function styleLayerId(layerName, id) {
  return `${layerName}-${id}`;
}

/** Style layers of one data layer, wired to its source, with prefixed ids. */
export function sourcedLayers(layerName, layers, visible) {
  return layers.map((layer) => ({
    ...layer,
    id: styleLayerId(layerName, layer.id),
    source: layerName,
    'source-layer': layerName,
    layout: { ...layer.layout, visibility: visible ? 'visible' : 'none' },
  }));
}

const usesText = (layers) => layers.some((l) => l.type === 'symbol' && l.layout?.['text-field']);

/**
 * A standalone MapLibre style of data layers, each entry being
 * `{name, file, display}`, drawn in the order given. Sources are
 * `pmtiles://<file>`, relative to the folder holding the style.
 */
export function buildStyle(entries) {
  const layers = entries.flatMap((e) =>
    sourcedLayers(e.name, e.display.layers, e.display.defaultVisible),
  );
  return {
    version: 8,
    name: 'ERAP Map data layers',
    ...(usesText(layers) ? { glyphs: GLYPHS_URL } : {}),
    sources: Object.fromEntries(
      entries.map((e) => [e.name, { type: 'vector', url: `pmtiles://${e.file}` }]),
    ),
    layers,
  };
}

/** Problems the MapLibre style validator finds in a style, as text. */
export function styleProblems(style) {
  return validateStyleMin(style).map((e) => e.message);
}

/** Entries in draw order: ascending `order`, then name. */
export function drawOrder(entries) {
  return [...entries].sort(
    (a, b) => a.display.order - b.display.order || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
  );
}

// ---------------------------------------------------------------------------
// Resolve one layer

/**
 * Resolves a layer's display config into its manifest `display` block:
 * schema check, breaks resolved from the data, shorthand expanded, legend
 * filled in, and the style layers checked with the MapLibre validator.
 *
 * @param {string} layerName the layer name (also source and source layer).
 * @param {object} config the parsed .style.json.
 * @param {(attribute: string) => number[]} [valuesOf] numeric values of an
 *   attribute in the layer's data; needed only for `breaks`.
 * @throws {DisplayError} listing every problem found.
 */
export function resolveDisplay(layerName, config, valuesOf) {
  validateConfig(config);

  let layers;
  let derived;
  if (config.symbology) {
    const needsData = config.symbology.color.type === 'stepped' && config.symbology.color.breaks;
    if (needsData && !valuesOf) throw new DisplayError(['breaks need the layer data']);
    const symbology = { ...config.symbology, color: resolveRule(config.symbology.color, valuesOf) };
    layers = symbologyLayers(symbology);
    derived = symbologyLegend(symbology, config.title);
  } else {
    layers = config.layers;
    const ids = layers.map((l) => l.id);
    const dupes = ids.filter((id, i) => ids.indexOf(id) !== i);
    if (dupes.length) {
      throw new DisplayError([`layers: duplicate id ${[...new Set(dupes)].join(', ')}`]);
    }
    derived = deriveLegend(layers, config.title);
  }

  let legend;
  if (config.legend) legend = explicitLegend(config.legend, derived, layers);
  else if (derived) legend = derived;
  else {
    throw new DisplayError([
      'legend: cannot derive a legend from these layers (the first fill, circle or line colour must be a constant, a match or a step with constant colours); add an explicit "legend"',
    ]);
  }

  const display = {
    title: config.title,
    defaultVisible: config.defaultVisible,
    order: config.order ?? DEFAULT_ORDER,
    ...(config.popup ? { popup: config.popup } : {}),
    layers,
    legend,
  };

  const style = buildStyle([{ name: layerName, file: `${layerName}.pmtiles`, display }]);
  // Validate as if glyphs were there: the web map's basemap provides them.
  const problems = styleProblems({ ...style, glyphs: GLYPHS_URL });
  if (problems.length) throw new DisplayError(problems.map((p) => `MapLibre style: ${p}`));
  validateDisplay(display);
  return display;
}
