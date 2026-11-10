import { useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import {
  isVisible,
  loadManifest,
  manifestUrl,
  withVisibility,
  type LayerDefinition,
  type VisibilityState,
} from '../layers';
import { BASEMAP_STYLES, DEFAULT_BASEMAP_THEME, type BasemapTheme } from './basemap';
import { BasemapToggle } from './BasemapToggle';
import { createMap, setBasemapStyle, setLayerVisibility, tilesBaseUrl } from './createMap';
import { LayerList } from './LayerList';
import { MapPanel } from './MapPanel';
import { attachPopups, type PopupHandlers } from './popups';
import 'maplibre-gl/dist/maplibre-gl.css';

const NO_LAYERS: readonly LayerDefinition[] = [];

/**
 * Full-page map with a panel holding the basemap toggle and the layer list.
 * The data layers come from the pipeline's `manifest.json`, fetched once
 * when the map is created; the basemap shows without waiting for it.
 * Clicking a feature of a visible layer with a pop-up definition opens its
 * pop-up. MapLibre lives outside React's render tree: the map is created
 * once and removed on unmount.
 */
export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<MapLibreMap | null>(null);
  const popups = useRef<PopupHandlers | null>(null);
  const appliedStyle = useRef<string | null>(null);
  const [theme, setTheme] = useState<BasemapTheme>(DEFAULT_BASEMAP_THEME);
  // null until the manifest has been read.
  const [layers, setLayers] = useState<readonly LayerDefinition[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  // Layers not in here are at their default visibility.
  const [visibility, setVisibility] = useState<VisibilityState>({});
  const [available, setAvailable] = useState<ReadonlySet<string> | null>(null);
  // Read when the map is created; later changes go through setBasemapStyle.
  const initialTheme = useRef(theme);
  // Read by the map each time it adds the data layers (on every style.load).
  const currentVisibility = useRef(visibility);
  // Read by the pop-up handlers at event time.
  const currentLayers = useRef<readonly LayerDefinition[]>(NO_LAYERS);

  useEffect(() => {
    if (!container.current) return;
    const controller = new AbortController();
    const baseUrl = tilesBaseUrl();
    const loaded = loadManifest(manifestUrl(baseUrl), { signal: controller.signal });
    const style = BASEMAP_STYLES[initialTheme.current];
    const created = createMap(container.current, {
      style,
      layers: loaded.then((result) => result.layers),
      tilesBaseUrl: baseUrl,
      signal: controller.signal,
      isVisible: (def) => isVisible(currentVisibility.current, def),
      onLayersChecked: setAvailable,
    });
    void loaded.then((result) => {
      if (controller.signal.aborted) return;
      currentLayers.current = result.layers;
      setLayers(result.layers);
      setProblem(result.problem);
    });
    const handlers = attachPopups(created, () => currentLayers.current);
    map.current = created;
    popups.current = handlers;
    appliedStyle.current = style;

    return () => {
      controller.abort();
      handlers.detach();
      created.remove();
      map.current = null;
      popups.current = null;
      appliedStyle.current = null;
      currentLayers.current = NO_LAYERS;
    };
  }, []);

  useEffect(() => {
    if (!map.current) return;
    const style = BASEMAP_STYLES[theme];
    if (style === appliedStyle.current) return;
    setBasemapStyle(map.current, style);
    appliedStyle.current = style;
  }, [theme]);

  useEffect(() => {
    currentVisibility.current = visibility;
    if (!map.current) return;
    for (const def of layers ?? NO_LAYERS) {
      setLayerVisibility(map.current, def, isVisible(visibility, def));
    }
    popups.current?.closeIfHidden();
  }, [visibility, layers]);

  return (
    <>
      <div ref={container} className="map" />
      <MapPanel>
        <BasemapToggle value={theme} onChange={setTheme} />
        <LayerList
          layers={layers}
          problem={problem}
          visibility={visibility}
          available={available}
          onChange={(id, visible) => setVisibility((state) => withVisibility(state, id, visible))}
        />
      </MapPanel>
    </>
  );
}
