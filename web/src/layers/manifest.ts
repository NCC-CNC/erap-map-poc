import type { Display, LayerDefinition } from './types';

/**
 * Reads the layers from the pipeline's `manifest.json` (ADR 0007), the
 * runtime contract between the pipeline and the app: each entry names the
 * archive and carries the resolved `display` block of its
 * `<layer>.style.json`. The pipeline has already validated it against the
 * shared JSON Schema; this checks it again, by hand, so a stale or edited
 * manifest cannot break the map. `schema.test.ts` keeps these checks in
 * step with the schema.
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
}

/** Messages shown in the layer panel. */
export const MESSAGES = {
  missing:
    'Data layers are not available: the layer list (manifest.json) could not be loaded. Build the tiles with the pipeline, then reload.',
  invalid:
    'Data layers are not available: the layer list (manifest.json) is not valid. Rebuild the tiles with the pipeline, then reload.',
  empty: 'No data layers have been built yet.',
  skipped: (n: number) =>
    n === 1
      ? '1 layer in manifest.json could not be read and is not shown.'
      : `${n} layers in manifest.json could not be read and are not shown.`,
} as const;

// Same rules as the pipeline: layer names (lib/config.sh) and style layer
// ids and types (the schema's styleLayer).
const LAYER_NAME = /^[a-z0-9][a-z0-9_-]*$/;
const ARCHIVE_FILE = /^[A-Za-z0-9_.-]+\.pmtiles$/;
const STYLE_LAYER_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
const STYLE_LAYER_TYPES = ['fill', 'line', 'symbol', 'circle', 'heatmap', 'fill-extrusion'];

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

function numberFormat(value: unknown, path: string, problems: Problems): void {
  const format = object(value, path, problems, [], ['decimals', 'grouping', 'suffix']);
  if (!format) return;
  const { decimals, grouping, suffix } = format;
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

function popup(value: unknown, path: string, problems: Problems): void {
  const p = object(value, path, problems, ['title', 'stats'], ['charts']);
  if (!p) return;
  valueSource(p.title, `${path}.title`, problems);
  list(p.stats, `${path}.stats`, problems).forEach((item, i) => {
    const where = `${path}.stats[${i}]`;
    const stat = object(item, where, problems, ['label', 'value'], ['format']);
    if (!stat) return;
    check(isText(stat.label), `${where}.label must be text`, problems);
    valueSource(stat.value, `${where}.value`, problems);
    if (stat.format !== undefined) numberFormat(stat.format, `${where}.format`, problems);
  });
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

function legend(value: unknown, path: string, problems: Problems): void {
  const l = object(value, path, problems, ['kind', 'shape', 'border', 'opacity', 'items']);
  if (!l) return;
  check(
    l.kind === 'single' || l.kind === 'categories' || l.kind === 'ramp',
    `${path}.kind must be single, categories or ramp`,
    problems,
  );
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
    const entry = object(item, where, problems, ['color', 'label']);
    if (!entry) return;
    check(isText(entry.color), `${where}.color must be a colour`, problems);
    check(isText(entry.label), `${where}.label must be text`, problems);
  });
}

function styleLayers(value: unknown, path: string, problems: Problems): void {
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
    check(STYLE_LAYER_TYPES.includes(type as string), `${where}.type is not a vector layer type`, problems);
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
 * which the pipeline checks outside the schema.
 */
export function displayProblems(value: unknown, path = 'display'): string[] {
  const problems: Problems = [];
  const d = object(value, path, problems, ['title', 'defaultVisible', 'order', 'layers', 'legend'], ['popup']);
  if (!d) return problems;
  check(isText(d.title), `${path}.title must be text`, problems);
  check(typeof d.defaultVisible === 'boolean', `${path}.defaultVisible must be true or false`, problems);
  check(Number.isInteger(d.order), `${path}.order must be a whole number`, problems);
  styleLayers(d.layers, `${path}.layers`, problems);
  legend(d.legend, `${path}.legend`, problems);
  if (d.popup !== undefined) popup(d.popup, `${path}.popup`, problems);
  return problems;
}

/** A manifest entry as a layer definition, or the problems that stop it. */
function toDefinition(entry: unknown, index: number): LayerDefinition | string[] {
  const where = `layers[${index}]`;
  if (!isObject(entry)) return [`${where} must be an object`];
  const problems: Problems = [];
  const { name, file } = entry;
  check(typeof name === 'string' && LAYER_NAME.test(name), `${where}.name is not a valid layer name`, problems);
  check(typeof file === 'string' && ARCHIVE_FILE.test(file), `${where}.file is not a .pmtiles file name`, problems);
  if (entry.display === undefined || entry.display === null) {
    problems.push(`${where}.display is missing (built before display configs; rebuild the layer)`);
  } else {
    problems.push(...displayProblems(entry.display, `${where}.display`));
  }
  if (problems.length) return problems;

  const display = entry.display as Display;
  return {
    id: name as string,
    title: display.title,
    file: file as string,
    sourceLayer: name as string,
    defaultVisible: display.defaultVisible,
    order: display.order,
    layers: display.layers,
    legend: display.legend,
    ...(display.popup ? { popup: display.popup } : {}),
  };
}

/** Draw order: ascending `order`, then id, as in the pipeline's style.json. */
export function drawOrder(defs: readonly LayerDefinition[]): LayerDefinition[] {
  return [...defs].sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * Reads a parsed `manifest.json` into layer definitions in draw order.
 * Entries that are not valid (or repeat a name) are left out with a
 * console warning and counted in `problem`.
 *
 * @throws {ManifestError} when the manifest has no `layers` list.
 */
export function parseManifest(json: unknown): ManifestLayers {
  if (!isObject(json) || !Array.isArray(json.layers)) {
    throw new ManifestError('manifest.json has no layers list');
  }
  const defs: LayerDefinition[] = [];
  let skipped = 0;
  json.layers.forEach((entry, i) => {
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
  else if (defs.length === 0) problem = MESSAGES.empty;
  return { layers: drawOrder(defs), problem };
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
  const none = (problem: string | null): ManifestLayers => ({ layers: [], problem });
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
