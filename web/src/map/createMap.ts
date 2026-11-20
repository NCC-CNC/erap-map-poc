import { Map as MapLibreMap, NavigationControl, type ErrorEvent } from 'maplibre-gl';
import {
  themePaintUpdates,
  toMapLibre,
  visibilityUpdates,
  type LayerDefinition,
  type Theme,
} from '../layers';
import { pmtilesProtocol } from './pmtiles';
// Sets the MapLibre worker URL; must run before any map is created.
import './worker';

export interface CreateMapOptions {
  /** Basemap style URL, from `BASEMAP_STYLES` in `./basemap`. */
  style: string;
  /**
   * Data layers to add, in draw order, or a promise of them (from
   * style.json, see `loadStyle`): the basemap shows straight away and the
   * data layers are added over it once they are known.
   */
  layers: readonly LayerDefinition[] | Promise<readonly LayerDefinition[]>;
  /** Aborting stops layers being added, for example after the map is removed. */
  signal?: AbortSignal;
  /**
   * Current visibility of a layer, read each time the data layers are
   * added, so a basemap switch keeps what the user switched on or off.
   * Defaults to the definition's `defaultVisible`.
   */
  isVisible?: (def: LayerDefinition) => boolean;
  /**
   * The colour theme to draw a layer with (ADR 0012), read like
   * `isVisible`, so a basemap switch keeps the user's choice. Defaults to
   * the layer's first theme, which its style layers draw.
   */
  themeOf?: (def: LayerDefinition) => Theme | undefined;
  /**
   * Called with a layer's id and a short reason when MapLibre reports an
   * error for it: a style layer or source it would not add, or an archive
   * it could not read. The other layers still draw.
   */
  onLayerError?: (layerId: string, reason: string) => void;
}

/** The folder holding `style.json` and the archives: `<BASE_URL>tiles/`. */
export function tilesBaseUrl(): string {
  return new URL(`${import.meta.env.BASE_URL}tiles/`, window.location.href).href;
}

/**
 * Registers the protocols the layers' sources use: `pmtiles://` always,
 * `cog://` (ADR 0010) only when a source needs it, as its code (with its
 * GeoTIFF decoders) is loaded on demand.
 */
async function registerProtocols(defs: readonly LayerDefinition[]): Promise<void> {
  pmtilesProtocol();
  const urls = defs.flatMap((def) => Object.values(def.sources)).map((s) => ('url' in s ? s.url : ''));
  if (urls.some((url) => url?.startsWith('cog://'))) (await import('./cog')).registerCogProtocol();
}

/**
 * Adds the data layers to the current style, in order, skipping any
 * already there. MapLibre validates each source and style layer as it is
 * added and reports a bad one as an error event rather than adding it; such
 * a layer is reported to `onError` and left out, and the others are added.
 */
function addDataLayers(
  map: MapLibreMap,
  defs: readonly LayerDefinition[],
  build: (def: LayerDefinition) => ReturnType<typeof toMapLibre>,
  onError: (layerId: string, reason: string) => void,
): void {
  for (const def of defs) {
    const { sources, layers } = build(def);
    const failed: string[] = [];
    const listener = (e: ErrorEvent) => failed.push(e.error?.message ?? String(e.error));
    map.on('error', listener);
    try {
      for (const [id, source] of Object.entries(sources)) {
        if (!map.getSource(id)) map.addSource(id, source);
      }
      for (const layer of layers) {
        if (!map.getLayer(layer.id)) map.addLayer(layer);
      }
    } catch (error) {
      failed.push(error instanceof Error ? error.message : String(error));
    } finally {
      map.off('error', listener);
    }
    if (failed.length) {
      console.warn(`Layer "${def.id}": ${failed.join('; ')}`);
      onError(def.id, failed[0]!);
    }
  }
}

/**
 * Creates the map in `container` with the given basemap style and the data
 * layers. The data layers are added on every `style.load`, each with its
 * current visibility from `isVisible` and theme from `themeOf`, so they
 * survive a basemap switch with `setBasemapStyle` as the user left them.
 * An error MapLibre reports later for a layer's source (an archive it
 * cannot read) is passed to `onLayerError` too.
 */
export function createMap(container: HTMLElement, options: CreateMapOptions): MapLibreMap {
  const {
    style,
    layers,
    signal,
    isVisible = (def) => def.defaultVisible,
    themeOf = (def) => def.themes?.[0],
    onLayerError = () => {},
  } = options;

  // MapLibre adds the attribution control by default; keep it, as the
  // basemap and data licences require attribution.
  const map = new MapLibreMap({
    container,
    style,
    center: [-96, 60],
    zoom: 3,
    // Keep the view in the URL (`#zoom/lat/lon`): a view can be shared or
    // reloaded, and scripts/screenshot.sh opens the map at a given view.
    hash: true,
  });

  // A compass for the rotation and tilt a right-drag (or Ctrl-drag) sets:
  // the needle shows both, a click resets the map to north up and flat,
  // and dragging it rotates and tilts. Top right, clear of the map panel.
  map.addControl(new NavigationControl({ showZoom: false, visualizePitch: true }), 'top-right');

  // Registered once; each later style reuses them.
  let ready: Promise<readonly LayerDefinition[]> | undefined;
  // The layer each data source belongs to, for source errors.
  const sourceLayer = new Map<string, string>();

  map.on('error', (e: ErrorEvent & { sourceId?: string }) => {
    const layerId = e.sourceId && sourceLayer.get(e.sourceId);
    if (layerId && !signal?.aborted) onLayerError(layerId, e.error?.message ?? 'could not be read');
  });

  map.on('style.load', () => {
    const loadedStyle = map.style;
    ready ??= Promise.resolve(layers).then(async (defs) => {
      for (const def of defs) for (const id of Object.keys(def.sources)) sourceLayer.set(id, def.id);
      await registerProtocols(defs);
      return defs;
    });
    void ready.then((defs) => {
      // Skip if the map was removed or the style replaced while waiting.
      if (signal?.aborted || map.style !== loadedStyle) return;
      addDataLayers(map, defs, (def) => toMapLibre(def, isVisible(def), themeOf(def)), onLayerError);
    });
  });

  return map;
}

/**
 * Shows or hides a data layer by setting the layout `visibility` of each of
 * its style layers. Style layers not in the map yet (left out with an error,
 * or a new style still loading) are skipped; they pick up the current visibility
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
 * Draws a layer in a colour theme (ADR 0012) by setting the paint
 * properties the theme gives on its style layers. Style layers not in the
 * map yet are skipped; they are added in the theme from `themeOf`.
 */
export function setLayerTheme(map: MapLibreMap, def: LayerDefinition, theme: Theme): void {
  for (const [id, property, value] of themePaintUpdates(def, theme)) {
    // From the layer file, as in style.json; the web tests check the test
    // layers' style.json with the MapLibre style validator.
    type Paint = Parameters<MapLibreMap['setPaintProperty']>;
    if (map.getLayer(id)) map.setPaintProperty(id, property as Paint[1], value as Paint[2]);
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
