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

/**
 * Builds the MapLibre source and style layers for a definition.
 *
 * @param tilesBaseUrl absolute URL of the folder holding the archives,
 *   ending in a slash, for example `http://localhost:5173/tiles/`.
 */
export function toMapLibre(def: LayerDefinition, tilesBaseUrl: string): MapLibreLayer {
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
          source: def.id,
          'source-layer': def.sourceLayer,
        }) as LayerSpecification,
    ),
  };
}
