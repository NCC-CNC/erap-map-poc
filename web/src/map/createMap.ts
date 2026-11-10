import { Map as MapLibreMap } from 'maplibre-gl';
import { PMTiles } from 'pmtiles';
import { layerRegistry, toMapLibre, type LayerDefinition, type MapLibreLayer } from '../layers';
import { pmtilesProtocol } from './pmtiles';
// Sets the MapLibre worker URL; must run before any map is created.
import './worker';

export interface CreateMapOptions {
  /** Basemap style URL, from `BASEMAP_STYLES` in `./basemap`. */
  style: string;
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
 * Checks which archives can be read, registering each with the `pmtiles`
 * protocol. An archive that cannot be read (missing, not yet built) is
 * skipped with a console warning, so the basemap and the other layers still
 * show.
 */
async function availableLayers(built: readonly MapLibreLayer[]): Promise<MapLibreLayer[]> {
  const protocol = pmtilesProtocol();
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
  return built.filter((_, i) => available[i]);
}

/** Adds data layers to the current style, in order, skipping any already there. */
function addDataLayers(map: MapLibreMap, layers: readonly MapLibreLayer[]): void {
  for (const { sourceId, source, layers: styleLayers } of layers) {
    if (map.getSource(sourceId)) continue;
    map.addSource(sourceId, source);
    for (const layer of styleLayers) map.addLayer(layer);
  }
}

/**
 * Creates the map in `container` with the given basemap style and the data
 * layers. The data layers are added on every `style.load`, so they survive
 * a basemap switch with `setBasemapStyle`.
 */
export function createMap(container: HTMLElement, options: CreateMapOptions): MapLibreMap {
  const { style, layers = layerRegistry, tilesBaseUrl = defaultTilesBaseUrl(), signal } = options;

  // MapLibre adds the attribution control by default; keep it, as the
  // basemap and data licences require attribution.
  const map = new MapLibreMap({
    container,
    style,
    center: [-96, 60],
    zoom: 3,
  });

  // Checked once; each later style reuses the result.
  let available: Promise<MapLibreLayer[]> | undefined;

  map.on('style.load', () => {
    const loadedStyle = map.style;
    available ??= availableLayers(layers.map((def) => toMapLibre(def, tilesBaseUrl)));
    void available.then((ready) => {
      // Skip if the map was removed or the style replaced while waiting.
      if (signal?.aborted || map.style !== loadedStyle) return;
      addDataLayers(map, ready);
    });
  });

  return map;
}

/**
 * Switches the basemap. This replaces the whole style, which drops the data
 * layers; `createMap` adds them again when the new style has loaded. `diff`
 * is off so that MapLibre always does a full reload and fires `style.load`.
 */
export function setBasemapStyle(map: MapLibreMap, style: string): void {
  map.setStyle(style, { diff: false });
}
