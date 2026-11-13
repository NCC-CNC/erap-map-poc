import type {
  LayerSpecification,
  RasterDEMSourceSpecification,
  VectorSourceSpecification,
} from '@maplibre/maplibre-gl-style-spec';
import type { LayerDefinition } from './types';

/** How the map reads a layer's archive: the protocol its source URL uses. */
export type ArchiveKind = 'pmtiles' | 'cog';

/** A layer definition turned into the MapLibre source and layers to add. */
export interface MapLibreLayer {
  sourceId: string;
  source: (VectorSourceSpecification | RasterDEMSourceSpecification) & { url: string };
  /** The archive URL without the protocol prefix, as fetched. */
  archiveUrl: string;
  /** `cog` for a raster layer's COG, `pmtiles` otherwise. */
  archiveKind: ArchiveKind;
  layers: LayerSpecification[];
}

/**
 * How a raster layer's COG is read (ADR 0010): through the `cog://`
 * protocol (`@geomatico/maplibre-cog-protocol`, see `../map/cog.ts`), whose
 * `#dem` mode encodes each pixel value, the grey level 0 to 255 that is
 * the share of the pixel covered by 1 cells, as a Terrain-RGB "elevation"
 * for the `color-relief` layer. The pipeline's style.json uses the same
 * source (`pipeline/style/display.mjs`).
 */
export const RASTER_SOURCE = {
  type: 'raster-dem',
  tileSize: 256,
} as const satisfies Omit<RasterDEMSourceSpecification, 'url'>;

/**
 * How a raster layer built before COGs is read (ADR 0008): grey PNG tiles
 * in a .pmtiles archive, the red channel being the grey level 0 to 255.
 * Kept so an older build still shows until it is rebuilt.
 */
export const RASTER_PNG_SOURCE = {
  type: 'raster-dem',
  tileSize: 256,
  encoding: 'custom',
  redFactor: 1,
  greenFactor: 0,
  blueFactor: 0,
  baseShift: 0,
} as const satisfies Omit<RasterDEMSourceSpecification, 'url'>;

/** Whether an archive file name is a raster layer's COG. */
export function isCog(file: string): boolean {
  return file.endsWith('.cog.tif');
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
 * (and, for a vector layer, its source layer), and with its layout
 * `visibility` set. A raster layer gets a `raster-dem` source, read from
 * its COG through `cog://` (or, built before COGs, from PNG tiles in a
 * .pmtiles archive); a vector layer a `vector` source through `pmtiles://`.
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
  const raster = def.type === 'raster';
  const archiveKind: ArchiveKind = raster && isCog(def.file) ? 'cog' : 'pmtiles';
  const source: MapLibreLayer['source'] =
    archiveKind === 'cog'
      ? { ...RASTER_SOURCE, url: `cog://${archiveUrl}#dem` }
      : raster
        ? { ...RASTER_PNG_SOURCE, url: `pmtiles://${archiveUrl}` }
        : { type: 'vector', url: `pmtiles://${archiveUrl}` };
  return {
    sourceId: def.id,
    archiveUrl,
    archiveKind,
    source,
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
