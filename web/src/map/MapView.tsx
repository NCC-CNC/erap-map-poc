import { useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { BASEMAP_STYLES, DEFAULT_BASEMAP_THEME, type BasemapTheme } from './basemap';
import { BasemapToggle } from './BasemapToggle';
import { createMap, setBasemapStyle } from './createMap';
import { attachPopups } from './popups';
import 'maplibre-gl/dist/maplibre-gl.css';

/**
 * Full-page map with a basemap toggle. Clicking a feature of a layer with a
 * pop-up definition opens its pop-up. MapLibre lives outside React's render
 * tree: the map is created once and removed on unmount.
 */
export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<MapLibreMap | null>(null);
  const appliedStyle = useRef<string | null>(null);
  const [theme, setTheme] = useState<BasemapTheme>(DEFAULT_BASEMAP_THEME);
  // Read when the map is created; later changes go through setBasemapStyle.
  const initialTheme = useRef(theme);

  useEffect(() => {
    if (!container.current) return;
    const controller = new AbortController();
    const style = BASEMAP_STYLES[initialTheme.current];
    const created = createMap(container.current, { style, signal: controller.signal });
    const detachPopups = attachPopups(created);
    map.current = created;
    appliedStyle.current = style;

    return () => {
      controller.abort();
      detachPopups();
      created.remove();
      map.current = null;
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

  return (
    <>
      <div ref={container} className="map" />
      <BasemapToggle value={theme} onChange={setTheme} />
    </>
  );
}
