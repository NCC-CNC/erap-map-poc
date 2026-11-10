import type {
  LayerSpecification,
  VectorSourceSpecification,
} from '@maplibre/maplibre-gl-style-spec';
import { styleLayers } from './symbology';
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
 * Builds the MapLibre source and style layers for a definition, with the
 * style layers generated from its symbology.
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
    layers: styleLayers(def.id, def.symbology).map(
      (layer) =>
        ({
          ...layer,
          source: def.id,
          'source-layer': def.sourceLayer,
          layout: { visibility: visibilityValue(visible) },
        }) as LayerSpecification,
    ),
  };
}
