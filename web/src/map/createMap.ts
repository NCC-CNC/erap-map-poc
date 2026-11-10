import { Map as MapLibreMap } from 'maplibre-gl';
import { PMTiles } from 'pmtiles';
import { layerRegistry, toMapLibre, type LayerDefinition } from '../layers';
import { basemapStyle } from './basemap';
import { pmtilesProtocol } from './pmtiles';

export interface CreateMapOptions {
  /** Data layers to add; defaults to the layer registry. */
  layers?: readonly LayerDefinition[];
  /** Absolute URL of the folder holding the archives; defaults to `/tiles/`. */
  tilesBaseUrl?: string;
  /** Aborting stops layers being added, for example after the map is removed. */
  signal?: AbortSignal;
}

function defaultTilesBaseUrl(): string {
  return new URL(`${import.meta.env.BASE_URL}tiles/`, window.location.href).href;
}

/**
 * Adds data layers to a loaded map, in order. An archive that cannot be read
 * (missing, not yet built) is skipped with a console warning, so the
 * basemap and the other layers still show.
 */
async function addDataLayers(
  map: MapLibreMap,
  layers: readonly LayerDefinition[],
  tilesBaseUrl: string,
  signal?: AbortSignal,
): Promise<void> {
  const protocol = pmtilesProtocol();
  const built = layers.map((def) => toMapLibre(def, tilesBaseUrl));

  const available = await Promise.all(
    built.map(async ({ sourceId, archiveUrl }) => {
      const archive = protocol.get(archiveUrl) ?? new PMTiles(archiveUrl);
      protocol.add(archive);
      try {
        await archive.getHeader();
        return true;
      } catch (error) {
        console.warn(`Layer "${sourceId}" skipped: could not read ${archiveUrl}.`, error);
        return false;
      }
    }),
  );
  if (signal?.aborted) return;

  built.forEach(({ sourceId, source, layers: styleLayers }, i) => {
    if (!available[i] || map.getSource(sourceId)) return;
    map.addSource(sourceId, source);
    for (const layer of styleLayers) map.addLayer(layer);
  });
}

/** Creates the map in `container` with the basemap and the data layers. */
export function createMap(container: HTMLElement, options: CreateMapOptions = {}): MapLibreMap {
  const { layers = layerRegistry, tilesBaseUrl = defaultTilesBaseUrl(), signal } = options;

  // MapLibre adds the attribution control by default; keep it, as the
  // basemap and data licences require attribution.
  const map = new MapLibreMap({
    container,
    style: basemapStyle(),
    center: [-96, 60],
    zoom: 3,
  });

  map.once('load', () => {
    void addDataLayers(map, layers, tilesBaseUrl, signal);
  });

  return map;
}
