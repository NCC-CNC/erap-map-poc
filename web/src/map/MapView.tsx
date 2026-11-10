import { useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { loadRuntimeConfig } from '../config';
import { DEFAULT_BASEMAP_THEME, resolveBasemaps, warnIfFallback, type BasemapTheme, type Basemaps } from './basemap';
import { BasemapToggle } from './BasemapToggle';
import { createMap, setBasemapStyle } from './createMap';
import { attachPopups } from './popups';
import 'maplibre-gl/dist/maplibre-gl.css';

/**
 * Full-page map with a basemap toggle. Clicking a feature of a layer with a
 * pop-up definition opens its pop-up. The runtime config is loaded first,
 * as it decides the basemap. MapLibre lives outside React's render tree:
 * the map is created once and removed on unmount.
 */
export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<MapLibreMap | null>(null);
  const appliedStyle = useRef<string | null>(null);
  const [basemaps, setBasemaps] = useState<Basemaps | null>(null);
  const [theme, setTheme] = useState<BasemapTheme>(DEFAULT_BASEMAP_THEME);
  // Read when the map is created; later changes go through setBasemapStyle.
  const initialTheme = useRef(theme);

  useEffect(() => {
    const controller = new AbortController();
    let created: MapLibreMap | undefined;
    let detachPopups: (() => void) | undefined;

    void loadRuntimeConfig({ signal: controller.signal })
      .then((config) => {
        if (controller.signal.aborted || !container.current) return;
        const resolved = resolveBasemaps(config.cartoApiKey);
        warnIfFallback(resolved);
        const style = resolved.styles[initialTheme.current];
        created = createMap(container.current, { style, signal: controller.signal });
        detachPopups = attachPopups(created);
        map.current = created;
        appliedStyle.current = style;
        setBasemaps(resolved);
      })
      .catch((error: unknown) => {
        if (!controller.signal.aborted) console.error('Could not start the map.', error);
      });

    return () => {
      controller.abort();
      detachPopups?.();
      created?.remove();
      map.current = null;
      appliedStyle.current = null;
    };
  }, []);

  useEffect(() => {
    if (!basemaps || !map.current) return;
    const style = basemaps.styles[theme];
    if (style === appliedStyle.current) return;
    setBasemapStyle(map.current, style);
    appliedStyle.current = style;
  }, [basemaps, theme]);

  return (
    <>
      <div ref={container} className="map" />
      <BasemapToggle value={theme} onChange={setTheme} disabled={!basemaps} />
    </>
  );
}
