import type {
  LayerSpecification,
  VectorSourceSpecification,
} from '@maplibre/maplibre-gl-style-spec';
import type { LayerDefinition } from './types';

/** A layer definition turned into the MapLibre source and layers to add. */
export interface MapLibreLayer {
  sourceId: string;
  source: VectorSourceSpecification & { url: string };
  /** The archive URL without the `pmtiles://` prefix, as fetched. */
  archiveUrl: string;
  layers: LayerSpecification[];
}

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
 * and source layer, and with its layout `visibility` set.
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
  return {
    sourceId: def.id,
    archiveUrl,
    source: {
      type: 'vector',
      url: `pmtiles://${archiveUrl}`,
    },
    layers: def.layers.map(
      (layer) =>
        ({
          ...layer,
          id: styleLayerId(def.id, layer.id),
          source: def.id,
          'source-layer': def.sourceLayer,
          layout: { ...layer.layout, visibility: visibilityValue(visible) },
        }) as LayerSpecification,
    ),
  };
}
