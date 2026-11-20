import type { LayerSpecification, SourceSpecification } from '@maplibre/maplibre-gl-style-spec';
import type { LayerDefinition, Theme } from './types';

/** A layer's MapLibre sources and style layers, ready to add to the map. */
export interface MapLibreLayer {
  sources: Record<string, SourceSpecification>;
  layers: LayerSpecification[];
}

/** MapLibre's layout `visibility` value for a shown or hidden layer. */
export function visibilityValue(visible: boolean): 'visible' | 'none' {
  return visible ? 'visible' : 'none';
}

/**
 * The id of a style layer on the map: the id in the layer file prefixed
 * with the layer name, so ids from different layers never clash. The
 * pipeline's `style.json` uses the same rule (`pipeline/lib/style.sh`).
 */
export function styleLayerId(layerId: string, id: string): string {
  return `${layerId}-${id}`;
}

/** The map ids of a layer's style layers, in draw order (last on top). */
export function styleLayerIds(def: LayerDefinition): string[] {
  return def.layers.map((layer) => layer.id);
}

/**
 * A source URL from style.json with its archive resolved against the
 * tiles URL: the pipeline writes `pmtiles://<layer>.pmtiles` and
 * `cog://<layer>.cog.tif#dem` relative to style.json (ADR 0010), so the
 * same file works wherever it is served. A URL with an absolute archive,
 * or of another protocol, is kept as it is.
 *
 * @param tilesBaseUrl absolute URL of the folder holding style.json,
 *   ending in a slash, for example `http://localhost:5173/tiles/`.
 */
export function resolveSourceUrl(url: string, tilesBaseUrl: string): string {
  const match = /^(pmtiles|cog):\/\/(.*)$/.exec(url);
  if (!match) return new URL(url, tilesBaseUrl).href;
  const [, protocol, rest] = match as unknown as [string, string, string];
  if (/^[a-z][a-z0-9+.-]*:/i.test(rest)) return url;
  const hash = rest.indexOf('#');
  const path = hash < 0 ? rest : rest.slice(0, hash);
  const fragment = hash < 0 ? '' : rest.slice(hash);
  return `${protocol}://${new URL(path, tilesBaseUrl).href}${fragment}`;
}

/**
 * A layer's sources and style layers to add to the map, with their layout
 * `visibility` set and, for a layer with colour themes (ADR 0012), the
 * paint of `theme` laid over theirs.
 */
export function toMapLibre(def: LayerDefinition, visible: boolean, theme?: Theme): MapLibreLayer {
  const prefix = `${def.id}-`;
  return {
    sources: def.sources,
    layers: def.layers.map((layer) => {
      const set = theme?.paint[layer.id.startsWith(prefix) ? layer.id.slice(prefix.length) : layer.id];
      // A property left undefined (not set by the style layer) is not added.
      const paint = set && Object.fromEntries(Object.entries(set).filter(([, v]) => v !== undefined));
      const styled = paint ? { ...layer, paint: { ...(layer as { paint?: object }).paint, ...paint } } : layer;
      return { ...styled, layout: { ...styled.layout, visibility: visibilityValue(visible) } } as LayerSpecification;
    }),
  };
}
