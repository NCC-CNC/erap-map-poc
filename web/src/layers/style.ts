import type { LayerSpecification, SourceSpecification } from '@maplibre/maplibre-gl-style-spec';
import { canonicalLocale, setNumberLocale } from '../locale';
import { resolveLegend } from './legend';
import { resolveSourceUrl, styleLayerId } from './spec';
import type {
  BasemapName,
  LayerDefinition,
  LayerMetadata,
  LayerType,
  MapDefaults,
  Theme,
  ThemeConfig,
} from './types';

/**
 * Reads the data layers from the pipeline's `style.json` (design note 04):
 * a MapLibre style (version 8) of every built layer, loaded over the
 * basemap. Each style layer names its map layer in
 * `metadata["erap:layer"]`; the style's `metadata["erap:layers"]` holds
 * what MapLibre does not know about (title, order, visibility, legend,
 * themes, pop-up, modal), the layer file's `display` as it is
 * (`./layer.generated.ts`). The style's `center`, `zoom` and
 * `metadata["erap:basemap"]` are the opening view; `erap:view` (zoom
 * limits and bounds), `erap:title` and `erap:locale` (numbers are
 * formatted in it from when the style is read) the rest of the map
 * config's settings (`mapDefaults`). A problem in one style
 * layer is left to MapLibre, whose error events name it (see
 * `../map/createMap.ts`), so the other layers still draw.
 */

/** What the map gets from style.json. */
export interface StyleLayers {
  /** The layers in draw order (last on top). */
  layers: LayerDefinition[];
  /** A short message for the layer panel when something is wrong, else null. */
  problem: string | null;
  /** The map config's settings (view, limits, basemap, title, locale); null when style.json sets none. */
  map: MapDefaults | null;
}

/** A style.json that cannot be read at all. */
export class StyleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StyleError';
  }
}

/** Messages shown in the layer panel. */
export const MESSAGES = {
  missing:
    'Data layers are not available: the map style (style.json) could not be loaded. Build the tiles with the pipeline, then reload.',
  invalid:
    'Data layers are not available: the map style (style.json) is not valid. Rebuild the tiles with the pipeline, then reload.',
  empty: 'No data layers have been built yet.',
} as const;

/** The basemaps the map config may name (`pipeline/schema/map.schema.json`). */
export const BASEMAP_NAMES: readonly BasemapName[] = ['light', 'dark'];

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);
const inRange = (v: unknown, min: number, max: number): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;

/**
 * The map's settings from a style's `center`, `zoom` and metadata
 * (`erap:basemap`, `erap:view` with `minzoom`, `maxzoom` and `bounds`,
 * `erap:title`, `erap:locale`), or null when it sets none. A value that is
 * not valid is left out with a console warning.
 */
export function mapDefaults(style: Json): MapDefaults | null {
  const defaults: MapDefaults = {};
  const { center, zoom } = style;
  const metadata = isObject(style.metadata) ? style.metadata : {};
  const basemap = metadata['erap:basemap'];
  const view = metadata['erap:view'];
  const title = metadata['erap:title'];
  const locale = metadata['erap:locale'];
  if (view !== undefined) {
    if (isObject(view)) {
      const { minzoom, maxzoom, bounds } = view;
      if (minzoom !== undefined) {
        if (inRange(minzoom, 0, 24)) defaults.minZoom = minzoom;
        else console.warn('style.json: erap:view minzoom ignored: not a number from 0 to 24.');
      }
      if (maxzoom !== undefined) {
        if (inRange(maxzoom, defaults.minZoom ?? 0, 24)) defaults.maxZoom = maxzoom;
        else console.warn('style.json: erap:view maxzoom ignored: not a number from minzoom to 24.');
      }
      if (bounds !== undefined) {
        if (
          Array.isArray(bounds) &&
          bounds.length === 4 &&
          inRange(bounds[0], -180, 180) &&
          inRange(bounds[1], -90, 90) &&
          inRange(bounds[2], -180, 180) &&
          inRange(bounds[3], -90, 90) &&
          bounds[0] < bounds[2] &&
          bounds[1] < bounds[3]
        ) {
          defaults.bounds = [bounds[0], bounds[1], bounds[2], bounds[3]];
        } else {
          console.warn('style.json: erap:view bounds ignored: not [west, south, east, north].');
        }
      }
    } else {
      console.warn('style.json: erap:view ignored: not an object.');
    }
  }
  if (title !== undefined) {
    if (typeof title === 'string' && title.trim()) defaults.title = title;
    else console.warn('style.json: erap:title ignored: not a text.');
  }
  if (locale !== undefined) {
    const tag = typeof locale === 'string' ? canonicalLocale(locale) : null;
    if (tag) defaults.locale = tag;
    else console.warn('style.json: erap:locale ignored: not a language tag such as en-CA.');
  }
  if (center !== undefined) {
    if (Array.isArray(center) && inRange(center[0], -180, 180) && inRange(center[1], -90, 90)) {
      defaults.center = [center[0], center[1]];
    } else {
      console.warn('style.json: center ignored: not [longitude, latitude].');
    }
  }
  if (zoom !== undefined) {
    if (inRange(zoom, 0, 24)) defaults.zoom = zoom;
    else console.warn('style.json: zoom ignored: not a number from 0 to 24.');
  }
  if (basemap !== undefined) {
    if (BASEMAP_NAMES.includes(basemap as BasemapName)) defaults.basemap = basemap as BasemapName;
    else console.warn(`style.json: erap:basemap ignored: not one of ${BASEMAP_NAMES.join(', ')}.`);
  }
  return Object.keys(defaults).length ? defaults : null;
}

const paintOf = (layer: LayerSpecification): Json =>
  ((layer as { paint?: Json }).paint ?? {}) as Json;

/**
 * The themes ready to apply: every theme sets every paint property any
 * theme sets, the first (whose paint the layer file leaves out) with the
 * style layers' own values, the others with theirs over those. Each has its
 * legend, from the style layers in that theme.
 */
function resolveThemes(
  name: string,
  configs: readonly ThemeConfig[],
  layers: readonly LayerSpecification[],
): Theme[] {
  const byId = new Map(layers.map((layer) => [layer.id, layer]));
  const base: Record<string, Record<string, unknown>> = {};
  for (const theme of configs) {
    for (const [id, paint] of Object.entries(theme.paint ?? {})) {
      const own = paintOf(byId.get(styleLayerId(name, id)) ?? ({} as LayerSpecification));
      const props = (base[id] ??= {});
      // A property the style layer does not set goes back to MapLibre's default.
      for (const property of Object.keys(paint)) props[property] = own[property];
    }
  }
  return configs.map((theme) => {
    const paint = Object.fromEntries(
      Object.entries(base).map(([id, props]) => [id, { ...props, ...theme.paint?.[id] }]),
    );
    const drawn = layers.map((layer) => {
      const set = paint[layer.id.slice(name.length + 1)];
      return set ? ({ ...layer, paint: { ...paintOf(layer), ...set } } as LayerSpecification) : layer;
    });
    return {
      id: theme.id,
      label: theme.label,
      paint,
      legend: resolveLegend(theme.legend, drawn, theme.label),
    };
  });
}

/**
 * Reads a parsed style.json into layer definitions in draw order, sources
 * resolved against `tilesBaseUrl`. Style layers without `erap:layer`
 * belong to no map layer and are left out with a console warning.
 *
 * @throws {StyleError} when it is not a version 8 style with sources and layers.
 */
export function parseStyle(json: unknown, tilesBaseUrl: string): StyleLayers {
  if (!isObject(json) || json.version !== 8 || !isObject(json.sources) || !Array.isArray(json.layers)) {
    throw new StyleError('style.json is not a MapLibre style (version 8, sources, layers)');
  }
  const sources = json.sources as Record<string, Json>;
  const metadata = isObject(json.metadata) ? json.metadata : {};
  const map = mapDefaults(json);
  // Numbers (legends here, pop-ups and modals later) in the map's locale.
  setNumberLocale(map?.locale);
  const entries = (isObject(metadata['erap:layers']) ? metadata['erap:layers'] : {}) as Record<
    string,
    LayerMetadata
  >;

  // Style layers by map layer, in the style's (draw) order.
  const groups = new Map<string, LayerSpecification[]>();
  for (const layer of json.layers as unknown[]) {
    const name = isObject(layer) && isObject(layer.metadata) ? layer.metadata['erap:layer'] : undefined;
    if (typeof name !== 'string' || !isObject(layer) || typeof layer.id !== 'string') {
      console.warn('style.json: a style layer without an id or erap:layer is left out.', layer);
      continue;
    }
    const group = groups.get(name) ?? [];
    group.push(layer as unknown as LayerSpecification);
    groups.set(name, group);
  }

  const layers = [...groups].map(([name, styleLayers]): LayerDefinition => {
    const raw: unknown = entries[name];
    const meta: LayerMetadata = isObject(raw) ? (raw as LayerMetadata) : {};
    const title = typeof meta.title === 'string' && meta.title ? meta.title : name;
    const own: Record<string, SourceSpecification> = {};
    for (const layer of styleLayers) {
      const id = 'source' in layer ? layer.source : undefined;
      const source = id === undefined ? undefined : sources[id];
      if (id === undefined || !isObject(source) || own[id]) continue;
      own[id] = (
        typeof source.url === 'string' ? { ...source, url: resolveSourceUrl(source.url, tilesBaseUrl) } : source
      ) as SourceSpecification;
    }
    const firstSource = Object.values(own)[0];
    const type: LayerType =
      meta.type === 'raster' || meta.type === 'vector'
        ? meta.type
        : firstSource?.type === 'vector'
          ? 'vector'
          : 'raster';
    const themes =
      Array.isArray(meta.themes) && meta.themes.length
        ? resolveThemes(name, meta.themes, styleLayers)
        : undefined;
    return {
      id: name,
      type,
      title,
      defaultVisible: meta.visible === true,
      order: typeof meta.order === 'number' ? meta.order : 0,
      sources: own,
      layers: styleLayers,
      ...(themes ? { themes } : { legend: resolveLegend(meta.legend, styleLayers, title) }),
      ...(meta.popup ? { popup: meta.popup } : {}),
      ...(meta.modal ? { modal: meta.modal } : {}),
    };
  });

  return { layers, problem: layers.length ? null : MESSAGES.empty, map };
}

/** The `style.json` URL in the folder holding the archives. */
export function styleUrl(tilesBaseUrl: string): string {
  return new URL('style.json', tilesBaseUrl).href;
}

export interface LoadOptions {
  signal?: AbortSignal;
  /** For tests; defaults to the global `fetch`. */
  fetch?: typeof fetch;
}

/**
 * Fetches and reads `style.json` from the tiles folder (revalidated on
 * every load, so a pipeline run shows on reload). Never rejects: a missing
 * or invalid style gives no layers and a `problem` for the panel, and the
 * basemap still shows. An aborted load gives no layers and no problem.
 */
export async function loadStyle(tilesBaseUrl: string, options: LoadOptions = {}): Promise<StyleLayers> {
  const { signal, fetch: fetchFn = fetch } = options;
  const url = styleUrl(tilesBaseUrl);
  const none = (problem: string | null): StyleLayers => ({ layers: [], problem, map: null });
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
    return parseStyle(await response.json(), tilesBaseUrl);
  } catch (error) {
    if (signal?.aborted) return none(null);
    console.warn(`${url} is not a valid map style.`, error);
    return none(MESSAGES.invalid);
  }
}
