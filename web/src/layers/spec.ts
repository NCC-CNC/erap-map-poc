import type {
  LayerSpecification,
  RasterDEMSourceSpecification,
  VectorSourceSpecification,
} from '@maplibre/maplibre-gl-style-spec';
import type { LayerDefinition } from './types';

/** A layer definition turned into the MapLibre source and layers to add. */
export interface MapLibreLayer {
  sourceId: string;
  source: (VectorSourceSpecification | RasterDEMSourceSpecification) & { url: string };
  /** The archive URL without the `pmtiles://` prefix, as fetched. */
  archiveUrl: string;
  layers: LayerSpecification[];
}

/**
 * How a raster layer's archive is read (ADR 0008): 256 px grey PNG tiles
 * whose grey level is the share of the tile pixel covered by 1 cells, 0 to
 * 255, decoded as an "elevation" of 0 to 1 for the `color-relief` layer.
 * The pipeline's style.json uses the same source (`pipeline/style/display.mjs`).
 */
export const RASTER_SOURCE = {
  type: 'raster-dem',
  tileSize: 256,
  encoding: 'custom',
  redFactor: 1 / 255,
  greenFactor: 0,
  blueFactor: 0,
  baseShift: 0,
} as const satisfies Omit<RasterDEMSourceSpecification, 'url'>;

/** MapLibre's layout `visibility` value for a shown or hidden layer. */
export function visibilityValue(visible: boolean): 'visible' | 'none' {
  return visible ? 'visible' : 'none';
}

/**
 * The id of a style layer on the map: the configured id prefixed with the
 * layer id, so ids from different layers never clash. The pipeline's
 * `style.json` uses the same rule (`pipeline/style/display.mjs`).
 */
export function styleLayerId(layerId: string, id: string): string {
  return `${layerId}-${id}`;
}

/** The map ids of a layer's style layers, in draw order (last on top). */
export function styleLayerIds(def: LayerDefinition): string[] {
  return def.layers.map((layer) => styleLayerId(def.id, layer.id));
}

/**
 * Builds the MapLibre source and style layers for a definition: each
 * configured style layer with its id prefixed, wired to the layer's source
 * (and, for a vector layer, its source layer), and with its layout
 * `visibility` set. A raster layer gets a `raster-dem` source.
 *
 * @param tilesBaseUrl absolute URL of the folder holding the archives,
 *   ending in a slash, for example `http://localhost:5173/tiles/`.
 * @param visible whether the layers start shown; defaults to the
 *   definition's `defaultVisible`.
 */
export function toMapLibre(
  def: LayerDefinition,
  tilesBaseUrl: string,
  visible: boolean = def.defaultVisible,
): MapLibreLayer {
  const archiveUrl = new URL(def.file, tilesBaseUrl).href;
  const url = `pmtiles://${archiveUrl}`;
  const raster = def.type === 'raster';
  return {
    sourceId: def.id,
    archiveUrl,
    source: raster ? { ...RASTER_SOURCE, url } : { type: 'vector', url },
    layers: def.layers.map(
      (layer) =>
        ({
          ...layer,
          id: styleLayerId(def.id, layer.id),
          source: def.id,
          ...(raster ? {} : { 'source-layer': def.sourceLayer }),
          layout: { ...layer.layout, visibility: visibilityValue(visible) },
        }) as LayerSpecification,
    ),
  };
}
