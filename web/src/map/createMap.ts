import { Map as MapLibreMap } from 'maplibre-gl';
import { PMTiles } from 'pmtiles';
import {
  toMapLibre,
  visibilityUpdates,
  type LayerDefinition,
  type MapLibreLayer,
} from '../layers';
import { pmtilesProtocol } from './pmtiles';
// Sets the MapLibre worker URL; must run before any map is created.
import './worker';

export interface CreateMapOptions {
  /** Basemap style URL, from `BASEMAP_STYLES` in `./basemap`. */
  style: string;
  /**
   * Data layers to add, in draw order, or a promise of them (from the
   * manifest, see `loadManifest`): the basemap shows straight away and the
   * data layers are added once they are known.
   */
  layers: readonly LayerDefinition[] | Promise<readonly LayerDefinition[]>;
  /** Absolute URL of the folder holding the archives; defaults to `tilesBaseUrl()`. */
  tilesBaseUrl?: string;
  /** Aborting stops layers being added, for example after the map is removed. */
  signal?: AbortSignal;
  /**
   * Current visibility of a layer, read each time the data layers are
   * added, so a basemap switch keeps what the user switched on or off.
   * Defaults to the definition's `defaultVisible`.
   */
  isVisible?: (def: LayerDefinition) => boolean;
  /** Called once with the ids of the layers whose archive could be read. */
  onLayersChecked?: (available: ReadonlySet<string>) => void;
}

/** The folder holding the archives and `manifest.json`: `<BASE_URL>tiles/`. */
export function tilesBaseUrl(): string {
  return new URL(`${import.meta.env.BASE_URL}tiles/`, window.location.href).href;
}

/**
 * Checks which archives can be read, registering each with the `pmtiles`
 * protocol. An archive that cannot be read (missing, not yet built) is
 * skipped with a console warning, so the basemap and the other layers still
 * show.
 */
async function availableLayers(
  layers: CreateMapOptions['layers'],
  baseUrl: string,
): Promise<LayerDefinition[]> {
  const defs = await layers;
  const protocol = pmtilesProtocol();
  const available = await Promise.all(
    defs.map(async (def) => {
      const { archiveUrl } = toMapLibre(def, baseUrl);
      const archive = protocol.get(archiveUrl) ?? new PMTiles(archiveUrl);
      protocol.add(archive);
      try {
        await archive.getHeader();
        return true;
      } catch (error) {
        console.warn(`Layer "${def.id}" skipped: could not read ${archiveUrl}.`, error);
        return false;
      }
    }),
  );
  return defs.filter((_, i) => available[i]);
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
 * layers. The data layers are added on every `style.load`, each with its
 * current visibility from `isVisible`, so they survive a basemap switch
 * with `setBasemapStyle` as the user left them.
 */
export function createMap(container: HTMLElement, options: CreateMapOptions): MapLibreMap {
  const {
    style,
    layers,
    tilesBaseUrl: baseUrl = tilesBaseUrl(),
    signal,
    isVisible = (def) => def.defaultVisible,
    onLayersChecked,
  } = options;

  // MapLibre adds the attribution control by default; keep it, as the
  // basemap and data licences require attribution.
  const map = new MapLibreMap({
    container,
    style,
    center: [-96, 60],
    zoom: 3,
  });

  // Checked once; each later style reuses the result.
  let available: Promise<LayerDefinition[]> | undefined;

  map.on('style.load', () => {
    const loadedStyle = map.style;
    if (!available) {
      available = availableLayers(layers, baseUrl);
      void available.then((ready) => {
        if (!signal?.aborted) onLayersChecked?.(new Set(ready.map((def) => def.id)));
      });
    }
    void available.then((ready) => {
      // Skip if the map was removed or the style replaced while waiting.
      if (signal?.aborted || map.style !== loadedStyle) return;
      addDataLayers(
        map,
        ready.map((def) => toMapLibre(def, baseUrl, isVisible(def))),
      );
    });
  });

  return map;
}

/**
 * Shows or hides a data layer by setting the layout `visibility` of each of
 * its style layers. Style layers not in the map yet (archive missing, or a
 * new style still loading) are skipped; they pick up the current visibility
 * from `isVisible` when they are added.
 */
export function setLayerVisibility(
  map: MapLibreMap,
  def: LayerDefinition,
  visible: boolean,
): void {
  for (const [id, value] of visibilityUpdates(def, visible)) {
    if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', value);
  }
}

/**
 * Switches the basemap. This replaces the whole style, which drops the data
 * layers; `createMap` adds them again when the new style has loaded. `diff`
 * is off so that MapLibre always does a full reload and fires `style.load`.
 */
export function setBasemapStyle(map: MapLibreMap, style: string): void {
  map.setStyle(style, { diff: false });
}
