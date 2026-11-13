import type {
  BasemapName,
  Display,
  FormatPreset,
  LayerDefinition,
  LayerType,
  MapDefaults,
} from './types';

/**
 * Reads the layers from the pipeline's `manifest.json` (ADR 0007), the
 * runtime contract between the pipeline and the app: each entry names the
 * archive and carries the resolved `display` block of its
 * `<layer>.style.json`. The pipeline has already validated it against the
 * shared JSON Schema; this checks it again, by hand, so a stale or edited
 * manifest cannot break the map. `schema.test.ts` keeps these checks in
 * step with the schema. An entry with `enabled: false` (built, then left
 * out by the local map config, ADR 0009) is not shown, and the manifest's
 * `map` gives the opening view and basemap.
 */

/** A layer list that could not be read at all. */
export class ManifestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ManifestError';
  }
}

/** What the map gets from the manifest. */
export interface ManifestLayers {
  /** Valid layers in draw order (last on top). */
  layers: LayerDefinition[];
  /** A short message for the layer panel when something is wrong, else null. */
  problem: string | null;
  /** How the map opens, from the manifest's `map`; null when it sets none. */
  map: MapDefaults | null;
}

/** Messages shown in the layer panel. */
export const MESSAGES = {
  missing:
    'Data layers are not available: the layer list (manifest.json) could not be loaded. Build the tiles with the pipeline, then reload.',
  invalid:
    'Data layers are not available: the layer list (manifest.json) is not valid. Rebuild the tiles with the pipeline, then reload.',
  empty: 'No data layers have been built yet.',
  allDisabled: 'Every built data layer is turned off in your map config (map.config.json).',
  skipped: (n: number) =>
    n === 1
      ? '1 layer in manifest.json could not be read and is not shown.'
      : `${n} layers in manifest.json could not be read and are not shown.`,
} as const;

// Same rules as the pipeline: layer names (lib/config.sh) and style layer
// ids and types (the schema's styleLayer).
const LAYER_NAME = /^[a-z0-9][a-z0-9_-]*$/;
const ARCHIVE_FILE = /^[A-Za-z0-9_.-]+\.pmtiles$/;
const COG_FILE = /^[A-Za-z0-9_.-]+\.cog\.tif$/;
const STYLE_LAYER_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
// Style layer types per layer type: a raster layer is drawn with the one
// `color-relief` layer the pipeline expands from its raster shorthand.
const STYLE_LAYER_TYPES: Record<LayerType, readonly string[]> = {
  vector: ['fill', 'line', 'symbol', 'circle', 'heatmap', 'fill-extrusion'],
  raster: ['color-relief'],
};

type Problems = string[];
type Json = Record<string, unknown>;

const isObject = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);
const isText = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

/**
 * Checks that `value` is an object with every `required` key and no keys
 * outside `allowed`; adds problems at `path` and returns the object.
 */
function object(
  value: unknown,
  path: string,
  problems: Problems,
  required: readonly string[],
  optional: readonly string[] = [],
): Json | null {
  if (!isObject(value)) {
    problems.push(`${path} must be an object`);
    return null;
  }
  for (const key of required) if (!(key in value)) problems.push(`${path}.${key} is missing`);
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) {
      problems.push(`${path}.${key} is not allowed`);
    }
  }
  return value;
}

function check(ok: boolean, message: string, problems: Problems): void {
  if (!ok) problems.push(message);
}

function list(value: unknown, path: string, problems: Problems, minItems = 0): unknown[] {
  if (!Array.isArray(value)) {
    problems.push(`${path} must be a list`);
    return [];
  }
  if (value.length < minItems) problems.push(`${path} must have at least ${minItems} item(s)`);
  return value;
}

function valueSource(value: unknown, path: string, problems: Problems): void {
  if (isObject(value) && 'featureId' in value) {
    object(value, path, problems, ['featureId']);
    check(value.featureId === true, `${path}.featureId must be true`, problems);
    return;
  }
  const source = object(value, path, problems, ['attribute']);
  if (source) check(isText(source.attribute), `${path}.attribute must be text`, problems);
}

/** The number format presets (schema `$defs/formatPreset`). */
export const FORMAT_PRESETS: readonly FormatPreset[] = ['number', 'count', 'percent', 'hectares', 'km'];

const isPreset = (v: unknown): v is FormatPreset => FORMAT_PRESETS.includes(v as FormatPreset);

/** A format: a preset name, or an object (schema `$defs/format`). */
function numberFormat(value: unknown, path: string, problems: Problems): void {
  if (typeof value === 'string') {
    check(isPreset(value), `${path} must be one of ${FORMAT_PRESETS.join(', ')}`, problems);
    return;
  }
  const format = object(value, path, problems, [], ['preset', 'decimals', 'grouping', 'suffix']);
  if (!format) return;
  const { preset, decimals, grouping, suffix } = format;
  if (preset !== undefined) {
    check(isPreset(preset), `${path}.preset must be one of ${FORMAT_PRESETS.join(', ')}`, problems);
  }
  if (decimals !== undefined) {
    check(
      Number.isInteger(decimals) && (decimals as number) >= 0 && (decimals as number) <= 20,
      `${path}.decimals must be a whole number from 0 to 20`,
      problems,
    );
  }
  if (grouping !== undefined) check(typeof grouping === 'boolean', `${path}.grouping must be true or false`, problems);
  if (suffix !== undefined) check(typeof suffix === 'string', `${path}.suffix must be text`, problems);
}

/** A labelled value (schema `$defs/popupStat`). */
function stat(value: unknown, where: string, problems: Problems): void {
  const s = object(value, where, problems, ['label', 'value'], ['format']);
  if (!s) return;
  check(isText(s.label), `${where}.label must be text`, problems);
  valueSource(s.value, `${where}.value`, problems);
  if (s.format !== undefined) numberFormat(s.format, `${where}.format`, problems);
}

function popup(value: unknown, path: string, problems: Problems): void {
  const p = object(value, path, problems, ['title', 'stats'], ['charts']);
  if (!p) return;
  valueSource(p.title, `${path}.title`, problems);
  list(p.stats, `${path}.stats`, problems).forEach((item, i) => stat(item, `${path}.stats[${i}]`, problems));
  if (p.charts === undefined) return;
  list(p.charts, `${path}.charts`, problems).forEach((item, i) => {
    const where = `${path}.charts[${i}]`;
    const chart = object(item, where, problems, ['type', 'title', 'valueLabel', 'points']);
    if (!chart) return;
    check(chart.type === 'bar' || chart.type === 'line', `${where}.type must be bar or line`, problems);
    check(isText(chart.title), `${where}.title must be text`, problems);
    check(isText(chart.valueLabel), `${where}.valueLabel must be text`, problems);
    list(chart.points, `${where}.points`, problems, 1).forEach((pointItem, j) => {
      const at = `${where}.points[${j}]`;
      const point = object(pointItem, at, problems, ['label', 'attribute']);
      if (!point) return;
      check(typeof point.label === 'string', `${at}.label must be text`, problems);
      check(isText(point.attribute), `${at}.attribute must be text`, problems);
    });
  });
}

/** Text, or null where the schema allows it (`$defs/cellAttribute`). */
function cells(value: unknown, path: string, problems: Problems, length: number, what: string): void {
  const items = list(value, path, problems, 1);
  items.forEach((v, i) => check(v === null || isText(v), `${path}[${i}] must be an attribute or null`, problems));
  check(items.length === length, `${path} must have one item per ${what} (${length})`, problems);
}

const BLOCK_TYPES = ['attributes', 'table', 'chart', 'text', 'list'] as const;

/** One block of a modal section (schema `$defs/modalBlock`). */
function modalBlock(value: unknown, path: string, problems: Problems): void {
  if (!isObject(value)) {
    problems.push(`${path} must be an object`);
    return;
  }
  switch (value.type) {
    case 'attributes': {
      const b = object(value, path, problems, ['type', 'items']);
      if (b) list(b.items, `${path}.items`, problems, 1).forEach((item, i) => stat(item, `${path}.items[${i}]`, problems));
      return;
    }
    case 'table': {
      const b = object(value, path, problems, ['type', 'columns', 'rows'], ['caption', 'rowHeader']);
      if (!b) return;
      if (b.caption !== undefined) check(isText(b.caption), `${path}.caption must be text`, problems);
      if (b.rowHeader !== undefined) check(isText(b.rowHeader), `${path}.rowHeader must be text`, problems);
      const columns = list(b.columns, `${path}.columns`, problems, 1);
      columns.forEach((item, i) => {
        const where = `${path}.columns[${i}]`;
        const column = object(item, where, problems, ['label'], ['format']);
        if (!column) return;
        check(isText(column.label), `${where}.label must be text`, problems);
        if (column.format !== undefined) numberFormat(column.format, `${where}.format`, problems);
      });
      list(b.rows, `${path}.rows`, problems, 1).forEach((item, i) => {
        const where = `${path}.rows[${i}]`;
        const row = object(item, where, problems, ['label', 'values']);
        if (!row) return;
        check(isText(row.label), `${where}.label must be text`, problems);
        cells(row.values, `${where}.values`, problems, columns.length, 'column');
      });
      return;
    }
    case 'chart': {
      const b = object(
        value,
        path,
        problems,
        ['type', 'chart', 'title', 'valueLabel', 'categories', 'series'],
        ['format', 'colors'],
      );
      if (!b) return;
      check(['bar', 'pie', 'doughnut'].includes(b.chart as string), `${path}.chart must be bar, pie or doughnut`, problems);
      check(isText(b.title), `${path}.title must be text`, problems);
      check(isText(b.valueLabel), `${path}.valueLabel must be text`, problems);
      if (b.format !== undefined) numberFormat(b.format, `${path}.format`, problems);
      const categories = list(b.categories, `${path}.categories`, problems, 1);
      categories.forEach((c, i) => check(isText(c), `${path}.categories[${i}] must be text`, problems));
      const series = list(b.series, `${path}.series`, problems, 1);
      series.forEach((item, i) => {
        const where = `${path}.series[${i}]`;
        const s = object(item, where, problems, ['label', 'attributes'], ['color']);
        if (!s) return;
        check(isText(s.label), `${where}.label must be text`, problems);
        cells(s.attributes, `${where}.attributes`, problems, categories.length, 'category');
        if (s.color !== undefined) check(isText(s.color), `${where}.color must be a colour`, problems);
      });
      if (b.chart !== 'bar') check(series.length === 1, `${path}: a ${String(b.chart)} chart takes one series`, problems);
      if (b.colors !== undefined) {
        const colors = list(b.colors, `${path}.colors`, problems, 1);
        colors.forEach((c, i) => check(isText(c), `${path}.colors[${i}] must be a colour`, problems));
        check(colors.length === categories.length, `${path}.colors must have one colour per category`, problems);
      }
      return;
    }
    case 'text': {
      const b = object(value, path, problems, ['type', 'text']);
      if (b) check(isText(b.text), `${path}.text must be text`, problems);
      return;
    }
    case 'list': {
      const b = object(value, path, problems, ['type', 'items', 'empty']);
      if (!b) return;
      check(isText(b.empty), `${path}.empty must be text`, problems);
      list(b.items, `${path}.items`, problems, 1).forEach((item, i) => {
        const where = `${path}.items[${i}]`;
        const entry = object(item, where, problems, ['text'], ['when']);
        if (!entry) return;
        check(isText(entry.text), `${where}.text must be text`, problems);
        if (entry.when !== undefined) check(isText(entry.when), `${where}.when must be an attribute`, problems);
      });
      return;
    }
  }
  problems.push(`${path}.type must be one of ${BLOCK_TYPES.join(', ')}`);
}

/** A click modal template (schema `$defs/modal`). */
function modal(value: unknown, path: string, problems: Problems): void {
  const m = object(value, path, problems, ['title', 'sections'], ['subtitle']);
  if (!m) return;
  check(isText(m.title), `${path}.title must be text`, problems);
  if (m.subtitle !== undefined) check(isText(m.subtitle), `${path}.subtitle must be text`, problems);
  list(m.sections, `${path}.sections`, problems, 1).forEach((item, i) => {
    const where = `${path}.sections[${i}]`;
    const section = object(item, where, problems, ['heading'], ['description', 'blocks']);
    if (!section) return;
    check(isText(section.heading), `${where}.heading must be text`, problems);
    check(
      section.description !== undefined || section.blocks !== undefined,
      `${where} needs a description or blocks`,
      problems,
    );
    if (section.description !== undefined) {
      check(isText(section.description), `${where}.description must be text`, problems);
    }
    if (section.blocks !== undefined) {
      list(section.blocks, `${where}.blocks`, problems, 1).forEach((block, j) =>
        modalBlock(block, `${where}.blocks[${j}]`, problems),
      );
    }
  });
}

const THEME_ID = STYLE_LAYER_ID;

/** Colour themes (schema `$defs/resolvedTheme`) and the default among them. */
function themes(value: unknown, defaultTheme: unknown, path: string, problems: Problems): void {
  const ids = new Set<string>();
  list(value, `${path}.themes`, problems, 1).forEach((item, i) => {
    const where = `${path}.themes[${i}]`;
    const theme = object(item, where, problems, ['id', 'label', 'paint', 'legend']);
    if (!theme) return;
    const { id } = theme;
    check(typeof id === 'string' && THEME_ID.test(id), `${where}.id is not a valid id`, problems);
    if (typeof id === 'string') {
      check(!ids.has(id), `${where}.id ${id} is used twice`, problems);
      ids.add(id);
    }
    check(isText(theme.label), `${where}.label must be text`, problems);
    const paint = theme.paint;
    if (!isObject(paint) || Object.keys(paint).length === 0) {
      problems.push(`${where}.paint must be an object of style layer paint properties`);
    } else {
      for (const [layerId, props] of Object.entries(paint)) {
        check(
          isObject(props) && Object.keys(props).length > 0,
          `${where}.paint.${layerId} must be an object of paint properties`,
          problems,
        );
      }
    }
    legend(theme.legend, `${where}.legend`, problems);
  });
  check(
    typeof defaultTheme === 'string' && ids.has(defaultTheme),
    `${path}.defaultTheme must be the id of one of the themes`,
    problems,
  );
}

const LEGEND_KINDS = ['single', 'categories', 'ramp', 'gradient'];

function legend(value: unknown, path: string, problems: Problems): void {
  const l = object(value, path, problems, ['kind', 'shape', 'border', 'opacity', 'items']);
  if (!l) return;
  check(LEGEND_KINDS.includes(l.kind as string), `${path}.kind must be ${LEGEND_KINDS.join(', ')}`, problems);
  check(
    l.shape === 'square' || l.shape === 'circle' || l.shape === 'line',
    `${path}.shape must be square, circle or line`,
    problems,
  );
  check(isText(l.border), `${path}.border must be a colour`, problems);
  check(
    typeof l.opacity === 'number' && l.opacity >= 0 && l.opacity <= 1,
    `${path}.opacity must be a number from 0 to 1`,
    problems,
  );
  list(l.items, `${path}.items`, problems, 1).forEach((item, i) => {
    const where = `${path}.items[${i}]`;
    const entry = object(item, where, problems, ['color', 'label'], ['position']);
    if (!entry) return;
    check(isText(entry.color), `${where}.color must be a colour`, problems);
    check(isText(entry.label), `${where}.label must be text`, problems);
    const { position } = entry;
    if (position !== undefined) {
      check(
        typeof position === 'number' && position >= 0 && position <= 1,
        `${where}.position must be a number from 0 to 1`,
        problems,
      );
    }
  });
}

function styleLayers(value: unknown, path: string, problems: Problems, layerType: LayerType): void {
  const seen = new Set<string>();
  list(value, path, problems, 1).forEach((item, i) => {
    const where = `${path}[${i}]`;
    if (!isObject(item)) {
      problems.push(`${where} must be an object`);
      return;
    }
    // Other style-spec properties are passed to MapLibre as they are; the
    // pipeline has checked them with the MapLibre style validator.
    const { id, type } = item;
    check(typeof id === 'string' && STYLE_LAYER_ID.test(id), `${where}.id is not a valid id`, problems);
    check(
      STYLE_LAYER_TYPES[layerType].includes(type as string),
      `${where}.type is not a ${layerType} layer type`,
      problems,
    );
    check(!('source' in item) && !('source-layer' in item), `${where} must not set its source`, problems);
    if (typeof id === 'string') {
      check(!seen.has(id), `${where}.id ${id} is used twice`, problems);
      seen.add(id);
    }
  });
}

/**
 * Problems with a manifest `display` block (schema `$defs/display`), as
 * plain text; empty when it is valid. Style layer ids must also be unique,
 * which the pipeline checks outside the schema, and theme paint must name
 * them. A raster layer has one `color-relief` style layer and no pop-up,
 * modal or themes; a vector layer has vector style layers only, and a
 * pop-up or a modal, not both.
 */
export function displayProblems(
  value: unknown,
  path = 'display',
  layerType: LayerType = 'vector',
): string[] {
  const problems: Problems = [];
  const d = object(
    value,
    path,
    problems,
    ['title', 'defaultVisible', 'order', 'layers', 'legend'],
    ['popup', 'modal', 'themes', 'defaultTheme'],
  );
  if (!d) return problems;
  check(isText(d.title), `${path}.title must be text`, problems);
  check(typeof d.defaultVisible === 'boolean', `${path}.defaultVisible must be true or false`, problems);
  check(Number.isInteger(d.order), `${path}.order must be a whole number`, problems);
  styleLayers(d.layers, `${path}.layers`, problems, layerType);
  legend(d.legend, `${path}.legend`, problems);
  const raster = layerType === 'raster';
  if (d.popup !== undefined && d.modal !== undefined) {
    problems.push(`${path} has both a popup and a modal`);
  }
  if (d.popup !== undefined) {
    if (raster) problems.push(`${path}.popup is not allowed on a raster layer`);
    else popup(d.popup, `${path}.popup`, problems);
  }
  if (d.modal !== undefined) {
    if (raster) problems.push(`${path}.modal is not allowed on a raster layer`);
    else modal(d.modal, `${path}.modal`, problems);
  }
  if (d.themes !== undefined || d.defaultTheme !== undefined) {
    if (raster) problems.push(`${path}.themes are not allowed on a raster layer`);
    else {
      themes(d.themes, d.defaultTheme, path, problems);
      const ids = new Set(Array.isArray(d.layers) ? d.layers.map((l) => (isObject(l) ? l.id : undefined)) : []);
      (Array.isArray(d.themes) ? d.themes : []).forEach((t, i) => {
        if (!isObject(t) || !isObject(t.paint)) return;
        for (const layerId of Object.keys(t.paint)) {
          check(ids.has(layerId), `${path}.themes[${i}].paint.${layerId} is not a style layer of this layer`, problems);
        }
      });
    }
  }
  return problems;
}

/** A manifest entry as a layer definition, or the problems that stop it. */
function toDefinition(entry: unknown, index: number): LayerDefinition | string[] {
  const where = `layers[${index}]`;
  if (!isObject(entry)) return [`${where} must be an object`];
  const problems: Problems = [];
  const { name, file } = entry;
  // Entries written before raster layers have no type: they are vector.
  const type = entry.type ?? 'vector';
  check(typeof name === 'string' && LAYER_NAME.test(name), `${where}.name is not a valid layer name`, problems);
  if (type !== 'vector' && type !== 'raster') {
    problems.push(`${where}.type must be vector or raster`);
    return problems;
  }
  // A vector layer is a .pmtiles archive; a raster one a COG (.cog.tif,
  // ADR 0010), or a .pmtiles of PNG tiles if built before COGs.
  const fileOk =
    typeof file === 'string' &&
    (ARCHIVE_FILE.test(file) || (type === 'raster' && COG_FILE.test(file)));
  check(
    fileOk,
    type === 'raster'
      ? `${where}.file is not a .cog.tif or .pmtiles file name`
      : `${where}.file is not a .pmtiles file name`,
    problems,
  );
  if (entry.display === undefined || entry.display === null) {
    problems.push(`${where}.display is missing (built before display configs; rebuild the layer)`);
  } else {
    problems.push(...displayProblems(entry.display, `${where}.display`, type));
  }
  if (problems.length) return problems;

  const display = entry.display as Display;
  return {
    id: name as string,
    type,
    title: display.title,
    file: file as string,
    sourceLayer: name as string,
    defaultVisible: display.defaultVisible,
    order: display.order,
    layers: display.layers,
    legend: display.legend,
    ...(display.popup ? { popup: display.popup } : {}),
    ...(display.modal ? { modal: display.modal } : {}),
    ...(display.themes ? { themes: display.themes, defaultTheme: display.defaultTheme } : {}),
  };
}

/** Draw order: ascending `order`, then id, as in the pipeline's style.json. */
export function drawOrder(defs: readonly LayerDefinition[]): LayerDefinition[] {
  return [...defs].sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * Reads a parsed `manifest.json` into layer definitions in draw order.
 * Entries that are not valid (or repeat a name) are left out with a
 * console warning and counted in `problem`; entries with `enabled: false`
 * are left out quietly.
 *
 * @throws {ManifestError} when the manifest has no `layers` list.
 */
export function parseManifest(json: unknown): ManifestLayers {
  if (!isObject(json) || !Array.isArray(json.layers)) {
    throw new ManifestError('manifest.json has no layers list');
  }
  const defs: LayerDefinition[] = [];
  let skipped = 0;
  let disabled = 0;
  json.layers.forEach((entry, i) => {
    if (isObject(entry) && entry.enabled === false) {
      disabled++;
      return;
    }
    const result = toDefinition(entry, i);
    if (Array.isArray(result)) {
      console.warn(`manifest.json: layer ${i} skipped:\n${result.join('\n')}`);
      skipped++;
    } else if (defs.some((def) => def.id === result.id)) {
      console.warn(`manifest.json: layer ${i} skipped: "${result.id}" is listed twice.`);
      skipped++;
    } else {
      defs.push(result);
    }
  });
  let problem: string | null = null;
  if (skipped) problem = MESSAGES.skipped(skipped);
  else if (defs.length === 0) problem = disabled ? MESSAGES.allDisabled : MESSAGES.empty;
  return { layers: drawOrder(defs), problem, map: mapDefaults(json.map) };
}

/** The basemaps the map config may name (`map.config.schema.json`). */
export const BASEMAP_NAMES: readonly BasemapName[] = ['light', 'dark'];

const inRange = (v: unknown, min: number, max: number): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;

/**
 * The manifest's `map` (the local map config's opening view and basemap,
 * ADR 0009) as map defaults, or null when there is none. A field that is
 * not valid is left out with a console warning, so the app's own default
 * applies to it.
 */
export function mapDefaults(value: unknown): MapDefaults | null {
  if (value === undefined || value === null) return null;
  if (!isObject(value)) {
    console.warn('manifest.json: map ignored: not an object.');
    return null;
  }
  const defaults: MapDefaults = {};
  const { center, zoom, basemap } = value;
  if (center !== undefined) {
    if (Array.isArray(center) && center.length === 2 && inRange(center[0], -180, 180) && inRange(center[1], -90, 90)) {
      defaults.center = [center[0], center[1]];
    } else {
      console.warn('manifest.json: map.center ignored: not [longitude, latitude].');
    }
  }
  if (zoom !== undefined) {
    if (inRange(zoom, 0, 22)) defaults.zoom = zoom;
    else console.warn('manifest.json: map.zoom ignored: not a number from 0 to 22.');
  }
  if (basemap !== undefined) {
    if (BASEMAP_NAMES.includes(basemap as BasemapName)) defaults.basemap = basemap as BasemapName;
    else console.warn(`manifest.json: map.basemap ignored: not one of ${BASEMAP_NAMES.join(', ')}.`);
  }
  return defaults;
}

/** The `manifest.json` URL in the folder holding the archives. */
export function manifestUrl(tilesBaseUrl: string): string {
  return new URL('manifest.json', tilesBaseUrl).href;
}

export interface LoadOptions {
  signal?: AbortSignal;
  /** For tests; defaults to the global `fetch`. */
  fetch?: typeof fetch;
}

/**
 * Fetches and reads `manifest.json` (revalidated on every load, so a
 * pipeline run shows on reload). Never rejects: a missing or invalid
 * manifest gives no layers and a `problem` for the panel, and the basemap
 * still shows. An aborted load gives no layers and no problem.
 */
export async function loadManifest(url: string, options: LoadOptions = {}): Promise<ManifestLayers> {
  const { signal, fetch: fetchFn = fetch } = options;
  const none = (problem: string | null): ManifestLayers => ({ layers: [], problem, map: null });
  let response: Response;
  try {
    response = await fetchFn(url, { cache: 'no-cache', signal });
  } catch (error) {
    if (signal?.aborted) return none(null);
    console.warn(`Could not fetch ${url}.`, error);
    return none(MESSAGES.missing);
  }
  if (!response.ok) {
    console.warn(`Could not fetch ${url}: HTTP ${response.status}.`);
    return none(MESSAGES.missing);
  }
  try {
    return parseManifest(await response.json());
  } catch (error) {
    if (signal?.aborted) return none(null);
    console.warn(`${url} is not a valid layer list.`, error);
    return none(MESSAGES.invalid);
  }
}
