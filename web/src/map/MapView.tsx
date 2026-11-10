import { useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import {
  initialVisibility,
  isVisible,
  layerRegistry,
  withVisibility,
  type LayerDefinition,
  type VisibilityState,
} from '../layers';
import { BASEMAP_STYLES, DEFAULT_BASEMAP_THEME, type BasemapTheme } from './basemap';
import { BasemapToggle } from './BasemapToggle';
import { createMap, setBasemapStyle, setLayerVisibility } from './createMap';
import { LayerList } from './LayerList';
import { MapPanel } from './MapPanel';
import { attachPopups, type PopupHandlers } from './popups';
import 'maplibre-gl/dist/maplibre-gl.css';

const LAYERS: readonly LayerDefinition[] = layerRegistry;

/**
 * Full-page map with a panel holding the basemap toggle and the layer list.
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
  const [visibility, setVisibility] = useState<VisibilityState>(() => initialVisibility(LAYERS));
  const [available, setAvailable] = useState<ReadonlySet<string> | null>(null);
  // Read when the map is created; later changes go through setBasemapStyle.
  const initialTheme = useRef(theme);
  // Read by the map each time it adds the data layers (on every style.load).
  const currentVisibility = useRef(visibility);

  useEffect(() => {
    if (!container.current) return;
    const controller = new AbortController();
    const style = BASEMAP_STYLES[initialTheme.current];
    const created = createMap(container.current, {
      style,
      layers: LAYERS,
      signal: controller.signal,
      isVisible: (def) => isVisible(currentVisibility.current, def),
      onLayersChecked: setAvailable,
    });
    const handlers = attachPopups(created, LAYERS);
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
    for (const def of LAYERS) setLayerVisibility(map.current, def, isVisible(visibility, def));
    popups.current?.closeIfHidden();
  }, [visibility]);

  return (
    <>
      <div ref={container} className="map" />
      <MapPanel>
        <BasemapToggle value={theme} onChange={setTheme} />
        <LayerList
          layers={LAYERS}
          visibility={visibility}
          available={available}
          onChange={(id, visible) => setVisibility((state) => withVisibility(state, id, visible))}
        />
      </MapPanel>
    </>
  );
}
